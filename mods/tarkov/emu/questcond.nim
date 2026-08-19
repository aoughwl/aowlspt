## Quest conditions: reading them out of a template, and checking them against
## a profile.
##
## A quest template carries three groups of conditions — `AvailableForStart`,
## `AvailableForFinish`, `Fail` — and until something evaluates them a quest is
## a state machine with no guard on any transition: accept anything, complete
## anything, and be paid for it. This module is that guard.
##
## **Everything here is a pure function of JSON text.** Nothing in this file
## reads the database, touches the profile store, or sends mail; it takes the
## template text and the profile text and answers a question about them. That
## is what makes it testable without a game, a client or a database — `selfCheck`
## at the bottom runs the whole evaluator against literals — and it is why the
## database lookups and the profile edits live in `quests.nim` instead.
##
## Two condition spellings are in the wild and both are handled. The old one
## wraps a condition as `{"_parent":"Kills","_props":{...}}`; the current one
## flattens it to `{"conditionType":"Kills", ...}`. A dump of either vintage has
## to work, because the emulator is pointed at whatever database the user has.
##
## What is **not** evaluated, and is not faked:
##
## - `distance`, `weapon`, `daytime`, `equipment` and the other qualifiers
##   inside a `Kills` condition. When one is present and non-empty the kill is
##   not credited from a raid's victim list at all, because crediting a kill
##   whose qualifier could not be checked hands out progress that was not
##   earned. The client's own counter still counts — see `mergeCounters`.
## - Time limits (`availableAfter`, `Fail` conditions with a duration). Nothing
##   here has a clock in it beyond the timestamp a caller passes in.
## - Skill levels beyond `Skills.Common`, and hideout-area conditions.
##
## A condition kind this module does not know is reported as *unchecked* rather
## than as failed. `isChecked` says which is which, and a caller that wants to
## be strict can refuse on the count. Failing on an unknown kind would strand a
## player on a quest forever with no way out; passing it silently would be a
## free reward. Naming it is the only honest third option.

import std/strutils
import aowlspt/json

type
  CondGroup* = enum
    cgStart, cgFinish, cgFail

  Reward* = object
    ## One entry of a template's `rewards.<state>` array, flattened to what a
    ## caller can act on. `items` is the raw JSON array for an item reward and
    ## empty for every other kind.
    kind*: string
    target*: string
    value*: float
    items*: string

proc groupName*(g: CondGroup): string =
  case g
  of cgStart: "AvailableForStart"
  of cgFinish: "AvailableForFinish"
  of cgFail: "Fail"

# ---------------------------------------------------------------------------
# The two spellings
# ---------------------------------------------------------------------------

proc condKind*(cond: string): string =
  ## `conditionType` on a current dump, `_parent` on an older one. Empty when
  ## the value is not a condition at all, which a caller must treat as
  ## unchecked rather than as a kind it happens not to know.
  let flat = field(cond, "conditionType")
  if flat.found:
    return flat.asText("")
  result = field(cond, "_parent").asText("")

proc condProps*(cond: string): string =
  ## The properties, wherever this dump keeps them. The flattened spelling has
  ## no `_props` and puts everything on the condition itself, so "no `_props`"
  ## means "the condition is its own props" -- not "this condition has none".
  let nested = field(cond, "_props")
  if nested.found:
    return nested.raw()
  result = cond

proc condId*(cond: string): string =
  ## The condition's own id. It is the key `TaskConditionCounters` is stored
  ## under and the id a `QuestHandover` names, so a condition without one is a
  ## condition whose progress cannot be recorded anywhere.
  result = field(condProps(cond), "id").asText("")

proc conditionsOf*(tpl: string; g: CondGroup): seq[string] =
  ## One group of a template's conditions, each as raw JSON.
  result = @[]
  if tpl.len == 0:
    return
  let node = field(tpl, "conditions." & groupName(g))
  if not node.found:
    return
  let elems = each(node)
  for e in elems:
    result.add raw(e)

# ---------------------------------------------------------------------------
# Comparisons and statuses
# ---------------------------------------------------------------------------

