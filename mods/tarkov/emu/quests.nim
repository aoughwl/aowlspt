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
import traders
import repeatable
import templates

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
  ## MEASURED, not assumed: `availableAfter` is a UNIX-second delay, an INTEGER.
  ## A byte scan of the live db.json found 783 occurrences and every one is a
  ## number -- 758 of them `0`, the rest 5 / 3600 / 7200 / 36000 / 43200 /
  ## 75600 / 86400. Never a boolean. Writing `false` here made the client's
  ## typed reader throw `error reading integer. unexpected token: Boolean.
  ## Path '[0].Quests[N].availableAfter'` and take the quest list with it --
  ## valid JSON, wrong TYPE, so any check that only parses would still pass.
  setNumber(d, "availableAfter", 0)
  list.add d

proc questTemplate*(qid: string): string =
  let v = dbRead("templates.quests." & qid)
  if v.ok and v.raw.len > 0:
    return v.raw
  result = ""

proc questTemplate*(p: Profile; qid: string; nowSeconds: int): string =
  ## The database's template, or -- when there is none -- the one
  ## `emu/repeatable` computes for a daily this profile currently has.
  ##
  ## This one lookup is the whole integration. A repeatable quest is an
  ## ordinary quest whose template happens to be a function of the profile and
  ## the clock rather than a row in a table, so accepting one, handing items to
  ## one and completing one all go through the code that was already here and
  ## already tested: the same condition evaluator, the same counters, the same
  ## reward payout, the same refusals. Nothing below this line knows the
  ## difference.
  ##
  ## The database is asked first, so a real quest can never be shadowed by a
  ## generated one -- the generated ids come out of a seeded stream and a
  ## collision with a real quest id would otherwise silently replace it.
  let direct = questTemplate(qid)
  if direct.len > 0:
    return direct
  result = questTemplateFor(p, qid, nowSeconds)

var gQuestXpMultiplier = 1.0

proc configureQuestXp*(multiplier: float) =
  gQuestXpMultiplier = multiplier

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
  if gQuestXpMultiplier != 1.0 and result > 0:
    result = int(float(result) * gQuestXpMultiplier + 0.5)

# ---------------------------------------------------------------------------
# Editing the profile around a quest
# ---------------------------------------------------------------------------

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

proc freshIds*(itemsJson: string): string =
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

var gRefreshId = ""
var gRefreshText = ""

