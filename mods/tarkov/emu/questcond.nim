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
## - `daytime`, `weaponCaliber`, the weapon-mod lists and the two equipment
##   lists inside a `Kills` condition. When one of those restricts anything the
##   kill is not credited from a raid's victim list, because crediting a kill
##   whose qualifier could not be checked hands out progress that was not
##   earned — but the refusal now **names the clause** it could not check, so a
##   player whose quest will not finish is told which one stopped it. The
##   client's own counter still counts — see `mergeCounters`.
##
##   `distance` **is** checked: the reference dump's `Victim` carries a
##   `Distance` per kill and this used to refuse it anyway. So did 191 of the
##   283 `Kills` sub-conditions in a real database, which carry `distance` and
##   `daytime` keys with neutral values (`>= 0`, `0..0`) and restrict nothing.
##   `killCredit` carries the counts and the reasoning.
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

proc listHasAny(node: JsonRef; wanted: seq[string]): bool =
  ## Whether an array of strings contains ANY of several spellings of the same
  ## thing. Used for `Location`, whose target may be a database key
  ## (`bigmap`), a `base.Id` (`Woods`), a `base._Id` or a `base.Name` -- see
  ## `emu/raid.locationAliases` for the measured distribution. An exact
  ## compare against one canonical spelling refused 233 of the 301 `Location`
  ## targets in the live database.
  if not node.found:
    return false
  let elems = each(node)
  for e in elems:
    let got = e.asText("")
    for w in wanted:
      if got == w:
        return true
  result = false

proc sideMatches(target, side: string): bool =
  case target
  of "", "Any": true
  of "AnyPmc": side == "Usec" or side == "Bear"
  of "Savage": side == "Savage"
  else: target == side

proc isMongoId(s: string): bool =
  ## A 24-character hex string. A quest's `weapon` list is written in template
  ## ids, and this is how a value that *is* one is told from a display name --
  ## which matters because `Victim.Weapon` is typed `String` in the reference
  ## and nothing establishes which of the two the client puts there.
  if s.len != 24:
    return false
  for ch in s:
    let hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or
              (ch >= 'A' and ch <= 'F')
    if not hex:
      return false
  result = true

proc restrictsDistance(node: JsonRef): bool =
  ## Whether a `distance` qualifier restricts anything at all.
  ##
  ## `{"compareMethod": ">=", "value": 0}` is *every kill at every range* --
  ## the database's way of writing "no restriction", and it is what 243 of the
  ## 283 `Kills` sub-conditions in a real `templates.quests` carry. Reading the
  ## mere presence of the key as a restriction is what used to refuse two
  ## thirds of every kill condition in the game:
  ##
  ##     distance values, build/db/db.json, 283 Kills sub-conditions
  ##       (">=", 0)  243     absent  27     everything else  13
  if not node.found or node.isNull:
    return false
  let how = node.field("compareMethod").asText(">=")
  let want = numberAt(node, "value", 0.0)
  if want <= 0.0 and (how == ">=" or how == ">"):
    return false
  result = true

proc distanceMet(how: string; want, got: float): bool =
  case how
  of ">=": got >= want
  of ">": got > want
  of "<=": got <= want
  of "<": got < want
  of "=", "==": got == want
  of "!=": got != want
  else:
    # An unknown comparison is not a comparison. The caller turns this into a
    # refusal rather than a credit, for the same reason as everything else here.
    false

proc restrictsDaytime(node: JsonRef): bool =
  ## `{"from": 0, "to": 0}` is the whole day -- 244 of 283 in a real database.
  if not node.found or node.isNull:
    return false
  let a = numberAt(node, "from", 0.0)
  let b = numberAt(node, "to", 0.0)
  result = a != b

proc noteRefusal(refused: var seq[string]; what: string) =
  for r in refused:
    if r == what:
      return
  refused.add what

