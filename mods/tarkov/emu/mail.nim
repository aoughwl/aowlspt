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
## The inbox is **bounded**, and it did not used to be. Emptying a message
## leaves it in place on purpose -- `rewardCollected: true`, `hasRewards:
## false` -- so the player keeps the record of where the items came from. But
## nothing ever removed one, and a soak of 200 play cycles grew `mail.<id>` by
## 53133 bytes, about 267 per withdrawn-and-collected flea offer, monotonically
## for the life of the profile. Every request that opens the inbox carries all
## of it, and the same soak measured average request latency going from 797 us
## to 105 ms as it grew.
##
## What is dropped is only ever a **collected** message, and only the older
## ones: `mailKeepCollected` of them are kept per dialog (one by default) and
## the rest go, along with any collected message older than `mailKeepHours`.
## Both are off at zero or below, for anyone who wants the whole history.
##
## Per dialog rather than overall, because the inbox screen shows one row per
## sender with the *newest* message as its preview -- so the second-newest
## emptied "your offer was withdrawn" is not on any screen the client draws,
## and the items it is a record of are in the stash where the player put them.
## A message still holding items is never dropped at any age or count: the
## mailbox is the only place those items exist. Nor is an ordinary message with
## no attachments, which is the only record of what a trader said.
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
import store
import ids
import notify
import templates

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

var gKeepHours = 72
var gKeepCollected = 1

proc configureMail*(keepHours, keepCollected: int) =
  ## From the mod's config. Zero or fewer turns either rule off.
  gKeepHours = keepHours
  gKeepCollected = keepCollected

const SystemSenderId* = "000000000000000000000001"
  ## The sender a message with no trader behind it comes from.
  ##
  ## It has to be a MongoId and it may not be empty. `ChatMessagesList+
  ## DialogueChatMessageSerializer.Deserialize` hands the message's `uid`
  ## straight to `UpdatableChatMember.FindOrCreate` -> `EFT.MongoID..ctor`,
  ## which throws `ArgumentOutOfRangeException: Critical MongoId error:
  ## incorrect length. Id:` on anything that is not 24 characters -- measured
  ## in the client's own errors log, and it takes the WHOLE `/client/mail/
  ## dialog/list` response down with it, not just that one row.
  ##
  ## 24 HEX characters: the ctor's message names only the length, but whether
  ## it also validates the alphabet was NOT measured, so this stays inside what
  ## a real MongoId looks like. No BSG trader id is a run of zeros, so a system
  ## dialog cannot collide with a trader's.

proc senderId*(sender: string): string =
  ## A sender the client can construct a `MongoID` from.
  ##
  ## Real trader ids pass through untouched. Everything else -- `""` from the
  ## BTR hand-over, `"ragfair"` from the three flea notices -- is mapped, and
  ## mapped DETERMINISTICALLY, so the dialog a player pinned or removed is the
  ## same dialog after a restart.
  if sender.len == 24:
    return sender
  if sender.len == 0:
    return SystemSenderId
  # FNV-1a over the name, twice with different offsets, for 96 stable bits.
  var a = 0xcbf29ce484222325'i64
  var b = 0x100000001b3'i64
  for ch in sender:
    a = a xor int64(ord(ch))
    a = a * 0x100000001b3'i64
    b = b xor int64(ord(ch) + 131)
    b = b * 0x100000001b3'i64
  result = hex(a, 12) & hex(b, 12)

proc withHealedSender*(messageJson: string): string =
  ## Rewrites a stored message's `uid` if it cannot be a MongoId.
  ##
  ## Paired with `withoutBadSystemData` and for the same reason: fixing only
  ## the writer leaves every mailbox that already holds a `""`-sender message
  ## permanently unable to open its inbox.
  let uid = field(messageJson, "uid").asText("")
  let fixed = senderId(uid)
  if fixed == uid:
    return messageJson
  var d = parseObject(messageJson)
  if not d.ok:
    return messageJson
  setText(d, "uid", fixed)
  result = text(d)

