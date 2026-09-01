## autoscript -- the automation library. A TEST IS A NIMONY SCRIPT.
##
## ===========================================================================
## WHAT THIS IS FOR
## ===========================================================================
##
## Testing a feature that only shows itself in a raid means: own the gear that
## triggers it, get into the right map on the right side, and be sure you really
## deployed. Doing that by hand -- buy an M4, three magazines, 180 rounds, walk
## the menu, remember to tick practice mode -- is why features get tested once.
##
## So a test is a script. The script SAYS what it wants, and running it launches
## the whole stack, mints the gear, drives entry, and prints a verdict:
##
##     import autoscript
##
##     var s = newScript("woods-pmc-m4")
##     onMap(s, "Woods")
##     asSide(s, "pmc")
##     equipWeapon(s, "FirstPrimaryWeapon",
##                 "5447a9cd4bdc2dbd208b4567",   # M4A1
##                 "55d4887d4bdc2d962f8b4570",   # a STANAG in its mod_magazine
##                 "54527ac44bdc2d36668b4567")   # loaded with M855A1
##     equip(s, "Headwear",           "5aa7e276e5b5b000171d0647")   # Altyn
##     equip(s, "TacticalVest",       "5ab8dced86f774646209ec87")   # ANA M1
##     carryLoaded(s, "TacticalVest", "55d4887d4bdc2d962f8b4570", 3,
##                 "54527ac44bdc2d36668b4567")     # 3 mags, loaded with M855A1
##     carry(s, "TacticalVest", "590c678286f77426c9660122", 2)     # 2 IFAKs
##     stock(s, "54527ac44bdc2d36668b4567", 180)                    # spare ammo
##     runAndQuit(s)
##
## `runAndQuit(s)` is the whole runner. It exits 0 PASS, 1 FAIL, 2 INCONCLUSIVE.
##
## ===========================================================================
## THE VERDICT, AND WHY THERE ARE THREE OF THEM
## ===========================================================================
##
##   PASS          every declared item was READ BACK off the profile, and the
##                 host's own raid-phase latch said DEPLOYED.
##   FAIL          something measurable did not happen: gear was refused, or
##                 fewer items came back than were asked for, or the latch
##                 reported a phase other than DEPLOYED.
##   INCONCLUSIVE  the question was never asked. No install, no backend, no
##                 profile, the client never got far enough, or the raid-phase
##                 latch produced no observation at all.
##
## **A script that TRIES to enter a raid and never deploys is INCONCLUSIVE, never
## PASS.** A run that could not look is not a pass (CLAUDE.md 9b). `finish`
## enforces that once, centrally, rather than trusting every step to. A script
## that never attempts a raid at all -- a gear-only test -- is not making a claim
## about deployment and is not failed for one; `raidAttempted` is what tells
## those two apart, and collapsing them would be a check that cannot pass.
##
## ===========================================================================
## HOW "AM I DEPLOYED" IS DECIDED -- and how it is NOT
## ===========================================================================
##
## The ONLY trustworthy signal is the host's raid-phase latch (`raidphase.nim`).
## It arms on GameWorld cached + MainPlayer Unity-alive + MainPlayer in
## AllAlivePlayersList + Camera.main non-null, survives the MainPlayer null
## flicker (~3 frames in 4) and clears on `SessionEndUIScene`.
##
## A raid-ENTRY log line is NOT proof of raid STATE. That mistake invalidated
## four experiments in one week, and this file therefore never treats
## `enterraid.py` exiting 0, a `RegisterPlayer` line, or a scene-load marker as
## deployment. It waits for the latch to SAY so.
##
## The latch lives in the game process and this runner does not. The latch's one
## out-of-process observable is the host log line
##
##     natesp: raid phase = DEPLOYED -- LATCHED at tick ... [S1 ... S5 ...]
##
## printed every 5s by `natesp.nim`. That line is gated: `gNeDiag = gNeOn and
## readBoolKey("natEspDiag")`, so BOTH `natEsp` and `natEspDiag` must be on, and
## `debugEsp` is what populates the GameWorld cache the latch reads. So
## `armPhaseReporting` writes those three keys into `aowlspt-host.json` BEFORE
## the client is launched (host flags are read at boot), and says it did.
##
## If no `raid phase =` line ever appears, the verdict is INCONCLUSIVE naming
## the three flags -- NOT "you did not deploy". Those are different facts and
## collapsing them is how a broken instrument reads as a broken feature.
##
## ===========================================================================
## WHY THE GEAR IS MINTED BY THE BACKEND AND NOT BY THIS PROCESS
## ===========================================================================
##
## `mods/tarkov` IS the SPT emulator and it owns the profile. `emu/loadout.nim`
## does the minting there, reusing the machinery that already exists:
## `emu/spawn`'s name search (with its ambiguity refusal), `emu/trading.giveItem`
## for the stash, `emu/grid` for real cells in a worn container, and above all
## `emu/bots.validateSlots` -- the ancestry-aware slot validator -- and
## `emu/bots.auditStacks`.
##
## A client-side mod could not do this even if it wanted to: `serve()` inside the
## game process registers into nothing, so a mod that reports over HTTP reports
## nowhere. The backend's plain-HTTP control port is the only channel a separate
## process has, and `emu/loadout` answers on it at
## `/aowlspt/tarkov/autoscript/loadout`.
##
## ===========================================================================
## HOW THE GEAR CHECK CAN FAIL -- the falsifiable part
## ===========================================================================
##
## `applyGear` does not believe the mint. The server saves the profile, then
## RE-READS it off the store and counts, per request, how many items of that
## template are parented where the request asked. Five numbers come back and they
## are five different numbers: `requested`, `baseline` (how many were ALREADY
## there, read before anything was minted), `minted`, `placed` (after MINUS
## baseline) and `rejected`.
##
## `placed < requested` is a FAIL, and it is reachable. Point `equip` at
## `Headwear` with a rifle template: `validateSlots` refuses it, minted goes to
## 1 and placed to 0, and the runner prints
##
##     GEAR   FAIL  asked for 1, minted 1, read back 0; 1 refusal(s)
##       ! validateSlots: slot refused: 5447a9cd... -> Headwear on 55d7217a...
##
## That is the input that makes this check fail. A check whose failing input
## cannot be named is not a check.
##
## ===========================================================================
## THE STEPS, IF A SCRIPT WANTS THEM SEPARATELY
## ===========================================================================
##
##   launchStack(s)        start backend+client if nothing is running; wait for
##                         the backend's control port to answer
##   pickProfile(s)        choose the profile to mint into and play
##   applyGear(s)          POST the loadout; read the report back
##   verifyGear(s)         the read-back alone, mints nothing
##   enterRaid(s)          drive menu -> offline raid on the declared map
##   waitDeployed(s, secs) wait for the raid-phase latch to say DEPLOYED
##   finish(s)             print the report, return the exit code
##   run(s)                all of the above, in order, stopping at the first
##                         step that does not PASS
##
## Every step returns `bool` and every step that returns false has already
## written its reason into the script's log. None of them throw.
##
## ===========================================================================
## ACTUATION -- AND WHICH VERBS ACTUALLY PROVE ANYTHING
## ===========================================================================
##
## The verbs are NOT equally strong, and this library refuses to pretend they
## are. These assert a FINISHED STATE, each read back from a value the GAME
## maintains and this library never writes:
##
##   walkAndSee        `EFT.Player::get_Position` -- metres actually travelled.
##   magCycle          the completion line carries the game's `Magazine.Count`.
##   sprintAndSee      `EFT.Player::get_IsSprintEnabled` after `EnableSprint`.
##   aimAndSee         `FirearmController::get_IsAiming` after `set_IsAiming`.
##   swapWeaponAndSee  `FirearmController::get_Item` 45 frames after the swap
##                     command -- a DIFFERENT weapon object must be in hands.
##   lookAndSee        `EFT.MovementContext::get_Rotation` -- degrees of yaw and
##                     pitch the game itself holds, wrapped across 0.
##
## `fire`, `jump`, `prone`, `pose`, `lean`, `toggleInventory`, `examineWeapon`,
## `command` and `reload` are ISSUE-ONLY: a PASS means THE HOST ACCEPTED THE
## CALL. pact has no readback for the trigger or for stance today, and saying so
## is better than upgrading an INCONCLUSIVE to a PASS. An issue-only PASS that read
## like a verified one would be precisely the check that cannot fail, so the
## distinction is in the transcript, in the doc comments, and in `actuated`'s
## INCONCLUSIVE.
##
## ===========================================================================
## THE VERSION HANDSHAKE -- why a green run used to mean nothing
## ===========================================================================
##
## `run` asks the DEPLOYED install what it can do before it mints anything, on
## both halves: `/aowlspt/tarkov/autoscript/capabilities` for the backend and
## `pact caps` for the host. Every declaration verb records the tokens it needs
## (`equipWeapon` needs `magazine`; `swapWeaponAndSee` needs the `swap` verb),
## so a script never has to remember to. See `checkVersion` for the exact input
## that used to pass and now fails.
##
## The full reference -- every verb, its arguments, its refusals, the loadout
## wire format and the report's field meanings -- is `docs/AUTOMATION-API.md`.