proc refreshAvailability*(p: var Profile; nowSeconds: int): int =
  ## The ENTRY POINT of the quest chain.
  ##
  ## `unlockFollowUps` only ever re-evaluates the quests that NAMED the one
  ## just completed, so on a profile that has completed nothing it does
  ## nothing at all -- and a fresh profile therefore has no quest it is
  ## allowed to start, forever. That is not a display bug: the whole tree is
  ## unreachable, because reaching any of it requires completing something
  ## first.
  ##
  ## This is the same `groupMet(cgStart)` test `unlockFollowUps` applies,
  ## applied instead to EVERY quest the database has whose profile entry is
  ## absent or `Locked`. Quests already Started/Success/Fail are left alone --
  ## re-deciding a quest the player is on would reset it.
  ##
  ## The cost is one full condition pass over ~558 templates. It is paid on
  ## profile creation and on `/client/quest/list`, which is a menu load, not a
  ## frame. It is NOT paid per condition-evaluation: the table is taken apart
  ## once with `members`, for the reason `unlockFollowUps` documents.
  result = 0
  # Nothing has happened to this profile since the last pass, so this pass has
  # nothing to find.
  #
  # The pass is idempotent by design -- it only ever moves a quest out of
  # absent/`Locked` -- which means running it against a profile document byte
  # for byte identical to the one it last ran against cannot produce a
  # different answer. `/client/quest/list` calls it on EVERY menu load, and a
  # menu load does not change the profile, so in the steady state this is the
  # whole cost of the route. The key is the profile TEXT, not its id or a
  # revision counter, so a change to the profile from any direction misses.
  # The one input it does NOT key on is `templates.quests` itself: a `dbPatch`
  # of the quest table while the server is up would not be seen. That is
  # stated rather than defended -- nothing in this emulator patches it.
  if p.id.len > 0 and p.id == gRefreshId and p.text == gRefreshText:
    return 0
  let all = dbRead("templates.quests")
  if not all.ok or all.raw.len == 0:
    return
  let table = parseObject(all.raw)
  if not table.ok:
    return
  var list = parseArray(p.field("Quests").raw())
  if not list.ok:
    list = newList()
  # The profile's quest states, read once rather than re-scanned per template.
  # `questStatus` walks the profile's whole `Quests` array from the front, and
  # this loop runs it 558 times; see `questListFor` for the measurement.
  var sIds: seq[string] = @[]
  var sStates: seq[string] = @[]
  let mine0 = field(p.text, "Quests")
  if mine0.found:
    for e in each(mine0):
      let id0 = e.field("qid").asText("")
      if id0.len == 0:
        continue
      sIds.add id0
      sStates.add e.field("status").asText("")
  var changed = false
  for m in table.fields:
    var status = ""
    for k in 0 ..< sIds.len:
      if sIds[k] == m.name:
        status = sStates[k]
        break
    # Empty and `Locked` are both "not decided in the player's favour yet".
    # Anything else is a state the player reached and must keep.
    if status.len > 0 and status != "Locked":
      continue
    var reason = ""
    if not groupMet(p.text, m.name, m.value, cgStart, reason):
      # Still gated. Recorded as Locked rather than left absent, so the
      # served list can state a status for every quest instead of omitting
      # the key on some -- a missing key and `status:0` are not the same
      # document to the client.
      if status.len == 0:
        setState(list, m.name, "Locked", nowSeconds)
        changed = true
      continue
    setState(list, m.name, "AvailableForStart", nowSeconds)
    changed = true
    inc result
  if changed:
    setTopLevel(p, "Quests", text(list))
  # Remembered AFTER the write, so the memo holds the text a *later* call will
  # actually arrive with. Remembering the input instead would memo a document
  # that no longer exists and the skip above would never fire.
  gRefreshId = p.id
  gRefreshText = p.text

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

proc grantRewardList*(p: var Profile; rewards: seq[Reward];
                      sender, label: string; kind: MessageKind;
                      nowSeconds: int; experience: var int): seq[string] =
  ## Pays out a list of rewards, whatever produced it. Returns the notes worth
  ## logging -- reward kinds that were read and not applied, named rather than
  ## dropped, because a player missing an unlocked trader assort needs the
  ## reason to exist somewhere.
  ##
  ## Shared with `emu/achievements`, which pays the same `Reward` shape out of a
  ## different table: the reference gives an achievement a `Rewards` list of the
  ## same type a quest has, and two copies of this arithmetic is two places for
  ## the next reward kind to be forgotten.
  result = @[]
  experience = 0
  var attachments = newList()
  for r in rewards:
    case r.kind
    of "Experience":
      experience = experience + int(r.value)
    of "TraderStanding":
      let who = if r.target.len > 0: r.target else: sender
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
      if r.target.len > 0:
        var t = traderEntry(p, r.target)
        setBool(t, "unlocked", true)
        putTraderEntry(p, r.target, t)
    else:
      # AssortmentUnlock, Skill, StashRows, ProductionScheme, and whatever the
      # next patch adds. Each needs a system this module does not own, and a
      # reward silently swallowed is a support question with no answer.
      result.add "reward not applied: " & r.kind &
                 (if r.target.len > 0: " (" & r.target & ")" else: "")

  if attachments.len > 0:
    # Items go through the post rather than into the stash. The stash has no
    # room reserved for them, a full stash would lose them, and the mailbox is
    # where the game itself puts a reward.
    if not deliver(p.id, sender, label, kind, nowSeconds, text(attachments)):
      result.add "the reward items for " & label & " could not be delivered"

