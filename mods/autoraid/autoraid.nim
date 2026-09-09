## aowl.autoraid -- ENTER (AND LEAVE) A RAID WITHOUT TOUCHING THE MOUSE.
##
##     python tools\buildlock.py build mod autoraid
##
## ===========================================================================
## THREE FEATURES, ONE DLL, TWO PROCESSES
## ===========================================================================
##
## 1. **A command-line raid.** `aowlspt-launch --raid="Woods"` becomes
##    `-aowl.raid=Woods` on the client's command line. Once the host's
##    main-thread drain has fired, the mod drives the main menu into an offline
##    raid on that map. Zero clicks from launch to deployed.
##
## 2. **A map menu on a key.** `F8` by default, gated behind `hotkeys` (OFF as
##    shipped). An overlay list of maps drawn on the host's shared region;
##    Up/Down or 1-9 to choose, Enter to go. `enterKey` skips the menu entirely
##    and enters `defaultMap`.
##
## 3. **A spawned default loadout.** SERVER SIDE. `loadoutMode = spawned` has a
##    kit CREATED for each raid from `loadout.json`; the gear you were wearing
##    is moved to the stash first (never destroyed) and every created item is
##    stripped at match end so none of it reaches the stash. The shipped value
##    is `current`, which does nothing at all.
##
## ===========================================================================
## WHAT THIS MOD DOES *NOT* DO, AND WHY EACH ONE MATTERS
## ===========================================================================
##
## **It installs no detour.** Not one. Two detours on one function have the
## second overwrite the first's trampoline and silently kill the first feature,
## and the functions this flow cares about -- `TarkovApplication::Update`,
## `PreloaderUI::Update`, every `Screen::Show` -- are already hooked by the
## host. The mod RIDES what exists: `everyMain` for the per-frame tick, the
## `ui.show` event bus for screen arrivals, the shared region for drawing.
##
## **It resolves no IL2CPP name.** Fact #145: resolving a name is harmless and
## USING one is fatal -- three separate features killed the client that way.
## Every call goes to an RVA byte-verified against the sixteen bytes it is
## declared to begin with (`ar/calls.nim`).
##
## **It writes NOTHING into game memory.** Not one managed field, not one byte.
## Every state change it makes is a CALL to the method the game itself calls --
## `Toggle::Set`, `TweenAnimatedButton::OnPointerClick`, `Button::Press` --
## which is why `tools/storelint.py` has nothing to find here.
##
## **It enumerates no scene roots.** `Scene::GetRootGameObjects` allocates, and
## in a raid it enumerates the LOCATION scene, where the menu is not. Every
## screen comes from its own `::Show` receiver and every root is reached by
## climbing from one with `Transform::get_root`.
##
## ===========================================================================
## THE THREE VERDICTS, AND WHAT WOULD FALSIFY EACH
## ===========================================================================
##
## `AutoRaid CMDLINE VERDICT PASS` is emitted when the host reports phase
## `DEPLOYED` -- the game's own deploy signal -- not when the last button press
## returned. It FAILS when the state machine refuses, and it is INCONCLUSIVE
## (with the reason) when the host cannot answer the phase question or the
## four-minute bound expires with the machine still working.
##
## `AutoRaid MENU VERDICT` reads back the REGION's own counters and asks whether
## anything was actually PAINTED while the menu was open. "The mod set its open
## flag" is not evidence and is not what it checks.
##
## `AutoRaid LOADOUT VERDICT` is `mods/tarkov`'s, logged verbatim, because the
## only process that can read the saved profile back is the one that saved it.
##
## ===========================================================================
## FILE MAP
## ===========================================================================
##   ar/native.nim       the ONE C translation unit: guarded reads, the hotkey,
##                       the region draw callback over a POD mirror
##   ar/calls.nim        every call into the game, byte-verified, in one place
##   ar/uitree.nim       bounded, breadth-first walkers
##   ar/press.nim        three klasses, three routes; no generic press
##   ar/showbus.nim      the `ui.show` oracle and the screen receivers
##   ar/phase.nim        "where is the client, really?", asked of the host
##   ar/machine.nim      the raid-ENTRY state machine
##   ar/exitmachine.nim  the raid-EXIT state machine
##   ar/menu.nim         the map menu on a key
##   ar/cmdline.nim      the two declared `-aowl.*` arguments
##   ar/cfg.nim          the settings schema
##   ar/loadoutclient.nim the server half
##
## Read `docs/AUTORAID-MAP.md` for the three flows with the evidence behind
## each claim, and `mods/autoraid/README.md` for the user-facing half.

