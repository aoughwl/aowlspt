# ---------------------------------------------------------------------------
# raidphase -- ONE shared answer to "is the player actually deployed?"
#
# WHY THIS EXISTS. ESP, the maps HUD and the detection paths each had their own
# gate and all of them keyed, directly or indirectly, on the GameWorld existing.
# `EFT.GameWorld::RegisterPlayer` fires for EVERY BOT during scene LOAD, roughly
# two minutes before the player deploys, so the overlays armed on the loading
# screen. The same gate is wrong at the other end: on the post-raid results
# screen the game scene root still exists, the borrowed GameWorld cache still
# answers non-null, and the map kept drawing over the results screen.
#
# THE TEN-SECOND ERROR (this is the third user report, and the reason for S6).
# The five signals below are ALL satisfied at the END OF SCENE LOAD -- the world
# is built, the local player is spawned into the alive list, a camera exists --
# which is roughly TEN SECONDS before the player actually deploys. The latch
# mechanics were right and the diag verdict said PASS, because it only asserted
# that the arm was WELL-FORMED (armed on a positive observation), never that it
# was TIMELY. That is the check-that-cannot-fail shape of CLAUDE.md 9b. So S6
# below is the true deploy signal, and `rpDelta` measures and PRINTS the gap
# between the proxy becoming ready and the true signal firing, every raid, with
# a verdict that CAN say FAIL.
#
# WHAT IS AND IS NOT PROVEN HERE. `EFT.AbstractGame.<Status>k__BackingField` is
# at +0x38 -- and that is proven from COMPILED CODE, not metadata alone: both
# accessors are one instruction and they agree (`get_Status` @0x8AD140 is
# `8B 41 38 C3`, `set_Status` @0x7C9AD0 is `89 51 38 C3`). It is still NOT read
# here, and deliberately so: an exhaustive offline scan of every field of every
# one of the 31282 types found exactly TWO non-compiler-generated fields typed
# `AbstractGame` (`EFT.NonWavesSpawnScenario._game`,
# `<LateFixedUpdateWorker>d__5.<>4__this`), and neither is reachable from any
# object this host holds; `EFT.TarkovApplication` and `EFT.Player` have no game
# field either. The instance otherwise lives in
# `Comfort.Common.Singleton<AbstractGame>`, an instantiated generic static whose
# layout CLAUDE.md 5 says is not reachable offline. So there is no field path
# from GameWorld or TarkovApplication to `Status` that could be byte-verified,
# and inventing one would be exactly the guessed offset that reads a plausible
# number. That leg is INCONCLUSIVE and is reported as such -- it is not silently
# approximated. Both accessor RVAs are additionally SHARED (60 and 35 owners --
# identical one-instruction bodies get folded), so neither may be detoured.
#
# WHAT IS PROVEN, and is what this module gates on:
#   S1  the borrowed GameWorld cache is non-null, readable AND Unity-alive
#       (m_CachedPtr non-zero) -- after a raid the cache outlives the world
#   S2  GameWorld.MainPlayer is non-null, readable AND UNITY-ALIVE. Unity's fake
#       null keeps a destroyed object readable with m_CachedPtr zeroed, so
#       readability alone is not liveness (this is the check ESP did not have).
#   S3  MainPlayer is a member of the LIVE GameWorld.AllAlivePlayersList -- the
#       game's own spawned-and-in-world set. False in the menu and after
#       extract. ESP did not have this either; the maps HUD did.
#   S4  SceneManager does NOT list a scene named `SessionEndUIScene`. MEASURED:
#       when the post-raid results screen is up, SceneManager lists exactly ONE
#       scene, named that, with root `Session End UI`; during the menu and
#       during a raid it lists CommonUIScene/MenuUIScene/GameUIScene instead.
#       This is one of the two END-OF-RAID darkening signals.
#   S5  `UnityEngine.Camera::get_main` returns non-null. MEASURED LIVE on the
#       post-raid results screen while the borrowed GameWorld cache was still
#       answering non-null: natesp reported "Camera.main is null -- menu or
#       loading screen". Camera.main is ALSO null in the menu and on the
#       loading screen, so this single readable signal closes BOTH ends that
#       GameWorld-existence gets wrong. It is the discriminator this module
#       could not derive offline and did not invent.
#   S6  THE TRUE DEPLOY SIGNAL. `EFT.GameWorld::OnGameStarted` @0x2508000
#       (UNIQUE) is the moment the raid actually starts, and its first two
#       instructions are the proof of what it does: load
#       `GameWorld.AfterGameStarted` (+0x130, an Action) and invoke it. It
#       cannot itself be detoured -- a relative branch sits at prologue offset
#       10 and the engine needs 14 relocatable bytes (see abi/aowlspt_raidstart.h
#       for the disassembly and abi/aowlspt_detour.h for why the 5-byte island
#       form does not exist). So the host rides the delegate instead: every
#       subscriber to that Action runs INSIDE OnGameStarted, i.e. at exactly the
#       same instant. Two UNIQUE, cleanly-relocatable subscribers are bound and
#       either firing sets S6:
#         Audio.SpatialSystem.SpatialAudioSystem::AfterGameStarted @0x2194770
#         EFT.ExfiltrationTimerSoundPlayer::AfterGameStarted       @0xA4CAF0
#       (`EFT.RaidTimerAnnouncementController::AfterGameStarted` @0xA43BC0 was
#       REJECTED: SHARED, 2 owners.) Both are bound because a body EXISTING is
#       not a body SUBSCRIBED, and that cannot be established offline.
#
# WHAT S6 CANNOT ESTABLISH OFFLINE, stated plainly: that either subscriber is
# actually attached to the delegate in an offline raid. If NEITHER fires, the
# latch does not arm, the overlays stay dark, and `rpDelta` reports
# INCONCLUSIVE with the reason. It does NOT quietly fall back to the early
# proxies -- that is the bug. The single exception is a target that failed to
# BIND (a prologue mismatch on a different build), which is a structural,
# observable condition: then the module says so loudly and reverts to the
# five-signal arm, because a build we cannot hook must not lose the feature.
#
# WHY A LATCH AND NOT A PER-FRAME AND. Fact #235: `GameWorld.MainPlayer`
# (+0x230) reads NULL on roughly three of every four frames DURING a live raid.
# A per-frame `S1 and S2 and S3` therefore flickers false inside a real raid,
# and a consumer that darkened on it would strobe -- which is exactly the bug
# `hudPublish`'s held-frame logic was written to work around. So:
#     ARM   on a positive deploy observation: S1 and S2 and S3 and S5
#     CLEAR only on a positive END observation: S4 present, or S1 gone, or S5
#           (Camera.main) gone
# Neither edge is driven by the flickering read alone. The latch state, both
# edges, and all five raw signals are reported separately by `rpSignals()`, so
# a wrong verdict says which signal produced it instead of being a bare bool.
#
# SAFETY. Read-only: no detour is installed, no method is resolved by name, and
# nothing is written. It rides the existing `EFT.TarkovApplication::Update`
# drain. The whole body runs under ONE `aowl_p_p_seh` (`cRpTickGuarded`) and
# opens no inner guard -- callers (natesp's gate, the mod export) read the
# CACHED verdict and never evaluate inside their own guard, because
# `aowl_p_p_seh` is not re-entrant. Every hop is `cIsReadable`-guarded, the
# alive-list walk is capped at `cBdMaxPlayers`, the scene query is capped by
# `InspMaxScenes` and runs at most once a second, and the module self-disables
# after `RpMaxFaults` faults.
# ---------------------------------------------------------------------------

