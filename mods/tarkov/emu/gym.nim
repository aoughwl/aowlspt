## The gym: the workout minigame, and what the server is entitled to believe
## about it.
##
## `hideout.qte` is one entry in this database and it describes the whole thing:
## area 23 at level 1, fifteen `quickTimeEvents` — a shrinking circle, faster
## and with a tighter success range each time — a `requirements` list, and a
## `results` block with three effects in it. `finishEffect` for reaching the
## end, `singleSuccessEffect` for each circle hit, `singleFailEffect` for the
## one that is missed.
##
## The client plays it. The server is told how it went, in one array of
## booleans, and the whole design question is which parts of that array a server
## is allowed to act on.
##
## ## What the client asserts, and what this server checks
##
## The request is `HandleQTEEventRequestData` — `{Action, id, results:[bool],
## timestamp}`. **Whether any individual circle was actually hit is not
## checkable here and is never checked.** The circle shrinks in the client, the
## mouse is in the client, and no part of that reaches this process. A server
## that pretends otherwise would be inventing a verdict.
##
## What *is* checkable is everything around the booleans, and all of it is
## checked before a point of Strength is paid out:
##
## - **The gym exists.** The entry names `area: 23` at `areaLevel: 1`, and a
##   profile whose `Hideout.Areas` has no area 23 at that level has no gym to
##   have worked out in.
## - **The requirements the entry carries.** 30 energy, 30 hydration, and no
##   `Fracture` on either arm. This is the real limiter and it is worth saying
##   why: a workout costs 2 energy and 2 hydration per circle hit and 4 per one
##   missed, so a full fifteen-event run costs **30 to 32** of each — 30 for
##   fifteen hits, 32 for fourteen and a miss — and the 30-point floor means
##   the gym cannot be run indefinitely without food and water. Skipping this
##   check is what makes strength free.
##
##   (This line used to read "between 30 and 60", which is 15 × 4 — the cost of
##   a run that missed every circle. This server refuses that array two bullets
##   down: `singleFailEffect` carries `result: "Exit"`, so a miss may only be
##   the *last* element and at most one of a run can be a miss. 60 was never
##   reachable through `gymRun`. `finishEffect` adds 0/0, so the bound is the
##   whole of it.)
## - **The length of the array.** `results` may not be longer than the fifteen
##   events the database defines. A client claiming forty circles in a
##   fifteen-circle workout is claiming events that do not exist.
## - **Where the failure is.** `singleFailEffect` carries `result: "Exit"`,
##   which is the database saying that missing one circle ends the session. So
##   a valid run is a run of successes, optionally ending in **one** failure as
##   its last element. A `false` anywhere before the end describes a workout
##   that carried on after the game had ended it, and is refused. A short,
##   all-true run is *not* refused — a player can walk away from the bench, and
##   the finish bonus simply does not apply.
##
## Everything else is the client's word, and this file says so where it takes
## it rather than leaving a reader to wonder.
##
## ## What is paid out, and what is not
##
## Energy and hydration come straight off the entry: `singleSuccessEffect` is
## -2/-2 and `singleFailEffect` is -4/-4, multiplied by the counts.
##
## Skill comes off `singleSuccessEffect.rewardsRange`, which in this database is
## two entries of `type: "Skill"` — `Endurance` and `Strength` — each with a
## `levelMultipliers` table reading 0 -> 6, 10 -> 5, 25 -> 4. The multiplier for
## a skill is the one for the highest level threshold at or below the level the
## profile currently has, and the raw claim is that multiplier times the number
## of circles hit. It goes in through `addSkill`, so the ordinary skill curve —
## fresh-skill bonus, fatigue, the per-session cap — prices it exactly as a
## raid's gains are priced, rather than a second set of arithmetic that can
## disagree with the first.
##
## **Both skills are paid, not one of the two.** Each entry carries
## `weight: 1`, and a `weight` in this database usually means a weighted pick
## (a scav case reward is picked that way). Two readings are possible and the
## data does not settle it; what settles it is that the gym trains both
## Endurance and Strength, and the two entries differ in nothing but `skillId`.
## If a future table ever carries unequal weights here, this is the decision to
## revisit.
##
## **The two health penalties are not applied, and the player is told so.**
## `finishEffect` names a reward of type `MusclePain` and `singleFailEffect`
## names one of type `GymArmTrauma`. Neither string exists anywhere else in this
## database: `globals.config.Health.Effects` defines `MildMusclePain` and
## `SevereMusclePain` and nothing called `MusclePain`, and `GymArmTrauma`
## appears exactly once in the whole file — here. So applying one would mean
## inventing two facts, which effect it becomes and which body part carries it,
## and this server does not invent data. The workout is therefore slightly
## cheaper than the game's, in a direction that is stated in a warning on the
## response rather than hidden.
##
## (`globals.config.Health.Effects.MildMusclePain.GymEffectivity` is 0.5 and the
## severe one's is 1.0. That is plainly *about* this feature, and it is not used
## here: nothing in the database says whether it scales gain, chance or
## duration, and the mild-is-half/severe-is-full ordering rules out the obvious
## guess. Naming it and leaving it alone is the honest state.)

