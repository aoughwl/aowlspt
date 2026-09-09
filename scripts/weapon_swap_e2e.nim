## weapon_swap_e2e -- ONE COMMAND: launch, mint two weapons, enter a raid,
## swap between them, and prove the swap by reading what is really in hands.
##
##     aowl script scripts\weapon_swap_e2e.nim
##
## Nobody touches the keyboard, and nobody buys a rifle or a pistol first.
##
## ===========================================================================
## WHAT THIS PROVES, AND HOW IT CAN FAIL
## ===========================================================================
##
## The verdict comes from `FirearmController::get_Item` -- the weapon object the
## GAME says is in the player's hands -- read 45 drain frames after each swap
## command and compared, by pointer, with the one held when the command went
## out. It is NOT the translate result. `ETranslateResult` says the input system
## consumed a keypress; it says so just as loudly when the player ends up
## holding exactly what they were holding before, which is the whole failure
## mode this script exists to be able to catch.
##
## THE INPUT THAT MAKES IT FAIL: delete the `swapWeaponAndSee(s, "secondary")`
## below and leave only the swap back to "primary". The player is already
## holding the primary, the command translates, the same item comes back, the
## host counts `noeffect`, and the run reports FAIL. That is why the script
## swaps AWAY first -- not for realism, but so the assertion has something to
## be wrong about.
##
## A SECOND, INDEPENDENT LEG: after swapping back to the rifle, it runs the
## user's own example -- unload the magazine and load the ammunition back -- and
## takes its verdict from the game's own `Magazine.Count`. The two legs use
## different receivers and different readbacks, so one passing does not make the
## other pass.
##
## ===========================================================================
## THE HANDSHAKE
## ===========================================================================
##
## `swapWeaponAndSee` declares that it needs the host's `swap` verb, and
## `equipWeapon` declares that it needs the backend's `magazine` capability.
## `run`/`runToRaid` ask the DEPLOYED install for both before minting anything.
## Against a stale `D:\Aowlspt` this script REFUSES by name -- it does not mint
## a rifle with no magazine and then report a swap that never had two weapons to
## swap between.

import autoscript

proc main() =
  var s = newScript("weapon-swap-e2e")

  onMap(s, "Factory")   # the smallest map, so the load is the shortest
  asSide(s, "pmc")
  withActuation(s)

  # The rig first, then what goes in it: requests apply in declaration order and
  # "nothing is worn in TacticalVest" is the refusal you get otherwise.
  equip(s, "TacticalVest", "5ab8dced86f774646209ec87")   # ANA M1

  # TWO weapons, because a swap needs somewhere to swap TO. A script that minted
  # one and then asserted a swap would be asserting against an empty holster,
  # and the failure would read as a broken ECommand channel rather than as a
  # loadout that never had a second gun.
  equipWeapon(s, "FirstPrimaryWeapon",
              "5447a9cd4bdc2dbd208b4567",     # M4A1
              "55d4887d4bdc2d962f8b4570",     # STANAG in mod_magazine
              "54527ac44bdc2d36668b4567")     # loaded with M855A1
  equipWeapon(s, "Holster",
              "56d59856d2720bd8418b456a",     # P226R
              "56d59948d2720bb7418b4582",     # its 15-round magazine
              "56d59d3ad2720bdb418b4577")     # loaded with 9x19 PST gzh

  # Spare magazines in the rig, so the unload half of the cycle has somewhere to
  # put 30 rounds. A character with nowhere to put them fails at UnloadMagazine
  # for a container reason that looks nothing like a container reason.
  carryLoaded(s, "TacticalVest", "55d4887d4bdc2d962f8b4570", 2,
              "54527ac44bdc2d36668b4567")
  stock(s, "54527ac44bdc2d36668b4567", 120)

  if runToRaid(s):
    # Let the deploy animation finish before touching the hands. A swap issued
    # while the weapon is still being drawn refuses at HasFirearmInHands, which
    # is a TIMING answer wearing a capability answer's clothes.
    discard pactDo(s, "wait 300", 20)
    pactStatusNote(s)

    # AWAY first. This is the leg that can fail honestly: the player is holding
    # the rifle, so a sidearm must arrive for get_Item to read differently.
    if swapWeaponAndSee(s, "secondary", 6):
      # …and BACK. Independently falsifiable for the same reason in reverse.
      discard swapWeaponAndSee(s, "primary", 6)

    # Different receivers and different readbacks, so none of these can pass on
    # the strength of another. Sprint is `Player::get_IsSprintEnabled`; the look
    # is `MovementContext::get_Rotation`, degrees the game itself holds.
    discard lookAndSee(s, 45.0, 0.0, 5)
    discard lookAndSee(s, -45.0, 0.0, 5)
    discard sprintAndSee(s, true, 4)
    discard sprintAndSee(s, false, 4)

    # THE USER'S OWN EXAMPLE, with nobody at the keyboard.
    discard magCycle(s, 60)
    pactStatusNote(s)

  quitWith(finish(s))

main()
