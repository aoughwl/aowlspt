## Quests: accepting them, handing things over, finishing them — and checking
## that the finishing was earned.
##
## A quest is not an object the server owns — it is an entry in the profile's
## `Quests` array saying which template the player is on and what state it is
## in. The template itself (conditions, rewards, which trader) lives in the
## database, and a server without one can still track state: the player can
## accept a quest the server knows nothing about, and the client renders it from
## its own bundles.
##
## The states are the client's own spelling and are not negotiable:
## `Locked`, `AvailableForStart`, `Started`, `AvailableForFinish`, `Success`,
## `Fail`. A state outside that set is a quest the client draws as blank.
##
## This module is the half that has a profile, a database and a mailbox.
## `emu/questcond` is the half that has none of those: it reads a template and
## answers questions about it, and every decision here is made by asking it.
## The split is not tidiness — it is what makes the condition evaluator
## testable, and `questcond.selfCheck` is the test.
##
## The rule the guards exist for: **a quest that pays out for nothing is worse
## than one that will not complete.** A refused completion is visible, says
## which condition failed, and the player can go and do it. A completion that
## pays for nothing is invisible, and the player who notices has already been
## handed an experience level and a rifle they did not earn.
##
## The one place that rule bends is a quest the loaded database does not have.
## There the conditions are unknown rather than unmet, and the quest completes
## with whatever rewards the template does not name — because the alternative
## is a player stranded forever on a quest the server cannot describe. It is
## logged; it is not silent.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids
import profile
import mail
import questcond

type
  QuestAction* = enum
    qaNone, qaAccept, qaComplete, qaHandover, qaFail

proc questAction*(name: string): QuestAction =
  case name
  of "QuestAccept": qaAccept
  of "QuestComplete": qaComplete
  of "QuestHandover": qaHandover
  of "QuestFail": qaFail
  else: qaNone

proc findQuest(list: List; qid: string): int =
  result = -1
  for i in 0 ..< list.len:
    if field(list.items[i], "qid").asText("") == qid:
      return i

proc setState(list: var List; qid, state: string; nowSeconds: int) =
  ## Sets or adds an entry, keeping every other field of an existing one --
  ## `completedConditions` in particular, which is progress a state change must
  ## not wipe.
  let at = findQuest(list, qid)
  if at >= 0:
    var d = parseObject(list.items[at])
    setText(d, "status", state)
    setNumber(d, "statusTimer", nowSeconds)
    list.replaceAt(at, text(d))
    return
  var d = newDoc()
  setText(d, "qid", qid)
  setText(d, "status", state)
  setNumber(d, "startTime", nowSeconds)
  setNumber(d, "statusTimer", nowSeconds)
  setRaw(d, "completedConditions", "[]")
  setBool(d, "availableAfter", false)
  list.add d

proc questTemplate*(qid: string): string =
  let v = dbRead("templates.quests." & qid)
  if v.ok and v.raw.len > 0:
    return v.raw
  result = ""

proc rewardExperience*(qid, state: string): int =
  ## Experience from a quest's own reward table, when the database has one.
  ## Zero when it does not -- a quest with no known rewards still completes,
  ## because refusing to complete it would strand the player on it forever.
  result = 0
  let tpl = questTemplate(qid)
  if tpl.len == 0:
    return 0
  let rewards = rewardsOf(tpl, state)
  for r in rewards:
    if r.kind == "Experience":
      result = result + int(r.value)

# ---------------------------------------------------------------------------
# Editing the profile around a quest
# ---------------------------------------------------------------------------

proc setTopLevel(p: var Profile; name, rawValue: string) =
  ## Sets a top-level member of the profile, adding it when it is missing.
  ##
  ## `profile.setRaw` replaces a value that is already there and does nothing
  ## when it is not, which is right for a path into a document nobody promised
  ## a shape for -- and wrong for `TaskConditionCounters` on a profile that
  ## predates this module, where "nothing happened" means every counter written
  ## this raid is dropped without a word. The fallback re-serialises the top
  ## level through `Doc`, which keeps every other member as the raw text it
  ## already was.
  if p.field(name).found:
    setRaw(p, name, rawValue)
    return
  var d = parseObject(p.text)
  if not d.ok:
    return
  setRaw(d, name, rawValue)
  p.text = text(d)

proc counters(p: Profile): string =
  let c = p.field("TaskConditionCounters")
  if c.found and isObject(c):
    return c.raw()
  result = "{}"

proc questLabel(qid, tpl: string): string =
  ## What a refusal calls the quest. Its name when the database has one, its id
  ## when it does not -- an id is unhelpful, and it is still better than a
  ## message with a hole in it.
  let n = questName(tpl)
  if n.len > 0:
    return n
  result = qid

