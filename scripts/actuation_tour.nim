## actuation_tour -- every player-actuation verb, in one run, each with its own
## three-valued verdict.
##
##     .\installer\build\aowl.exe script scripts\actuation_tour.nim
##
## This is the reference script for `docs/PLAYER_ACTUATION.md`: it exercises the
## whole surface -- gear, entry, movement, look, stance, aim, fire, reload, and
## the magazine unload/load cycle -- with nobody at the keyboard.
##
## WHAT IT PROVES, AND WHAT IT DOES NOT
## ------------------------------------
## Read this before believing a green run. The verbs are NOT equally strong, and
## the library refuses to pretend they are.
##
##   walkAndSee   PROVES movement. pact re-reads `EFT.Player::get_Position` --
##                the game's own number -- and reports metres actually travelled.
##                `took` rising is the finished state having changed.
##   magCycle     PROVES a magazine cycle. The completion line carries the game's
##                own `Magazine.Count` readback, which this library never writes.
##   everything   ISSUE-ONLY. pact has no readback for rotation, trigger, aim,
##   else         stance or the ECommand channel today, so a PASS on `look`,
##                `fire`, `aim`, `pose`, `lean`, `prone`, `jump`, `sprint`,
##                `command` or `reload` means THE HOST ACCEPTED THE CALL and
##                nothing more. It is not evidence the camera turned or the gun
##                fired.
##
## That asymmetry is deliberately visible in the transcript rather than smoothed
## over: an issue-only PASS that read like a verified one would be precisely the
## check that cannot fail.
##
## `actuated(s, "look 15 0")` will therefore report INCONCLUSIVE, "no readback
## counter moved". That is the correct answer -- nothing was measured -- and it
## is the honest thing to see in a report until pact grows a rotation readback.
##
## TEMPLATE IDS -- pasted, not searched; see woods_pmc_m4.nim for why.
##   5447a9cd4bdc2dbd208b4567  Colt M4A1 5.56x45 assault rifle
##   55d4887d4bdc2d962f8b4570  Colt M4A1 STANAG 30-round magazine
##   54527ac44bdc2d36668b4567  5.56x45mm M855A1
##   5ab8dced86f774646209ec87  ANA Tactical M1 armored rig

import autoscript

proc main() =
  var s = newScript("actuation-tour")

  onMap(s, "Factory")     # smallest map, shortest load
  asSide(s, "pmc")
  withActuation(s)        # arms playerActuation + liveInspector + write, at BOOT

  # Declaration order matters: the rig must exist before anything goes in it.
  equip(s, "TacticalVest", "5ab8dced86f774646209ec87")
  equipWeapon(s, "FirstPrimaryWeapon", "5447a9cd4bdc2dbd208b4567",
              "55d4887d4bdc2d962f8b4570", "54527ac44bdc2d36668b4567")
  carryLoaded(s, "TacticalVest", "55d4887d4bdc2d962f8b4570", 2,
              "54527ac44bdc2d36668b4567")
  stock(s, "54527ac44bdc2d36668b4567", 120)

  if runToRaid(s):
    # Let the deploy animation finish. A verb issued while the weapon is still
    # being drawn refuses at HasFirearmInHands -- a TIMING answer wearing a
    # capability answer's clothes.
    discard pactWait(s, 300)
    pactStatusNote(s)

    # ---- movement: the one thing that is genuinely VERIFIED ---------------
    # Forward at full input for 90 frames, then assert metres travelled.
    discard walkAndSee(s, 0.0, 1.0, 90)
    # Strafe back, so the tour does not walk the character off the map.
    discard walkAndSee(s, 0.0, -1.0, 90)

    # ---- look / stance / weapon handling: ISSUE-ONLY ----------------------
    # Each of these reports PASS on ACCEPTANCE. Do not read them as effects.
    discard look(s, 30.0, 0.0)
    discard look(s, -30.0, 0.0)
    discard pose(s, -1.0)          # crouch
    discard pose(s, 1.0)           # stand back up
    discard lean(s, 1.0)
    discard lean(s, 0.0)
    discard sprint(s, true)
    discard sprint(s, false)
    discard aim(s, true)
    discard aim(s, false)

    # ---- the trigger -----------------------------------------------------
    # Held, then RELEASED. A `fire on` with no matching `fire off` leaves the
    # trigger down for the rest of the raid, which corrupts every later verb.
    discard fire(s, true)
    discard pactWait(s, 20)
    discard fire(s, false)

    # ---- THE USER'S OWN EXAMPLE ------------------------------------------
    # Unload the magazine and load the ammunition back, with nobody at the
    # keyboard. Verified: the completion line carries the game's own
    # Magazine.Count.
    discard magCycle(s, 60)

    # The reload KEY is a different channel (ECommand through the captured
    # GamePlayerOwner) and can be unavailable on its own. Issue-only.
    discard reload(s)

    pactStatusNote(s)

  quitWith(finish(s))

main()
