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
  if everyMain(onMainTick) != Ok:
    warn "AutoRaid: the host's main-thread drain is bound but `everyMain` " &
         "REFUSED to register a callback. No key will be polled, no menu can " &
         "open and no raid can be entered. This mod is inert for the session."
    return
  gTickArmed = true
  menu.bindKeys()
  menu.arm()
  let st = verifyAll()
  info "AutoRaid: call surface verified -- " & $st.ok & " target(s) " &
       "byte-verified, " & $st.bad & " REFUSED" &
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
      "stored. It takes effect on the NEXT RAID, not this one: the loadout is " &
      "applied before the client's LAST /client/game/profile/list fetch, and " &
      "by the time you can change this setting that fetch has already " &
      "happened. It is also read by the SERVER half, in the backend process, " &
      "so a client-side edit reaches it only when the backend re-reads its " &
      "config. Current stored state: " & summary())
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
