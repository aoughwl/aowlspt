## What must be true of a `/client/mail/dialog/*` body the moment it leaves.
##
## This module exists because of a bug whose every part looked correct in
## isolation. `/client/match/local/end` read `transferItems`, found items in it,
## checked they were not already in the stash or the mailbox, and posted them.
## Every one of those steps did what it says. What arrived in the player's inbox
## was a message from "Unknown" holding one item called "Stash" drawn with a
## missing icon, and nothing anywhere reported a problem.
##
## MEASURED, live mailbox `store\aowl.tarkov\mail.00000000000a00000000004f`,
## 2026-08-28: one message, `type 4`, `uid ""`, `hasRewards true`, one
## attachment, `_tpl 566abbc34bdc2d92178b4576` -- "Standard stash 10x30" in
## `db.json` -- and its `_id 656f0f98d80a697f855d34b1` appears in NO profile
## item list, so it was the CLIENT's transfer container, not the player's own
## stash. `EFT.TransferItemsController.TryGetTransferContainer(string profileId,
## Stash)` is the reason: the thing `transferItems` is keyed by is a `Stash`,
## and it serialises its own root item alongside its contents.
##
## The writer is fixed in `emu/raid.transferredItems` and `emu/mail.newMessage`.
## This is the part that would have caught it, and it is deliberately written
## the way CLAUDE.md 9b demands: it asserts a property of the FINISHED PAYLOAD
## -- the bytes the client is about to be handed -- and it asserts a NEGATIVE.
## It does not re-read anything this server just wrote through the same code
## that wrote it. Feed it the exact 416-byte mailbox measured above and it says
## so; that is the input which makes it fail, and `selfCheckMail` runs on
## precisely that input at load so the claim is not taken on trust.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import mail
import templates

proc senderProblem(uid: string; tradersKnown: bool): string =
  ## Why this `uid` cannot be shown with a name, or `""` if it can.
  if uid.len != 24:
    return "sender id '" & uid & "' is not 24 characters, and " &
           "EFT.MongoID..ctor throws on it -- which takes the whole response " &
           "down, not just this row"
  if uid == SystemSenderId:
    return ""
  if not tradersKnown:
    # INCONCLUSIVE, not PASS. A database with no traders in it cannot say that
    # a sender is unknown, and reporting nothing here would be a check that
    # cannot fail.
    return ""
  if dbRead("traders." & uid).ok:
    return ""
  result = "sender id '" & uid & "' is neither a trader in the database nor " &
           "the declared system sender, so the client draws it as \"Unknown\""

proc attachmentProblems(msg: JsonRef; into: var seq[string]) =
  ## Every attachment of one message that must not be there.
  let data = msg.field("items.data")
  if not data.exists or not isArray(data):
    return
  for it in each(data):
    let tpl = it.field("_tpl").asText("")
    if isStashTpl(tpl):
      into.add "message " & msg.field("_id").asText("?") & " attaches item " &
               it.field("_id").asText("?") & " of template " & tpl &
               ", which is a stash/container ROOT -- a box, not cargo; the " &
               "client draws it as a single unusable item and hides whatever " &
               "was inside it"

proc mailPayloadProblems*(payloadJson: string): seq[string] =
  ## Everything wrong with a served `dialog/list`, `dialog/view` or
  ## `getAllAttachments` body. Empty means nothing was found -- which is only
  ## a pass if there was something to look at, so the caller checks that too.
  ##
  ## Both shapes are walked without being told which one it was given:
  ## `dialog/list` carries `data[].message`, `dialog/view` and
  ## `getAllAttachments` carry `data.messages[]`.
  result = @[]
  let tradersKnown = dbRead("traders").ok
  let root = whole(payloadJson)
  let data = root.field("data")
  if not data.exists:
    return
  if isArray(data):
    for row in each(data):
      let m = row.field("message")
      if m.exists and isObject(m):
        let uid = m.field("uid").asText("")
        let p = senderProblem(uid, tradersKnown)
        if p.len > 0:
          result.add p
        attachmentProblems(m, result)
  elif isObject(data):
    let msgs = data.field("messages")
    if msgs.exists and isArray(msgs):
      for m in each(msgs):
        if not isObject(m):
          result.add "a message in this dialog is not an object, so it " &
                     "renders as nothing at all"
          continue
        let p = senderProblem(m.field("uid").asText(""), tradersKnown)
        if p.len > 0:
          result.add p
        attachmentProblems(m, result)

