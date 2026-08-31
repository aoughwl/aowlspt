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

# ---- the cost meter (abi/aowlspt_raidphase.h) -----------------------------
# Statics plus QueryPerformanceCounter. Touches no game memory, resolves no
# address, allocates nothing, opens NO SEH guard -- `rpDrainTick` already holds
# the one guard this module is allowed and `aowl_p_p_seh` is not re-entrant.
proc cRpCostBegin() {.importc: "aowl_rp_cost_begin", nodecl.}
proc cRpCostEnd() {.importc: "aowl_rp_cost_end", nodecl.}
proc cRpPhaseScene() {.importc: "aowl_rp_phase_scene", nodecl.}
proc cRpSubBegin(s: int32) {.importc: "aowl_rp_sub_begin", nodecl.}
proc cRpSubEnd(s: int32) {.importc: "aowl_rp_sub_end", nodecl.}
proc cRpCtrlOut() {.importc: "aowl_rp_ctrl_out", nodecl.}
proc cRpCtrlIn() {.importc: "aowl_rp_ctrl_in", nodecl.}
proc cRpCtrlMeanNs(w: int32): int64 {.importc: "aowl_rp_ctrl_mean_ns", nodecl.}
proc cRpCtrlMaxNs(w: int32): int64 {.importc: "aowl_rp_ctrl_max_ns", nodecl.}
proc cRpCtrlSamples(w: int32): int64 {.importc: "aowl_rp_ctrl_samples", nodecl.}
proc cRpCostMeanNs(p: int32): int64 {.importc: "aowl_rp_cost_mean_ns", nodecl.}
proc cRpCostMaxNs(p: int32): int64 {.importc: "aowl_rp_cost_max_ns", nodecl.}
proc cRpCostP95Ns(p: int32): int64 {.importc: "aowl_rp_cost_p95_ns", nodecl.}
proc cRpCostN(p: int32): int64 {.importc: "aowl_rp_cost_n", nodecl.}
proc cRpCostOver(p: int32): int64 {.importc: "aowl_rp_cost_over", nodecl.}
proc cRpCostOvf(p: int32): int64 {.importc: "aowl_rp_cost_ovf", nodecl.}
proc cRpP95Sat(): int64 {.importc: "aowl_rp_p95_sat", nodecl.}
proc cRpTopEdgeNs(): int64 {.importc: "aowl_rp_top_edge_ns", nodecl.}
proc cRpBudgetNs(): int64 {.importc: "aowl_rp_budget_ns", nodecl.}
proc cRpMinSamples(): int64 {.importc: "aowl_rp_min_samples", nodecl.}
proc cRpSubMeanNs(s: int32): int64 {.importc: "aowl_rp_sub_mean_ns", nodecl.}
proc cRpSubMaxNs(s: int32): int64 {.importc: "aowl_rp_sub_max_ns", nodecl.}
proc cRpSubN(s: int32): int64 {.importc: "aowl_rp_sub_n", nodecl.}
proc cRpSubName(s: int32): cstring {.importc: "aowl_rp_sub_name", nodecl.}
proc cRpSubCount(): int32 {.importc: "aowl_rp_sub_count", nodecl.}
proc cRpAccMeanNs(): int64 {.importc: "aowl_rp_acc_mean_ns", nodecl.}
proc cRpAccN(): int64 {.importc: "aowl_rp_acc_n", nodecl.}
proc cRpGapMeanNs(): int64 {.importc: "aowl_rp_gap_mean_ns", nodecl.}
proc cRpGapN(): int64 {.importc: "aowl_rp_gap_n", nodecl.}
proc cRpDropped(): int64 {.importc: "aowl_rp_dropped", nodecl.}

const
  RpPhLight = 0'i32
  RpPhScene = 1'i32
  RpSubScene = 0'i32
  RpSubCam = 1'i32
  RpSubWorld = 2'i32

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
var gRpArmed = false       ## a detour that populates the GameWorld cache exists