proc addStanding(p: var Profile; traderId: string; delta: float) =
  ## Moves one trader's standing, leaving every other field of their entry --
  ## `salesSum`, `unlocked`, `nextResupply` -- exactly as it was.
  if traderId.len == 0 or delta == 0.0:
    return
  var info = parseObject(p.field("TradersInfo").raw())
  if not info.ok:
    info = newDoc()
  var t = parseObject(getRaw(info, traderId))
  if not t.ok:
    t = newDoc()
    # A trader the profile has no entry for still has to start somewhere, and
    # the client reads all four of these before it draws the trader at all.
    setNumber(t, "loyaltyLevel", 1)
    setNumber(t, "salesSum", 0)
    setBool(t, "unlocked", true)
    setBool(t, "disabled", false)
  let current = get(t, "standing").asFloat(0.0)
  setNumber(t, "standing", current + delta)
  setRaw(info, traderId, text(t))
  setTopLevel(p, "TradersInfo", text(info))

proc freshIds(itemsJson: string): string =
  ## Re-ids a reward item tree, keeping its shape.
  ##
  ## The ids in a quest template are fixed: every player who completes the
  ## quest is handed items with the same `_id`. Once an attachment can be
  ## redeemed into the stash -- and it can, `emu/redeem` does it -- two rewards
  ## sharing an id is two items the client cannot tell apart, and the second
  ## one to arrive overwrites the first. `parentId` is remapped alongside so a
  ## rifle keeps its mods.
  let list = parseArray(itemsJson)
  if not list.ok:
    return "[]"
  var was: seq[string] = @[]
  var now1: seq[string] = @[]
  for i in 0 ..< list.len:
    let old = field(list.items[i], "_id").asText("")
    if old.len > 0:
      was.add old
      now1.add newId()
  var out1 = newList()
  for i in 0 ..< list.len:
    var d = parseObject(list.items[i])
    if not d.ok:
      continue
    let old = get(d, "_id").asText("")
    for k in 0 ..< was.len:
      if was[k] == old:
        setText(d, "_id", now1[k])
    let parent = get(d, "parentId").asText("")
    if parent.len > 0:
      for k in 0 ..< was.len:
        if was[k] == parent:
          setText(d, "parentId", now1[k])
    out1.add d
  result = text(out1)

proc unlockFollowUps(p: var Profile; qid: string; nowSeconds: int): int =
  ## Marks every quest that was waiting on this one as available.
  ##
  ## The whole quest table is taken apart once, with `members`, rather than
  ## looked up per candidate: a dotted lookup per quest is a fresh scan of a
  ## multi-megabyte document each time, and there are several hundred quests.
  ## Once per completion is a cost worth paying; several hundred times is not.
  result = 0
  let all = dbRead("templates.quests")
  if not all.ok or all.raw.len == 0:
    return
  let table = parseObject(all.raw)
  if not table.ok:
    return
  var list = parseArray(p.field("Quests").raw())
  if not list.ok:
    list = newList()
  var changed = false
  for m in table.fields:
    if m.name == qid:
      continue
    let status = questStatus(p.text, m.name)
    if status.len > 0 and status != "Locked":
      continue
    # Only the quests that actually named this one. Re-evaluating every quest
    # in the table on every completion would also work and would quietly cost
    # a full condition pass over the whole game.
    var waiting = false
    let starts = conditionsOf(m.value, cgStart)
    for c in starts:
      if condKind(c) == "Quest" and
         field(condProps(c), "target").asText("") == qid:
        waiting = true
    if not waiting:
      continue
    var reason = ""
    if not groupMet(p.text, m.name, m.value, cgStart, reason):
      continue
    setState(list, m.name, "AvailableForStart", nowSeconds)
    changed = true
    inc result
  if changed:
    setTopLevel(p, "Quests", text(list))

