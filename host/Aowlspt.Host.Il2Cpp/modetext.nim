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
const MtxResolveMaxPasses = 30
  ## Same budget as `SeasonsMaxPasses`: the walk is bounded and cheap, so 30
  ## tries (well under a second at 60fps) is plenty before the main menu is up,
  ## and giving up loudly beats retrying forever in silence.

proc modeTextFindGameModeRoot(): Il2CppPtr =
  ## `ChangeGameModeButton`, searched from every scene root down to a bounded
  ## depth -- the same pattern as `seasonsFindMenuScreen`. "Common UI" is the
  ## verified live root (fact #116), but this does not hardcode that layer, so
  ## an inserted UI wrapper does not silently break the walk.
  result = nil
  var roots: seq[Il2CppPtr] = @[]
  let n = iSceneRoots(roots, false)
  if roots.len == 0:
    gMtxResolveWhy = "iSceneRoots enumerated NO roots (" & $n & ")"
    return
  var names = ""
  var i = 0
  while i < roots.len and i < 32:
    let goT = iToTransform(roots[i])
    if goT != nil and duOk(goT, 0x20'i32):
      if names.len < 300:
        names = names & "'" & iObjName(goT) & "' "
      let m = modsFindNamed(goT, "ChangeGameModeButton", 8)
      if m != nil:
        gMtxResolveWhy = ""
        return m
    i = i + 1
  gMtxResolveWhy = "no 'ChangeGameModeButton' within 8 levels of any of the " &
                    $roots.len & " scene root(s): " & names

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

  # ---- resolve the REAL target once, by walking, never by a cached RVA guess ----
  if not gMtxResolved:
    if gMtxResolvePasses < MtxResolveMaxPasses:
      inc gMtxResolvePasses
      if modeTextResolveBoth():
        gMtxResolved = true
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
      elif not gMtxResolveSaidWalk and gMtxResolvePasses == 2:
        gMtxResolveSaidWalk = true
        okLog "menu mode text: not found yet -- " & gMtxResolveWhy &
              ". Expected before the main menu is up; retried on a throttle."
    elif not gMtxResolveGaveUp:
      gMtxResolveGaveUp = true
      warn "menu mode text: GIVING UP after " & $gMtxResolvePasses &
           " passes -- " & gMtxResolveWhy & ". Stock corner label left alone; " &
           "this feature is otherwise idle for the session."
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
  if not gModeTextStarved and gModeTextWant.len == 0 and
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
  # all -- no read, no guard entry, no allocation.
  if gModeTextLogged and
     (gModeTextWant.len == 0 or gModeTextWant == gModeTextApplied):
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
    warn "menu mode text: the guarded body faulted (" & $gModeTextFaults &
         " of " & $ModeTextMaxFaults & ")"
    if gModeTextFaults >= ModeTextMaxFaults:
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