# ---------------------------------------------------------------------------
# The raid's clock
# ---------------------------------------------------------------------------
#
# `daytime` used to be refused on the grounds that "`Victim.Time` is a `String`
# and nothing establishes which clock it is on". The distrust was right and the
# conclusion was not, because `Victim.Time` is the wrong input and never was
# the only one. `WeatherHelper.IsNightTime(DateTimeEnum timeVariant, String
# mapLocation)` in the reference dump is proof of method: the game decides
# night from **what the client selected and which map**, never from a victim's
# timestamp.
#
# So this takes a raid clock from the caller and answers a window question with
# it. What the clock is built from -- and the arithmetic that turns
# `RaidSettings` into one -- is `emu/raid.raidClock`; this module reads no
# database and does not gain one here.
#
# The question it answers is deliberately narrow. A `daytime` window is checked
# per **kill** in the game and this server has no per-kill clock, so the only
# answer it can give is about the whole raid: does the entire interval the raid
# could have spanned lie inside the window, entirely outside it, or across its
# edge. Inside credits, outside is a verified no, and across the edge is
# refused by name -- which is the same three-way answer `Location` gets, and
# for the same reason.

type
  RaidClock* = object
    ## What the raid configuration establishes about the in-game clock.
    ##
    ## `startHour` is the hour the raid begins at, 0..24. `spanHours` is how
    ## far the in-game clock can move before the raid must be over -- the map's
    ## `EscapeTimeLimit` multiplied by the client's `TimeFlowType`. `known` is
    ## false when the configuration did not establish both, and a clock that is
    ## not known decides nothing.
    known*: bool
    startHour*: float
    spanHours*: float

  DaytimeVerdict* = enum
    dtInside     ## every moment of the raid is inside the window
    dtOutside    ## no moment of it is
    dtUndecided  ## the raid crosses the window's edge

proc unknownClock*(): RaidClock =
  ## The clock a raid this server was told nothing about has.
  RaidClock(known: false, startHour: 0.0, spanHours: 0.0)

proc wrap24(v: float): float =
  result = v
  while result < 0.0:
    result = result + 24.0
  while result >= 24.0:
    result = result - 24.0

proc daytimeVerdict*(c: RaidClock; fromHour, toHour: float): DaytimeVerdict =
  ## Where a raid sits against one `{from, to}` window.
  ##
  ## Every window in a real `templates.quests` wraps midnight -- 22->10, 21->4,
  ## 21->5, 21->6, 22->7 -- so the arithmetic is done relative to the window's
  ## own start rather than to midnight, which makes wrapping cost nothing.
  ## `from == to` never reaches here: `restrictsDaytime` reads it as "the whole
  ## day", which is what 244 of the 283 `Kills` sub-conditions carry.
  if not c.known:
    return dtUndecided
  if c.spanHours < 0.0 or c.spanHours >= 24.0:
    # A span of a whole day or more is inside every window and outside every
    # window at once. Nothing to say.
    return dtUndecided
  var width = toHour - fromHour
  if width <= 0.0:
    width = width + 24.0
  if width <= 0.0 or width >= 24.0:
    return dtUndecided
  let offset = wrap24(c.startHour - fromHour)
  if offset + c.spanHours <= width:
    return dtInside
  if offset >= width and offset + c.spanHours <= 24.0:
    return dtOutside
  result = dtUndecided

