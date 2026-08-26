# modetext.nim -- the main menu's bottom-right GAME MODE label, host/mod-driven.
#
# `include`d into `aowlhost.nim` (NOT imported) so it shares that file's guarded
# raw primitives (`cIsReadable`, `cReadPtrAt`), its logging (`okLog`/`warn`/
# `info`), `hexOf`, `cRegsInt`, `cThreadId`, `attachDrain`, `newString`/`gRt`,
# and the VEH/SEH guard.
#
# WHAT IT DOES
# ------------
# A stock post-1.0 main menu reads "PVE ZONE" in the bottom-right corner. That
# string is `EFT.UI.PreloaderUI::_sessionModeText` (+0x128), one of three the
# corner label is composed from, and the game ships its own setter for it:
# `EFT.UI.PreloaderUI::SetGameModeText(string)` @ RVA 0x156cff0. The offsets and
# RVAs, and the disassembled proof that the setter writes 0x128, are in
# `abi/aowlspt_modetext.h`; all of it came from the decrypted metadata offline.
#
# So the host sets the text by CALLING THE REAL MANAGED SETTER at its static
# RVA. It does not write `TMP.m_text`, it does not poke a dirty byte, and it does
# not fight a `LocalizedText`. That is deliberate: the live Phase-2a settings
# relabel does write `m_text` + a dirty byte, the store demonstrably lands, and
# the screen still never changes. Calling the method the game itself calls is the
# way past that, and this file exists partly to prove it.
#
# WHERE THE STRING COMES FROM
# ---------------------------
# The backend, over the poll the host ALREADY makes. `takeModSet` reads
# `menuModeText` out of the same `/aowlspt/mods/client/<hostver>` document it
# already reads `inRaid` out of -- no new endpoint, no new thread, no new socket.
# The manager fills that field from (in order) any mod that pushed an override,
# else the logged-in profile's nickname. See `mods/manager/mgr/control.nim`.
#
# SAFETY
# ------
#   * flag-gated `uxMenuModeText`, default OFF;
#   * the detour target and the setter are both 16-byte prologue-verified
#     against committed executable memory before anything binds or is called
#     (`aowl_mtx_fn`), so on any other build this is a silent no-op;
#   * the whole per-tick body runs under ONE `aowl_p_p_seh` guard -- one, never
#     nested, because the guard is not re-entrant;
#   * every pointer hop is `cIsReadable`-guarded before it is dereferenced;
#   * self-disables after `ModeTextMaxFaults` guarded bodies fail;
#   * NO PER-FRAME ALLOCATION. `PreloaderUI::Update` runs every frame; a managed
#     string is allocated ONLY when the wanted text differs from the last text
#     this host applied. A previous crash on this host came from exactly the
#     mistake this rule exists to prevent.

# ---- the verified targets and thunks (abi/aowlspt_modetext.h) ----
proc cMtxFn(i: int32): Il2CppPtr {.importc: "aowl_mtx_fn", nodecl.}
proc cMtxName(i: int32): Il2CppPtr {.importc: "aowl_mtx_name", nodecl.}
proc cMtxRva(i: int32): uint32 {.importc: "aowl_mtx_rva", nodecl.}
proc cMtxOkCount(): int32 {.importc: "aowl_mtx_ok_count", nodecl.}
proc cMtxBadCount(): int32 {.importc: "aowl_mtx_bad_count", nodecl.}
proc cMtxOffModeText(): int32 {.importc: "aowl_mtx_off_mode_text", nodecl.}
proc cMtxOffCornerLabel(): int32 {.
  importc: "aowl_mtx_off_corner_label", nodecl.}
proc cMtxCallVPP(fn, self, a0: Il2CppPtr) {.
  importc: "aowl_mtx_call_v_pp", nodecl.}

const
  MtxTUpdate  = 0'i32
  MtxTSetText = 1'i32
  MtxTRefresh = 2'i32
  ModeTextMaxFaults = 3
    ## After this many guarded bodies have faulted, the feature switches itself
    ## off for the session. Three, not one: a single fault during a scene change
    ## is worth surviving, a pattern of them is not worth continuing through.

# `gModeTextOn` (the `uxMenuModeText` flag) and `gModeTextSlot` (the kind=13
# postfix slot on `PreloaderUI::Update`) are declared in `aowlhost.nim`, next to
# `gDebugUiSlot`. They have to be: `attachDrain` and `patchReturned` are defined
# above this file's include point and both name the slot, and while procs
# resolve across the whole module regardless of order, module-level `var`s do
# not. The rest of the state is local to this feature and lives here.
var gModeTextFaults = 0
var gModeTextOff = false          ## self-disabled
var gModeTextWant = ""            ## what the backend last asked for
var gModeTextApplied = ""         ## what this host last actually set
var gModeTextSelf: Il2CppPtr = nil
var gModeTextFires = 0
var gModeTextLogged = false       ## the one-shot identification log
var gModeTextApplies = 0
var gModeTextStarved = false      ## the one-shot "armed with no source" warning

const ModeTextStarveFrames = 3600
  ## Roughly a minute of menu at 60fps. If the detour has fired this many times
  ## and the backend has still never said what the label should read, the
  ## feature is armed and doing nothing -- which from the outside is
  ## indistinguishable from it being broken. It says so once, loudly, rather
  ## than leaving a silent no-op to be discovered by staring at the corner of
  ## the screen. This host's recurring failure mode is a feature that arms and
  ## then shows nothing, so being armed is not the same as working.

proc modeTextSetWanted(s: string) =
  ## Called from the host's own tick loop (NOT the Unity thread) when the
  ## backend poll produced a new value. It only records the wish; the Unity
  ## thread is the only thing that ever calls into managed code.
  ##
  ## An empty string means "the backend has nothing to say", and is a no-op
  ## rather than a request to blank the label -- a manager that is down, an
  ## older manager that omits the field, and a profile with no nickname must all
  ## leave the stock "PVE ZONE" exactly where it is.
  if not gModeTextOn or gModeTextOff or s.len == 0 or s == gModeTextWant:
    return
  gModeTextWant = s
  info "menu mode text: the backend wants the corner label to read \"" & s &
       "\"; it will be applied on the next PreloaderUI frame"

