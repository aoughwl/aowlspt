## The checks the modules can make about themselves, and the one caller they
## have.
##
## Four of these existed and nothing called any of them: `loot.selfCheck`,
## `market.selfCheck`, `questcond.selfCheck` and `skills.selfCheckSkills`. They
## read like coverage in a review and were none — the same reason
## `selfCheckProduction` was deleted rather than kept. A check nobody runs is
## worse than no check, because it is *counted* as one.
##
## They are worth keeping, though, and this is why: each of them is over code
## with **no database, no host and no profile** in it — the flea's filter and
## sort, the loot generator over a fixture it carries, the quest condition
## evaluator over literals, and the skill curve. That is exactly the code
## `emutest` cannot reach precisely, because everything `emutest` sees has been
## through a route, a JSON encoder and the wire. `emutest` can tell that a
## search came back sorted; only `market.selfCheck` can tell that a category
## tree with a cycle in it terminates.
##
## So they run at **load**, and a failure refuses the load.
##
## That is the gate, and it is a real one rather than a printed line: nothing
## reads the server's log in a test, but `emutest`, `realtest`, `soak`,
## `fuzzwire` and every developer's own server all start by waiting for the
## first answer, and a mod that returns `ErrUnsupported` never gives one. A
## defect in any of this is a defect in pure arithmetic that no input can work
## around, so refusing to serve is the honest answer to it — a flea that sorts
## wrongly or a curve that pays the wrong number is not something to run a
## season on and find out later.
##
## The cost is a few milliseconds of the first load: the loot generator over its
## own small fixture is the expensive one, and it is three passes over a
## document of a dozen items.

import std/strutils
import loot
import market
import questcond
import skills
import progression
import health
import production
import gym
import customise
import tuning
import globalsgaps
import itemsgaps
import itemsadd
import mailcheck
import spawn
import loadout
import decorate
import dialogue
import insurance
import raid
import bots
import orbit

proc failedLines(report, label: string; into: var seq[string]) =
  ## `loot.selfCheck` and `questcond.selfCheck` report one line per check,
  ## `ok    ...` or `FAIL ...`. Read for the failures rather than compared
  ## against an expected transcript: the line count moves whenever a check is
  ## added, and a test that has to be edited to add a check is a test people
  ## stop adding checks to.
  for l in splitLines(report):
    if l.startsWith("FAIL"):
      into.add label & ": " & l

