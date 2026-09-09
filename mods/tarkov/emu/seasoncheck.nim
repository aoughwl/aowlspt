## The invariants the seasonal event data has to satisfy, and the reason they
## are asserted here rather than discovered on screen.
##
## `/client/season/active` serves `data/post1/seasonactive.json` and
## `/client/seasonal-perks/list` serves two empty perk lists. The profile
## carries `SeasonalRewards` as a dictionary keyed by reward id. Those three are
## the only places a seasonal id appears, and NOTHING checked that they agreed:
## a reward whose `seasonId` names a season we do not serve, or a profile record
## keyed by a reward id that is not in the served season, is a dangling
## reference the client resolves to nothing.
##
## What this does NOT claim
## ------------------------
## This was written while chasing an access violation in
## `EFT.UI.SeasonWidgetData::From` @0x141ffd0, on the hypothesis that the client
## was indexing the seasonal rewards by a -1 that the served data had produced.
## That hypothesis is FALSE, and the disassembly is the reason (see
## `docs/AOWL_FACTS.md`): `From` null-checks `profile` at +0x116 and
## `profile.BattlePass` (Profile@0x118) at +0x11f before touching either, and
## null-checks `seasonalRewardController` and its `SeasonalRewards` book at
## +0x342/+0x34b. The only indexing in the whole body is a dictionary bucket
## walk. There is no data hole this module can close that would have prevented
## that crash.
##
## So these checks are DEFENSIVE, not a fix, and saying so is the point -- a
## check advertised as a fix for something it cannot affect is worse than no
## check at all.
##
## Every assertion here is over the FINISHED document and is phrased as a
## negative ("no reward references a season other than the served one"), and the
## two validators carry POSITIVE CONTROLS: each is run over a literal that is
## deliberately broken and must report exactly the failures that literal
## contains. A validator that answers "0 problems" on a document built to
## contain problems is the defect this file is guarding against, so it fails
## the load the same way a real violation does.

import aowlspt
import aowlspt/json
import post1

proc oneLine(xs: seq[string]): string =
  ## `strutils.join` is not relied on here: this module runs at load and a
  ## missing overload in the nimony stdlib would take the whole server down for
  ## a diagnostic string. Three lines is cheaper than that risk.
  result = ""
  var first = true
  for x in xs:
    if not first: result.add " | "
    result.add x
    first = false

proc badSeasonRewards*(seasonJson: string; into: var seq[string]): bool =
  ## Every violation of the season document's own internal consistency.
  ##
  ## Pure over the text it is handed -- no file, no profile, no server -- which
  ## is what lets the positive control below feed it a broken literal.
  ##
  ## Returns true when the document is clean. `into` gains one line per
  ## violation, never a summary line, because a count that says "3 problems"
  ## and a list that names two is a disagreement waiting to happen.
  result = true
  let root = whole(seasonJson)
  if not root.exists or not root.isObject:
    into.add "season: payload did not parse as a JSON object"
    return false
  let season = root.child("season")
  if not season.exists or not season.isObject:
    into.add "season: no `season` object in the payload"
    return false

  let id = season.child("id").asText("")
  if id.len == 0:
    into.add "season: the season carries no `id`"
    result = false

  # A season whose window is inverted is not a season the client can ever
  # consider active. Asserted as an ordering, not against a wall clock: the
  # captured event is historical on purpose (see `onSeasonActive`) and a check
  # against `now` would fail every day for a reason that is not a defect.
  let startTs = season.child("startTs").asInt(0)
  let endTs = season.child("endTs").asInt(0)
  if startTs == 0 or endTs == 0:
    into.add "season: startTs/endTs missing -- the client cannot window it"
    result = false
  elif endTs <= startTs:
    into.add "season: endTs (" & $endTs & ") is not after startTs (" &
             $startTs & ")"
    result = false

  let rewards = season.child("seasonalRewards")
  if not rewards.exists or not rewards.isArray:
    into.add "season: `seasonalRewards` is missing or is not an array"
    return false

  var seen: seq[string] = @[]
  for r in each(rewards):
    if not r.isObject:
      into.add "season: a `seasonalRewards` element is not an object"
      result = false
      continue
    let rid = r.child("id").asText("")
    if rid.len == 0:
      into.add "season: a seasonal reward carries no `id`"
      result = false
    else:
      var dup = false
      for s in seen:
        if s == rid: dup = true
      if dup:
        into.add "season: seasonal reward id '" & rid &
                 "' appears more than once -- a by-id lookup is ambiguous"
        result = false
      else:
        seen.add rid
    # The dangling reference this module exists for.
    let sid = r.child("seasonId").asText("")
    if id.len > 0 and sid != id:
      into.add "season: reward '" & rid & "' has seasonId '" & sid &
               "', which is not the served season '" & id & "'"
      result = false