proc grantRewards(p: var Profile; qid, tpl, state: string; nowSeconds: int;
                  experience: var int): seq[string] =
  ## Pays a quest out. Returns the notes worth logging -- reward kinds that
  ## were read and not applied, named rather than dropped, because a player
  ## missing an unlocked trader assort needs the reason to exist somewhere.
  result = @[]
  experience = 0
  if tpl.len == 0:
    return
  let trader = traderOf(tpl)
  var attachments = newList()
  let rewards = rewardsOf(tpl, state)
  for r in rewards:
    case r.kind
    of "Experience":
      experience = experience + int(r.value)
    of "TraderStanding":
      let who = if r.target.len > 0: r.target else: trader
      addStanding(p, who, r.value)
    of "Item":
      if r.items.len > 0:
        let fresh = parseArray(freshIds(r.items))
        for i in 0 ..< fresh.len:
          attachments.add fresh.items[i]
    of "TraderUnlock":
      # Unlocking a trader is an edit to `TradersInfo.<id>.unlocked`, and it is
      # applied: it is one field, and a locked trader is a quest chain the
      # player cannot continue.
      var info = parseObject(p.field("TradersInfo").raw())
      if info.ok and r.target.len > 0:
        var t = parseObject(getRaw(info, r.target))
        if not t.ok:
          t = newDoc()
          setNumber(t, "loyaltyLevel", 1)
          setNumber(t, "salesSum", 0)
          setNumber(t, "standing", 0)
          setBool(t, "disabled", false)
        setBool(t, "unlocked", true)
        setRaw(info, r.target, text(t))
        setTopLevel(p, "TradersInfo", text(info))
    else:
      # AssortmentUnlock, Skill, StashRows, ProductionScheme, and whatever the
      # next patch adds. Each needs a system this module does not own, and a
      # reward silently swallowed is a support question with no answer.
      result.add "reward not applied: " & r.kind &
                 (if r.target.len > 0: " (" & r.target & ")" else: "")

  if attachments.len > 0:
    let kind = if state == "Fail": mkQuestFail
               elif state == "Started": mkQuestStart
               else: mkQuestSuccess
    let label = questLabel(qid, tpl)
    # Items go through the post rather than into the stash. The stash has no
    # room reserved for them, a full stash would lose them, and the mailbox is
    # where the game itself puts a quest reward.
    if not deliver(p.id, trader, label, kind, nowSeconds, text(attachments)):
      result.add "the reward items for " & label & " could not be delivered"

# ---------------------------------------------------------------------------
# The actions
# ---------------------------------------------------------------------------

proc handedOver(body: JsonRef): int =
  ## How many items a `QuestHandover` carried. One per entry when an entry does
  ## not say -- a handover with no count is one item, and reading it as zero
  ## makes a five-item condition unreachable.
  result = 0
  let items = body.field("items")
  if not items.found:
    return 1
  let list = each(items)
  for i in list:
    let n = i.field("count").asInt(1)
    result = result + (if n > 0: n else: 1)
  if result == 0:
    result = 1

proc requiredFor(tpl, condIdent: string): int =
  ## What a condition asks for, across all three groups. Zero when the template
  ## does not have the condition -- which is the signal to fall back to the old
  ## behaviour of crediting a handover outright, because there is nothing to
  ## count against.
  result = 0
  if tpl.len == 0 or condIdent.len == 0:
    return
  var g = cgStart
  while true:
    let conds = conditionsOf(tpl, g)
    for c in conds:
      if condId(c) == condIdent:
        let n = int(numberAt(whole(condProps(c)), "value", 0.0))
        return (if n > 0: n else: 1)
    if g == cgStart: g = cgFinish
    elif g == cgFinish: g = cgFail
    else: break