proc selfCheckFailures*(): seq[string] =
  ## Every failure, from every module that can be checked without a server.
  ## Empty is the only acceptable answer.
  result = @[]
  let marketFails = market.selfCheck()
  for f in marketFails:
    result.add "market: " & f
  # `selfCheckSkills` appends its own already-labelled failures, and returns
  # whether it added none. The return is discarded because the list is the
  # answer and a second way of saying the same thing can disagree with it.
  discard skills.selfCheckSkills(result)
  # Two more of the same shape: the price of a treatment at a trader and the
  # roll of a scav case are both pure arithmetic over a table, and both are
  # reachable through a route only on a database that carries the table -- which
  # the test fixture does not. Checking them here is the difference between
  # arithmetic that is pinned and arithmetic that is merely present.
  discard health.selfCheckHealth(result)
  discard production.selfCheckScavCase(result)
  # The gym's workout is the third of that shape: what a reported run of the
  # minigame is worth is pure arithmetic over one database entry, and the only
  # way to reach it through a route is on a database that carries `hideout.qte`.
  discard gym.selfCheckGym(result)
  # The progression floors: the family filter and the level<->experience maths.
  # Pure over the exp table, and the round trip is asserted rather than the
  # write, so an off-by-one in the cumulative sum fails here and not on screen.
  progression.selfCheckProgression(result)
  # And the fourth, with one difference worth naming here because it is the one
  # exception to this module's "no database" rule. `selfCheckCustomisation` is
  # pure over a literal table for the whole of the validator, and then -- only
  # when the loaded database actually carries `templates.customization` -- runs
  # the ids a new profile is created with through that same validator. It is
  # skipped entirely on a database without the table, so a server started on the
  # small fixture still loads; on a real one it is the check that catches a
  # default naming the wrong body part, which is the state those ids were in.
  discard customise.selfCheckCustomisation(result)
  # The two modules behind the expanded singleplayer surface. `tuning` proves
  # the generated override table parses and that a patched globals document
  # READS BACK correct -- not that the write happened, which is the check that
  # cannot fail. `spawn` proves every refusal path carries a reason.
  discard tuning.selfCheckTuning(result)
  # `globalsgaps` proves the twelve config members REAL BSG sends and our
  # pre-1.0 database does not are actually PRESENT in the finished document --
  # a negative over the merged text, plus the two ways a merge silently lies
  # (dropping what the database had, or overwriting it).
  discard globalsgaps.selfCheckGlobalsGaps(result)

  # `itemsgaps` proves the per-item `_props` members REAL BSG sends and our
  # pre-1.0 database lacks are spliced in at the right depth, without
  # overwriting the database and without inventing an item id.
  discard itemsgaps.selfCheckItemsGaps(result)
  # `itemsadd` proves the WHOLE item templates BSG serves and our pre-1.0
  # database lacks are spliced in as new ids, without overwriting an id the
  # database already has and without dropping a sibling -- the referential
  # hole that made the client throw "Cannot find template ... for item".
  discard itemsadd.selfCheckItemsAdd(result)
  discard spawn.selfCheckSpawn(result)
  # `loadout` is the automation library's gear minter. Its offline half proves
  # only what it can: that every DECLINING path names a reason, that a spec
  # which could not be looked at answers INCONCLUSIVE rather than PASS, and that
  # the report carries requested/minted/placed as three separate numbers. It
  # deliberately does NOT assert that gear arrived -- that needs a real profile,
  # and a check written to pass without one is the check that cannot fail.
  discard loadout.selfCheckLoadout(result)
  # `mailcheck` proves the served-mail payload check can FAIL. It is run on
  # the exact bad body measured in a live mailbox on 2026-08-28 -- a message
  # whose one attachment is the tpl of a stash -- and refuses the load if the
  # checker fails to notice it. A payload checker that has only ever been run
  # on good input is `return @[]` wearing a hat.
  discard mailcheck.selfCheckMail(result)
  # The fifth of that shape, and the one with two halves for the same reason
  # `selfCheckCustomisation` has two. The pure half is the whole of the hideout
  # decoration planner -- which offer resolves to which field of
  # `Hideout.Customization`, which conditions gate it, and which mannequin poses
  # are real -- against literal tables. The database half checks one invariant
  # over the real pair: that every one of `hideout.customisation`'s offers
  # agrees with `templates.customization` about what kind of thing it is. The
  # profile field written is *derived* from that agreement, so a table that
  # stops agreeing is a floor written into the ceiling's field, and it is
  # invisible anywhere but in the client's own hideout.
  discard decorate.selfCheckDecorate(result)
  # The sixth, and the one with no database half at all. `emu/dialogue` turns a
  # trader's own `dialogue` list into the sentence a player reads, and three
  # pieces of it are pure: the calendar behind `{date}` and `{time}` (written
  # out here because there is no `std/times` in this toolchain), the
  # placeholder filler that decides whether a line may be shown at all, and the
  # seeded pick that has to give the same line twice for a redelivery to say
  # what the first attempt said. None of it is reachable from `emutest`: the
  # fixtures carry no `dialogue`, so every route falls back to the plain
  # wording and a broken calendar would ship as `31.12.1969`.
  discard dialogue.selfCheckDialogue(result)
  # The seventh. `emu/insurance` is the only module here whose arithmetic is
  # over a *sequence* of raids rather than one call: what a raid lost, what the
  # payout took out of the cover, and what the raid after that must therefore
  # not lose again. The middle step did not exist -- nothing ever removed an id
  # from `InsuredItems` -- and the shape of the defect is why it is checked
  # here and not through a route: what went wrong was that a later raid queued
  # a return it should not have, and no request the client makes says "and
  # nothing else was posted". The closed loop is written out over literal
  # profiles instead.
  discard insurance.selfCheckInsurance(result)
  # The eighth, and the only one whose subject is what a route does *not* send.
  # `/client/locations` answered with the whole `locations` subtree spliced in
  # verbatim -- every map's `looseLoot` included -- which is 560 MiB and 10.8
  # seconds on an import that has loose loot, to draw a list of nineteen maps.
  # Nothing about that is visible from `emutest`: the response was correct, it
  # was merely enormous, and no request the client makes says "and nothing else
  # came back". So the check runs the map-list builder over a fixture that
  # deliberately carries a map's `looseLoot` and a `staticAmmo` table, and
  # asserts they are absent from what comes out -- along with the shape the
  # client's own type says it wants, a list keyed by `_Id`. The weather
  # fallback rides along for the same reason: no fixture carries a `weather`
  # table, so a table being silently ignored looks exactly like the constant.
  discard raid.selfCheckRaid(result)
  # The ninth, and the one whose whole subject is a *fixture* being wrong. Three
  # defects in `emu/bots` -- appearance weight maps read as lists, health
  # variants read as an object, and `bots.base` imported and never opened --
  # were all invisible from `emutest` for one reason: `tests/fixtures/emu-full.json`
  # is written in the shape the code expected rather than the shape the game
  # ships, so the fixture agreed with the bug. A check that carries its own
  # tables, in the real shape, is the only kind that could have caught them, and
  # it is the reason this one is here rather than on the wire.
  discard bots.selfCheckBots(result)
  # The tenth. `emu/orbit` is the ORBIT high-level half, and every part of it
  # that can be wrong without a raid running is arithmetic: the cell binning
  # function and the weighted centroid. The specific defect it guards is
  # `int(x / cell)` truncating toward zero, which folds the negative half of
  # every map onto the positive half and puts a whole map's anchors in one
  # quadrant -- a bug that produces a plausible plan, not an error.
  discard orbit.selfCheckOrbit(result)
  failedLines(loot.selfCheck(), "loot", result)
  failedLines(questcond.selfCheck(), "questcond", result)
