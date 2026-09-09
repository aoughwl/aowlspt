## ammoloading_e2e -- THE WHOLE POINT, in one file.
##
##     .\installer\build\aowl.exe script scripts\ammoloading_e2e.nim
##
## "I shouldn't have to unload the magazine and reload the ammo for something to
## trigger for you to observe." This script does that, with nobody at the
## keyboard: it mints a weapon and a loaded magazine, enters an offline raid,
## waits for the raid-phase LATCH to say DEPLOYED, unloads and reloads the
## magazine through `pact`, and then asks `mods/ammoloading` whether it SAW it.
##
## WHAT EACH VERDICT MEANS, AND WHY THEY MUST BE DIFFERENT
## -------------------------------------------------------
## Every stage names itself, because "it didn't work" is four different problems:
##
##   STACK  INCONCLUSIVE   the backend never came up; nothing was tested
##   GEAR   FAIL           the weapon or magazine did not read back after
##                         minting -- there was nothing to cycle. Two distinct
##                         sub-cases, and they are NOT collapsed:
##                           magPlaced=0    no magazine is in the weapon's
##                                          mod_magazine slot on the saved
##                                          profile; GetCurrentMagazine() will
##                                          read null in raid
##                           roundsPlaced=0 the magazine IS mounted and holds
##                                          nothing; a reload test against an
##                                          empty magazine proves nothing
##   DEPLOY INCONCLUSIVE   the latch never reported (needs debugEsp + natEsp +
##                         natEspDiag, read at boot)
##   DEPLOY FAIL           the latch reported another phase and never DEPLOYED
##   PACT   INCONCLUSIVE   the request never reached the host -- the inspector
##                         channel is off. THE SCRIPT DID NOT RUN.
##   PACT   FAIL           pact REFUSED it and its own line says why (no firearm
##                         in hands, not deployed, a hop that did not validate)
##   MAGCYC FAIL           the cycle was ISSUED and Magazine.Count did not come
##                         back. A partial load lands here on purpose.
##   AMMOLD FAIL           the cycle completed and mods/ammoloading is ARMED but
##                         NEVER FIRED. **THIS IS THE VERDICT THIS SCRIPT EXISTS
##                         TO BE ABLE TO PRODUCE.** The mod did not see it.
##   AMMOLD INCONCLUSIVE   the mod says NOT ARMED, or says nothing -- no hook is
##                         installed, so its zero counter means nothing
##
## "The script did not run" (INCONCLUSIVE, exit 2) and "the mod never fired"
## (FAIL, exit 1) are deliberately different exit codes.
##
## THE RUNG
## --------
## `probe` -- install the verified prefix on `LoadMagazineProcess::Start` and
## COUNT firings, with zero dereferences. It is the rung that proves the TRIGGER
## fires, which is the thing that has never been demonstrated. `spawn` and
## `animate` additionally need a bundle riding a vanilla key via mods/textures,
## which is not set up, and asking for them here would make this test fail for a
## reason that has nothing to do with the trigger.
##
## THE TEMPLATE IDS -- pasted, not searched; see woods_pmc_m4.nim for why.
##   5447a9cd4bdc2dbd208b4567  Colt M4A1 5.56x45 assault rifle
##   55d4887d4bdc2d962f8b4570  Colt M4A1 STANAG 30-round magazine
##   54527ac44bdc2d36668b4567  5.56x45mm M855A1
##   5ab8dced86f774646209ec87  ANA Tactical M1 armored rig

import autoscript

proc main() =
  var s = newScript("ammoloading-e2e")

  onMap(s, "Factory")   # the smallest map, so the load is the shortest
  asSide(s, "pmc")

  # Arm BEFORE the launch. Both of these are read at boot: the host flags by the
  # host, the rung by the mod when it loads. Declaring them after the client is
  # up would write a file that says "on" over a process that is off.
  withActuation(s)
  withAmmoLoading(s, "probe")

  # The rig first, then what goes in it -- requests apply in declaration order.
  equip(s, "TacticalVest", "5ab8dced86f774646209ec87")

  # THE WEAPON MUST HAVE A MAGAZINE IN IT. `pact`'s chain is
  # HasFirearmInHands -> get_HandsController -> get_Item -> GetCurrentMagazine,
  # and an empty weapon refuses at the fourth hop with "no current magazine" --
  # a correct refusal that would nevertheless make this test fail for a gear
  # reason while looking like an actuation one.
  #
  # It is no longer unverified, and `equipLoaded` was the wrong verb. MEASURED
  # against this install's db.json:
  #
  #   5447a9cd4bdc2dbd208b4567 (M4A1)   _props.Chambers[0]._name =
  #                                     "patron_in_weapon"; NO _props.Cartridges
  #   55d4887d4bdc2d962f8b4570 (STANAG) _props.Cartridges[0]._max_count = 30
  #
  # So `equipLoaded` on the WEAPON asked the backend for a cartridge capacity a
  # weapon does not have. It was REFUSED -- "the database declares no
  # _props.Cartridges[0]._max_count" -- and even if it had not been, nothing was
  # ever mounted in the weapon's `mod_magazine` slot. That is exactly why
  # `GetCurrentMagazine()` came back null and this test could never reach the
  # thing it exists to measure.
  #
  # `equipWeapon` mounts a NAMED magazine (the M4A1's mod_magazine filter admits
  # 20 templates; picking one by document order is the guess this library
  # refuses), loads it, and chambers a round. The acceptance is a walk of the
  # saved profile: `magPlaced` and `roundsPlaced` are separate FAILs, so an empty
  # magazine cannot pass as a loaded one.
  equipWeapon(s, "FirstPrimaryWeapon", "5447a9cd4bdc2dbd208b4567",
              "55d4887d4bdc2d962f8b4570", "54527ac44bdc2d36668b4567")

  # Spares in the rig, so the unload has somewhere to put 30 rounds. The unload
  # moves ammunition into the inventory; a character with nowhere to put it is a
  # cycle that fails at UnloadMagazine for a container reason.
  carryLoaded(s, "TacticalVest", "55d4887d4bdc2d962f8b4570", 2,
              "54527ac44bdc2d36668b4567")
  stock(s, "54527ac44bdc2d36668b4567", 120)

  if runToRaid(s):
    # In a live raid. Let the weapon finish being drawn before touching it: a
    # magazine cycle issued during the deploy animation refuses at
    # HasFirearmInHands, which is a TIMING answer wearing a capability answer's
    # clothes.
    discard pactDo(s, "wait 300", 20)
    pactStatusNote(s)

    if magCycle(s, 60):
      discard assertAmmoLoadingFired(s, 40)
    pactStatusNote(s)

  quitWith(finish(s))

main()