proc applyQuestOnProfile*(p: var Profile; action: QuestAction; body: JsonRef;
                          nowSeconds: int; experience: var int;
                          problem: var string): bool =
  ## One quest action, guarded and paid. Returns whether the profile changed;
  ## `problem` is set on a refusal and is what the client shows the player.
  ##
  ## `experience` is an out-parameter rather than an edit to `Info.Experience`
  ## because a batch of item-event actions accumulates experience from several
  ## sources and adds it once -- adding it here as well would pay it twice.
  experience = 0
  problem = ""
  let qid = body.field("qid").asText("")
  if qid.len == 0:
    problem = "that quest action names no quest"
    return false

  let tpl = questTemplate(qid)
  let label = questLabel(qid, tpl)
  var list = parseArray(p.field("Quests").raw())
  if not list.ok:
    list = newList()

  case action
  of qaAccept:
    let status = questStatus(p.text, qid)
    if status == "Started" or status == "Success":
      # A replayed accept, or a client out of step. Starting it again would
      # reset `completedConditions` on a quest already half done.
      problem = "cannot accept " & label & ": it is already " & status
      return false
    var reason = ""
    var unchecked = 0
    if tpl.len > 0 and not groupMet(p.text, qid, tpl, cgStart, reason, unchecked):
      problem = "cannot accept " & label & ": " & reason
      return false
    if tpl.len == 0:
      warn "accepting " & qid & ": the database has no template for it, so " &
           "its start conditions were not checked"
    elif unchecked > 0:
      warn "accepting " & label & ": " & $unchecked &
           " start condition(s) are of a kind this server does not evaluate"
    setState(list, qid, "Started", nowSeconds)
    setTopLevel(p, "Quests", text(list))
    # Some quests hand over an item at the start -- a key, a marker. Paid here
    # so the player has it before they are asked to use it.
    let notes = grantRewards(p, qid, tpl, "Started", nowSeconds, experience)
    for n in notes:
      warn label & ": " & n
    return true

  of qaComplete:
    let status = questStatus(p.text, qid)
    if status == "Success":
      problem = "cannot complete " & label & ": it is already finished"
      return false
    if status != "Started" and status != "AvailableForFinish":
      problem = "cannot complete " & label & ": it is " &
                (if status.len == 0: "not started" else: status)
      return false
    var reason = ""
    var unchecked = 0
    if tpl.len > 0 and not groupMet(p.text, qid, tpl, cgFinish, reason,
                                    unchecked):
      problem = "cannot complete " & label & ": " & reason
      return false
    if tpl.len == 0:
      warn "completing " & qid & ": the database has no template for it, so " &
           "nothing was checked and nothing is paid"
    elif unchecked > 0:
      warn "completing " & label & ": " & $unchecked &
           " finish condition(s) are of a kind this server does not evaluate"
    setState(list, qid, "Success", nowSeconds)
    setTopLevel(p, "Quests", text(list))
    let notes = grantRewards(p, qid, tpl, "Success", nowSeconds, experience)
    for n in notes:
      warn label & ": " & n
    let opened = unlockFollowUps(p, qid, nowSeconds)
    if opened > 0:
      info label & " opened " & $opened & " follow-up quest(s)"
    return true

  of qaFail:
    setState(list, qid, "Fail", nowSeconds)
    setTopLevel(p, "Quests", text(list))
    # Failure rewards are usually a standing penalty, and a penalty that is not
    # applied is a failure with no cost.
    let notes = grantRewards(p, qid, tpl, "Fail", nowSeconds, experience)
    for n in notes:
      warn label & ": " & n
    return true

  of qaHandover:
    let at = findQuest(list, qid)
    if at < 0:
      problem = "handover for a quest that was never started: " & label
      return false
    let cond = body.field("conditionId").asText("")
    if cond.len == 0:
      problem = "a handover for " & label & " that names no condition"
      return false

    let given = handedOver(body)
    let need = requiredFor(tpl, cond)
    let sofar = counterValue(p.text, cond) + given
    setTopLevel(p, "TaskConditionCounters",
                setCounter(counters(p), cond, "HandoverItem", qid, sofar))

    # Marked complete only when the count is actually there. The old behaviour
    # credited the condition on the first handover, which finished a "hand over
    # five" condition after one -- and the items themselves are removed by the
    # inventory actions in the same batch either way, so a partial handover
    # that credited fully was a player five items poorer for nothing.
    var d = parseObject(list.items[at])
    if need == 0 or sofar >= need:
      var done = parseArray(getRaw(d, "completedConditions"))
      if not done.ok:
        done = newList()
      var already = false
      for i in 0 ..< done.len:
        if done.at(i).asText("") == cond:
          already = true
      if not already:
        done.add quoted(cond)
      setRaw(d, "completedConditions", text(done))
      list.replaceAt(at, text(d))
      setTopLevel(p, "Quests", text(list))
    return true

  of qaNone:
    problem = "not a quest action"
    return false

# ---------------------------------------------------------------------------
# After a raid
# ---------------------------------------------------------------------------

proc raidLocation*(body: string): string =
  ## Which map the raid was on, out of the raid-result body.
  ##
  ## The client spells it two ways depending on build: a `location` member, or
  ## a `serverId` of the form `bigmap.1700000000`. Read wrong, every
  ## `Location`-qualified kill condition silently stops counting, so both are
  ## tried before giving up.
  let direct = field(body, "location")
  if direct.found and direct.asText("").len > 0:
    return direct.asText("")
  let server = field(body, "serverId").asText("")
  if server.len == 0:
    return ""
  var name = ""
  for ch in server:
    if ch == '.':
      break
    name.add ch
  result = name

