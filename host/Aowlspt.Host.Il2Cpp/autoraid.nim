# autoraid.nim -- HOST-NATIVE AUTO-RAID.
#
# On launch, drive the main menu into an OFFLINE raid on a chosen map, natively
# on the Unity main thread, with NO Python and NO live inspector. This is the
# shipped-beta path: `liveInspector` is OFF in the beta, so the Python driver
# `tools/enterraid.py` (which navigates through the inspector file channel)
# cannot run there, and it is also flakier than this -- it drops batches at the
# busy menu. This feature reuses the SAME in-host UI primitives the inspector
# engine already carries (`inspect.nim`): find-by-GameObject-name, the
# activeInHierarchy check, and the DefaultUIButton OnClick(+0x120) press path.
#
# HOW IT IS WIRED -- no new detour
# --------------------------------
# It rides the EXISTING `EFT.TarkovApplication::Update` drain (the same slot the
# singleplayer-rebrand and cursor-free features alias, `gDrainSlot`), by adding
# `autoRaidDrainTick()` to that slot's dispatch in `patchFired`. That drain ticks
# for the WHOLE session -- crucially the matchmaker screens are up before the
# main menu's `PreloaderUI` can be assumed, so a `PreloaderUI::Update` rider
# would be the wrong anchor (this is exactly why `splRebrand` rides this drain,
# not that one). Two detours on one function have the second overwrite the
# first's trampoline; there is only ever ONE, and this adds a rider, not a hook.
#
# THE STATE MACHINE (self-pacing: act only when the expected control is VISIBLE)
# -----------------------------------------------------------------------------
# The measured navigation (facts #240/#263/#265 and tools/enterraid.py):
#
#   ArWaitMenu -> ArPressPlay -> ArNext1 -> ArSelectMap -> ArNext2
#              -> ArNext3 -> ArNext4 -> ArReady -> ArDone
#
#   ArWaitMenu   wait until a PlayButton is activeInHierarchy under MenuScreen
#                (scoped to MenuScreen so the RewardInfo popup's second
#                PlayButton is never mistaken for PLAY, fact #240)
#   ArPressPlay  press that PlayButton (DefaultUIButton OnClick +0x120)
#   ArNext1      press the active NextButton  -> Matchmaker Location Selection
#   ArSelectMap  the location tiles are AnimatedToggles whose descendant "Label"
#                TMP holds the map name; find the one == autoRaidMap and press it
#   ArNext2      press NextButton              -> Matchmaker Offline Raid Screen
#   ArNext3      press NextButton              -> Insurance
#   ArNext4      press NextButton              -> AcceptScreen
#   ArReady      press NextButton (the AcceptScreen READY is ITSELF a NextButton,
#                verified live) -> Final Countdown -> raid loads
#   ArDone       STOP. Once READY is pressed the raid scene is loading; touching
#                the UI during the load errors matchmaking (fact #261), so this
#                state makes NO call into the game ever again.
#
# Practice/offline is NOT ticked here: `singleplayerRebrand` already forces the
# practice toggle host-side (fact #263), which is what keeps the raid routing to
# the emulated backend. This feature only advances the screens; run it WITH
# `singleplayerRebrand` on.
#
# SAFETY, per il2cpp-host discipline
# ----------------------------------
#   * ONE `aowl_p_p_seh` around the whole tick body (`cArTickGuarded`), never
#     nested -- it runs inside no other guard here, and the primitives it calls
#     open none of their own on this path.
#   * Every pointer hop is `duOk`/`iUnityAlive`-checked; nothing is blind-called.
#     The press reads and validates the UnityEvent slot before UnityEvent::Invoke.
#   * Every walk is bounded by a node budget AND an 18ms in-walk wall-clock slice.
#   * Flag-gated `uxAutoRaid`, DEFAULT OFF; map from `autoRaidMap` (default Woods).
#   * Self-disables after `ArMaxFaults` guarded-body faults, and self-disables
#     with a logged reason if any step's control never appears within its bound
#     (it never spins forever).
#   * No per-frame managed allocation on the idle path: the only managed strings
#     it allocates are GetComponent type names, inside GetComponent's own path,
#     throttled to at most one attempt per tick and only while actively stepping.