proc withoutBadSystemData*(messageJson: string): string =
  ## Drops `systemData` unless it really is an object.
  ##
  ## The client DTO (`DialogueChatMessageSerializer.systemData`, measured with
  ## tools/fldoff.py) is a reference type, so ABSENT and `null` both deserialise
  ## to null and are fine; ANY scalar is a hard parse error. This never invents
  ## a populated object -- we have no dump of one -- it only removes a value
  ## that cannot possibly be right.
  let m = whole(messageJson)
  let sd = m.field("systemData")
  if not sd.exists:
    return messageJson
  if sd.isObject or sd.isNull:
    return messageJson
  var d = parseObject(messageJson)
  if not d.ok:
    return messageJson
  remove(d, "systemData")
  result = text(d)

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

proc withoutContainerRoots*(attachments: string): string =
  ## Drops stash / container ROOT items from an attachment array.
  ##
  ## The last line of defence, not the fix. The fix is in
  ## `emu/raid.transferredItems`, which no longer hands the transfer
  ## container's own root item to this module. This is here because a mailbox
  ## is the one place in this server where a wrong item cannot be undone by
  ## the player -- a box they cannot open, holding cargo the mail grid will
  ## not descend into -- and because three other callers (`emu/quests`,
  ## `emu/insurance`, `emu/market`) build attachment arrays from sources this
  ## module does not control.
  ##
  ## Dropping the root is safe for its contents: anything that was inside it
  ## now has a `parentId` naming an item that is not in the array, and
  ## `parented` re-parents exactly those onto the message's own container.
  let list = parseArray(attachments)
  if not list.ok:
    return attachments
  var out1 = newList()
  var removed = 0
  for i in 0 ..< list.len:
    if isStashTpl(field(list.items[i], "_tpl").asText("")):
      inc removed
      continue
    out1.add list.items[i]
  if removed == 0:
    return attachments
  warn $removed & " container root item(s) were kept out of a mail " &
       "attachment; a stash is a box, not a reward"
  result = text(out1)

proc withUnwrappedContainer*(messageJson: string): string =
  ## REPAIR ON READ for mailboxes written before `emu/raid.transferredItems`
  ## stopped handing over the transfer container's own root.
  ##
  ## The shape of the damage: `EFT.TransferItemsController.TryGetTransferContainer`
  ## returns a Stash, so the serialised transfer carried the CONTAINER's root
  ## item beside its contents, and `parented` re-parented only that root onto
  ## the message. The player is left with a box the mail grid will not descend
  ## into, and their cargo hanging off an `_id` that is a root no longer.
  ##
  ## The repair is the two functions above, composed, and nothing new:
  ## `withoutContainerRoots` drops the container root, which makes everything
  ## that was inside it an orphan, and `parented` is *defined* as "re-parent
  ## the orphans onto the message's container". So the contents become the
  ## attachments. Reusing them is deliberate -- a second, parallel notion of
  ## "what is a container root" is exactly how the writer and the reader drift.
  ##
  ## This reads and rewrites ONLY the response. The store file is never
  ## touched, so nothing here can lose a message, and a mailbox repaired by a
  ## later real fix simply stops matching the fast path below.
  ##
  ## THREE outcomes, not two, per CLAUDE.md 9b:
  ##   * no container root among the attachments -> returned byte-identical;
  ##   * a container root WITH contents -> the contents are served instead;
  ##   * a container root with NOTHING inside it -> there is no cargo to serve
  ##     and pretending otherwise would be the silent failure. The message is
  ##     served with `hasRewards:false` so no parcel badge sends the player
  ##     hunting for it, and the loss is stated out loud, naming the message.
  let m = whole(messageJson)
  if not m.field("hasRewards").asBool(false):
    return messageJson
  let data = m.field("items.data")
  if not data.found or not isArray(data):
    return messageJson
  let before = parseArray(data)
  if not before.ok or before.len == 0:
    return messageJson
  # The fast path, taken by every healthy message in every mailbox: decide
  # whether there is anything to do BEFORE building a single new document.
  var anyRoot = false
  for i in 0 ..< before.len:
    if isStashTpl(field(before.items[i], "_tpl").asText("")):
      anyRoot = true
  if not anyRoot:
    return messageJson

  var d = parseObject(messageJson)
  if not d.ok:
    return messageJson
  let containerId = get(d, "items").field("stash").asText("")
  if containerId.len == 0:
    # No container id means `parented` has nothing to re-parent onto, and a
    # guessed one would put the items in a window that does not exist.
    warn "mail repair: message '" & m.field("_id").asText("") &
         "' holds a container root but names no container; left untouched"
    return messageJson

  let kept = withoutContainerRoots(text(before))
  let repaired = parseArray(kept)
  let count = (if repaired.ok: repaired.len else: 0)
  if count == 0:
    warn "mail repair: message '" & m.field("_id").asText("") &
         "' attached a container root and NOTHING ELSE, so there is no " &
         "cargo inside it to serve -- the contents were never stored. It is " &
         "served with no rewards rather than as a box that cannot be opened"
    setBool(d, "hasRewards", false)
    var empty = newDoc()
    setText(empty, "stash", containerId)
    setRaw(empty, "data", "[]")
    setRaw(d, "items", text(empty))
    return text(d)

  var box = newDoc()
  setText(box, "stash", containerId)
  setRaw(box, "data", parented(kept, containerId))
  setRaw(d, "items", text(box))
  info "mail repair: message '" & m.field("_id").asText("") &
       "' had its transfer container unwrapped; " & $count &
       " item(s) inside it are served as the attachments"
  result = text(d)