import aowlspt
import aowlspt/server
import aowlspt/json
import profile
import inventory
import skills
import production

# ---------------------------------------------------------------------------
# The pure half: one QTE entry and one array of booleans
# ---------------------------------------------------------------------------

type
  GymRun* = object
    ## What a run of the minigame was worth, given the entry that describes it.
    ## No profile and no database in it, so `emu/selfchecks` can pin the whole
    ## of this arithmetic at load against a literal entry.
    ok*: bool
    problem*: string
    successes*: int
    failures*: int
    finished*: bool          ## every event the entry defines was played
    energyDelta*: int        ## negative: what the workout costs
    hydrationDelta*: int
    skillIds*: seq[string]
    skillMultipliers*: seq[string]  ## the matching `levelMultipliers` arrays
    unnamedEffects*: seq[string]    ## reward types this database defines nowhere

proc newGymRun(): GymRun =
  GymRun(ok: false, problem: "", successes: 0, failures: 0, finished: false,
         energyDelta: 0, hydrationDelta: 0, skillIds: @[],
         skillMultipliers: @[], unnamedEffects: @[])

proc exitsOnFailure(entryJson: string): bool =
  ## Whether the database says one missed circle ends the session. Read rather
  ## than assumed: it is `results.singleFailEffect.rewardsRange[].result` being
  ## `"Exit"`, and the rule about where a `false` may appear is only legitimate
  ## because the data says this.
  result = false
  let range = field(entryJson, "results.singleFailEffect.rewardsRange")
  if not range.found:
    return
  let entries = each(range)
  for e in entries:
    if e.field("result").asText("") == "Exit":
      return true

proc effectEnergy(entryJson, effect: string): int =
  field(entryJson, "results." & effect & ".energy").asInt(0)

proc effectHydration(entryJson, effect: string): int =
  field(entryJson, "results." & effect & ".hydration").asInt(0)

proc collectEffect(entryJson, effect: string; run: var GymRun; times: int) =
  ## The rewards of one effect, applied `times` over. Skill rewards are
  ## collected for the caller to price against the profile; a reward type this
  ## database defines nowhere is collected too, as something to tell the player
  ## about rather than something to silently drop.
  if times <= 0:
    return
  let range = field(entryJson, "results." & effect & ".rewardsRange")
  if not range.found:
    return
  let entries = each(range)
  for e in entries:
    let kind = e.field("type").asText("")
    case kind
    of "Skill":
      let id = e.field("skillId").asText("")
      if id.len == 0:
        continue
      var at = -1
      for k in 0 ..< run.skillIds.len:
        if run.skillIds[k] == id:
          at = k
      if at < 0:
        run.skillIds.add id
        run.skillMultipliers.add raw(e.field("levelMultipliers"))
    of "MusclePain", "GymArmTrauma", "HealthEffect":
      # See the header: none of these three names an effect this database
      # defines, so none of them is applied. Recorded once per run, not once
      # per event.
      var seen = false
      for k in 0 ..< run.unnamedEffects.len:
        if run.unnamedEffects[k] == kind:
          seen = true
      if not seen:
        run.unnamedEffects.add kind
    else:
      var seen = false
      for k in 0 ..< run.unnamedEffects.len:
        if run.unnamedEffects[k] == kind:
          seen = true
      if not seen and kind.len > 0:
        run.unnamedEffects.add kind