## Carries the string for the guarded allocation, for the same reason
## `gBrandText` does: `aowl_p_p_seh` passes exactly one pointer.
var gModeTextAlloc = ""

proc modeTextNewString(a: Il2CppPtr): Il2CppPtr =
  ## Allocates the managed `System.String` for `gModeTextAlloc`.
  ##
  ## This is NOT separately SEH-guarded, and that is deliberate: it is only ever
  ## called from `modeTextTickBody`, which already runs under one
  ## `aowl_p_p_seh`, and that guard is NOT re-entrant -- a nested one shares the
  ## single thread-local `jmp_buf`, disarms the outer guard when it returns, and
  ## leaves the rest of the body running unprotected. `debugui.nim`'s
  ## `duNewStringImpl` carries the same comment for the same reason. A fault in
  ## `il2cpp_string_new` is therefore caught by the OUTER guard, which is the
  ## correct place for it. `a` is unused.
  result = newString(gRt, gModeTextAlloc)

{.emit: """
extern void* aowl_mtx_tick_body(void* a);
static void* aowl_mtx_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_mtx_tick_body, a);
}
""".}
proc cMtxTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mtx_tick_guarded", nodecl.}

# ---------------------------------------------------------------------------
# RETARGET (measured today, fact #116): `PreloaderUI::SetGameModeText` writes
# `_sessionModeText`(+0x128) and that field genuinely updates -- but it never
# reaches the screen. The label a player actually sees is TWO TMPs under
# Common UI: `ChangeGameModeButton/Available/MainTextContainer/{MainText,
# MainTextHover}`. `aowl ui findtext "ZONE" --root "Common UI" --all` found
# exactly those two, walk COMPLETE; the same search under Preloader UI and
# Menu UI returned zero hits, walk COMPLETE -- the label is not in
# PreloaderUI's subtree at all, which is why the old call could succeed and
# still show nothing. So this now WALKS to the real nodes from a verified
# scene root (never a hardcoded pointer -- those are per-session) and writes
# BOTH TMPs, because MainTextHover is the hover state and a stale hover copy
# changes the label under the cursor (fact #88, the same bug that hit the
# MODS row captions).
# ---------------------------------------------------------------------------

var gMtxTmpMain: Il2CppPtr = nil    ## resolved once, revalidated, never re-walked
var gMtxLocMain: Il2CppPtr = nil    ## optional LocalizedText sibling; nil is fine
var gMtxTmpHover: Il2CppPtr = nil
var gMtxLocHover: Il2CppPtr = nil
var gMtxResolved = false
var gMtxResolvePasses = 0
var gMtxResolveWhy = ""
var gMtxResolveSaidWalk = false
var gMtxResolveGaveUp = false

# ---------------------------------------------------------------------------
# THE THROTTLE. This block is the fix for a MEASURED main-thread stall, and the
# comment it replaced ("retried on a throttle") was simply false -- there was no
# throttle at all. Until it resolved, `modeTextTickBody` ran
# `modsFindNamed(root, "ChangeGameModeButton", 8)` over all 11 scene roots EVERY
# FRAME, and `modsFindNamed` has no node budget and no time slice: 32 children
# per level, 8 levels, allocating a managed name string per node visited.
#
# Measured on the live client: first fire 0:00:14.172, resolved 0:00:46.485 --
# 32.3 seconds across <=30 passes, i.e. >=1.08 SECONDS PER FRAME on the Unity
# main thread. It stalled the process so hard that a 302-byte HTTP response from
# our own backend took 1.2 s, and the user reported the game as "SUPER DUPER
# laggy" during load. `uxMenuModeText` has been OFF on the live install since.
#
# The shape below is the one a nearby agent arrived at for exactly this class of
# bug in the version brand (`modstab.nim`, `VerBrand*`), and it is deliberately
# copied rather than reinvented:
#   * a HUNT cadence while unresolved and a STEADY cadence once resolved;
#   * a wall-clock SLICE per pass, with a logged BACK-OFF to the steady cadence
#     when a pass overruns -- the hunt gives up its speed, not the hunt;
#   * a NODE BUDGET inside the walk itself, so one pass is bounded even if the
#     slice is never checked;
#   * a give-up in WALL CLOCK, not in attempts. An attempt budget and a fast
#     poll are incompatible: 30 attempts at one every 2 frames is under a
#     second, which is long before the main menu exists, so the old
#     `MtxResolveMaxPasses = 30` would have given up before its target could
#     possibly be there. "Not reachable yet" is not a failure.
const MtxHuntFrames = 4
  ## While unresolved. Not 1: even a budgeted walk allocates a name string per
  ## node, and nothing that allocates belongs on every frame of the Unity thread.
const MtxSteadyFrames = 120
  ## Once resolved: a revalidate-and-recheck, not a search.
const MtxSliceMs = 12'u64
  ## One WHOLE resolve pass may cost this much -- the root enumeration (which
  ## allocates) plus the descent. Deliberately ABOVE `MtxWalkMs`: the in-walk
  ## deadline is what keeps a pass short, and this outer figure exists to catch
  ## a pass that overran for some reason the inner bound could not see. Setting
  ## it below the inner bound would make the back-off fire on every healthy
  ## pass, which is a check that cannot fail in the other direction.
const MtxHuntMs = 300_000'u64
  ## Five minutes of wall clock to find the button, then a loud give-up. The
  ## menu can legitimately be many seconds away on a cold load.