# ---- bounds ----
const
  ArWarmupMs      = 5000'u64    ## the menu is not up before this; do not walk.
  ArTickFrames    = 30          ## ~0.5 s at 60 fps between attempts.
  ArMinActionMs   = 700'u64     ## min gap between two presses (screen settle).
  ArReuseMs       = 2500'u64    ## if the ONLY active NextButton is the one we just
                                ## pressed and it has persisted this long, the flow
                                ## reuses one NextButton object across screens -- press
                                ## it again rather than waiting forever.
  ArMenuWaitMs    = 180000'u64  ## the menu can take >60 s on a cold launch.
  ArStepTimeoutMs = 45000'u64   ## per non-menu step: if the control never appears.
  ArWalkMs        = 18'u64      ## per-walk wall-clock slice, checked INSIDE the walk.
  ArNodeBudget    = 24000       ## per-walk node cap (the offline screens sit deep).
  ArFanout        = 256         ## children examined per level.
  ArFindDepth     = 12          ## descent depth.
  ArMapDepth      = 8           ## depth to find a "Label" under a map toggle.
  ArMaxFaults     = 3

# ---- step ids ----
const
  ArWaitMenu  = 0
  ArPressPlay = 1
  ArNext1     = 2   ## -> Matchmaker Location Selection
  ArSelectMap = 3
  ArNext2     = 4   ## -> Matchmaker Offline Raid Screen
  ArNext3     = 5   ## -> Insurance
  ArNext4     = 6   ## -> AcceptScreen
  ArReady     = 7   ## -> Final Countdown (the READY is itself a NextButton)
  ArDone      = 8
  ArFailed    = 9

# ---- the guarded-body thunk (ONE aowl_p_p_seh, never nested) ----
{.emit: """
extern void* aowl_ar_tick_body(void* a);
static void* aowl_ar_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_ar_tick_body, a);
}
""".}
proc cArTickGuarded(a: Il2CppPtr): Il2CppPtr {.importc: "aowl_ar_tick_guarded", nodecl.}

# ---- state (gArOn / gArMap are set in the flag-reading pass in aowlhost.nim) ----
var gArOn = false                  ## the `uxAutoRaid` flag; DEFAULT OFF
var gArOff = false                 ## self-disabled after faults / a timed-out step
var gArFaults = 0
var gArMap = "Woods"               ## `autoRaidMap`
var gArStep = ArWaitMenu
var gArT0 = 0'u64                  ## first-tick time (for warm-up)
var gArFrames = 0
var gArStepT0 = 0'u64             ## when the current step began (per-step timeout)
var gArLastPressed: Il2CppPtr = nil ## last NextButton pressed (screen-transition dedup)
var gArLastActionMs = 0'u64        ## time of the last successful press
var gArStarted = false

proc arStepName(s: int): string =
  case s
  of ArWaitMenu:  "WAIT-MENU"
  of ArPressPlay: "PLAY"
  of ArNext1:     "NEXT->location"
  of ArSelectMap: "SELECT-MAP"
  of ArNext2:     "NEXT->offline-raid"
  of ArNext3:     "NEXT->insurance"
  of ArNext4:     "NEXT->accept"
  of ArReady:     "READY"
  of ArDone:      "DONE"
  else:           "FAILED"

proc arGoto(s: int) =
  gArStep = s
  gArStepT0 = cNowMs()