proc advanceQuestsAfterRaid*(p: var Profile; beforeText, location,
                             exitStatus: string; nowSeconds: int): int =
  ## Folds a raid's results into the quest state. Returns the number of quests
  ## whose status changed.
  ##
  ## `p` is the profile the client handed back; `beforeText` is the one the
  ## server had before the raid. Both are needed: the client's copy is the only
  ## place this raid's counters exist, and the server's is the only place a
  ## counter the client forgot still exists.
  result = 0
  let merged = mergeCounters(field(beforeText, "TaskConditionCounters").raw(),
                             counters(p))
  var now1 = merged

  var list = parseArray(p.field("Quests").raw())
  if not list.ok:
    return 0

  # Kills the client did not report a counter for. This is a fallback, not the
  # mechanism -- see `questcond.killCredit` for why it credits nothing rather
  # than guessing when a condition carries a qualifier it cannot check.
  for i in 0 ..< list.len:
    let entry = whole(list.items[i])
    if entry.field("status").asText("") != "Started":
      continue
    let qid = entry.field("qid").asText("")
    let tpl = questTemplate(qid)
    if tpl.len == 0:
      continue
    let conds = conditionsOf(tpl, cgFinish)
    for c in conds:
      if condKind(c) != "CounterCreator":
        continue
      let ident = condId(c)
      if ident.len == 0 or hasCounter(now1, ident):
        continue
      var unverifiable = false
      let credit = killCredit(c, p.text, location, exitStatus, unverifiable)
      if credit > 0:
        now1 = setCounter(now1, ident, "CounterCreator", qid, credit)
        info "credited " & $credit & " kill(s) to " & questLabel(qid, tpl) &
             " from the raid's victim list"

  setTopLevel(p, "TaskConditionCounters", now1)

  # Now re-read the states with the new counters in place. `Fail` is checked
  # first: a quest that both failed and finished is failed, because a Fail
  # group that is met is almost always "you killed the person you were told to
  # protect" and finishing it anyway would pay for it.
  list = parseArray(p.field("Quests").raw())
  if not list.ok:
    return 0
  var changed = false
  for i in 0 ..< list.len:
    let entry = whole(list.items[i])
    let status = entry.field("status").asText("")
    if status != "Started" and status != "AvailableForFinish":
      continue
    let qid = entry.field("qid").asText("")
    let tpl = questTemplate(qid)
    if tpl.len == 0:
      continue
    var reason = ""
    let fails = conditionsOf(tpl, cgFail)
    if fails.len > 0 and groupMet(p.text, qid, tpl, cgFail, reason):
      setState(list, qid, "Fail", nowSeconds)
      changed = true
      inc result
      warn questLabel(qid, tpl) & " failed during the raid"
      continue
    if status == "Started" and groupMet(p.text, qid, tpl, cgFinish, reason):
      # Ready to hand in, not handed in. The rewards are paid by the
      # `QuestComplete` the player sends when they talk to the trader, and
      # paying them here would pay them twice.
      setState(list, qid, "AvailableForFinish", nowSeconds)
      changed = true
      inc result
      success questLabel(qid, tpl) & " is ready to hand in"
  if changed:
    setTopLevel(p, "Quests", text(list))

# ---------------------------------------------------------------------------
# The unguarded entry point
# ---------------------------------------------------------------------------

proc applyQuest*(questsJson: string; action: QuestAction; body: JsonRef;
                 nowSeconds: int; experience: var int;
                 problem: var string): string =
  ## Returns the new `Quests` array, with **no conditions checked**.
  ##
  ## Kept only while `tarkov.nim` still calls it. It cannot check anything: it
  ## is handed the quest array and not the profile, and every condition worth
  ## evaluating is about the profile -- the player's level, their standing, the
  ## counters a raid wrote. Once the item-event dispatch calls
  ## `applyQuestOnProfile` instead, this goes.
  experience = 0
  problem = ""
  var list = parseArray(questsJson)
  if not list.ok:
    list = newList()
  let qid = body.field("qid").asText("")
  if qid.len == 0:
    problem = "that quest action names no quest"
    return questsJson
  case action
  of qaAccept:
    setState(list, qid, "Started", nowSeconds)
  of qaComplete:
    setState(list, qid, "Success", nowSeconds)
    experience = rewardExperience(qid, "Success")
  of qaFail:
    setState(list, qid, "Fail", nowSeconds)
  of qaHandover:
    let at = findQuest(list, qid)
    if at < 0:
      problem = "handover for a quest that was never started: " & qid
      return questsJson
    var d = parseObject(list.items[at])
    var done = parseArray(getRaw(d, "completedConditions"))
    if not done.ok:
      done = newList()
    let cond = body.field("conditionId").asText("")
    if cond.len > 0:
      var already = false
      for i in 0 ..< done.len:
        if done.at(i).asText("") == cond:
          already = true
      if not already:
        done.add quoted(cond)
    setRaw(d, "completedConditions", text(done))
    list.replaceAt(at, text(d))
  of qaNone:
    problem = "not a quest action"
    return questsJson
  result = text(list)