proc loadMail*(profileId: string; usable: var bool): List =
  ## Every message for a profile, oldest first, and whether the inbox could be
  ## read at all.
  ##
  ## An empty inbox is `[]`, not an error: a new profile has one. An inbox that
  ## is *there* and unreadable is a different answer, and the difference matters
  ## because every writer here rewrites the whole list -- see `emu/store`. The
  ## mailbox is also the only place a redeemed reward exists before it is
  ## redeemed, so overwriting it loses items outright.
  let raw1 = readKey(mailKey(profileId), usable)
  if raw1.len == 0:
    return newList()
  result = parseArray(raw1)
  if not result.ok:
    result = newList()
  # Heal the stored inbox on the way out. Messages written before this existed
  # carry `systemData: false`, and the client's `DialogueChatMessageSerializer`
  # declares that member as `ChatMessageSystemData` -- an OBJECT. Newtonsoft
  # cannot convert Boolean to a class, throws inside `ExecuteRequest`, and the
  # exception kills the raid load, not just the inbox. Fixing only the writer
  # would leave every existing mailbox broken forever, so the read heals too.
  #
  # `withUnwrappedContainer` is the third healer, and it is HERE rather than in
  # the four route handlers on purpose: `dialogList`, `dialogView`,
  # `allAttachments` and redemption (`attachmentsOf`) all read through this one
  # proc, so putting it here is what makes the inbox badge, the dialog window,
  # the collect-all screen and the item the player actually drags out agree.
  # A repair applied in the view but not in redemption would show cargo that
  # could not be taken.
  for i in 0 ..< result.len:
    result.replaceAt(i, withUnwrappedContainer(
                          withHealedSender(withoutBadSystemData(result.items[i]))))

proc loadMail*(profileId: string): List =
  ## For the read-only callers: the inbox screen, the dialog view, the
  ## attachment list. A failure shows an empty inbox for one request and is
  ## logged; it writes nothing.
  var usable = true
  result = loadMail(profileId, usable)

proc saveMail*(profileId: string; messages: List): bool =
  result = save(mailKey(profileId), text(messages)) == Ok

proc newMessage*(sender, text1: string; kind: MessageKind; nowSeconds: int;
                 attachments0: string = ""): Doc =
  ## One message. `attachments` is a raw JSON array of items when there are any;
  ## a message with an empty one is a message with no rewards, which is the
  ## common case and must not be reported as having them -- the client puts a
  ## badge on the inbox for messages with rewards and a wrong badge sends the
  ## player looking for something that is not there.
  # Filtered before anything else looks at it, so `hasRewards` and the
  # container below are both decided on what is really being sent. A message
  # whose ONLY attachment was a container root is a message with no rewards,
  # and must not carry the badge that sends a player looking for one.
  let attachments = withoutContainerRoots(attachments0)
  result = newDoc()
  setText(result, "_id", newId())
  setText(result, "uid", senderId(sender))
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

proc collected(messageJson: string): bool =
  ## Has this message been emptied? `rewardCollected` is set by
  ## `removeAttachments` when the last item leaves, and it is the only mark that
  ## distinguishes "the player already has this" from "this is still owed".
  let m = whole(messageJson)
  if not m.field("rewardCollected").asBool(false):
    return false
  # Belt and braces: a message that still reports rewards is not reclaimable
  # whatever the other flag says. The two disagreeing means a bug somewhere
  # else, and the safe reading of a bug here is "keep the items".
  result = not m.field("hasRewards").asBool(false)