{.emit: """
extern void* aowl_rp_tick_body(void* a);
static void* aowl_rp_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_rp_tick_body, a);
}
""".}
proc cRpTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_rp_tick_guarded", nodecl.}

const
  RpPhaseUnknown* = 0'i32   ## I could not look. NOT "no raid".
  RpPhaseMenu*    = 1'i32   ## no GameWorld cached
  RpPhaseLoading* = 2'i32   ## GameWorld exists, local player not in-world yet
  RpPhaseDeployed* = 3'i32  ## every readable precondition holds
  RpPhaseResults* = 4'i32   ## SessionEndUIScene is up -- raid over

  RpMaxFaults = 8
  RpSceneEveryMs = 1000'u64
  RpSessionEndScene = "SessionEndUIScene"

var gRpPhase = RpPhaseUnknown
var gRpS1 = false          ## GameWorld cached + readable
var gRpS2 = false          ## MainPlayer readable AND Unity-alive
var gRpS3 = false          ## MainPlayer in AllAlivePlayersList
var gRpS4 = -1'i32         ## SessionEndUIScene: 1 present, 0 absent, -1 unknown
var gRpS5 = false          ## Camera.main non-null
var gRpAliveN = 0
var gRpFaults = 0
var gRpTicks = 0'i64
var gRpSceneAt = 0'u64
var gRpEverDeployed = false
var gRpLatched = false     ## the deploy latch -- see the header
var gRpArmedAt = 0'i64
var gRpClearedBy = ""      ## which END signal cleared the latch, verbatim
var gRpCam: Il2CppPtr = nil
var gRpCamAt = 0'i64