proc gymRun*(entryJson: string; results: seq[bool]): GymRun =
  ## One reported workout against the entry that describes it.
  ##
  ## Refuses rather than clamps. A `results` array that does not describe a
  ## workout this entry could have produced is a client this server does not
  ## understand, and paying out the part of it that does parse is how a wrong
  ## claim becomes a real skill point.
  result = newGymRun()
  let events = field(entryJson, "quickTimeEvents")
  if not events.found or not isArray(events):
    result.problem = "the database's gym entry defines no quick time events"
    return
  let defined = count(events)
  if defined <= 0:
    result.problem = "the database's gym entry defines no quick time events"
    return
  if results.len == 0:
    result.problem = "that workout reports no events at all"
    return
  if results.len > defined:
    result.problem = "that workout reports " & $results.len &
                     " event(s) and this gym has only " & $defined
    return

  let exits = exitsOnFailure(entryJson)
  for i in 0 ..< results.len:
    if results[i]:
      result.successes = result.successes + 1
    else:
      result.failures = result.failures + 1
      if exits and i != results.len - 1:
        result.problem = "that workout reports event " & $(i + 1) &
                         " as missed and then " &
                         $(results.len - i - 1) & " more; a missed event " &
                         "ends the session"
        return

  result.finished = results.len == defined
  result.energyDelta =
    result.successes * effectEnergy(entryJson, "singleSuccessEffect") +
    result.failures * effectEnergy(entryJson, "singleFailEffect")
  result.hydrationDelta =
    result.successes * effectHydration(entryJson, "singleSuccessEffect") +
    result.failures * effectHydration(entryJson, "singleFailEffect")
  if result.finished:
    result.energyDelta = result.energyDelta +
                         effectEnergy(entryJson, "finishEffect")
    result.hydrationDelta = result.hydrationDelta +
                            effectHydration(entryJson, "finishEffect")
    collectEffect(entryJson, "finishEffect", result, 1)
  # Bound to locals first: `result` goes in as a `var` parameter and the counts
  # come out of it, which the compiler reads as a mutable argument aliasing an
  # immutable one.
  let hits = result.successes
  let misses = result.failures
  collectEffect(entryJson, "singleSuccessEffect", result, hits)
  collectEffect(entryJson, "singleFailEffect", result, misses)
  result.ok = true

proc gymMultiplier*(levelMultipliersJson: string; level: int): float =
  ## The multiplier for a skill at `level`: the one belonging to the highest
  ## `level` threshold at or below it.
  ##
  ## Zero when the table is empty or names no threshold this level has reached,
  ## and zero is a refusal to pay rather than a payment of nothing — the caller
  ## grants nothing for a skill it cannot price.
  result = 0.0
  if levelMultipliersJson.len == 0:
    return
  let list = each(whole(levelMultipliersJson))
  var best = -1
  for e in list:
    let at = e.field("level").asInt(0)
    if at <= level and at > best:
      best = at
      result = e.field("multiplier").asFloat(0.0)

# ---------------------------------------------------------------------------
# The half that has a database and a profile
# ---------------------------------------------------------------------------

proc gymAction*(name: string): bool =
  ## `ItemEventActions.HIDEOUT_QTE_EVENT`. The reference dump carries the enum's
  ## member names and not their values, so this is the wire spelling the client
  ## uses, the same convention `emu/personal` states for its own actions.
  result = name == "HideoutQuickTimeEvent"

proc qteTable*(): string =
  ## `hideout.qte` as raw JSON, "[]" when the database has none. Served
  ## verbatim on `/client/hideout/qte/list`: it is content, and nothing in it
  ## needs looking at to send it.
  let v = dbRead("hideout.qte")
  if v.ok and v.raw.len > 0:
    return v.raw
  result = "[]"

proc qteEntry(id: string): string =
  ## The entry with this id, or "" when the database has no such entry.
  let table = qteTable()
  let list = each(whole(table))
  for e in list:
    if e.field("id").asText("") == id:
      return raw(e)
  result = ""