import aowlspt
import aowlspt/server
import aowlspt/settings
import aowlspt/json
import ar / native
import ar / calls
import ar / uitree
import ar / showbus
import ar / phase
import ar / machine
import ar / exitmachine
import ar / menu
import ar / cmdline
import ar / cfg
import ar / loadoutclient

const
  ModGuid = "aowl.autoraid"
  ModName = "AutoRaid"
  ModAuthor = "aowlspt"
  ModVersion = "0.1.0"

  CmdlineBoundMs = 240000'i64
    ## FOUR MINUTES from arming to a verdict on the command-line raid. Generous
    ## on purpose: WAIT-MENU alone is allowed three, because the menu can take
    ## well over a minute on a cold launch. Past this the verdict is
    ## INCONCLUSIVE WITH A REASON -- never a silent give-up, and never a FAIL,
    ## because "it was still working when I stopped watching" is not a failure.
  PhasePollMs = 2000'i64
    ## How often the phase is polled while waiting for DEPLOYED. A bounded
    ## cadence rather than every frame: the verb is cheap, not free.
  ExitBoundMs = 240000'i64
    ## Four minutes from arming the exit to a verdict on it. The results chain
    ## after a raid can take a while; past this the verdict is INCONCLUSIVE
    ## with the step named -- never a silent give-up.

# ---------------------------------------------------------------------------
# Client-side state
# ---------------------------------------------------------------------------

var gDrainBound = false      ## the host's main-thread drain has actually FIRED
var gTickArmed = false       ## `everyMain` is registered
var gCmdlineArmed = false    ## the command-line raid has been armed
var gCmdlineVerdict = false  ## ...and its verdict has been printed
var gCmdlineT0 = 0'i64
var gLastPhasePoll = 0'i64
var gDrainWaits = 0
var gSaidNoDrain = false
var gDeployedAt = 0'i64      ## when the cmdline raid's PASS verdict fired
var gExitArmed = false       ## the exit machine has been armed by -aowl.raidexit
var gExitVerdict = false     ## ...and its verdict has been printed
var gExitT0 = 0'i64
var gLastExitPoll = 0'i64
var gExitSaidWait = false

# The BUS arm (`autoraid.arm`). Another client-side mod asks for a raid over the
# host's event bus instead of the command line; it lands on the SAME
# `machine.arm` and the SAME refusals.
#
# THREADING. An event handler runs on whichever thread EMITTED the event, and a
# module-level Nim STRING assigned from a foreign thread is the measured
# `corrupted thread-free list` crash -- an ARC value freed on a thread that does
# not own it (`ar/showbus.nim`'s header). So the three strings this request
# carries are staged in PLAIN CHAR ARRAYS, which are POD and owned by nobody,
# and are turned back into Nim strings on the main thread where they are used.
const BusTextCap = 64
var gBusMapBuf: array[BusTextCap, char]
var gBusMapLen = 0
var gBusSideBuf: array[BusTextCap, char]
var gBusSideLen = 0
var gBusSrcBuf: array[BusTextCap, char]
var gBusSrcLen = 0
var gBusExitAfter = 0        ## `exitAfterSeconds` from the request; 0 = stay
var gBusPending = false      ## a request is queued for the main thread
var gBusArmed = false        ## ...and `machine.arm` accepted it
var gBusVerdict = false
var gBusT0 = 0'i64
var gLastBusPoll = 0'i64
var gBusRequests = 0
var gBusRefusals = 0

proc stash(dst: var array[BusTextCap, char]; n: var int; s: string) =
  ## Copy at most `BusTextCap` bytes. TRUNCATES rather than overflowing; the
  ## map cap `machine.arm` enforces is 32, so a 64-byte stage cannot silently
  ## turn an over-long label into an acceptable one.
  var i = 0
  while i < s.len and i < BusTextCap:
    dst[i] = s[i]
    i = i + 1
  n = i