proc prune*(messages: List; nowSeconds: int): List =
  ## Drops collected messages: those past the keep window, and those beyond the
  ## per-dialog allowance. Order is preserved, and nothing that still holds
  ## items is ever dropped.
  ##
  ## `nowSeconds` of zero or less means "no clock here" and skips the age rule
  ## -- `removeAttachments` runs this on the write that empties a message and
  ## has no clock to hand. The count rule is the one that bounds the store, and
  ## it holds either way.
  result = messages
  var drop: seq[bool] = @[]
  var any = false
  for i in 0 ..< messages.len:
    let can = collected(messages.items[i])
    if can:
      any = true
    drop.add false
  if not any:
    return

  if gKeepHours > 0 and nowSeconds > 0:
    let cutoff = nowSeconds - gKeepHours * 3600
    for i in 0 ..< messages.len:
      if collected(messages.items[i]) and
         field(messages.items[i], "dt").asInt(0) < cutoff:
        drop[i] = true

  if gKeepCollected > 0:
    # Newest first, so the allowance is spent on the messages the inbox screen
    # can actually reach. `deliver` appends, so document order is oldest first.
    var senders: seq[string] = @[]
    var seen: seq[int] = @[]
    var i = messages.len - 1
    while i >= 0:
      if not drop[i] and collected(messages.items[i]):
        let uid = field(messages.items[i], "uid").asText("")
        var at = -1
        for k in 0 ..< senders.len:
          if senders[k] == uid:
            at = k
        if at < 0:
          senders.add uid
          seen.add 1
        else:
          seen[at] = seen[at] + 1
          if seen[at] > gKeepCollected:
            drop[i] = true
      dec i

  var out1 = newList()
  for i in 0 ..< messages.len:
    if not drop[i]:
      out1.add messages.items[i]
  result = out1

# ---------------------------------------------------------------------------
# What the player does to a dialog
# ---------------------------------------------------------------------------
#
# Four routes -- `read`, `pin`, `unpin`, `remove` -- and all four were stubs
# answering `null` and doing nothing, so reading mail never cleared the badge,
# pinning never pinned and removing never removed. The reference dump has the
# shapes: `SetDialogReadRequestData { Dialogs: List<MongoId> }`,
# `PinDialogRequestData { DialogId }`, `RemoveDialogRequestData { DialogId }`,
# and `Profile.Dialogue { Id, Type, Messages, Users, Pinned, New,
# AttachmentsNew }` -- which is why `pinned` and `new` are members of what
# `dialogList` builds, and why both were hard-coded.
#
# **Where the state lives.** `read` is per *message*, so it goes on the message.
# `pinned` and `removed` are per *dialog*, and this mod has no dialog document
# to put them on -- the inbox is a flat list of messages and a dialog is a
# `uid` that appears in some of them. So they go in a second store key,
# `maildlg.<profile id>`, an object keyed by sender. Keeping them there rather
# than duplicating them onto every message means "pin this dialog" is one write
# whatever the dialog holds, and a dialog with no messages left can still be
# marked.

const StateKeyPrefix* = "maildlg."

proc dialogStateKey*(profileId: string): string = StateKeyPrefix & profileId

proc loadDialogState(profileId: string; usable: var bool): Doc =
  let raw1 = readKey(dialogStateKey(profileId), usable)
  if raw1.len == 0:
    return newDoc()
  result = parseObject(raw1)
  if not result.ok:
    result = newDoc()

proc loadDialogState(profileId: string): Doc =
  var usable = true
  result = loadDialogState(profileId, usable)

proc saveDialogState(profileId: string; state: Doc): bool =
  result = save(dialogStateKey(profileId), text(state)) == Ok

proc dialogFlag(state: Doc; uid, name: string): bool =
  if uid.len == 0:
    return false
  result = get(state, uid).field(name).asBool(false)

proc setDialogFlag(state: var Doc; uid, name: string; value: bool) =
  var entry = parseObject(getRaw(state, uid))
  if not entry.ok:
    entry = newDoc()
  setBool(entry, name, value)
  setRaw(state, uid, text(entry))

