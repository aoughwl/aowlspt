# splrebrand.nim -- rebrand the "PRACTICE GAME MODE" block on the Matchmaker
# Offline Raid Screen as aowlspt SINGLEPLAYER, and hide the practice-mode
# checkbox, WITHOUT touching the offline routing.
#
# `include`d into `aowlhost.nim` AFTER `nativeui.nim`, `debugui.nim` and
# `inspect.nim`, because it borrows a byte-verified primitive from each and
# adds NO C targets and NO header of its own:
#   * from `nativeui.nim` -- `nuFn`/`nuOk`/`nuStr` and the call thunks, the
#     real setters `TMP_Text::set_text`(NuTTmpSetText) and
#     `LocalizedText::SetLabelText`(NuTLocSetLabelText), plus `nuSetActive`,
#     `nuActiveInHierarchy`. Every one is resolved by RVA + startup-snapshot
#     prologue verify inside `cNuFn`, independent of the `nativeUi` flag, so
#     this feature does not depend on another feature being enabled.
#   * from `inspect.nim`  -- `iSceneRoots` (the DontDestroyOnLoad-aware root
#     walk), `iChildCount`/`iChildAt`/`iObjName`/`iToTransform`/`iHierRoot`,
#     `iUnityAlive`, `iFindTarget`/`iTargetFn`/`iMark`, `iInspSeedTextType`
#     and its cached `gTxtTypeStr`, and `iIsKnownKlass`.
#   * from `debugui.nim`  -- `duOk`, the every-hop VirtualQuery.
#
# WHAT THE USER SEES / WANTS
# --------------------------
# On the Matchmaker Offline Raid Screen (reached via recipe `enter-offline-raid`,
# under the `Menu UI` scene root) there is:
#   * a heading  "PRACTICE GAME MODE"
#   * a description  "In this mode, you can practice offline ..."
#   * a checkbox "Enable practice mode for this raid" (label at
#     Content/NonLayoutContainer/SoloModeCheckmarkBlocker/Label; the control is
#     `EFT.UI.UpdatableToggle` on the SoloModeCheckmarkBlocker GameObject --
#     fact #71).
# This feature relabels the heading + description to SINGLEPLAYER branding and
# SetActive(false)s the checkbox's GameObject.
#
# WHY HIDING THE TOGGLE IS SAFE FOR ROUTING
# -----------------------------------------
# The user reports the checkbox is UNCHECKED and the raid is ALREADY offline
# against our emulated backend. That proves the offline ROUTING does not depend
# on this toggle -- our backend is the server regardless. SetActive(false) hides
# the GameObject; it does NOT change the toggle's boolean value (it stays
# whatever it was, i.e. unchecked), and this feature never calls set_isOn. So
# neither the routing nor the practice/persistence semantics are altered -- only
# the control's visibility. Persistence (loot/XP saving) is decided by the
# backend, not by a client field we touch here; this feature makes no claim
# about it and changes nothing that would affect it.
#
# DISCOVERY IS LIVE AND BY CONTENT, NEVER A HARDCODED PATH (fact #104)
# -------------------------------------------------------------------
# A hardcoded child path that does not exist FAULTS and self-disables. So the
# screen is found by object NAME ("Matchmaker Offline Raid Screen") from a
# verified scene root, then the three targets are found by the TEXT they DISPLAY
# (the same signal `findtext` and the recipe's `find_text` use), each hop
# guarded. A miss is a quiet return (the screen only exists once the user
# navigates to it), never a fault.
#
# SAFETY (all eight rules)
# ------------------------
#   * flag-gated `singleplayerRebrand`, DEFAULT OFF;
#   * every managed target is 16-byte prologue-verified in `cNuFn` before it is
#     called (byte-compared to the startup snapshot), so on any other build
#     this is a silent no-op;
#   * the whole per-tick body runs under ONE `aowl_p_p_seh` (`cSplTickGuarded`)
#     -- one, never nested;
#   * every pointer hop is `duOk`/`nuOk`-guarded before it is dereferenced, and
#     `iUnityAlive` before any icall;
#   * every walk is bounded by a node budget AND an in-walk wall-clock deadline;
#   * self-disables after `SplMaxFaults` guarded bodies fault;
#   * NO PER-FRAME MANAGED ALLOCATION: the branding strings are INTERNED once
#     via `nuStr`, and the whole body is throttled to ~1 Hz while hunting and
#     slower once done -- it rides the existing `TarkovApplication::Update`
#     drain (a slot alias, NOT a second detour).