proc grantRewards(p: var Profile; qid, tpl, state: string; nowSeconds: int;
                  experience: var int): seq[string] =
  ## One quest's payout for one outcome.
  result = @[]
  experience = 0
  if tpl.len == 0:
    return
  let kind = if state == "Fail": mkQuestFail
             elif state == "Started": mkQuestStart
             else: mkQuestSuccess
  result = grantRewardList(p, rewardsOf(tpl, state), traderOf(tpl),
                           questLabel(qid, tpl), kind, nowSeconds, experience)

# ---------------------------------------------------------------------------
# The actions
# ---------------------------------------------------------------------------

proc handedOver(p: Profile; body: JsonRef): int =
  ## How many items a `QuestHandover` carried. One per entry when an entry does
  ## not say -- a handover with no count is one item, and reading it as zero
  ## makes a five-item condition unreachable.
  ##
  ## **Clamped to what the profile holds.** The count used to be taken from the
  ## request as written, so a body naming one item with `count: 9999` finished a
  ## "hand over five" condition -- and its reward -- while five items' worth of
  ## nothing left the stash. The credit now cannot exceed the item's own
  ## `StackObjectsCount`, which is the number the inventory actions in the same
  ## batch are about to remove.
  result = 0
  let items = body.field("items")
  if not items.found:
    return 1
  let owned = each(field(p.text, "Inventory.items"))
  let list = each(items)
  for i in list:
    var n = i.field("count").asInt(1)
    if n < 1:
      n = 1
    let id = i.field("id").asText("")
    if id.len > 0:
      # An id the profile does not have credits nothing: it is either an item
      # already handed over in an earlier request or one that was never there.
      var have = 0
      for it in owned:
        if it.field("_id").asText("") == id:
          have = it.field("upd.StackObjectsCount").asInt(1)
          if have < 1:
            have = 1
      if n > have:
        n = have
    result = result + n
  if list.len == 0:
    # No entries at all is the old shorthand for "one item", and it predates
    # the counts. An entry that resolved to nothing is *not* that: it is an id
    # the profile does not hold, and crediting one for it would put the loophole
    # straight back.
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
                          problem: var string; note: var string): bool =
  ## One quest action, guarded and paid. Returns whether the profile changed;
  ## `problem` is set on a refusal and is what the client shows the player.
  ##
  ## `note` is the other half: the action *was* applied and the player should
  ## still hear about it. There is one of those and it matters -- a quest the
  ## database has no template for is accepted, because a server with no quest
  ## table still has to let a client play, and none of its conditions were
  ## checked and none of its rewards exist. Answering `err:0` with nothing in
  ## it is how a player ends up wondering where the reward went.
  ##
  ## `experience` is an out-parameter rather than an edit to `Info.Experience`
  ## because a batch of item-event actions accumulates experience from several
  ## sources and adds it once -- adding it here as well would pay it twice.
  experience = 0
  problem = ""
  note = ""
  let qid = body.field("qid").asText("")
  if qid.len == 0:
    problem = "that quest action names no quest"
    return false

  let tpl = questTemplate(p, qid, nowSeconds)
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
      note = "accepted " & qid & ", but this server has no template for it: " &
             "its start conditions were not checked and its rewards do not " &
             "exist here"
      warn note
    elif unchecked > 0:
      warn "accepting " & label & ": " & $unchecked &
           " start condition(s) are of a kind this server does not evaluate"
    setState(list, qid, "Started", nowSeconds)
    if tpl.len > 0 and questTemplate(qid).len == 0:
      # A generated quest -- a daily, a weekly, the scav's. Marked on the entry
      # so that `pruneExpiredRepeatables` can recognise its own and nothing
      # else: the whole reason it is safe to delete a finished quest's record is
      # that this flag says the server invented it in the first place.
      let at = findQuest(list, qid)
      if at >= 0:
        var d = parseObject(list.items[at])
        setBool(d, "sptRepeatable", true)
        list.replaceAt(at, text(d))
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
      note = "completed " & qid & ", but this server has no template for it: " &
             "nothing was checked and nothing is paid"
      warn note
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

    let given = handedOver(p, body)
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
  # `bigmap.1700000000` -- but **only** when there is a dot to split on.
  #
  # Post-1.0 spells `serverId` differently and does not put the map in it at
  # all: `TUTORIAL_1891947_20_08_2026_01_20_33` (capture seq 204), a mode and
  # an account and a timestamp. Returning everything up to the first dot used
  # to hand that whole string back as a map name, so every `Location`
  # condition compared against a map that does not exist and quietly failed.
  # No dot now means no map, and the caller is expected to have remembered one
  # -- see `raidMapFor` and `emu/sessions.enterRaid`.
  var name = ""
  var sawDot = false
  for ch in server:
    if ch == '.':
      sawDot = true
      break
    name.add ch
  if not sawDot:
    return ""
  result = name

