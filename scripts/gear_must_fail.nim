## gear_must_fail -- the acceptance test FOR THE LIBRARY ITSELF.
##
##     .\installer\build\aowl.exe script scripts\gear_must_fail.nim
##
## CLAUDE.md 9b: a verification that cannot fail IS the bug. The gear check in
## `autoscript` claims it can tell "the loadout arrived" from "the loadout did
## not". This script is the input that makes it say NO.
##
## It asks for a **rifle in the Headwear slot**. `emu/bots.validateSlots` -- the
## ancestry-aware validator, the same one the bot generator runs -- refuses that
## placement, the item is dropped before the profile is saved, and the read-back
## finds nothing there. The expected transcript is:
##
##     GEAR    requested=1 minted=1 placed=0 slotDropped=1 flatStacks=0
##       ! validateSlots: slot refused: 5447a9cd4bdc2dbd208b4567 -> Headwear
##                        on 55d7217a4bdc2d86028b456d
##     GEAR    FAIL  asked for 1, minted 1, read back 0; 1 refusal(s)
##
##     === gear-must-fail: FAIL ===
##
## and the process exits **1**.
##
## So this script INVERTS the verdict: it exits 0 when the gear check said FAIL,
## and 1 when it said anything else. A PASS here would mean the gear check
## reported success for gear that is provably not on the profile -- which is the
## exact defect this file exists to catch, and it is louder as a failing test
## than as a paragraph in a doc.
##
## `attachOnly` -- it drives a stack that is already up and never launches the
## client, because it has nothing to do with a raid. It also never reaches the
## raid steps at all: `run` stops at the first step that is not PASS.
##
## Note the three-outcome discipline survives the inversion. If the gear step
## came back INCONCLUSIVE -- no backend, no profile, an install whose tarkov.dll
## predates this feature -- that is NOT a pass either. The question was not
## asked, and this script says so and exits 2.

import autoscript

proc main() =
  var s = newScript("gear-must-fail")
  attachOnly(s)

  # A Colt M4A1 in the helmet slot. Not a typo: the point.
  equip(s, "Headwear", "5447a9cd4bdc2dbd208b4567")

  if not launchStack(s):
    note(s, "no backend to ask -- INCONCLUSIVE, not a pass")
    quitWith(2)
  if not pickProfile(s):
    note(s, "no profile to mint into -- INCONCLUSIVE, not a pass")
    quitWith(2)

  let gearSaidOk = applyGear(s)
  if gearSaidOk:
    note(s, "DEFECT: the gear check reported PASS for a rifle in the " &
            "Headwear slot. It cannot distinguish gear that arrived from " &
            "gear that did not, which makes every other PASS it has ever " &
            "printed meaningless.")
    quitWith(1)
  if verdictOf(s) == "INCONCLUSIVE":
    note(s, "the gear check could not look (" & reasonOf(s) &
            ") -- INCONCLUSIVE, not a pass")
    quitWith(2)
  note(s, "the gear check correctly refused a rifle in the Headwear slot " &
          "and reported FAIL. The check can fail, so its passes mean " &
          "something.")
  quitWith(0)

main()