proc parseNumber*(s: string): float =
  ## A number out of text, without raising. `parseFloat` is `.raises` and can
  ## only be called inside a `try`, which is a lot of machinery for reading a
  ## template field that is a number two thirds of the time.
  result = 0.0
  var i = 0
  var neg = false
  if i < s.len and (s[i] == '-' or s[i] == '+'):
    neg = s[i] == '-'
    inc i
  var whole1 = 0.0
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    whole1 = whole1 * 10.0 + float(ord(s[i]) - ord('0'))
    inc i
  var frac = 0.0
  var scale = 0.1
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      frac = frac + float(ord(s[i]) - ord('0')) * scale
      scale = scale * 0.1
      inc i
  result = whole1 + frac
  if neg:
    result = -result

proc numberAt*(j: JsonRef; name: string; default: float = 0.0): float =
  ## A member that is a number, whichever way this dump wrote it.
  ##
  ## The live quest templates write the same field both ways -- `"value": 1500`
  ## on one reward and `"value": "1500"` on the next -- and `asFloat` on a
  ## quoted value correctly refuses it as not-a-number. Reading experience as
  ## zero because the template quoted it is a quest that pays nothing, which is
  ## exactly the failure this module exists to prevent.
  let v = j.field(name)
  if not v.found:
    return default
  if isText(v):
    return parseNumber(v.asText(""))
  result = v.asFloat(default)

proc compareOk*(op: string; have, want: float): bool =
  ## The client's `compareMethod`, which is the operator written out. An absent
  ## one is `>=`: every condition in the live templates that omits it is a
  ## threshold, and treating a missing operator as equality would make "reach
  ## level 5" fail at level 6.
  case op
  of ">": have > want
  of "<": have < want
  of "<=": have <= want
  of "=", "==": have == want
  of "!=", "<>": have != want
  else: have >= want

proc statusCode*(name: string): int =
  ## The client's own numbering for a quest status. `Quest` conditions name the
  ## statuses they want as integers, so evaluating one means mapping the string
  ## this emulator stores back to the number the template speaks.
  case name
  of "Locked": 0
  of "AvailableForStart": 1
  of "Started": 2
  of "AvailableForFinish": 3
  of "Success": 4
  of "Fail": 5
  of "FailRestartable": 6
  of "MarkedAsFailed": 7
  of "Expired": 8
  of "AvailableAfter": 9
  else: -1

proc questStatus*(profileText, qid: string): string =
  ## What the profile says about one quest, or the empty string when it has
  ## never seen it. Empty is not `Locked`: a quest the profile has no entry for
  ## is one whose availability is still to be decided, and reporting it as
  ## locked would satisfy a `Quest` condition asking for status 0.
  let quests = field(profileText, "Quests")
  if not quests.found:
    return ""
  let elems = each(quests)
  for e in elems:
    if e.field("qid").asText("") == qid:
      return e.field("status").asText("")
  result = ""

proc completedConditions*(profileText, qid: string): seq[string] =
  result = @[]
  let quests = field(profileText, "Quests")
  if not quests.found:
    return
  let elems = each(quests)
  for e in elems:
    if e.field("qid").asText("") == qid:
      let done = e.field("completedConditions")
      if done.found:
        let ids = each(done)
        for i in ids:
          result.add i.asText("")
      return

proc isCompleted*(profileText, qid, condIdent: string): bool =
  if condIdent.len == 0:
    return false
  let done = completedConditions(profileText, qid)
  for d in done:
    if d == condIdent:
      return true
  result = false

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
#
# `TaskConditionCounters` is a flat map of condition id -> `{id, type,
# sourceId, value}`. It is looked up with `child` rather than a dotted path
# because the key is an id out of a database this emulator did not write, and a
# dotted path would silently mis-resolve one containing a dot.

proc counterValue*(profileText, condIdent: string): int =
  ## Progress recorded against one condition. Zero when there is none.
  ##
  ## `ConditionCounters.Counters` is read as a fallback because a client of an
  ## older build fills that array instead of the map, and a player whose
  ## progress is in the array would otherwise see it ignored.
  result = 0
  if condIdent.len == 0:
    return
  let map = field(profileText, "TaskConditionCounters")
  if map.found:
    let entry = child(map, condIdent)
    if entry.found:
      return entry.field("value").asInt(0)
  let legacy = field(profileText, "ConditionCounters.Counters")
  if legacy.found:
    let elems = each(legacy)
    for e in elems:
      if e.field("id").asText("") == condIdent:
        return e.field("value").asInt(0)