# ---- the independent report -----------------------------------------------
# `raidPhaseLog`, and NOTHING else, gates the lines below. It defaults ON, which
# is a deliberate departure from "new features ship OFF": the entire point of
# this emitter is that with all 28 optional features off the host must STILL say
# whether we are in a raid, and a default-OFF flag would defeat exactly that.
# The departure is bounded -- it adds no work in the tick (the tick is already
# unconditional), touches no game memory of its own, and only formats state that
# was already computed.
var gRpLogOn = true
var gRpLogAt = 0'u64
var gRpLogLast = -2'i32    ## last phase PRINTED; -2 = nothing printed yet
const RpLogEveryMs = 5000'u64

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
  # THE IN-GUARD POSITIVE CONTROL. Same clock helpers, same place in the tick,
  # 512 integer adds into a volatile sink. Taken FIRST so it also prices SEH
  # guard entry: `ctrl_out` cheap while `ctrl_in` is dear would mean the guard
  # itself is the cost, which is neither of the two explanations the control
  # normally separates.
  cRpCtrlIn()
  gRpS1 = false
  gRpS2 = false
  gRpS3 = false
  gRpAliveN = 0

  # ---- the raw signals ---------------------------------------------------
  # S4, at most once a second: the scene-name query is three calls into Unity
  # and the results screen does not appear between frames.
  #
  # The tick is classified SCENE or LIGHT here, and the two are counted apart:
  # folding one ~1/s Unity query into sixty cheap ticks hides its entire cost
  # inside the mean, which is the exact shape of hole that hid 11.4ms.
  if (cNowMs() - gRpSceneAt) >= RpSceneEveryMs:
    gRpSceneAt = cNowMs()
    cRpPhaseScene()
    cRpSubBegin(RpSubScene)
    gRpS4 = iSceneNamePresent(RpSessionEndScene)
    cRpSubEnd(RpSubScene)
  cRpSubBegin(RpSubCam)
  gRpS5 = rpCameraMain() != nil
  cRpSubEnd(RpSubCam)

  # The three sub-brackets are DISJOINT (none encloses another) and cover every
  # call this body makes into the game. What is left over is local bookkeeping,
  # and `rpCostLine` prints the identity `accounted=X of Y us` so the leftover
  # is visible rather than assumed to be zero.
  cRpSubBegin(RpSubWorld)
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
  cRpSubEnd(RpSubWorld)

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
  # RECORDED, not just tested inline: the log line below must be able to say
  # "S1/S2/S3 are INCONCLUSIVE because nothing populates the GameWorld cache"
  # rather than printing them as `no`, which reads as a measurement of absence.
  gRpArmed = gDebugEspSlot >= 0 or gBotDiagSlot >= 0
  if gRpLatched:
    gRpPhase = RpPhaseDeployed
  elif gRpS4 == 1'i32:
    gRpPhase = RpPhaseResults
  elif gRpS1:
    gRpPhase = RpPhaseLoading
  elif gRpArmed:
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
  # THE OUT-OF-GUARD POSITIVE CONTROL, immediately before the real bracket.
  cRpCtrlOut()
  cRpCostBegin()
  let ok = cRpTickGuarded(nil)
  cRpCostEnd()
  if ok == nil:
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

proc rpUs(ns: int64): string =
  ## ONE unit, everywhere, always spelled. natesp's sub-means were read as
  ## NANOseconds once and sent an agent after a phantom; every number this
  ## module prints carries `us` and every line says so again in words.
  if ns < 0: return "n/a"
  $(ns div 1000) & "." & $((ns mod 1000) div 100) & "us"

proc rpArmedNote(): string =
  ## The difference between "measured absent" and "nobody looked". S1/S2/S3 all
  ## read from `gDuGameWorld`, which is populated ONLY by the kind=11
  ## RegisterPlayer detour (flag `debugEsp`) or botdiag's handler (`botDiag`).
  ## With both off the cache is permanently null and S1/S2/S3 are permanently
  ## `no` -- which is NOT a measurement of "not in a raid". This is the exact
  ## confusion that made four bisect runs read as fast raids when they were
  ## menu-only.
  if gRpArmed:
    "S1/S2/S3 ARE MEASURED (a GameWorld-populating detour is installed)"
  else:
    "S1/S2/S3 ARE INCONCLUSIVE, NOT 'no': neither debugEsp nor botDiag is " &
    "armed, so NOTHING populates the GameWorld cache and those three can only " &
    "ever read `no`. Do not read them as evidence of no raid."

