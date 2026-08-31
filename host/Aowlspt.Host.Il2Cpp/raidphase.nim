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
# WHAT IS AND IS NOT PROVEN HERE. The signal one would WANT is
# `EFT.AbstractGame.<Status>k__BackingField` (+0x38, enum EFT.GameStatus:
# Stopped=0 Running=1 Runned=2 Starting=3 Started=4 Stopping=5 SoftStopping=6 --
# decoded offline with `tools/fldoff.py enum EFT.GameStatus`). It is NOT read
# here, and deliberately so: an exhaustive offline scan of every field of every
# one of the 31282 types found exactly TWO non-compiler-generated fields typed
# `AbstractGame` (`EFT.NonWavesSpawnScenario._game`,
# `<LateFixedUpdateWorker>d__5.<>4__this`), and neither is reachable from any
# object this host holds. The instance otherwise lives in
# `Comfort.Common.Singleton<AbstractGame>`, an instantiated generic static whose
# layout CLAUDE.md 5 says is not reachable offline. So there is no field path
# from GameWorld or TarkovApplication to `Status` that could be byte-verified,
# and inventing one would be exactly the guessed offset that reads a plausible
# number. That leg is INCONCLUSIVE and is reported as such -- it is not silently
# approximated.
#
# WHAT IS PROVEN, and is what this module gates on:
#   S1  the borrowed GameWorld cache is non-null and readable
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

proc rpDisabled*(): bool = gRpFaults >= RpMaxFaults

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
  gRpS1 = bdOk(gw, cBdOffMainPlayer() + 8'i32)
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
  if gRpS4 == 1'i32:
    gRpLatched = false
    gRpClearedBy = "S4 SessionEndUIScene is listed by SceneManager"
  elif not gRpS1:
    gRpLatched = false
    gRpClearedBy = "S1 the GameWorld cache is gone"
  elif not gRpS5:
    gRpLatched = false
    gRpClearedBy = "S5 Camera.main is null"

  # ---- the ARM edge ------------------------------------------------------
  elif gRpS2 and gRpS3:
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

proc rpDrainTick*() =
  ## Rides the existing Update drain. No detour of its own.
  if rpDisabled(): return
  gRpTicks = gRpTicks + 1
  if cRpTickGuarded(nil) == nil:
    gRpFaults = gRpFaults + 1
    gRpPhase = RpPhaseUnknown
    if gRpFaults == 1 or gRpFaults == RpMaxFaults:
      warn "raidphase: the guarded read-only tick FAULTED (" & $gRpFaults &
           " of " & $RpMaxFaults & "). Every consumer now reads phase=UNKNOWN, " &
           "which is a REFUSAL, not 'no raid'. At the cap this module stops " &
           "touching game memory for the session."

proc rpPhase*(): int32 = gRpPhase

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
  " latch=" & (if gRpLatched: "ARMED@" & $gRpArmedAt else: "clear") &
  (if not gRpLatched and gRpClearedBy.len > 0: "(" & gRpClearedBy & ")" else: "") &
  " everDeployed=" & (if gRpEverDeployed: "yes" else: "no") &
  " ticks=" & $gRpTicks & " faults=" & $gRpFaults

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