proc hasCounter*(countersJson, condIdent: string): bool =
  ## Whether a counter exists at all, which is a different question from
  ## whether it is zero. A condition the client has reported on -- even as
  ## nothing -- must not then be second-guessed from a victim list.
  if condIdent.len == 0:
    return false
  result = child(whole(countersJson), condIdent).found

proc setCounter*(countersJson, condIdent, kind, questId: string;
                 value: int): string =
  ## Writes one counter, keeping every other member of the map byte for byte --
  ## the map holds counters for quests this call knows nothing about.
  var d = parseObject(countersJson)
  if not d.ok:
    d = newDoc()
  var e = parseObject(getRaw(d, condIdent))
  if not e.ok:
    e = newDoc()
  setText(e, "id", condIdent)
  setText(e, "type", kind)
  setText(e, "sourceId", questId)
  setNumber(e, "value", value)
  setRaw(d, condIdent, text(e))
  result = text(d)

proc mergeCounters*(baseJson, incomingJson: string): string =
  ## The larger of the two values for every condition either map knows about.
  ##
  ## Larger, not "whatever the client last said". The raid result is a profile
  ## the client hands back, and a client that started the raid from a stale
  ## copy -- or reset a counter it treats as per-session -- would otherwise
  ## delete campaign progress that was already earned. `oneSessionOnly`
  ## counters are the case this gets wrong, and they are not modelled here;
  ## losing a session's worth of progress on one of those is a far cheaper
  ## mistake than losing a campaign's worth on all the others.
  var base = parseObject(baseJson)
  if not base.ok:
    base = newDoc()
  let inc1 = parseObject(incomingJson)
  if not inc1.ok:
    return text(base)
  for m in inc1.fields:
    let mine = whole(getRaw(base, m.name))
    let theirs = whole(m.value)
    if not mine.found or theirs.field("value").asInt(0) >
                         mine.field("value").asInt(0):
      setRaw(base, m.name, m.value)
  result = text(base)

# ---------------------------------------------------------------------------
# Evaluating one condition
# ---------------------------------------------------------------------------

proc isProgressKind(kind: string): bool =
  ## Kinds whose satisfaction is "a counter reached the required value". They
  ## are grouped because the profile records all of them the same way, whatever
  ## the player actually did to earn them.
  case kind
  of "CounterCreator", "HandoverItem", "FindItem", "LeaveItemAtLocation",
     "PlaceBeacon", "WeaponAssembly", "VisitPlace", "UseItem", "HealthEffect",
     "Shots", "SellItemToTrader": true
  else: false

proc isChecked*(kind: string): bool =
  ## Whether this module actually evaluates a kind. Everything else is passed
  ## and counted as unchecked by `groupMet` -- see the module comment.
  case kind
  of "Level", "Quest", "TraderLoyalty", "TraderStanding", "Skill": true
  else: isProgressKind(kind)

proc skillProgress(profileText, skillId: string): float =
  result = 0.0
  let common = field(profileText, "Skills.Common")
  if not common.found:
    return
  let elems = each(common)
  for e in elems:
    if e.field("Id").asText("") == skillId:
      return e.field("Progress").asFloat(0.0)

proc intText(v: float): string =
  ## Condition thresholds are written as numbers but read as counts. Printing
  ## `5` rather than `5.0` matters only in the refusal message, which is the
  ## one place a player reads it.
  result = $int(v)