# ---- the exact stock text this screen ships (lower-cased for matching) ----
const
  SplScreenName   = "Matchmaker Offline Raid Screen"
  SplBlockerName  = "SoloModeCheckmarkBlocker"
  SplHeadStock    = "practice game mode"
  SplDescStock    = "in this mode"
  SplToggleStock  = "enable practice mode for this raid"
  # ---- what we replace them with. Factual; no persistence claim. ----
  SplHeadNew      = "SINGLEPLAYER"
  SplDescNew      = "aowlspt - a local single-player raid against the emulated server."

# ---- bounds ----
const
  SplWarmupMs     = 5000'u64   ## the menu is not up before this; do not walk.
  SplHuntFrames   = 60         ## ~1 s at 60 fps while hunting/maintaining.
  SplSteadyFrames = 180        ## ~3 s once confirmed done -- just guards clobber.
  SplWalkMs       = 6'u64      ## per-pass wall-clock slice, checked INSIDE the walk.
  SplNodeBudget   = 3000       ## per-pass node cap, threaded through the recursion.
  SplFanout       = 64         ## children examined per level.
  SplFindDepth    = 8          ## depth for the screen-by-name descent.
  SplScanDepth    = 12         ## depth for the by-text scan within the screen.
  SplBlockerUp    = 5          ## how far to climb from the toggle label to the blocker.
  SplMaxFaults    = 3

# ---- the guarded-body thunk (ONE aowl_p_p_seh, never nested) ----
{.emit: """
extern void* aowl_spl_tick_body(void* a);
static void* aowl_spl_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_spl_tick_body, a);
}
""".}
proc cSplTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_spl_tick_guarded", nodecl.}

# ---- state (gSplOn is set in the flag-reading pass in aowlhost.nim) ----
var gSplOn = false                 ## the `singleplayerRebrand` flag; DEFAULT OFF
var gSplOff = false                ## self-disabled after faults
var gSplFaults = 0
var gSplT0 = 0'u64
var gSplFrames = 0

var gSplResolved = false           ## heading TMP found; cache below is trusted
var gSplHeadTmp: Il2CppPtr = nil   ## the "PRACTICE GAME MODE" TMP
var gSplHeadLoc: Il2CppPtr = nil   ## its LocalizedText sibling (optional; nil ok)
var gSplDescTmp: Il2CppPtr = nil   ## the description TMP (optional)
var gSplDescLoc: Il2CppPtr = nil
var gSplCheckGo: Il2CppPtr = nil   ## the SoloModeCheckmarkBlocker GameObject
var gSplConfirmed = false          ## finished-state assertion has passed+logged
var gSplSummaryLogged = false

