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

## Phase 1.5 target: the tab BUILDER, hooked postfix.
proc cBridgeSettingsTabTargetCount(): int32 {.
  importc: "aowl_bridge_settingstab_target_count", nodecl.}
proc cBridgeSettingsTabTargetAt(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_settingstab_target_at", nodecl.}
proc cBridgeSettingsTabTargetName(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_settingstab_target_name", nodecl.}

# The slot/flag/guard globals (gSettingsUiSlot / gSettingsUiProbe /
# gSettingsUiDone) are declared in aowlhost.nim beside the other detour slots.

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
          " _createdControls list is null/unreadable (tab likely not " &
          "initialized yet -- expected before it is first opened)"
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
# PHASE 1.5 -- the walk that actually finds controls
#
# Phase 1 proved the mechanism and disproved the timing: `Show` fires on the
# Unity thread with a readable `this`, but every tab's `_createdControls` is
# still null there. Controls are built lazily by
# `SettingsScreen::EnsureTabInitialized(this, ESettingsGroup)`, which `OpenGroup`
# calls on every tab switch (and which returns early, via a HashSet at +0x138,
# once a group has been built).
#
# So this is a POSTFIX detour (kind=7) on that method: the entry registers are
# still the entry registers (the thunk saved them), so RCX is `this` and EDX is
# the group -- but the body has already run, so the tab's controls EXIST. The
# group tells us exactly which tab field to read, so we walk that one tab rather
# than re-guessing all five.
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
  if gSuiTabFires == 1:
    okLog "settings probe: EnsureTabInitialized (postfix) first fired on thread " &
          $tid & " (host thread " & $int(gHostThreadId) & ")" &
          (if onHost: " -- host thread (unexpected, NOT Unity's)"
           else: " -- Unity's main thread") & "; this=0x" & hexOf(selfPtr)
  if onHost or selfPtr == 0'u64:
    return cast[Il2CppPtr](1)

  let gname = readCString(cSuiGroupName(group))
  let off = cSuiGroupTabOffset(group)
  if off < 0'i32:
    okLog "settings probe: EnsureTabInitialized group=" & $int(group) &
          " is outside the known 0..4 mapping; nothing walked (no write)"
    return cast[Il2CppPtr](1)
  if group >= 0'i32 and int(group) < gSuiGroupsLogged.len and
     gSuiGroupsLogged[int(group)]:
    return cast[Il2CppPtr](1)     # already censused this tab; stay quiet

  let self = cast[Il2CppPtr](selfPtr)
  if cIsReadable(self, off + 8'i32) == 0'i32:
    okLog "settings probe: this not readable at the tab field 0x" &
          hexOf(uint64(off)) & " for group=" & gname & "; aborting (no write)"
    return cast[Il2CppPtr](1)
  let tab = cReadPtrAt(self, off)
  if tab == nil:
    okLog "settings probe: group=" & gname & " tab field (0x" &
          hexOf(uint64(off)) & ") is still null after EnsureTabInitialized"
    return cast[Il2CppPtr](1)

  if group >= 0'i32 and int(group) < gSuiGroupsLogged.len:
    gSuiGroupsLogged[int(group)] = true
  okLog "settings probe: tab built -- group=" & gname & " (" & $int(group) &
        ") tab=0x" & hexOf(cast[uint64](tab)) & " klass=0x" &
        hexOf(cast[uint64](cReadPtrAt(tab, 0'i32)))
  suiWalkTab(tab, gname)
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
    okLog "settings probe: fault caught in the tab walk -- the VEH guard kept " &
          "the settings screen alive (nothing was written)"

proc bindSettingsTabProbe(verbose: bool): bool =
  ## Installs the read-only POSTFIX detour (kind=7) on
  ## `SettingsScreen::EnsureTabInitialized` from the verified static target in
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
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 7'i32, true):
      okLog "settings-UI control probe (Phase 1.5) armed POSTFIX on " & spec &
            "; open Settings and click each tab -- every control's label, klass " &
            "and value-widget pointer is logged as the tab is built"
      return true
  result = false