# ---- S6, the true deploy signal, and the timeliness measurement -------------
## Set by `rpStartFired`, the read-only detour on an `AfterGameStarted`
## subscriber. Cleared on every CLEAR edge so the next raid measures afresh.
var gRpTrueStart = false
var gRpTrueAtMs = 0'u64        ## cNowMs() when S6 fired
var gRpTrueBy = ""             ## which subscriber fired, verbatim
## cNowMs() at the FIRST tick on which the five proxy signals all held for this
## raid. This is when the OLD code would have armed -- so `gRpTrueAtMs` minus
## this is exactly the error the user has been seeing.
var gRpProxyAtMs = 0'u64
var gRpProxyReady = false
## One-shot per raid: the delta line is emitted from `rpDrainTick`, OUTSIDE the
## SEH-guarded body, so no string building happens inside the guard.
var gRpDeltaPending = false
var gRpInconclusivePending = false
var gRpLastDelta = ""          ## the last verdict line, verbatim, for rpSignals

## How far apart the proxy and the true signal may be before the proxy is
## declared EARLY. The reported error is ~10s; 2s is generous and still catches
## it. A FAIL here is not a crash -- it is the latch telling you the proxy is
## still being trusted for something it cannot answer.
const RpDeltaOkMs = 2000'u64

proc rpDisabled*(): bool = gRpFaults >= RpMaxFaults

proc rpStartBound*(): bool =
  ## True when at least one `AfterGameStarted` subscriber detour is installed.
  ## When FALSE the module has no true signal available on this build and falls
  ## back to the five-signal arm -- loudly, in `bindRaidStart`.
  gRpStartSlotA >= 0 or gRpStartSlotB >= 0

proc rpStartFired*(regs: Il2CppPtr; which: int32) =
  ## Fired from the read-only detours on the `AfterGameStarted` subscribers, on
  ## the Unity main thread, INSIDE `EFT.GameWorld::OnGameStarted`. It reads no
  ## register and touches NO game memory -- one bool, one timestamp, one string
  ## constant -- so it opens no SEH guard of its own and cannot fault into the
  ## game. `regs` is accepted only to match the dispatch signature.
  discard regs
  if gRpTrueStart: return
  gRpTrueStart = true
  gRpTrueAtMs = cNowMs()
  gRpTrueBy = (if which == 0'i32:
                 "SpatialAudioSystem::AfterGameStarted"
               else:
                 "ExfiltrationTimerSoundPlayer::AfterGameStarted")
  gRpDeltaPending = true