proc rpIndependentVerdict*(): string =
  ## THE ANSWER THAT SURVIVES ALL 28 OPTIONAL FEATURES BEING OFF.
  ##
  ## S4 (SceneManager scene names) and S5 (`UnityEngine.Camera::get_main`) are
  ## the only two of the five signals that depend on NO optional feature: S4
  ## goes through inspect's nav table and S5 through debugui's byte-verified
  ## static RVA table, and neither table is behind a flag.
  ##
  ## MEASURED (see this module's header): Camera.main is NULL in the menu, NULL
  ## on the loading screen, and NULL on the post-raid results screen, and it is
  ## live during a raid. So S5 alone is a genuine positive raid observation, and
  ## it is the one this line reports. It is stated SEPARATELY from `rpPhase()`
  ## and does not feed it -- the latch keeps its measured semantics and the
  ## consumers keep their gate; this is an extra instrument, not a new gate.
  ##
  ## THREE OUTCOMES, never two.
  if rpDisabled():
    "INCONCLUSIVE -- raidphase self-disabled after " & $gRpFaults &
      " faults. This is NOT 'not in a raid'."
  elif gRpS4 == 1'i32:
    "NOT IN A RAID (raid OVER) -- S4: SceneManager lists SessionEndUIScene, " &
      "the post-raid results screen."
  elif gRpS5:
    "IN A RAID -- S5: Camera.main is LIVE. Measured NULL in the menu, NULL on " &
      "the loading screen and NULL on the results screen, so a live " &
      "Camera.main is a positive in-raid observation and needs no feature flag."
  elif gRpS4 == 0'i32:
    "NOT IN A RAID -- S5: Camera.main is NULL (menu or loading screen) and S4 " &
      "confirms SceneManager was successfully enumerated with no " &
      "SessionEndUIScene."
  else:
    "INCONCLUSIVE -- S5 Camera.main is null AND S4 could not enumerate " &
      "SceneManager (a nav entry did not verify). Both legs refused; this is " &
      "'I could not look', NOT 'not in a raid'."

