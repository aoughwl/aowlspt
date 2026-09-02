# settingsui.nim -- Phase 1 read-only probe of the native SettingsScreen control
# tree. `include`d into `aowlhost.nim` (NOT a separate module) so it shares that
# file's guarded raw-read primitives (`cIsReadable`/`cReadPtrAt`/`cReadI32At`/
# `cWordAt`), its logging (`okLog`/`warn`), `hexOf`, `attachDrain`, and the
# verified `SettingsScreen::Show` target -- exactly the discipline the version
# brand uses, one hop deeper into the settings UI.
#
# It NEVER writes. From inside the read-only detour on `SettingsScreen::Show`
# (Unity thread, `this` = the live SettingsScreen), it walks each initialized tab
# and that tab's `_createdControls` list, decodes every control's label String by
# the fixed IL2CPP layout, and logs it together with the control's il2cpp type
# pointer. Every hop is `cIsReadable`-guarded (a VirtualQuery, never a faulting
# deref) and logged, so a fault names the op and an unreadable hop is a skip, not
# a crash. Flag-gated `settingsUiProbe`, default-off. The offsets live in
# `abi/aowlspt_settingsui.h`; they are Phase-0 candidates and this probe's log is
# their live validation (see the offsets-used note in the delivery report).

# ---- offsets from abi/aowlspt_settingsui.h (single source of truth) ----
proc cSuiOffCurrentTab(): int32 {.importc: "aowl_sui_off_currenttab", nodecl.}
proc cSuiOffGameTab(): int32 {.importc: "aowl_sui_off_gametab", nodecl.}
proc cSuiOffGraphicsTab(): int32 {.importc: "aowl_sui_off_graphicstab", nodecl.}
proc cSuiOffPostFxTab(): int32 {.importc: "aowl_sui_off_postfxtab", nodecl.}
proc cSuiOffSoundTab(): int32 {.importc: "aowl_sui_off_soundtab", nodecl.}
proc cSuiOffControlsTab(): int32 {.importc: "aowl_sui_off_controlstab", nodecl.}
proc cSuiOffCreatedCtrls(): int32 {.importc: "aowl_sui_off_createdctrls", nodecl.}
proc cSuiOffListItems(): int32 {.importc: "aowl_sui_off_list_items", nodecl.}
proc cSuiOffListSize(): int32 {.importc: "aowl_sui_off_list_size", nodecl.}
proc cSuiOffArrElems(): int32 {.importc: "aowl_sui_off_arr_elems", nodecl.}
proc cSuiOffCtrlText(): int32 {.importc: "aowl_sui_off_ctrl_text", nodecl.}
proc cSuiOffCtrlValue(): int32 {.importc: "aowl_sui_off_ctrl_value", nodecl.}
proc cSuiOffLocTextList(): int32 {.importc: "aowl_sui_off_loctext_list", nodecl.}
proc cSuiOffTmpMText(): int32 {.importc: "aowl_sui_off_tmp_mtext", nodecl.}
## ESettingsGroup -> tab field offset / name, read off `EnsureTabInitialized`'s
## own switch (see aowlspt_settingsui.h). -1 / "?" outside 0..4.
proc cSuiGroupTabOffset(group: int32): int32 {.
  importc: "aowl_sui_group_tab_offset", nodecl.}
proc cSuiGroupName(group: int32): Il2CppPtr {.
  importc: "aowl_sui_group_name", nodecl.}
proc cSuiOffFirstSelected(): int32 {.
  importc: "aowl_sui_off_firstselected", nodecl.}

## Phase 1.7 target: the Unity-thread heartbeat we poll from.
proc cBridgeSettingsSelTargetCount(): int32 {.
  importc: "aowl_bridge_settingstick_target_count", nodecl.}
