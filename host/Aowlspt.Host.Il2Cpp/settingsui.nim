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