proc requirementsMet(p: Profile; entryJson: string; problem: var string): bool =
  ## Every requirement the entry carries, or a refusal naming the first one that
  ## is not met.
  ##
  ## An unrecognised requirement type is a **refusal**, not a pass. This
  ## database's gym asks for two things, `Health` and two excluded
  ## `BodyPartBuff`s, and a third kind appearing in a future table must not
  ## quietly become a workout that costs nothing to start — that is the shape of
  ## the free-hideout bug `emu/hideout` documents at length.
  problem = ""
  let reqs = field(entryJson, "requirements")
  if not reqs.found:
    return true
  let list = each(reqs)
  for r in list:
    let kind = r.field("type").asText("")
    case kind
    of "Health":
      let energy = r.field("energy").asInt(0)
      let hydration = r.field("hydration").asInt(0)
      let haveEnergy = p.field("Health.Energy.Current").asInt(0)
      let haveHydration = p.field("Health.Hydration.Current").asInt(0)
      if haveEnergy < energy:
        problem = "this workout needs " & $energy & " energy and you have " &
                  $haveEnergy
        return false
      if haveHydration < hydration:
        problem = "this workout needs " & $hydration &
                  " hydration and you have " & $haveHydration
        return false
    of "BodyPartBuff":
      let part = r.field("bodyPart").asText("")
      let name = r.field("effectName").asText("")
      if part.len == 0 or name.len == 0:
        problem = "the database's gym has a body part requirement naming no " &
                  "part or no effect"
        return false
      let has = p.field("Health.BodyParts." & part & ".Effects." &
                        name).found
      if r.field("excluded").asBool(false):
        if has:
          problem = "you cannot work out with " & name & " on your " & part
          return false
      elif not has:
        problem = "this workout needs " & name & " on your " & part
        return false
    of "Area":
      let areaType = r.field("areaType").asInt(-1)
      let need = r.field("requiredLevel").asInt(0)
      let have = areaLevel(p.field("Hideout.Areas").raw(), areaType)
      if have < need:
        problem = "this workout needs hideout area " & $areaType &
                  " at level " & $need & " and yours is at " & $have
        return false
    else:
      problem = "this server does not know the gym requirement \"" & kind &
                "\", so it cannot say whether you meet it"
      return false
  result = true

proc readResults(body: JsonRef; into: var seq[bool]; problem: var string): bool =
  ## `results` as booleans, strictly. `asBool` would read a missing member and a
  ## string as `false`, which turns a malformed request into a workout of
  ## failures rather than into a refusal.
  problem = ""
  let list = body.field("results")
  if not list.found or not isArray(list):
    problem = "that workout reports no results array"
    return false
  let entries = each(list)
  for e in entries:
    let r = raw(e)
    if r == "true":
      into.add true
    elif r == "false":
      into.add false
    else:
      problem = "that workout reports " & r & " as an event result, which is " &
                "neither true nor false"
      return false
  result = true

