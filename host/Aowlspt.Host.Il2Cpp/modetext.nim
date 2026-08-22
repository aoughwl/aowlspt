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

proc modeTextRawString(p: Il2CppPtr): string =
  ## A `System.String*` as text by its FIXED runtime layout -- length int32 at
  ## +0x10, UTF-16 chars inline at +0x14 -- with every read guarded. The same
  ## primitive the version brand uses, and self-validating: a slot that is not a
  ## String yields "" rather than garbage. ASCII only, which is all the corner
  ## label has ever held; a non-ASCII char makes it bail rather than guess.
  result = ""
  if p == nil or cIsReadable(p, 0x14'i32) == 0'i32:
    return
  let n = cReadI32At(cast[Il2CppPtr](cast[uint64](p) + 0x10'u64))
  if n <= 0'i32 or n > 128'i32:
    return
  let chars = cast[Il2CppPtr](cast[uint64](p) + 0x14'u64)
  if cIsReadable(chars, int32(n) * 2'i32) == 0'i32:
    return
  for i in 0 ..< int(n):
    let c = cWordAt(chars, uint64(i))
    if c == 0'u16 or c > 0x7E'u16:
      return ""
    result.add char(c)

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

proc modeTextTickBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_mtx_tick_body", cdecl.} =
  ## The whole managed-touching body, under ONE guard. `a` is the live
  ## `PreloaderUI` this, already non-nil and readable when we get here.
  ##
  ## Returns a non-nil sentinel on clean completion; the guard returns nil if
  ## this faulted, and the caller counts that toward the self-disable.
  result = cast[Il2CppPtr](1)
  let self = a

  # ---- the one-shot identification log ----
  #
  # This is what makes the target verifiable from a real run rather than from
  # this file's claims: the object pointer the user is looking at, the parent
  # chain to it, and the CURRENT text of the field, read before anything is
  # written. On a stock client the last of these prints "PVE ZONE".
  if not gModeTextLogged:
    gModeTextLogged = true
    let modeOff = cMtxOffModeText()
    let lblOff = cMtxOffCornerLabel()
    var cur = ""
    if cIsReadable(self, modeOff + 8'i32) != 0'i32:
      cur = modeTextRawString(cReadPtrAt(self, modeOff))
    var lbl: Il2CppPtr = nil
    if cIsReadable(self, lblOff + 8'i32) != 0'i32:
      lbl = cReadPtrAt(self, lblOff)
    okLog "menu mode text: FOUND the corner label. parent chain = " &
          "EFT.UI.PreloaderUI(this=0x" & hexOf(cast[uint64](self)) & ")" &
          " -> _alphaVersionLabel:LocalizedText(+0x" & hexOf(uint64(lblOff)) &
          ")=0x" & hexOf(cast[uint64](lbl)) &
          " ; the mode string is _sessionModeText(+0x" &
          hexOf(uint64(modeOff)) & ") and currently reads \"" & cur & "\"" &
          " (this is the \"PVE ZONE\" slot; identified offline from the " &
          "decrypted metadata, and confirmed here by SetGameModeText's own " &
          "mov [rcx+0x128],rdx)"
    # Seed `gModeTextApplied` with the stock value so that a backend asking for
    # exactly what is already on screen costs no allocation and no call.
    if cur.len > 0:
      gModeTextApplied = cur

  if gModeTextWant.len == 0 or gModeTextWant == gModeTextApplied:
    return                                   # nothing changed: no alloc, no call

  let fn = cMtxFn(MtxTSetText)
  if fn == nil:
    # Verified at bind time, so this is only reachable if the module moved under
    # us. Refuse permanently rather than retry every frame.
    warn "menu mode text: SetGameModeText no longer verifies; switching off"
    gModeTextOff = true
    return

  # THE ONE ALLOCATION, and only because the text actually changed.
  gModeTextAlloc = gModeTextWant
  let ns = modeTextNewString(cast[Il2CppPtr](0))
  if ns == nil or cIsReadable(ns, 0x14'i32) == 0'i32:
    warn "menu mode text: the guarded il2cpp_string_new failed or returned an " &
         "unreadable String; the stock label is left alone"
    # Do not retry this exact value every frame.
    gModeTextApplied = gModeTextWant
    return

  # Call the game's own setter. RCX=this, RDX=the String, R8=MethodInfo*=NULL
  # (correct here: SetGameModeText is not shared generic code). The setter
  # stores 0x128 and refreshes the corner label itself -- which is the whole
  # reason this is a call and not a field poke.
  cMtxCallVPP(fn, self, ns)
  gModeTextApplied = gModeTextWant
  inc gModeTextApplies
  okLog "menu mode text: called EFT.UI.PreloaderUI::SetGameModeText @ 0x" &
        hexOf(uint64(cMtxRva(MtxTSetText))) & " on this=0x" &
        hexOf(cast[uint64](self)) & " with \"" & gModeTextApplied &
        "\" (apply #" & $gModeTextApplies & ")"

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
    okLog "menu mode text: PreloaderUI.Update postfix first fired on thread " &
          $tid & (if tid == int(gHostThreadId):
                    " (HOST thread -- unexpected, NOT Unity's)"
                  else: " (Unity's main thread)")

  if cIsReadable(self, cMtxOffModeText() + 8'i32) == 0'i32:
    return

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
  # The setter must verify too, before anything is hooked. Binding a per-frame
  # detour whose only purpose is a call we then could not make is pure cost.
  if cMtxFn(MtxTSetText) == nil:
    if verbose:
      info "menu mode text: " & readCString(cMtxName(MtxTSetText)) &
           " @ 0x" & hexOf(uint64(cMtxRva(MtxTSetText))) &
           " did not verify; nothing bound"
    return false
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
  if attachDrain("EFT.UI.PreloaderUI::Update", fn, cast[Il2CppMethod](0),
                 false, verbose, 13'i32, true):
    okLog "menu mode text CLAIMED the shared EFT.UI.PreloaderUI::Update " &
          "detour (slot " & $gModeTextSlot & ", postfix); the debug overlay " &
          "will ride on this same detour if it is turned on later. The " &
          "bottom-right corner label follows the backend's `menuModeText`, " &
          "which defaults to the logged-in character's name"
    return true
  result = false
