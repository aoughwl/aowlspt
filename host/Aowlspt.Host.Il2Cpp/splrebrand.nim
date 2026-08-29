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
# FORCE THE TOGGLE, THEN HIDE (corrected 2026-08-28)
# --------------------------------------------------
# The coordinator's correction: offline/singleplayer likely REQUIRES the box
# CHECKED, so hiding it while unchecked could drop the raid out of offline. So
# this now FORCES the value before hiding, in this order (order matters):
#   1. `Toggle::set_isOn(SplForceIsOn)` on the UpdatableToggle -- the NOTIFYING
#      setter, byte-verified @0x55BA430 (fact #71), re-asserted once. It runs the
#      game's onValueChanged listener (the thing that actually selects the mode);
#      a raw m_IsOn store would move the field WITHOUT running it.
#   2. read m_IsOn(+0x120) BACK and assert it equals the wanted value -- a
#      readback that can FAIL (CLAUDE.md 9b). Only on PASS do we hide.
#   3. `SetActive(false)` to hide the (now correctly-valued) checkbox.
# If set_isOn does not verify, or the readback does not match, this REFUSES to
# hide and leaves the box VISIBLE rather than hidden-with-an-unknown-value.
#
# WHICH WAY IT GATES IS UNCONFIRMED -- INCONCLUSIVE, flagged for live check.
# The original report ("unchecked AND offline") and the correction ("offline
# needs checked") conflict, and it cannot be settled offline on this machine
# (no decrypted metadata / no GameAssembly.dll here to disassemble the
# UpdatableToggle handler). So `SplForceIsOn = true` follows the user's stated
# expectation; if a live raid comes up ONLINE after this, flip that ONE const.
# This feature never claims anything about loot/XP persistence.
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
  # ---- the co-op / Edge-of-Darkness "your progress is not saved/shared"
  # warning, hidden whole. Matched by DISPLAYED TEXT within THIS screen only
  # (the global findtext could never surface it -- the 16-root search exhausted
  # its node budget every time). The predicate is deliberately narrow so it can
  # NEVER catch the unrelated weapon warning "ATTENTION! Your weapon doesn't
  # have the required vital part": it requires "progress" AND a corroborating
  # co-op/not-saved token, AND explicitly EXCLUDES "vital part"/"weapon".
  SplWarnStock    = "progress"
  SplWarnExclA    = "vital part"
  SplWarnExclB    = "weapon"
  # ---- what we replace them with. Factual; no persistence claim. ----
  SplHeadNew      = "SINGLEPLAYER"
  SplDescNew      = "aowlspt - a local single-player raid against the emulated server."
  # ---- the practice toggle, forced ON before it is hidden ----
  # `aowl_sw_targets[AOWL_SW_TOGGLE_SET_ISON]` = UnityEngine.UI.Toggle::set_isOn
  # @0x55BA430, byte-verified (16-byte prologue vs the startup snapshot) inside
  # `cSwFn2`; a mismatch returns nil and this feature REFUSES to touch the box.
  SplToggleSetIsOn = 1'i32
  # WHICH WAY DOES THE BOX GATE OFFLINE? UNCONFIRMED. The user's original report
  # was "unchecked AND offline"; the correction is "offline likely REQUIRES
  # checked". I cannot settle it offline on this machine (no decrypted metadata,
  # no GameAssembly.dll here, so the UpdatableToggle::onValueChanged handler
  # cannot be disassembled), so this is INCONCLUSIVE and must be confirmed live.
  # We force the box to the user's stated expectation (ON = checked). If a live
  # deploy shows forcing ON drops us ONLINE, flip this ONE const to `false`
  # (force OFF) -- do NOT re-derive the plumbing.
  SplForceIsOn    = true