proc unstash(src: array[BusTextCap, char]; n: int): string =
  result = ""
  var i = 0
  while i < n:
    result.add src[i]
    i = i + 1

proc exitAfter(): int =
  ## Seconds to dwell after DEPLOYED, from whichever request armed this raid.
  if gBusArmed: gBusExitAfter else: exitAfterSeconds()

# ---------------------------------------------------------------------------
# The main-thread gate.
#
# `call("aowlspt.host::main_thread")` reports `bound` only once the host's drain
# has ACTUALLY FIRED on Unity's thread. That is the gate everything here waits
# on, and NOT BOUND IS A REFUSAL, NOT A FALLBACK: `UnityEngine.Input::GetKey*`
# and every managed call below are documented ways to crash a frame or two later
# when made from the host's own thread. MEASURED, crash Crash_2026-09-02_211541986:
# a mod's `everyMain` tick ran on the HOST's thread and called `Input::GetKey`,
# whose native body fetches a global manager pointer and dereferences it at
# +0x4A0 with NO null test. The pointer was NULL.
# ---------------------------------------------------------------------------

proc drainBound(): bool =
  if gDrainBound: return true
  var raw = ""
  let empty = "[]"
  if call("aowlspt.host::main_thread", empty, raw) != Ok or raw.len == 0:
    return false
  if not asBool(field(raw, "bound"), false): return false
  gDrainBound = true
  info "AutoRaid: the host's main-thread drain is BOUND (" &
       asText(field(raw, "method"), "?") & ", " &
       $asInt(field(raw, "frames"), 0) & " frame(s), thread " &
       $asInt(field(raw, "mainThreadId"), 0) & "). Everything that touches " &
       "the client is unblocked from here; before this point nothing was " &
       "called, because a call from the host's own thread is the documented " &
       "way to crash a frame or two later."
  result = true

# ---------------------------------------------------------------------------
# The one per-frame tick. Unity's thread, once per host drain.
# ---------------------------------------------------------------------------