proc rpMemberOfAlive(gw, you: Il2CppPtr; n: var int): bool =
  ## Capped membership test over GameWorld.AllAlivePlayersList (+0x1C8). Pure
  ## pointer comparison -- the list entries are never dereferenced.
  n = 0
  if not bdOk(gw, cBdOffAliveList() + 8'i32): return false
  let lst = cReadPtrAt(gw, cBdOffAliveList())
  if not bdOk(lst, cBdOffListSize() + 4'i32): return false
  let arr = cReadPtrAt(lst, cBdOffListItems())
  let size = cReadI32At(bdPtrAdd(lst, cBdOffListSize()))
  if not bdSanePtr(arr) or arr == nil or size <= 0'i32: return false
  let cap = (if size > int32(cBdMaxPlayers): int32(cBdMaxPlayers) else: size)
  n = int(size)
  var i = 0
  while i < int(cap):
    let slot = bdPtrAdd(arr, cBdOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) != 0'i32:
      if cReadPtrAt(slot, 0'i32) == you: return true
    inc i
  false

proc rpCameraMain(): Il2CppPtr =
  ## `UnityEngine.Camera::get_main` through debugui's already byte-verified
  ## target table -- no name is resolved here and no address is invented.
  ## Re-asked at most every 15 frames; the cached pointer is re-validated every
  ## time, so a camera destroyed between refreshes cannot be reported live.
  let fn = cDuFn(DuCameraMain)
  if fn == nil: return nil
  if (gRpTicks - gRpCamAt) >= 15 or (gRpCam != nil and not duOk(gRpCam, 0x20'i32)):
    gRpCam = cDuCallPV(fn)
    gRpCamAt = gRpTicks
  if not duOk(gRpCam, 0x20'i32) or not bdSanePtr(gRpCam):
    gRpCam = nil
  gRpCam

proc rpTickBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_rp_tick_body", cdecl.} =
  gRpS1 = false
  gRpS2 = false
  gRpS3 = false
  gRpAliveN = 0

  # ---- the raw signals ---------------------------------------------------
  # S4, at most once a second: the scene-name query is three calls into Unity
  # and the results screen does not appear between frames.
  if (cNowMs() - gRpSceneAt) >= RpSceneEveryMs:
    gRpSceneAt = cNowMs()
    gRpS4 = iSceneNamePresent(RpSessionEndScene)
  gRpS5 = rpCameraMain() != nil

  let gw = gDuGameWorld
  # S1 is READABLE **AND UNITY-ALIVE**. MEASURED 2026-09-05 (six auto raids):
  # after a raid the borrowed cache still points at a GameWorld whose page is
  # readable, so S1 stayed true at the rebuilt MAIN MENU and this reported
  # LOADING for as long as the process lived -- never MENU again. The same
  # fake-null test S2 applies to the player applies to the world: a destroyed
  # UnityEngine.Object keeps its managed shell with m_CachedPtr zeroed.
  gRpS1 = bdOk(gw, cBdOffMainPlayer() + 8'i32) and bdSanePtr(gw) and
          iUnityAlive(gw)
  var you: Il2CppPtr = nil
  if gRpS1:
    you = cReadPtrAt(gw, cBdOffMainPlayer())
    # Unity fake null: readable is NOT alive. A destroyed UnityEngine.Object
    # stays readable with m_CachedPtr zeroed and the next internal call dies
    # inside Unity's own C++.
    gRpS2 = bdOk(you, 0x20'i32) and bdSanePtr(you) and iUnityAlive(you)
    if gRpS2:
      gRpS3 = rpMemberOfAlive(gw, you, gRpAliveN)

  # ---- the CLEAR edge, evaluated FIRST -----------------------------------
  # A positive end-of-raid observation always beats a positive deploy one. On
  # the results screen the GameWorld cache is still non-null and S2/S3 can
  # still read true; that is the exact case that kept the map drawing.
  var cleared = false
  if gRpS4 == 1'i32:
    gRpLatched = false
    cleared = true
    gRpClearedBy = "S4 SessionEndUIScene is listed by SceneManager"
  elif not gRpS1:
    gRpLatched = false
    cleared = true
    gRpClearedBy = "S1 the GameWorld cache is gone"
  elif not gRpS5:
    gRpLatched = false
    cleared = true
    gRpClearedBy = "S5 Camera.main is null"

  if cleared:
    # A raid that reached the proxy-ready state but never saw S6 is the case the
    # delta line MUST report, and it can only be reported here -- at the end,
    # once we know it never came. INCONCLUSIVE, never PASS.
    if gRpProxyReady and not gRpTrueStart and rpStartBound():
      gRpInconclusivePending = true
    gRpTrueStart = false
    gRpTrueAtMs = 0'u64
    gRpTrueBy = ""
    gRpProxyReady = false
    gRpProxyAtMs = 0'u64

  # ---- the ARM edge ------------------------------------------------------
  else:
    # The five readable signals. This is the OLD arm condition and is now only
    # a PRECONDITION plus the zero point of the timeliness measurement.
    let proxy = gRpS2 and gRpS3
    if proxy and not gRpProxyReady:
      gRpProxyReady = true
      gRpProxyAtMs = cNowMs()
    # S6 is what actually arms. `rpStartBound()` false means this build could
    # not be hooked at all, and losing the feature entirely is worse than the
    # early arm -- so on that build, and only there, the proxy arms alone.
    if proxy and (gRpTrueStart or not rpStartBound()):
      if not gRpLatched:
        gRpArmedAt = gRpTicks
        gRpClearedBy = ""
      gRpLatched = true
      gRpEverDeployed = true

  # ---- the reported phase ------------------------------------------------
  if gRpLatched:
    gRpPhase = RpPhaseDeployed
  elif gRpS4 == 1'i32:
    gRpPhase = RpPhaseResults
  elif gRpS1:
    gRpPhase = RpPhaseLoading
  elif gDebugEspSlot >= 0 or gBotDiagSlot >= 0:
    # No world cached, and something IS armed to populate the cache, so this is
    # a real observation of "no raid" rather than nobody watching.
    gRpPhase = RpPhaseMenu
  else:
    # Nobody is armed to populate the cache. Reporting that as "not in a raid"
    # is the silent decline CLAUDE.md 6 forbids.
    gRpPhase = RpPhaseUnknown
  cast[Il2CppPtr](1)

proc rpEmitDelta() =
  ## THE FALSIFIABLE NEGATIVE. Prints, once per raid, the interval between the
  ## proxy signals becoming ready (where the latch USED to arm) and the true
  ## deploy signal firing. A ten-second early arm shows up here as a ten-second
  ## delta and a FAIL -- which the previous "armed on a positive observation"
  ## verdict structurally could not say, because it asserted the shape of our own
  ## write rather than a property of the finished state.
  ##
  ## Called from `rpDrainTick`, OUTSIDE the guarded body, so the string building
  ## never happens inside `aowl_p_p_seh`.
  if gRpDeltaPending:
    gRpDeltaPending = false
    if gRpProxyAtMs == 0'u64:
      gRpLastDelta = "raidphase DELTA: true deploy signal fired at t=" &
        $gRpTrueAtMs & "ms via " & gRpTrueBy & ", but the five proxy signals " &
        "were NOT yet ready -- delta unmeasurable this raid. INCONCLUSIVE."
    elif gRpTrueAtMs >= gRpProxyAtMs:
      let d = gRpTrueAtMs - gRpProxyAtMs
      gRpLastDelta = "raidphase DELTA: proxy-ready t=" & $gRpProxyAtMs &
        "ms, true deploy t=" & $gRpTrueAtMs & "ms via " & gRpTrueBy &
        ", delta=+" & $d & "ms -- " &
        (if d <= RpDeltaOkMs:
           "PASS (the five readable signals were TIMELY within " &
             $RpDeltaOkMs & "ms)"
         else:
           "FAIL: the five readable signals were ready " & $d & "ms BEFORE " &
             "the raid actually started. That is exactly the window in which " &
             "ESP and the map used to draw over the loading screen. The latch " &
             "held them dark; do NOT re-gate any consumer on the proxies.")
    else:
      let d = gRpProxyAtMs - gRpTrueAtMs
      gRpLastDelta = "raidphase DELTA: true deploy t=" & $gRpTrueAtMs &
        "ms via " & gRpTrueBy & " PRECEDED proxy-ready t=" & $gRpProxyAtMs &
        "ms by " & $d & "ms -- PASS (the latch arms on the later of the two, " &
        "so the overlays still wait for a live MainPlayer)."
    okLog gRpLastDelta
  if gRpInconclusivePending:
    gRpInconclusivePending = false
    gRpLastDelta = "raidphase DELTA: the raid ENDED and the true deploy signal " &
      "NEVER fired, although the five proxy signals were ready at t=" &
      $gRpProxyAtMs & "ms -- INCONCLUSIVE, not a pass. Neither " &
      "SpatialAudioSystem::AfterGameStarted nor " &
      "ExfiltrationTimerSoundPlayer::AfterGameStarted was invoked, so either " &
      "neither subscribes to GameWorld.AfterGameStarted in this game mode or " &
      "the raid never truly started. ESP and the map stayed DARK for the whole " &
      "raid; that is the deliberate choice (a dark overlay is recoverable, an " &
      "overlay on the loading screen is the reported bug), but this line is the " &
      "one to act on."
    warn gRpLastDelta

proc rpDrainTick*() =
  ## Rides the existing Update drain. No detour of its own.
  if rpDisabled(): return
  gRpTicks = gRpTicks + 1
  rpEmitDelta()
  if cRpTickGuarded(nil) == nil:
    gRpFaults = gRpFaults + 1
    gRpPhase = RpPhaseUnknown
    if gRpFaults == 1 or gRpFaults == RpMaxFaults:
      warn "raidphase: the guarded read-only tick FAULTED (" & $gRpFaults &
           " of " & $RpMaxFaults & "). Every consumer now reads phase=UNKNOWN, " &
           "which is a REFUSAL, not 'no raid'. At the cap this module stops " &
           "touching game memory for the session."

proc rpPhase*(): int32 = gRpPhase

proc rpGameWorld*(): bool = gRpS1
  ## S1 verbatim: the borrowed GameWorld cache is non-null AND readable. NOT a
  ## synonym for "in a raid" -- it is still true on the results screen (see the
  ## CLEAR edge below), which is exactly why `rpPhase` exists and why this is
  ## reported alongside the phase by `aowlspt.host::raid_phase` rather than
  ## instead of it.

proc rpDeployed*(): bool = gRpPhase == RpPhaseDeployed
  ## THE gate. False on UNKNOWN by design: "I could not look" must darken the
  ## overlays, not arm them.

proc rpPhaseName*(p: int32): string =
  case p
  of RpPhaseMenu: "MENU"
  of RpPhaseLoading: "LOADING"
  of RpPhaseDeployed: "DEPLOYED"
  of RpPhaseResults: "RESULTS"
  else: "UNKNOWN"

proc rpWhy*(): string =
  ## The FIRST signal that failed, never the last. A later failure is a
  ## consequence and reporting it sends the reader the wrong way.
  if rpDisabled():
    return "self-disabled after " & $gRpFaults & " faults -- INCONCLUSIVE"
  case gRpPhase
  of RpPhaseResults:
    "RAID OVER -- " & gRpClearedBy & ". The GameWorld cache is STILL non-null " &
      "here (measured live on the results screen with the map still drawing), " &
      "which is exactly why world-existence must not decide this case."
  of RpPhaseDeployed:
    (if gRpTrueStart:
       "LATCHED on the TRUE deploy signal (" & gRpTrueBy & ", invoked from " &
       "inside EFT.GameWorld::OnGameStarted) at t=" & $gRpTrueAtMs & "ms. "
     else:
       "LATCHED on the five readable signals ALONE, because no AfterGameStarted " &
       "subscriber could be hooked on this build -- this is the pre-fix " &
       "behaviour and arms about ten seconds early. ") &
    "LATCHED at tick " & $gRpArmedAt & " on a positive deploy observation " &
      "(GameWorld cached, MainPlayer Unity-ALIVE, MainPlayer in " &
      "AllAlivePlayersList with " & $gRpAliveN & " entries, Camera.main " &
      "non-null). It stays latched through the MainPlayer null flicker (fact " &
      "#235, ~3 frames in 4) and clears only on a positive END signal."
  of RpPhaseLoading:
    if gRpClearedBy.len > 0 and not gRpS5:
      "NOT DEPLOYED -- " & gRpClearedBy & ". Camera.main is null on the loading " &
        "screen as well as in the menu, so bots registering into a live " &
        "GameWorld two minutes before deploy read exactly like this and the " &
        "overlays stay dark."
    elif not gRpS5:
      "NOT DEPLOYED -- S5 Camera.main is null: menu or loading screen. The " &
        "GameWorld exists because bots are registering, which is NOT deploy."
    elif not gRpS2:
      "NOT DEPLOYED -- S2: GameWorld is cached and Camera.main is live, but " &
        "MainPlayer is null, unreadable or Unity-fake-null (m_CachedPtr == 0)."
    elif gRpProxyReady and not gRpTrueStart:
      "NOT DEPLOYED -- S6: all five readable signals hold (they have since t=" &
        $gRpProxyAtMs & "ms) but the TRUE deploy signal has not fired. This is " &
        "the ~10-second window the user reported three times: the scene has " &
        "finished loading and you are in the alive list, but the raid has not " &
        "started. ESP and the map stay dark until an AfterGameStarted " &
        "subscriber runs inside EFT.GameWorld::OnGameStarted."
    else:
      "NOT DEPLOYED -- S3: MainPlayer is alive but NOT in " &
        "GameWorld.AllAlivePlayersList (" & $gRpAliveN & " entries) -- created " &
        "but not yet a spawned participant"
  of RpPhaseMenu:
    "S1: no GameWorld is cached, which is what the menu looks like" &
      (if gRpClearedBy.len > 0: " (latch cleared by " & gRpClearedBy & ")" else: "")
  else:
    "INCONCLUSIVE -- either no detour is armed to populate the GameWorld cache " &
      "(set host flag debugEsp or botDiag) or the guarded tick faulted. This " &
      "is NOT 'you are not in a raid'."

proc rpSignals*(): string =
  ## All four signals, separately falsifiable, so one live raid shows WHICH one
  ## moves at the deploy moment. The loading-vs-deployed discriminator is the
  ## open question this line exists to settle.
  "S1 gameworld=" & (if gRpS1: "yes" else: "no") &
  " S2 mainplayer-alive=" & (if gRpS2: "yes" else: "no") &
  " S3 in-alivelist=" & (if gRpS3: "yes" else: "no") &
  "(n=" & $gRpAliveN & ")" &
  " S4 sessionend-scene=" &
    (if gRpS4 == 1'i32: "PRESENT" elif gRpS4 == 0'i32: "absent" else: "UNKNOWN") &
  " S5 camera-main=" & (if gRpS5: "live" else: "NULL") &
  " S6 true-deploy=" &
    (if gRpTrueStart: "FIRED(" & gRpTrueBy & ")"
     elif rpStartBound(): "not-yet"
     else: "UNHOOKABLE-ON-THIS-BUILD") &
  " proxy-ready=" & (if gRpProxyReady: $gRpProxyAtMs & "ms" else: "no") &
  " latch=" & (if gRpLatched: "ARMED@" & $gRpArmedAt else: "clear") &
  (if not gRpLatched and gRpClearedBy.len > 0: "(" & gRpClearedBy & ")" else: "") &
  " everDeployed=" & (if gRpEverDeployed: "yes" else: "no") &
  " ticks=" & $gRpTicks & " faults=" & $gRpFaults &
  (if gRpLastDelta.len > 0: " | " & gRpLastDelta else:
     " | delta: no raid measured yet -- INCONCLUSIVE")

proc cRsTargetAt(i: int32): Il2CppPtr {.importc: "aowl_rs_target_at", nodecl.}
proc cRsTargetName(i: int32): Il2CppPtr {.importc: "aowl_rs_target_name", nodecl.}
proc cRsTargetCount(): int32 {.importc: "aowl_rs_target_count", nodecl.}

proc bindRaidStart*(verbose: bool): bool =
  ## Installs the read-only kind=20/21 detours on the two UNIQUE
  ## `AfterGameStarted` subscribers verified in `abi/aowlspt_raidstart.h`. Both
  ## are attempted; either one binding is enough for S6 to be available, and
  ## both binding is the intent, because neither subscription can be proven
  ## offline. Nothing is written to the game and no argument is read.
  ##
  ## NOT flag-gated. `raidphase` is the shared deploy gate for ESP and the maps
  ## HUD and runs unconditionally; a flag that turned S6 off would silently
  ## restore the ten-second early arm, which is the bug. The detours are
  ## read-only, fire at most once per raid, and are inert until a raid starts.
  if rpStartBound(): return true
  if not gReady or gDisableDrain: return false
  var bound = 0
  for i in 0 ..< int(cRsTargetCount()):
    let fn = cRsTargetAt(int32(i))
    let spec = readCString(cRsTargetName(int32(i)))
    # There are exactly two detour slots (kinds 20 and 21) for this table. A
    # third row added to `aowl_rs_targets` would otherwise be swept up and bound
    # to no slot, so it would fire into nothing -- silently. Refuse it aloud
    # instead (fact #187: an inserted row shifts every index below it).
    if i >= 2:
      warn "raidphase: aowl_rs_targets row " & $i & " (" & spec & ") has NO " &
           "detour slot -- only kinds 20/21 exist. It is NOT bound. Add a slot " &
           "and a dispatch arm in aowlhost.nim before adding a row."
      break
    if fn == nil:
      if verbose:
        info "raidphase: true-deploy target " & spec & " did NOT byte-verify " &
             "against its recorded prologue on this build -- not bound"
      continue
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose,
                   int32(20 + i)):
      inc bound
      okLog "raidphase: TRUE deploy signal armed on " & spec &
            " (read-only; it runs inside EFT.GameWorld::OnGameStarted, which " &
            "cannot be hooked directly -- a relative branch sits at prologue " &
            "offset 10)"
  if bound == 0:
    warn "raidphase: NEITHER AfterGameStarted subscriber could be hooked on " &
         "this build, so there is no true deploy signal. The latch FALLS BACK " &
         "to the five readable signals, which are satisfied at the end of scene " &
         "load and therefore arm ESP and the map about TEN SECONDS EARLY. This " &
         "is the reported bug, announced rather than hidden."
    return false
  if bound == 1:
    info "raidphase: only one of the two AfterGameStarted subscribers bound. " &
         "That is sufficient -- but if the delta line reports INCONCLUSIVE " &
         "next raid, the unbound one is the first thing to look at."
  true

proc aowlHostRaidPhase(): int32 {.exportc: "aowl_host_raid_phase_impl", cdecl.} =
  ## READ-ONLY export of the cached phase for out-of-host consumers (mods/maps,
  ## mods/admin). It returns the value the guarded tick last computed; it never
  ## evaluates here, because a mod calls this from inside its own guard and
  ## `aowl_p_p_seh` is not re-entrant.
  gRpPhase

{.emit: """
extern int aowl_host_raid_phase_impl(void);
__declspec(dllexport) int aowl_host_raid_phase(void) {
    return aowl_host_raid_phase_impl();
}
""".}