proc evaluate*(profileText, qid, cond: string; reason: var string): bool =
  ## One condition against one profile. `reason` is filled in only on a refusal
  ## and says which condition failed and by how much -- a refusal that does not
  ## say what is missing sends the player back to the wiki.
  reason = ""
  let kind = condKind(cond)
  let props = condProps(cond)
  let p = whole(props)
  let op = p.field("compareMethod").asText(">=")

  case kind
  of "Level":
    let want = numberAt(p, "value", 0.0)
    let have = float(field(profileText, "Info.Level").asInt(1))
    if compareOk(op, have, want):
      return true
    reason = "level " & intText(have) & " is not " & op & " " & intText(want)
    return false
  of "Quest":
    let target = p.field("target").asText("")
    let have = statusCode(questStatus(profileText, target))
    let wanted = p.field("status")
    if not wanted.found:
      # A `Quest` condition with no status list says nothing; treating it as a
      # requirement would block on a condition that has none.
      return true
    let codes = each(wanted)
    for c in codes:
      if c.asInt(-1) == have:
        return true
    reason = "quest " & target & " is " &
             (if have < 0: "not started" else: questStatus(profileText, target))
    return false
  of "TraderLoyalty":
    let target = p.field("target").asText("")
    let want = numberAt(p, "value", 0.0)
    let info = child(field(profileText, "TradersInfo"), target)
    let have = info.field("loyaltyLevel").asFloat(1.0)
    if compareOk(op, have, want):
      return true
    reason = "loyalty level " & intText(have) & " with " & target &
             " is not " & op & " " & intText(want)
    return false
  of "TraderStanding":
    let target = p.field("target").asText("")
    let want = numberAt(p, "value", 0.0)
    let info = child(field(profileText, "TradersInfo"), target)
    let have = info.field("standing").asFloat(0.0)
    if compareOk(op, have, want):
      return true
    reason = "standing with " & target & " is not " & op & " " & $want
    return false
  of "Skill":
    let target = p.field("target").asText("")
    let want = numberAt(p, "value", 0.0)
    let have = skillProgress(profileText, target)
    if compareOk(op, have, want):
      return true
    reason = "skill " & target & " is not " & op & " " & $want
    return false
  else:
    if not isProgressKind(kind):
      # Unchecked, not failed. `groupMet` counts these separately.
      return true
    let ident = p.field("id").asText("")
    var want = int(numberAt(p, "value", 1.0))
    if want < 1:
      want = 1
    if isCompleted(profileText, qid, ident):
      # A condition the player has already been credited with stays credited
      # even if the counter behind it was never written -- an old handover, or
      # one on a server whose template table did not have the quest yet.
      return true
    let have = counterValue(profileText, ident)
    if have >= want:
      return true
    reason = kind & " " & $have & " of " & $want
    if ident.len > 0:
      reason = reason & " (" & ident & ")"
    return false

proc groupMet*(profileText, qid, tpl: string; g: CondGroup;
               reason: var string; unchecked: var int): bool =
  ## Every condition in a group. An empty group is met: a quest with no finish
  ## conditions is one you hand in by talking to the trader, and there are real
  ## ones like that.
  reason = ""
  unchecked = 0
  let conds = conditionsOf(tpl, g)
  var ok = true
  for c in conds:
    if not isChecked(condKind(c)):
      inc unchecked
      continue
    var why = ""
    if not evaluate(profileText, qid, c, why):
      if ok:
        # The first unmet condition is the one reported. Listing all of them
        # reads as a wall in the client's warning box, and the player fixes
        # them one at a time anyway.
        reason = why
      ok = false
  result = ok

proc groupMet*(profileText, qid, tpl: string; g: CondGroup;
               reason: var string): bool =
  var ignored = 0
  result = groupMet(profileText, qid, tpl, g, reason, ignored)

# ---------------------------------------------------------------------------
# Crediting a raid's kills
# ---------------------------------------------------------------------------
#
# The client accumulates `TaskConditionCounters` itself and hands them back in
# the raid result, and that is the input this trusts first. Deriving kills from
# `Stats.Eft.Victims` is the fallback for a counter the client did not report
# at all -- which happens on a quest accepted mid-raid, and on any client whose
# own quest data disagrees with the database this server was started with.

proc subConditions*(cond: string): seq[string] =
  ## The `counter.conditions` of a `CounterCreator`, each as raw JSON.
  result = @[]
  let node = field(condProps(cond), "counter.conditions")
  if not node.found:
    return
  let elems = each(node)
  for e in elems:
    result.add raw(e)

proc listHas(node: JsonRef; wanted: string): bool =
  ## Whether an array of strings contains a value. An absent or empty array is
  ## "no restriction" and is the caller's decision, not this one's.
  if not node.found:
    return false
  let elems = each(node)
  for e in elems:
    if e.asText("") == wanted:
      return true
  result = false