# ---------------------------------------------------------------------------
# Discovery: bounded, time-sliced. BREADTH-BEFORE-DEPTH, exactly like
# splrebrand's proven `splFindByName`: at each node, name-check ALL direct
# children before recursing into any subtree. A container like MenuScreen is a
# DIRECT child of a wide root (Common UI has many sibling screens); a pure DFS
# burns the whole 18 ms slice descending the first sibling's subtree before it
# ever reaches MenuScreen -- which is exactly how the first cut sat at WAIT-MENU
# for 180 s and self-disabled. `arWalkActive` additionally requires the match be
# activeInHierarchy (so an INACTIVE NextButton on a screen we are not on can
# never be pressed, fact #72) and can EXCLUDE one pointer (the button we just
# pressed).
# ---------------------------------------------------------------------------
proc arWalkActive(t: Il2CppPtr; name: string; depth: int; budget: var int;
                  deadline: uint64; exclude: Il2CppPtr): Il2CppPtr =
  result = nil
  if t == nil or depth < 0 or budget <= 0 or not duOk(t, 0x20'i32): return
  budget = budget - 1
  if (budget and 31) == 0 and cNowMs() > deadline:
    budget = 0                              # poison the budget: unwinds all levels
    return
  if t != exclude and iObjName(t) == name:
    let a = iActiveInHierarchy(t)
    if a[0] and a[1]:
      return t
    # matched by name but inactive (or state unknown): keep searching.
  if depth == 0: return
  var n = 0
  if not iChildCount(t, n): return
  # Pass 1 -- breadth: name+active check every direct child (no descent).
  var i = 0
  while i < n and i < ArFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      budget = budget - 1
      if (budget and 31) == 0 and cNowMs() > deadline:
        budget = 0
        return
      if c != exclude and iObjName(c) == name:
        let a = iActiveInHierarchy(c)
        if a[0] and a[1]:
          return c
    i = i + 1
  # Pass 2 -- depth: recurse only after the whole level missed.
  i = 0
  while i < n and i < ArFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil:
      result = arWalkActive(c, name, depth - 1, budget, deadline, exclude)
      if result != nil: return
    i = i + 1

proc arWalkAny(t: Il2CppPtr; name: string; depth: int; budget: var int;
               deadline: uint64): Il2CppPtr =
  ## Like `arWalkActive` but returns the first name match regardless of active
  ## state -- for containers (MenuScreen) whose own active flag we do not gate
  ## on. Breadth-before-depth, same reason.
  result = nil
  if t == nil or depth < 0 or budget <= 0 or not duOk(t, 0x20'i32): return
  budget = budget - 1
  if (budget and 31) == 0 and cNowMs() > deadline:
    budget = 0
    return
  if iObjName(t) == name:
    return t
  if depth == 0: return
  var n = 0
  if not iChildCount(t, n): return
  var i = 0
  while i < n and i < ArFanout and budget > 0:      # pass 1 -- breadth
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      budget = budget - 1
      if (budget and 31) == 0 and cNowMs() > deadline:
        budget = 0
        return
      if iObjName(c) == name:
        return c
    i = i + 1
  i = 0
  while i < n and i < ArFanout and budget > 0:      # pass 2 -- depth
    let c = iChildAt(t, i)
    if c != nil:
      result = arWalkAny(c, name, depth - 1, budget, deadline)
      if result != nil: return
    i = i + 1

proc arCollect(t: Il2CppPtr; name: string; depth: int; budget: var int;
               deadline: uint64; into: var seq[Il2CppPtr]; cap: int) =
  ## Collect up to `cap` nodes named `name` under `t` (active or not) -- for the
  ## map tiles, which we must scan by their child Label text.
  if t == nil or depth < 0 or budget <= 0 or into.len >= cap or
     not duOk(t, 0x20'i32): return
  budget = budget - 1
  if (budget and 31) == 0 and cNowMs() > deadline:
    budget = 0
    return
  if iObjName(t) == name:
    into.add t
    if into.len >= cap: return
  if depth == 0: return
  var n = 0
  if not iChildCount(t, n): return
  var i = 0
  while i < n and i < ArFanout and budget > 0 and into.len < cap:
    let c = iChildAt(t, i)
    if c != nil:
      arCollect(c, name, depth - 1, budget, deadline, into, cap)
    i = i + 1

# ---------------------------------------------------------------------------
# Scene-root enumeration -- reuse inspect.nim's `iSceneRoots` (the same path
# `splFindScreen` uses successfully), which asks the anchor GameObject for its
# scene via GameObject::get_scene_Injected and enumerates ALL its roots via
# Scene::GetRootGameObjects. The first cut scoped the search to the anchor
# (Preloader UI) subtree, which holds AlphaLabel but NOT PlayButton -- PlayButton
# lives under a DIFFERENT root (Common UI -> MenuScreen). So every step searches
# a PREFERRED root by name, then FALLS BACK across every enumerated root, so a
# wrong scope can never silently starve the search.
# ---------------------------------------------------------------------------
var gArRootsLogged = false

proc arEnumRoots(into: var seq[Il2CppPtr]) =
  let anchor = splAnchor()
  discard iSceneRoots(into, false, anchor)
  if not gArRootsLogged and into.len > 0:
    gArRootsLogged = true
    var names = ""
    var i = 0
    while i < into.len and names.len < 600:
      let r = iToTransform(into[i])
      if r != nil and duOk(r, 0x20'i32):
        names = names & "[" & iObjName(r) & "]"
      i = i + 1
    okLog "autoRaid: enumerated " & $into.len &
          " DontDestroyOnLoad root(s): " & names

proc arNamedRoot(roots: seq[Il2CppPtr]; name: string): Il2CppPtr =
  result = nil
  var i = 0
  while i < roots.len:
    let r = iToTransform(roots[i])
    if r != nil and duOk(r, 0x20'i32) and iObjName(r) == name:
      return r
    i = i + 1

proc arPlayUnder(root: Il2CppPtr; deadline: uint64): Il2CppPtr =
  ## MenuScreen under `root`, then the ACTIVE PlayButton under MenuScreen
  ## (scoping to MenuScreen skips the RewardInfo popup's second PlayButton).
  result = nil
  if root == nil: return
  var b = ArNodeBudget
  let ms = arWalkAny(root, "MenuScreen", ArFindDepth, b, deadline)
  if ms == nil: return
  var b2 = ArNodeBudget
  result = arWalkActive(ms, "PlayButton", ArFindDepth, b2, deadline, nil)

proc arFindPlay(): Il2CppPtr =
  ## The active PlayButton under Common UI -> MenuScreen, with a fallback across
  ## every enumerated root. One shared 18 ms deadline bounds the whole search.
  result = nil
  var roots: seq[Il2CppPtr] = @[]
  arEnumRoots(roots)
  if roots.len == 0: return
  let deadline = cNowMs() + ArWalkMs
  let cu = arNamedRoot(roots, "Common UI")
  if cu != nil:
    result = arPlayUnder(cu, deadline)
    if result != nil: return
  var i = 0
  while i < roots.len and cNowMs() <= deadline:
    let r = iToTransform(roots[i])
    if r != nil and r != cu and duOk(r, 0x20'i32):
      result = arPlayUnder(r, deadline)
      if result != nil: return
    i = i + 1

proc arFindActiveAcross(prefName, ctrlName: string;
                        exclude: Il2CppPtr): Il2CppPtr =
  ## The active control named `ctrlName`, searched under the root named
  ## `prefName` FIRST (fact #237: the shared-name search must hit the intended
  ## root before Common UI eats the name), then across every enumerated root.
  ## One shared 18 ms deadline bounds the whole search.
  result = nil
  var roots: seq[Il2CppPtr] = @[]
  arEnumRoots(roots)
  if roots.len == 0: return
  let deadline = cNowMs() + ArWalkMs
  let pref = arNamedRoot(roots, prefName)
  if pref != nil:
    var b = ArNodeBudget
    result = arWalkActive(pref, ctrlName, ArFindDepth, b, deadline, exclude)
    if result != nil: return
  var i = 0
  while i < roots.len and cNowMs() <= deadline:
    let r = iToTransform(roots[i])
    if r != nil and r != pref and duOk(r, 0x20'i32):
      var b = ArNodeBudget
      result = arWalkActive(r, ctrlName, ArFindDepth, b, deadline, exclude)
      if result != nil: return
    i = i + 1

proc arFindNext(exclude: Il2CppPtr): Il2CppPtr =
  ## The active NextButton under "Menu UI" (fact #237), else any root, excluding
  ## `exclude` (the one we just pressed).
  result = arFindActiveAcross("Menu UI", "NextButton", exclude)

# ---------------------------------------------------------------------------
# The press: DefaultUIButton / AnimatedToggle OnClick(+0x120) via UnityEvent::
# Invoke -- exactly `inspect.nim`'s `iPressComponentAndFire`, but SILENT (host
# log, not the inspector output channel). Nothing is blind-called: the component
# is resolved, the UnityEvent slot read and validated, then Invoke.
# ---------------------------------------------------------------------------
proc arPress(node: Il2CppPtr; compType: string): bool =
  result = false
  if node == nil: return
  var comp: Il2CppPtr = nil
  var w = ""
  if not iVisComponent(node, compType, comp, w) or comp == nil: return
  let off = cNavOffOnClick()                  # 0x120 on this build
  if not duOk(comp, off + 8'i32) or not iUnityAlive(comp): return
  let ev = cReadPtrAt(comp, off)
  if ev == nil or iIsGameObject(ev) or iIsKnownKlass(cast[uint64](ev)): return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("UnityEvent::Invoke", fn, rva): return
  iMark("autoRaid: UnityEvent::Invoke", ev)
  discard cInspUP(fn, ev, nil)
  result = true

proc arTrim(s: string): string =
  ## Strip leading/trailing ASCII whitespace (map labels may be padded).
  var a = 0
  var b = s.len - 1
  while a <= b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r' or s[a] == '\n'):
    inc a
  while b >= a and (s[b] == ' ' or s[b] == '\t' or s[b] == '\r' or s[b] == '\n'):
    dec b
  result = ""
  var i = a
  while i <= b:
    result.add s[i]
    inc i

proc arSelectMapUnder(root: Il2CppPtr; want: string; deadline: uint64): bool =
  ## Scan the AnimatedToggles under `root` for one whose descendant "Label" TMP
  ## text == `want`, and press it. Bounded by the shared `deadline`.
  result = false
  if root == nil: return
  var toggles: seq[Il2CppPtr] = @[]
  var b = ArNodeBudget
  arCollect(root, "AnimatedToggle", ArFindDepth, b, deadline, toggles, 64)
  var i = 0
  while i < toggles.len and cNowMs() <= deadline:
    let tog = toggles[i]
    var labels: seq[Il2CppPtr] = @[]
    var b2 = ArNodeBudget
    arCollect(tog, "Label", ArMapDepth, b2, deadline, labels, 8)
    var j = 0
    while j < labels.len:
      let tmp = splTmpOf(labels[j])
      if tmp != nil:
        let got = iLower(arTrim(splTmpText(tmp)))
        if got.len > 0 and got == want:
          if arPress(tog, "AnimatedToggle"):
            return true
      j = j + 1
    i = i + 1

proc arSelectMap(): bool =
  ## Find the AnimatedToggle whose descendant "Label" TMP text == `gArMap`
  ## (case-insensitive), under "Menu UI" first (fact #237) then any root, and
  ## press it. Returns true only once a real match was pressed -- an unmatched
  ## map is a REFUSAL (stay on this step), never a silent advance.
  result = false
  var roots: seq[Il2CppPtr] = @[]
  arEnumRoots(roots)
  if roots.len == 0: return
  let deadline = cNowMs() + ArWalkMs
  let want = iLower(arTrim(gArMap))
  let pref = arNamedRoot(roots, "Menu UI")
  if pref != nil and arSelectMapUnder(pref, want, deadline):
    return true
  var i = 0
  while i < roots.len and cNowMs() <= deadline:
    let r = iToTransform(roots[i])
    if r != nil and r != pref and duOk(r, 0x20'i32):
      if arSelectMapUnder(r, want, deadline):
        return true
    i = i + 1

# ---------------------------------------------------------------------------
# The tick body -- everything that touches managed memory, under ONE guard.
# ---------------------------------------------------------------------------
proc arFail(why: string) =
  gArOff = true
  gArStep = ArFailed
  warn "autoRaid: " & why & " -- switching itself off for this session and " &
       "leaving the menu alone. This is a REFUSAL, not a success."

proc arTickBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_ar_tick_body", cdecl.} =
  ## Returns a non-nil sentinel on clean completion; the guard returns nil on a
  ## fault. At most ONE find+press per call, so the machine self-paces frame by
  ## frame instead of racing the menu.
  result = cast[Il2CppPtr](1)
  discard a
  if gArStep == ArDone or gArStep == ArFailed: return

  let now = cNowMs()
  # Enforce a settle gap after every press so a screen has time to transition.
  if gArLastActionMs != 0'u64 and now - gArLastActionMs < ArMinActionMs: return

  if gArStepT0 == 0'u64: gArStepT0 = now
  let stepTimeout = (if gArStep == ArWaitMenu: ArMenuWaitMs else: ArStepTimeoutMs)
  if now - gArStepT0 > stepTimeout:
    arFail("step " & arStepName(gArStep) & " never completed within " &
           $(int(stepTimeout div 1000'u64)) & " s (control never became visible)")
    return

  if gArStep == ArWaitMenu:
    let pb = arFindPlay()
    if pb != nil:
      okLog "autoRaid: menu ready (PlayButton visible under MenuScreen); " &
            "driving into an OFFLINE raid on map \"" & gArMap & "\"."
      arGoto(ArPressPlay)
    return

  if gArStep == ArPressPlay:
    let pb = arFindPlay()
    if pb != nil and arPress(pb, "DefaultUIButton"):
      okLog "autoRaid: pressed PLAY"
      gArLastPressed = nil
      gArLastActionMs = now
      arGoto(ArNext1)
    return

  if gArStep == ArNext1 or gArStep == ArNext2 or gArStep == ArNext3 or
     gArStep == ArNext4 or gArStep == ArReady:
    # One NextButton per screen. Prefer one that differs from the button we last
    # pressed; if the ONLY active NextButton is that same object and it has
    # persisted past ArReuseMs, the flow reuses one object across screens, so
    # press it rather than stall.
    var nb = arFindNext(gArLastPressed)
    if nb == nil and gArLastPressed != nil and
       now - gArLastActionMs > ArReuseMs:
      nb = arFindNext(nil)                     # allow the reused object
    if nb != nil and arPress(nb, "DefaultUIButton"):
      okLog "autoRaid: pressed " & arStepName(gArStep)
      gArLastPressed = nb
      gArLastActionMs = now
      if gArStep == ArNext1:   arGoto(ArSelectMap)
      elif gArStep == ArNext2: arGoto(ArNext3)
      elif gArStep == ArNext3: arGoto(ArNext4)
      elif gArStep == ArNext4: arGoto(ArReady)
      else:
        okLog "autoRaid: READY pressed -- the raid scene is loading. Going " &
              "hands-off; this feature will not touch the UI again this session."
        arGoto(ArDone)
    return

  if gArStep == ArSelectMap:
    if arSelectMap():
      okLog "autoRaid: selected map \"" & gArMap & "\""
      gArLastActionMs = now
      arGoto(ArNext2)
    return

proc autoRaidDrainTick() =
  ## Rides the `EFT.TarkovApplication::Update` drain (slot alias, no second
  ## detour). Cheap when idle: off, self-disabled, done, or inside the warm-up it
  ## is a handful of integer compares and makes NO call into the game.
  if not gArOn or gArOff: return
  if gArStep == ArDone: return
  if gArT0 == 0'u64: gArT0 = cNowMs()
  if cNowMs() - gArT0 < ArWarmupMs: return      # the menu cannot be up yet
  if not gArStarted:
    gArStarted = true
    gArStepT0 = cNowMs()
  inc gArFrames
  if gArFrames < ArTickFrames: return
  gArFrames = 0
  if cArTickGuarded(nil) == nil:
    inc gArFaults
    warn "autoRaid: the guarded tick body faulted (" & $gArFaults & " of " &
         $ArMaxFaults & ")"
    if gArFaults >= ArMaxFaults:
      arFail("too many faults")
