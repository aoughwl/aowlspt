## Skills, and weapon mastering.
##
## Both live in the profile's `Skills` section — `Common` for the character's
## skills, `Mastering` for the weapons they have carried — and both arrive the
## same way: the client plays the raid, keeps its own tally, and hands the whole
## profile back at `/client/match/local/end`.
##
## That last sentence is the design problem. The raid result *is* a profile, so
## the naive server takes the client's skill numbers verbatim — and then the
## skills are whatever the client says they are, which means whatever anyone who
## edits their client says they are. The other naive server ignores them, and
## then skills never move at all.
##
## So what is taken from the raid result is the **delta**: the difference
## between the skills the profile went in with and the ones it came out with.
## That is the raid's claim about how much work was done, which is fair — the
## server was not there and cannot know — and it is then run through the game's
## own progression curve, which the server *does* own. A client claiming a
## thousand points of Endurance gets the same answer as one claiming a hundred,
## because the curve and the cap are applied here.
##
## The curve is EFT's, and it has three parts:
##
## - **Fresh points.** The first few points of a session are worth more, which
##   is what makes a short raid on a neglected skill feel like it moved.
## - **Fatigue.** Past a threshold, each further point in the same session is
##   divided down, asymptotically. This is what actually stops grinding, and it
##   is why the gain is integrated point by point below rather than multiplied
##   in one go: applying one multiplier to a large delta would make a single
##   enormous claim *more* efficient than the many small ones the game gives.
## - **A hard cap** per raid per skill, on top, because fatigue only converges
##   slowly and a large enough claim still crawls past it.
##
## Settings come out of `globals.config.SkillsSettings` when the database has
## them and from the constants below when it does not, so a server with no
## database still levels skills — with the live game's numbers, which are the
## honest default.
##
## **What is not here: the effects.** A skill level's buffs — recoil, weight,
## healing speed — are applied by the client, out of its own bundles, from the
## progress number. There is no server-side table to write them into and no
## endpoint that asks for them, so inventing one would be writing a document
## nothing reads. What the server owns is the number and the level it implies,
## and `skillLevel`/`isElite` expose that for anything that needs it. Hideout
## bonuses are a different matter — those *are* server-side, and they are in
## `emu/production.nim`.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import numbers
import profile

const
  ProgressPerLevel* = 100.0
  MaxSkillLevel* = 51
    ## 51 is elite. The client draws anything above it as 51 anyway, so progress
    ## is clamped here rather than left to grow into a number no screen shows.
  MaxSkillProgress* = ProgressPerLevel * float(MaxSkillLevel)

  DefaultProgressRate* = 1.0
  DefaultFreshEffectiveness* = 1.5
  DefaultFreshPoints* = 10.0
  DefaultPointsBeforeFatigue* = 100.0
  DefaultFatiguePerPoint* = 1.0
  DefaultPerRaidCap* = 100.0
    ## One level, per skill, per raid, after everything else. Generous on
    ## purpose: it is a backstop against a nonsense claim, not the thing that
    ## shapes normal play -- fatigue is.
  DefaultMasteringPerRaidCap* = 100

type
  SkillCurve* = object
    progressRate*: float
    freshEffectiveness*: float
    freshPoints*: float
    pointsBeforeFatigue*: float
    fatiguePerPoint*: float
    perRaidCap*: float

proc defaultCurve*(): SkillCurve =
  ## A literal, deliberately. A global initialised by a call is silently left
  ## zeroed in a `--app:lib` build, and a zeroed curve is one where every skill
  ## gain is multiplied by nothing -- a bug that looks exactly like "skills do
  ## not work" and has no error anywhere.
  SkillCurve(progressRate: DefaultProgressRate,
             freshEffectiveness: DefaultFreshEffectiveness,
             freshPoints: DefaultFreshPoints,
             pointsBeforeFatigue: DefaultPointsBeforeFatigue,
             fatiguePerPoint: DefaultFatiguePerPoint,
             perRaidCap: DefaultPerRaidCap)

proc dbFloat(path: string; fallback: float): float =
  let v = dbRead(path)
  if not v.ok or v.raw.len == 0:
    return fallback
  result = asFloat(v, fallback)