proc applyGym*(p: var Profile; body: JsonRef; nowSeconds: int;
               ch: var Change): bool =
  ## `HideoutQuickTimeEvent`: one reported workout. Returns whether the profile
  ## changed.
  ##
  ## Verified whole, then applied, like every other payment here — the gym is
  ## paid for in energy and hydration and paid out in skill, and a run that is
  ## refused halfway is a player charged for a workout they did not get.
  let id = body.field("id").asText("")
  if id.len == 0:
    ch.problems.add "gym: that workout names no quick time event"
    return false
  let entryJson = qteEntry(id)
  if entryJson.len == 0:
    # Refused rather than guessed. Without the entry there is no event count to
    # bound the claim by, no energy cost and no skill multipliers, and every
    # one of those absences pays the player rather than the house.
    ch.problems.add "gym: this server's database describes no quick time " &
                    "event " & id & ", so it cannot say what that workout was " &
                    "worth; nothing was awarded"
    return false

  let area = field(entryJson, "area").asInt(-1)
  let needLevel = field(entryJson, "areaLevel").asInt(0)
  if area >= 0:
    let have = areaLevel(p.field("Hideout.Areas").raw(), area)
    if have < needLevel:
      ch.problems.add "gym: this workout needs hideout area " & $area &
                      " at level " & $needLevel & " and yours is at " & $have
      return false

  var problem = ""
  if not requirementsMet(p, entryJson, problem):
    ch.problems.add "gym: " & problem
    return false

  var results: seq[bool] = @[]
  if not readResults(body, results, problem):
    ch.problems.add "gym: " & problem
    return false

  let run = gymRun(entryJson, results)
  if not run.ok:
    ch.problems.add "gym: " & run.problem
    return false

  # ---- act ---------------------------------------------------------------
  #
  # Through `addSkill`, which means the gym shares `PointsEarnedDuringSession`
  # with the raid that reset it -- so a second workout on the same session is
  # worth less than the first, and a third less again. Measured against the
  # real table: fifteen hits at level 0 claim 90 raw and are granted 27.5 the
  # first time and 36 for the next two runs together. That is the fatigue curve
  # doing exactly what it does to a raid's gains, and it is the right side to
  # err on -- the alternative is a second counter that can disagree with the
  # first about what a point of Endurance costs.
  let curve = skillCurve()
  var common = p.field("Skills.Common").raw()
  for k in 0 ..< run.skillIds.len:
    let level = skillLevel(skillProgress(common, run.skillIds[k]))
    let multiplier = gymMultiplier(run.skillMultipliers[k], level)
    if multiplier <= 0.0:
      # The table names this skill and prices it at nothing for this level.
      # Nothing is granted and the player is told, rather than a silent zero.
      ch.problems.add "gym: this server's database gives no " &
                      run.skillIds[k] & " multiplier at level " & $level &
                      ", so none was awarded"
      continue
    var granted = 0.0
    common = addSkill(common, run.skillIds[k],
                      multiplier * float(run.successes), curve, nowSeconds,
                      granted)
  setRaw(p, "Skills.Common", common)

  var energy = p.field("Health.Energy.Current").asInt(0) + run.energyDelta
  if energy < 0: energy = 0
  let energyMax = p.field("Health.Energy.Maximum").asInt(0)
  if energyMax > 0 and energy > energyMax: energy = energyMax
  setNumber(p, "Health.Energy.Current", energy)

  var hydration = p.field("Health.Hydration.Current").asInt(0) +
                  run.hydrationDelta
  if hydration < 0: hydration = 0
  let hydrationMax = p.field("Health.Hydration.Maximum").asInt(0)
  if hydrationMax > 0 and hydration > hydrationMax: hydration = hydrationMax
  setNumber(p, "Health.Hydration.Current", hydration)

  for k in 0 ..< run.unnamedEffects.len:
    # Once per workout, and only when the effect was actually due. See the
    # header: these are penalties this database names and does not define, and
    # a player who is not told is a player whose gym is quietly easier than the
    # game's.
    ch.problems.add "gym: the workout's \"" & run.unnamedEffects[k] &
                    "\" penalty was not applied -- this server's database " &
                    "names it and defines no such effect"
  result = true

# ---------------------------------------------------------------------------
# The self-check
# ---------------------------------------------------------------------------

const CheckEntry = """{"id":"gym","area":23,"areaLevel":1,
  "quickTimeEvents":[{"type":"ShrinkingCircle"},{"type":"ShrinkingCircle"},
    {"type":"ShrinkingCircle"},{"type":"ShrinkingCircle"}],
  "results":{
    "finishEffect":{"energy":0,"hydration":0,
      "rewardsRange":[{"weight":1,"result":"Exit","time":86400,
                       "type":"MusclePain"}]},
    "singleSuccessEffect":{"energy":-2,"hydration":-2,
      "rewardsRange":[
        {"weight":1,"result":"None","skillId":"Endurance",
         "levelMultipliers":[{"level":0,"multiplier":6},
                             {"level":10,"multiplier":5},
                             {"level":25,"multiplier":4}],"type":"Skill"},
        {"weight":1,"result":"None","skillId":"Strength",
         "levelMultipliers":[{"level":0,"multiplier":6},
                             {"level":10,"multiplier":5},
                             {"level":25,"multiplier":4}],"type":"Skill"}]},
    "singleFailEffect":{"energy":-4,"hydration":-4,
      "rewardsRange":[{"weight":1,"result":"Exit","type":"GymArmTrauma"}]}}}"""

