## Achievements, awarded rather than merely listed.
##
## `/client/achievement/list` has always handed over `templates.achievements`,
## and `/client/achievement/statistic` has always answered an empty `elements`
## map, so the achievements screen drew the whole set and none of them was ever
## obtained. This is the other half.
##
## ## It is the quest machinery, with a different table
##
## The reference makes this cheap: `Achievement.Conditions` is an
## `AchievementQuestConditionTypes`, which is the same five condition groups a
## `Quest` has and the same `QuestCondition` inside them, and
## `Achievement.Rewards` is the same `Reward` list. So the evaluator is
## `emu/questcond` unchanged and the payout is `grantRewardList` in
## `emu/quests` -- the one the quest payout itself now goes through.
##
## What the profile keeps is the reference's `Dictionary<MongoId, Int64>` at
## `Achievements`: the id of each achievement obtained, against the moment it
## was obtained. That is also the "already awarded?" test, and it is a complete
## one -- there is no second place an award is recorded, so there is nothing for
## it to disagree with.
##
## ## Nothing is awarded for a condition that was not checked
##
## `groupMet` counts the conditions it had no evaluator for and reports them
## separately, and this refuses to award on a non-zero count. That is the same
## rule `questcond.killCredit` applies to a qualifier it cannot check, for the
## same reason in the opposite direction: a quest that will not complete is
## visible and a reward paid for nothing is not.
##
## An achievement with an **empty** finish group is refused too. The live table
## has entries whose conditions this server's evaluator reduces to nothing, and
## "every condition is met" is trivially true of none of them -- which would
## award the whole set on the first raid a player finished.
##
## ## When it runs
##
## After a raid, and after a quest is handed in. Both are moments the profile
## has just changed in a way an achievement condition reads -- counters, level,
## trader standing, quest status -- and both already re-read the profile, so
## this costs one pass over the achievement table on each rather than a timer.
## It is deliberately *not* run on every item event: the table is a few hundred
## entries and the stash is dragged in thousands of times per session.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import profile
import templates
import questcond
import quests
import mail

proc obtained*(p: Profile): Doc =
  result = parseObject(p.field("Achievements").raw())
  if not result.ok:
    result = newDoc()

proc hasAchievement*(p: Profile; id: string): bool =
  result = has(obtained(p), id)

proc achievementName(tpl: string): string =
  ## What to call it in a log line and in the reward message. The table carries
  ## a localisation key rather than a name, so the id is the honest fallback --
  ## an empty label in the player's inbox is worse than an ugly one.
  let n = field(tpl, "name")
  if n.found and n.asText("").len > 0:
    return n.asText("")
  result = field(tpl, "id").asText("")

proc awardAchievements*(p: var Profile; nowSeconds: int;
                        awarded: var seq[string]): int =
  ## Evaluates every achievement the profile does not have, awards the ones
  ## whose finish conditions are all met and all checkable, and returns how many
  ## were awarded. Any experience they carry is added to the profile here, so
  ## the caller has one thing to do with the result: save it.
  awarded = @[]
  result = 0
  let table = dbRead("templates.achievements")
  if not table.ok or table.raw.len == 0:
    return
  let list = whole(table.raw)
  if not isArray(list):
    # `GetAchievementsResponse.Elements` is a list, and a database that keyed it
    # by id instead would silently evaluate nothing. Said out loud rather than
    # returning zero.
    warn "templates.achievements is not a list; no achievement can be awarded"
    return

  var held = obtained(p)
  var changed = false
  for entry in each(list):
    let tpl = raw(entry)
    let id = entry.field("id").asText("")
    if id.len == 0:
      continue
    if has(held, id):
      continue
    let conds = conditionsOf(tpl, cgFinish)
    if conds.len == 0:
      # Nothing to meet is not the same as everything met -- see the header.
      continue
    var reason = ""
    var unchecked = 0
    if not groupMet(p.text, id, tpl, cgFinish, reason, unchecked):
      continue
    if unchecked > 0:
      # Named, once per achievement per pass, because an achievement that can
      # never be awarded on this server is a thing a player will ask about.
      info "achievement " & achievementName(tpl) & " has " & $unchecked &
           " condition(s) this server cannot evaluate; not awarding it"
      continue
    setNumber(held, id, nowSeconds)
    changed = true
    inc result
    awarded.add id
    var experience = 0
    # `Achievement.Rewards` is a flat list, where a quest's is keyed by
    # outcome -- see `rewardList`.
    let notes = grantRewardList(p, rewardList(field(tpl, "rewards")),
                                "", achievementName(tpl), mkSystem,
                                nowSeconds, experience)
    for n in notes:
      warn "achievement " & achievementName(tpl) & ": " & n
    if experience > 0:
      addExperience(p, experience)
    success "achievement obtained: " & achievementName(tpl)
  if changed:
    p.setTopLevel("Achievements", text(held))

proc completedStatistics*(ids: seq[string]): string =
  ## `CompletedAchievementsResponse.Elements` -- `{achievementId: count}`.
  ##
  ## The reference gives the shape and not the meaning of the number, and the
  ## real server's is a population statistic: how many accounts hold each
  ## achievement. On a server whose population is the profiles in its own store,
  ## that is exactly countable, so it is counted rather than faked -- one on the
  ## achievements this account has, and no entry at all for the rest, which is
  ## what "nobody has done this" looks like.
  var o = obj()
  var seen: seq[string] = @[]
  var counts: seq[int] = @[]
  for id in ids:
    var at = -1
    for k in 0 ..< seen.len:
      if seen[k] == id:
        at = k
    if at < 0:
      seen.add id
      counts.add 1
    else:
      counts[at] = counts[at] + 1
  for k in 0 ..< seen.len:
    put(o, seen[k], counts[k])
  result = done(o).text