proc skillCurve*(): SkillCurve =
  ## The live numbers when the database has them, the constants when it does
  ## not, and per-key: a database that names three of the six is used for those
  ## three. Falling back wholesale on one missing key would throw away real data
  ## over a field nobody set.
  result = defaultCurve()
  const root = "globals.config.SkillsSettings."
  result.progressRate = dbFloat(root & "SkillProgressRate", result.progressRate)
  result.freshEffectiveness = dbFloat(root & "SkillFreshEffectiveness",
                                      result.freshEffectiveness)
  result.freshPoints = dbFloat(root & "SkillFreshPoints", result.freshPoints)
  result.pointsBeforeFatigue = dbFloat(root & "SkillPointsBeforeFatigue",
                                       result.pointsBeforeFatigue)
  result.fatiguePerPoint = dbFloat(root & "SkillFatiguePerPoint",
                                   result.fatiguePerPoint)
  let cap = setting("skillMaxPerRaid")
  if cap.ok:
    let c = asFloat(cap, 0.0)
    if c > 0.0:
      result.perRaidCap = c

# ---------------------------------------------------------------------------
# Levels
# ---------------------------------------------------------------------------

proc skillLevel*(progress: float): int =
  ## The level a progress number is worth. Floor, not round: 199 points is level
  ## one, and a client that rounds would show a level the server does not agree
  ## the player has.
  if progress <= 0.0:
    return 0
  result = int(progress / ProgressPerLevel)
  if result > MaxSkillLevel: result = MaxSkillLevel

proc progressForLevel*(level: int): float = float(level) * ProgressPerLevel

proc isElite*(progress: float): bool = skillLevel(progress) >= MaxSkillLevel

# ---------------------------------------------------------------------------
# The curve
# ---------------------------------------------------------------------------

proc grantedFor*(rawGain, alreadyThisRaid: float; c: SkillCurve): float =
  ## What a raw claim of `rawGain` is actually worth, given that
  ## `alreadyThisRaid` points have already been granted this raid.
  ##
  ## Integrated one point at a time rather than multiplied once. That is not
  ## pedantry: fatigue is a function of how much has been earned *so far*, so a
  ## single multiplication would price the whole claim at its cheapest rate and
  ## make one big claim strictly better than the many small ones the game
  ## actually produces -- which is the exact shape of an exploit.
  if rawGain <= 0.0:
    return 0.0
  var remaining = rawGain * c.progressRate
  var earned = alreadyThisRaid
  var granted = 0.0
  # Bounded, because `remaining` comes off a request body. At one point per
  # step the cap can only be reached by a claim far past anything the curve
  # would pay out for anyway, and stopping is the right answer to it.
  var steps = 0
  while remaining > 0.0 and steps < 20000:
    inc steps
    let step = if remaining < 1.0: remaining else: 1.0
    var mult = 1.0
    if earned < c.freshPoints:
      mult = c.freshEffectiveness
    elif earned > c.pointsBeforeFatigue:
      let denom = c.fatiguePerPoint * (earned - c.pointsBeforeFatigue) + 1.0
      if denom > 0.0:
        mult = 1.0 / denom
    let gain = step * mult
    if c.perRaidCap > 0.0 and earned + gain >= c.perRaidCap:
      granted = granted + (c.perRaidCap - earned)
      return granted
    granted = granted + gain
    earned = earned + gain
    remaining = remaining - step
  result = granted

# ---------------------------------------------------------------------------
# Skills.Common
# ---------------------------------------------------------------------------

proc findSkill(list: List; id: string): int =
  result = -1
  for i in 0 ..< list.len:
    if field(list.items[i], "Id").asText("") == id:
      return i

proc skillProgress*(commonJson, id: string): float =
  let list = parseArray(commonJson)
  if not list.ok:
    return 0.0
  let at = findSkill(list, id)
  if at < 0:
    return 0.0
  result = field(list.items[at], "Progress").asFloat(0.0)

