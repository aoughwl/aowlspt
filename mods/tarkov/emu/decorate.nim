## The hideout's own wardrobe: floors, walls, ceilings, shooting-range targets,
## mannequin poses, and the shooting range's score.
##
## Three operations, one screen, and all three were on the "real content gaps"
## list as unserved. **None of them needed anything imported.** `docs/BACKLOG.md`
## says of that list that "its reasons are the part to distrust", and this file
## is the fifth, sixth and seventh rows to fall to reading the database instead
## of the sentence about it.
##
## ## What is actually in the database
##
## `hideout.customisation` is imported and populated. It is an object of two
## arrays:
##
## | | count | what an entry carries |
## |---|---:|---|
## | `globals` | 38 | `id`, `type`, `systemName`, `itemId`, `isEnabled`, `conditions` |
## | `slots` | 47 | the same minus `itemId`, plus `slotId` and `areaTypeId` |
##
## The 38 globals are 11 floors, 10 walls, 8 ceilings and 9 shooting-range
## targets. The 47 slots are 29 poster slots and 18 statuette slots — *places to
## put a thing*, not things — and they carry no `itemId`, which is why applying
## one is refused below rather than guessed at.
##
## `templates.customization` — the same 728-entry table `emu/customise` already
## validates clothing against — carries the other half. Its node tree has
## `Floor`, `Wall`, `Ceiling`, `ShootingRangeMark` and `MannequinPose` nodes
## alongside the `Head`/`Body`/`Voice` ones, and every one of the 38 globals'
## `itemId` resolves to an entry under one of the first four.
##
## ## The join, and why the profile's key is derived rather than written down
##
## A profile's `Hideout.Customization` is `Dictionary<String, MongoId>` in the
## reference DTO — a map with no declared keys, so nothing in the reference says
## what to call the floor. What the database says is much better than a guess:
##
##     offer.itemId -> templates.customization[itemId]._parent -> ._name
##
## and that node name is `Floor`, `Wall`, `Ceiling` or `ShootingRangeMark`. It
## is also, in all 38 cases, exactly the offer's own `type` with its first
## letter capitalised — checked here on every apply, and checked over the whole
## real table at load by `selfCheckDecorate`. So the key written into the
## profile is the table's own word for what the thing is, and a table that
## renames its nodes is a table this still reads correctly. Nothing is spelled
## out inline.
##
## The `type`/branch cross-check is not decoration. It is the one thing that
## catches an offer pointing at the wrong item — a `wall` whose `itemId` is a
## ceiling would otherwise write a ceiling into the wall's slot, and the symptom
## is a hideout that renders wrongly with nothing in any log.
##
## ## What is refused, and what each refusal costs the player
##
## - **An offer id the table does not have** — refused by id. The alternative is
##   writing an unknown id into a field the client renders.
## - **An offer that is one of the 47 `slots`** — refused by name, saying that
##   this server does not put items into hideout slots. A slot entry has no
##   `itemId`: there is nothing to write, and inventing one would put an
##   arbitrary poster on the wall. Consequence: poster and statuette slots stay
##   empty here.
## - **A condition that is not met** — refused with the condition named and the
##   shortfall stated. The four kinds this database uses are `Block` (18 of the
##   38 carry one), `Quest` (12), `Level` (3) and `HideoutArea` (1).
##   `Block` is the table saying the entry is not obtainable; `Quest` and
##   `Level` go through `emu/questcond`'s evaluator, which already speaks this
##   exact flat condition shape; `HideoutArea` is read off `Hideout.Areas`.
## - **A condition kind this server does not know** — refused, not waved
##   through. A gate nobody can evaluate is a gate, and the failure mode of the
##   permissive reading is a decoration handed out for free, which is the shape
##   of the hideout bug `emu/hideout` documents at length.
## - **No `hideout.customisation` and no `templates.customization`** — refused
##   naming the missing table. A server started without them cannot tell whether
##   any of this is real.
##
## ## Mannequin poses
##
## `HideoutCustomizationSetMannequinPoseRequest` is `{Poses: {slotId: poseId}}`
## and the profile's `Hideout.MannequinPoses` is the same map. Each *value* is
## checked against `templates.customization` through `emu/customise`'s own
## `entryAllowed` — it exists, it is not a category, this side may wear it, this
## edition has it — and then against the `MannequinPose` node, of which this
## database has ten.
##
## **Each *key* is the client's word and cannot be checked here.** It names a
## mannequin in the player's hideout, and there is no table of mannequins in
## this database: `hideout.customisation.slots` has poster and statuette slots
## and no mannequin slot at all. So the key is stored as sent. The consequence
## of a wrong one is a pose recorded under a slot the client never reads, which
## is a mannequin that does not change — visible, harmless, and not something
## this server can distinguish from a correct one.
##
## Whether the player has *unlocked* a pose is not checked, for exactly the
## reason `emu/customise` gives about clothing: unlocks live in
## `CustomisationUnlocks`, filled by `BuyCustomisation`, and `trader/<id>/
## suits.json` is not in the imported database. Five of the ten poses carry
## `AvailableAsDefault: false` and are wearable here. That is more permissive
## than the game and it is a stated gap, not an oversight.
##
## ## The shooting range's score
##
## `RecordShootingRangePoints` is `{Points: n}` and it goes into
## `Stats.Eft.OverallCounters.Items` as `{Key: ["ShootingRangePoints"], Value:
## n}`.
##
## **The number is entirely the client's word and this file says so rather than
## dressing it up.** There is no shooting range in this process: no target, no
## bullet and no hit. What *can* be checked is that the player has a shooting
## range at all — area 12, which is the areaType every `shootingRangeMark`
## condition in `hideout.customisation` gates on — and that the number is not
## negative. Both are checked. Nothing else about it is checkable and nothing
## else is claimed.
##
## The value is stored **as sent**, not as a running maximum. That is a choice
## and here is the argument: nothing in this database reads the counter — the
## string `ShootingRangePoints` appears nowhere in `db.json`, in no quest
## condition and in no achievement — so its only consumer is the client's own
## board, and a server quietly showing a higher number than the client just
## displayed would be inventing a score. The counter key spelling is the
## well-known client one and is *(unverified)*: the reference dump carries the
## request DTO and not the key.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import profile
import inventory
import customise
import questcond
import production