proc unread(messageJson: string): bool =
  ## Absent is unread. Every message written before this existed has no `read`
  ## member, and the honest reading of "nobody has said you read this" is that
  ## you have not -- the other way round would silently clear the badge on
  ## every mailbox in existence the first time this shipped.
  not field(messageJson, "read").asBool(false)

proc deliver*(profileId, sender, text1: string; kind: MessageKind;
              nowSeconds: int; attachments: string = ""): bool =
  ## Appends a message and saves. The whole inbox is rewritten, which is the
  ## right trade at inbox sizes and the wrong one at a hundred thousand -- if
  ## that ever matters, the fix is a key per message, not a partial write.
  ##
  ## Pruned on the way through, because this is the one place the inbox grows
  ## and doing it here means the bound holds without a sweep that has to know
  ## which profiles exist.
  var usable = true
  let existing = loadMail(profileId, usable)
  if not usable:
    # The inbox is there and could not be read. Delivering into an empty list
    # would replace it -- with a quest reward or an insurance return in it, that
    # is the player's items gone. Refusing means the caller keeps the item where
    # it is and can try again.
    return false
  var messages = prune(existing, nowSeconds)
  messages.add newMessage(sender, text1, kind, nowSeconds, attachments)
  result = saveMail(profileId, messages)

  # And tell the player, if there is one logged in.
  #
  # This is the source of the notification rather than a sweep over what
  # changed, and the difference is what makes the notifier worth having: a
  # quest reward, an insurance return and a sold flea offer all arrive here,
  # and the badge appears when the message does instead of up to a minute
  # later. It is after the save on purpose -- a notification for a message that
  # failed to persist sends the player to an inbox that does not have it.
  #
  # The push cannot fail in a way this cares about: with no websocket open it
  # goes on the poll's queue, and with nobody logged in it goes nowhere, which
  # is correct. So the result is discarded rather than checked.
  if result:
    discard notifyProfile(profileId,
                          newMessageNote(sender, "", ord(kind), nowSeconds))
    # A dialog the player removed comes back when its sender writes again --
    # the client's own behaviour, and the only alternative here is a trader
    # whose insurance returns land in a row nobody can see.
    var stateUsable = true
    var state = loadDialogState(profileId, stateUsable)
    if stateUsable and dialogFlag(state, sender, "removed"):
      setDialogFlag(state, sender, "removed", false)
      discard saveDialogState(profileId, state)

proc markDialogsRead*(profileId: string; dialogIds: seq[string]): int =
  ## `/client/mail/dialog/read`. Returns how many messages changed.
  ##
  ## An empty `dialogIds` marks **nothing**, rather than everything: the
  ## request DTO always names the dialogs, so an empty list is a request this
  ## server did not understand, and the destructive reading of a request nobody
  ## made is the wrong one.
  result = 0
  if dialogIds.len == 0:
    return 0
  var usable = true
  var messages = loadMail(profileId, usable)
  if not usable:
    return 0
  for i in 0 ..< messages.len:
    let uid = field(messages.items[i], "uid").asText("")
    var wanted = false
    for want in dialogIds:
      if want == uid:
        wanted = true
    if not wanted or not unread(messages.items[i]):
      continue
    var m = parseObject(messages.items[i])
    if not m.ok:
      continue
    setBool(m, "read", true)
    messages.replaceAt(i, text(m))
    inc result
  if result > 0 and not saveMail(profileId, messages):
    return 0

proc setDialogPinned*(profileId, dialogId: string; pinned: bool): bool =
  ## `/client/mail/dialog/pin` and `/unpin`.
  if dialogId.len == 0:
    return false
  var usable = true
  var state = loadDialogState(profileId, usable)
  if not usable:
    return false
  if dialogFlag(state, dialogId, "pinned") == pinned:
    return true
  setDialogFlag(state, dialogId, "pinned", pinned)
  result = saveDialogState(profileId, state)