proc pruneExpiredRepeatables*(p: var Profile; nowSeconds: int): int =
  ## Drops the profile's record of generated quests that are finished *and* no
  ## longer offered. Returns how many went.
  ##
  ## Three dailies a day, kept forever, is a profile document that grows for the
  ## life of the character -- and this server reads and writes the whole
  ## document on every request, so growth there is latency on everything.
  ## `emu/mail` is bounded for exactly this reason and the measurement is in
  ## EMULATOR.md.
  ##
  ## Three guards, and each of them is the difference between a bound and a
  ## bug:
  ##
  ## - only entries carrying `sptRepeatable`, which this module writes itself
  ##   when it accepts one. A quest from the database is never touched.
  ## - only `Success` or `Fail`. A daily the player is halfway through is state
  ##   they earned, and it survives the day it was offered for -- it becomes a
  ##   quest with no template, which is a case `questTemplate` already handles.
  ## - only ids that are **not** currently offered, which is the check that a
  ##   quest cannot be pruned and then re-accepted for its reward again.
  result = 0
  var list = parseArray(p.field("Quests").raw())
  if not list.ok or list.len == 0:
    return 0
  var anyGenerated = false
  for i in 0 ..< list.len:
    if field(list.items[i], "sptRepeatable").asBool(false):
      anyGenerated = true
  if not anyGenerated:
    # The common case, and it costs one pass rather than a generation of every
    # set for every profile that has never seen a daily.
    return 0
  let offered = currentIds(p, nowSeconds)
  var kept = newList()
  for i in 0 ..< list.len:
    let entry = whole(list.items[i])
    let status = entry.field("status").asText("")
    if entry.field("sptRepeatable").asBool(false) and
       (status == "Success" or status == "Fail"):
      let qid = entry.field("qid").asText("")
      var current = false
      for id in offered:
        if id == qid:
          current = true
      if not current:
        inc result
        continue
    kept.add list.items[i]
  if result > 0:
    setTopLevel(p, "Quests", text(kept))