import std/strutils
import std/syncio
import std/envvars
import aowlsptinstall/winfs
import aowlsession

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
# `aowl_spawn` / `aowl_spawn_alive` live in aowlspt_inject.h, not the shim.
# Omitting this include compiles to an *implicit declaration* error rather than
# a missing symbol, which reads like a nimony problem and is not one.
{.emit: """#include "aowlspt_inject.h" """.}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnAlive(h: uint64): int32 {.importc: "aowl_spawn_alive", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

const
  DefaultRoot* = "D:\\Aowlspt"
    ## The live install. Overridable per script with `atRoot`.

  ScriptSession* = "000000000000000000000002"
    ## This runner's own session cookie. Deliberately NOT `ProbeSession`, so a
    ## backend log can tell a script's traffic from the launcher's probe.

  PhaseMarker = "natesp: raid phase = "
  DeployedMarker = "natesp: raid phase = DEPLOYED"

type
  Verdict* = enum
    ## The order matters: `worst` below takes the highest, and INCONCLUSIVE is
    ## deliberately WORSE than FAIL. A run that could not look must never be
    ## reported as a run that looked and found a fault -- that is a different
    ## and much more actionable thing.
    vPass, vFail, vInconclusive

  Side* = enum
    sidePmc, sideScav

  Gear = object
    tpl: string
    query: string
    slot: string      ## an equipment slot, for `equip`
    inside: string    ## the container's equipment slot, for `carry`
    count: int
    ammo: string
    magazine: string   ## mounted in the item's `mod_magazine` slot, for weapons
    condition: int

  Script* = object
    name*: string
    root*: string
    map*: string
    side*: Side
    clear*: bool          ## strip the character before minting
    launch*: bool         ## start the stack, or attach to a running one
    entryDriver*: string  ## tools\enterraid.py, or "" to look beside the CWD
    gear: seq[Gear]
    # ---- state gathered as the run proceeds ----
    port*: int
    profileId*: string
    profileName*: string
    verdict*: Verdict
    reason*: string
    lines: seq[string]
    gearRequested*: int
    gearMinted*: int
    gearPlaced*: int
    phaseSeen*: string    ## the last raid phase the host log reported
    entered*: bool        ## the latch said DEPLOYED at least once
    steps*: int
      ## How many steps have reported. Zero means NOTHING RAN, which `finish`
      ## turns into INCONCLUSIVE. Without this counter a script that used the
      ## steps individually could never report PASS: `worse` is monotone, so a
      ## seed of INCONCLUSIVE is absorbing. Seeding PASS instead needs something
      ## to distinguish "everything passed" from "nothing was attempted", and
      ## this is it.
    raidAttempted*: bool
    actuation*: bool
      ## Whether this script intends to ACTUATE the player in raid. Arming is
      ## opt-in because it turns on three host flags (`playerActuation`,
      ## `liveInspector`, `liveInspectorWrite`) that are default-OFF by rule, and
      ## a script that only checks gear has no business turning them on.
    ammoMode*: string
      ## The rung to put `mods/ammoloading` on before the launch, or "" to leave
      ## that mod exactly as the install has it.
    inspSerial*: int
      ## Bumped into every inspector batch. The channel triggers on a CONTENT
      ## CHANGE, so two identical batches would run once; this is what makes the
      ## second one run.
    actuations*: int      ## pact requests this script sent
    actuationsOk*: int    ## of those, ones whose outcome line was observed
    needBackend: seq[string]
      ## Capability tokens this script needs from the DEPLOYED tarkov.dll. Every
      ## declaration verb adds its own, so a script never has to remember to.
    needPact: seq[string]
      ## Verb names this script needs from the DEPLOYED host DLL's pact.
    apiSeen*: int         ## the backend's `api` integer, -1 if never answered
    capsSeen*: string     ## its capability list, verbatim
    pactCapsSeen*: string ## the host's `caps` line, verbatim
      ## Whether `enterRaid` ran. The never-deployed rule in `finish` applies
      ## only when it did: a script that deliberately tests gear alone and never
      ## goes near a raid is not making a claim about deployment, and failing it
      ## for one would be a check that cannot pass. A script that DOES try and
      ## never deploys is still INCONCLUSIVE, which is the rule that matters.

# ---------------------------------------------------------------------------
# Declaring a script
# ---------------------------------------------------------------------------

proc newScript*(name: string): Script =
  ## A script with nothing declared. Defaults: the live install, Woods, PMC,
  ## strip the character first, launch the stack.
  ##
  ## `clear` defaults TRUE on purpose. A test that runs against whatever the
  ## character happened to be wearing is a test whose result depends on the last
  ## run, and "the slot is already occupied" is the most common way a loadout
  ## silently does not arrive.
  # `AOWLSPT_ROOT` wins over the default, so the same script can be pointed at a
  # scratch install without editing it -- which is how this library's own gear
  # acceptance is run without touching D:\Aowlspt. `atRoot` still wins over
  # both, because a script that names its install means it.
  var root = DefaultRoot
  let fromEnv = getEnv("AOWLSPT_ROOT")
  if fromEnv.len > 0:
    root = fromEnv
  Script(name: name, root: root, map: "Woods", side: sidePmc,
         clear: true, launch: true, entryDriver: "", gear: @[], port: 0,
         profileId: "",
         profileName: "", verdict: vPass,
         reason: "", lines: @[],
         gearRequested: 0, gearMinted: 0, gearPlaced: 0, phaseSeen: "",
         entered: false, steps: 0, raidAttempted: false,
         actuation: false, ammoMode: "", inspSerial: 0,
         actuations: 0, actuationsOk: 0,
         needBackend: @["loadout"], needPact: @[],
         apiSeen: -1, capsSeen: "", pactCapsSeen: "")

proc atRoot*(s: var Script; root: string) =
  ## The install to drive. Default `D:\Aowlspt`.
  s.root = root

proc onMap*(s: var Script; map: string) =
  ## The map, by the name the SELECT LOCATION screen displays -- "Woods",
  ## "Customs", "Factory", "Interchange", "Reserve", "Shoreline", "Lighthouse",
  ## "Streets of Tarkov", "Ground Zero", "The Lab".
  s.map = map

proc asSide*(s: var Script; side: string) =
  ## "pmc" or "scav". Anything else is refused at `run` time with a reason
  ## rather than folded into pmc -- a scav test that quietly ran as a PMC is a
  ## result that means nothing.
  s.side = if toLowerAscii(side) == "scav": sideScav else: sidePmc

proc keepGear*(s: var Script) =
  ## Do NOT strip the character before minting. Use when a script is testing
  ## what a raid did to an existing loadout.
  s.clear = false

proc withEntryDriver*(s: var Script; path: string) =
  ## Where `enterraid.py` is. Default: `tools\enterraid.py` relative to the
  ## working directory, i.e. the repo root.
  s.entryDriver = path

proc attachOnly*(s: var Script) =
  ## Do not launch anything; drive whatever is already running. Use when a human
  ## already has the client up.
  s.launch = false

proc needsBackend*(s: var Script; cap: string) =
  ## Declare that this script cannot mean anything against a `tarkov.dll` that
  ## lacks `cap`. Declaring twice is harmless; `checkVersion` de-duplicates by
  ## reporting each missing token once.
  s.needBackend.add cap

proc needsPact*(s: var Script; verb: string) =
  ## Declare that this script needs `verb` from the DEPLOYED host DLL's pact.
  s.needPact.add verb

proc addGear(s: var Script; g: Gear) =
  s.gear.add g

proc equip*(s: var Script; slot, tpl: string) =
  ## Wear one item in one of the 14 equipment slots. A slot holds ONE thing;
  ## asking for more is refused by name rather than silently placing the first.
  addGear(s, Gear(tpl: tpl, query: tpl, slot: slot, inside: "", count: 1,
                  ammo: "", magazine: "", condition: 100))

proc equipLoaded*(s: var Script; slot, tpl, ammo: string) =
  ## Wear it, and fill its cartridges with `ammo` to the capacity the TEMPLATE
  ## declares. Refused, with a reason, when the template's cartridge filter does
  ## not accept that round -- a magazine "filled" with ammo the filter omits is
  ## a gun that spawns empty.
  ##
  ## FOR MAGAZINES AND OTHER CARTRIDGE-BEARING CONTAINERS, NOT WEAPONS. A weapon
  ## declares `_props.Chambers`, not `_props.Cartridges` (measured), holds no
  ## rounds directly, and needs a magazine mounted in `mod_magazine`. Pointing
  ## this verb at one is REFUSED by the backend with a reason that says the
  ## template is a chambered item and that no `magazine` was named -- which is
  ## the right refusal, but `equipWeapon` is the verb you wanted.
  needsBackend(s, "ammo")
  addGear(s, Gear(tpl: tpl, query: tpl, slot: slot, inside: "", count: 1,
                  ammo: ammo, magazine: "", condition: 100))

proc equipWeapon*(s: var Script; slot, weapon, magazine, ammo: string) =
  ## Wear a WEAPON with a magazine mounted in it and a round in the chamber.
  ##
  ## This is what `equipLoaded` could never do, and the reason is a measured fact
  ## about the database, not a preference:
  ##
  ##   `5447a9cd4bdc2dbd208b4567` (M4A1) declares `_props.Chambers[0]._name =
  ##   "patron_in_weapon"` and NO `_props.Cartridges`.
  ##   `55d4887d4bdc2d962f8b4570` (STANAG) declares `_props.Cartridges` and no
  ##   slots of its own.
  ##
  ## So a weapon holds no rounds directly. `equipLoaded(s, slot, m4, ammo)` asked
  ## the backend for a cartridge capacity the weapon does not have, was REFUSED
  ## with "the database declares no _props.Cartridges[0]._max_count", and -- even
  ## had it succeeded -- would still have mounted nothing in `mod_magazine`. That
  ## is why `GetCurrentMagazine()` read null in raid and why `pactMagCycle` had
  ## nothing to cycle. `equipWeapon` is the fix.
  ##
  ## The magazine is NAMED, never guessed. The M4A1's `mod_magazine` filter
  ## admits 20 templates and "the first one" is an arbitrary document order --
  ## the same guess this library refuses in `byName`. A magazine the filter
  ## excludes is REFUSED BEFORE MINTING, because a magazine the client drops on
  ## load saves to the profile, reads back, and still leaves the raid unarmed.
  ##
  ## The acceptance is a walk of the finished state, not a re-read of the write:
  ## the server re-reads the saved profile, finds the item worn in `slot`, and
  ## counts its `mod_magazine` children and THEIR cartridges. `magPlaced == 0`
  ## and `roundsPlaced == 0` are separate FAILs, because "no magazine" and "an
  ## empty magazine" break a raid differently.
  # THE HANDSHAKE'S REASON FOR EXISTING. A tarkov.dll built before `magazine`
  # existed parses this spec, ignores the field, mints the rifle alone and
  # answers 200 with placed=1. `checkVersion` is what turns that into a loud
  # refusal instead of a green run that tested nothing.
  needsBackend(s, "magazine")
  needsBackend(s, "ammo")
  addGear(s, Gear(tpl: weapon, query: weapon, slot: slot, inside: "", count: 1,
                  ammo: ammo, magazine: magazine, condition: 100))

proc carry*(s: var Script; container, tpl: string; count: int) =
  ## `count` of an item in real cells of the container worn in that equipment
  ## slot -- "TacticalVest", "Backpack", "Pockets", "SecuredContainer".
  ##
  ## Refused, never placed at 0,0, when there is no room: an overlapping item is
  ## drawn on top of what is already there and cannot be picked up, which looks
  ## exactly like never having been given it.
  ##
  ## Equip the container EARLIER IN THE SCRIPT than the things that go in it.
  ## Requests are applied in declaration order, and "nothing is worn in
  ## TacticalVest" is the refusal you get otherwise -- it is named, not silent.
  needsBackend(s, "inside")
  addGear(s, Gear(tpl: tpl, query: tpl, slot: "", inside: container,
                  count: count, ammo: "", magazine: "", condition: 100))

proc carryLoaded*(s: var Script; container, tpl: string; count: int;
                  ammo: string) =
  ## `count` magazines in the container, each loaded with `ammo`. This is the
  ## "magazines = 3, ammo = m855a1" case.
  needsBackend(s, "inside")
  needsBackend(s, "ammo")
  addGear(s, Gear(tpl: tpl, query: tpl, slot: "", inside: container,
                  count: count, ammo: ammo, magazine: "", condition: 100))

proc stock*(s: var Script; tpl: string; count: int) =
  ## `count` of an item loose in the stash, stack-limit aware and merged into
  ## stacks already there. For spares the raid does not start with.
  addGear(s, Gear(tpl: tpl, query: tpl, slot: "", inside: "", count: count,
                  ammo: "", magazine: "", condition: 100))

proc byName*(s: var Script; query: string; count: int) =
  ## Stash `count` of whatever the English item name `query` names. Convenient
  ## and deliberately strict: an AMBIGUOUS name is REFUSED and the candidates
  ## are listed, because "the first match" is an arbitrary document order and a
  ## test that equipped the wrong rifle proves nothing.
  needsBackend(s, "query")
  addGear(s, Gear(tpl: "", query: query, slot: "", inside: "", count: count,
                  ammo: "", magazine: "", condition: 100))

proc wear*(s: var Script; slot, tpl: string; condition: int) =
  ## `equip` with a durability/resource percentage, applied only to the
  ## properties the template actually declares.
  needsBackend(s, "condition")
  addGear(s, Gear(tpl: tpl, query: tpl, slot: slot, inside: "", count: 1,
                  ammo: "", magazine: "", condition: condition))

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

proc withActuation*(s: var Script) =
  ## Declare that this script drives the PLAYER once the raid is DEPLOYED.
  ##
  ## Arms three host flags before the launch, because all three are read at
  ## boot: `playerActuation` (pact itself), `liveInspector` and
  ## `liveInspectorWrite` (the file channel the request travels on, and its
  ## write gate). Without this, every actuation verb below refuses BY NAME
  ## rather than sitting silent.
  s.actuation = true

proc withAmmoLoading*(s: var Script; mode: string) =
  ## Put `mods/ammoloading` on a rung of its own ladder before the launch:
  ## "off" / "probe" / "read" / "spawn" / "animate". `probe` is the rung that
  ## proves the trigger fires with zero dereferences and no bundle; the two
  ## rungs above it additionally need a bundle riding a vanilla key via
  ## `mods/textures`, which this library does not set up and does not pretend to.
  s.ammoMode = mode

proc worse(a, b: Verdict): Verdict =
  if a == vInconclusive or b == vInconclusive: vInconclusive
  elif a == vFail or b == vFail: vFail
  else: vPass

proc verdictName*(v: Verdict): string =
  case v
  of vPass: "PASS"
  of vFail: "FAIL"
  of vInconclusive: "INCONCLUSIVE"

proc say(s: var Script; line: string) =
  s.lines.add line
  echo "[" & s.name & "] " & line

proc note*(s: var Script; line: string) =
  ## A script's own commentary, into the same transcript the runner prints.
  say(s, line)

proc step(s: var Script; label: string; v: Verdict; why: string): bool =
  ## One step's outcome. Always three-valued, always with a reason: a bare
  ## verdict is not one.
  say(s, label & "  " & verdictName(v) & "  " & why)
  s.steps = s.steps + 1
  s.verdict = worse(s.verdict, v)
  if v != vPass:
    s.reason = label & ": " & why
  result = v == vPass

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc jq(s: string): string =
  result = "\""
  for c in s:
    if c == '"' or c == '\\': result.add '\\'
    result.add c
  result.add '"'

proc jsonInt(body, key: string; fallback: int): int =
  ## `"key":<digits>` out of a flat report. Deliberately not a parser: this
  ## reads ONE well-known server-produced document, and a miss returns the
  ## fallback so a changed report shape shows up as an obviously wrong number
  ## rather than as a crash.
  result = fallback
  let at = find(body, "\"" & key & "\":")
  if at < 0: return
  var i = at + key.len + 3
  var neg = false
  if i < body.len and body[i] == '-':
    neg = true
    inc i
  var v = 0
  var any = false
  while i < body.len and body[i] >= '0' and body[i] <= '9':
    v = v * 10 + (ord(body[i]) - ord('0'))
    any = true
    inc i
  if any:
    result = if neg: -v else: v

proc jsonStr(body, key: string): string =
  ## `"key":"..."` out of the same. Same reasoning as `jsonInt`.
  result = ""
  let at = find(body, "\"" & key & "\":\"")
  if at < 0: return
  var i = at + key.len + 4
  while i < body.len and body[i] != '"':
    if body[i] == '\\' and i + 1 < body.len:
      result.add body[i + 1]
      i = i + 2
      continue
    result.add body[i]
    inc i

proc hostLogPath(s: Script): string =
  joinPath(s.root, "aowlspt\\aowlspt-host.log")

proc hostConfig(s: Script): string =
  joinPath(s.root, "aowlspt\\aowlspt-host.json")

proc logSize(s: Script): int64 =
  fileSizeOf(hostLogPath(s))

proc readTail(path: string; fromByte: int64): string =
  ## Everything a file has gained since `fromByte`. Reading the whole file and
  ## slicing is deliberate: the host log is measured at ~14 KB, and a seek-based
  ## reader would be a second file API to keep correct for no gain.
  var whole = ""
  if not readTextFile(path, whole):
    return ""
  if fromByte <= 0 or int(fromByte) >= whole.len:
    return if fromByte <= 0: whole else: ""
  result = whole.substr(int(fromByte))

# ---------------------------------------------------------------------------
# Host flags
# ---------------------------------------------------------------------------

proc setBoolKey(text, key: string): string =
  ## `"key": false` -> `"key": true` in a config document, leaving everything
  ## else byte-identical. Returns "" when the key is not present, which the
  ## caller must report rather than paper over: silently adding a key the host
  ## does not declare produces a flag nothing reads.
  let at = find(text, "\"" & key & "\"")
  if at < 0: return ""
  var i = at + key.len + 2
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  if i + 5 <= text.len and text.substr(i, i + 4) == "false":
    return text.substr(0, i - 1) & "true" & text.substr(i + 5)
  if i + 4 <= text.len and text.substr(i, i + 3) == "true":
    return text     # already on
  result = ""

proc armPhaseReporting*(s: var Script): bool =
  ## Turn on the three host flags that make the raid-phase latch OBSERVABLE from
  ## outside the game process, before the client boots.
  ##
  ##   debugEsp     populates the GameWorld cache the latch reads
  ##   natEsp       `gNeDiag = gNeOn and readBoolKey("natEspDiag")` -- both
  ##   natEspDiag   halves are required, which is measured, not assumed
  ##
  ## Host flags are read at boot, so this must happen BEFORE the launch. A
  ## failure here is reported and does not stop the run: the run then simply
  ## cannot conclude anything about deployment, and `waitDeployed` says exactly
  ## that instead of guessing.
  let path = hostConfig(s)
  var text = ""
  if not readTextFile(path, text):
    say(s, "flags  could not read " & path &
           " -- the raid-phase latch will not be observable")
    return false
  var missing = ""
  for key in ["debugEsp", "natEsp", "natEspDiag"]:
    let next = setBoolKey(text, key)
    if next.len == 0:
      if missing.len > 0: missing.add ", "
      missing.add key
    else:
      text = next
  if missing.len > 0:
    say(s, "flags  " & path & " declares no " & missing &
           " -- the raid-phase latch may not report")
  # `std/syncio` rather than `winfs.openHeld`. Deliberate and measured: winfs's
  # held-handle API is typed on Win32 `HANDLE`, and nimony emits the extern for
  # an imported proc BEFORE this module's `{.emit.}` includes, so referencing it
  # here fails to compile with `unknown type name 'HANDLE'` -- a build error that
  # reads like a toolchain fault and is purely an ordering one.
  var f: File
  if not open(f, path, fmWrite):
    say(s, "flags  could not open " & path & " for writing")
    return false
  write(f, text)
  close(f)
  say(s, "flags  debugEsp/natEsp/natEspDiag armed in " & path &
         " (host flags are read at boot, so this is before the launch)")
  result = true

proc setStrKey(text, key, value: string): string =
  ## `"key": "old"` -> `"key": "value"`, leaving everything else byte-identical.
  ## Same contract as `setBoolKey`: "" means THE KEY IS NOT THERE, which the
  ## caller reports rather than papering over by inventing it.
  let at = find(text, "\"" & key & "\"")
  if at < 0: return ""
  var i = at + key.len + 2
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  if i >= text.len or text[i] != '"': return ""
  let vstart = i + 1
  var j = vstart
  while j < text.len and text[j] != '"':
    if text[j] == '\\': inc j
    inc j
  if j >= text.len: return ""
  result = text.substr(0, vstart - 1) & value & text.substr(j)

proc writeWhole(path, text: string): bool =
  var f: File
  if not open(f, path, fmWrite): return false
  write(f, text)
  close(f)
  true

proc armActuation*(s: var Script): bool =
  ## Turn on the three flags that make in-raid actuation REACHABLE from outside
  ## the game process, before the client boots.
  ##
  ##   playerActuation      pact itself; without it every request is refused
  ##   liveInspector        the file channel the request travels on
  ##   liveInspectorWrite   the gate `allow write` needs; `pact` CALLS INTO GAME
  ##                        CODE, so it is deliberately on the write side
  ##
  ## Returns false and SAYS WHY. A false here does not stop the run: the
  ## actuation steps then refuse by name, which is a better outcome than a run
  ## that silently never actuated and still passed.
  if not s.actuation: return true
  let path = hostConfig(s)
  var text = ""
  if not readTextFile(path, text):
    say(s, "flags  could not read " & path & " -- actuation cannot be armed")
    return false
  var missing = ""
  for key in ["playerActuation", "liveInspector", "liveInspectorWrite"]:
    let next = setBoolKey(text, key)
    if next.len == 0:
      if missing.len > 0: missing.add ", "
      missing.add key
    else:
      text = next
  if missing.len > 0:
    say(s, "flags  " & path & " declares no " & missing &
           " -- actuation will be REFUSED, not silently skipped")
    return false
  if not writeWhole(path, text):
    say(s, "flags  could not write " & path)
    return false
  say(s, "flags  playerActuation/liveInspector/liveInspectorWrite armed in " &
         path)
  result = true

proc armAmmoLoading*(s: var Script): bool =
  ## Put `mods/ammoloading` on the declared rung before the launch. Mod config
  ## is read at mod load, so this must happen first, exactly like a host flag.
  if s.ammoMode.len == 0: return true
  let path = joinPath(s.root, "aowlspt\\mods\\ammoloading\\config.json")
  var text = ""
  if not readTextFile(path, text):
    say(s, "ammo   could not read " & path &
           " -- is the mod installed in this root? The mod cannot observe " &
           "anything it is not loaded for.")
    return false
  let on = setBoolKey(text, "enabled")
  if on.len == 0:
    say(s, "ammo   " & path & " declares no `enabled` key")
    return false
  text = on
  let m = setStrKey(text, "mode", s.ammoMode)
  if m.len == 0:
    say(s, "ammo   " & path & " declares no string `mode` key")
    return false
  text = m
  if not writeWhole(path, text):
    say(s, "ammo   could not write " & path)
    return false
  say(s, "ammo   mods/ammoloading enabled, mode=" & s.ammoMode & " in " & path)
  result = true

# ---------------------------------------------------------------------------
# Step 1 -- the stack
# ---------------------------------------------------------------------------

proc launchStack*(s: var Script): bool =
  ## Attach to a running backend, or start `aowlspt-launch.exe` and wait for the
  ## backend's plain-HTTP control port to ANSWER.
  ##
  ## Readiness is `aowlsession.answers`, which asks the tarkov mod's own
  ## selfcheck route. That is the right readiness: the next thing this runner
  ## does is ask that mod for profiles, and the backend only begins listening
  ## after every mod has loaded. A fixed sleep would be a guess, and the false
  ## crash (the client needs 60s+ to reach profile-select and then WAITS for a
  ## human) is exactly what a guess gets wrong.
  var why = ""
  var port = controlPort(s.root, why)
  if port > 0:
    s.port = port
    if s.actuation or s.ammoMode.len > 0:
      # NOT armed, and said so. Host flags and mod config are read at BOOT, so
      # attaching to a client that is already up cannot arm them, and writing
      # them now would produce a file that says "on" over a process that is off
      # -- the exact shape of a check that cannot fail.
      say(s, "STACK   attached to an ALREADY-RUNNING client, so " &
             "playerActuation / the inspector / the ammoloading rung were NOT " &
             "armed by this run: those are read at boot. Whatever that client " &
             "booted with is what is in effect, and the actuation steps below " &
             "report what they actually find.")
    return step(s, "STACK ", vPass, "attached to a running backend -- " & why)

  if not s.launch:
    return step(s, "STACK ", vInconclusive,
                "nothing is running and this script said attachOnly -- " & why)

  let exe = joinPath(s.root, "aowlspt\\aowlspt-launch.exe")
  if not exists(exe):
    return step(s, "STACK ", vInconclusive,
                "there is no " & exe & ", so this install cannot be launched")

  discard armPhaseReporting(s)
  discard armActuation(s)
  discard armAmmoLoading(s)

  say(s, "STACK   launching " & exe)
  # `toCString` takes a `var string`, so every argument to `cSpawn` must be a
  # named local. Passing an expression is a compile error, not a runtime one.
  var xe = exe
  var wd = joinPath(s.root, "aowlspt")
  var cl = "\"" & exe & "\""
  let h = cSpawn(toCString(xe), toCString(wd), toCString(cl))
  if h == 0'u64:
    return step(s, "STACK ", vInconclusive, "could not start " & exe)

  # 240s, not 60. The client takes >60s to reach profile-select on a cold boot
  # and the backend comes up first; a 60s budget here is the false crash in
  # runner form.
  var waited = 0
  while waited < 240:
    cSleepMs(2000'i32)
    waited = waited + 2
    port = controlPort(s.root, why)
    if port > 0:
      s.port = port
      return step(s, "STACK ", vPass,
                  "backend up after ~" & $waited & "s -- " & why)
    if cSpawnAlive(h) == 0'i32 and waited > 10:
      # The launcher exits once it has started the client; that is normal and is
      # NOT a failure. Keep waiting on the port, which is the real signal.
      discard
  result = step(s, "STACK ", vInconclusive,
                "the backend's control port never answered in 240s -- " & why)

# ---------------------------------------------------------------------------
# Step 1b -- THE VERSION HANDSHAKE
#
# THE BUG THIS CLOSES, stated as the input that used to pass and should not.
# ------------------------------------------------------------------------
# Deploy a `tarkov.dll` built before `equipWeapon`'s `magazine` field existed.
# Run `scripts/woods_pmc_m4.nim` against it. The old route is PRESENT, so there
# is no 404; it parses the spec, never looks at `magazine`, mints the rifle,
# re-reads the profile, finds one rifle worn in FirstPrimaryWeapon and answers
# `requested=1 minted=1 placed=1 verdict=PASS`. The runner reports PASS. The
# raid starts with an unloaded rifle and the feature under test was never
# exercised.
#
# `applyGear` could not catch it: its only staleness signal was HTTP 404, which
# distinguishes "no route" from "a route", not "a current route" from "an old
# one". So both halves of the install now SAY WHAT THEY CAN DO, and every
# declaration verb records what it needs.
#
# WHY TWO HALVES. Gear is minted by the backend (`tarkov.dll`) and the player is
# driven by the host (`aowlspt-host-il2cpp.dll`). They are deployed separately
# and go stale separately -- a run has repeatedly had a current backend and a
# host from a previous batch. One handshake covering both would report a
# half-stale install as wholly stale, which is a worse diagnosis than none.
# ---------------------------------------------------------------------------

proc capsHave(caps, token: string): bool =
  ## Exact TOKEN membership in a comma-separated list -- never `contains`.
  ## `contains` would let `magazine` be satisfied by a build that only declared
  ## `magazines`, or `ammo` by `ammobox`: a substring test on a capability list
  ## is a check that can pass for the wrong reason, which is the shape of defect
  ## this whole step exists to stop.
  result = false
  var cur = ""
  var i = 0
  while i <= caps.len:
    if i == caps.len or caps[i] == ',' or caps[i] == ' ':
      if cur == token: return true
      cur = ""
    else:
      cur.add caps[i]
    inc i

proc checkVersion*(s: var Script): bool =
  ## Ask the DEPLOYED install what it can do, and refuse loudly if it cannot do
  ## what this script declared it needs.
  ##
  ##   PASS          every declared token is present in what the install
  ##                 reported, on both halves this script actually uses
  ##   FAIL          the install ANSWERED and a token this script needs is
  ##                 absent -- including the 404 case, which is a measured
  ##                 answer ("this build has no autoscript routes at all") and
  ##                 not an inability to look
  ##   INCONCLUSIVE  nothing answered: no control port, or a transport error.
  ##                 Nothing was learned about the install's age.
  if s.port <= 0:
    return step(s, "VERSN ", vInconclusive,
                "there is no control port, so the install's capabilities " &
                "could not be asked for and its age is unknown")
  let r = call(s.port, "GET", "/aowlspt/tarkov/autoscript/capabilities", "",
               ScriptSession)
  if not r.ok:
    return step(s, "VERSN ", vInconclusive,
                "the capabilities route could not be reached: " & r.error)
  if r.status == 404:
    return step(s, "VERSN ", vFail,
                "the backend answers but has NO " &
                "/aowlspt/tarkov/autoscript/capabilities route. This " &
                "install's tarkov.dll PREDATES the version handshake, so " &
                "nothing it mints can be trusted to match what this script " &
                "asked for. Rebuild and redeploy the tarkov mod. Refusing " &
                "rather than minting against an install of unknown age.")
  if r.status != 200:
    return step(s, "VERSN ", vInconclusive,
                "the capabilities route answered HTTP " & $r.status)
  s.apiSeen = jsonInt(r.body, "api", -1)
  # The caps array, flattened to a comma list. `jsonStr` reads one string; this
  # reads the whole array, because a partial read here would make a missing
  # token indistinguishable from a token past wherever the read stopped.
  var caps = ""
  let at = find(r.body, "\"caps\":[")
  if at >= 0:
    var i = at + 8
    while i < r.body.len and r.body[i] != ']':
      if r.body[i] == '"':
        inc i
        while i < r.body.len and r.body[i] != '"':
          caps.add r.body[i]
          inc i
        caps.add ','
      inc i
  s.capsSeen = caps
  if caps.len == 0:
    return step(s, "VERSN ", vFail,
                "the capabilities route answered 200 and declared NO caps at " &
                "all (api=" & $s.apiSeen & "). An install that cannot name " &
                "one capability cannot be checked against, so this is refused " &
                "rather than assumed current.")
  var missing = ""
  var nMissing = 0
  for want in s.needBackend:
    if not capsHave(caps, want) and find("," & missing, "," & want & ",") < 0:
      if missing.len > 0: missing.add ","
      missing.add want
      nMissing = nMissing + 1
  if nMissing > 0:
    return step(s, "VERSN ", vFail,
                "this install's tarkov.dll is STALE for this script: it " &
                "declares api=" & $s.apiSeen & " caps=[" & caps &
                "] and does NOT have [" & missing & "], which this script's " &
                "declarations require. It would have answered 200 and minted " &
                "something else. Rebuild and redeploy the tarkov mod.")
  result = step(s, "VERSN ", vPass,
                "the deployed tarkov.dll declares api=" & $s.apiSeen &
                " and has every capability this script needs (" &
                $s.needBackend.len & " asked)")

# ---------------------------------------------------------------------------
# Step 2 -- the profile
# ---------------------------------------------------------------------------

proc pickProfile*(s: var Script): bool =
  ## The profile to mint into and play: the one played last, else the most
  ## recent. `aowlsession.autoProfile` decides, so a script and the launcher
  ## agree on which character "the profile" means.
  if s.port <= 0:
    return step(s, "PROFILE", vInconclusive,
                "there is no control port, so no profile can be chosen")
  let list = listProfiles(s.port, s.root)
  if list.items.len == 0:
    return step(s, "PROFILE", vInconclusive,
                "this install has no profiles yet -- create one in the " &
                "launcher first" &
                (if list.error.len > 0: " (" & list.error & ")" else: ""))
  var chosen = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                       edition: "", lastPlayed: 0)
  var reason = ""
  if not autoProfile(list, readLastProfile(s.root), chosen, reason):
    return step(s, "PROFILE", vInconclusive, reason)
  s.profileId = chosen.id
  s.profileName = chosen.nickname
  result = step(s, "PROFILE", vPass,
                chosen.nickname & " (" & chosen.id & ", " & chosen.side &
                ", level " & $chosen.level & ") -- " & reason)

# ---------------------------------------------------------------------------
# Step 3 -- the gear
# ---------------------------------------------------------------------------

proc specJson(s: Script): string =
  result = "{\"profileId\":" & jq(s.profileId) &
           ",\"clear\":" & (if s.clear: "true" else: "false") & ",\"gear\":["
  var first = true
  for g in s.gear:
    if not first: result.add ","
    first = false
    result.add "{"
    if g.tpl.len > 0:
      result.add "\"tpl\":" & jq(g.tpl) & ","
    result.add "\"query\":" & jq(g.query)
    if g.slot.len > 0: result.add ",\"slot\":" & jq(g.slot)
    if g.inside.len > 0: result.add ",\"inside\":" & jq(g.inside)
    if g.ammo.len > 0: result.add ",\"ammo\":" & jq(g.ammo)
    if g.magazine.len > 0: result.add ",\"magazine\":" & jq(g.magazine)
    result.add ",\"count\":" & $g.count
    result.add ",\"condition\":" & $g.condition
    result.add "}"
  result.add "]}"

proc reportGear(s: var Script; body: string; label: string): bool =
  ## The server's report, turned into a step. The three numbers are printed
  ## SEPARATELY and every refusal is echoed verbatim: `requested`, `minted` and
  ## `placed` collapsed into one boolean cannot express the failure this whole
  ## feature exists to catch.
  s.gearRequested = jsonInt(body, "requested", 0)
  s.gearMinted = jsonInt(body, "minted", 0)
  s.gearPlaced = jsonInt(body, "placed", 0)
  let verdict = jsonStr(body, "verdict")
  let reason = jsonStr(body, "reason")
  say(s, label & "  requested=" & $s.gearRequested &
         " minted=" & $s.gearMinted & " placed=" & $s.gearPlaced &
         " slotDropped=" & $jsonInt(body, "slotDropped", 0) &
         " flatStacks=" & $jsonInt(body, "flatStacks", 0))
  # Every rejection line, in full. A truncated refusal list is a refusal that
  # did not happen as far as the reader is concerned.
  # No `continue` anywhere in this loop. MEASURED on this nimony, 2026-08-31:
  # a `continue` inside a `for` over an array literal compiles to
  # `[Error] unreachable: (continue@C,9v,tools/autoscript.nim .)` at the final
  # build step -- an error that names no line of yours. Flag-shaped control flow
  # instead.
  for pair in ["rejected", "observations"]:
    let mark = if pair == "rejected": "  ! " else: "  . "
    let at = find(body, "\"" & pair & "\":[")
    if at >= 0:
      var i = at + pair.len + 3
      while i < body.len and body[i] != ']':
        if body[i] == '"':
          var one = ""
          inc i
          while i < body.len and body[i] != '"':
            if body[i] == '\\' and i + 1 < body.len:
              one.add body[i + 1]
              i = i + 2
            else:
              one.add body[i]
              inc i
          if one.len > 0:
            say(s, mark & one)
        inc i
  # `!` is a refusal this spec caused and fails it; `.` is an observation about
  # the profile it did not cause. Two marks, because one list would make a
  # perfectly good loadout read like a failed one.

  # THE PER-REQUEST BREAKDOWN. Added because the aggregate alone is not
  # actionable: a run that reported `requested=188 minted=188 placed=184` with
  # zero refusals said, truthfully, that four items went missing and gave the
  # reader nowhere to look. The server has always sent the per-entry numbers;
  # the runner was throwing them away.
  var gi = find(body, "\"gear\":[")
  if gi >= 0:
    var i = gi + 8
    var depth = 0
    var one = ""
    while i < body.len:
      let c = body[i]
      if c == '{':
        depth = depth + 1
      if depth > 0:
        one.add c
      if c == '}':
        depth = depth - 1
        if depth == 0:
          let want = jsonInt(one, "requested", 0)
          let got = jsonInt(one, "placed", 0)
          let mint = jsonInt(one, "minted", 0)
          let base = jsonInt(one, "baseline", 0)
          let why = jsonStr(one, "why")
          let mag = jsonStr(one, "magazine")
          let magN = jsonInt(one, "magPlaced", 0)
          let rds = jsonInt(one, "roundsPlaced", 0)
          let chb = jsonInt(one, "chambered", 0)
          # A weapon is only `ok` when its magazine came back WITH ROUNDS IN IT.
          # Judging it on `placed` alone would report ok for a rifle that spawns
          # with nothing to fire -- a check that cannot fail for the one property
          # the raid actually needs.
          var good = got >= want and want > 0
          if mag.len > 0 and (magN == 0 or rds == 0):
            good = false
          let mark = if good: "  ok " else: "  XX "
          say(s, mark & jsonStr(one, "where") & "  " &
                 jsonStr(one, "name") & "  req=" & $want & " base=" & $base &
                 " minted=" & $mint & " placed=" & $got &
                 (if mag.len > 0:
                    "  mag=" & $magN & " rounds=" & $rds & " chambered=" & $chb
                  else: "") &
                 (if why.len > 0: "  -- " & why else: ""))
          one = ""
      if c == ']' and depth == 0:
        i = body.len
      inc i
  let v = if verdict == "PASS": vPass
          elif verdict == "FAIL": vFail
          else: vInconclusive
  result = step(s, label, v, reason)

proc applyGear*(s: var Script): bool =
  ## Mint the declared loadout, then take the server's READ-BACK verdict.
  ##
  ## This never asserts its own write. The server saves, re-reads the profile off
  ## the store, and counts what is really parented where the script asked. See
  ## the module header for the input that makes this FAIL.
  if s.gear.len == 0:
    return step(s, "GEAR  ", vPass, "the script declared no gear")
  if s.port <= 0 or s.profileId.len == 0:
    return step(s, "GEAR  ", vInconclusive,
                "no backend or no profile, so no gear could be minted")
  let r = call(s.port, "POST", "/aowlspt/tarkov/autoscript/loadout",
               specJson(s), ScriptSession)
  if not r.ok:
    return step(s, "GEAR  ", vInconclusive,
                "the loadout route could not be reached: " & r.error)
  if r.status == 404:
    return step(s, "GEAR  ", vInconclusive,
                "the backend answers but has no " &
                "/aowlspt/tarkov/autoscript/loadout route -- this install's " &
                "tarkov.dll predates the automation library")
  if r.status != 200:
    return step(s, "GEAR  ", vInconclusive,
                "the loadout route answered HTTP " & $r.status)
  result = reportGear(s, r.body, "GEAR  ")

proc verifyGear*(s: var Script): bool =
  ## The read-back alone: mints nothing, saves nothing, same counting. Use it
  ## after a raid to assert what survived.
  if s.gear.len == 0:
    return step(s, "VERIFY", vPass, "the script declared no gear")
  if s.port <= 0 or s.profileId.len == 0:
    return step(s, "VERIFY", vInconclusive, "no backend or no profile")
  let r = call(s.port, "POST", "/aowlspt/tarkov/autoscript/verify",
               specJson(s), ScriptSession)
  if not r.ok or r.status != 200:
    return step(s, "VERIFY", vInconclusive,
                "the verify route did not answer (" &
                (if r.error.len > 0: r.error else: "HTTP " & $r.status) & ")")
  result = reportGear(s, r.body, "VERIFY")

# ---------------------------------------------------------------------------
# Step 4 -- the raid
# ---------------------------------------------------------------------------

proc enterRaid*(s: var Script): bool =
  ## Drive the menu into an offline raid on the declared map.
  ##
  ## `tools/enterraid.py` does the driving and is validated: it navigates by
  ## GameObject NAME plus a `visible` filter (menu captions live in
  ## `DefaultUIButton._text`, which `findtext` cannot see), it ticks practice
  ## mode -- without which the client runs ONLINE matchmaking and aborts with "a
  ## task was cancelled" -- and it goes inspector-silent during the load, because
  ## an inspector command stalls the Unity main thread and times matchmaking out.
  ## All of that is wrapped rather than reimplemented.
  ##
  ## **Its exit code is NOT the verdict.** Entry is not state. This step passing
  ## means "the entry driver ran"; `waitDeployed` is what decides whether a raid
  ## actually happened.
  s.raidAttempted = true
  if s.side == sideScav:
    return step(s, "ENTER ", vInconclusive,
                "scav-side entry is not implemented in the entry driver " &
                "(enterraid.py presses PLAY, which is the PMC path). Refusing " &
                "rather than entering as a PMC and calling it a scav run.")
  var py = s.entryDriver
  if py.len == 0:
    py = absolutePathOf("tools\\enterraid.py")
  if not exists(py):
    return step(s, "ENTER ", vInconclusive,
                "cannot find the entry driver (looked at " & py &
                "). Run the script from the repo root, or name it with " &
                "withEntryDriver(s, path).")
  say(s, "ENTER   python " & py & " " & s.map)
  var pyExe = "python"
  var pyWd = parentOf(py)
  var pyCmd = "python \"" & py & "\" \"" & s.map & "\""
  let h = cSpawn(toCString(pyExe), toCString(pyWd), toCString(pyCmd))
  if h == 0'u64:
    return step(s, "ENTER ", vInconclusive,
                "could not start python for " & py &
                " -- is python on PATH?")
  var waited = 0
  while waited < 600 and cSpawnAlive(h) != 0'i32:
    cSleepMs(2000'i32)
    waited = waited + 2
  if cSpawnAlive(h) != 0'i32:
    return step(s, "ENTER ", vInconclusive,
                "the entry driver was still running after 600s")
  result = step(s, "ENTER ", vPass,
                "the entry driver finished after ~" & $waited &
                "s. This is NOT proof of deployment -- see DEPLOY.")

proc waitDeployed*(s: var Script; seconds: int): bool =
  ## Wait for the raid-phase LATCH to say DEPLOYED.
  ##
  ## Three outcomes, and the third one is real:
  ##
  ##   PASS          the host log carried `raid phase = DEPLOYED`
  ##   FAIL          it carried `raid phase = <something else>` and never
  ##                 DEPLOYED within the budget -- the latch looked and said no
  ##   INCONCLUSIVE  it carried NO `raid phase =` line at all, so the latch never
  ##                 reported. That is an instrument that did not run, not a raid
  ##                 that did not happen, and the two must not share a verdict.
  let path = hostLogPath(s)
  if not exists(path):
    return step(s, "DEPLOY", vInconclusive,
                "there is no " & path & ", so the raid-phase latch cannot be " &
                "observed at all")
  var waited = 0
  var anyPhase = false
  while waited < seconds:
    let tail = readTail(path, 0)
    if find(tail, DeployedMarker) >= 0:
      s.entered = true
      s.phaseSeen = "DEPLOYED"
      return step(s, "DEPLOY", vPass,
                  "the raid-phase latch reported DEPLOYED after ~" & $waited &
                  "s (GameWorld cached, MainPlayer Unity-alive and in " &
                  "AllAlivePlayersList, Camera.main live)")
    let at = find(tail, PhaseMarker)
    if at >= 0:
      anyPhase = true
      var i = at + PhaseMarker.len
      var name = ""
      while i < tail.len and tail[i] != ' ' and tail[i] != '\r' and
            tail[i] != '\n':
        name.add tail[i]
        inc i
      s.phaseSeen = name
    cSleepMs(3000'i32)
    waited = waited + 3
  if anyPhase:
    return step(s, "DEPLOY", vFail,
                "the raid-phase latch reported \"" & s.phaseSeen &
                "\" and never DEPLOYED within " & $seconds & "s")
  result = step(s, "DEPLOY", vInconclusive,
                "the host log carried no `raid phase =` line in " & $seconds &
                "s, so the latch never reported. That is NOT 'you did not " &
                "deploy'. It needs host flags debugEsp + natEsp + natEspDiag, " &
                "which are read at boot; see armPhaseReporting.")

# ---------------------------------------------------------------------------
# Step 5 -- ACTUATION. Driving the player, from out here.
#
# THE CHANNEL, AND WHY THIS ONE.
# ------------------------------
# `autoscript` is a separate process; `pact` lives inside the game. Three
# candidates existed and two are unsuitable, for reasons rather than taste:
#
#   an HTTP endpoint in the client   IMPOSSIBLE. A client-side mod's `serve()`
#                                    registers into nothing -- the listener is
#                                    the backend's, in another process.
#   a host config key                A LEVEL, NOT AN EDGE. A key can say
#                                    "actuation is on"; it cannot say "do one
#                                    magazine cycle NOW", it cannot be said
#                                    twice, and it has nowhere to put an answer.
#   the inspector file channel       CHOSEN. It is already an outside-process ->
#                                    Unity-main-thread pipe, content-change
#                                    triggered, with a serial line to re-run the
#                                    same request, a per-command SEH guard, and
#                                    an existing write gate (`allow write`) that
#                                    is exactly the right gate for a verb that
#                                    calls into game code.
#
# THE ANSWER COMES BACK BY LOG, NOT BY FILE, and that is deliberate. The
# inspector's own out-file is written per batch; pact executes on the NEXT drain
# frame, after the batch has been answered. So the host log is the medium of
# record for the outcome, the same log this runner already tails for the
# raid-phase latch -- one instrument, not two.
#
# WHAT EACH OUTCOME MEANS. `pact-rpc: QUEUED` is the REQUEST ARRIVING, and is
# never treated as the request succeeding. The outcome of a magazine cycle is a
# separate later line the game's own count readback produces.
# ---------------------------------------------------------------------------

const
  RpcQueued = "pact-rpc: QUEUED"
  RpcRefused = "pact-rpc: REFUSED"
  MagComplete = "pact magcycle: COMPLETE"
  MagWarn = "pact magcycle: "
  AmmoFired = "ammoloading  FIRST FIRING"
  AmmoFiringHeartbeat = "ammoloading  ARMED and FIRING"
  AmmoNeverFired = "ammoloading  ARMED but NEVER FIRED"
  AmmoNotArmed = "ammoloading  NOT ARMED"

proc inspectSend(s: var Script; request: string): bool =
  ## Drop one `pact` request into the inspector command file. Returns false only
  ## if the file could not be written; ARRIVAL is a separate question, answered
  ## by `pactDo` reading the log.
  let path = joinPath(s.root, "aowlspt\\aowlspt-inspect.txt")
  s.inspSerial = s.inspSerial + 1
  # The serial line is not decoration: the channel triggers on a CONTENT CHANGE,
  # so `pact magcycle` twice in a row with no serial would run ONCE and the
  # second call would wait out its whole budget on the first one's answer.
  let body = "#" & $s.inspSerial & "\n" &
             "allow write\n" &
             "pact " & request & "\n"
  writeWhole(path, body)

proc waitForLine(s: var Script; fromByte: int64; marker: string;
                 seconds: int): bool =
  ## Poll the host log for a literal, from a byte offset taken BEFORE the thing
  ## that should produce it. The offset matters: without it a marker left by an
  ## earlier cycle in the same run reads as this cycle's answer, which is a check
  ## that cannot fail.
  let path = hostLogPath(s)
  var waited = 0
  while waited < seconds:
    if find(readTail(path, fromByte), marker) >= 0:
      return true
    cSleepMs(1000'i32)
    waited = waited + 1
  false

proc pactDo*(s: var Script; request: string; seconds: int = 20): bool =
  ## Send one pact request and wait for the host to say it ARRIVED.
  ##
  ##   PASS          the host log carried `pact-rpc: QUEUED "<request>"`
  ##   FAIL          it carried `pact-rpc: REFUSED` -- the host looked at the
  ##                 request and declined it, and its own line says why
  ##   INCONCLUSIVE  neither line appeared. The request never reached pact: the
  ##                 inspector is off, the write gate is off, or the client is
  ##                 not draining. That is an instrument that did not run.
  ##
  ## `request` is the pact sub-command verbatim -- "magcycle", "wait 60",
  ## "move 0 1 90", "look 5 0", "fire on", "reload", "status".
  let label = "PACT  "
  if not exists(hostLogPath(s)):
    return step(s, label, vInconclusive,
                "there is no host log, so no pact answer could ever be read")
  let mark = logSize(s)
  s.actuations = s.actuations + 1
  if not inspectSend(s, request):
    return step(s, label, vInconclusive,
                "could not write the inspector command file under " & s.root &
                "\\aowlspt -- the request was never sent")
  say(s, label & "  sent `pact " & request & "` (batch #" & $s.inspSerial & ")")
  if waitForLine(s, mark, RpcQueued & " \"" & request & "\"", seconds):
    s.actuationsOk = s.actuationsOk + 1
    return step(s, label, vPass,
                "the host accepted `pact " & request &
                "`. ACCEPTED IS NOT DONE -- the effect is asserted separately.")
  let tail = readTail(hostLogPath(s), mark)
  let at = find(tail, RpcRefused)
  if at >= 0:
    var line = ""
    var i = at
    while i < tail.len and tail[i] != '\r' and tail[i] != '\n':
      line.add tail[i]
      inc i
    return step(s, label, vFail, "the host REFUSED it -- " & line)
  result = step(s, label, vInconclusive,
                "the host log carried no `pact-rpc:` line for `" & request &
                "` in " & $seconds & "s, so the request never reached pact. " &
                "That is NOT 'the actuation failed'. It needs host flags " &
                "playerActuation + liveInspector + liveInspectorWrite, which " &
                "are read at BOOT; see withActuation / armActuation.")

# ---------------------------------------------------------------------------
# The actuation verbs
# ---------------------------------------------------------------------------
#
# Every verb below is a thin, TYPED wrapper over `pactDo`, and every one of them
# is honest about the same thing: `pactDo` proves the host ACCEPTED the request,
# which is not proof the player moved. Accepting is a fact about the channel;
# moving is a fact about the game.
#
# So there are two tiers, and they are deliberately not the same call:
#
#   walk / look / fire / ...     ISSUE the request. PASS means accepted.
#   walkAndSee / actuated(...)   ISSUE it and then read pact's OWN readback
#                                counters back, which are computed from the
#                                game's `get_Position` and not from our write.
#
# A script that only ever calls the first tier has not demonstrated actuation,
# and `finish` says so via `actuationsOk` rather than letting it read as a pass.

proc fnum(v: float): string =
  ## A float pact's own `iParseF` can read back. `$` on a float is not used
  ## anywhere in this repo (`formatFloat` is the idiom in botnav/botdiag), and a
  ## scientific-notation "1e-05" reaching pact would be REFUSED as a malformed
  ## number rather than coerced to zero -- which is the right refusal, but a
  ## confusing one to hit because of a formatter.
  formatFloat(v, ffDecimal, 3)

proc counterOf(line, key: string): int =
  ## `asked=12` -> 12, from pact's own status line. Returns -1 when the key is
  ## absent, which is NOT zero: "the counter says none" and "there is no
  ## counter" are different observations and collapsing them would let a status
  ## line pact never printed read as a clean run.
  result = -1
  let want = key & "="
  let at = find(line, want)
  if at < 0: return
  var i = at + want.len
  var n = 0
  var any = false
  while i < line.len and line[i] >= '0' and line[i] <= '9':
    n = n * 10 + (int(line[i]) - int('0'))
    any = true
    inc i
  if any: result = n

proc pactStatusLine*(s: var Script; seconds: int = 15): string =
  ## pact's counter line, or "" when it did not answer. Diagnostic AND the basis
  ## of every effect assertion below.
  let mark = logSize(s)
  if not inspectSend(s, "status"): return ""
  if not waitForLine(s, mark, "pact-rpc: status ", seconds): return ""
  let tail = readTail(hostLogPath(s), mark)
  let at = find(tail, "pact-rpc: status ")
  var line = ""
  var i = at
  while i < tail.len and tail[i] != '\r' and tail[i] != '\n':
    line.add tail[i]
    inc i
  result = line

proc checkPactVersion*(s: var Script): bool =
  ## THE HOST HALF OF THE HANDSHAKE. Ask the deployed host DLL's pact what verbs
  ## it has, and refuse if this script needs one it does not.
  ##
  ## Only meaningful for a script that declared `withActuation`; a gear-only
  ## script is not making a claim about the host and is not failed for one.
  ##
  ##   PASS          every verb this script needs is in the host's `caps` line
  ##   FAIL          the line came back and a needed verb is absent -- a stale
  ##                 host DLL, measured
  ##   INCONCLUSIVE  no `caps` line at all. Either the host predates the
  ##                 handshake or the inspector channel is not draining, and
  ##                 those are not the same fact. `pact caps` is answered ABOVE
  ##                 every gate in the host, so a silent channel is the only
  ##                 reason a CURRENT host would not answer.
  if not s.actuation: return true
  let mark = logSize(s)
  if not inspectSend(s, "caps"):
    return step(s, "PVERSN", vInconclusive,
                "could not write the inspector command file under " & s.root &
                "\\aowlspt, so the host was never asked what it can do")
  if not waitForLine(s, mark, "pact-rpc: caps ", 25):
    return step(s, "PVERSN", vInconclusive,
                "the host log carried no `pact-rpc: caps` line in 25s. Either " &
                "this install's host DLL PREDATES the pact handshake, or the " &
                "inspector channel is not draining at all (liveInspector / " &
                "liveInspectorWrite are read at BOOT). Those are different " &
                "facts and this step will not guess between them.")
  let tail = readTail(hostLogPath(s), mark)
  let at = find(tail, "pact-rpc: caps ")
  var line = ""
  var i = at
  while i < tail.len and tail[i] != '\r' and tail[i] != '\n':
    line.add tail[i]
    inc i
  s.pactCapsSeen = line
  # Only the `verbs=` field. The line also carries `readback=` and `issueonly=`,
  # which are SUBSETS naming how strong each verb's evidence is; matching a need
  # against the whole line would let `readback=swap` satisfy a script that needs
  # the `swap` verb even on a build where the verb had been withdrawn.
  var verbs = ""
  let vat = find(line, "verbs=")
  if vat >= 0:
    var j = vat + 6
    while j < line.len and line[j] != ' ':
      verbs.add line[j]
      inc j
  var missing = ""
  var nMissing = 0
  for want in s.needPact:
    if not capsHave(verbs, want):
      if missing.len > 0: missing.add ","
      missing.add want
      nMissing = nMissing + 1
  if nMissing > 0:
    return step(s, "PVERSN", vFail,
                "this install's host DLL is STALE for this script: its pact " &
                "does not have [" & missing & "]. It read `" & line &
                "`. Rebuild and redeploy the host.")
  result = step(s, "PVERSN", vPass,
                "the deployed host's pact has every verb this script needs (" &
                $s.needPact.len & " asked) -- " & line)

proc actuated*(s: var Script; request: string; settleSeconds: int = 6): bool =
  ## Issue one pact request AND ASSERT IT TOOK EFFECT.
  ##
  ## The assertion is on pact's own readback counters, which it computes from
  ## `EFT.Player::get_Position` -- the game's number, maintained by the game,
  ## that this library never writes. `took` rising is metres actually travelled
  ## past `PactMinMoveM`; `noeffect` rising is the call having been made and the
  ## world not having moved.
  ##
  ##   PASS          `took` rose across the request
  ##   FAIL          `noeffect` or `never` rose -- the call was made (or dropped
  ##                 with a stated reason) and the finished state did not change
  ##   INCONCLUSIVE  the request was never accepted, pact never answered a
  ##                 status request, or neither counter moved. The last case is
  ##                 the honest one for a verb pact does not readback-check at
  ##                 all (look, fire, aim, lean): nothing was measured.
  ##
  ## NOTE, and it is the point of this proc existing: only MOVEMENT has a
  ## readback in pact today. `actuated(s, "look 5 0")` will report INCONCLUSIVE
  ## "no counter moved", which is correct and is not a pass. Do not read a
  ## silent `look` as a look that happened.
  let before = pactStatusLine(s)
  if before.len == 0:
    return step(s, "ACTUAT", vInconclusive,
                "pact never answered a status request, so no BEFORE counters " &
                "exist and no effect can be asserted for `" & request & "`")
  let took0 = counterOf(before, "took")
  let noeff0 = counterOf(before, "noeffect")
  let never0 = counterOf(before, "never")
  if took0 < 0 or noeff0 < 0:
    return step(s, "ACTUAT", vInconclusive,
                "pact's status line carries no took/noeffect counters -- it " &
                "read `" & before & "`. pact is probably not bound or not " &
                "deployed; nothing was measured.")
  if not pactDo(s, request, 20):
    return false
  # Let the world settle. pact only compares positions after PactSettleFrames,
  # so asking immediately would read the mark against itself -- a comparison of
  # a value with itself is the check that cannot fail, in its purest form.
  cSleepMs(int32(settleSeconds * 1000))
  let after = pactStatusLine(s)
  if after.len == 0:
    return step(s, "ACTUAT", vInconclusive,
                "pact accepted `" & request & "` and then never answered a " &
                "status request, so the effect was never read back")
  let took1 = counterOf(after, "took")
  let noeff1 = counterOf(after, "noeffect")
  let never1 = counterOf(after, "never")
  if took1 > took0:
    return step(s, "ACTUAT", vPass,
                "`" & request & "` TOOK: pact's own get_Position readback " &
                "counted real world movement (took " & $took0 & " -> " &
                $took1 & "). Nobody touched the keyboard.")
  if never1 > never0:
    return step(s, "ACTUAT", vFail,
                "`" & request & "` was NEVER ISSUED by pact (never " & $never0 &
                " -> " & $never1 & "); its refusal is in the host log -- " &
                after)
  if noeff1 > noeff0:
    return step(s, "ACTUAT", vFail,
                "`" & request & "` was CALLED and the world did not move " &
                "(noeffect " & $noeff0 & " -> " & $noeff1 & "). The call " &
                "reached the game and the finished state is unchanged.")
  result = step(s, "ACTUAT", vInconclusive,
                "`" & request & "` was accepted and NO readback counter moved " &
                "in " & $settleSeconds & "s. Either pact does not readback-" &
                "check this verb (only movement is checked today: look, fire, " &
                "aim, lean, pose and the ECommand channel are ISSUE-ONLY), or " &
                "the readback could not run. Nothing was measured, which is " &
                "not a pass.")

proc walk*(s: var Script; strafe, forward: float; frames: int): bool =
  ## `EFT.Player::Move(Vector2)`, held for `frames` frames.
  ##
  ## `strafe` is +right / -left, `forward` is +forward / -back; the game clamps
  ## the magnitude, so 1.0 is a full-speed input and 0.5 is a walk. `frames` is
  ## FRAMES, not seconds -- pact re-applies the held vector once per drain tick,
  ## because `Move` is an input sample and one call is one frame of walking.
  ##
  ## ISSUE-ONLY. Use `walkAndSee` for the version that asserts metres travelled.
  pactDo(s, "move " & fnum(strafe) & " " & fnum(forward) & " " & $frames, 20)

proc walkAndSee*(s: var Script; strafe, forward: float; frames: int;
                 settleSeconds: int = 6): bool =
  ## `walk`, then assert the player really moved, via pact's `get_Position`
  ## readback. THIS is the movement verb a test should use: `walk` alone can
  ## report PASS with the player wedged against a wall.
  actuated(s, "move " & fnum(strafe) & " " & fnum(forward) & " " & $frames, settleSeconds)

proc look*(s: var Script; dx, dy: float): bool =
  ## `EFT.Player::Rotate(Vector2, bool)` -- a DELTA in degrees, not an absolute
  ## heading. +dx turns right, +dy looks down (the game's own sign convention at
  ## its call sites).
  ##
  ## Issues only; PASS means the host accepted the call. `lookAndSee` is the one
  ## that asserts the aim really moved.
  pactDo(s, "look " & fnum(dx) & " " & fnum(dy), 20)

proc lookAndSee*(s: var Script; dx, dy: float; settleSeconds: int = 5): bool =
  ## `look`, and ASSERT the aim moved, from the game's own
  ## `EFT.MovementContext::get_Rotation` -- degrees of yaw and pitch the game
  ## maintains and this library never writes. The host marks the aim before the
  ## `Rotate` and re-reads it 12 drain frames later, wrapping yaw so a turn
  ## across 0 degrees is two degrees and not 358.
  ##
  ## THE INPUT THAT MAKES IT FAIL: `lookAndSee(s, 0.0, 90.0)` while already
  ## pitched fully down. The call is made, the game's own clamp refuses the
  ## delta, the aim does not move and this reports FAIL. A tiny delta below
  ## `PactMinRotDeg` (0.3 degrees) also fails, deliberately -- at that size the
  ## change is indistinguishable from idle sway.
  needsPact(s, "look")
  actuated(s, "look " & fnum(dx) & " " & fnum(dy), settleSeconds)

proc fire*(s: var Script; on: bool): bool =
  ## Hold or release the trigger -- `FirearmController::SetTriggerPressed`.
  ##
  ## REFUSED by pact, by name, unless `Player::HasFirearmInHands()` is true: on a
  ## knife or empty hands the FirearmController pointer is the abstract base and
  ## calling a FirearmController method on it is type confusion that no nil check
  ## catches. ISSUE-ONLY; the readback for "did it shoot" is the ammo count, not
  ## a pact counter.
  pactDo(s, "fire " & (if on: "on" else: "off"), 20)

proc aim*(s: var Script; on: bool): bool =
  ## Aim down sights -- `FirearmController::set_IsAiming`. Same firearm-in-hands
  ## refusal as `fire`. Issues only at this tier, but the host DOES read
  ## `get_IsAiming` back after the call, so `aimAndSee` is a real assertion.
  pactDo(s, "aim " & (if on: "on" else: "off"), 20)

proc sprint*(s: var Script; on: bool): bool =
  ## `EFT.Player::EnableSprint(bool)`. Issues only; PASS means the host accepted
  ## the request.
  ##
  ## Unlike `look`, `fire` and the stance verbs, sprint IS readback-checked in
  ## the host: `pactExec` calls `EFT.Player::get_IsSprintEnabled` immediately
  ## after `EnableSprint` and scores `took` or `noeffect` from the game's own
  ## answer. So `sprintAndSee` is a real assertion, not an aspiration -- use it.
  pactDo(s, "sprint " & (if on: "on" else: "off"), 20)

proc sprintAndSee*(s: var Script; on: bool; settleSeconds: int = 4): bool =
  ## `sprint`, and ASSERT the game agrees. The evidence is
  ## `Player::get_IsSprintEnabled` read back by the host after the call -- a
  ## boolean the game maintains and this library never writes.
  ##
  ## Its failing input is nameable: ask to sprint while prone, or while
  ## overweight, and the game refuses the state change; `get_IsSprintEnabled`
  ## still reads false and this reports FAIL.
  needsPact(s, "sprint")
  actuated(s, "sprint " & (if on: "on" else: "off"), settleSeconds)

proc aimAndSee*(s: var Script; on: bool; settleSeconds: int = 4): bool =
  ## `aim`, and ASSERT it. The host reads `FirearmController::get_IsAiming`
  ## back after `set_IsAiming` and scores took/noeffect from it.
  needsPact(s, "aim")
  actuated(s, "aim " & (if on: "on" else: "off"), settleSeconds)

proc swapWeapon*(s: var Script; which: string): bool =
  ## PUT A DIFFERENT WEAPON IN HANDS. `which` is "primary", "primary2",
  ## "secondary" (the sidearm) or "knife".
  ##
  ## This travels the ECommand channel -- `GamePlayerOwner::TranslateCommand`
  ## with the ordinal the metadata declares (SelectFirstPrimaryWeapon=41,
  ## SelectSecondPrimaryWeapon=42, SelectSecondaryWeapon=43, SelectKnife=38) --
  ## and so it needs the LateUpdate capture detour to have attached. A refusal
  ## here is specifically about that channel, not about pact.
  ##
  ## ISSUE-ONLY at this tier. `swapWeaponAndSee` is the one that asserts.
  needsPact(s, "swap")
  pactDo(s, "swap " & which, 20)

proc swapWeaponAndSee*(s: var Script; which: string;
                       settleSeconds: int = 6): bool =
  ## `swapWeapon`, and ASSERT THE FINISHED STATE: a DIFFERENT weapon item is in
  ## the player's hands.
  ##
  ## The evidence is `FirearmController::get_Item`, read by the host 45 drain
  ## frames after the command was translated and compared, by pointer, with the
  ## item held when it went out. It is not the translate result -- that says the
  ## input system consumed a keypress, which is true even when the player ends
  ## up holding exactly what they were holding before.
  ##
  ## THE INPUT THAT MAKES THIS FAIL, and it is one line away: ask for
  ## `swapWeaponAndSee(s, "primary")` while the primary is already in hands. The
  ## command translates, the animation does not run, the same item comes back,
  ## and the host counts `noeffect`. That is why `scripts/weapon_swap_e2e.nim`
  ## swaps AWAY first.
  needsPact(s, "swap")
  actuated(s, "swap " & which, settleSeconds)

proc toggleInventory*(s: var Script): bool =
  ## ECommand 37, ToggleInventory -- open or close the in-raid inventory screen.
  ## A TOGGLE, so calling it twice returns the screen to where it started.
  ## ISSUE-ONLY: pact has no readback for whether the screen is up.
  needsPact(s, "inventory")
  pactDo(s, "inventory", 20)

proc examineWeapon*(s: var Script): bool =
  ## ECommand 36, ExamineWeapon -- the ammo/chamber inspect animation.
  ## ISSUE-ONLY.
  needsPact(s, "examine")
  pactDo(s, "examine", 20)

proc jump*(s: var Script): bool =
  ## `EFT.Player::Jump()`. ISSUE-ONLY.
  pactDo(s, "jump", 20)

proc prone*(s: var Script): bool =
  ## `EFT.Player::ToggleProne()`. A TOGGLE, not a set: calling it twice returns
  ## the player to where they started, which is a real way to write a test that
  ## proves nothing. ISSUE-ONLY.
  pactDo(s, "prone", 20)

proc pose*(s: var Script; delta: float): bool =
  ## `EFT.Player::ChangePose(float)`. Negative crouches, positive stands; the
  ## magnitude is a pose-level delta and NOT metres. ISSUE-ONLY.
  pactDo(s, "pose " & fnum(delta), 20)

proc lean*(s: var Script; dir: float): bool =
  ## `EFT.Player::ToggleLean(float)` -- -1 left, 0 centre, +1 right, by the
  ## game's own convention at its call sites. ISSUE-ONLY.
  pactDo(s, "lean " & fnum(dir), 20)

proc command*(s: var Script; code: int): bool =
  ## Send a raw `ECommand` through the captured `GamePlayerOwner`. 16 is reload.
  ##
  ## This channel is the one that can be UNAVAILABLE on its own: it needs the
  ## `GamePlayerOwner::LateUpdate` capture detour to have attached, and pact
  ## warns after 600 drain frames if it never did. When that happens, movement,
  ## look, fire, aim and the magazine cycle all still work -- so a FAIL here is
  ## specifically about the ECommand channel and must not be read as pact being
  ## broken.
  pactDo(s, "command " & $code, 20)

proc reload*(s: var Script): bool =
  ## `command(16)` by name. ISSUE-ONLY: it presses the reload key, and whether a
  ## magazine actually changed hands is `magCycle`'s question, not this one.
  pactDo(s, "reload", 20)

proc pactWait*(s: var Script; frames: int): bool =
  ## Hold pact's queue for `frames` frames before the next request executes.
  ## Frames, not seconds: it is a queue entry, so it composes with the held
  ## movement vector rather than sleeping this process.
  pactDo(s, "wait " & $frames, 20)

proc magCycle*(s: var Script; seconds: int = 60): bool =
  ## THE USER'S OWN EXAMPLE, with nobody at the keyboard: unload the magazine in
  ## the weapon and load the same ammunition back.
  ##
  ## Four outcomes, each naming its own stage:
  ##
  ##   INCONCLUSIVE  the request never reached pact (see `pactDo`)
  ##   FAIL          pact REFUSED it -- no firearm in hands, not deployed, a hop
  ##                 that did not validate. Nothing was issued.
  ##   FAIL          the cycle was ISSUED and did not complete -- the game's own
  ##                 `Magazine.Count` did not come back. A PARTIAL load counts
  ##                 here, on purpose.
  ##   PASS          `pact magcycle: COMPLETE`, which is that same count
  ##                 readback -- a number the game maintains and we never write.
  let mark = logSize(s)
  if not pactDo(s, "magcycle", 20):
    return false
  if waitForLine(s, mark, MagComplete, seconds):
    return step(s, "MAGCYC", vPass,
                "the magazine was unloaded and reloaded, and the game's own " &
                "Magazine.Count came back. Nobody touched the keyboard.")
  let tail = readTail(hostLogPath(s), mark)
  let at = find(tail, MagWarn)
  if at >= 0:
    var line = ""
    var i = at
    while i < tail.len and tail[i] != '\r' and tail[i] != '\n':
      line.add tail[i]
      inc i
    return step(s, "MAGCYC", vFail,
                "the cycle did not complete -- " & line)
  result = step(s, "MAGCYC", vInconclusive,
                "pact accepted the request but the host log carried neither `" &
                MagComplete & "` nor a `" & MagWarn & "` line in " & $seconds &
                "s. The cycle was queued and its state machine never reported. " &
                "That is a run that could not look.")

proc assertAmmoLoadingFired*(s: var Script; seconds: int = 40): bool =
  ## Did `mods/ammoloading` OBSERVE the cycle?
  ##
  ## This is the negative-shaped end of the test and the only part that speaks
  ## for the mod. It asserts on the MOD'S OWN announcement, not on ours:
  ##
  ##   PASS          `ammoloading  FIRST FIRING` (or a heartbeat reading ARMED
  ##                 and FIRING) after the cycle
  ##   FAIL          the mod says `ARMED but NEVER FIRED` -- it was installed,
  ##                 it was watching, and the detour did not fire. THIS IS THE
  ##                 VERDICT THE WHOLE SCRIPT EXISTS TO BE ABLE TO PRODUCE.
  ##   INCONCLUSIVE  `NOT ARMED`, or nothing at all -- no hook is installed, so
  ##                 a zero counter says nothing about whether loading happened
  let mark = logSize(s)
  if waitForLine(s, mark, AmmoFired, seconds):
    return step(s, "AMMOLD", vPass,
                "mods/ammoloading announced its FIRST FIRING of " &
                "LoadMagazineProcess::Start after our cycle. The trigger " &
                "fires, which is the thing that had never been demonstrated.")
  let tail = readTail(hostLogPath(s), 0)
  if find(tail, AmmoFired) >= 0 or find(tail, AmmoFiringHeartbeat) >= 0:
    return step(s, "AMMOLD", vPass,
                "mods/ammoloading is ARMED and FIRING (its announcement " &
                "predates this cycle's window, so this is the mod's state, " &
                "not this cycle's edge).")
  if find(tail, AmmoNeverFired) >= 0:
    return step(s, "AMMOLD", vFail,
                "mods/ammoloading is ARMED but NEVER FIRED: the hook is " &
                "installed and verified, a magazine cycle completed, and " &
                "LoadMagazineProcess::Start did not fire. The mod did not " &
                "see it.")
  if find(tail, AmmoNotArmed) >= 0:
    return step(s, "AMMOLD", vInconclusive,
                "mods/ammoloading reports NOT ARMED -- no hook is installed, " &
                "so its counters say nothing. Put it on the `probe` rung " &
                "with withAmmoLoading(s, \"probe\") BEFORE the launch.")
  result = step(s, "AMMOLD", vInconclusive,
                "mods/ammoloading said nothing at all in " & $seconds &
                "s -- neither a firing, nor a heartbeat, nor NOT ARMED. The " &
                "mod may not be installed in " & s.root &
                ". Nothing was observed, which is not the same as nothing " &
                "having happened.")

proc pactStatusNote*(s: var Script) =
  ## Ask pact for its counter line and put it in the transcript. Diagnostic
  ## only: it changes no verdict, because a counter line is what you READ when a
  ## verdict has already been reached, not the verdict itself.
  let mark = logSize(s)
  discard inspectSend(s, "status")
  if waitForLine(s, mark, "pact-rpc: status ", 15):
    let tail = readTail(hostLogPath(s), mark)
    let at = find(tail, "pact-rpc: status ")
    var line = ""
    var i = at
    while i < tail.len and tail[i] != '\r' and tail[i] != '\n':
      line.add tail[i]
      inc i
    say(s, "PACT    " & line)
  else:
    say(s, "PACT    pact never answered a status request; no counters to show")

# ---------------------------------------------------------------------------
# The verdict
# ---------------------------------------------------------------------------

proc finish*(s: var Script): int =
  ## Print the transcript's conclusion and return the process exit code:
  ## 0 PASS, 1 FAIL, 2 INCONCLUSIVE.
  ##
  ## The "never entered a raid" rule is enforced HERE, once, rather than trusted
  ## to every step: a script whose latch never said DEPLOYED cannot report PASS,
  ## whatever else went right.
  if s.steps == 0:
    s.verdict = vInconclusive
    s.reason = "no step ran, so nothing was measured"
  if s.verdict == vPass and s.raidAttempted and not s.entered:
    s.verdict = vInconclusive
    s.reason = "every step passed but the raid-phase latch never said " &
               "DEPLOYED, so no raid was observed. A run that could not look " &
               "is not a pass."
  if s.verdict == vPass and s.actuation and s.actuations == 0:
    # A script that DECLARED it drives the player and then drove nothing has not
    # tested actuation; reporting PASS for it would be a check that cannot fail.
    s.verdict = vInconclusive
    s.reason = "this script declared withActuation and then sent no pact " &
               "request at all, so nothing about actuation was measured."
  if s.verdict == vPass:
    s.reason = "gear read back " & $s.gearPlaced & "/" & $s.gearRequested &
               (if s.entered: " and the raid-phase latch said DEPLOYED"
                elif s.raidAttempted: ""
                else: "; no raid was attempted by this script")
  echo ""
  echo "=== " & s.name & ": " & verdictName(s.verdict) & " ==="
  echo "    " & s.reason
  echo "    map=" & s.map & " side=" &
       (if s.side == sideScav: "scav" else: "pmc") &
       " profile=" & (if s.profileName.len > 0: s.profileName else: "(none)") &
       " gear requested/minted/placed=" & $s.gearRequested & "/" &
       $s.gearMinted & "/" & $s.gearPlaced &
       " phase=" & (if s.phaseSeen.len > 0: s.phaseSeen else: "(never reported)") &
       (if s.actuation: " pact sent/accepted=" & $s.actuations & "/" &
                        $s.actuationsOk
        else: "")
  case s.verdict
  of vPass: 0
  of vFail: 1
  of vInconclusive: 2

proc runToRaid*(s: var Script; deploySeconds: int = 420): bool =
  ## Everything `run` does EXCEPT the verdict: stack, profile, gear, entry, and
  ## the raid-phase latch. Returns true only when the latch actually said
  ## DEPLOYED, so a script can put in-raid work after it without having to
  ## re-derive what "we are in a raid" means.
  ##
  ## A script that uses this owns its own ending: call `finish(s)` and
  ## `quitWith` it, or the run reports nothing.
  if not launchStack(s): return false
  if not checkVersion(s): return false
  if not checkPactVersion(s): return false
  if not pickProfile(s): return false
  if not applyGear(s): return false
  if not enterRaid(s): return false
  result = waitDeployed(s, deploySeconds)

proc run*(s: var Script): int =
  ## Every step in order, stopping at the first that does not PASS. Returns the
  ## exit code -- `quit run(s)` is the whole of a script's main.
  ##
  ## THE HANDSHAKE IS BEFORE THE GEAR, deliberately. Minting against an install
  ## of unknown age and then discovering it was stale leaves a profile full of
  ## items the script did not mean to ask for; refusing first leaves it alone.
  if launchStack(s):
    if checkVersion(s):
      if checkPactVersion(s):
        if pickProfile(s):
          if applyGear(s):
            if enterRaid(s):
              discard waitDeployed(s, 420)
  result = finish(s)

proc verdictOf*(s: Script): string =
  ## The worst verdict any step has reported so far, as a word. For a script
  ## that inverts or branches on the outcome -- `scripts/gear_must_fail.nim` is
  ## the one that must.
  verdictName(s.verdict)

proc reasonOf*(s: Script): string = s.reason

proc quitWith*(code: int) =
  ## Exit with an explicit code, so a script need not `import std/syncio` for
  ## `quit` alone. 0 PASS, 1 FAIL, 2 INCONCLUSIVE -- and nothing else, because a
  ## fourth code would be a fourth outcome nothing knows how to read.
  quit(code)

proc runAndQuit*(s: var Script) =
  ## `run` and exit with its code. This exists so a script does not have to
  ## `import std/syncio` for `quit` alone -- the one-line main of every script
  ## is `runAndQuit(s)`.
  quit(run(s))