type
  DecorAction* = enum
    ## `HideoutEventActions` members, in the wire spelling. The reference dump
    ## carries the enum's member names and not their values, so these are the
    ## PascalCase forms of `HIDEOUT_CUSTOMIZATION_APPLY_COMMAND`,
    ## `HIDEOUT_CUSTOMIZATION_SET_MANNEQUIN_POSE` and
    ## `HIDEOUT_RECORD_SHOOTING_RANGE_POINTS` — the same convention
    ## `emu/personal` and `emu/gym` state for their own actions.
    daNone
    daApply
    daPose
    daPoints

  DecorPlan* = object
    ## One resolved `HideoutCustomizationApplyCommand`: which member of
    ## `Hideout.Customization` to write, and what to write into it. Resolved
    ## whole before anything is written, like every other plan here.
    ok*: bool
    problem*: string
    slot*: string        ## `Floor`, `Wall`, `Ceiling`, `ShootingRangeMark`
    itemId*: string

  PosePlan* = object
    ## One resolved `HideoutCustomizationSetMannequinPose`. Parallel arrays
    ## rather than a table, for the same reason `emu/customise` uses them: the
    ## caller writes them without needing to know what any of them mean, and a
    ## batch with one bad entry writes none of them.
    ok*: bool
    problem*: string
    slots*: seq[string]
    poses*: seq[string]

const
  ShootingRangeArea* = 12
    ## The shooting range. Not a spelled-out constant taken on faith: every
    ## `shootingRangeMark` entry in `hideout.customisation.globals` carries a
    ## `HideoutArea` condition on areaType 12, which is the database naming it.

  PointsCounterKey* = "ShootingRangePoints"
    ## *(unverified)* — the key the client reads its board from. The reference
    ## dump has `RecordShootingRangePoints` with a `Points` member and no key
    ## spelling anywhere, and this string appears nowhere in the database
    ## either. A wrong spelling here is a board that reads zero, not a wrong
    ## number.

proc decorateAction*(name: string): DecorAction =
  case name
  of "HideoutCustomizationApplyCommand": daApply
  of "HideoutCustomizationSetMannequinPose": daPose
  of "HideoutRecordShootingRangePoints": daPoints
  else: daNone

proc hideoutCustomisationTable*(): string =
  ## `hideout.customisation` as raw JSON, or an empty pair of arrays.
  ##
  ## The empty *pair* rather than "" or "[]", because this is also what the
  ## `/client/hideout/customization/offer/list` route sends and the response is
  ## an object with two lists in it. A server with no hideout customisation
  ## table answers "no offers", which is a hideout that cannot be redecorated
  ## rather than a menu that will not open. The planning below tells the two
  ## apart by looking for the arrays, not by looking at this string.
  ## An object carrying neither array is normalised to the empty pair as well,
  ## for the reason `emu/customise`'s `customisationTable` sets out at length:
  ## a table with nothing in it is the situation of not having a table, and a
  ## check or a route that tells the two apart is one that fails on a database
  ## whose only fault is being empty. The planning below refuses either the same
  ## way, and the route sends a shape the client can read either way.
  let v = dbRead("hideout.customisation")
  if v.ok and v.raw.len > 0:
    let j = whole(v.raw)
    if j.field("globals").found or j.field("slots").found:
      return v.raw
  result = "{\"globals\":[],\"slots\":[]}"