proc addSkill*(commonJson, id: string; rawGain: float; c: SkillCurve;
               nowSeconds: int; granted: var float): string =
  ## One skill, gained. Returns the new `Skills.Common` array.
  ##
  ## `PointsEarnedDuringSession` is the fatigue counter and is kept on the entry
  ## the client already carries, so a raid's second batch of Endurance is priced
  ## against the first. It is *not* reset here: resetting belongs to whatever
  ## starts a raid, and doing it on a gain would make every gain a fresh session.
  granted = 0.0
  var list = parseArray(commonJson)
  if not list.ok:
    list = newList()
  if id.len == 0:
    return text(list)
  var at = findSkill(list, id)
  var d = newDoc()
  if at >= 0:
    d = parseObject(list.items[at])
  else:
    setText(d, "Id", id)
    setRaw(d, "Progress", numText(0.0))
    setRaw(d, "PointsEarnedDuringSession", numText(0.0))
    setNumber(d, "LastAccess", nowSeconds)

  let already = get(d, "PointsEarnedDuringSession").asFloat(0.0)
  granted = grantedFor(rawGain, already, c)
  if granted <= 0.0:
    granted = 0.0
    if at >= 0:
      return text(list)
  var progress = get(d, "Progress").asFloat(0.0) + granted
  if progress > MaxSkillProgress:
    progress = MaxSkillProgress
  # Through `numText`, like every other float this server stores. Skill
  # progress is added to on every raid for the life of a character, which makes
  # it the accumulator most exposed to binary drift: see `emu/numbers`.
  setRaw(d, "Progress", numText(progress))
  setNumber(d, "PointsEarnedDuringSession", already + granted)
  setNumber(d, "LastAccess", nowSeconds)
  if at >= 0:
    list.replaceAt(at, text(d))
  else:
    list.add d
  result = text(list)

proc applyRaidSkills*(preCommonJson, playedCommonJson: string; c: SkillCurve;
                      nowSeconds: int; levelUps: var seq[string]): string =
  ## The whole `Skills.Common` array, rebuilt from the pre-raid one plus what
  ## the raid claims.
  ##
  ## Built on the *pre-raid* array, not the client's: the client's numbers are
  ## only ever read as a difference. A skill the client sends that the profile
  ## has never had is a legitimate first gain, and its delta is the whole of it;
  ## a skill whose number went *down* is discarded rather than applied, because
  ## nothing in the game reduces a skill mid-raid and the likely cause is a
  ## client that posted a stale profile.
  levelUps = @[]
  var out1 = preCommonJson
  let claimed = each(whole(playedCommonJson))
  for s in claimed:
    let id = s.field("Id").asText("")
    if id.len == 0:
      continue
    let before = skillProgress(preCommonJson, id)
    let after = s.field("Progress").asFloat(0.0)
    let delta = after - before
    if delta <= 0.0:
      continue
    var granted = 0.0
    out1 = addSkill(out1, id, delta, c, nowSeconds, granted)
    if skillLevel(before + granted) > skillLevel(before):
      levelUps.add id
  if not parseArray(out1).ok:
    return "[]"
  result = out1

proc resetSession*(commonJson: string): string =
  ## Clears every fatigue counter. Called when a raid *starts*: fatigue is
  ## per-raid, and a counter that is never reset makes the second raid of a
  ## session pay nothing.
  var list = parseArray(commonJson)
  if not list.ok:
    return commonJson
  for i in 0 ..< list.len:
    var d = parseObject(list.items[i])
    if not d.ok:
      continue
    setRaw(d, "PointsEarnedDuringSession", numText(0.0))
    list.replaceAt(i, text(d))
  result = text(list)

# ---------------------------------------------------------------------------
# Mastering
# ---------------------------------------------------------------------------
#
# Mastering is per weapon *family*, not per weapon: every AK template shares one
# entry. The families are in the database at `globals.config.Mastering`, each
# with the templates it covers and the two thresholds that separate its three
# levels. A server with no globals has no families, so mastering does not move —
# which is right, because without the table there is no way to know which
# family a weapon belongs to and guessing would credit the wrong one.

proc masteringTable*(): string =
  let v = dbRead("globals.config.Mastering")
  if v.ok and v.raw.len > 0 and isArray(whole(v.raw)):
    return v.raw
  result = "[]"

proc masteringForWeapon*(masteringJson, weaponTpl: string): string =
  ## The family name a weapon belongs to, or empty.
  if weaponTpl.len == 0:
    return ""
  let families = each(whole(masteringJson))
  for f in families:
    let tpls = each(f.field("Templates"))
    for t in tpls:
      if t.asText("") == weaponTpl:
        return f.field("Name").asText("")
  result = ""

proc masteringLevel*(masteringJson, name: string; progress: int): int =
  ## 1, 2 or 3. One rather than zero for a family the player has touched at all,
  ## which is the client's own numbering -- a weapon you have fired is mastered
  ## at level one, not at level none.
  let families = each(whole(masteringJson))
  for f in families:
    if f.field("Name").asText("") != name:
      continue
    let l2 = f.field("Level2").asInt(0)
    let l3 = f.field("Level3").asInt(0)
    if l3 > 0 and progress >= l3:
      return 3
    if l2 > 0 and progress >= l2:
      return 2
    return 1
  result = 1

