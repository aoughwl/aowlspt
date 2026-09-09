## woods_pmc_m4 -- the worked example.
##
## "Go into Woods as a PMC with an M4A1, three loaded magazines, an Altyn, a rig,
## two IFAKs and 180 spare rounds, and tell me whether that actually happened."
##
##     .\installer\build\aowl.exe script scripts\woods_pmc_m4.nim
##
## `aowl script` builds this file and RUNS it. Running it starts the backend and
## the client if they are not already up, waits for the backend's control port to
## answer, picks the profile, mints the gear, drives the menu into an offline
## raid on Woods, waits for the host's raid-phase latch to say DEPLOYED, and
## exits 0 PASS / 1 FAIL / 2 INCONCLUSIVE.
##
## THE TEMPLATE IDS
## ----------------
## Pasted rather than searched, because an id is exact and free while a name
## search is a 2.7 MB scan whose AMBIGUOUS answers this library refuses on
## purpose. `byName(s, "bandage", 2)` exists for when a name is unambiguous, and
## the refusal names the candidates when it is not.
##
##   5447a9cd4bdc2dbd208b4567  Colt M4A1 5.56x45 assault rifle
##   55d4887d4bdc2d962f8b4570  Colt M4A1 5.56x45 STANAG 30-round magazine
##   54527ac44bdc2d36668b4567  5.56x45mm M855A1
##   5aa7e276e5b5b000171d0647  Altyn bulletproof helmet
##   5ab8dced86f774646209ec87  ANA Tactical M1 armored rig
##   590c678286f77426c9660122  IFAK personal tactical first aid kit
##
## ORDER MATTERS, AND IT IS NOT A STYLE RULE
## -----------------------------------------
## The rig is equipped BEFORE the magazines that go inside it. Requests are
## applied in declaration order, and a `carry` into an empty slot is refused with
## "nothing is worn in TacticalVest" -- named, not silent, but still a FAIL.

import autoscript

proc main() =
  var s = newScript("woods-pmc-m4")

  onMap(s, "Woods")
  asSide(s, "pmc")

  # Worn. `clear` defaults true, so the character is stripped first and these
  # slots are guaranteed empty -- "the slot is already occupied" is the most
  # common way a loadout silently does not arrive.
  equip(s, "Headwear", "5aa7e276e5b5b000171d0647")
  equip(s, "TacticalVest", "5ab8dced86f774646209ec87")
  equip(s, "FirstPrimaryWeapon", "5447a9cd4bdc2dbd208b4567")

  # In the rig. Each magazine is filled to the capacity its own template
  # declares, with a round its own cartridge filter accepts -- a mag "filled"
  # with ammo the filter omits is a gun that spawns empty, and that is refused
  # with a reason rather than written.
  carryLoaded(s, "TacticalVest", "55d4887d4bdc2d962f8b4570", 3,
              "54527ac44bdc2d36668b4567")

  # Also in the rig, not the pockets. MEASURED, 2026-08-31, against the live
  # db.json: `clear` deliberately exempts Pockets -- a character with no Pockets
  # item does not spawn at all -- so the four pocket cells are still holding
  # whatever the character had, and IFAKs into them come back
  # "no grid of 627a4e6b255f7527fb05a0f6 (4) has a free cell". That is a correct,
  # named refusal, and the fix is to put them somewhere with room.
  carry(s, "TacticalVest", "590c678286f77426c9660122", 2)

  # Loose in the stash, so a reload after the raid has somewhere to come from.
  stock(s, "54527ac44bdc2d36668b4567", 180)

  # Launch, mint, enter, wait for the raid-phase latch, print the verdict, and
  # exit 0 PASS / 1 FAIL / 2 INCONCLUSIVE.
  runAndQuit(s)

main()