proc sideMatches(target, side: string): bool =
  case target
  of "", "Any": true
  of "AnyPmc": side == "Usec" or side == "Bear"
  of "Savage": side == "Savage"
  else: target == side

proc killCredit*(cond, victimsJson, location, exitStatus: string;
                 unverifiable: var bool): int =
  ## How many of a raid's victims this `CounterCreator` should count.
  ##
  ## `unverifiable` comes back true when the condition carries a qualifier this
  ## module cannot check -- a weapon list, a distance, a time of day. In that
  ## case the count is **zero**, not a guess: the alternative is crediting a
  ## sniper-rifle-only kill to a pistol, which completes a quest that was not
  ## done. The client's own counter is the answer for those, and it is merged
  ## in ahead of this.
  unverifiable = false
  result = 0
  let subs = subConditions(cond)
  if subs.len == 0:
    return 0

  var wantsKills = false
  var side = ""
  var roles = notFound()
  var bodyParts = notFound()
  var propsText: seq[string] = @[]

  for s in subs:
    let k = condKind(s)
    let sp = condProps(s)
    let sj = whole(sp)
    case k
    of "Kills":
      wantsKills = true
      side = sj.field("target").asText("")
      propsText.add sp
      # Qualifiers with no evaluator here. Checked for presence rather than
      # ignored, because ignoring one over-credits.
      if sj.field("weapon").count > 0 or
         sj.field("weaponModsInclusive").count > 0 or
         sj.field("distance").exists or
         sj.field("equipmentInclusive").count > 0 or
         sj.field("daytime").exists:
        unverifiable = true
      if sj.field("savageRole").count > 0:
        roles = sj.field("savageRole")
      if sj.field("bodyPart").count > 0:
        bodyParts = sj.field("bodyPart")
    of "Location":
      let target = sj.field("target")
      if target.count > 0 and not listHas(target, location):
        # The raid was somewhere else. Not unverifiable -- verified, and no.
        return 0
    of "ExitStatus":
      let status = sj.field("status")
      if status.count > 0 and not listHas(status, exitStatus):
        return 0
    else:
      # A sub-condition with no evaluator makes the whole counter unverifiable
      # for the same reason a qualifier does.
      unverifiable = true

  if not wantsKills or unverifiable:
    return 0

  let victims = field(victimsJson, "Stats.Eft.Victims")
  if not victims.found:
    return 0
  let list = each(victims)
  for v in list:
    if not sideMatches(side, v.field("Side").asText("")):
      continue
    if roles.found and not listHas(roles, v.field("Role").asText("")):
      continue
    if bodyParts.found and not listHas(bodyParts, v.field("BodyPart").asText("")):
      continue
    inc result

# ---------------------------------------------------------------------------
# Rewards
# ---------------------------------------------------------------------------

proc rewardList*(node: JsonRef): seq[Reward] =
  ## A `Reward` array, flattened to what a caller can act on. `value` is read as
  ## a float because the live templates write it as a string on some entries and
  ## a number on others, and `asFloat` reads `"1"` as 1 -- which is the whole
  ## reason not to read it with `asInt` off a raw member.
  ##
  ## Split out from `rewardsOf` because a quest keeps its rewards **per
  ## outcome** -- `rewards.Success`, `rewards.Fail` -- and an achievement keeps
  ## a single flat list: the reference has `Quest.Rewards` as a
  ## `QuestRewards` of named groups and `Achievement.Rewards` as a plain
  ## `IEnumerable<Reward>`. Same element, two containers.
  result = @[]
  if not node.found or not isArray(node):
    return
  let elems = each(node)
  for e in elems:
    var r = Reward(kind: e.field("type").asText(""),
                   target: e.field("target").asText(""),
                   value: numberAt(e, "value", 0.0),
                   items: "")
    let its = e.field("items")
    if its.found and isArray(its):
      r.items = its.raw()
    result.add r

proc rewardsOf*(tpl, state: string): seq[Reward] =
  ## A quest template's rewards for one outcome.
  result = @[]
  if tpl.len == 0:
    return
  result = rewardList(field(tpl, "rewards." & state))