proc masteringCap*(): int =
  let c = setting("masteringMaxPerRaid")
  if c.ok:
    let n = asInt(c, 0)
    if n > 0:
      return n
  result = DefaultMasteringPerRaidCap

proc applyRaidMastering*(preJson, playedJson: string; cap: int): string =
  ## The same delta-and-clamp as the skills, without the curve: mastering has no
  ## fatigue in the game, only a per-raid ceiling here to bound a claim.
  var list = parseArray(preJson)
  if not list.ok:
    list = newList()
  let claimed = each(whole(playedJson))
  for m in claimed:
    let id = m.field("Id").asText("")
    if id.len == 0:
      continue
    var at = -1
    for i in 0 ..< list.len:
      if field(list.items[i], "Id").asText("") == id:
        at = i
    let before = if at >= 0: field(list.items[at], "Progress").asInt(0) else: 0
    var delta = m.field("Progress").asInt(0) - before
    if delta <= 0:
      continue
    if cap > 0 and delta > cap:
      delta = cap
    if at >= 0:
      var d = parseObject(list.items[at])
      # Mastering progress is a whole number of points, not a float.
      setNumber(d, "Progress", before + delta)
      list.replaceAt(at, text(d))
    else:
      var d = newDoc()
      setText(d, "Id", id)
      setNumber(d, "Progress", delta)
      list.add d
  result = text(list)

# ---------------------------------------------------------------------------
# The profile-level entry point
# ---------------------------------------------------------------------------

proc applyRaidProgress*(p: var Profile; preProfileJson: string;
                        nowSeconds: int; levelUps: var seq[string]): bool =
  ## `p` is the profile the client handed back; `preProfileJson` is the one it
  ## went in with. Rewrites `Skills.Common` and `Skills.Mastering` on `p` so the
  ## saved profile carries the server's numbers rather than the client's.
  levelUps = @[]
  if not p.ok:
    return false
  let pre = field(preProfileJson, "Skills.Common")
  let preCommon = if pre.found: raw(pre) else: "[]"
  let played = p.field("Skills.Common")
  let playedCommon = if played.found: raw(played) else: "[]"
  let newCommon = applyRaidSkills(preCommon, playedCommon, skillCurve(),
                                  nowSeconds, levelUps)
  setRaw(p, "Skills.Common", newCommon)

  let preM = field(preProfileJson, "Skills.Mastering")
  let playedM = p.field("Skills.Mastering")
  setRaw(p, "Skills.Mastering",
         applyRaidMastering(if preM.found: raw(preM) else: "[]",
                            if playedM.found: raw(playedM) else: "[]",
                            masteringCap()))
  result = true

proc startRaidSkills*(p: var Profile): bool =
  ## Clears the per-raid fatigue counters. One line at match start.
  if not p.ok:
    return false
  let common = p.field("Skills.Common")
  if not common.found:
    return false
  setRaw(p, "Skills.Common", resetSession(raw(common)))
  result = true

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

proc nearly(a, b: float): bool =
  let d = a - b
  result = (if d < 0.0: -d else: d) < 0.001