# ---------------------------------------------------------------------------
# The pure half: one offer, one profile's worth of text, no database
# ---------------------------------------------------------------------------

proc refuseDecor(problem: string): DecorPlan =
  DecorPlan(ok: false, problem: problem, slot: "", itemId: "")

proc refusePose(problem: string): PosePlan =
  PosePlan(ok: false, problem: problem, slots: @[], poses: @[])

proc lowerFirst(s: string): string =
  ## `Floor` -> `floor`. The one transformation between the table's two names
  ## for the same thing, written once.
  if s.len == 0:
    return ""
  result = toLowerAscii(s[0 .. 0]) & s[1 .. s.len - 1]

proc offerIn(tableJson, list, offerId: string): string =
  ## The entry with this id in `globals` or `slots`, or "" when there is none.
  let node = field(tableJson, list)
  if not node.found or not isArray(node):
    return ""
  let entries = each(node)
  for e in entries:
    if e.field("id").asText("") == offerId:
      return raw(e)
  result = ""

proc offerName(entryJson: string): string =
  ## What to call an entry in a refusal. `systemName` is what the table calls
  ## it and the locale is what the player sees; the id is the fallback, because
  ## a refusal naming nothing is a refusal nobody can act on.
  let name = field(entryJson, "systemName").asText("")
  if name.len > 0:
    return name
  result = field(entryJson, "id").asText("that entry")

proc conditionMet*(profileText, condJson: string; reason: var string): bool =
  ## One condition off a customisation entry. `reason` is filled in on a refusal
  ## only, and names the condition and the shortfall.
  ##
  ## Four kinds and no fifth. An unrecognised kind is a **refusal**: a condition
  ## nobody evaluated is not a condition that passed, and the cost of the
  ## permissive reading is a locked decoration handed out for nothing.
  reason = ""
  let kind = condKind(condJson)
  case kind
  of "Block":
    # Eighteen of the 38 globals carry one. It is the table saying the entry is
    # not obtainable — there is no value to compare and nothing a player can do
    # about it, so there is nothing to evaluate either.
    reason = "this database's customisation table blocks it outright"
    return false
  of "HideoutArea":
    let props = whole(condProps(condJson))
    let areaType = props.field("areaType").asInt(-1)
    let want = props.field("value").asFloat(0.0)
    let op = props.field("compareMethod").asText(">=")
    let have = float(areaLevel(field(profileText, "Hideout.Areas").raw(),
                               areaType))
    if compareOk(op, have, want):
      return true
    reason = "hideout area " & $areaType & " is at level " & $int(have) &
             " and this needs " & op & " " & $int(want)
    return false
  of "Level", "Quest":
    # The flat spelling `emu/questcond` already reads: `condKind` takes
    # `conditionType` and `condProps` returns the condition itself when there is
    # no `_props`, which is exactly the shape of these. Passed the empty quest
    # id because neither kind uses it — `Level` reads `Info.Level` and `Quest`
    # reads the status of the quest it *names*, not of the one asking.
    return evaluate(profileText, "", condJson, reason)
  of "":
    reason = "one of its conditions says what kind of condition it is nowhere"
    return false
  else:
    reason = "this server does not know how to check a \"" & kind &
             "\" condition, so it cannot say whether you have met it"
    return false

proc conditionsMet*(profileText, entryJson: string; reason: var string): bool =
  reason = ""
  let conds = field(entryJson, "conditions")
  if not conds.found or not isArray(conds):
    return true
  let list = each(conds)
  for c in list:
    if not conditionMet(profileText, raw(c), reason):
      return false
  result = true