proc advanceQuestsAfterRaid*(p: var Profile; beforeText, location,
                             exitStatus: string; nowSeconds: int;
                             clock: RaidClock = unknownClock();
                             locationAliases: seq[string] = @[]): int =
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
    let tpl = questTemplate(p, qid, nowSeconds)
    if tpl.len == 0:
      continue
    let conds = conditionsOf(tpl, cgFinish)
    for c in conds:
      if condKind(c) != "CounterCreator":
        continue
      let ident = condId(c)
      if ident.len == 0 or hasCounter(now1, ident):
        continue
      var refused: seq[string] = @[]
      let credit = killCredit(c, p.text, location, exitStatus, refused,
                              clock, locationAliases)
      if credit > 0:
        now1 = setCounter(now1, ident, "CounterCreator", qid, credit)
        info "credited " & $credit & " kill(s) to " & questLabel(qid, tpl) &
             " from the raid's victim list"
      elif refused.len > 0:
        # The refusal is said out loud, with the clause that caused it. A
        # player who cannot finish a quest deserves to know which qualifier
        # stopped it -- silence here is indistinguishable from a server that
        # simply lost the kills. `killCredit` carries why each one is refused.
        var which = ""
        for r in refused:
          if which.len > 0: which.add ", "
          which.add r
        warn questLabel(qid, tpl) & ": this raid's kills were not credited " &
             "from the victim list -- the condition qualifies on " & which &
             ", which the raid report does not let this server check. " &
             "The quest advances only if the client reported its own counter."

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
    let tpl = questTemplate(p, qid, nowSeconds)
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

  # And the bound. A raid is the right moment: it is a write of the profile
  # anyway, it is the only thing that reliably happens between one day's
  # dailies and the next, and it is rare enough that regenerating the sets to
  # answer "is this one still offered" costs nothing anybody can measure.
  let dropped = pruneExpiredRepeatables(p, nowSeconds)
  if dropped > 0:
    info "dropped " & $dropped & " finished repeatable quest(s) that are no " &
         "longer offered"

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

# ---------------------------------------------------------------------------
# The served quest list
# ---------------------------------------------------------------------------

proc questListFor*(p: Profile): string =
  ## `/client/quest/list` for ONE profile: the cached template array with each
  ## element's `status` restated from what this profile says.
  ##
  ## `emu/templates.questList` passes the database through untouched, and the
  ## database is SPT's, where `status` is a STATIC field on the template. On a
  ## fresh profile that means 508 quests arrive as `status: 0` (Locked) and 50
  ## arrive with **no `status` key at all** -- and a missing key and `0` are
  ## not the same document to a deserialiser. Neither number has anything to
  ## do with the player.
  ##
  ## So the invariant asserted here is a negative one: after this proc, there
  ## is no quest in the served array whose status disagrees with the status
  ## `QuestAccept` would enforce, and no quest with the key missing.
  ##
  ## Whether the client's journal reads THIS field or reads the profile's own
  ## `Quests` array is NOT established -- both are now consistent, which is the
  ## only claim made.
  let base = questList()
  let list = parseArray(base)
  if not list.ok:
    return base

  # The profile's quest states, read ONCE.
  #
  # This used to call `questStatus(p.text, qid)` inside the loop below, and
  # that proc re-locates `Quests` in the profile text and walks the whole array
  # from the start. With 558 templates against a profile carrying a few hundred
  # entries that is a quadratic scan over a ~200 KB document, and it was the
  # cost of the route: MEASURED with `tools/loadpathbench.py`, `/client/quest/
  # list` took 2004 ms on the first request and 1803 ms on the second -- i.e.
  # essentially all of it was this, not serialization and not the deflate.
  #
  # Same answer, one pass. `questStatus` is left exactly as it is: it is the
  # right shape for its other callers, which ask about one quest.
  var qIds: seq[string] = @[]
  var qCodes: seq[int] = @[]
  let mine = field(p.text, "Quests")
  if mine.found:
    for e in each(mine):
      let id = e.field("qid").asText("")
      if id.len == 0:
        continue
      let c = statusCode(e.field("status").asText(""))
      qIds.add id
      qCodes.add(if c >= 0: c else: 0)

  var out1 = newList()
  for i in 0 ..< list.len:
    var d = parseObject(list.items[i])
    if not d.ok:
      continue
    let qid = get(d, "_id").asText("")
    var code = 0
    if qid.len > 0:
      for k in 0 ..< qIds.len:
        if qIds[k] == qid:
          code = qCodes[k]
          break
    setNumber(d, "status", code)
    out1.add d
  result = text(out1)