proc traderOf*(tpl: string): string =
  ## Who gave the quest. The sender of the reward message, and the trader whose
  ## standing a `TraderStanding` reward moves when it names no target.
  let t = field(tpl, "traderId")
  if t.found:
    return t.asText("")
  result = field(tpl, "traderId2").asText("")

proc questName*(tpl: string): string =
  let n = field(tpl, "QuestName")
  if n.found:
    return n.asText("")
  result = field(tpl, "name").asText("")

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

proc selfCheck*(): string =
  ## Runs the evaluator against literals and returns one line per check. Kept
  ## in the module rather than in a test binary because the module has no
  ## dependency on the host: this runs anywhere the code compiles, which is the
  ## property that made the evaluator worth writing as pure text functions.
  var out1 = ""
  var fails = 0

  const Profile1 = """{"Info":{"Level":7},
    "TradersInfo":{"T1":{"loyaltyLevel":2,"standing":0.35}},
    "TaskConditionCounters":{"c1":{"id":"c1","value":3}},
    "Skills":{"Common":[{"Id":"Endurance","Progress":250.0}]},
    "Quests":[{"qid":"q0","status":"Success","completedConditions":["h9"]}]}"""

  const Flat = """{"conditionType":"Level","value":5,"compareMethod":">="}"""
  const Old = """{"_parent":"Level","_props":{"value":9,"compareMethod":">="}}"""
  const Counter5 = """{"conditionType":"CounterCreator","id":"c1","value":5,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage"},
                             {"conditionType":"Location","target":["bigmap"]}]}}"""
  const Counter2 = """{"conditionType":"CounterCreator","id":"c1","value":2}"""
  const QuestDone = """{"conditionType":"Quest","target":"q0","status":[4]}"""
  const QuestNot = """{"conditionType":"Quest","target":"q7","status":[4]}"""
  const Loyalty = """{"conditionType":"TraderLoyalty","target":"T1","value":3,
    "compareMethod":">="}"""
  const Handed = """{"conditionType":"HandoverItem","id":"h9","value":4}"""
  const Weird = """{"conditionType":"FlyToTheMoon","value":1}"""

  var why = ""
  # Both spellings reach the same evaluator.
  if not evaluate(Profile1, "q1", Flat, why): inc fails; out1.add "FAIL level>=5\n"
  else: out1.add "ok    level 7 satisfies >= 5\n"
  if evaluate(Profile1, "q1", Old, why): inc fails; out1.add "FAIL level>=9\n"
  else: out1.add "ok    level 7 refused by >= 9: " & why & "\n"

  if evaluate(Profile1, "q1", Counter5, why): inc fails; out1.add "FAIL counter 3/5\n"
  else: out1.add "ok    counter short of target: " & why & "\n"
  if not evaluate(Profile1, "q1", Counter2, why): inc fails; out1.add "FAIL counter 3/2\n"
  else: out1.add "ok    counter over target passes\n"

  if not evaluate(Profile1, "q1", QuestDone, why): inc fails; out1.add "FAIL quest done\n"
  else: out1.add "ok    a finished prerequisite passes\n"
  if evaluate(Profile1, "q1", QuestNot, why): inc fails; out1.add "FAIL quest absent\n"
  else: out1.add "ok    an unstarted prerequisite refuses: " & why & "\n"

  if evaluate(Profile1, "q1", Loyalty, why): inc fails; out1.add "FAIL loyalty\n"
  else: out1.add "ok    loyalty 2 refused by >= 3\n"

  # A condition already in `completedConditions` passes with no counter at all.
  if not evaluate(Profile1, "q0", Handed, why): inc fails; out1.add "FAIL handed over\n"
  else: out1.add "ok    a credited handover needs no counter\n"

  # An unknown kind passes, and is counted as unchecked rather than as met.
  if not evaluate(Profile1, "q1", Weird, why): inc fails; out1.add "FAIL unknown kind\n"
  else: out1.add "ok    an unknown condition is passed, not failed\n"
  if isChecked("FlyToTheMoon"): inc fails; out1.add "FAIL unknown is checked\n"
  else: out1.add "ok    and reported as unchecked\n"

  # Counters: merge takes the larger, and never drops a key.
  let merged = mergeCounters("""{"a":{"id":"a","value":9},"b":{"id":"b","value":1}}""",
                             """{"a":{"id":"a","value":2},"c":{"id":"c","value":4}}""")
  if field(merged, "a.value").asInt(0) != 9 or
     field(merged, "b.value").asInt(0) != 1 or
     field(merged, "c.value").asInt(0) != 4:
    inc fails
    out1.add "FAIL merge " & merged & "\n"
  else:
    out1.add "ok    merged counters keep the larger and lose nothing\n"

  let written = setCounter("{}", "z1", "CounterCreator", "q1", 6)
  if field(written, "z1.value").asInt(0) != 6:
    inc fails
    out1.add "FAIL setCounter " & written & "\n"
  else:
    out1.add "ok    a counter written into an empty map reads back\n"

  # Kill credit: the right map counts, the wrong one does not, and a condition
  # with a weapon list counts nothing at all.
  const Victims = """{"Stats":{"Eft":{"Victims":[
    {"Side":"Savage","Role":"assault","BodyPart":"Head"},
    {"Side":"Savage","Role":"assault","BodyPart":"Chest"},
    {"Side":"Usec","Role":"pmcUSEC","BodyPart":"Head"}]}}}"""
  var unver = false
  if killCredit(Counter5, Victims, "bigmap", "Survived", unver) != 2:
    inc fails
    out1.add "FAIL kill credit on the right map\n"
  else:
    out1.add "ok    two scav kills on the named map are credited\n"
  if killCredit(Counter5, Victims, "factory4_day", "Survived", unver) != 0:
    inc fails
    out1.add "FAIL kill credit on the wrong map\n"
  else:
    out1.add "ok    the same kills on another map are not\n"

  const Sniped = """{"conditionType":"CounterCreator","id":"c9","value":1,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage",
                             "weapon":["mosin"]}]}}"""
  if killCredit(Sniped, Victims, "bigmap", "Survived", unver) != 0 or not unver:
    inc fails
    out1.add "FAIL unverifiable qualifier\n"
  else:
    out1.add "ok    a weapon qualifier credits nothing and says so\n"

  # A whole group, and the reason it refused.
  const Tpl = """{"QuestName":"Debut","traderId":"T1","conditions":{
    "AvailableForStart":[""" & Flat & """],
    "AvailableForFinish":[""" & Counter5 & "," & Weird & """]},
    "rewards":{"Success":[{"type":"Experience","value":"1500"},
                          {"type":"TraderStanding","target":"T1","value":0.02},
                          {"type":"Item","target":"i1","items":[{"_id":"i1"}]}]}}"""
  var unchecked = 0
  if not groupMet(Profile1, "q1", Tpl, cgStart, why, unchecked):
    inc fails
    out1.add "FAIL start group\n"
  else:
    out1.add "ok    the start conditions are met\n"
  if groupMet(Profile1, "q1", Tpl, cgFinish, why, unchecked):
    inc fails
    out1.add "FAIL finish group\n"
  else:
    out1.add "ok    the finish conditions are not: " & why & "\n"
  if unchecked != 1:
    inc fails
    out1.add "FAIL unchecked count " & $unchecked & "\n"
  else:
    out1.add "ok    and one condition went unchecked\n"

  let rw = rewardsOf(Tpl, "Success")
  var xp = 0
  var stand = 0.0
  var gave = ""
  for r in rw:
    if r.kind == "Experience": xp = int(r.value)
    elif r.kind == "TraderStanding": stand = r.value
    elif r.kind == "Item": gave = r.items
  if xp != 1500 or gave.len == 0:
    inc fails
    out1.add "FAIL rewards xp=" & $xp & " items=" & gave & "\n"
  else:
    out1.add "ok    rewards read, including a value written as a string\n"
  if traderOf(Tpl) != "T1" or questName(Tpl) != "Debut":
    inc fails
    out1.add "FAIL template header\n"
  else:
    out1.add "ok    the template names its trader and its quest\n"

  if fails == 0:
    out1.add "questcond: all checks passed\n"
  else:
    out1.add "questcond: " & $fails & " check(s) FAILED\n"
  result = out1