proc planDecoration*(hideoutJson, customisationJson, profileText,
                     offerId: string): DecorPlan =
  ## The one write a `HideoutCustomizationApplyCommand` asks for, or the first
  ## refusal. No database and no profile object in it, so `emu/selfchecks` can
  ## pin the whole of it at load against literal tables.
  if offerId.len == 0:
    return refuseDecor("that request names no customisation offer")

  # Absent, and present-but-empty, are the same situation and get the same
  # answer. Telling them apart would answer "there is no offer <id>" to a
  # database that has no offers at all, which sends whoever reads it looking
  # for a typo in the id rather than for the missing table.
  let globals = field(hideoutJson, "globals")
  let slots = field(hideoutJson, "slots")
  if (not globals.found or count(globals) == 0) and
     (not slots.found or count(slots) == 0):
    return refuseDecor("this server's database has no hideout customisation " &
                       "table, so it cannot tell whether that offer is real; " &
                       "nothing was changed")

  let entry = offerIn(hideoutJson, "globals", offerId)
  if entry.len == 0:
    let slotEntry = offerIn(hideoutJson, "slots", offerId)
    if slotEntry.len > 0:
      # A slot is a place, not a thing: 47 of them and not one carries an
      # `itemId`. Refused by name rather than answered with something, because
      # the only way to answer is to choose a poster, and choosing one is
      # inventing content.
      return refuseDecor("\"" & offerName(slotEntry) & "\" is a hideout " &
                         "slot rather than a decoration, and this server " &
                         "does not put items into hideout slots; the slot " &
                         "was left empty")
    return refuseDecor("there is no customisation offer " & offerId &
                       " in this server's database")

  if not field(entry, "isEnabled").asBool(true):
    return refuseDecor("\"" & offerName(entry) &
                       "\" is switched off in this server's database")

  var reason = ""
  if not conditionsMet(profileText, entry, reason):
    return refuseDecor("you cannot apply \"" & offerName(entry) & "\": " &
                       reason)

  let itemId = field(entry, "itemId").asText("")
  if itemId.len == 0:
    return refuseDecor("\"" & offerName(entry) & "\" names no item in this " &
                       "server's database, so there is nothing to apply")

  if customisationJson.len == 0:
    return refuseDecor("this server's database has no customization table, " &
                       "so it cannot tell what " & itemId &
                       " is; nothing was changed")
  if not field(customisationJson, itemId).found:
    return refuseDecor("\"" & offerName(entry) & "\" names " & itemId &
                       " and there is no such entry in this server's database")

  let branch = branchOf(customisationJson, itemId)
  if branch.len == 0:
    return refuseDecor("\"" & offerName(entry) & "\" names " & itemId &
                       ", which is not placed under anything in this " &
                       "server's customization table, so there is no field " &
                       "to write it to")

  let kind = field(entry, "type").asText("")
  if kind.len > 0 and kind != lowerFirst(branch):
    # The cross-check. An offer whose `type` and whose item disagree is a table
    # this server should not act on: writing the item would put a ceiling in
    # the wall's field, and nothing downstream would notice.
    return refuseDecor("\"" & offerName(entry) & "\" calls itself a " & kind &
                       " and names " & itemId & ", which is a " &
                       lowerFirst(branch) &
                       "; this server will not apply one as the other")

  result = DecorPlan(ok: true, problem: "", slot: branch, itemId: itemId)

proc planPoses*(customisationJson, side, gameVersion, posesJson: string):
    PosePlan =
  ## Every write a `HideoutCustomizationSetMannequinPose` asks for, or the first
  ## refusal. All or nothing, for the reason `emu/customise` gives: a request
  ## naming three poses one of which is wrong changes none of them, because a
  ## half-posed row of mannequins is a player who cannot tell what took.
  if customisationJson.len == 0:
    return refusePose("this server's database has no customization table, so " &
                      "it cannot tell whether those poses are real; nothing " &
                      "was changed")
  let poses = whole(posesJson)
  if not poses.found or not isObject(poses):
    return refusePose("that request names no mannequin poses to set")
  let entries = members(poses)
  if entries.len == 0:
    return refusePose("that request names no mannequin poses to set")

  var plan = PosePlan(ok: true, problem: "", slots: @[], poses: @[])
  for e in entries:
    let poseId = whole(e.value).asText("")
    if poseId.len == 0:
      return refusePose("that request names no pose for mannequin " & e.name)
    var problem = ""
    if not entryAllowed(customisationJson, poseId, side, gameVersion, problem):
      return refusePose(problem)
    let branch = branchOf(customisationJson, poseId)
    if branch != "MannequinPose":
      return refusePose("customisation " & poseId & " is " &
                        (if branch.len > 0: "a " & branch else: "unplaced") &
                        " and not a mannequin pose")
    # `e.name` is the mannequin's own id and is stored as sent -- there is no
    # table of mannequins in this database to check it against. See the header.
    plan.slots.add e.name
    plan.poses.add poseId
  result = plan

# ---------------------------------------------------------------------------
# The half that has a profile
# ---------------------------------------------------------------------------