# ---------------------------------------------------------------------------
# Small guarded primitives, each a thin reuse of an already-verified target.
# ---------------------------------------------------------------------------
var gSplLocStr: Il2CppPtr = nil
proc splLocTypeStr(): Il2CppPtr =
  ## Interned "LocalizedText" for GetComponent. Allocated at most once.
  if gSplLocStr != nil and duOk(gSplLocStr, 0x18'i32):
    return gSplLocStr
  var nm = "LocalizedText"
  gSplLocStr = cNavNewString(toCString(nm))
  result = gSplLocStr

proc splComponent(node, typeStr: Il2CppPtr): Il2CppPtr =
  ## `Component::GetComponent(String)` on a Transform node. Returns nil on any
  ## refusal -- a null is an ANSWER (the component is absent), never a fault.
  result = nil
  if cNavIcallReady() == 0'i32 or typeStr == nil: return
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet("Component::GetComponent(String)", fn) or fn == nil: return
  if not duOk(node, 0x20'i32) or not iUnityAlive(node): return
  iMark("Component::GetComponent(String) [splrebrand]", node)
  let comp = cast[Il2CppPtr](cInspUPP(fn, node, typeStr, nil))
  if comp != nil and duOk(comp, 0xE8'i32) and iUnityAlive(comp):
    result = comp

proc splTmpOf(node: Il2CppPtr): Il2CppPtr =
  ## The TextMeshProUGUI component on a node, via the cached "TextMeshProUGUI"
  ## type string `findtext` already seeds.
  if not iInspSeedTextType(): return nil
  splComponent(node, gTxtTypeStr)

proc splTmpText(tmp: Il2CppPtr): string =
  ## m_text @0x0E0, decoded by the fixed System.String layout. Guarded exactly
  ## as `findtext` guards it: a KNOWN-KLASS value there is type confusion, not a
  ## String, and must not be read as one.
  result = ""
  if not duOk(tmp, 0xE8'i32): return
  let sp = cReadPtrAt(tmp, 0xE0'i32)
  if sp != nil and not iIsKnownKlass(cast[uint64](sp)) and duOk(sp, 0x18'i32):
    result = suiReadString(sp)

proc splParent(t: Il2CppPtr): Il2CppPtr =
  ## `Transform::get_parent`, guarded. nil on any refusal.
  result = nil
  var idx = 0
  var hits = 0
  if not iFindTarget("Transform::get_parent", idx, hits): return
  let fn = iTargetFn(idx)
  if fn == nil or not iUnityAlive(t): return
  iMark("Transform::get_parent", t)
  let par = cast[Il2CppPtr](cInspUP(fn, t, nil))
  if par != nil and duOk(par, 0x20'i32):
    result = par

proc splSetText(tmp, loc: Il2CppPtr; s: string): bool =
  ## Set TMP text through the REAL setters and re-apply -- the same recipe as
  ## `nuSetText`, inlined here so it does not depend on the `nativeUi` flag.
  ## `ForceMeshUpdate` is deliberately NOT called (0x628110 is the universal
  ## empty stub). The interned string means no per-tick managed allocation.
  let fnSet = nuFn(NuTTmpSetText)
  let str = nuStr(s)
  if fnSet == nil or str == nil or not nuOk(tmp, 0x10'i32): return false
  cNuCallVPP(fnSet, tmp, str)
  if loc != nil and nuOk(loc, 0x10'i32):
    let fnLoc = nuFn(NuTLocSetLabelText)
    if fnLoc != nil:
      cNuCallVPP(fnLoc, loc, str)
      cNuCallVPP(fnSet, tmp, str)          # re-apply after LocalizedText clobber
  result = true

# ---------------------------------------------------------------------------
# Discovery: bounded, time-sliced.
# ---------------------------------------------------------------------------
proc splFindByName(t: Il2CppPtr; name: string; depth: int;
                   budget: var int; deadline: uint64): Il2CppPtr =
  ## A bounded, TIME-SLICED descent by object name. Three bounds (budget,
  ## in-walk deadline, depth+fan-out), mirroring `mtxDescend`.
  result = nil
  if t == nil or depth < 0 or budget <= 0 or not duOk(t, 0x20'i32): return
  budget = budget - 1
  if (budget and 31) == 0 and cNowMs() > deadline:
    budget = 0                              # poison the budget: unwinds all levels
    return
  if iObjName(t) == name:
    return t
  if depth == 0: return
  var n = 0
  if not iChildCount(t, n): return
  var i = 0
  while i < n and i < SplFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil:
      result = splFindByName(c, name, depth - 1, budget, deadline)
      if result != nil: return
    i = i + 1

proc splFindScreen(): Il2CppPtr =
  ## The "Matchmaker Offline Raid Screen" transform, from every scene root, ONE
  ## shared node budget and in-walk deadline across all roots. `iSceneRoots`
  ## reaches `Menu UI` (a SceneManager-listed scene on this build), so this does
  ## not depend on the live inspector's `gInspPreloader` anchor. A nil return
  ## means the screen is not up right now, which is the common case.
  result = nil
  var roots: seq[Il2CppPtr] = @[]
  discard iSceneRoots(roots, false)
  if roots.len == 0: return
  let deadline = cNowMs() + SplWalkMs
  var budget = SplNodeBudget
  var i = 0
  while i < roots.len and budget > 0:
    let r = iToTransform(roots[i])
    if r != nil and duOk(r, 0x20'i32):
      let m = splFindByName(r, SplScreenName, SplFindDepth, budget, deadline)
      if m != nil: return m
    i = i + 1

proc splScanNode(t: Il2CppPtr; depth: int; budget: var int; deadline: uint64) =
  ## DFS the screen subtree; at each node read its TMP text and, by CONTENT,
  ## fill whichever of the three targets it is. Bounded exactly like the name
  ## descent. Records into the module-level cache.
  if t == nil or depth < 0 or budget <= 0 or not duOk(t, 0x20'i32): return
  budget = budget - 1
  if (budget and 31) == 0 and cNowMs() > deadline:
    budget = 0
    return
  let tmp = splTmpOf(t)
  if tmp != nil:
    let low = iLower(splTmpText(tmp))
    if low.len > 0:
      if gSplHeadTmp == nil and iContains(low, SplHeadStock):
        gSplHeadTmp = tmp
        gSplHeadLoc = splComponent(t, splLocTypeStr())
      elif gSplDescTmp == nil and iContains(low, SplDescStock):
        gSplDescTmp = tmp
        gSplDescLoc = splComponent(t, splLocTypeStr())
      elif gSplCheckGo == nil and iContains(low, SplToggleStock):
        # Climb to the SoloModeCheckmarkBlocker and take its GameObject.
        var up = t
        var k = 0
        while k < SplBlockerUp and up != nil:
          if iObjName(up) == SplBlockerName:
            let go = iGameObjectOf(up)
            if go != nil and duOk(go, 0x20'i32):
              gSplCheckGo = go
            break
          up = splParent(up)
          k = k + 1
  if depth == 0: return
  var n = 0
  if not iChildCount(t, n): return
  var i = 0
  while i < n and i < SplFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil:
      splScanNode(c, depth - 1, budget, deadline)
    i = i + 1

# ---------------------------------------------------------------------------
# Maintain + assert the FINISHED STATE (never our own write -- fact #9b).
# ---------------------------------------------------------------------------
proc splCacheStale(): bool =
  ## The screen can be destroyed (navigate away) and rebuilt; the cached
  ## pointers then read a dead object. If the heading TMP is gone, drop the
  ## whole cache and re-discover.
  gSplHeadTmp == nil or not duOk(gSplHeadTmp, 0xE8'i32) or
    not iUnityAlive(gSplHeadTmp)

proc splMaintain() =
  ## Re-apply the branding on drift (LocalizedText re-clobbers m_text on a
  ## localisation refresh) and keep the checkbox hidden. Then, ONCE, assert the
  ## finished state and log PASS/FAIL/INCONCLUSIVE per target.
  # Heading -- the primary deliverable.
  let headLow = iLower(splTmpText(gSplHeadTmp))
  var headOk = false
  if iContains(headLow, iLower(SplHeadNew)):
    headOk = true
  else:
    discard splSetText(gSplHeadTmp, gSplHeadLoc, SplHeadNew)

  # Description -- optional; only maintained if it was found.
  var descState = 2   # 0 FAIL, 1 PASS, 2 INCONCLUSIVE (not found)
  if gSplDescTmp != nil and duOk(gSplDescTmp, 0xE8'i32) and iUnityAlive(gSplDescTmp):
    if iContains(iLower(splTmpText(gSplDescTmp)), iLower(SplDescNew)):
      descState = 1
    else:
      discard splSetText(gSplDescTmp, gSplDescLoc, SplDescNew)
      descState = 0

  # Checkbox -- SetActive(false) on drift; assert activeInHierarchy == false.
  var hideState = 2
  if gSplCheckGo != nil and duOk(gSplCheckGo, 0x20'i32) and iUnityAlive(gSplCheckGo):
    if nuActiveInHierarchy(gSplCheckGo):
      discard nuSetActive(gSplCheckGo, false)
      hideState = 0
    else:
      hideState = 1

  # Finished-state summary, once, when the heading has taken.
  if headOk and not gSplSummaryLogged:
    let descStr = (case descState
      of 1: "PASS (reads the new description)"
      of 0: "FAIL (still not the new description -- re-applying)"
      else: "INCONCLUSIVE (no description TMP was found on this screen)")
    let hideStr = (case hideState
      of 1: "PASS (checkbox GameObject activeInHierarchy == false)"
      of 0: "FAIL (checkbox still active -- re-applying SetActive(false))"
      else: "INCONCLUSIVE (the practice-mode checkbox was not found)")
    okLog "singleplayer rebrand: FINISHED-STATE readback -- heading: PASS " &
          "(the rendered TMP no longer reads \"PRACTICE GAME MODE\"); " &
          "description: " & descStr & "; hide: " & hideStr & ". This asserts " &
          "the live tree, not that the setter ran."
    gSplSummaryLogged = true
    if descState != 0 and hideState != 0:
      gSplConfirmed = true

# ---------------------------------------------------------------------------
# The guarded body + the drain rider.
# ---------------------------------------------------------------------------
proc splRebrandTickBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_spl_tick_body", cdecl.} =
  ## Everything that touches managed memory, under ONE guard. Returns a non-nil
  ## sentinel on clean completion; the guard returns nil if this faulted.
  result = cast[Il2CppPtr](1)
  discard a

  if gSplResolved and splCacheStale():
    # The screen went away and came back (or was rebuilt). Re-discover from
    # scratch rather than writing into a dead object.
    gSplResolved = false
    gSplHeadTmp = nil; gSplHeadLoc = nil
    gSplDescTmp = nil; gSplDescLoc = nil
    gSplCheckGo = nil
    gSplConfirmed = false
    gSplSummaryLogged = false

  if not gSplResolved:
    let screen = splFindScreen()
    if screen == nil: return              # not up right now -- quiet, not a fault
    var budget = SplNodeBudget
    let deadline = cNowMs() + SplWalkMs
    splScanNode(screen, SplScanDepth, budget, deadline)
    if gSplHeadTmp == nil:
      return                              # screen present but heading not read yet
    gSplResolved = true
    okLog "singleplayer rebrand: resolved on \"" & SplScreenName &
          "\" -- heading TMP " & (if gSplHeadTmp != nil: "found" else: "MISSING") &
          ", description TMP " & (if gSplDescTmp != nil: "found" else: "not found") &
          ", checkbox GameObject " &
          (if gSplCheckGo != nil: "found" else: "NOT found") &
          ". Walking from the live scene root, by displayed text -- no " &
          "hardcoded child path."

  splMaintain()

proc splRebrandDrainTick() =
  ## Rides the `EFT.TarkovApplication::Update` drain (slot alias, no second
  ## detour). Cheap when idle: off, self-disabled, or inside the warm-up it is
  ## a handful of integer compares and makes NO call into the game.
  if not gSplOn or gSplOff: return
  if gSplT0 == 0'u64: gSplT0 = cNowMs()
  if cNowMs() - gSplT0 < SplWarmupMs: return   # the menu cannot be up yet
  inc gSplFrames
  let every = (if gSplResolved and gSplConfirmed: SplSteadyFrames
               else: SplHuntFrames)
  if gSplFrames < every: return
  gSplFrames = 0
  if cSplTickGuarded(nil) == nil:
    inc gSplFaults
    warn "singleplayer rebrand: the guarded body faulted (" & $gSplFaults &
         " of " & $SplMaxFaults & ")"
    if gSplFaults >= SplMaxFaults:
      gSplOff = true
      warn "singleplayer rebrand: too many faults; switching itself off for " &
           "this session and leaving the stock screen alone. This is a " &
           "REFUSAL, not a success."