const MtxNodeBudget = 1200
  ## Nodes one resolve pass may visit across ALL roots combined.
  ##
  ## SIZED FROM THE REAL TREE, not from a round number. The measured pass A
  ## shape is: ~13 roots, each costing one `iObjName`, then a depth-3 descent
  ## under exactly ONE of them at a fan-out of 24 -- a worst case of
  ## 13 + 24 + 24*24 = 613 nodes, so 1200 is roughly 2x headroom and pass B has
  ## the remainder. The old 4000 was BOTH too small and too large: too small
  ## because a depth-8 fan-out-32 sweep exhausted it before reaching root 11 of
  ## 11 (MEASURED on the live client), and too large because 4000 nodes at the
  ## measured per-node cost is 750 ms on the Unity main thread. Visiting fewer
  ## nodes is the fix; a bigger budget would only have made the stall longer.
const MtxWalkMs = 6'u64
  ## The IN-WALK deadline, checked every 32 nodes inside the recursion. This is
  ## the bound whose absence produced the 750 ms pass: `MtxSliceMs` was only
  ## compared AFTER the walk had already returned, so it could report a stall
  ## but never prevent one. A budget that is only checked at the end is a
  ## report, not a bound.
const MtxFanout = 24
  ## Children examined per level. 24, not 32: `Common UI`'s interesting
  ## children are few, and every extra slot is a full `iObjName` -- a by-name
  ## target resolve plus a managed string allocation, per node.
const MtxDescendDepth = 3
  ## Fact #116 records the path as `Common UI` -> `ChangeGameModeButton`, so
  ## depth 3 is already two levels of slack for an inserted wrapper. Depth 8 is
  ## what made the old sweep unaffordable, and it never once helped.
const MtxRootCap = 32
  ## Roots examined. The live client reported 11 and then 13.

var gMtxLastNodes = 0
  ## Nodes the last pass actually visited. Logged, because "it was slow" is an
  ## impression and "613 nodes in 40 ms" is a measurement the next session can
  ## act on without re-deriving anything.
var gMtxLastVia = ""

var gMtxFrames = 0
var gMtxSlow = false              ## a pass overran the slice; one-shot log
var gMtxT0: uint64 = 0            ## first tick from the rider chain
var gMtxTResolved: uint64 = 0
var gMtxNotReady = 0              ## passes where the button was legitimately absent

# ---------------------------------------------------------------------------
# REMOVE THE BUTTON ENTIRELY (`uxHideModeButton`, default OFF).
#
# The bottom-right "PVE ZONE" control is `Common UI -> ChangeGameModeButton`
# (fact #116 -- it is NOT `PreloaderUI._sessionModeText`, which something once
# reported success against while the screen never changed). Since the host now
# skips the character/mode selection screen on launch, this button is the last
# route back into the mode UI, and the user does not want to see it.
#
# The mechanism is deliberately the SMALLEST one that works, and it is not new:
# `uxHideSeasons` removes `Common UI/MenuScreen/SeasonsButton` with a single
# `GameObject::SetActive(false)` and that is human-confirmed on screen (fact
# #81). This is the same primitive on a different object. It only ever sets
# active=FALSE, never true, so the game can rebuild the menu and we hide it
# again, but nothing this host does can put a hidden control back.
#
# MUTUALLY EXCLUSIVE WITH `uxMenuModeText`, ENFORCED RATHER THAN LEFT TO LUCK.
# That feature exists to rewrite the text OF THIS BUTTON to the character name.
# If the button is gone there is nothing to rewrite, and doing it anyway means
# two resolve walks and two writes per menu, on the Unity main thread, to paint
# an object nobody can see. So `uxHideModeButton` WINS and forces the other off
# at flag-read time, loudly. Making the flags fight silently is how this
# codebase produces its worst outcomes.
var gModeHideOn = false
var gMtxHideGo: Il2CppPtr = nil   ## the ChangeGameModeButton GameObject, cached
var gMtxHidden = 0
var gMtxSaidHidden = false

