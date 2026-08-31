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
##     equip(s, "FirstPrimaryWeapon", "5447a9cd4bdc2dbd208b4567")   # M4A1
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
         entered: false, steps: 0, raidAttempted: false)

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

proc addGear(s: var Script; g: Gear) =
  s.gear.add g

proc equip*(s: var Script; slot, tpl: string) =
  ## Wear one item in one of the 14 equipment slots. A slot holds ONE thing;
  ## asking for more is refused by name rather than silently placing the first.
  addGear(s, Gear(tpl: tpl, query: tpl, slot: slot, inside: "", count: 1,
                  ammo: "", condition: 100))

proc equipLoaded*(s: var Script; slot, tpl, ammo: string) =
  ## Wear it, and fill its cartridges with `ammo` to the capacity the TEMPLATE
  ## declares. Refused, with a reason, when the template's cartridge filter does
  ## not accept that round -- a magazine "filled" with ammo the filter omits is
  ## a gun that spawns empty.
  addGear(s, Gear(tpl: tpl, query: tpl, slot: slot, inside: "", count: 1,
                  ammo: ammo, condition: 100))

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
  addGear(s, Gear(tpl: tpl, query: tpl, slot: "", inside: container,
                  count: count, ammo: "", condition: 100))

proc carryLoaded*(s: var Script; container, tpl: string; count: int;
                  ammo: string) =
  ## `count` magazines in the container, each loaded with `ammo`. This is the
  ## "magazines = 3, ammo = m855a1" case.
  addGear(s, Gear(tpl: tpl, query: tpl, slot: "", inside: container,
                  count: count, ammo: ammo, condition: 100))

proc stock*(s: var Script; tpl: string; count: int) =
  ## `count` of an item loose in the stash, stack-limit aware and merged into
  ## stacks already there. For spares the raid does not start with.
  addGear(s, Gear(tpl: tpl, query: tpl, slot: "", inside: "", count: count,
                  ammo: "", condition: 100))

proc byName*(s: var Script; query: string; count: int) =
  ## Stash `count` of whatever the English item name `query` names. Convenient
  ## and deliberately strict: an AMBIGUOUS name is REFUSED and the candidates
  ## are listed, because "the first match" is an arbitrary document order and a
  ## test that equipped the wrong rifle proves nothing.
  addGear(s, Gear(tpl: "", query: query, slot: "", inside: "", count: count,
                  ammo: "", condition: 100))

proc wear*(s: var Script; slot, tpl: string; condition: int) =
  ## `equip` with a durability/resource percentage, applied only to the
  ## properties the template actually declares.
  addGear(s, Gear(tpl: tpl, query: tpl, slot: slot, inside: "", count: 1,
                  ammo: "", condition: condition))

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

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
    return step(s, "STACK ", vPass, "attached to a running backend -- " & why)

  if not s.launch:
    return step(s, "STACK ", vInconclusive,
                "nothing is running and this script said attachOnly -- " & why)

  let exe = joinPath(s.root, "aowlspt\\aowlspt-launch.exe")
  if not exists(exe):
    return step(s, "STACK ", vInconclusive,
                "there is no " & exe & ", so this install cannot be launched")

  discard armPhaseReporting(s)

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
          let mark = if got >= want and want > 0: "  ok " else: "  XX "
          say(s, mark & jsonStr(one, "where") & "  " &
                 jsonStr(one, "name") & "  req=" & $want & " base=" & $base &
                 " minted=" & $mint & " placed=" & $got &
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
       " phase=" & (if s.phaseSeen.len > 0: s.phaseSeen else: "(never reported)")
  case s.verdict
  of vPass: 0
  of vFail: 1
  of vInconclusive: 2

proc run*(s: var Script): int =
  ## Every step in order, stopping at the first that does not PASS. Returns the
  ## exit code -- `quit run(s)` is the whole of a script's main.
  if launchStack(s):
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