proc writeInHideout(p: var Profile; member, name, valueJson: string): bool =
  ## `Hideout.<member>.<name> = valueJson`, creating `Hideout.<member>` when the
  ## profile has none.
  ##
  ## Not `setRaw(p, "Hideout.<member>.<name>", ...)`: that replaces a value
  ## already there and does nothing at all when it is not, and neither of these
  ## two maps is written when a profile is created before this change. A write
  ## that silently does nothing is the worst of the three possible outcomes.
  var hideout = parseObject(p.field("Hideout").raw())
  if not hideout.ok:
    return false
  var m = parseObject(hideout.getRaw(member))
  if not m.ok:
    m = newDoc()
  setRaw(m, name, valueJson)
  setRaw(hideout, member, text(m))
  setTopLevel(p, "Hideout", text(hideout))
  result = true

proc applyDecoration*(p: var Profile; body: JsonRef; ch: var Change): bool =
  ## `HideoutCustomizationApplyCommand`. Returns whether the profile changed.
  let plan = planDecoration(hideoutCustomisationTable(), customisationTable(),
                            p.text, body.field("offerId").asText(""))
  if not plan.ok:
    ch.problems.add "hideout customisation: " & plan.problem
    return false
  if not writeInHideout(p, "Customization", plan.slot,
                        "\"" & plan.itemId & "\""):
    ch.problems.add "hideout customisation: this profile has no hideout to " &
                    "decorate; nothing was changed"
    return false
  result = true

proc applyMannequinPose*(p: var Profile; body: JsonRef; ch: var Change): bool =
  ## `HideoutCustomizationSetMannequinPose`. Returns whether the profile
  ## changed.
  let plan = planPoses(customisationTable(), p.side,
                       p.field("Info.GameVersion").asText("standard"),
                       raw(body.field("poses")))
  if not plan.ok:
    ch.problems.add "mannequin pose: " & plan.problem
    return false
  for k in 0 ..< plan.slots.len:
    if not writeInHideout(p, "MannequinPoses", plan.slots[k],
                          "\"" & plan.poses[k] & "\""):
      ch.problems.add "mannequin pose: this profile has no hideout to pose " &
                      "a mannequin in; nothing was changed"
      return false
  result = plan.slots.len > 0

proc recordShootingRange*(p: var Profile; body: JsonRef; ch: var Change): bool =
  ## `HideoutRecordShootingRangePoints`. Returns whether the profile changed.
  ##
  ## The number is the client's and is stored as sent -- see the header. The two
  ## things a server can say about it are said here.
  let points = body.field("points")
  if not points.found:
    ch.problems.add "shooting range: that request reports no score"
    return false
  let value = points.asInt(-1)
  if value < 0:
    ch.problems.add "shooting range: " & raw(points) &
                    " is not a score this server will record"
    return false
  let have = areaLevel(p.field("Hideout.Areas").raw(), ShootingRangeArea)
  if have < 1:
    ch.problems.add "shooting range: you have no shooting range in your " &
                    "hideout, so there was nowhere to score " & $value
    return false

  # `setRaw` on a profile replaces a value that is there and does nothing when
  # it is not, so a profile with no counters block would take the write and
  # drop it. Refused instead: "recorded" and "silently discarded" must not look
  # the same to the player.
  let counters = p.field("Stats.Eft.OverallCounters")
  if not counters.found:
    ch.problems.add "shooting range: this profile has no counters block to " &
                    "record a score in; nothing was changed"
    return false
  var stats = parseObject(counters.raw())
  if not stats.ok:
    stats = newDoc()
  var items = parseArray(stats.getRaw("Items"))
  if not items.ok:
    items = newList()
  var at = -1
  for i in 0 ..< items.len:
    let key = field(items.items[i], "Key")
    if not key.found or not isArray(key):
      continue
    let parts = each(key)
    for part in parts:
      if part.asText("") == PointsCounterKey:
        at = i
  var rec = newDoc()
  setRaw(rec, "Key", "[" & quoted(PointsCounterKey) & "]")
  setNumber(rec, "Value", value)
  if at >= 0:
    replaceAt(items, at, text(rec))
  else:
    items.add rec
  setRaw(stats, "Items", text(items))
  setRaw(p, "Stats.Eft.OverallCounters", text(stats))
  result = true

# ---------------------------------------------------------------------------
# The self-check
# ---------------------------------------------------------------------------