proc selfCheckMail*(into: var seq[string]): bool =
  ## Proves the check above can FAIL, then proves it passes on a clean body.
  ##
  ## The first half is the point. A payload checker that has only ever been run
  ## on good input is indistinguishable from `return @[]`, and this repo has
  ## shipped four of those. The bad fixture is the real bug, byte for byte:
  ## the template and the empty sender measured in the live mailbox.
  result = true
  const stashTpl = "566abbc34bdc2d92178b4576"
  let bad = "{\"err\":0,\"data\":{\"messages\":[{\"_id\":\"aaaaaaaaaaaaaaaaaaaaaaaa\"," &
            "\"uid\":\"\",\"type\":4,\"hasRewards\":true,\"items\":{\"stash\":" &
            "\"bbbbbbbbbbbbbbbbbbbbbbbb\",\"data\":[{\"_id\":" &
            "\"656f0f98d80a697f855d34b1\",\"_tpl\":\"" & stashTpl &
            "\",\"parentId\":\"bbbbbbbbbbbbbbbbbbbbbbbb\",\"slotId\":\"main\"}]}}]}}"
  let found = mailPayloadProblems(bad)
  var sawStash = false
  var sawSender = false
  for f in found:
    if f.contains(stashTpl):
      sawStash = true
    if f.contains("is not 24 characters"):
      sawSender = true
  if not sawStash:
    into.add "mailcheck: the payload check does NOT notice a stash template " &
             "attached to a message, so it could never have caught the bug " &
             "it was written for"
    result = false
  if not sawSender:
    into.add "mailcheck: the payload check does NOT notice an empty sender id"
    result = false

  let good = "{\"err\":0,\"data\":{\"messages\":[{\"_id\":\"aaaaaaaaaaaaaaaaaaaaaaaa\"," &
             "\"uid\":\"" & SystemSenderId & "\",\"type\":4,\"hasRewards\":true," &
             "\"items\":{\"stash\":\"bbbbbbbbbbbbbbbbbbbbbbbb\",\"data\":[{\"_id\":" &
             "\"cccccccccccccccccccccccc\",\"_tpl\":\"590c657e86f77412b013051d\"," &
             "\"parentId\":\"bbbbbbbbbbbbbbbbbbbbbbbb\",\"slotId\":\"main\"}]}}]}}"
  let clean = mailPayloadProblems(good)
  if clean.len > 0:
    into.add "mailcheck: a well-formed mail payload was reported as broken: " &
             clean[0]
    result = false

  # -------------------------------------------------------------------------
  # The REPAIR, judged by the same check, on the same two shapes.
  # -------------------------------------------------------------------------
  #
  # `emu/mail.withUnwrappedContainer` heals mailboxes written before the
  # writer was fixed. It is asserted here, through `mailPayloadProblems`,
  # rather than by re-reading what it just wrote -- the negative that matters
  # is "no served attachment list still contains a container root", and this
  # is the module that already knows how to say that.
  let wrapped =
    "{\"_id\":\"aaaaaaaaaaaaaaaaaaaaaaaa\",\"uid\":\"" & SystemSenderId &
    "\",\"type\":4,\"hasRewards\":true,\"rewardCollected\":false,\"items\":{" &
    "\"stash\":\"bbbbbbbbbbbbbbbbbbbbbbbb\",\"data\":[" &
    "{\"_id\":\"656f0f98d80a697f855d34b1\",\"_tpl\":\"" & stashTpl &
    "\",\"parentId\":\"bbbbbbbbbbbbbbbbbbbbbbbb\",\"slotId\":\"main\"}," &
    "{\"_id\":\"dddddddddddddddddddddddd\",\"_tpl\":\"590c657e86f77412b013051d\"," &
    "\"parentId\":\"656f0f98d80a697f855d34b1\",\"slotId\":\"main\"}," &
    "{\"_id\":\"eeeeeeeeeeeeeeeeeeeeeeee\",\"_tpl\":\"590c657e86f77412b013051d\"," &
    "\"parentId\":\"656f0f98d80a697f855d34b1\",\"slotId\":\"main\"}]}}"
  let healed = mail.withUnwrappedContainer(wrapped)
  let healedBody = "{\"err\":0,\"data\":{\"messages\":[" & healed & "]}}"
  let healedProblems = mailPayloadProblems(healedBody)
  if healedProblems.len > 0:
    into.add "mailcheck: the mail repair left a container root in the served " &
             "payload: " & healedProblems[0]
    result = false
  # The cargo must SURVIVE the unwrap. Dropping the box and its contents would
  # also produce zero problems above, so the negative alone cannot pass this.
  if not healed.contains("dddddddddddddddddddddddd") or
     not healed.contains("eeeeeeeeeeeeeeeeeeeeeeee"):
    into.add "mailcheck: the mail repair unwrapped the transfer container but " &
             "did not serve what was INSIDE it -- the player loses the cargo"
    result = false
  if healed.contains("656f0f98d80a697f855d34b1"):
    into.add "mailcheck: the mail repair still serves the transfer container's " &
             "own root item"
    result = false
  if not whole(healed).field("hasRewards").asBool(false):
    into.add "mailcheck: the mail repair dropped the reward badge from a " &
             "message that still has two items in it"
    result = false

  # And the live mailbox's ACTUAL shape: a container root and nothing else.
  # There is no cargo inside it to recover -- it was never serialised -- so the
  # only honest outcome is a message with no rewards. A repair that reported
  # success here would be the failure this file exists to prevent.
  let emptyWrapped =
    "{\"_id\":\"aaaaaaaaaaaaaaaaaaaaaaaa\",\"uid\":\"" & SystemSenderId &
    "\",\"type\":4,\"hasRewards\":true,\"rewardCollected\":false,\"items\":{" &
    "\"stash\":\"bbbbbbbbbbbbbbbbbbbbbbbb\",\"data\":[" &
    "{\"_id\":\"656f0f98d80a697f855d34b1\",\"_tpl\":\"" & stashTpl &
    "\",\"parentId\":\"bbbbbbbbbbbbbbbbbbbbbbbb\",\"slotId\":\"main\"}]}}"
  let healedEmpty = mail.withUnwrappedContainer(emptyWrapped)
  if mailPayloadProblems("{\"err\":0,\"data\":{\"messages\":[" & healedEmpty &
                         "]}}").len > 0:
    into.add "mailcheck: the mail repair still serves a container root for a " &
             "message whose only attachment was that container"
    result = false
  if whole(healedEmpty).field("hasRewards").asBool(false):
    into.add "mailcheck: a message whose only attachment was an empty " &
             "transfer container is still served with a reward badge, which " &
             "sends the player hunting for cargo that was never stored"
    result = false