proc selfCheckGym*(into: var seq[string]): bool =
  ## The workout's arithmetic, against a literal entry cut down from the real
  ## one — four events instead of fifteen, the same three effects and the same
  ## multiplier table.
  ##
  ## Runs at load through `emu/selfchecks`, so a defect here is a mod that
  ## refuses to serve rather than one that quietly pays out the wrong number of
  ## Strength points for the rest of a wipe.
  let before = into.len

  # A full run of successes: four circles at -2 each, plus a finish effect
  # worth nothing, and both skills collected once.
  let full = gymRun(CheckEntry, @[true, true, true, true])
  if not full.ok:
    into.add "gym: a full run was refused: " & full.problem
  else:
    if full.successes != 4 or full.failures != 0:
      into.add "gym: a full run counted " & $full.successes & "/" &
               $full.failures & " rather than 4/0"
    if not full.finished:
      into.add "gym: a run of every event did not count as finished"
    if full.energyDelta != -8 or full.hydrationDelta != -8:
      into.add "gym: a full run cost " & $full.energyDelta & " energy and " &
               $full.hydrationDelta & " hydration rather than -8 and -8"
    if full.skillIds.len != 2:
      into.add "gym: a full run collected " & $full.skillIds.len &
               " skill(s) rather than 2"
    if full.unnamedEffects.len != 1:
      into.add "gym: a finished run reported " & $full.unnamedEffects.len &
               " undefined effect(s) rather than 1 (MusclePain)"

  # Ending on a miss: three at -2 and one at -4, and the fail effect's
  # undefined penalty is reported alongside the finish one.
  let missed = gymRun(CheckEntry, @[true, true, true, false])
  if not missed.ok:
    into.add "gym: a run ending on a miss was refused: " & missed.problem
  else:
    if missed.successes != 3 or missed.failures != 1:
      into.add "gym: a run ending on a miss counted " & $missed.successes &
               "/" & $missed.failures & " rather than 3/1"
    if missed.energyDelta != -10 or missed.hydrationDelta != -10:
      into.add "gym: a run ending on a miss cost " & $missed.energyDelta &
               " energy rather than -10"
    if missed.unnamedEffects.len != 2:
      into.add "gym: a finished run ending on a miss reported " &
               $missed.unnamedEffects.len & " undefined effect(s) rather than 2"

  # Walking away part-way: allowed, cheaper, and not a finish.
  let short = gymRun(CheckEntry, @[true, true])
  if not short.ok:
    into.add "gym: a run cut short was refused: " & short.problem
  elif short.finished or short.energyDelta != -4:
    into.add "gym: a run cut short counted as finished or cost " &
             $short.energyDelta & " rather than -4"

  # A miss that is not the last event describes a session that carried on after
  # the database says it ended.
  let carriedOn = gymRun(CheckEntry, @[true, false, true, true])
  if carriedOn.ok:
    into.add "gym: a run reporting events after a miss was accepted"

  # More events than the gym has.
  let tooMany = gymRun(CheckEntry, @[true, true, true, true, true])
  if tooMany.ok:
    into.add "gym: a run of 5 events was accepted by a gym that has 4"

  # No events at all.
  let empty = gymRun(CheckEntry, @[])
  if empty.ok:
    into.add "gym: a run reporting no events at all was accepted"

  # The multiplier table, at and either side of every threshold it names.
  let mult = "[{\"level\":0,\"multiplier\":6},{\"level\":10,\"multiplier\":5}," &
             "{\"level\":25,\"multiplier\":4}]"
  let wantLevels = @[0, 9, 10, 24, 25, 51]
  let wantValues = @[6.0, 6.0, 5.0, 5.0, 4.0, 4.0]
  for k in 0 ..< wantLevels.len:
    let got = gymMultiplier(mult, wantLevels[k])
    if got < wantValues[k] - 0.0001 or got > wantValues[k] + 0.0001:
      into.add "gym: the multiplier at level " & $wantLevels[k] & " is " &
               $got & " rather than " & $wantValues[k]
  if gymMultiplier("[]", 5) != 0.0:
    into.add "gym: an empty multiplier table priced a level at something"

  result = into.len == before