const CheckHideout = """{"globals":[
 {"id":"g_floor","type":"floor","systemName":"Floor_Plain","isEnabled":true,
  "itemId":"i_floor","conditions":[]},
 {"id":"g_wall","type":"wall","systemName":"Wall_Level","isEnabled":true,
  "itemId":"i_wall","conditions":[{"conditionType":"HideoutArea",
   "areaType":12,"value":3,"compareMethod":">="}]},
 {"id":"g_ceiling","type":"ceiling","systemName":"Ceiling_Blocked",
  "isEnabled":true,"itemId":"i_ceiling",
  "conditions":[{"conditionType":"Block"}]},
 {"id":"g_mark","type":"shootingRangeMark","systemName":"Target_Level",
  "isEnabled":true,"itemId":"i_mark",
  "conditions":[{"conditionType":"Level","value":20,"compareMethod":">="}]},
 {"id":"g_odd","type":"floor","systemName":"Floor_Odd","isEnabled":true,
  "itemId":"i_wall","conditions":[]},
 {"id":"g_unknown","type":"floor","systemName":"Floor_Unknown",
  "isEnabled":true,"itemId":"i_floor",
  "conditions":[{"conditionType":"Weather","value":1}]},
 {"id":"g_off","type":"floor","systemName":"Floor_Off","isEnabled":false,
  "itemId":"i_floor","conditions":[]},
 {"id":"g_noitem","type":"floor","systemName":"Floor_Nothing",
  "isEnabled":true,"itemId":"","conditions":[]}
],"slots":[
 {"id":"s_poster","type":"posterSlot","systemName":"Poster_1",
  "isEnabled":true,"slotId":"Poster_1","areaTypeId":14,"conditions":[]}
]}"""

const CheckCustom = """{
 "n_hideout":{"_id":"n_hideout","_name":"Hideout","_parent":"",
   "_type":"Node","_props":{"Side":[]}},
 "n_floor":{"_id":"n_floor","_name":"Floor","_parent":"n_hideout",
   "_type":"Node","_props":{"Side":[]}},
 "n_wall":{"_id":"n_wall","_name":"Wall","_parent":"n_hideout",
   "_type":"Node","_props":{"Side":[]}},
 "n_ceiling":{"_id":"n_ceiling","_name":"Ceiling","_parent":"n_hideout",
   "_type":"Node","_props":{"Side":[]}},
 "n_mark":{"_id":"n_mark","_name":"ShootingRangeMark","_parent":"n_hideout",
   "_type":"Node","_props":{"Side":[]}},
 "n_pose":{"_id":"n_pose","_name":"MannequinPose","_parent":"n_hideout",
   "_type":"Node","_props":{"Side":[]}},
 "n_head":{"_id":"n_head","_name":"Head","_parent":"n_hideout",
   "_type":"Node","_props":{"Side":[]}},
 "i_floor":{"_id":"i_floor","_name":"FloorPlain","_parent":"n_floor",
   "_type":"Item","_props":{"Name":"FloorPlain","Side":["Usec","Bear"],
   "ProfileVersions":[]}},
 "i_wall":{"_id":"i_wall","_name":"WallLevel","_parent":"n_wall",
   "_type":"Item","_props":{"Name":"WallLevel","Side":["Usec","Bear"],
   "ProfileVersions":[]}},
 "i_ceiling":{"_id":"i_ceiling","_name":"CeilingBlocked",
   "_parent":"n_ceiling","_type":"Item","_props":{"Name":"CeilingBlocked",
   "Side":["Usec","Bear"],"ProfileVersions":[]}},
 "i_mark":{"_id":"i_mark","_name":"TargetLevel","_parent":"n_mark",
   "_type":"Item","_props":{"Name":"TargetLevel","Side":["Usec","Bear"],
   "ProfileVersions":[]}},
 "i_pose":{"_id":"i_pose","_name":"StandingPose","_parent":"n_pose",
   "_type":"Item","_props":{"Name":"StandingPose","Side":["Usec","Bear"],
   "ProfileVersions":[],"MannequinPoseName":"standing"}},
 "i_bearpose":{"_id":"i_bearpose","_name":"BearPose","_parent":"n_pose",
   "_type":"Item","_props":{"Name":"BearPose","Side":["Bear"],
   "ProfileVersions":[],"MannequinPoseName":"bear"}},
 "i_head":{"_id":"i_head","_name":"AHead","_parent":"n_head",
   "_type":"Item","_props":{"Name":"AHead","Side":["Usec","Bear"],
   "ProfileVersions":[]}}
}"""

const CheckProfileLow = """{"Info":{"Level":5},
 "Hideout":{"Areas":[{"type":12,"level":1}]},"Quests":[]}"""

const CheckProfileHigh = """{"Info":{"Level":25},
 "Hideout":{"Areas":[{"type":12,"level":3}]},"Quests":[]}"""