proc killCredit*(cond, victimsJson, location, exitStatus: string;
                 refused: var seq[string]; clock: RaidClock;
                 locationAliases: seq[string] = @[]): int =
  ## How many of a raid's victims this `CounterCreator` should count.
  ##
  ## `locationAliases` is every spelling of the raid's map (see
  ## `emu/raid.locationAliases`). `location` alone is not enough: a quest's
  ## `Location` target is usually the client's `base.Id` and this server's
  ## `location` is the database key, and on 13 of 19 maps those differ. When
  ## the list is empty `location` is used on its own, which is what every
  ## selfcheck below passes and what a caller with no index can do.
  ##
  ## `refused` comes back naming every qualifier that stopped the count. It is
  ## empty on a clean credit and on a counter that is not about kills at all;
  ## when it is not empty the count is **zero**, not a guess, because crediting
  ## a kill whose qualifier could not be checked hands out progress that was not
  ## earned. The caller turns the names into a sentence the player can read --
  ## a quest that will not finish should say which clause stopped it.
  ##
  ## ## What the raid report actually carries
  ##
  ## The refusal used to reach much further than the data justified. The
  ## reference dump's `Victim` (`SPTarkov.Server.Core.Models.Eft.Common.Tables`)
  ## is:
  ##
  ##     Distance, Level, PrestigeLevel, ProfileId, AccountId, BodyPart,
  ##     ColliderType, Location, Name, Role, Side, Time, Weapon
  ##
  ## so **`distance` is in the report**, per kill, as a number -- and it was
  ## being refused. Worse, the old check refused on the *presence* of the
  ## `distance` and `daytime` keys, and a real `templates.quests` writes both on
  ## almost every kill condition with neutral values (`>= 0`, `0..0`): 191 of
  ## the 283 `Kills` sub-conditions in `build/db/db.json` carry no real
  ## qualifier at all and every one of them was refused.
  ##
  ## ## What is still refused, and why
  ##
  ## - **`daytime`**, when and only when `clock` does not decide it. The old
  ##   refusal here read `Victim.Time` and distrusted it, correctly -- a wall
  ##   clock read as a raid clock over-credits about half the time. What it got
  ##   wrong is that `Victim.Time` was ever the input. `clock` is the raid's own
  ##   configuration, and `daytimeVerdict` above answers only when the whole
  ##   raid is on one side of the window's edge. A raid this server was told
  ##   nothing about still lands here, by name.
  ## - **`weapon`**, when the report does not spell it as a template id. The
  ##   condition's list is template ids; `Victim.Weapon` is a `String`. If the
  ##   client puts an id there this credits it; if it puts a display name there
  ##   nothing here can map one to the other -- that needs `templates.items` and
  ##   the locale table, and this module deliberately reads no database.
  ## - **`weaponCaliber`** -- the report carries no caliber, and deriving one
  ##   from a weapon id needs the item table this module does not read.
  ## - **`weaponModsInclusive` / `weaponModsExclusive`** -- the report carries
  ##   nothing about what was bolted to the gun.
  ## - **`equipmentInclusive` / `equipmentExclusive`** -- what the *player* was
  ##   wearing at the moment of the kill is not in the report in any form.
  ## - **`enemyEquipmentInclusive` / `enemyEquipmentExclusive` /
  ##   `enemyHealthEffects`** -- `Victim` carries no equipment and no effects.
  ##
  ## None of these is a dead end for the player: this whole function is the
  ## *fallback* for a counter the client did not report. `mergeCounters` takes
  ## the client's own `TaskConditionCounters` first, and the client can check
  ## every one of the above because it was there.
  refused = @[]
  result = 0
  let subs = subConditions(cond)
  if subs.len == 0:
    return 0

  var wantsKills = false
  var side = ""
  var roles = notFound()
  var bodyParts = notFound()
  var weapons = notFound()
  var distHow = ""
  var distWant = 0.0
  var wantsDistance = false

  for s in subs:
    let k = condKind(s)
    let sp = condProps(s)
    let sj = whole(sp)
    case k
    of "Kills":
      wantsKills = true
      side = sj.field("target").asText("")
      if sj.field("savageRole").count > 0:
        roles = sj.field("savageRole")
      if sj.field("bodyPart").count > 0:
        bodyParts = sj.field("bodyPart")
      # Checked here, against the victim record's own members.
      let dist = sj.field("distance")
      if restrictsDistance(dist):
        wantsDistance = true
        distHow = dist.field("compareMethod").asText(">=")
        distWant = numberAt(dist, "value", 0.0)
      if sj.field("weapon").count > 0:
        weapons = sj.field("weapon")
      # Checked against the raid's own configuration rather than against any
      # victim's timestamp -- see `daytimeVerdict`.
      let day = sj.field("daytime")
      if restrictsDaytime(day):
        let verdict = daytimeVerdict(clock, numberAt(day, "from", 0.0),
                                     numberAt(day, "to", 0.0))
        if verdict == dtOutside:
          # The raid was at the wrong time of day, start to finish. Not
          # unverifiable -- verified, and no, exactly like `Location` below.
          refused = @[]
          return 0
        if verdict == dtUndecided:
          noteRefusal(refused, "daytime")
      # Not checked here. Each one names itself, so the player is told which
      # clause stopped the quest rather than being told nothing.
      if sj.field("weaponModsInclusive").count > 0 or
         sj.field("weaponModsExclusive").count > 0:
        noteRefusal(refused, "weapon mods")
      if sj.field("weaponCaliber").count > 0:
        noteRefusal(refused, "weaponCaliber")
      if sj.field("equipmentInclusive").count > 0 or
         sj.field("equipmentExclusive").count > 0:
        noteRefusal(refused, "your own equipment")
      if sj.field("enemyEquipmentInclusive").count > 0 or
         sj.field("enemyEquipmentExclusive").count > 0:
        noteRefusal(refused, "the target's equipment")
      if sj.field("enemyHealthEffects").count > 0:
        noteRefusal(refused, "the target's health effects")
    of "Location":
      let target = sj.field("target")
      var spellings: seq[string] = @[]
      for a in locationAliases:
        spellings.add a
      if spellings.len == 0:
        spellings.add location
      if target.count > 0 and not listHasAny(target, spellings):
        # The raid was somewhere else. Not unverifiable -- verified, and no.
        refused = @[]
        return 0
    of "ExitStatus":
      let status = sj.field("status")
      if status.count > 0 and not listHas(status, exitStatus):
        refused = @[]
        return 0
    else:
      # A sub-condition with no evaluator makes the whole counter unverifiable
      # for the same reason a qualifier does.
      noteRefusal(refused, "a " & k & " sub-condition")

  if not wantsKills:
    # Not a kill counter at all. Nothing here has an opinion about it, and
    # reporting its unknown sub-conditions as refused kills would put a
    # sentence about kills in front of a player doing a hand-in.
    refused = @[]
    return 0
  if refused.len > 0:
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
    if wantsDistance:
      let dnode = v.field("Distance")
      if not dnode.found or dnode.isNull or dnode.isText:
        # The condition restricts range and this victim record does not carry
        # one. The whole counter is refused rather than this one victim: a
        # partial count is a number nobody can act on.
        noteRefusal(refused, "distance")
        return 0
      if not distanceMet(distHow, distWant, dnode.asFloat(0.0)):
        continue
    if weapons.found:
      let w = v.field("Weapon").asText("")
      if not isMongoId(w):
        noteRefusal(refused, "weapon")
        return 0
      if not listHas(weapons, w):
        continue
    inc result