# ---- bounds ----
const
  SplWarmupMs     = 5000'u64   ## the menu is not up before this; do not walk.
  SplHuntFrames   = 60         ## ~1 s at 60 fps while hunting/maintaining.
  SplSteadyFrames = 180        ## ~3 s once confirmed done -- just guards clobber.
  SplWalkMs       = 18'u64     ## per-pass wall-clock slice, checked INSIDE the walk.
  SplNodeBudget   = 24000      ## per-ROOT node cap (reset per root), threaded through the
                               ## recursion. The offline-raid screen sits deep in the large
                               ## "UI" root (the live inspector only reached it after ~thousands
                               ## of nodes), so 3000 shared across all roots exhausted before
                               ## reaching it -- the silent nil that hid this bug.
  SplFanout       = 256        ## children examined per level -- the "UI" root has many child
                               ## screens; 64 could cut off the target sibling.
  SplFindDepth    = 8          ## depth for the screen-by-name descent.
  SplScanDepth    = 12         ## depth for the by-text scan within the screen.
  SplBlockerUp    = 5          ## how far to climb from the toggle label to the blocker.
  SplWarnUp       = 4          ## how far to climb from the warning TMP to its panel container.
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

var gSplDiagPasses = 0             ## hunt passes since the last diag line (rate limiter)
var gSplLastWhy = ""              ## the last discovery-failure reason we logged
var gSplLastNodes = 0             ## nodes visited on the last screen descent

var gSplResolved = false           ## heading TMP found; cache below is trusted
var gSplHeadTmp: Il2CppPtr = nil   ## the "PRACTICE GAME MODE" TMP
var gSplHeadLoc: Il2CppPtr = nil   ## its LocalizedText sibling (optional; nil ok)
var gSplDescTmp: Il2CppPtr = nil   ## the description TMP (optional)
var gSplDescLoc: Il2CppPtr = nil
var gSplCheckGo: Il2CppPtr = nil   ## the SoloModeCheckmarkBlocker GameObject
var gSplToggle: Il2CppPtr = nil    ## the EFT.UI.UpdatableToggle component (a Toggle)
var gSplForceRefused = false       ## set_isOn did not verify; box left VISIBLE
var gSplForceRefusedLogged = false
var gSplWarnGo: Il2CppPtr = nil    ## the co-op/EoD "progress" warning container to hide
var gSplWarnText = ""              ## the matched displayed text (evidence for the readback)
var gSplWarnName = ""              ## name of the node we hide (container or the TMP node)
var gSplWarnMatched = false        ## a valid co-op/progress text match was found this discovery
var gSplWarnRefused = false        ## screen resolved but NO co-op/progress warning matched
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