proc selfCheckDecorate*(into: var seq[string]): bool =
  ## The whole of the planning, against literal tables shaped like the real
  ## ones, plus one invariant checked over the **real** pair when the database
  ## carries them.
  ##
  ## The pure half is arithmetic and shape over text: no host, no profile
  ## object, no database, and no input can work around a defect in it. The
  ## database half is the one thing a wire test cannot reach, for the same
  ## reason `emu/customise`'s is here — a fixture has neither 38 offers nor 728
  ## customisations and never will.
  let before = into.len

  # An offer the table does not have.
  let unknown = planDecoration(CheckHideout, CheckCustom, CheckProfileHigh,
                               "no_such_offer")
  if unknown.ok:
    into.add "decorate: an unknown offer id was accepted"
  elif unknown.problem.find("no_such_offer") < 0:
    into.add "decorate: refusing an unknown offer did not name it: " &
             unknown.problem

  # No offer at all.
  if planDecoration(CheckHideout, CheckCustom, CheckProfileHigh, "").ok:
    into.add "decorate: an apply naming no offer was accepted"

  # The plain case: the profile field is the item's branch, not the offer's
  # type, and the item written is the offer's own.
  let floorPlan = planDecoration(CheckHideout, CheckCustom, CheckProfileHigh,
                                 "g_floor")
  if not floorPlan.ok:
    into.add "decorate: a floor was refused: " & floorPlan.problem
  elif floorPlan.slot != "Floor" or floorPlan.itemId != "i_floor":
    into.add "decorate: a floor planned " & floorPlan.slot & " = " &
             floorPlan.itemId & " rather than Floor = i_floor"

  # A slot is not a decoration.
  let slotPlan = planDecoration(CheckHideout, CheckCustom, CheckProfileHigh,
                                "s_poster")
  if slotPlan.ok:
    into.add "decorate: a poster slot was accepted as a decoration"
  elif slotPlan.problem.find("slot") < 0:
    into.add "decorate: refusing a slot did not say so: " & slotPlan.problem

  # `Block` is never met.
  let blocked = planDecoration(CheckHideout, CheckCustom, CheckProfileHigh,
                               "g_ceiling")
  if blocked.ok:
    into.add "decorate: a blocked ceiling was accepted"

  # `HideoutArea`, both ways round.
  let areaLow = planDecoration(CheckHideout, CheckCustom, CheckProfileLow,
                               "g_wall")
  if areaLow.ok:
    into.add "decorate: a wall needing shooting range 3 was accepted at 1"
  elif areaLow.problem.find("12") < 0:
    into.add "decorate: refusing an area condition did not name the area: " &
             areaLow.problem
  let areaHigh = planDecoration(CheckHideout, CheckCustom, CheckProfileHigh,
                                "g_wall")
  if not areaHigh.ok:
    into.add "decorate: a wall was refused at the level that has it: " &
             areaHigh.problem
  elif areaHigh.slot != "Wall":
    into.add "decorate: a wall planned " & areaHigh.slot & " rather than Wall"

  # `Level`, both ways round.
  let levelLow = planDecoration(CheckHideout, CheckCustom, CheckProfileLow,
                                "g_mark")
  if levelLow.ok:
    into.add "decorate: a level-20 target was accepted at level 5"
  let levelHigh = planDecoration(CheckHideout, CheckCustom, CheckProfileHigh,
                                 "g_mark")
  if not levelHigh.ok:
    into.add "decorate: a level-20 target was refused at level 25: " &
             levelHigh.problem
  elif levelHigh.slot != "ShootingRangeMark":
    into.add "decorate: a target planned " & levelHigh.slot &
             " rather than ShootingRangeMark"

  # An unknown condition kind is refused rather than waved through.
  let odd = planDecoration(CheckHideout, CheckCustom, CheckProfileHigh,
                           "g_unknown")
  if odd.ok:
    into.add "decorate: an offer gated on an unknown condition kind was " &
             "accepted"
  elif odd.problem.find("Weather") < 0:
    into.add "decorate: refusing an unknown condition did not name it: " &
             odd.problem

  # Switched off, and naming no item.
  if planDecoration(CheckHideout, CheckCustom, CheckProfileHigh, "g_off").ok:
    into.add "decorate: a disabled offer was accepted"
  if planDecoration(CheckHideout, CheckCustom, CheckProfileHigh,
                    "g_noitem").ok:
    into.add "decorate: an offer naming no item was accepted"

  # The cross-check: a `floor` whose item is a wall.
  let odd2 = planDecoration(CheckHideout, CheckCustom, CheckProfileHigh,
                            "g_odd")
  if odd2.ok:
    into.add "decorate: a floor naming a wall as its item was accepted"

  # No tables at all, each named in its own refusal.
  let noHideout = planDecoration("{}", CheckCustom, CheckProfileHigh, "g_floor")
  if noHideout.ok:
    into.add "decorate: an apply was accepted with no hideout customisation " &
             "table"
  # And the empty table, which must answer exactly as the absent one does --
  # the shape of the bug that made an empty `templates.customization` refuse
  # the whole mod's load.
  let emptyHideout = planDecoration("{\"globals\":[],\"slots\":[]}",
                                    CheckCustom, CheckProfileHigh, "g_floor")
  if emptyHideout.ok:
    into.add "decorate: an apply was accepted against an empty hideout " &
             "customisation table"
  elif emptyHideout.problem != noHideout.problem:
    into.add "decorate: an empty hideout customisation table refuses " &
             "differently from an absent one: \"" & emptyHideout.problem &
             "\" against \"" & noHideout.problem & "\""
  let noCustom = planDecoration(CheckHideout, "", CheckProfileHigh, "g_floor")
  if noCustom.ok:
    into.add "decorate: an apply was accepted with no customization table"

  # ---- mannequin poses ---------------------------------------------------
  let pose = planPoses(CheckCustom, "Usec", "standard",
                       "{\"mannequin_1\":\"i_pose\"}")
  if not pose.ok:
    into.add "decorate: a mannequin pose was refused: " & pose.problem
  elif pose.slots.len != 1 or pose.slots[0] != "mannequin_1" or
       pose.poses[0] != "i_pose":
    into.add "decorate: a pose planned " &
             (if pose.slots.len > 0: pose.slots[0] & " = " & pose.poses[0]
              else: "nothing") & " rather than mannequin_1 = i_pose"

  let twoPoses = planPoses(CheckCustom, "Usec", "standard",
                           "{\"m1\":\"i_pose\",\"m2\":\"i_pose\"}")
  if not twoPoses.ok or twoPoses.slots.len != 2:
    into.add "decorate: two poses in one request did not plan two writes"

  # A head is not a pose.
  let notPose = planPoses(CheckCustom, "Usec", "standard",
                          "{\"m1\":\"i_head\"}")
  if notPose.ok:
    into.add "decorate: a head was accepted as a mannequin pose"

  # The other faction's pose, through `emu/customise`'s own side check.
  let wrongSide = planPoses(CheckCustom, "Usec", "standard",
                            "{\"m1\":\"i_bearpose\"}")
  if wrongSide.ok:
    into.add "decorate: a Bear pose was accepted on a Usec profile"

  # All or nothing.
  let mixed = planPoses(CheckCustom, "Usec", "standard",
                        "{\"m1\":\"i_pose\",\"m2\":\"i_head\"}")
  if mixed.ok or mixed.slots.len > 0:
    into.add "decorate: a pose request with one bad entry was partly applied"

  # Nothing to set, and no table to check against.
  if planPoses(CheckCustom, "Usec", "standard", "{}").ok:
    into.add "decorate: an empty pose request was accepted"
  if planPoses("", "Usec", "standard", "{\"m1\":\"i_pose\"}").ok:
    into.add "decorate: a pose was accepted with no customization table"

  # ---- the real tables, when this database has them -----------------------
  #
  # The invariant the profile key is derived from: every offer's `type` is its
  # item's branch with the first letter lowered. It holds for all 38 today, and
  # if it ever stops holding the derivation above is picking a field name out of
  # a table that disagrees with itself -- which is exactly the class of bug the
  # scrambled `Customization` block was, and it is invisible in the client.
  let liveHideout = hideoutCustomisationTable()
  let liveCustom = customisationTable()
  if liveCustom.len > 0:
    let globals = field(liveHideout, "globals")
    if globals.found and isArray(globals):
      let entries = each(globals)
      for e in entries:
        let itemId = e.field("itemId").asText("")
        let kind = e.field("type").asText("")
        let name = e.field("systemName").asText(e.field("id").asText("?"))
        if itemId.len == 0:
          into.add "decorate: hideout customisation \"" & name &
                   "\" names no item"
          continue
        if not field(liveCustom, itemId).found:
          into.add "decorate: hideout customisation \"" & name & "\" names " &
                   itemId & ", which is not in templates.customization"
          continue
        let branch = branchOf(liveCustom, itemId)
        if branch.len == 0:
          into.add "decorate: hideout customisation \"" & name & "\" names " &
                   itemId & ", which is not placed under any node"
        elif kind != lowerFirst(branch):
          into.add "decorate: hideout customisation \"" & name &
                   "\" calls itself a " & kind & " and names a " &
                   lowerFirst(branch)

  result = into.len == before