proc cBridgeSettingsSelTargetAt(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_settingstick_target_at", nodecl.}
proc cBridgeSettingsSelTargetName(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_settingstick_target_name", nodecl.}

## Phase 1.5 target: the tab BUILDER, hooked postfix.
proc cBridgeSettingsTabTargetCount(): int32 {.
  importc: "aowl_bridge_settingstab_target_count", nodecl.}
proc cBridgeSettingsTabTargetAt(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_settingstab_target_at", nodecl.}
proc cBridgeSettingsTabTargetName(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_settingstab_target_name", nodecl.}
## The row's REGISTER-SLOT count. `attachDrain`'s postfix gate needs it, and it
## comes from the target table's own column rather than from a literal here, so
## the number a postfix is bound on is the number the table declares and
## `tools/drainaudit.py` re-derives from the metadata. 0 = undeclared, refused.
proc cBridgeSettingsTabTargetSlots(i: int32): int32 {.
  importc: "aowl_bridge_settingstab_target_slots", nodecl.}

# The slot/flag/guard globals (gSettingsUiSlot / gSettingsUiProbe /
# gSettingsUiDone) are declared in aowlhost.nim beside the other detour slots.

## The live SettingsScreen `this`, as last seen by the hook that ACTUALLY
## drives Phase 1/2/3 (the `ShowScreen` postfix in `suiTabInitBody`, below --
## first-fire AND every revisit). Declared here, ahead of `invoke2.nim`'s
## `gMi2Self`, because nimony forward-resolves procs across an `include`
## boundary but NOT variables (see the note on the revisit path below), and
## this is the earliest point a consumer further down the include chain
## (`inspect.nim`) can see a pointer that is actually kept live. Read-only
## outside this file; never written from anywhere but a verified `this`.
var gSettingsLiveSelf: Il2CppPtr = nil

## Cap the controls read per tab so a corrupt `_size` cannot spin the walk.
const cSuiMaxControls = 64
## Cap the label length decoded from a TMP string.
const cSuiMaxLabel = 128

proc suiPtrAdd(p: Il2CppPtr; off: int32): Il2CppPtr =
  ## `p + off` as an Il2CppPtr, for reading an int32 field at an offset with
  ## `cReadI32At` (which reads at the pointer it is given, no offset of its own).
  cast[Il2CppPtr](cast[uint64](p) + uint64(off))

proc suiReadString(p: Il2CppPtr): string =
  ## Decode a `System.String` at `p` by its FIXED IL2CPP layout -- length is the
  ## int32 at +0x10, the UTF-16 chars are inline at +0x14 -- with no reflection.
  ## Every read is `cIsReadable`-guarded, so a slot that is not a String yields ""
  ## and the caller treats it as "no label". BMP only; unusual code points become
  ## '?' so a real label with punctuation still reads, but a NUL ends it.
  result = ""
  if p == nil or cIsReadable(p, 0x14'i32) == 0'i32:
    return
  let n = cReadI32At(suiPtrAdd(p, 0x10'i32))
  if n <= 0'i32 or n > int32(cSuiMaxLabel):
    return
  let chars = suiPtrAdd(p, 0x14'i32)
  if cIsReadable(chars, n * 2'i32) == 0'i32:
    return
  for i in 0 ..< int(n):
    let c = cWordAt(chars, uint64(i))
    if c == 0'u16:
      break
    if c >= 0x20'u16 and c <= 0x7E'u16:
      result.add char(c)
    else:
      result.add '?'

proc suiReadControlLabel(control: Il2CppPtr): string =
  ## control.Text(+0x80) -> LocalizedText -> +0x78 List<TMP> -> first TMP ->
  ## m_text(+0xE0) -> System.String. Each hop guarded; "" on any unreadable hop.
  result = ""
  if control == nil or cIsReadable(control, cSuiOffCtrlText() + 8'i32) == 0'i32:
    return
  let locText = cReadPtrAt(control, cSuiOffCtrlText())
  if locText == nil or cIsReadable(locText, cSuiOffLocTextList() + 8'i32) == 0'i32:
    return
  let tmpList = cReadPtrAt(locText, cSuiOffLocTextList())
  if tmpList == nil or cIsReadable(tmpList, cSuiOffListItems() + 8'i32) == 0'i32:
    return
  let tmpArr = cReadPtrAt(tmpList, cSuiOffListItems())
  if tmpArr == nil or cIsReadable(tmpArr, cSuiOffArrElems() + 8'i32) == 0'i32:
    return
  let tmp0 = cReadPtrAt(tmpArr, cSuiOffArrElems())      # first TextMeshProUGUI
  if tmp0 == nil or cIsReadable(tmp0, cSuiOffTmpMText() + 8'i32) == 0'i32:
    return
  let str = cReadPtrAt(tmp0, cSuiOffTmpMText())
  result = suiReadString(str)

proc suiWalkTab(tabPtr: Il2CppPtr; tabName: string) =
  ## Read a SettingsTab's `_createdControls` List and log each control's label +
  ## il2cpp type pointer + value-widget pointer. Pure reads, all guarded.
  if tabPtr == nil or cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) == 0'i32:
    okLog "settings probe: tab=" & tabName & " not readable for its control list"
    return
  let lst = cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    okLog "settings probe: tab=" & tabName &
          " _createdControls list is null/unreadable -- expected for any tab " &
          "the user has not selected yet; only the SELECTED tab is built"
    return
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if arr == nil or size <= 0'i32:
    okLog "settings probe: tab=" & tabName & " has 0 controls (size=" & $int(size) &
          ", items=0x" & hexOf(cast[uint64](arr)) & ")"
    return
  let n = (if size > int32(cSuiMaxControls): int32(cSuiMaxControls) else: size)
  okLog "settings probe: tab=" & tabName & " _createdControls size=" & $int(size) &
        (if n < size: " (capped to " & $int(n) & ")" else: "")
  var shown = 0
  for i in 0 ..< int(n):
    let slot = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) == 0'i32:
      continue
    let control = cReadPtrAt(slot, 0'i32)
    if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
      continue
    let klass = cReadPtrAt(control, 0'i32)               # Il2CppObject header
    let widget = cReadPtrAt(control, cSuiOffCtrlValue())
    let label = suiReadControlLabel(control)
    okLog "settings probe: tab=" & tabName & " control[" & $i & "] label='" &
          label & "' type=0x" & hexOf(cast[uint64](klass)) &
          " widget=0x" & hexOf(cast[uint64](widget))
    inc shown
  okLog "settings probe: tab=" & tabName & " logged " & $shown & " controls"

proc settingsUiProbeFired(regs: Il2CppPtr) =
  ## Fired from the read-only kind=4 detour on `SettingsScreen::Show`, on the
  ## Unity main thread, with `this` = the live SettingsScreen. Walks the tab
  ## fields + `_currentTab` and each tab's controls. Runs at most once. Writes
  ## nothing.
  let tid = int(cThreadId())
  let selfPtr = cRegsInt(regs, 0'i32)          # RCX = this
  let onHost = (tid == int(gHostThreadId))
  okLog "settings probe: SettingsScreen.Show fired on thread " & $tid &
        " (host thread " & $int(gHostThreadId) & "); this=0x" & hexOf(selfPtr) &
        (if onHost: " -- this IS the host thread (unexpected, NOT Unity's)"
         else: " -- Unity's main thread")
  if onHost or gSettingsUiDone or selfPtr == 0'u64:
    return
  let self = cast[Il2CppPtr](selfPtr)
  if cIsReadable(self, cSuiOffCurrentTab() + 8'i32) == 0'i32:
    okLog "settings probe: this not readable for the tab fields (0x" &
          hexOf(uint64(cSuiOffCurrentTab())) & "); aborting the walk (no write)"
    return
  gSettingsUiDone = true

  # The typed tab fields, then _currentTab. Duplicates (currentTab == one typed
  # field) are skipped so the log is not doubled.
  let tabs = [
    ("game",     cReadPtrAt(self, cSuiOffGameTab())),
    ("graphics", cReadPtrAt(self, cSuiOffGraphicsTab())),
    ("postfx",   cReadPtrAt(self, cSuiOffPostFxTab())),
    ("sound",    cReadPtrAt(self, cSuiOffSoundTab())),
    ("controls", cReadPtrAt(self, cSuiOffControlsTab())),
    ("current",  cReadPtrAt(self, cSuiOffCurrentTab())),
  ]
  var seen: seq[uint64] = @[]
  var tabsWalked = 0
  for pair in tabs:
    let name = pair[0]
    let tp = pair[1]
    if tp == nil:
      okLog "settings probe: tab=" & name & " field is null (not built yet)"
      continue
    let key = cast[uint64](tp)
    var dup = false
    for k in seen:
      if k == key: dup = true
    if dup:
      okLog "settings probe: tab=" & name & " -> 0x" & hexOf(key) &
            " (same object already walked; skipping)"
      continue
    seen.add key
    suiWalkTab(tp, name)
    inc tabsWalked
  okLog "settings probe: walk done -- " & $tabsWalked &
        " distinct tab object(s) examined. Read-only, nothing was written."

proc bindSettingsUiProbe(verbose: bool): bool =
  ## Installs the read-only Phase-1 detour on `SettingsScreen::Show` (kind=4),
  ## from the verified static target in `aowlspt_bridge.h`. Opt-in
  ## (`settingsUiProbe`); binds nothing on a build whose prologue does not match.
  if gSettingsUiSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let count = cBridgeSettingsTargetCount()
  for i in 0 ..< int(count):
    let fn = cBridgeSettingsTargetAt(int32(i))
    if fn == nil:
      if verbose:
        info "settings-UI probe target " & $i & " did not verify on this build"
      continue
    let spec = readCString(cBridgeSettingsTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 4'i32):
      okLog "settings-UI probe (Phase 1) armed on " & spec &
            "; open the in-game settings screen to log its control tree"
      return true
  result = false

# ---------------------------------------------------------------------------
# PHASE 1.8 -- the walk at the method that actually builds the controls
#
# Phases 1 and 1.5 each cost a live cycle and each disproved a guess: at
# `SettingsScreen::Show` no tab has controls, and at a POSTFIX on
# `SettingsScreen::EnsureTabInitialized` they STILL do not, because that method
# only calls each tab's `Show()` -- it builds nothing.
#
# The chain was then settled OFFLINE, from disassembly + metadata alone; the
# full evidence is in `docs/timbuktu/SETTINGS-CONTROLS-RE.md` and the target
# comment in `abi/aowlspt_bridge.h`. In one line:
#
#   ShowScreen(0x1720DE0) -> [tail jmp] set_IsSelected(tab, true) (0x171BCA0)
#     -> vtable slot 0x2C8 OnFirstSelect -> CreateControls
#       -> CreateControl<T> gshared (0x2B86E20), `mov [rsi+0x88], rdi`
#
# `EnsureTabInitialized` is called by ShowScreen ~50 bytes BEFORE that tail
# jump, which is exactly why the Phase-1.5 postfix saw null. So this is the same
# POSTFIX detour (kind=7), moved to `ShowScreen`: RCX is the SettingsScreen, EDX
# is the group, and `_currentTab` (+0x118) -- written just before the tail jump
# -- names the tab whose controls were just built.
#
# Corollary worth remembering: only the SELECTED tab is ever built, so four of
# the five `_createdControls` lists being null is the correct steady state, not
# a failure.
#
# Still read-only, still reflection-free, still every hop cIsReadable-guarded,
# still capped -- and now the whole body runs inside the VEH/SEH guard, so a
# fault cannot take the settings screen (or the client) down with it.
# ---------------------------------------------------------------------------

## Log each group at most once, so clicking back and forth between tabs (which
## re-fires this every time) does not flood the log with the same census.
var gSuiGroupsLogged: array[8, bool]
## Total firings, for the one-line "fired" trace on the first call only.
var gSuiTabFires = 0

## The group -> live tab-object / klass registry, filled by the
## `EnsureTabInitialized` postfix below.
##
## Two jobs. It lets the Phase-1.6 `OnTabSelected` walk NAME the tab it is handed
## (that hook gets the SettingsTab directly and has no group argument), and it is
## the live klass-pointer census: each concrete tab type has its own klass, so
## printing them here is how we confirm type identity at runtime without ever
## touching reflection. Indexed by ESettingsGroup (0..4).
# ---------------------------------------------------------------------------
# THE BREADCRUMB
#
# `aowl_p_p_seh` catches a fault and returns nil. That kept the settings screen
# alive -- and told us nothing whatsoever about WHERE it faulted, so "fault
# caught in the tab walk" appeared twice, the write side disabled itself for the
# session, and there was no way to know which hop had done it.
#
# So: before every step that dereferences something the game owns, the code
# leaves a note saying what it is about to touch and with which pointer. The
# longjmp does not unwind this -- it is an ordinary global -- so the handler's
# caller can read the note and name the exact hop that died.
#
# Declared HERE, in the first of the three settings files, because nimony
# forward-resolves procs across an `include` boundary but NOT variables, and
# `settingswrite.nim` and `settingspages.nim` are both included after this one.
# ---------------------------------------------------------------------------
var gSwCrumb = "(nothing attempted yet)"

proc swCrumb(what: string) =
  ## Leave a note about the hop that is about to happen. Cheap: one string
  ## assignment, and this whole path runs on a tab click, never per frame.
  gSwCrumb = what

proc swCrumbP(what: string; p: Il2CppPtr) =
  gSwCrumb = what & " ptr=0x" & hexOf(cast[uint64](p))

var gSuiTabPtr: array[8, uint64]
var gSuiTabKlass: array[8, uint64]

proc suiTabInitBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_settingstab_body", cdecl.} =
  ## The whole Phase-1.5 walk, called ONLY through `aowl_settingstab_body_guarded`
  ## so any fault inside -- including a read of a valid-looking pointer to an
  ## invalid next pointer, which `cIsReadable` cannot catch -- is trapped and the
  ## settings screen survives. `a` is the detour `regs`. Returns a non-nil
  ## sentinel on clean completion; the guard returns nil if it faulted. Writes
  ## nothing, ever.
  let regs = a
  let tid = int(cThreadId())
  let onHost = (tid == int(gHostThreadId))
  let selfPtr = cRegsInt(regs, 0'i32)          # RCX = this (SettingsScreen)
  # EDX = the ESettingsGroup argument. `cRegsInt` hands back the full 64-bit RDX,
  # so take the low 32 as the game does (`mov esi, edx`) and reinterpret rather
  # than convert -- a plain int32() of a value above 0x7FFFFFFF would overflow.
  let group = cast[int32](uint32(cRegsInt(regs, 1'i32) and 0xFFFFFFFF'u64))
  inc gSuiTabFires
  swBeginVisit()
  swCrumb("STAGE: entered suiTabInitBody")
  if gSuiTabFires == 1:
    okLog "settings probe: ShowScreen (postfix) first fired on thread " &
          $tid & " (host thread " & $int(gHostThreadId) & ")" &
          (if onHost: " -- host thread (unexpected, NOT Unity's)"
           else: " -- Unity's main thread") & "; this=0x" & hexOf(selfPtr)
  if onHost or selfPtr == 0'u64:
    return cast[Il2CppPtr](1)
  gSettingsLiveSelf = cast[Il2CppPtr](selfPtr)

  # THE NATIVE LIFECYCLE RIDER (`settingsNativeLifecycle`). Riding this same
  # detour rather than installing a second one on ShowScreen -- see the flag's
  # own comment in `aowlhost.nim`. A no-op unless `settingsModsTab` AND
  # `settingsNativeLifecycle` are both on. Runs BEFORE any of Phase 1.8's own
  # work below so a fault in that work can never suppress the hide.
  swCrumb("STAGE: modsNativeOnShowScreen group=" & $int(group))
  modsNativeOnShowScreen(group)
  # NATIVE TABS' GRAPHICS SUBTAB STRIP rides this SAME postfix -- it installs
  # NOTHING of its own on ShowScreen. §7.9 / the double-detour rule: a second
  # physical detour here would overwrite this one's trampoline and silently
  # kill Phase 1/2/3. Already inside this body's ONE `aowl_p_p_seh`; it must
  # not open another, and it does not (the guard is not re-entrant, and a
  # nested one DISARMS the outer).
  #
  # This is the ONE place strip visibility and highlight are decided, because
  # it is the only event that fires for all three routes into a group: the
  # player's tab click, our own ShowScreen call, and `OpenGroup` when the
  # screen first opens (§2.7). The toggle edge this replaced could see only
  # the first, which is why the strip never appeared when Settings opened
  # straight onto GRAPHICS.
  swCrumb("STAGE: ntOnShowScreen group=" & $int(group))
  ntOnShowScreen(cast[Il2CppPtr](selfPtr), group)

  let gname = readCString(cSuiGroupName(group))
  let off = cSuiGroupTabOffset(group)
  let alreadyLogged = (group >= 0'i32 and int(group) < gSuiGroupsLogged.len and
                       gSuiGroupsLogged[int(group)])
  if alreadyLogged:
    # Already announced this tab. But this call IS a tab click (OpenGroup ->
    # ShowScreen -> EnsureTabInitialized runs every time, early-returning via the
    # HashSet at +0x138), so it is a free Unity-thread poll opportunity: re-read
    # the registered tabs in case the controls have appeared since.
    #
    # It is ALSO the only moment Phase 2/3 can re-assert themselves on a tab the
    # player has come back to. The original code returned here, which meant the
    # relabel, the value read-back and the pages ran EXACTLY ONCE per tab per
    # session and could never be re-checked or re-applied. That is what made
    # "the model changed but the pixels did not" impossible to tell apart from
    # "the game overwrote us a frame later": nothing ever looked again.
    swCrumb("STAGE: revisit -- suiPollRegisteredTabs")
    suiPollRegisteredTabs()
    let selfR = cast[Il2CppPtr](selfPtr)
    if cIsReadable(selfR, cSuiOffCurrentTab() + 8'i32) != 0'i32:
      let tabR = cReadPtrAt(selfR, cSuiOffCurrentTab())
      if tabR != nil:
        let gnameR = readCString(cSuiGroupName(group))
        # PUBLISH BEFORE Phase 2/3 -- see the identical comment on the
        # first-build path above. A fault in `swOnTabBuilt`/`swPagesOnTabBuilt`
        # below must not be able to take the MODS tab's only tab pointer down
        # with it.
        gModsLastTabPtr = tabR
        gModsLastTabName = gnameR
        swCrumb("STAGE: revisit -- swVerifyRelabel tab=" & gnameR)
        swVerifyRelabel("revisit tab=" & gnameR)
        # `revisit = true` keeps the relabel re-asserting itself while silencing
        # the Phase-2b value census, which would otherwise print thirty lines
        # every time the player clicks a tab. Passed as an ARGUMENT and not set
        # through a global on purpose: nimony forward-resolves procs across an
        # `include` boundary but NOT variables, and this file is included before
        # the one that would own such a global.
        swCrumb("STAGE: revisit -- swOnTabBuilt tab=" & gnameR)
        swOnTabBuilt(tabR, gnameR, true)
        swCrumb("STAGE: revisit -- swPagesOnTabBuilt tab=" & gnameR)
        swPagesOnTabBuilt(tabR, gnameR, true)
    return cast[Il2CppPtr](1)

  let self = cast[Il2CppPtr](selfPtr)
  if cIsReadable(self, cSuiOffCurrentTab() + 8'i32) == 0'i32:
    okLog "settings probe: this not readable at _currentTab (0x" &
          hexOf(uint64(cSuiOffCurrentTab())) & ") for group=" & gname &
          "; aborting (no write)"
    return cast[Il2CppPtr](1)

  # The authoritative tab is `_currentTab` (+0x118): ShowScreen writes it at
  # +0x1720F4E, and only THEN tail-jumps into set_IsSelected, which is what runs
  # OnFirstSelect -> CreateControls -> CreateControl<T> and fills +0x88. At this
  # postfix both have happened. The EDX group is kept only as a cross-check of
  # the metadata-derived tab-field offsets; a mismatch is logged, never fatal.
  let tab = cReadPtrAt(self, cSuiOffCurrentTab())
  if off >= 0'i32 and cIsReadable(self, off + 8'i32) != 0'i32:
    let byGroup = cReadPtrAt(self, off)
    if byGroup != tab:
      okLog "settings probe: NOTE group=" & gname & " field 0x" &
            hexOf(uint64(off)) & " -> 0x" & hexOf(cast[uint64](byGroup)) &
            " but _currentTab -> 0x" & hexOf(cast[uint64](tab)) &
            "; walking _currentTab (the one just selected)"
  if tab == nil:
    okLog "settings probe: _currentTab is still null after ShowScreen(group=" &
          gname & "); nothing walked (no write)"
    return cast[Il2CppPtr](1)

  if group >= 0'i32 and int(group) < gSuiGroupsLogged.len:
    gSuiGroupsLogged[int(group)] = true
  let klass = cast[uint64](cReadPtrAt(tab, 0'i32))
  # Register the tab object + its klass under its group. This is what lets the
  # Phase-1.6 OnTabSelected walk -- which is handed the SettingsTab and no group
  # -- print a real tab NAME, and it doubles as the live klass census.
  if group >= 0'i32 and int(group) < gSuiTabPtr.len:
    gSuiTabPtr[int(group)] = cast[uint64](tab)
    gSuiTabKlass[int(group)] = klass
  okLog "settings probe: tab built -- group=" & gname & " (" & $int(group) &
        ") tab=0x" & hexOf(cast[uint64](tab)) & " klass=0x" & hexOf(klass)
  # At THIS point the controls DO exist. ShowScreen writes `_currentTab` at
  # +0x1720F4E and then TAIL-JUMPS into set_IsSelected(tab, true), which runs
  # OnFirstSelect -> CreateControls -> CreateControl<T>, the only writer of
  # +0x88. A postfix here therefore sees a fully built tab -- confirmed live
  # (78 controls across game/graphics/postfx/sound).
  swCrumb("STAGE: suiWalkTab tab=" & gname)
  suiWalkTab(tab, gname)
  # PUBLISH THE LIVE TAB FOR THE MODS TAB RIGHT HERE -- BEFORE Phase 2/3.
  #
  # THE REGRESSION THIS FIXES: `gModsLastTabPtr` used to be set at the very end
  # of this body, after Phase 2 and Phase 3 ran. Both phases now walk far more
  # controls/rows than before (the row cap went 24 -> 48, subtabs 5 -> 8, and a
  # mod schema's rows are rendered onto this very tab by Phase 3), so a fault in
  # either phase is far likelier -- and when one faults, `aowl_p_p_seh` unwinds
  # this WHOLE body, so the publish at the bottom never runs. The MODS tab is
  # built by `modstab.nim`'s OWN separately-guarded tick, gated on exactly this
  # pointer (`gModsLastTabPtr != nil`, see `modsTabTickBody`) -- so a Phase 2/3
  # fault on ANY tab silently meant the MODS tab could never build AT ALL, for
  # the rest of the session, with no MODS-tab log line to say why. Publishing
  # here, right after Phase 1 confirms the tab is live and walked, means a
  # later fault in Phase 2/3 can no longer take this down with it.
  gModsLastTabPtr = tab
  gModsLastTabName = gname
  # The registry poll stays as a cheap backstop for any tab that somehow lags.
  swCrumb("STAGE: suiPollRegisteredTabs tab=" & gname)
  suiPollRegisteredTabs()
  # PHASE 2 -- the WRITE side, in `settingswrite.nim`. It runs here, inside this
  # body, precisely so it inherits this body's `aowl_p_p_seh` guard rather than
  # arming a second one (that guard is not re-entrant). It does nothing unless
  # `settingsRelabelProbe` or `settingsBindProbe` is set, and it disables itself
  # after two faults.
  swCrumb("STAGE: swVerifyRelabel (build) tab=" & gname)
  swVerifyRelabel("build tab=" & gname)
  swCrumb("STAGE: swOnTabBuilt (build) tab=" & gname)
  swOnTabBuilt(tab, gname, false)
  # PHASE 3 -- the per-mod settings PAGES, rendered by cloning stock controls.
  # Same guard, same fault budget, same default-OFF discipline; it renders only
  # onto the Game tab and only when `settingsPages` is set.
  swCrumb("STAGE: swPagesOnTabBuilt (build) tab=" & gname)
  swPagesOnTabBuilt(tab, gname, false)
  return cast[Il2CppPtr](1)

# The VEH/SEH guard thunk, the same mechanism botdiag/botcap use: `aowl_p_p_seh`
# (abi/aowlspt_shim.h) arms a vectored exception handler + setjmp, calls the
# body, and returns nil instead of letting an access violation propagate. A
# probe fault must NEVER reach the settings screen, so the WHOLE body goes
# through here.
{.emit: """
extern void* aowl_settingstab_body(void* a);
static void* aowl_settingstab_body_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_settingstab_body, a);
}
""".}
proc cSettingsTabBodyGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_settingstab_body_guarded", nodecl.}

proc settingsTabInitFired(regs: Il2CppPtr) =
  ## Dispatched by slot identity from `patchReturned` (the POSTFIX half) for the
  ## kind=7 detour. Runs the walk under the VEH/SEH guard and logs the catch if
  ## it faulted, so the settings screen keeps working either way.
  if cSettingsTabBodyGuarded(regs) == nil:
    warn "settings probe: fault caught in the tab walk -- the VEH guard kept " &
         "the settings screen alive. LAST HOP ATTEMPTED: " & gSwCrumb &
         ". That is the operation that faulted; everything before it completed."
    # Phase 2 may have been the half that faulted, and it is the half that
    # writes, so it spends a fault from its budget and switches itself off once
    # the budget is gone. The read probe is unaffected.
    swNoteFault()

proc bindSettingsTabProbe(verbose: bool): bool =
  ## Installs the read-only POSTFIX detour (kind=7) on
  ## `SettingsScreen::ShowScreen` from the verified static target in
  ## `aowlspt_bridge.h`. Shares the `settingsUiProbe` flag with the Phase-1 `Show`
  ## hook; binds nothing on a build whose prologue does not match.
  if gSettingsTabSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let count = cBridgeSettingsTabTargetCount()
  for i in 0 ..< int(count):
    let fn = cBridgeSettingsTabTargetAt(int32(i))
    if fn == nil:
      if verbose:
        info "settings tab-init target " & $i & " did not verify on this build"
      continue
    let spec = readCString(cBridgeSettingsTabTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 7'i32,
                   true, cBridgeSettingsTabTargetSlots(int32(i))):
      okLog "settings-UI control probe (Phase 1.8) armed POSTFIX on " & spec &
            "; open Settings and click each tab -- every control's label, klass " &
            "and value-widget pointer is logged as the tab is built"
      return true
  result = false

# ---------------------------------------------------------------------------
# PHASE 1.7 -- stop chasing the trigger; take a heartbeat and LOOK
#
# Three live rounds have now disproved one trigger guess each:
#   * `Show` fires before any controls exist (Phase 1);
#   * `EnsureTabInitialized` hands over real tab objects whose control list is
#     still null, and it PRE-WARMS all five tabs the moment the screen opens,
#     unprompted (Phase 1.5);
#   * `SettingsTab::OnTabSelected` never fired AT ALL across five real tab
#     clicks (Phase 1.6). A full cross-reference of the 81MB `il2cpp` segment --
#     the section the generated code actually lives in, `.text` holds none of
#     it -- finds ZERO callers of it. It is dead code in this build. The same
#     scan finds zero direct callers of every tab's Show / OnFirstSelect /
#     CreateControls, because they are all vtable-dispatched. So no static
#     cross-reference can name the trigger, and every further guess costs a
#     whole deploy-and-click cycle to disprove.
#
# So this stops asking WHEN and simply LOOKS, repeatedly, from a Unity-thread
# heartbeat (`GameSettingsTab::Update`, which Unity drives every frame for as
# long as the settings screen is up). Two jobs, both pure reads:
#
#   1. POLL -- re-read each registered tab's `_createdControls` (+0x88) on a
#      throttle and log the full census the first time it is non-empty.
#      Whatever fills it, and whenever, we see it.
#   2. FIND -- if a tab has been polled `cSuiScanAfter` times and 0x88 is STILL
#      null, scan that tab object's fields once and report every slot shaped
#      like a populated `List<T>`, decoding the first element through the known
#      control-label chain. If the controls live at some other offset, this
#      prints that offset AND the label proving it -- which ends the guessing
#      for good, from a single run, still without reflection.
#
# Read-only throughout, every hop cIsReadable-guarded, every loop capped, the
# whole body under the VEH/SEH guard, gated on `settingsUiProbe`.
# ---------------------------------------------------------------------------

## Poll every Nth tick, so the per-frame cost is a counter increment almost
## always, and a handful of guarded reads a few times a second at most.
const cSuiTickEvery = 20
## After this many polls with the list still null, run the one-shot field scan.
const cSuiScanAfter = 3
## Field-scan window over the tab object: offsets 0x10 .. 0x200, 8-byte steps.
const cSuiScanFrom = 0x10
const cSuiScanTo = 0x200
## Most List-shaped candidates reported per tab, so a pathological object cannot
## turn one scan into a hundred log lines.
const cSuiMaxCandidates = 12

var gSuiTicks = 0
## Per-group: whether its census has been logged, how many times it has been
## polled, and whether its one-shot field scan has already run.
var gSuiCensused: array[8, bool]
var gSuiPolls: array[8, int]
var gSuiScanned: array[8, bool]

proc suiListAt(obj: Il2CppPtr; off: int32; size: var int32): Il2CppPtr =
  ## If `obj+off` looks like a POPULATED `List<T>`, return its backing array and
  ## set `size`; otherwise nil. "Looks like" is deliberately strict, because the
  ## point of the scan is to report signal rather than noise: the slot must be a
  ## readable pointer, `_size` (+0x18) must be a small positive count, `_items`
  ## (+0x10) must be a readable array object, and that array's element count
  ## (+0x18, right before the inline elements at +0x20) must be at least
  ## `_size`. All pure reads, each one guarded.
  size = 0'i32
  if cIsReadable(obj, off + 8'i32) == 0'i32:
    return nil
  let lst = cReadPtrAt(obj, off)
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    return nil
  let n = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if n <= 0'i32 or n > 512'i32:
    return nil
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  if arr == nil or cIsReadable(arr, cSuiOffArrElems() + 8'i32) == 0'i32:
    return nil
  let maxLen = cReadI32At(suiPtrAdd(arr, 0x18'i32))
  if maxLen < n or maxLen > 4096'i32:
    return nil
  size = n
  result = arr

proc suiScanTabFields(tabPtr: Il2CppPtr; tabName: string) =
  ## ONE-SHOT empirical field scan: report every offset in the tab object that
  ## holds a populated List, with the first element's klass and -- decisively --
  ## whatever the control-label chain decodes at that element. A slot that
  ## prints a real settings label IS the created-controls list, whatever offset
  ## it turns out to live at. Reads only; writes nothing.
  okLog "settings probe: FIELD SCAN of tab=" & tabName & " obj=0x" &
        hexOf(cast[uint64](tabPtr)) & " -- _createdControls (0x" &
        hexOf(uint64(cSuiOffCreatedCtrls())) & ") is still null after " &
        $cSuiScanAfter & " polls, so every List-shaped field is reported here"
  var found = 0
  var off = int32(cSuiScanFrom)
  while off < int32(cSuiScanTo) and found < cSuiMaxCandidates:
    var n = 0'i32
    let arr = suiListAt(tabPtr, off, n)
    if arr != nil:
      var detail = ""
      let slot = suiPtrAdd(arr, cSuiOffArrElems())
      if cIsReadable(slot, 8'i32) != 0'i32:
        let elem0 = cReadPtrAt(slot, 0'i32)
        if elem0 != nil and cIsReadable(elem0, 8'i32) != 0'i32:
          let ek = cast[uint64](cReadPtrAt(elem0, 0'i32))
          let lbl = suiReadControlLabel(elem0)
          detail = " elem0=0x" & hexOf(cast[uint64](elem0)) &
                   " klass=0x" & hexOf(ek) &
                   (if lbl.len > 0:
                      " label='" & lbl & "'  <== LOOKS LIKE THE CONTROL LIST"
                    else: " (no label decoded here)")
      okLog "settings probe:   candidate list at +0x" & hexOf(uint64(off)) &
            " size=" & $int(n) & detail
      inc found
    off = off + 8'i32
  if found == 0:
    okLog "settings probe:   no List-shaped field anywhere in 0x" &
          hexOf(uint64(cSuiScanFrom)) & "..0x" & hexOf(uint64(cSuiScanTo)) &
          " -- this tab holds no populated collection at all yet"
  else:
    okLog "settings probe:   field scan done -- " & $found &
          " candidate(s); the one printing a real label is the control list"

proc suiPollRegisteredTabs() =
  ## Re-read every registered tab's control list. Logs a tab's census once, the
  ## first time it is non-empty, and falls back to the one-shot field scan for a
  ## tab that stays stubbornly null. Shared by the frame tick and by the
  ## `EnsureTabInitialized` postfix, so tab CLICKS poll too, not only frames.
  for g in 0 ..< gSuiTabPtr.len:
    let raw = gSuiTabPtr[g]
    if raw == 0'u64 or gSuiCensused[g]:
      continue
    let tab = cast[Il2CppPtr](raw)
    let name = readCString(cSuiGroupName(int32(g)))
    var n = 0'i32
    let arr = suiListAt(tab, cSuiOffCreatedCtrls(), n)
    if arr != nil:
      gSuiCensused[g] = true
      okLog "settings probe: controls APPEARED for tab=" & name & " after " &
            $gSuiPolls[g] & " poll(s) -- walking them now"
      suiWalkTab(tab, name)
    else:
      gSuiPolls[g] = gSuiPolls[g] + 1
      if gSuiPolls[g] >= cSuiScanAfter and not gSuiScanned[g]:
        gSuiScanned[g] = true
        suiScanTabFields(tab, name)

proc suiTickBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_settingstick_body", cdecl.} =
  ## The throttled heartbeat body, called ONLY through the VEH/SEH guard. `a` is
  ## the detour `regs`; nothing in it is read, because the poll walks the
  ## registry rather than `this`. Returns a non-nil sentinel on clean
  ## completion. Writes nothing, ever.
  let tid = int(cThreadId())
  if tid == int(gHostThreadId):
    return cast[Il2CppPtr](1)
  inc gSuiTicks
  if (gSuiTicks mod cSuiTickEvery) != 0:
    return cast[Il2CppPtr](1)
  if gSuiTicks == cSuiTickEvery:
    okLog "settings probe: Unity-thread tick is live on thread " & $tid &
          " -- polling each registered tab's control list from here"
  suiPollRegisteredTabs()
  return cast[Il2CppPtr](1)

# The VEH/SEH guard thunk -- same mechanism as every other host detour body.
{.emit: """
extern void* aowl_settingstick_body(void* a);
static void* aowl_settingstick_body_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_settingstick_body, a);
}
""".}
proc cSettingsTickBodyGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_settingstick_body_guarded", nodecl.}

proc settingsTickFired(regs: Il2CppPtr) =
  ## Dispatched by slot identity from `patchFired` for the kind=8 tick detour.
  if cSettingsTickBodyGuarded(regs) == nil:
    okLog "settings probe: fault caught in the tick poll -- the VEH guard kept " &
          "the settings screen alive (nothing was written)"

proc bindSettingsTickProbe(verbose: bool): bool =
  ## Installs the read-only PREFIX tick (kind=8) on `GameSettingsTab::Update`.
  ## Reuses the slot the dead Phase-1.6 `OnTabSelected` hook held, so this costs
  ## no new slot. Shares the `settingsUiProbe` flag; binds nothing on a build
  ## whose prologue does not match.
  if gSettingsSelSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let count = cBridgeSettingsSelTargetCount()
  for i in 0 ..< int(count):
    let fn = cBridgeSettingsSelTargetAt(int32(i))
    if fn == nil:
      if verbose:
        info "settings tick target " & $i & " did not verify on this build"
      continue
    let spec = readCString(cBridgeSettingsSelTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 8'i32):
      okLog "settings-UI CONTROL poll (Phase 1.7) armed on " & spec &
            "; it polls every registered tab's control list once per " &
            $cSuiTickEvery & " frames while Settings is open, and field-scans " &
            "any tab that stays empty -- so the controls get reported whenever " &
            "they appear, whatever creates them"
      return true
  result = false