var gSplTogStr: Il2CppPtr = nil
proc splTogTypeStr(): Il2CppPtr =
  ## Interned "UpdatableToggle" for GetComponent (fact #71: the control is
  ## EFT.UI.UpdatableToggle). It derives from UnityEngine.UI.Toggle, so the
  ## returned component is a valid `this` for Toggle::set_isOn and carries
  ## m_IsOn at +0x120.
  if gSplTogStr != nil and duOk(gSplTogStr, 0x18'i32):
    return gSplTogStr
  var nm = "UpdatableToggle"
  gSplTogStr = cNavNewString(toCString(nm))
  result = gSplTogStr

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

proc splForceToggle(): int =
  ## Force the practice toggle to `SplForceIsOn` via the NOTIFYING setter
  ## `Toggle::set_isOn`, so the game's own onValueChanged listener runs (that
  ## listener is what actually selects the mode -- a raw m_IsOn store would move
  ## the field and NOT run it). Re-asserts once, like a LocalizedText re-apply,
  ## in case something flips it on the same frame. Then reads m_IsOn BACK and
  ## returns the FINISHED STATE, never the fact that the setter ran:
  ##   1 -> readback matches the wanted value (PASS)
  ##   0 -> readback does NOT match (FAIL -- caller must REFUSE to hide)
  ##  -1 -> could not act at all (set_isOn did not verify, or the component is
  ##        unreadable) -- INCONCLUSIVE, caller must REFUSE to hide.
  result = -1
  let fn = cSwFn2(SplToggleSetIsOn)
  if fn == nil:
    if not gSplForceRefusedLogged:
      gSplForceRefusedLogged = true
      warn "singleplayer rebrand: Toggle::set_isOn @0x55BA430 did NOT verify " &
           "against the startup prologue snapshot on this build, so the " &
           "practice toggle CANNOT be forced. REFUSING to hide the checkbox -- " &
           "it is left VISIBLE (and at whatever value the game set) rather than " &
           "hidden with an unknown value. This is a REFUSAL, not a success."
    gSplForceRefused = true
    return
  let off = cSwOffToggleIsOn()
  if not duOk(gSplToggle, off + 8'i32):
    return
  let want = (if SplForceIsOn: 1'i32 else: 0'i32)
  cSwCallVPB2(fn, gSplToggle, want)        # force
  cSwCallVPB2(fn, gSplToggle, want)        # re-assert once
  # READBACK on the finished state. `cSwReadU8` is the guarded byte read.
  let got = cSwReadU8(gSplToggle, off)
  if got == want:
    result = 1
  else:
    result = 0

# ---------------------------------------------------------------------------
# Discovery: bounded, time-sliced.
# ---------------------------------------------------------------------------
proc splFindByName(t: Il2CppPtr; name: string; depth: int;
                   budget: var int; deadline: uint64): Il2CppPtr =
  ## A bounded, TIME-SLICED descent by object name. Three bounds (budget,
  ## in-walk deadline, depth+fan-out), mirroring `mtxDescend`.
  ## BREADTH-BEFORE-DEPTH: at each node we check ALL of its direct children's
  ## names before recursing into any subtree. The target here is a DIRECT child
  ## of the large "UI" root, so a pure DFS would burn the whole budget on the
  ## earlier siblings' (also large) subtrees before ever reaching it -- exactly
  ## the budget-exhaustion that returned nil forever. Checking the sibling names
  ## first reaches a direct child in O(#siblings) nodes, not O(subtree).
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
  # Pass 1 -- breadth: name-check every direct child (cheap; no descent).
  var i = 0
  while i < n and i < SplFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      budget = budget - 1
      if (budget and 31) == 0 and cNowMs() > deadline:
        budget = 0
        return
      if iObjName(c) == name:
        return c
    i = i + 1
  # Pass 2 -- depth: recurse only after the whole level missed by name.
  i = 0
  while i < n and i < SplFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil:
      result = splFindByName(c, name, depth - 1, budget, deadline)
      if result != nil: return
    i = i + 1

proc splAnchor(): Il2CppPtr =
  ## A DURABLE, inspector-independent anchor into the DontDestroyOnLoad scene --
  ## where the live UI (and the "Matchmaker Offline Raid Screen") actually lives,
  ## since SceneManager excludes that scene BY DESIGN (CLAUDE.md 2).
  ##
  ## MEASURED live (inspector `roots`/`find`): the offline-raid screen is a
  ## shallow descendant of "Menu UI" in the DontDestroyOnLoad scene (handle -12,
  ## 22 roots). `gVerPreloader` -- the version-brand's `PreloaderUI::Awake`
  ## `this` -- does NOT belong to that scene: `GameObject::get_scene_Injected`
  ## puts it in a game/environment scene enumerating 197-274 roots, so anchoring
  ## on it made `splFindScreen` walk the WRONG scene and report "NOT found across
  ## 197 roots". The correct object is the `PreloaderUI::Update` `this`, which
  ## DOES land in scene -12. `gSplUpdatePreloader` captures exactly that,
  ## unconditionally, from the shared Update rider block (aowlhost.nim) -- so it
  ## is populated for beta users with liveInspector OFF. `gInspPreloader` is the
  ## same Update `this` but only the inspector writes it; kept as a fallback for
  ## the case where a rider slot has not yet been claimed. `gVerPreloader` is
  ## NO LONGER used as an anchor -- it points at the wrong scene by construction.
  result = nil
  if gSplUpdatePreloader != nil and duOk(gSplUpdatePreloader, 0x20'i32):
    return gSplUpdatePreloader
  if gInspPreloader != nil and duOk(gInspPreloader, 0x20'i32):
    return gInspPreloader

proc splFindScreen(): Il2CppPtr =
  ## The "Matchmaker Offline Raid Screen" transform. Reaches DontDestroyOnLoad
  ## via our own durable anchor (NOT the inspector), and gives EACH root the full
  ## node budget (reset per root) so the deep, wide "UI" root is not starved by
  ## whatever was walked before it. Sets `gSplLastWhy`/`gSplLastNodes` so the
  ## caller can log WHY, rate-limited -- a nil here used to be silent, which is
  ## what hid this bug (CLAUDE.md 6/9b).
  result = nil
  gSplLastNodes = 0
  let anchor = splAnchor()
  var roots: seq[Il2CppPtr] = @[]
  discard iSceneRoots(roots, false, anchor)
  if roots.len == 0:
    gSplLastWhy = (if anchor == nil:
      "iSceneRoots returned NO roots and this feature has no durable anchor " &
      "yet (gSplUpdatePreloader/gInspPreloader both null). This resolves once a " &
      "PreloaderUI::Update rider slot has been claimed and the menu is ticking " &
      "-- independent of liveInspector."
      else:
      "iSceneRoots returned NO roots even WITH a durable anchor -- the menu is " &
      "likely not up yet.")
    return
  let deadline = cNowMs() + SplWalkMs
  var i = 0
  while i < roots.len:
    var budget = SplNodeBudget                 # per-ROOT budget, reset each root
    let r = iToTransform(roots[i])
    if r != nil and duOk(r, 0x20'i32):
      let m = splFindByName(r, SplScreenName, SplFindDepth, budget, deadline)
      gSplLastNodes = gSplLastNodes + (SplNodeBudget - budget)
      if m != nil:
        gSplLastWhy = ""
        return m
    if cNowMs() > deadline: break
    i = i + 1
  gSplLastWhy = "screen \"" & SplScreenName & "\" NOT found across " &
    $roots.len & " root(s) with a per-root budget of " & $SplNodeBudget &
    " (" & $gSplLastNodes & " nodes visited, " & $int(SplWalkMs) &
    " ms slice). Normal when the offline-raid screen is not open; if it IS " &
    "open and this persists, raise the budget or the slice."

proc splIsCoopWarn(low: string): bool =
  ## True only for the co-op / Edge-of-Darkness "your progress is not saved/
  ## shared" warning. Requires "progress" AND a corroborating token, and hard-
  ## EXCLUDES the weapon warning ("...your weapon doesn't have the required
  ## vital part") so it can never hide the wrong node. `low` is already lowered.
  if not iContains(low, SplWarnStock): return false
  if iContains(low, SplWarnExclA) or iContains(low, SplWarnExclB): return false
  result = iContains(low, "not") or iContains(low, "co-op") or
           iContains(low, "coop") or iContains(low, "shared") or
           iContains(low, "saved") or iContains(low, "edge of darkness")

proc splWarnContainer(t: Il2CppPtr; nameOut: var string): Il2CppPtr =
  ## Climb up to `SplWarnUp` levels toward the warning-panel container and return
  ## its GameObject, mirroring the SoloModeCheckmarkBlocker climb. Falls back to
  ## the matched TMP node's OWN GameObject if no named panel is found -- so it
  ## always hides the matched warning, never a random sibling. Every hop guarded.
  result = nil
  nameOut = ""
  # default target: the matched node's own GameObject (hides at least the line).
  let selfGo = iGameObjectOf(t)
  if selfGo != nil and duOk(selfGo, 0x20'i32):
    result = selfGo
    nameOut = iObjName(t)
  var up = t
  var k = 0
  while k < SplWarnUp and up != nil and duOk(up, 0x20'i32):
    let low = iLower(iObjName(up))
    if iContains(low, "warn") or iContains(low, "progress") or
       iContains(low, "panel"):
      let go = iGameObjectOf(up)
      if go != nil and duOk(go, 0x20'i32):
        result = go
        nameOut = iObjName(up)
      break
    up = splParent(up)
    k = k + 1

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
        # Climb to the SoloModeCheckmarkBlocker and take BOTH its GameObject
        # (to hide) and its UpdatableToggle component (to force ON, fact #71).
        var up = t
        var k = 0
        while k < SplBlockerUp and up != nil:
          if iObjName(up) == SplBlockerName:
            let go = iGameObjectOf(up)
            if go != nil and duOk(go, 0x20'i32):
              gSplCheckGo = go
            let tog = splComponent(up, splTogTypeStr())
            if tog != nil and duOk(tog, cSwOffToggleIsOn() + 8'i32):
              gSplToggle = tog
            break
          up = splParent(up)
          k = k + 1
      # The co-op / EoD "progress is not saved/shared" warning is an INDEPENDENT
      # target (its text collides with none of the three above), so this is its
      # own `if`, not part of the elif chain. Matched by content, weapon warning
      # excluded, container taken by climbing like the checkbox blocker.
      if gSplWarnGo == nil and splIsCoopWarn(low):
        var wn = ""
        let wg = splWarnContainer(t, wn)
        if wg != nil:
          gSplWarnGo = wg
          gSplWarnText = low
          gSplWarnName = wn
          gSplWarnMatched = true
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

  # Practice toggle -- FORCE to the wanted value, THEN hide. Order matters: the
  # notifying `set_isOn` must run while the GameObject is ACTIVE so the game's
  # onValueChanged listener (which selects the mode) fires. The box is hidden
  # ONLY once its m_IsOn has read back as the wanted value -- a hidden box with
  # an unknown value is exactly the failure this guards against.
  var forceState = 2   # 2 INCONCLUSIVE/REFUSED, 1 PASS (readback == wanted), 0 FAIL
  var hideState  = 2   # 2 INCONCLUSIVE/REFUSED, 1 PASS (activeInHierarchy==false), 0 acting
  let wantOn = (if SplForceIsOn: 1'i32 else: 0'i32)
  if gSplToggle != nil and duOk(gSplToggle, cSwOffToggleIsOn() + 8'i32) and
     gSplCheckGo != nil and duOk(gSplCheckGo, 0x20'i32) and iUnityAlive(gSplCheckGo):
    if nuActiveInHierarchy(gSplCheckGo):
      let fr = splForceToggle()             # forces + re-asserts + reads back
      if fr == 1:
        discard nuSetActive(gSplCheckGo, false)   # PASS -> now hide
      # fr == 0 (readback mismatch) or -1 (set_isOn unverified): do NOT hide.
    # Assert the FINISHED STATE, whoever acted and whenever.
    if not gSplForceRefused:
      forceState = (if cSwReadU8(gSplToggle, cSwOffToggleIsOn()) == wantOn: 1 else: 0)
    if gSplForceRefused or forceState == 0:
      hideState = 2                          # box left VISIBLE on any doubt
    elif not nuActiveInHierarchy(gSplCheckGo):
      hideState = 1
    else:
      hideState = 0

  # Co-op / Edge-of-Darkness "progress is not saved/shared" warning -- hide the
  # whole container (content-discovery + SetActive, no write into game code).
  # Assert the FINISHED STATE (activeInHierarchy == false), not that SetActive
  # was called. If the screen resolved but nothing matched the co-op/progress
  # predicate, REFUSE -- never hide a random node.
  var warnState = 3   # 3 not-found-yet, 2 REFUSED, 1 PASS (hidden), 0 acting/FAIL
  if gSplWarnGo != nil and duOk(gSplWarnGo, 0x20'i32) and iUnityAlive(gSplWarnGo):
    if nuActiveInHierarchy(gSplWarnGo):
      discard nuSetActive(gSplWarnGo, false)
    warnState = (if not nuActiveInHierarchy(gSplWarnGo): 1 else: 0)
  elif not gSplWarnMatched:
    gSplWarnRefused = true
    warnState = 2

  # Finished-state summary, once, when the heading has taken. The two lines the
  # coordinator asked for are logged explicitly, plus a combined per-target line.
  if headOk and not gSplSummaryLogged:
    let onWord = (if SplForceIsOn: "true" else: "false")
    let forceStr = (case forceState
      of 1: "PASS"
      of 0: "FAIL"
      else: "INCONCLUSIVE")
    okLog "singleplayer: forced isOn=" & onWord & " (readback " & forceStr &
          "). NOTE: whether checked==offline is UNCONFIRMED on this build; if a " &
          "live raid comes up ONLINE after this, the fix is to force the " &
          "opposite value (flip SplForceIsOn), not to re-derive the plumbing."
    let hideStr = (case hideState
      of 1: "PASS"
      of 0: "acting (SetActive(false) issued; confirm next tick)"
      else: (if gSplForceRefused:
               "REFUSED (set_isOn did not verify -- box left VISIBLE)"
             elif forceState == 0:
               "REFUSED (isOn readback did not match -- box left VISIBLE)"
             else: "INCONCLUSIVE (no practice checkbox found)"))
    okLog "singleplayer: hide: " & hideStr
    let warnStr = (case warnState
      of 1: "PASS"
      of 0: "FAIL (SetActive(false) issued but node still activeInHierarchy)"
      of 2: "REFUSED (no co-op/progress warning matched on this screen -- " &
            "nothing hidden; the weapon \"vital part\" warning is excluded)"
      else: "INCONCLUSIVE (warning not present yet)")
    let warnEvidence = (if gSplWarnMatched:
      " (matched text contains \"progress\"+co-op token, weapon warning " &
      "excluded; hid container \"" & gSplWarnName & "\")"
      else: "")
    okLog "singleplayer: coop-warning hidden " & warnStr & warnEvidence
    let descStr = (case descState
      of 1: "PASS"
      of 0: "FAIL (re-applying)"
      else: "INCONCLUSIVE (no description TMP found)")
    okLog "singleplayer rebrand: FINISHED-STATE readback -- heading: PASS " &
          "(the rendered TMP no longer reads \"PRACTICE GAME MODE\"); " &
          "description: " & descStr & "; forced isOn: " & forceStr &
          "; hide: " & hideStr & "; coop-warning: " & warnStr &
          ". This asserts the live tree, not that a setter ran."
    gSplSummaryLogged = true
    if descState != 0 and forceState == 1 and hideState == 1 and warnState != 0:
      gSplConfirmed = true

# ---------------------------------------------------------------------------
# The guarded body + the drain rider.
# ---------------------------------------------------------------------------
var gSplLastWhyLogged = ""
proc splDiag(reason: string) =
  ## Rate-limited "why discovery has not fired" line. Logs when the reason
  ## CHANGES, or at most once per ~30 hunt passes (~30 s), so a failure path can
  ## no longer decline silently (CLAUDE.md 6) without spamming the log.
  if reason.len == 0: return
  inc gSplDiagPasses
  if reason != gSplLastWhyLogged or gSplDiagPasses >= 30:
    gSplDiagPasses = 0
    gSplLastWhyLogged = reason
    warn "singleplayer rebrand: not resolved -- " & reason

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
    gSplToggle = nil
    gSplForceRefused = false
    gSplWarnGo = nil; gSplWarnText = ""; gSplWarnName = ""
    gSplWarnMatched = false; gSplWarnRefused = false
    gSplConfirmed = false
    gSplSummaryLogged = false

  if not gSplResolved:
    let screen = splFindScreen()
    if screen == nil:
      splDiag(gSplLastWhy)                # announce WHY, rate-limited (was silent)
      return
    var budget = SplNodeBudget
    let deadline = cNowMs() + SplWalkMs
    splScanNode(screen, SplScanDepth, budget, deadline)
    if gSplHeadTmp == nil:
      splDiag("screen \"" & SplScreenName & "\" WAS found, but its heading TMP " &
        "(text containing \"" & SplHeadStock & "\") was not read within depth " &
        $SplScanDepth & "/" & $int(SplWalkMs) & " ms -- the screen may still be " &
        "building; retrying.")
      return                              # screen present but heading not read yet
    gSplResolved = true
    okLog "singleplayer rebrand: resolved on \"" & SplScreenName &
          "\" -- heading TMP " & (if gSplHeadTmp != nil: "found" else: "MISSING") &
          ", description TMP " & (if gSplDescTmp != nil: "found" else: "not found") &
          ", checkbox GameObject " &
          (if gSplCheckGo != nil: "found" else: "NOT found") &
          ", UpdatableToggle component " &
          (if gSplToggle != nil: "found" else: "NOT found") &
          ", co-op/progress warning " &
          (if gSplWarnGo != nil: "found (\"" & gSplWarnName & "\")"
           else: "not found") &
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