proc unknownRewardKeys*(profileSeasonalRewards, seasonJson: string): seq[string] =
  ## The keys of a profile's `SeasonalRewards` dictionary that name a reward the
  ## served season does NOT contain.
  ##
  ## Empty is clean. A fresh profile serves `{}` here, so on today's data this
  ## returns empty for a reason that has nothing to do with the invariant
  ## holding -- which is exactly why the positive control below exists. Without
  ## it this would be a check that cannot fail (CLAUDE.md 9b).
  result = @[]
  let prof = whole(profileSeasonalRewards)
  if not prof.exists or not prof.isObject:
    return
  var known: seq[string] = @[]
  let season = whole(seasonJson).child("season")
  for r in each(season.child("seasonalRewards")):
    let rid = r.child("id").asText("")
    if rid.len > 0: known.add rid
  for k in keys(prof):
    var found = false
    for s in known:
      if s == k: found = true
    if not found:
      result.add k

# --------------------------------------------------------------- the gate

const BrokenSeason = """{"season":{"id":"AAA","startTs":10,"endTs":20,
  "seasonalRewards":[{"id":"r1","seasonId":"AAA"},
                     {"id":"r2","seasonId":"BBB"},
                     {"id":"r1","seasonId":"AAA"},
                     {"seasonId":"AAA"}]}}"""

const GoodSeason = """{"season":{"id":"AAA","startTs":10,"endTs":20,
  "seasonalRewards":[{"id":"r1","seasonId":"AAA"}]}}"""

proc selfCheckSeason*(into: var seq[string]): bool =
  ## The positive controls first, then the real document.
  result = true

  # Control 1: the broken literal carries exactly three violations -- a wrong
  # seasonId, a duplicate id, and a reward with no id. Fewer than three means
  # `badSeasonRewards` is not looking; more means it is inventing.
  var control: seq[string] = @[]
  if badSeasonRewards(BrokenSeason, control):
    into.add "season selfcheck: badSeasonRewards passed a document built to " &
             "fail -- the validator is not looking, so its verdict on the " &
             "real season means nothing"
    result = false
  elif control.len != 3:
    into.add "season selfcheck: badSeasonRewards found " & $control.len &
             " violation(s) in a literal that contains exactly 3: " &
             oneLine(control)
    result = false

  # Control 2: and it must not fire on a clean one.
  var clean: seq[string] = @[]
  if not badSeasonRewards(GoodSeason, clean):
    into.add "season selfcheck: badSeasonRewards rejected a clean literal: " &
             oneLine(clean)
    result = false

  # Control 3: the profile-side invariant, which is vacuous on today's `{}`.
  let dangling = unknownRewardKeys("""{"r1":{},"nope":{}}""", GoodSeason)
  if dangling.len != 1 or dangling[0] != "nope":
    into.add "season selfcheck: unknownRewardKeys returned " &
             $dangling.len & " key(s) where exactly ['nope'] was planted"
    result = false
  if unknownRewardKeys("{}", GoodSeason).len != 0:
    into.add "season selfcheck: unknownRewardKeys flagged a key in an empty " &
             "dictionary"
    result = false

  # Now the served document. A missing file is NOT a failure: `onSeasonActive`
  # falls back to `{}` by design, and refusing the whole load because an
  # optional capture is not installed would be a worse outcome than the empty
  # season the client already tolerates. It is reported, not fatal.
  let table = post1Table("seasonactive")
  if table.len == 0:
    into.add "season: data/post1/seasonactive.json is not installed " &
             "(the route falls back to `{}`; this is a note, not a failure)"
    return result
  if not badSeasonRewards(table, into):
    result = false