proc rpCostLine*(): string =
  ## WHAT THE ONE UNCONDITIONAL RIDER COSTS. Every number is MICROSECONDS and
  ## says so. A saturated histogram prints a bound and the word INCONCLUSIVE --
  ## never a sentinel dressed as a measurement.
  let budget = cRpBudgetNs()
  var s = "raidphase cost (MICROSECONDS throughout, budget " & rpUs(budget) & "):"

  # THE POSITIVE CONTROL FIRST, because it decides whether anything below it
  # means anything at all. 512 integer adds, same clock, same place in the tick.
  let co = cRpCtrlMeanNs(0'i32)
  let ci = cRpCtrlMeanNs(1'i32)
  s = s & " CONTROL(512 int adds, same clock): out-of-guard mean=" & rpUs(co) &
      " max=" & rpUs(cRpCtrlMaxNs(0'i32)) & " n=" & $cRpCtrlSamples(0'i32) &
      ", in-guard mean=" & rpUs(ci) & " max=" & rpUs(cRpCtrlMaxNs(1'i32)) &
      " n=" & $cRpCtrlSamples(1'i32) & " --"
  if co < 0 or ci < 0:
    s = s & " NO CONTROL SAMPLES YET, so every cost below is UNVALIDATED."
  elif co > 1000000'i64 or ci > 1000000'i64:
    s = s & " the control itself costs over a millisecond, so THE BRACKET IS " &
        "MEASURING THE FRAME, not this rider. Every cost below is an " &
        "INSTRUMENT ARTIFACT -- do not attribute it to raidphase."
  elif ci > co * 8 and ci > 50000'i64:
    s = s & " out-of-guard is cheap but IN-GUARD is not: SEH guard ENTRY is " &
        "carrying the cost, which is a finding in itself."
  else:
    s = s & " trivial work prices as trivial on this clock, so the costs " &
        "below are WORK, not measurement."

  # PER PHASE. Disjoint and exhaustive over ticks: a tick either ran the ~1/s
  # SceneManager query (SCENE) or did not (LIGHT).
  var ph = 0'i32
  while ph < 2'i32:
    let nm = (if ph == RpPhLight: "LIGHT(no scene query)" else: "SCENE(scene query ran)")
    let n = cRpCostN(ph)
    if n <= 0:
      s = s & " [" & nm & "] no samples -- INCONCLUSIVE."
    else:
      let mean = cRpCostMeanNs(ph)
      let p95 = cRpCostP95Ns(ph)
      var p95Txt = ""
      var verdict = ""
      if p95 == cRpP95Sat():
        p95Txt = ">= " & rpUs(cRpTopEdgeNs()) & " (histogram SATURATED)"
        verdict = "INCONCLUSIVE: the 95th sample is above every finite edge, " &
                  "so the budget can be neither met nor missed on this " &
                  "evidence (mean=" & rpUs(mean) & ", max=" &
                  rpUs(cRpCostMaxNs(ph)) & ", " & $cRpCostOvf(ph) &
                  " sample(s) overflowed)"
      else:
        p95Txt = "<= " & rpUs(p95)
        if n < cRpMinSamples():
          verdict = "INCONCLUSIVE: only " & $n & " sample(s), fewer than the " &
                    $cRpMinSamples() & " this verdict requires -- not a PASS"
        elif p95 > budget:
          verdict = "FAIL: p95 " & p95Txt & " exceeds the budget " & rpUs(budget)
        else:
          verdict = "PASS: p95 " & p95Txt & " within budget " & rpUs(budget)
      s = s & " [" & nm & "] mean=" & rpUs(mean) & " p95" & p95Txt & " max=" &
          rpUs(cRpCostMaxNs(ph)) & " n=" & $n & " over-budget=" &
          $cRpCostOver(ph) & " -- " & verdict & "."
    inc ph

  # THE SUB-DECOMPOSITION, with its accounting identity printed. A decomposition
  # that does not sum to the whole is a HOLE, and the only way to see the hole
  # is to print `accounted=X of Y`.
  var si = 0'i32
  while si < cRpSubCount():
    s = s & " sub[" & $cRpSubName(si) & "] mean=" & rpUs(cRpSubMeanNs(si)) &
        " max=" & rpUs(cRpSubMaxNs(si)) & " n=" & $cRpSubN(si) & ";"
    inc si
  let acc = cRpAccMeanNs()
  # The whole, for the identity, is the sample-weighted mean across both phases.
  let nL = cRpCostN(RpPhLight)
  let nS = cRpCostN(RpPhScene)
  var whole = -1'i64
  if (nL + nS) > 0:
    let mL = (if nL > 0: cRpCostMeanNs(RpPhLight) else: 0'i64)
    let mS = (if nS > 0: cRpCostMeanNs(RpPhScene) else: 0'i64)
    whole = (mL * nL + mS * nS) div (nL + nS)
  if acc < 0 or whole <= 0:
    s = s & " accounted=n/a (no paired samples yet) -- INCONCLUSIVE, the " &
        "decomposition has NOT been shown to be exhaustive."
  else:
    let pct = (acc * 100'i64) div whole
    s = s & " accounted=" & rpUs(acc) & " of " & rpUs(whole) & " (" & $pct &
        "%) over " & $cRpAccN() & " tick(s)"
    if pct < 80:
      s = s & " -- OVER A FIFTH IS UNACCOUNTED. The sub-brackets do NOT " &
          "explain this body; do not conclude anything from them alone."
    else:
      s = s & " -- the sub-brackets account for the body."
  s = s & " tick-interval mean=" & rpUs(cRpGapMeanNs()) & " over " &
      $cRpGapN() & " tick(s), dropped=" & $cRpDropped() & " sample(s)."
  s

proc rpLogTick*() =
  ## THE FEATURE-INDEPENDENT RAID-PHASE REPORT.
  ##
  ## WHY IT EXISTS, measured: the latch was only ever REPORTED through natesp's
  ## diag line, so with `natEsp` off there was no way to confirm the client was
  ## in a raid. Four performance bisects produced fast frame times (~18-19ms)
  ## that were attributed to "features off is faster" and were afterwards shown
  ## to be MENU-ONLY -- one run printed `raid phase = UNKNOWN` across 43,597
  ## frames. A raid-ENTRY log line is not proof of raid STATE, and a ~74ms
  ## claim had to be retracted because of it.
  ##
  ## Gated by `raidPhaseLog` alone (default ON) and by nothing else. Throttled
  ## to one line every 5s, plus one on EVERY phase transition, so an entry or an
  ## extraction is never missed between throttle windows.
  if not gRpLogOn: return
  let now = cNowMs()
  let changed = gRpPhase != gRpLogLast
  if not changed and (now - gRpLogAt) < RpLogEveryMs: return
  gRpLogAt = now
  gRpLogLast = gRpPhase
  okLog "raid phase = " & rpPhaseName(gRpPhase) &
        (if changed: " (TRANSITION)" else: "") & " -- " & rpWhy() &
        "  [" & rpSignals() & "]" &
        "  FEATURE-INDEPENDENT VERDICT: " & rpIndependentVerdict() &
        "  " & rpArmedNote() &
        "  " & rpCostLine()

proc rpConfigureLog*(on: bool) =
  ## Called once at config load, from the point where `readBoolKeyDef` exists.
  gRpLogOn = on

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