proc removeDialog*(profileId, dialogId: string; kept: var int): bool =
  ## `/client/mail/dialog/remove`. `kept` comes back with the number of
  ## messages that were **not** deleted because they still hold the player's
  ## property.
  ##
  ## The client's semantics are a delete: the row goes off the inbox and does
  ## not come back. That is what happens here -- the dialog is marked `removed`
  ## and `dialogList` stops building a row for it, and every message of that
  ## sender that holds nothing is deleted outright rather than merely hidden,
  ## because a hidden message is a store that grows forever for a player who
  ## thought they were tidying up.
  ##
  ## The exception is the one this mod cannot give away: **a message that still
  ## holds uncollected items is the only place those items exist.** Deleting it
  ## destroys an insurance return or a quest reward on a mis-click, with no
  ## undo anywhere in this server. Those messages stay in the store. They are
  ## off the inbox like everything else in the dialog, and they are still on
  ## `getAllAttachments` -- the "collect all" screen, which lists messages with
  ## rewards and not dialogs -- so the gear is reachable and the row is gone.
  ##
  ## A new message from the same sender clears the mark, which is also the
  ## client's behaviour: a deleted chat comes back when the trader writes
  ## again. `deliver` does that.
  kept = 0
  if dialogId.len == 0:
    return false
  var usable = true
  var messages = loadMail(profileId, usable)
  if not usable:
    return false
  var keepList = newList()
  var removedAny = false
  for i in 0 ..< messages.len:
    let m = whole(messages.items[i])
    if m.field("uid").asText("") != dialogId:
      keepList.add messages.items[i]
      continue
    removedAny = true
    if m.field("hasRewards").asBool(false) and
       not m.field("rewardCollected").asBool(false):
      keepList.add messages.items[i]
      inc kept
  if removedAny and not saveMail(profileId, keepList):
    return false
  var state = loadDialogState(profileId, usable)
  if not usable:
    return false
  setDialogFlag(state, dialogId, "removed", true)
  result = saveDialogState(profileId, state)

proc dialogList*(profileId: string): string =
  ## The inbox screen: one entry per sender, with the newest message as its
  ## preview, an unread count, and whether the player pinned it.
  ##
  ## A dialog the player removed is not built at all -- that is what makes
  ## `remove` stick across a restart, and it is checked over the wire rather
  ## than assumed.
  let messages = loadMail(profileId)
  let state = loadDialogState(profileId)
  var senders: seq[string] = @[]
  var newest: seq[string] = @[]
  var counts: seq[int] = @[]
  var waiting: seq[int] = @[]
  var fresh: seq[int] = @[]
  for i in 0 ..< messages.len:
    let m = whole(messages.items[i])
    let uid = m.field("uid").asText("")
    if dialogFlag(state, uid, "removed"):
      continue
    let isNew = (if unread(messages.items[i]): 1 else: 0)
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
      fresh.add isNew
    else:
      newest[at] = messages.items[i]
      counts[at] = counts[at] + 1
      if pending:
        waiting[at] = waiting[at] + 1
      fresh[at] = fresh[at] + isNew

  var out1 = arr()
  for k in 0 ..< senders.len:
    var d = obj()
    put(d, "_id", senders[k])
    put(d, "type", ord(mkNpcTrader))
    put(d, "message", raw(newest[k]))
    put(d, "pinned", dialogFlag(state, senders[k], "pinned"))
    # The unread badge. Hard-coded to zero for as long as this route existed,
    # which is the same defect as the four stub handlers: the client draws
    # whatever the server says, and a server that always says "nothing new"
    # has no unread mail however much of it arrives.
    put(d, "new", fresh[k])
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
    # `raw`, not the bare string. `out1` is a JsonArray, and its `add(string)`
    # overload *quotes* what it is given: adding the message text directly put
    # `"{\"_id\":\"...\"}"` on the wire -- an array of strings where the
    # client expects an array of message objects. It parses without complaint
    # and then renders an empty dialog, because every element is a string with
    # no `_id`, no `text` and no `items`.
    out1.add raw(messages.items[i])
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
      # `raw` for the same reason as in `dialogView`: without it the "collect
      # all" screen was answered `{"messages":["{\"_id\":\"...\"}"]}` --
      # JSON strings, not objects -- and the screen listed nothing to collect
      # while the inbox badge said there was.
      out1.add raw(messages.items[i])
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
  var usable = true
  var messages = loadMail(profileId, usable)
  if not usable:
    return false
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
  # And the write that empties a message is the write that can reclaim the last
  # one: without pruning here the newly-collected message and the one it
  # replaces both sit in the store until the *next* delivery, which is one
  # message of permanent slack per profile and shows up as a store that never
  # quite comes back to the size it was.
  result = saveMail(profileId, prune(messages, 0))