proc killCredit*(cond, victimsJson, location, exitStatus: string;
                 refused: var seq[string]): int =
  ## The same, for a caller that knows nothing about the raid's clock. Every
  ## `daytime` window is then undecided and refused by name, which is what this
  ## function did for all of them before there was a clock to ask.
  result = killCredit(cond, victimsJson, location, exitStatus, refused,
                      unknownClock())

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
    {"Side":"Savage","Role":"assault","BodyPart":"Head","Distance":142.5,
     "Weapon":"5cadc190ae921500103bb3b6","Time":"22:14:03"},
    {"Side":"Savage","Role":"assault","BodyPart":"Chest","Distance":11.25,
     "Weapon":"5448bd6b4bdc2dfc2f8b4569","Time":"22:15:40"},
    {"Side":"Usec","Role":"pmcUSEC","BodyPart":"Head","Distance":63.0,
     "Weapon":"5cadc190ae921500103bb3b6","Time":"03:02:11"}]}}}"""
  var why1: seq[string] = @[]
  if killCredit(Counter5, Victims, "bigmap", "Survived", why1) != 2:
    inc fails
    out1.add "FAIL kill credit on the right map\n"
  else:
    out1.add "ok    two scav kills on the named map are credited\n"
  if killCredit(Counter5, Victims, "factory4_day", "Survived", why1) != 0:
    inc fails
    out1.add "FAIL kill credit on the wrong map\n"
  else:
    out1.add "ok    the same kills on another map are not\n"

  # The MEASURED spelling problem, both ways round. In the live db.json, 233
  # of the 301 `Location` targets under `templates.quests` are the client's
  # `base.Id` (`Woods` 39, `Shoreline` 46, `RezervBase` 28, `TarkovStreets`
  # 32, `Interchange` 23, `Lighthouse` 26, `Sandbox`/`Sandbox_high` 29) and
  # only 68 are database keys. `raidMapFor` canonicalises to the database key,
  # so an exact compare against `location` alone refuses all 233.
  #
  # The falsifying input is the SECOND case, not the first: passing only the
  # canonical spelling MUST still refuse, or this check could not fail.
  const CounterWoods = """{"conditionType":"CounterCreator","id":"cw","value":5,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage"},
                             {"conditionType":"Location","target":["Woods"]}]}}"""
  if killCredit(CounterWoods, Victims, "bigmap", "Survived", why1,
                unknownClock(), @["bigmap", "Woods", "Woods"]) != 2:
    inc fails
    out1.add "FAIL an Id-spelled Location target with the aliases present\n"
  else:
    out1.add "ok    a Location target spelled `Woods` credits a raid the " &
             "server canonicalised to `bigmap`\n"
  if killCredit(CounterWoods, Victims, "bigmap", "Survived", why1) != 0:
    inc fails
    out1.add "FAIL an Id-spelled target matched with no aliases at all\n"
  else:
    out1.add "ok    and with no alias list it still refuses, so the check " &
             "above can fail\n"
  if killCredit(CounterWoods, Victims, "shoreline", "Survived", why1,
                unknownClock(), @["shoreline", "Shoreline"]) != 0:
    inc fails
    out1.add "FAIL another map's aliases credited a Woods condition\n"
  else:
    out1.add "ok    a different map's aliases do not credit it\n"

  # The shape a real `templates.quests` writes on almost every kill condition:
  # both keys present, both neutral. This used to refuse every one of them.
  const Neutral = """{"conditionType":"CounterCreator","id":"c8","value":1,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage",
      "distance":{"compareMethod":">=","value":0},
      "daytime":{"from":0,"to":0},"weapon":[],"weaponModsInclusive":[],
      "enemyEquipmentInclusive":[]}]}}"""
  if killCredit(Neutral, Victims, "bigmap", "Survived", why1) != 2 or
     why1.len != 0:
    inc fails
    out1.add "FAIL neutral distance/daytime keys refused the count\n"
  else:
    out1.add "ok    a neutral distance and daytime restrict nothing\n"

  # And a real one is evaluated against `Victim.Distance` rather than refused.
  const Far = """{"conditionType":"CounterCreator","id":"c7","value":1,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage",
      "distance":{"compareMethod":">=","value":100}}]}}"""
  if killCredit(Far, Victims, "bigmap", "Survived", why1) != 1 or why1.len != 0:
    inc fails
    out1.add "FAIL long-range kill credit\n"
  else:
    out1.add "ok    only the 142 m kill counts for a >= 100 m condition\n"
  const Near = """{"conditionType":"CounterCreator","id":"c6","value":1,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage",
      "distance":{"compareMethod":"<=","value":25}}]}}"""
  if killCredit(Near, Victims, "bigmap", "Survived", why1) != 1:
    inc fails
    out1.add "FAIL short-range kill credit\n"
  else:
    out1.add "ok    and only the 11 m kill for a <= 25 m one\n"

  # A distance condition against a report that carries no distance is refused,
  # by name -- not credited and not silently zero.
  const NoDist = """{"Stats":{"Eft":{"Victims":[
    {"Side":"Savage","Role":"assault"}]}}}"""
  if killCredit(Far, NoDist, "bigmap", "Survived", why1) != 0 or
     why1.len != 1 or why1[0] != "distance":
    inc fails
    out1.add "FAIL distance with no Distance in the report\n"
  else:
    out1.add "ok    a range condition over a report with no range says so\n"

  # A weapon list is checked when the report spells the weapon as a template
  # id, and refused by name when it does not.
  const Sniped = """{"conditionType":"CounterCreator","id":"c9","value":1,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage",
                             "weapon":["5cadc190ae921500103bb3b6"]}]}}"""
  if killCredit(Sniped, Victims, "bigmap", "Survived", why1) != 1 or
     why1.len != 0:
    inc fails
    out1.add "FAIL weapon credited by template id\n"
  else:
    out1.add "ok    a weapon list matches the victim's weapon by template id\n"
  const NamedGun = """{"Stats":{"Eft":{"Victims":[
    {"Side":"Savage","Role":"assault","Weapon":"Mosin bolt-action rifle"}]}}}"""
  if killCredit(Sniped, NamedGun, "bigmap", "Survived", why1) != 0 or
     why1.len != 1 or why1[0] != "weapon":
    inc fails
    out1.add "FAIL weapon refused when the report gives a display name\n"
  else:
    out1.add "ok    and refuses by name when the report gives a display name\n"

  # The qualifiers that stay refused, each naming itself.
  const AtNight = """{"conditionType":"CounterCreator","id":"c5","value":1,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage",
      "daytime":{"from":22,"to":10}}]}}"""
  if killCredit(AtNight, Victims, "bigmap", "Survived", why1) != 0 or
     why1.len != 1 or why1[0] != "daytime":
    inc fails
    out1.add "FAIL daytime refusal\n"
  else:
    out1.add "ok    a night-only kill condition refuses and names `daytime`\n"

  # And the three answers a clock can give it. The window is 22->10, twelve
  # hours wide and wrapping midnight, which is the shape every one of the
  # twelve real ones has.
  let inside = RaidClock(known: true, startHour: 23.0, spanHours: 5.0)
  if killCredit(AtNight, Victims, "bigmap", "Survived", why1, inside) != 2 or
     why1.len != 0:
    inc fails
    out1.add "FAIL a raid wholly inside the window is credited\n"
  else:
    out1.add "ok    a raid whose whole span is inside 22->10 is credited\n"

  let outside = RaidClock(known: true, startHour: 12.0, spanHours: 5.0)
  if killCredit(AtNight, Victims, "bigmap", "Survived", why1, outside) != 0 or
     why1.len != 0:
    inc fails
    out1.add "FAIL a raid wholly outside the window is a verified no\n"
  else:
    out1.add "ok    and one wholly outside it is refused without naming a " &
             "qualifier\n"

  let straddling = RaidClock(known: true, startHour: 9.0, spanHours: 5.0)
  if killCredit(AtNight, Victims, "bigmap", "Survived", why1, straddling) != 0 or
     why1.len != 1 or why1[0] != "daytime":
    inc fails
    out1.add "FAIL a raid across the window's edge names `daytime`\n"
  else:
    out1.add "ok    and one across the window's edge still names `daytime`\n"

  # The wrap is not an accident of the numbers above: 23 + 5 runs to 04:00 the
  # next day, and 09:00 + 5 runs to 14:00 which is outside a window that ends
  # at 10. A window that does *not* wrap has to work too, and this is the only
  # place one exists.
  const ByDay = """{"conditionType":"CounterCreator","id":"c5d","value":1,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage",
      "daytime":{"from":8,"to":16}}]}}"""
  let midday = RaidClock(known: true, startHour: 9.0, spanHours: 5.0)
  if killCredit(ByDay, Victims, "bigmap", "Survived", why1, midday) != 2 or
     why1.len != 0:
    inc fails
    out1.add "FAIL a window that does not wrap midnight\n"
  else:
    out1.add "ok    a daytime window that does not wrap midnight works too\n"
  const Kitted = """{"conditionType":"CounterCreator","id":"c4","value":1,
    "counter":{"conditions":[{"conditionType":"Kills","target":"Savage",
      "weaponCaliber":["7.62x39"],
      "enemyEquipmentInclusive":[["5df8a4d786f77412672a1e3b"]]}]}}"""
  if killCredit(Kitted, Victims, "bigmap", "Survived", why1) != 0 or
     why1.len != 2:
    inc fails
    out1.add "FAIL caliber/equipment refusal " & $why1.len & "\n"
  else:
    out1.add "ok    caliber and the target's kit refuse, and both are named\n"

  # A counter that is not about kills reports nothing, however strange its
  # sub-conditions -- a hand-in must not produce a sentence about kills.
  const HandIn = """{"conditionType":"CounterCreator","id":"c3","value":1,
    "counter":{"conditions":[{"conditionType":"VisitPlace","target":"x"}]}}"""
  if killCredit(HandIn, Victims, "bigmap", "Survived", why1) != 0 or
     why1.len != 0:
    inc fails
    out1.add "FAIL a non-kill counter reported a kill refusal\n"
  else:
    out1.add "ok    a counter that is not about kills refuses nothing\n"

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
