## Quests: accepting them, handing things over, finishing them.
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

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

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
  let rewards = field(tpl, "rewards." & state)
  if not rewards.found:
    return 0
  let list = each(rewards)
  for r in list:
    if r.field("type").asText("") == "Experience":
      result = result + r.field("value").asInt(0)

proc applyQuest*(questsJson: string; action: QuestAction; body: JsonRef;
                 nowSeconds: int; experience: var int;
                 problem: var string): string =
  ## Returns the new `Quests` array. `experience` is what the change earned, so
  ## the caller can add it to the profile without this module needing to know
  ## what a profile is.
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
    # Handing items over is progress, not completion. The items themselves are
    # removed by the inventory actions the client sends alongside this.
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