proc selfCheckSkills*(failures: var seq[string]): bool =
  ## Pure over JSON text: no database, no host, no profile. What is checked is
  ## the two properties that make the delta design safe -- a big claim is not
  ## worth more per point than a small one, and a shrinking skill is ignored.
  let before = failures.len
  let c = defaultCurve()

  if skillLevel(0.0) != 0: failures.add "skills: 0 progress is not level 0"
  if skillLevel(99.9) != 0: failures.add "skills: 99 progress is not level 0"
  if skillLevel(100.0) != 1: failures.add "skills: 100 progress is not level 1"
  if skillLevel(1000000.0) != MaxSkillLevel:
    failures.add "skills: the level is not clamped to elite"
  if not isElite(5100.0): failures.add "skills: 5100 progress is not elite"

  # The first points are worth the fresh multiplier, exactly.
  let fresh = grantedFor(5.0, 0.0, c)
  if not nearly(fresh, 5.0 * DefaultFreshEffectiveness):
    failures.add "skills: 5 fresh points paid " & $fresh & ", not 7.5"

  # Fatigue: the same claim made in one go must not beat the same claim made in
  # pieces. This is the exploit the point-by-point integration exists to close.
  let oneGo = grantedFor(400.0, 0.0, c)
  var piecewise = 0.0
  var k = 0
  while k < 40:
    piecewise = piecewise + grantedFor(10.0, piecewise, c)
    inc k
  if oneGo > piecewise + 0.5:
    failures.add "skills: one large claim (" & $oneGo & ") beat forty small " &
                 "ones (" & $piecewise & ")"
  if oneGo > c.perRaidCap + 0.001:
    failures.add "skills: a claim of 400 got " & $oneGo & ", past the cap"

  # A claim of a million is worth no more than the cap.
  let absurd = grantedFor(1000000.0, 0.0, c)
  if absurd > c.perRaidCap + 0.001:
    failures.add "skills: an absurd claim got " & $absurd & ", past the cap"

  # The delta, not the number. A client claiming it went from 0 to 50 when the
  # profile was already at 40 gains 10 raw, not 50.
  const pre = """[{"Id":"Endurance","Progress":40.0,
                   "PointsEarnedDuringSession":0.0,"LastAccess":0}]"""
  const post = """[{"Id":"Endurance","Progress":50.0}]"""
  var ups: seq[string] = @[]
  let outJson = applyRaidSkills(pre, post, c, 100, ups)
  let got = skillProgress(outJson, "Endurance")
  if not nearly(got, 40.0 + grantedFor(10.0, 0.0, c)):
    failures.add "skills: a 10-point delta on a 40-point skill produced " & $got

  # And a shrinking skill changes nothing.
  const shrunk = """[{"Id":"Endurance","Progress":5.0}]"""
  var ups2: seq[string] = @[]
  let outJson2 = applyRaidSkills(pre, shrunk, c, 100, ups2)
  if not nearly(skillProgress(outJson2, "Endurance"), 40.0):
    failures.add "skills: a raid that lost progress was applied"

  # A level crossing is reported, so a caller can post the mail for it.
  const nearLevel = """[{"Id":"Strength","Progress":95.0,
                         "PointsEarnedDuringSession":0.0}]"""
  const crossed = """[{"Id":"Strength","Progress":100.0}]"""
  var ups3: seq[string] = @[]
  discard applyRaidSkills(nearLevel, crossed, c, 100, ups3)
  if ups3.len != 1:
    failures.add "skills: crossing level 1 reported " & $ups3.len & " level-ups"

  # An empty database is an empty profile section, not a crash.
  var ups4: seq[string] = @[]
  let outJson4 = applyRaidSkills("[]", """[{"Id":"Perception","Progress":3.0}]""",
                                 c, 100, ups4)
  if skillProgress(outJson4, "Perception") <= 0.0:
    failures.add "skills: a first-ever gain on an empty profile was lost"
  var ups5: seq[string] = @[]
  discard applyRaidSkills("[]", "[]", c, 100, ups5)

  # Fatigue counters reset between raids.
  let reset = resetSession(outJson)
  if field(reset, "[0].PointsEarnedDuringSession").asFloat(-1.0) != 0.0:
    failures.add "skills: the session counter survived a reset"

  # Mastering: families out of the table, deltas capped, unknown weapons unnamed.
  const mtable = """[{"Name":"Ak","Templates":["tplAk","tplAkm"],
                      "Level2":10,"Level3":50}]"""
  if masteringForWeapon(mtable, "tplAkm") != "Ak":
    failures.add "mastering: tplAkm did not resolve to the Ak family"
  if masteringForWeapon(mtable, "tplMp5").len != 0:
    failures.add "mastering: an unlisted weapon resolved to a family"
  if masteringForWeapon("[]", "tplAk").len != 0:
    failures.add "mastering: an empty table resolved a family"
  if masteringLevel(mtable, "Ak", 0) != 1:
    failures.add "mastering: no progress is not level 1"
  if masteringLevel(mtable, "Ak", 10) != 2:
    failures.add "mastering: the Level2 threshold did not raise the level"
  if masteringLevel(mtable, "Ak", 500) != 3:
    failures.add "mastering: the Level3 threshold did not raise the level"

  let mOut = applyRaidMastering("""[{"Id":"Ak","Progress":5}]""",
                                """[{"Id":"Ak","Progress":9000}]""", 100)
  if field(mOut, "[0].Progress").asInt(0) != 105:
    failures.add "mastering: a 9000-point claim was not capped at 100"
  let mNew = applyRaidMastering("[]", """[{"Id":"Mp5","Progress":7}]""", 100)
  if field(mNew, "[0].Progress").asInt(0) != 7:
    failures.add "mastering: a first-ever family was not added"

  result = failures.len == before