proc onMainTick(payload: string): string =
  ## ONE `everyMain` slot for the whole mod. Cheap when nothing is happening:
  ## the machines return on an integer compare when they are not armed, and the
  ## menu poll returns on one compare when `hotkeys` is off, which is shipped.
  result = ""
  menu.poll()
  machine.tick()
  exitmachine.tick()

  # The command-line verdict. Polled on a bounded cadence, and it reports the
  # FINISHED STATE the host observes -- not the fact that we armed something.
  if gCmdlineArmed and not gCmdlineVerdict:
    let now = nowMs()
    if machine.failed():
      gCmdlineVerdict = true
      warn "AutoRaid CMDLINE VERDICT FAIL -- " & machine.answer()
    elif now - gLastPhasePoll >= PhasePollMs:
      gLastPhasePoll = now
      let p = raidPhase()
      if deployed(p):
        gCmdlineVerdict = true
        gDeployedAt = now
        success "AutoRaid CMDLINE VERDICT PASS -- the client reports phase " &
                "DEPLOYED for map \"" & machine.wantedMap() & "\" (" & p.why &
                "). That is the game's OWN deploy signal, not this mod " &
                "reporting that its last button press returned. Screens " &
                "advanced: " & $machine.screensAdvanced() & "."
      elif not p.asked:
        if now - gCmdlineT0 > CmdlineBoundMs:
          gCmdlineVerdict = true
          warn "AutoRaid CMDLINE VERDICT INCONCLUSIVE -- this host has no " &
               "`aowlspt.host::raid_phase` verb, so whether the client " &
               "reached DEPLOYED could NOT be observed. The state machine " &
               "reached step " & machine.stage() & " and advanced " &
               $machine.screensAdvanced() & " screen(s), which is evidence " &
               "but is NOT the deploy signal. I could not look; that is not a " &
               "pass."
      elif now - gCmdlineT0 > CmdlineBoundMs:
        gCmdlineVerdict = true
        warn "AutoRaid CMDLINE VERDICT INCONCLUSIVE -- " &
             $(int(CmdlineBoundMs div 1000'i64)) & " s have passed since " &
             "arming and the client reports phase " & p.phase &
             ", not DEPLOYED. The state machine is at step " & machine.stage() &
             " having advanced " & $machine.screensAdvanced() & " screen(s), " &
             "and it has NOT refused -- so this is a bound on my patience, " &
             "not a failure of the flow. Read the AutoRaid lines above for " &
             "the step that is waiting."

  # The BUS raid's verdict. Same shape as the command-line one and deliberately
  # NOT folded into it: the two are armed by different requesters and a line
  # that says CMDLINE about an event-armed raid would send the next reader to
  # the launcher. It also sets `gDeployedAt`, which is what lets an
  # `exitAfterSeconds` in the request reach the exit machine below.
  if gBusArmed and not gBusVerdict:
    let now = nowMs()
    if machine.failed():
      gBusVerdict = true
      warn "AutoRaid BUS VERDICT FAIL -- " & machine.answer()
    elif now - gLastBusPoll >= PhasePollMs:
      gLastBusPoll = now
      let p = raidPhase()
      if deployed(p):
        gBusVerdict = true
        gDeployedAt = now
        success "AutoRaid BUS VERDICT PASS -- the client reports phase " &
                "DEPLOYED for map \"" & machine.wantedMap() & "\" (" & p.why &
                "), armed by autoraid.arm from \"" &
                unstash(gBusSrcBuf, gBusSrcLen) & "\". That is the game's OWN " &
                "deploy signal. Screens advanced: " &
                $machine.screensAdvanced() & "."
      elif now - gBusT0 > CmdlineBoundMs:
        gBusVerdict = true
        warn "AutoRaid BUS VERDICT INCONCLUSIVE -- " &
             $(int(CmdlineBoundMs div 1000'i64)) & " s since autoraid.arm " &
             "from \"" & unstash(gBusSrcBuf, gBusSrcLen) & "\" and " &
             (if p.asked: "the client reports phase " & p.phase & ", not DEPLOYED"
              else: "this host has no `raid_phase` verb, so DEPLOYED could " &
                    "NOT be observed at all") & ". The machine is at step " &
             machine.stage() & " having advanced " &
             $machine.screensAdvanced() & " screen(s) and has NOT refused. " &
             "I could not look; that is not a pass."

  # The command-line EXIT (-aowl.raidexit=N). Only ever after the command-line
  # raid's own verdict was PASS: dwell N seconds from the moment the client
  # reported DEPLOYED, arm the exit machine, then report ITS finished state --
  # the tree (an active PlayButton) AND the host's phase, because "every press
  # returned" is not evidence of being back at the menu.
  if gDeployedAt != 0'i64 and exitAfter() > 0 and not gExitVerdict:
    let now = nowMs()
    if not gExitArmed:
      if now - gDeployedAt >= int64(exitAfter()) * 1000'i64:
        var why = ""
        let exitReason =
          if gBusArmed: "autoraid.arm exitAfterSeconds from " &
                        unstash(gBusSrcBuf, gBusSrcLen)
          else: "-aowl.raidexit"
        if exitmachine.arm(exitReason, why):
          gExitArmed = true
          gExitT0 = now
          gLastExitPoll = 0'i64
          success "AutoRaid EXIT: dwelt " & $exitAfter() & " s after " &
                  "DEPLOYED, so the exit sequence is ARMED (" & exitReason & "): " &
                  "SHOW-IN-RAID -> DISCONNECT -> LEAVE -> RESULTS -> VERIFY. " &
                  "ARMED IS NOT EXITED: the verdict is read off the live tree."
        else:
          gExitVerdict = true
          warn "AutoRaid EXIT VERDICT FAIL -- the exit asked for on the " &
               "command line was REFUSED and will NOT be retried: " & why
      elif not gExitSaidWait:
        gExitSaidWait = true
        info "AutoRaid EXIT: DEPLOYED observed; leaving the raid in " &
             $exitAfter() & " s (" &
             (if gBusArmed: "autoraid.arm" else: "-aowl.raidexit") & ")."
    elif now - gLastExitPoll >= PhasePollMs:
      gLastExitPoll = now
      let stg = exitmachine.stage()
      if stg == "DONE":
        gExitVerdict = true
        # The tree (an ACTIVE PlayButton, MenuScreen::Show with a real profile
        # 0.3 s earlier) is the finished state. The host phase is the ONE
        # cross-check that can still fail: a host that still says DEPLOYED
        # contradicts the tree and neither is trusted. MEASURED 2026-09-05
        # (cycle 6): hosts before the Unity-alive S1 fix read LOADING at the
        # rebuilt main menu (the cached GameWorld outlived the raid); that
        # is not DEPLOYED and passes here, and the line prints the phase so
        # a reader can see which host they are on.
        let p = raidPhase()
        if p.asked and deployed(p):
          warn "AutoRaid EXIT VERDICT INCONCLUSIVE -- the tree shows an " &
               "active PlayButton (" & exitmachine.answer() & ") but the " &
               "host still reports phase DEPLOYED (" & p.why & "). The two " &
               "disagree, so neither is trusted."
        else:
          success "AutoRaid EXIT VERDICT PASS -- " & exitmachine.answer() &
                  "; the host reports phase " & p.phase &
                  (if p.asked: " (not DEPLOYED -- the cross-check; MENU is " &
                               "the host's own word for it, LOADING is a " &
                               "host from before the Unity-alive S1 fix)"
                   else: " (host phase verb absent; tree only)") & "."
      elif stg == "FAILED":
        gExitVerdict = true
        warn "AutoRaid EXIT VERDICT FAIL -- " & exitmachine.answer()
      elif now - gExitT0 > ExitBoundMs:
        gExitVerdict = true
        warn "AutoRaid EXIT VERDICT INCONCLUSIVE -- " &
             $(int(ExitBoundMs div 1000'i64)) & " s since arming and the " &
             "exit machine is at step " & stg & " without refusing; a bound " &
             "on my patience, not a failure. Read the `AutoRaid exit:` " &
             "lines above for the step that is waiting."

# ---------------------------------------------------------------------------
# Reaching Unity's thread.
# ---------------------------------------------------------------------------

proc bindTick(how: string): bool =
  ## Register the ONE `everyMain` tick and everything that depends on being on
  ## Unity's thread. Factored out of `waitForDrain` because the bus arm can
  ## reach the main thread FIRST -- being executed by the host's main-thread
  ## queue is stronger proof the drain fires than the `main_thread` verb is,
  ## and a host without that verb would otherwise never let a bus arm tick.
  ## Idempotent: `waitForDrain` returns early once `gTickArmed` is set.
  if gTickArmed: return true
  if everyMain(onMainTick) != Ok:
    warn "AutoRaid: the host's main-thread drain is bound but `everyMain` " &
         "REFUSED to register a callback. No key will be polled, no menu can " &
         "open and no raid can be entered. This mod is inert for the session."
    return false
  gTickArmed = true
  menu.bindKeys()
  menu.arm()
  let st = verifyAll()
  info "AutoRaid: call surface verified (" & how & ") -- " & $st.ok &
       " target(s) byte-verified, " & $st.bad & " REFUSED" &
       (if st.why.len > 0: " (first: " & st.why & ")" else: "") &
       ". Built against " & buildIdentity() & "."
  if not subscribe():
    warn "AutoRaid: could not subscribe to the host's `ui.show` event bus. " &
         "Every screen arrival is invisible to this mod, so the state machine " &
         "has NO receiver to act on and will refuse at its first step. This " &
         "is announced rather than degrading into a timeout-driven guess."
  else:
    info "AutoRaid: subscribed to `ui.show`. Screens are taken from their own " &
         "::Show receiver -- never searched for by name, which is the mistake " &
         "that produced three 45-second timeouts in one session."
  result = true

# ---------------------------------------------------------------------------
# Arming the command-line raid, from the main thread.
# ---------------------------------------------------------------------------

proc armFromCmdline(payload: string): string =
  ## Runs on the main thread via `onMainThread`, because `machine.arm` reads the
  ## live tree (`snapshotEpoch` -> `receiverOf` -> `alive`).
  result = ""
  var why = ""
  gCmdlineT0 = nowMs()
  gLastPhasePoll = 0'i64
  if machine.arm(requestedMap(), requestedSide(), "-aowl.raid", why):
    gCmdlineArmed = true
    return
  # A REFUSAL IS NOT RETRIED BLINDLY. "We are already in a raid" in particular
  # is not a transient: retrying it would press at a UI that is not there.
  gCmdlineVerdict = true
  warn "AutoRaid CMDLINE VERDICT FAIL -- the raid asked for on the command " &
       "line was REFUSED and will NOT be retried: " & why


# ---------------------------------------------------------------------------
# Arming from the BUS -- `autoraid.arm`, emitted by another client-side mod.
# ---------------------------------------------------------------------------

proc answerBus(source, map: string; accepted: bool; why: string) =
  ## The requester learns the OUTCOME, always -- accepted or refused, with the
  ## machine's own reason verbatim. A request dropped in silence is the failure
  ## this reply exists to prevent, so it is emitted on every path, including the
  ## ones that refuse before the main thread is ever reached.
  var d = newDoc()
  d.setText("source", source)
  d.setText("map", map)
  d.setBool("accepted", accepted)
  d.setText("why", why)
  discard emit("autoraid.armed", d.text)

proc armFromBus(payload: string): string =
  ## MAIN THREAD, via `onMainThread` -- the same reason `armFromCmdline` is:
  ## `machine.arm` reads the live tree.
  result = ""
  let map = unstash(gBusMapBuf, gBusMapLen)
  let side = unstash(gBusSideBuf, gBusSideLen)
  let source = unstash(gBusSrcBuf, gBusSrcLen)
  gBusPending = false
  if not bindTick("first reached Unity's thread through autoraid.arm"):
    gBusRefusals = gBusRefusals + 1
    let why = "this mod has no `everyMain` slot, so the state machine would " &
              "never tick. Nothing was armed."
    warn "AutoRaid: REFUSED autoraid.arm from \"" & source & "\" -- " & why
    answerBus(source, map, false, why)
    return
  var why = ""
  gBusT0 = nowMs()
  gLastBusPoll = 0'i64
  if machine.arm(map, side, "autoraid.arm from " & source, why):
    gBusArmed = true
    gBusVerdict = false
    success "autoRaid: ARMED by bus event autoraid.arm from " & source &
            " (map " & map & ", side " & side & ")" &
            (if gBusExitAfter > 0:
               ", leaving " & $gBusExitAfter & " s after DEPLOYED"
             else: ", staying in the raid") &
            ". ARMED IS NOT DEPLOYED: the verdict is the host's own phase."
    answerBus(source, map, true, "armed, step " & machine.stage())
    return
  # THE REFUSAL IS THE MACHINE'S, VERBATIM -- including "a raid-entry request
  # is already running", which is how a second arm while one is in flight is
  # rejected. There is never a second machine.
  gBusRefusals = gBusRefusals + 1
  warn "AutoRaid: REFUSED autoraid.arm from \"" & source & "\" (map \"" &
       map & "\") -- " & why
  answerBus(source, map, false, why)

proc onBusArm(payload: string): string =
  ## ANY THREAD -- an event handler runs on whichever thread emitted it. Nothing
  ## here touches the game and nothing here assigns a module-level string: it
  ## validates, it stages POD bytes, and it hands the work to the main thread.
  result = ""
  gBusRequests = gBusRequests + 1
  let map = trim(asText(field(payload, "map"), ""))
  var side = trim(asText(field(payload, "side"), "pmc"))
  if side.len == 0: side = "pmc"
  var source = trim(asText(field(payload, "source"), ""))
  if source.len == 0: source = "an unnamed mod"
  if not busArmEnabled():
    gBusRefusals = gBusRefusals + 1
    let why = "`busArmEnabled` is OFF in mods/autoraid/config.json, so this " &
              "mod refuses raids asked for over the bus. Nothing was armed."
    warn "AutoRaid: REFUSED autoraid.arm from \"" & source & "\" -- " & why
    answerBus(source, map, false, why)
    return
  if map.len == 0:
    gBusRefusals = gBusRefusals + 1
    let why = "autoraid.arm carried no `map`, and there is no default worth " &
              "guessing at -- entering the wrong raid is worse than entering " &
              "none. Nothing was armed."
    warn "AutoRaid: REFUSED autoraid.arm from \"" & source & "\" -- " & why
    answerBus(source, map, false, why)
    return
  if gBusPending:
    gBusRefusals = gBusRefusals + 1
    let why = "an earlier autoraid.arm is already queued for the main thread " &
              "and has not been answered yet. Refusing rather than racing two " &
              "requests at one state machine."
    warn "AutoRaid: REFUSED autoraid.arm from \"" & source & "\" -- " & why
    answerBus(source, map, false, why)
    return
  stash(gBusMapBuf, gBusMapLen, map)
  stash(gBusSideBuf, gBusSideLen, side)
  stash(gBusSrcBuf, gBusSrcLen, source)
  gBusExitAfter = asInt(field(payload, "exitAfterSeconds"), 0)
  if gBusExitAfter < 0: gBusExitAfter = 0
  gBusPending = true
  if onMainThread(armFromBus) != Ok:
    gBusPending = false
    gBusRefusals = gBusRefusals + 1
    let why = "the host refused to queue work on its main thread, so nothing " &
              "was armed. Every call this mod makes happens there, and it " &
              "will not be made anywhere else."
    warn "AutoRaid: REFUSED autoraid.arm from \"" & source & "\" -- " & why
    answerBus(source, map, false, why)

proc waitForDrain(payload: string): string =
  ## A bounded poll for the host's drain, from the mod's own timer thread. It
  ## touches NOTHING in the game -- it asks the host a question -- so it is
  ## legal off Unity's thread, which is exactly why the wait happens here and
  ## the work happens in `onMainThread`.
  result = ""
  if gTickArmed: return
  gDrainWaits = gDrainWaits + 1
  if not drainBound():
    if gDrainWaits == 30 and not gSaidNoDrain:
      gSaidNoDrain = true
      warn "AutoRaid: 30 s waiting and the host still reports its " &
           "main-thread drain as NOT BOUND. Nothing has been called and " &
           "nothing will be until it is -- that is a refusal, not a stall. " &
           "If it never binds, this mod does nothing at all this session and " &
           "the reason is in the host's own log, not here."
    return
  if not bindTick("the host reported its main-thread drain BOUND"):
    return
  if wasAsked():
    info "AutoRaid: the drain has fired, so arming the command-line raid on " &
         "\"" & requestedMap() & "\" now."
    discard onMainThread(armFromCmdline)

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

proc onSettings(url, body, session: string): string =
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
    if st == Ok:
      loadConfig()
  result = declaredSchemaReply(st).text

proc onSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  if st == Ok:
    loadConfig()
  result = declaredSchemaReply(st).text

proc onSettingsHotApply(key: string) =
  ## THE HONEST HOOK. Exactly one of `settingApplied` / `settingAppliesOnRestart`
  ## / `settingIgnored` on every path, because a setting that silently waits for
  ## something reads as broken.
  loadConfig()
  if key == "loadoutMode" or key == "applyAt":
    settingAppliesOnRestart(
      "stored, and it takes effect on the NEXT MENU CYCLE, not this one. " &
      "MEASURED: /client/game/profile/list is the ONLY request that carries " &
      "the PMC Inventory, it is fetched ONCE per menu cycle, and the loadout " &
      "is minted from inside `tarkov.profile.listing` just before that " &
      "document is served -- which by the time you can touch this setting has " &
      "already happened for the raid you are about to enter. It is also read " &
      "by the SERVER half, in the backend process, so a client-side edit " &
      "reaches it only when the backend re-reads its config. Current stored " &
      "state: " & summary())
    return
  if key == "hotkeys" or key == "menuKey" or key == "enterKey":
    menu.bindKeys()
    if hotkeysOn():
      menu.arm()
    settingApplied(
      "live now. " & (if hotkeysOn():
        "Keys are polled from the next main-thread tick; menuKey=" &
        menuKeyName() & " enterKey=" & enterKeyName() & ", bind state: " &
        keyBindWhy()
      else:
        "`hotkeys` is OFF, so NOTHING is polled -- not GetModuleHandle, not " &
        "Input::GetKeyDown -- and both key rows provably do nothing"))
    return
  if key == "busArmEnabled":
    settingApplied(
      "live now: the `autoraid.arm` handler reads this on every arriving " &
      "event, so the next one is " &
      (if busArmEnabled(): "accepted (and answered on `autoraid.armed`)"
       else: "REFUSED BY NAME and answered with accepted=false") &
      ". Requests so far this session: " & $gBusRequests & ", refused " &
      $gBusRefusals & ".")
    return
  if key == "maps" or key == "defaultMap":
    settingApplied(
      "live now: the menu rebuilds its rows from `maps` each time it opens, " &
      "so the next press of " & menuKeyName() & " shows " & $mapList().len &
      " map(s), starting on \"" & defaultMap() & "\".")
    return
  settingIgnored(
    "stored, and nothing in this mod reads it. That should be impossible -- " &
    "every declared key has a reader -- so if you are seeing this, a setting " &
    "was added to the schema without one. Current stored state: " & summary())

# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------

proc onLoadClient(): Status =
  ## THE CLIENT HALF. Nothing here touches the game: it declares, it reads
  ## config, and it starts a poll that waits for the host's drain. Every managed
  ## call in this mod happens later, on Unity's thread.
  cmdline.declare()
  reportArgs()
  menu.bindKeys()
  if on("autoraid.arm", onBusArm) != Ok:
    warn "AutoRaid: could NOT subscribe to `autoraid.arm`, so no other mod " &
         "can ask this one for a raid this session. The command line and the " &
         "menu key are unaffected. This is announced rather than leaving a " &
         "requester emitting into nothing."
  else:
    info "AutoRaid: listening for `autoraid.arm` " &
         "{map, side, source, exitAfterSeconds} -- another client-side mod " &
         "can arm the SAME machine `-aowl.raid` drives, and learns the " &
         "outcome from `autoraid.armed` {source, map, accepted, why}. Gated " &
         "by `busArmEnabled` (" & (if busArmEnabled(): "ON" else: "OFF") & ")."
  if every(1000, waitForDrain) != Ok:
    warn "AutoRaid: could not register the drain poll, so this mod will never " &
         "reach Unity's thread and is inert for the session."
    return Ok
  success ModName & " client: loaded, DEFAULT INERT. " & summary() &
          ". Nothing has been called into the game yet -- the mod waits for " &
          "the host to report its main-thread drain BOUND, because a call " &
          "from the host's own thread is the documented way to crash a frame " &
          "or two later."
  Ok

proc onLoadServer(): Status =
  ## THE SERVER HALF, in the backend process.
  if not install():
    warn ModName & " server: one or more subscriptions or the status route " &
         "did NOT register (named above). The loadout handshake is degraded."
  reportLoadout()
  success ModName & " server: loaded. " & StatusRoute & " serves the config " &
          "and the last apply result; the VERDICT for a spawned loadout is " &
          "mods/tarkov's `" & ResultEvent & "`, logged here verbatim."
  Ok

proc onLoad(): Status =
  loadConfig()
  # ONE schema, declared once, on whichever side is loading. `settingscheck.py`
  # asserts at BUILD time that every key below exists in config.json.
  declareSettings(schema())
  onSettingsApplied(onSettingsHotApply)
  discard serve("/aowlspt/settings/" & ModGuid, onSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onSettingsReset)
  if side() == sideServer:
    return onLoadServer()
  result = onLoadClient()

proc onUpdate(elapsedMs: int64): Status =
  ## NOT Unity's thread -- this is the host's own ~16 ms loop. Deliberately
  ## empty: every per-frame thing this mod does is on `everyMain`, and putting
  ## work here is how a mod ends up touching Unity objects from the wrong
  ## thread.
  Ok

proc onUnload(): Status =
  ## Give the region participant back. The scheduler slots are the host's to
  ## reclaim; the region's registry is a fixed array with a live flag, and a
  ## participant left registered after the DLL is gone is a call into freed
  ## code.
  menuUnregister()
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideServer},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