proc mtxAnchor(): Il2CppPtr =
  ## A LIVE `PreloaderUI`, from THIS FEATURE'S OWN capture first.
  ##
  ## The version brand's measured root cause is the trap being avoided here: it
  ## read `gInspPreloader`, which is written in exactly ONE place --
  ## `inspectFired`, the LIVE INSPECTOR's rider -- so with `liveInspector` off
  ## it had no anchor at any point in a run and never could have had one. A
  ## feature must not depend on another feature's flag to reach its own target.
  ##
  ## So, in order: `gModeTextSelf`, which `modeTextUpdateFired` sets from RCX on
  ## every one of OUR rider ticks and which therefore exists whenever this code
  ## can run at all; then `gVerPreloader`, captured by the `PreloaderUI::Awake`
  ## postfix at ~1.3 s (a bonus, and gated behind another flag, so never the
  ## only source).
  ##
  ## `gInspPreloader` is deliberately NOT consulted, and not merely as a matter
  ## of taste: it is declared in `inspect.nim`, which is `include`d AFTER this
  ## file, so a module-level var from it is not even in scope here. That the
  ## language stops it is convenient; the reason not to want it is the measured
  ## one above.
  result = nil
  if gModeTextSelf != nil and duOk(gModeTextSelf, 0x20'i32):
    return gModeTextSelf
  if gVerPreloader != nil and duOk(gVerPreloader, 0x20'i32):
    return gVerPreloader

proc mtxAnchorRoots(into: var seq[Il2CppPtr]): bool =
  ## Every root Transform we can reach, plus OUR OWN anchor's hierarchy root as
  ## an independent seed.
  ##
  ## `iSceneRoots` is used for the cross-root list because `ChangeGameModeButton`
  ## lives under `Common UI`, a DIFFERENT root from the `Preloader UI` our anchor
  ## sits on -- and `Transform::get_root` cannot cross roots, so a pure
  ## climb-and-descend (which is what fixed the version brand, whose target IS on
  ## the PreloaderUI hierarchy) cannot reach this one. That difference is why the
  ## two features do not share a resolver.
  ##
  ## KNOWN CROSS-FEATURE DEPENDENCY, NAMED RATHER THAN INHERITED SILENTLY:
  ## `iSceneRoots` reaches the `DontDestroyOnLoad` scene -- the only scene the
  ## live UI is actually in, since `sceneCount`/`GetSceneAt` exclude it BY
  ## DESIGN -- via `iAnchorSceneHandle`, which reads `gInspPreloader`. That
  ## global is written in exactly ONE place, `inspectFired`, the LIVE
  ## INSPECTOR's rider. So with `liveInspector` off, the root list can come back
  ## EMPTY and this feature cannot resolve. That is precisely the disease the
  ## version brand was just cured of, and it is reported here as a specific,
  ## actionable sentence instead of an empty list -- the proper fix is to
  ## generalise `iAnchorSceneHandle` to take an anchor argument, which is in
  ## `inspect.nim` and not this feature's file to change.
  ##
  ## Our own anchor's hierarchy root is appended regardless, so pass B has
  ## something to search even in that degraded case.
  result = false
  let n = iSceneRoots(into, false)
  let anchor = mtxAnchor()
  if anchor != nil:
    let at = iToTransform(anchor)
    if at != nil and duOk(at, 0x20'i32):
      var top = iHierRoot(at)
      if top == nil or not duOk(top, 0x20'i32):
        top = at
      var dup = false
      for k in 0 ..< into.len:
        if into[k] == top:
          dup = true
      if not dup:
        into.add top
  if into.len == 0:
    gMtxResolveWhy = "NO scene roots are reachable (iSceneRoots returned " &
                     $n & ") and this feature has no live PreloaderUI anchor " &
                     "of its own yet either. If this persists once the menu " &
                     "is up it is NOT a timing problem: iSceneRoots reaches " &
                     "the DontDestroyOnLoad scene -- where the live UI is -- " &
                     "only through gInspPreloader, which ONLY the live " &
                     "inspector's rider ever writes, so turning liveInspector " &
                     "on is the workaround and generalising " &
                     "iAnchorSceneHandle is the fix"
    return
  result = true

proc mtxDescend(t: Il2CppPtr; name: string; depth: int;
                 budget: var int; deadline: uint64): Il2CppPtr =
  ## A bounded, TIME-SLICED descent by name.
  ##
  ## THREE bounds, because the previous version had only one and it was not
  ## enough: a 750 ms walk was MEASURED on the live client (187x the 4 ms
  ## slice) because the slice was only checked AFTER the whole pass returned.
  ##   * `budget` -- total nodes across the whole pass, threaded through the
  ##     recursion;
  ##   * `deadline` -- checked INSIDE the walk, so a pass can abandon itself
  ##     mid-descent instead of stalling the Unity main thread to completion;
  ##   * `depth` and a per-level fan-out cap.
  ## `iObjName` is the expensive step (it resolves a target BY NAME and then
  ## allocates a managed string, per node), so the cheapest bound is simply not
  ## visiting the node -- which is what the targeted descent below is for.
  result = nil
  if t == nil or depth < 0 or budget <= 0 or not duOk(t, 0x20'i32):
    return
  budget = budget - 1
  if (budget and 31) == 0 and cNowMs() > deadline:
    budget = 0                        # poison the budget: unwinds every level
    return
  if iObjName(t) == name:
    return t
  if depth == 0:
    return
  var n = 0
  if not iChildCount(t, n):
    return
  var i = 0
  while i < n and i < MtxFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil:
      result = mtxDescend(c, name, depth - 1, budget, deadline)
      if result != nil:
        return
    i = i + 1

proc modeTextFindGameModeRoot(): Il2CppPtr =
  ## `ChangeGameModeButton`, reached from a live object we already hold.
  ##
  ## TARGETED, not a sweep. The measured path is `Common UI` ->
  ## `ChangeGameModeButton` (fact #116), so pass A reads the name of each ROOT
  ## once -- a dozen `iObjName` calls -- and only descends under the root that
  ## is actually named `Common UI`. The previous version descended 8 levels with
  ## a fan-out of 32 under EVERY root and burned its whole 4000-node budget
  ## without reaching root 11 of 11; the node it wanted was never in the part of
  ## the tree it could afford to look at.
  ##
  ## Pass B is the honest fallback for a build that renamed or re-parented the
  ## root, and it is reported DIFFERENTLY so the two can never be confused.
  result = nil
  var roots: seq[Il2CppPtr] = @[]
  if not mtxAnchorRoots(roots):
    return                              # gMtxResolveWhy already set
  let deadline = cNowMs() + MtxWalkMs
  var budget = MtxNodeBudget
  var names = ""
  var sawCommon = false
  var i = 0
  # ---- PASS A: the root named "Common UI", descended shallowly. ----
  while i < roots.len and i < MtxRootCap and budget > 0:
    let r = roots[i]
    if r != nil and duOk(r, 0x20'i32):
      let rn = iObjName(r)
      if names.len < 300:
        names = names & "'" & rn & "' "
      if rn == "Common UI":
        sawCommon = true
        let m = mtxDescend(r, "ChangeGameModeButton", MtxDescendDepth,
                           budget, deadline)
        if m != nil:
          gMtxResolveWhy = ""
          gMtxLastNodes = MtxNodeBudget - budget
          gMtxLastVia = "Common UI (pass A, targeted)"
          return m
    i = i + 1
  # ---- PASS B: every other root, same shallow depth, same shared budget. ----
  var j = 0
  while j < roots.len and j < MtxRootCap and budget > 0:
    let r = roots[j]
    if r != nil and duOk(r, 0x20'i32):
      let m = mtxDescend(r, "ChangeGameModeButton", MtxDescendDepth,
                         budget, deadline)
      if m != nil:
        gMtxResolveWhy = ""
        gMtxLastNodes = MtxNodeBudget - budget
        gMtxLastVia = "a root OTHER than 'Common UI' (pass B, fallback) -- " &
                      "fact #116 said Common UI, so this build has moved it"
        return m
    j = j + 1
  gMtxLastNodes = MtxNodeBudget - budget
  # THREE DISTINGUISHABLE OUTCOMES, never flattened into one. "I ran out of
  # budget" and "I looked everywhere and it is not there" are different facts
  # and only the second is a verdict.
  if budget <= 0:
    gMtxResolveWhy = "the descent hit its node budget (" & $MtxNodeBudget &
                     ") or its " & $int(MtxWalkMs) & " ms in-walk deadline " &
                     "after " & $gMtxLastNodes & " nodes over " & $roots.len &
                     " root(s); a root named 'Common UI' was " &
                     (if sawCommon: "PRESENT" else: "NOT present") &
                     ". This is INCONCLUSIVE, not a verdict of absent"
  elif not sawCommon:
    gMtxResolveWhy = "no root is named 'Common UI' (fact #116 says the button " &
                     "hangs off it) and no 'ChangeGameModeButton' within " &
                     $MtxDescendDepth & " levels of any of the " & $roots.len &
                     " root(s) either, in " & $gMtxLastNodes & " nodes. Roots " &
                     "seen: " & names
  else:
    gMtxResolveWhy = "'Common UI' WAS reached but has no " &
                     "'ChangeGameModeButton' within " & $MtxDescendDepth &
                     " levels, and neither does any other root (" &
                     $gMtxLastNodes & " nodes visited, budget NOT exhausted, " &
                     "so this one is a real absence AT THIS DEPTH). Roots: " &
                     names

proc modeTextResolveOne(btnT: Il2CppPtr; childName: string;
                         tmpOut, locOut: var Il2CppPtr): bool =
  ## Walks `btnT -> Available -> MainTextContainer -> childName`, then
  ## resolves the TextMeshProUGUI (required) and LocalizedText (optional --
  ## not every TMP carries one) components on the leaf. Never falls back to a
  ## guess: a missing hop is reported and nothing is cached.
  result = false
  tmpOut = nil
  locOut = nil
  let avail = modsChildNamed(btnT, "Available")
  if avail == nil:
    gMtxResolveWhy = "ChangeGameModeButton has no child 'Available'"
    return
  let container = modsChildNamed(avail, "MainTextContainer")
  if container == nil:
    gMtxResolveWhy = "Available has no child 'MainTextContainer'"
    return
  let leaf = modsChildNamed(container, childName)
  if leaf == nil:
    gMtxResolveWhy = "MainTextContainer has no child '" & childName & "'"
    return
  let tmp = modsComponent(leaf, "TextMeshProUGUI")
  if tmp == nil or not duOk(tmp, cSuiOffTmpMText() + 8'i32):
    gMtxResolveWhy = childName & " has no readable TextMeshProUGUI component"
    return
  tmpOut = tmp
  locOut = modsComponent(leaf, "LocalizedText")     # optional
  result = true

proc modeTextResolveBoth(): bool =
  result = false
  let btnT = modeTextFindGameModeRoot()
  if btnT == nil:
    return
  var tmpM: Il2CppPtr = nil
  var locM: Il2CppPtr = nil
  var tmpH: Il2CppPtr = nil
  var locH: Il2CppPtr = nil
  if not modeTextResolveOne(btnT, "MainText", tmpM, locM):
    return
  if not modeTextResolveOne(btnT, "MainTextHover", tmpH, locH):
    return
  gMtxTmpMain = tmpM
  gMtxLocMain = locM
  gMtxTmpHover = tmpH
  gMtxLocHover = locH
  result = true

proc modeTextApplyOne(tmp, loc, s: Il2CppPtr; label: string) =
  ## Writes through the REAL setters and re-applies, same recipe as
  ## `swRelabelControl`: `LocalizedText::SetLabelText` first (the level a
  ## locale pass re-applies from, when the sibling exists), then
  ## `TMP_Text::set_text` + the real dirty latch. `ForceMeshUpdate` @0x628110
  ## is this build's universal empty-body stub and is not called.
  ##
  ## VERIFIES THE OUTCOME: reads `m_text` back AFTER both calls and logs what
  ## is actually there, not what was asked for -- a verification that can only
  ## observe its own write is worthless (fact #88, the MODS row-caption bug).
  if loc != nil:
    let fn = cSwFn2(SwLocSetLabelText)
    if fn != nil:
      cSwCallVPP(fn, loc, s)
  discard swSetTmpTextByCall(tmp, s)
  let after = suiReadString(cReadPtrAt(tmp, cSuiOffTmpMText()))
  if after == gModeTextWant:
    okLog "menu mode text: " & label & " now reads \"" & after &
          "\" (VERIFIED by read-back)"
  else:
    warn "menu mode text: " & label & " reads \"" & after &
         "\" after the write, not the requested \"" & gModeTextWant &
         "\" -- something else is still writing this TMP"

proc modeTextTickBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_mtx_tick_body", cdecl.} =
  ## The whole managed-touching body, under ONE guard. `a` is the live
  ## `PreloaderUI` this, already non-nil and readable when we get here.
  ##
  ## Returns a non-nil sentinel on clean completion; the guard returns nil if
  ## this faulted, and the caller counts that toward the self-disable.
  result = cast[Il2CppPtr](1)
  let self = a           # the PreloaderUI `this`; unused by the new path below,
  discard self           # kept only so the shared drain's dispatch shape is intact

  # ---- REMOVE THE BUTTON (uxHideModeButton). Wins over the relabel outright. ----
  if gModeHideOn:
    # THE FAST PATH, once the object is known: a guarded pointer check, a
    # liveness check and one `activeSelf` ICALL. No allocation, no walk, so it
    # may run on the steady cadence and still hide a rebuilt menu promptly.
    if gMtxHideGo != nil:
      if duOk(gMtxHideGo, 0x20'i32) and iUnityAlive(gMtxHideGo):
        if modsGoActive(gMtxHideGo):
          if modsSetActive(gMtxHideGo, false):
            inc gMtxHidden
            if gMtxHidden == 2:
              okLog "hide mode button: ChangeGameModeButton came back after a " &
                    "menu rebuild and was switched off again from the cached " &
                    "object"
          else:
            warn "hide mode button: GameObject::SetActive(false) REFUSED on " &
                 "ChangeGameModeButton (the target verified, the call did not " &
                 "run). The button is UNTOUCHED -- this is a refusal, not a " &
                 "success."
        return
      gMtxHideGo = nil                  # destroyed; fall through and re-resolve
    let t0h = cNowMs()
    let btnT = modeTextFindGameModeRoot()
    let spentH = cNowMs() - t0h
    if spentH > MtxSliceMs and not gMtxSlow:
      gMtxSlow = true
      warn "hide mode button: one bounded walk cost " & $int(spentH) &
           " ms, over the " & $int(MtxSliceMs) & " ms slice, so the fast hunt " &
           "(every " & $MtxHuntFrames & " frames) has BACKED OFF to every " &
           $MtxSteadyFrames & " frames. This rider runs on the Unity main " &
           "thread and a stall here is the whole reason this feature was " &
           "rewritten; being late is the deliberate trade."
    if btnT == nil:
      inc gMtxNotReady
      if gMtxNotReady <= 2:
        okLog "hide mode button: not reachable yet -- " & gMtxResolveWhy &
              ". [pass " & $gMtxNotReady & ", " & $gMtxLastNodes &
              " nodes, " & $int(spentH) & " ms] Expected before the main " &
              "menu is up; it keeps looking."
      return
    let go = iGameObjectOf(btnT)
    if go == nil or not iUnityAlive(go):
      gMtxResolveWhy = "ChangeGameModeButton was found but its GameObject is " &
                       "null or its native half is not live yet"
      return
    gMtxHideGo = go
    if gMtxTResolved == 0:
      gMtxTResolved = cNowMs()
    if not modsGoActive(go):
      return                            # already hidden: a read, and no call
    if modsSetActive(go, false):
      inc gMtxHidden
      if not gMtxSaidHidden:
        gMtxSaidHidden = true
        okLog "hide mode button: Common UI/ChangeGameModeButton switched off " &
              "(the bottom-right PVE ZONE / switch-game-mode control), " &
              $int(gMtxTResolved - gMtxT0) & " ms after this rider first " &
              "ticked. Found STRUCTURALLY by walking from a verified scene " &
              "root with a " & $MtxNodeBudget & "-node budget -- never from a " &
              "cached pointer, and never from PreloaderUI._sessionModeText, " &
              "which is a recorded FALSE POSITIVE for this label (fact #116). " &
              "REACHED VIA " & gMtxLastVia & ", in " & $gMtxLastNodes &
              " nodes. " &
              "It is re-checked on a throttle so a menu rebuild hides it " &
              "again; this host never sets it back to active."
    else:
      warn "hide mode button: GameObject::SetActive(false) REFUSED on " &
           "ChangeGameModeButton. The button is UNTOUCHED."
    return

  # ---- resolve the REAL target once, by walking, never by a cached RVA guess ----
  if not gMtxResolved:
    block:
      let t0 = cNowMs()
      let got = modeTextResolveBoth()
      let spent = cNowMs() - t0
      if spent > MtxSliceMs and not gMtxSlow:
        gMtxSlow = true
        warn "menu mode text: one bounded walk cost " & $int(spent) &
             " ms, over the " & $int(MtxSliceMs) & " ms slice, so the fast " &
             "hunt has BACKED OFF from every " & $MtxHuntFrames &
             " frames to every " & $MtxSteadyFrames & " frames."
      inc gMtxResolvePasses
      if got:
        gMtxResolved = true
        gMtxTResolved = cNowMs()
        gModeTextLogged = true
        let curMain = suiReadString(cReadPtrAt(gMtxTmpMain, cSuiOffTmpMText()))
        let curHover = suiReadString(cReadPtrAt(gMtxTmpHover, cSuiOffTmpMText()))
        okLog "menu mode text: FOUND both corner-label TMPs by WALKING (never " &
              "hardcoded) Common UI/.../ChangeGameModeButton/Available/" &
              "MainTextContainer/{MainText,MainTextHover} from a verified scene " &
              "root. MainText=0x" & hexOf(cast[uint64](gMtxTmpMain)) &
              " currently reads \"" & curMain & "\"; MainTextHover=0x" &
              hexOf(cast[uint64](gMtxTmpHover)) & " currently reads \"" &
              curHover & "\". LocalizedText siblings: main=" &
              (if gMtxLocMain != nil: "0x" & hexOf(cast[uint64](gMtxLocMain))
               else: "none") &
              ", hover=" &
              (if gMtxLocHover != nil: "0x" & hexOf(cast[uint64](gMtxLocHover))
               else: "none") &
              ". The old EFT.UI.PreloaderUI::SetGameModeText path is REMOVED: " &
              "measured that _sessionModeText genuinely updates but never " &
              "reaches the screen, and these two TMPs are what actually renders."
        if curMain.len > 0:
          gModeTextApplied = curMain
      else:
        inc gMtxNotReady
        if not gMtxResolveSaidWalk and gMtxNotReady == 2:
          gMtxResolveSaidWalk = true
          okLog "menu mode text: not found yet -- " & gMtxResolveWhy &
                ". Expected before the main menu is up; it keeps looking on a " &
                "real throttle (every " & $MtxHuntFrames & " frames while " &
                "hunting, bounded to " & $MtxNodeBudget & " nodes and " &
                $int(MtxSliceMs) & " ms per pass)."
    # THE GIVE-UP moved OUT of here and into `modeTextUpdateFired`, where it is
    # measured in WALL CLOCK. The old `MtxResolveMaxPasses = 30` counted passes
    # that used to happen once per frame, so it also bounded nothing that
    # mattered: 30 frames is a fraction of a second, and the button appears
    # tens of seconds in.
    if not gMtxResolved:
      return

  if gModeTextWant.len == 0 or gModeTextWant == gModeTextApplied:
    return                                   # nothing changed: no alloc, no call

  # THE ONE ALLOCATION, and only because the text actually changed. One String
  # feeds both TMPs' writes below.
  gModeTextAlloc = gModeTextWant
  let ns = modeTextNewString(cast[Il2CppPtr](0))
  if ns == nil or cIsReadable(ns, 0x14'i32) == 0'i32:
    warn "menu mode text: the guarded il2cpp_string_new failed or returned an " &
         "unreadable String; the stock label is left alone"
    # Do not retry this exact value every frame.
    gModeTextApplied = gModeTextWant
    return

  modeTextApplyOne(gMtxTmpMain, gMtxLocMain, ns, "MainText")
  modeTextApplyOne(gMtxTmpHover, gMtxLocHover, ns, "MainTextHover")
  gModeTextApplied = gModeTextWant
  inc gModeTextApplies

proc modeTextUpdateFired(regs: Il2CppPtr) =
  ## Dispatched by slot identity from `patchReturned` for the kind=13 POSTFIX
  ## detour on `EFT.UI.PreloaderUI::Update`. Runs on Unity's main thread, once
  ## per frame, so the FIRST thing it does is get out of the way when there is
  ## nothing to do.
  if gModeTextOff:
    return
  inc gModeTextFires
  let selfRaw = cRegsInt(regs, 0'i32)          # RCX = the PreloaderUI `this`
  if selfRaw == 0'u64:
    return
  let self = cast[Il2CppPtr](selfRaw)
  gModeTextSelf = self

  # ARMED BUT STARVED. One shot, and only once the detour has demonstrably been
  # firing for a while with nothing ever asked of it. That means the hook is
  # healthy and the SOURCE is missing -- almost always the backend poll not
  # reaching this host (no `backendPort` and no installer `backend.json`, or the
  # manager mod not running) -- so it names that rather than the hook.
  # NOT when `uxHideModeButton` is the reason this rider is armed: that feature
  # has no backend source and never wanted one, so "the backend never sent a
  # menuModeText" would be a true sentence and a wrong diagnosis.
  if not gModeHideOn and not gModeTextStarved and gModeTextWant.len == 0 and
     gModeTextFires >= ModeTextStarveFrames:
    gModeTextStarved = true
    warn "menu mode text: the PreloaderUI.Update hook has fired " &
         $gModeTextFires & " times and the backend has never sent a " &
         "`menuModeText`, so the corner label is still the game's stock text. " &
         "The hook is fine; the SOURCE is missing. Check that the backend is " &
         "reachable (backendPort in aowlspt-host.json, or backendUrl in the " &
         "installer's backend.json) and that the manager mod is running."

  # The cheap early-out that keeps this off the hot path: after the one-shot
  # identification log has run, a frame with no pending change does no work at
  # all -- no read, no guard entry, no allocation. It does NOT apply when the
  # hide feature is on, because that one has work to do on every throttled pass
  # regardless of what the backend has said.
  if not gModeHideOn and gModeTextLogged and
     (gModeTextWant.len == 0 or gModeTextWant == gModeTextApplied):
    return

  # ------------------------------------------------------------------
  # THE THROTTLE. It lives HERE, on the side that decides whether to enter the
  # guard, and nowhere else -- a throttle duplicated on both sides of a split
  # once cancelled exactly and produced a feature that was armed, guarded,
  # never faulting and never doing anything.
  #
  # Adaptive, and every branch bounded:
  #   * hunting (target not yet found, no slice overrun) -> MtxHuntFrames;
  #   * resolved, or backed off after an overrun          -> MtxSteadyFrames.
  if gMtxT0 == 0:
    gMtxT0 = cNowMs()
  let hunting = (if gModeHideOn: gMtxHideGo == nil else: not gMtxResolved)
  let every = (if hunting and not gMtxSlow: MtxHuntFrames else: MtxSteadyFrames)
  inc gMtxFrames
  if gMtxFrames < every:
    return
  gMtxFrames = 0

  # THE GIVE-UP, in wall clock rather than in attempts, and LOUD. "The button is
  # still there" must never be a silent outcome.
  if hunting and cNowMs() - gMtxT0 > MtxHuntMs:
    if not gMtxResolveGaveUp:
      gMtxResolveGaveUp = true
      warn (if gModeHideOn: "hide mode button" else: "menu mode text") &
           ": GIVING UP after " & $int(MtxHuntMs div 1000) & " s and " &
           $gMtxNotReady & " bounded walks -- " & gMtxResolveWhy &
           ". Nothing was changed; the stock control is exactly as the game " &
           "made it. This is a REFUSAL, not a success."
      gModeTextOff = true
    return

  if gModeTextFires == 1:
    let tid = int(cThreadId())
    # NOT "postfix". This handler is dispatched from BOTH halves -- prefix when
    # the debug overlay claimed the shared slot, postfix when this feature
    # claimed it -- and the string used to say "postfix" unconditionally. That
    # lie cost a full investigation cycle: it made a prefix-claimed slot look
    # like a claim/fire mismatch and sent the hunt after a bug that did not
    # exist. The half is not knowable from here, so this no longer claims it.
    okLog "menu mode text: PreloaderUI.Update first fired on thread " &
          $tid & (if tid == int(gHostThreadId):
                    " (HOST thread -- unexpected, NOT Unity's)"
                  else: " (Unity's main thread)")

  # No `self` field-gate here any more: the new target is resolved by walking
  # scene roots, not by reading an offset on this PreloaderUI `this`. `self` is
  # still passed through only to keep the guarded call's shape unchanged.
  if cMtxTickGuarded(self) == nil:
    inc gModeTextFaults
    # A FAULT WHILE STILL HUNTING ALSO ENDS THE FAST CADENCE. Otherwise a walk
    # that faults every pass burns the whole budget in a handful of frames --
    # the "gave up before its target existed" failure, just relocated. The
    # budget is also LARGER while hunting: faulting on a half-built menu is not
    # the same event as faulting on a resolved target, and an earlier version of
    # this pattern in the version brand spent every attempt on pre-menu walk
    # faults and had nothing left for the moment the control appeared.
    let cap = (if hunting: ModeTextMaxFaults * 8 else: ModeTextMaxFaults)
    if hunting:
      gMtxSlow = true
    warn "menu mode text: the guarded body faulted (" & $gModeTextFaults &
         " of " & $cap & (if hunting: ", while still HUNTING -- expected " &
         "before the menu exists; the fast cadence has been dropped" else: "") &
         ")"
    if gModeTextFaults >= cap:
      gModeTextOff = true
      warn "menu mode text: too many faults; switching itself off for this " &
           "session and leaving the stock label alone"

proc bindModeText(verbose: bool): bool =
  ## Installs the POSTFIX detour on `EFT.UI.PreloaderUI::Update` from the
  ## verified static target. Opt-in (`uxMenuModeText`). A build whose prologue
  ## does not match binds nothing at all, so this is a no-op elsewhere rather
  ## than a hazard.
  ##
  ## SHARES `EFT.UI.PreloaderUI::Update` WITH THE DEBUG OVERLAY rather than
  ## excluding it. `debugui` (kind 10) drains the SAME function @ 0x1569f20, and
  ## two detours on one function have the second overwrite the first's
  ## trampoline -- the precise failure `bindDebugEspWorld` refuses for
  ## `GameWorld::RegisterPlayer`. But refusing is not the only answer to that:
  ## `bindDebugEspWorld`'s own comment names the better one -- when the other
  ## feature owns the target, ride on ITS firing instead of installing a second
  ## detour. That is what happens here. If the overlay already claimed the slot,
  ## this ALIASES `gModeTextSlot` onto it and `patchFired`/`patchReturned`
  ## dispatch both riders from the one detour. So `debugUi`/`debugEsp` and
  ## `uxMenuModeText` can all be on at once.
  ##
  ## The alias is only taken when the code pointer this feature verified is
  ## BYTE-IDENTICAL to the one the overlay hooked. Riding on a detour that is
  ## actually on some other function would feed `modeTextUpdateFired` an RCX
  ## that is not a `PreloaderUI`, and every read after that would be a guess.
  if gModeTextSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let fn = cMtxFn(MtxTUpdate)
  if fn == nil:
    if verbose:
      info "menu mode text: PreloaderUI.Update did not verify on this build " &
           "(" & $int(cMtxOkCount()) & " target(s) verified, " &
           $int(cMtxBadCount()) & " rejected); nothing bound"
    return false
  # `SetGameModeText` is NO LONGER the write path (measured: it updates
  # `_sessionModeText` but never reaches the screen -- fact #116), so its
  # verification is not a bind gate any more. The real target is resolved at
  # runtime by walking the scene tree in `modeTextTickBody`, which declines
  # and logs on its own if the path is not there; binding the shared drain
  # does not depend on it.
  # THE MULTIPLEX. The overlay armed first (aowlhost arms it first), so the
  # normal path when both are on is this one: no second detour, no second
  # trampoline, one shared firing.
  if gDebugUiSlot >= 0:
    let duFn = cDuPreloaderTarget()
    if duFn != fn:
      warn "menu mode text: the F3 debug overlay holds a detour whose target " &
           "(0x" & hexOf(cast[uint64](duFn)) & ") is not the " &
           "PreloaderUI::Update this feature verified (0x" &
           hexOf(cast[uint64](fn)) & "). Refusing to ride on it, and refusing " &
           "to add a second detour to the same function. Nothing bound."
      return false
    gModeTextSlot = gDebugUiSlot
    okLog "menu mode text armed as a RIDER on the debug overlay's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gModeTextSlot &
          ") -- one detour, one trampoline, both features live. The " &
          "bottom-right corner label follows the backend's `menuModeText`, " &
          "which defaults to the logged-in character's name"
    return true
  # The LIVE INSPECTOR, the third rider, may have claimed it instead. Same
  # rule, same reason: it claims through `cDuPreloaderTarget`, so the target
  # identity check above already covers it -- ride, never double-detour.
  if gInspSlot >= 0:
    let duFn = cDuPreloaderTarget()
    if duFn != fn:
      warn "menu mode text: the live inspector holds a detour whose target " &
           "(0x" & hexOf(cast[uint64](duFn)) & ") is not the " &
           "PreloaderUI::Update this feature verified (0x" &
           hexOf(cast[uint64](fn)) & "). Refusing to ride on it, and refusing " &
           "to add a second detour to the same function. Nothing bound."
      return false
    gModeTextSlot = gInspSlot
    okLog "menu mode text armed as a RIDER on the live inspector's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gModeTextSlot &
          ") -- one detour, one trampoline, both features live"
    return true
  if attachDrain("EFT.UI.PreloaderUI::Update", fn, cast[Il2CppMethod](0),
                 false, verbose, 13'i32, true):
    okLog "menu mode text CLAIMED the shared EFT.UI.PreloaderUI::Update " &
          "detour (slot " & $gModeTextSlot & ", postfix); the debug overlay " &
          "will ride on this same detour if it is turned on later. The " &
          "bottom-right corner label follows the backend's `menuModeText`, " &
          "which defaults to the logged-in character's name"
    return true
  result = false
