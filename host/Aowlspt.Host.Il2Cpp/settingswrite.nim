# settingswrite.nim -- PHASE 2: writing into Tarkov's REAL settings screen.
#
# `include`d into `aowlhost.nim` AFTER `settingsui.nim`, `invoke2.nim` and
# `debugui.nim`, which is the whole reason it is a file of its own: it needs all
# three of them at once and none of them needs it.
#
#   * from `settingsui.nim` -- `suiReadString`, `suiPtrAdd`, the settings-tree
#     offsets, and the live tab walk this hangs off;
#   * from `debugui.nim`    -- `cDuWriteU8` / `cDuWriteF32`, the guarded scalar
#     stores, and the `newString` + raw-`m_text` + dirty-flag recipe that is
#     PROVEN live (it is how the F3 overlay puts text on screen);
#   * from `aowlhost.nim`   -- `cUxWritePtr`, `cIsReadable`, `cReadPtrAt`,
#     `okLog`/`warn`, `hexOf`, `readBoolKey`.
#
# WHAT PHASE 2 IS FOR
# -------------------
# Phase 1 ended with 78 controls read off the real screen: labels decoded, klass
# pointers censused, widget pointers in hand. That proved we can SEE the settings
# screen. It proved nothing about changing it. Phase 2 is the two smallest
# possible proofs that we can:
#
#   2a RELABEL -- find the control whose stock label is 'FOV:' and make it read
#      'FOV: [aowlspt]'. One String allocation, one reference store into
#      `m_text`, one dirty byte. If that appears on screen, the write path into
#      the real settings screen is open, and it is open through the exact
#      primitive the version brand and the F3 overlay already use in production.
#
#   2b BIND -- read a real control's VALUE out of its widget and write one back.
#      A toggle first, because its value is a single bool at a known offset and
#      there is nothing to quantise or clamp.
#
# Both are flag-gated, default OFF, capped, and every hop is guarded. Neither
# runs unless the config asks for it.
#
# WHAT A RAW VALUE WRITE DOES NOT DO (stated here so nobody re-learns it live)
# ---------------------------------------------------------------------------
# Text repaints from a dirty flag, so a text write is COMPLETE and visible.
# A Toggle repaints from `Toggle::Set` and a Slider from `Slider::UpdateVisuals`
# -- neither of which a field store calls. So writing `m_IsOn` changes what the
# game reads and does NOT move the checkmark. That is fine for Phase 2b, whose
# job is to prove the value round-trips, and it is why 2b LOGS what it read and
# writes only when explicitly asked. The visual half is a direct RVA call and
# belongs to Phase 3, not here.

# ---- offsets + the guarded byte read (abi/aowlspt_settingswrite.h) ----
proc cSwOffToggleIsOn(): int32 {.importc: "aowl_sw_off_toggle_ison", nodecl.}
proc cSwOffNsSlider(): int32 {.importc: "aowl_sw_off_ns_slider", nodecl.}
proc cSwOffNsMin(): int32 {.importc: "aowl_sw_off_ns_min", nodecl.}
proc cSwOffNsMax(): int32 {.importc: "aowl_sw_off_ns_max", nodecl.}
proc cSwOffSliderValue(): int32 {.importc: "aowl_sw_off_slider_value", nodecl.}
proc cSwOffSliderMin(): int32 {.importc: "aowl_sw_off_slider_min", nodecl.}
proc cSwOffSliderMax(): int32 {.importc: "aowl_sw_off_slider_max", nodecl.}
proc cSwOffSliderWhole(): int32 {.importc: "aowl_sw_off_slider_whole", nodecl.}
proc cSwOffTmpDirty(): int32 {.importc: "aowl_sw_off_tmp_dirty", nodecl.}
proc cSwReadU8(p: Il2CppPtr; off: int32): int32 {.
  importc: "aowl_sw_read_u8", nodecl.}
proc cSwAnchorFloat(): Il2CppPtr {.importc: "aowl_sw_anchor_float", nodecl.}
proc cSwAnchorToggle(): Il2CppPtr {.importc: "aowl_sw_anchor_toggle", nodecl.}
proc cSwAnchorDropdown(): Il2CppPtr {.importc: "aowl_sw_anchor_dropdown", nodecl.}
proc cSwAnchorSelect(): Il2CppPtr {.importc: "aowl_sw_anchor_select", nodecl.}

# ---------------------------------------------------------------------------
# Flags and fault budget
# ---------------------------------------------------------------------------

## `settingsRelabelProbe` -- Phase 2a. Default OFF.
var gSwRelabel = false
## `settingsBindProbe` -- Phase 2b. Default OFF.
var gSwBind = false

## Self-disable after this many faults, counted by the caller of the guarded
## body. A write path that faults twice has proved it does not understand this
## build, and the right response is to stop writing, not to keep trying every
## time the player opens a tab.
## The fault budget.
##
## It used to be TWO, for the whole session. Live, Phase 3 cloned two rows,
## faulted, and the entire feature switched itself off permanently -- every
## later tab reported "the Phase-2/3 fault budget is spent". A budget that small
## is right for a probe that pokes one label and wrong for a renderer that
## builds dozens of rows: one bad row must not end the session.
##
## So the budget is now counted PER TAB VISIT, with a much larger hard ceiling
## across the session so a genuinely broken build still stops eventually rather
## than faulting forever.
const cSwMaxFaultsPerVisit = 4
const cSwMaxFaultsTotal    = 40
var gSwFaults = 0
var gSwVisitFaults = 0
var gSwOff = false

## Relabel at most this many controls per tab, so a schema or a match bug cannot
## turn one tab open into hundreds of String allocations.
const cSwMaxRelabels = 8

## The suffix Phase 2a appends. Deliberately unmistakable and deliberately NOT a
## replacement of the whole label: keeping the stock text and adding to it means
## a successful write is obvious AND the control still says what it controls.
const cSwBrandSuffix = " [aowlspt]"

# ---------------------------------------------------------------------------
# Per-session klass census
#
# The export ABI is token-gated on this build, so a control's TYPE is learned
# by observation: the klass pointer at obj+0x00 is stable within one process,
# and the live census found exactly four distinct values across all 78
# controls. Every control the census passes is typed by pointer equality
# against the four learned klasses.
#
# HOW A KLASS IS LEARNED, in order:
#
# 1. BY ITS TYPE NAME (`swLearnKlassByName`): the Il2CppClass's name and
#    namespace are read with page checks and verified against the offline
#    name index -- the same reader the inspector's `components` verb uses --
#    and compared with the four exact `EFT.UI.Settings.Setting*` names. This
#    is identity, not a caption, so it holds in every locale and on every tab.
# 2. BY A CAPTION ANCHOR (the header's `AOWL_SW_ANCHOR_*`), kept as the
#    fallback. MEASURED 2026-09-05 15:30 (host a220e060279c): the toggle
#    anchor is 'Enable VoIP' and the dropdown anchor is 'Device:', both SOUND
#    tab captions -- so on a first visit to Settings -> Game the census had
#    learned only the float slider ('FOV:'), the host page's donor fell back
#    to "the most common klass on the tab" (16 dropdown rows), all 13 of its
#    toggle rows were drawn as dropdown clones that the seeding refuses and
#    the read-back therefore skips, and the page could not persist anything.
#    The Game tab has 7 stock toggle rows (Automatic RAM Cleaner .. Helmet
#    Camera Mode); only the caption match was missing.
#
# Zero means "not learned yet on this launch".
# ---------------------------------------------------------------------------
var gSwKlassFloat: uint64 = 0
var gSwKlassToggle: uint64 = 0
var gSwKlassDropdown: uint64 = 0
var gSwKlassSelect: uint64 = 0

## Three decimals is enough to tell an FOV of 50 from 50.5 and a normalised
## 0..1 volume from a raw one, and it avoids `$` on a float, which is not the
## idiom this host uses (see `duFmt2`/`duFmt1` in the overlay).
proc swFmt(v: float64): string = formatFloat(v, ffDecimal, 3)

proc swKlassName(k: uint64): string =
  ## The learned name of a klass pointer, or "?" if this launch has not met an
  ## anchor for it yet. Never guesses.
  if k == 0'u64:
    result = "?"
  elif k == gSwKlassFloat: result = "float-slider"
  elif k == gSwKlassToggle: result = "toggle"
  elif k == gSwKlassDropdown: result = "dropdown"
  elif k == gSwKlassSelect: result = "select-slider"
  else: result = "?"

# Forward-declared; implemented in `inspect.nim`, which is `include`d after
# the components header it needs is emitted. Returns "" when the klass has no
# readable name; `known` says whether the offline name index has it.
proc swKlassFullName(k: uint64; known: var bool): string

var gSwKlassSeen: seq[uint64] = @[]   ## klasses already asked for a name (cap 32)
## THE TOGGLE WIDGET'S KLASS -- the UnityEngine.UI.Toggle-derived component
## at `control + cSuiOffCtrlValue()` of a SettingToggle ROW. Not the row's
## own klass (`gSwKlassToggle`), which is what `swSeedToggle` used to compare
## it against. MEASURED 2026-09-06 13:25 (host 499ea1e6a998): with the row
## klass finally learned, "NOT seeding a toggle value -- the cloned row's
## widget klass is 0x209e2b2a1e0 and the learned toggle klass is
## 0x209e2bd24a0 (the donor is not a toggle)" -- a compare of two different
## objects' types that could never be equal, so no row was ever seeded and
## the read-back (which reads only seeded rows) never persisted anything.
var gSwKlassToggleWidget: uint64 = 0
var gSwToggleWidgetSaid = false

# Forward-declared; implemented in `inspect.nim` (the klass-chain walker
# through the offline name index lives there). 1 = the widget IS a
# UnityEngine.UI.Toggle (or derives from one), 0 = it is not, -1 = unknown.
proc swWidgetIsToggle(widget: Il2CppPtr; chain: var string): int

proc swLearnKlassByName(klass: uint64) =
  ## Step 1 of the census (see the block comment above): type the klass by
  ## its own name, once per distinct klass per launch. Learns ONLY a name the
  ## offline index verifies -- a readable string that is not a known type is
  ## refused and said, never trusted.
  if klass == 0'u64:
    return
  if klass == gSwKlassFloat or klass == gSwKlassToggle or
     klass == gSwKlassDropdown or klass == gSwKlassSelect:
    return
  var i = 0
  while i < gSwKlassSeen.len:
    if gSwKlassSeen[i] == klass:
      return
    i = i + 1
  if gSwKlassSeen.len >= 32:            # rule 4: capped; a tab has four
    return
  gSwKlassSeen.add klass
  var known = false
  let nm = swKlassFullName(klass, known)
  if nm.len == 0:
    okLog "settings write: klass 0x" & hexOf(klass) & " has no readable " &
          "type name, so it can only be learned from a caption anchor"
    return
  if not known:
    okLog "settings write: klass 0x" & hexOf(klass) & " reads type '" & nm &
          "', which the offline name index does NOT know -- refusing to " &
          "learn from it; a caption anchor may still type it"
    return
  var slot = ""
  if nm == "EFT.UI.Settings.SettingFloatSlider":
    if gSwKlassFloat == 0'u64:
      gSwKlassFloat = klass
      slot = "float-slider"
  elif nm == "EFT.UI.Settings.SettingToggle":
    if gSwKlassToggle == 0'u64:
      gSwKlassToggle = klass
      slot = "toggle"
  elif nm == "EFT.UI.Settings.SettingDropDown":
    if gSwKlassDropdown == 0'u64:
      gSwKlassDropdown = klass
      slot = "dropdown"
  elif nm == "EFT.UI.Settings.SettingSelectSlider":
    if gSwKlassSelect == 0'u64:
      gSwKlassSelect = klass
      slot = "select-slider"
  if slot.len > 0:
    okLog "settings write: learned " & slot & " klass = 0x" & hexOf(klass) &
          " from its TYPE NAME '" & nm & "' (verified against the offline " &
          "name index) -- no caption anchor needed, so a first visit to " &
          "any tab types every row control it carries"

proc swLearnKlass(label: string; klass: uint64) =
  ## Teach the census from one control: by its type name first, then -- if
  ## its label is an anchor and that anchor is not already learned -- by the
  ## caption. Logged the first time each is learned, so the boot log shows
  ## exactly which types this session can recognise, and how.
  if klass == 0'u64:
    return
  swLearnKlassByName(klass)
  if label.len == 0:
    return
  if gSwKlassFloat == 0'u64 and label == readCString(cSwAnchorFloat()):
    gSwKlassFloat = klass
    okLog "settings write: learned float-slider klass = 0x" & hexOf(klass) &
          " from the stock label '" & label & "'"
  elif gSwKlassToggle == 0'u64 and label == readCString(cSwAnchorToggle()):
    gSwKlassToggle = klass
    okLog "settings write: learned toggle klass = 0x" & hexOf(klass) &
          " from the stock label '" & label & "'"
  elif gSwKlassDropdown == 0'u64 and label == readCString(cSwAnchorDropdown()):
    gSwKlassDropdown = klass
    okLog "settings write: learned dropdown klass = 0x" & hexOf(klass) &
          " from the stock label '" & label & "'"
  elif gSwKlassSelect == 0'u64 and label == readCString(cSwAnchorSelect()):
    gSwKlassSelect = klass
    okLog "settings write: learned select-slider klass = 0x" & hexOf(klass) &
          " from the stock label '" & label & "'"

# ---------------------------------------------------------------------------
# The label chain, as a WRITEABLE handle
#
# `suiReadString` decodes a label; this returns the TMP component the label
# lives on, which is what a write needs. Same hops, same guards -- the read
# probe validated every one of them live against real stock labels, which is
# what makes writing through them defensible at all.
# ---------------------------------------------------------------------------
proc swControlTmp(control: Il2CppPtr): Il2CppPtr =
  ## control.Text(+0x80) -> LocalizedText -> _labels(+0x78) List<TMP> -> [0].
  ## nil on any unreadable hop; never dereferences unguarded.
  result = nil
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
  let tmp0 = cReadPtrAt(tmpArr, cSuiOffArrElems())
  if tmp0 == nil or cIsReadable(tmp0, cSuiOffTmpMText() + 8'i32) == 0'i32:
    return
  result = tmp0

## Carries the text into `swNewStringImpl`. A global rather than an argument for
## the same reason `gBrandText` and `gDuStrText` are: the guarded alloc thunk
## carries exactly one pointer.
var gSwStrText: string = ""

proc swNewStringImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_sw_newstring", cdecl.} =
  ## Allocates the managed `System.String` for `gSwStrText` via
  ## `il2cpp_string_new` -- the ONE runtime export proven to work on this build's
  ## Unity thread (the version brand does exactly this in production).
  ##
  ## NOT separately SEH-guarded, and that is deliberate: every caller already
  ## runs inside the settings postfix's `aowl_p_p_seh`, and that guard is not
  ## re-entrant -- a nested one would disarm the outer on return and leave the
  ## rest of the body unprotected. Same reasoning, same comment, as
  ## `duNewStringImpl`.
  result = newString(gRt, gSwStrText)

## The Phase-3 setter table is declared in `settingspages.nim`, which is
## `include`d after this file; these three entries are needed HERE, by the
## relabel, so they are declared here and the constants restated. Duplicating
## three importc lines is cheaper than reordering two files.
proc cSwFn2(i: int32): Il2CppPtr {.importc: "aowl_sw_fn", nodecl.}
proc cSwName2(i: int32): Il2CppPtr {.importc: "aowl_sw_name", nodecl.}
proc cSwCallVPP(fn, self, arg: Il2CppPtr) {.importc: "aowl_sw_call_v_pp", nodecl.}
proc cSwCallVPB2(fn, self: Il2CppPtr; b: int32) {.
  importc: "aowl_sw_call_v_pb", nodecl.}

const
  SwLocSetLabelText = 6'i32            ## EFT.UI.LocalizedText::SetLabelText
  SwTmpSetText      = 7'i32            ## TMPro.TMP_Text::set_text
  SwTmpSetDirty     = 8'i32            ## TMPro.TMP_Text::set_havePropertiesChanged

## Announce, once, which of the three repaint routes verified on this build --
## so a relabel that does not appear can be read against what was available
## rather than guessed at.
var gSwRepaintLogged = false

proc swRepaintCensus() =
  if gSwRepaintLogged:
    return
  gSwRepaintLogged = true
  var line = "settings write: repaint routes on this build --"
  var i = SwLocSetLabelText
  while i <= SwTmpSetDirty:
    line = line & " " & readCString(cSwName2(i)) & "=" &
           (if cSwFn2(i) != nil: "OK" else: "REJECTED")
    i = i + 1'i32
  okLog line

proc swSetTmpTextByCall(tmp: Il2CppPtr; s: Il2CppPtr): bool =
  ## Put an already-allocated managed String on a TMP by CALLING the property
  ## setter, then poke the repaint through the real `set_havePropertiesChanged`
  ## rather than the raw byte. Returns false if neither call verified.
  result = false
  let fnSet = cSwFn2(SwTmpSetText)
  if fnSet != nil:
    cSwCallVPP(fnSet, tmp, s)
    result = true
  let fnDirty = cSwFn2(SwTmpSetDirty)
  if fnDirty != nil:
    cSwCallVPB2(fnDirty, tmp, 1'i32)

proc swSetLocalizedText(control: Il2CppPtr; s: Il2CppPtr): bool =
  ## Write at the LOCALIZEDTEXT level -- `SettingControl.Text` (+0x80) ->
  ## `EFT.UI.LocalizedText`, then `SetLabelText(String)`, the method the game's
  ## own `UpdateLocale` calls. This is the level cause (b) would otherwise
  ## clobber us from, and it is the setter the game itself trusts to repaint.
  result = false
  let fn = cSwFn2(SwLocSetLabelText)
  if fn == nil or control == nil or s == nil:
    return
  if cIsReadable(control, cSuiOffCtrlText() + 8'i32) == 0'i32:
    return
  let locText = cReadPtrAt(control, cSuiOffCtrlText())
  if locText == nil or cIsReadable(locText, cSuiOffLocTextList() + 8'i32) == 0'i32:
    return
  cSwCallVPP(fn, locText, s)
  result = true

proc swSetTmpText(tmp: Il2CppPtr; text: string): bool =
  ## Put `text` on a live TextMeshPro component by the PROVEN recipe: allocate a
  ## managed String, RAW-WRITE its pointer into `m_text` (+0xE0), then set
  ## `m_havePropertiesChanged` (+0x378) so TMP re-lays it out on its next tick.
  ## No runtime_invoke, no reflection, no method lookup.
  ##
  ## Returns false and writes NOTHING if the allocation failed or the slot is not
  ## safely writable -- a stock label is always an acceptable outcome.
  result = false
  if tmp == nil or text.len == 0:
    return
  gSwStrText = text
  let s = swNewStringImpl(cast[Il2CppPtr](0))
  if s == nil or cIsReadable(s, 0x14'i32) == 0'i32:
    warn "settings write: il2cpp_string_new returned nothing usable; the " &
         "label is left exactly as the game wrote it"
    return
  if cUxWritePtr(tmp, cSuiOffTmpMText(), s) == 0'i32:
    warn "settings write: m_text (+0x" & hexOf(uint64(cSuiOffTmpMText())) &
         ") was not safely writable; nothing was written"
    return
  discard cDuWriteU8(tmp, cSwOffTmpDirty(), 1'i32)
  result = true

## Names the routes the last relabel actually took, for the log line.
var gSwLastRoutes = ""

proc swRelabelControl(control, tmp: Il2CppPtr; text: string): bool =
  ## Relabel one control by CALLING the game's own setters, with the raw store
  ## kept only as the last resort.
  ##
  ## Order matters and is the whole fix:
  ##   1. `LocalizedText::SetLabelText` -- the level the game writes at. If the
  ##      row was reverting because LocalizedText re-applied its own string
  ##      (cause b), writing here is writing where it writes.
  ##   2. `TMP_Text::set_text` + `set_havePropertiesChanged` -- the real
  ##      property setter and the real repaint latch. If the row was correct in
  ##      the model and stale on screen (cause a), this is what rebuilds it.
  ##   3. the raw `m_text` store + dirty byte, unchanged, for a build where
  ##      neither prologue verifies.
  ##
  ## One String allocation feeds all three, so the belt and the braces cost one
  ## allocation between them, not three.
  result = false
  gSwLastRoutes = ""
  if tmp == nil or text.len == 0:
    return
  swRepaintCensus()
  gSwStrText = text
  let s = swNewStringImpl(cast[Il2CppPtr](0))
  if s == nil or cIsReadable(s, 0x14'i32) == 0'i32:
    warn "settings write: il2cpp_string_new returned nothing usable; the " &
         "label is left exactly as the game wrote it"
    return
  if swSetLocalizedText(control, s):
    gSwLastRoutes = gSwLastRoutes & "LocalizedText::SetLabelText "
    result = true
  if swSetTmpTextByCall(tmp, s):
    gSwLastRoutes = gSwLastRoutes & "TMP_Text::set_text "
    result = true
  if not result:
    if cUxWritePtr(tmp, cSuiOffTmpMText(), s) == 0'i32:
      warn "settings write: no setter verified AND m_text (+0x" &
           hexOf(uint64(cSuiOffTmpMText())) & ") was not safely writable; " &
           "nothing was written"
      return
    discard cDuWriteU8(tmp, cSwOffTmpDirty(), 1'i32)
    gSwLastRoutes = "raw m_text store + dirty byte (no setter verified) "
    result = true

# ---------------------------------------------------------------------------
# PHASE 2a -- the first VISIBLE proof
#
# Find the control labelled 'FOV:' and make it read 'FOV: [aowlspt]'.
#
# Idempotent by construction: the suffix is only appended to a label that does
# not already end in it, so clicking away and back -- which re-fires the whole
# postfix -- neither doubles the suffix nor reallocates a String.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# THE RELABEL VERDICT
#
# The previous build logged a successful relabel -- and then read the new value
# back THROUGH the new label in the same breath, so `m_text` provably held our
# String at that instant. The row on screen still said 'FOV:'. Two completely
# different causes produce exactly that, and no amount of reasoning separates
# them:
#
#   (a) NO REPAINT. The dirty byte we poke is the wrong field, or is not enough
#       on its own. The model is ours forever and the mesh is never rebuilt.
#   (b) OVERWRITE. `LocalizedText` re-applies its localised string a moment
#       later -- on enable, on a localisation refresh, on the next layout pass --
#       and our store is gone before a single frame is drawn.
#
# The difference is observable and only observable: re-read `m_text` LATER. If it
# still holds our string, the store survived and the pixels are stale -> (a). If
# it has reverted to 'FOV:', something overwrote us -> (b).
#
# So the host remembers what it wrote and to which component, and re-reads it on
# the next settings-postfix firing -- which, since this build, includes every
# RE-VISIT to a tab, not just the first. The verdict is printed in plain words.
# ---------------------------------------------------------------------------
var gSwWatchTmp: Il2CppPtr = nil
var gSwWatchWant: string = ""
var gSwWatchChecks = 0
const cSwMaxWatchChecks = 12

proc swVerifyRelabel(occasion: string) =
  ## Re-read the watched label and say, in words, which of the two causes this
  ## build is suffering from. Pure read; never writes, never faults unguarded.
  if gSwWatchTmp == nil or gSwWatchWant.len == 0:
    return
  if gSwWatchChecks >= cSwMaxWatchChecks:
    return
  gSwWatchChecks = gSwWatchChecks + 1
  if cIsReadable(gSwWatchTmp, cSuiOffTmpMText() + 8'i32) == 0'i32:
    okLog "settings write: VERDICT (" & occasion & ") the watched TMP at 0x" &
          hexOf(cast[uint64](gSwWatchTmp)) & " is no longer readable -- the " &
          "control was destroyed and rebuilt, which is itself cause (b): the " &
          "game replaced the row under us"
    gSwWatchTmp = nil
    return
  let now = suiReadString(cReadPtrAt(gSwWatchTmp, cSuiOffTmpMText()))
  if now == gSwWatchWant:
    okLog "settings write: VERDICT (" & occasion & ") m_text STILL HOLDS '" &
          now & "'. The store survived, so this is cause (a) NO REPAINT -- the " &
          "model is ours and TMP never rebuilt its mesh. The fix is the real " &
          "setter / a forced mesh update, not the dirty byte."
  else:
    okLog "settings write: VERDICT (" & occasion & ") m_text has REVERTED to '" &
          now & "' (we wrote '" & gSwWatchWant & "'). This is cause (b) " &
          "OVERWRITE -- LocalizedText re-applied its own string over ours. " &
          "The relabel is re-applied on every tab visit from this build, so " &
          "watch whether it now sticks."

proc swEndsWithBrand(s: string): bool =
  ## True if `s` already carries the suffix. Hand-rolled rather than
  ## `endsWith` so this file depends on nothing but what the host already has.
  result = false
  if s.len < cSwBrandSuffix.len:
    return
  let base = s.len - cSwBrandSuffix.len
  for i in 0 ..< cSwBrandSuffix.len:
    if s[base + i] != cSwBrandSuffix[i]:
      return
  result = true

proc swRelabelTab(tabPtr: Il2CppPtr; tabName: string; revisit: bool): int =
  ## Walk the tab's `_createdControls` and brand the anchor control. Returns how
  ## many labels were rewritten (0 or 1 in practice -- the cap is a safety net,
  ## not an expectation).
  ##
  ## The walk is a deliberate copy of `suiWalkTab`'s shape rather than a
  ## refactor of it: the read probe must stay a pure read that can be trusted on
  ## its own, and a shared helper that sometimes writes would take that away.
  result = 0
  if tabPtr == nil or cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) == 0'i32:
    return
  let lst = cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    return
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if arr == nil or size <= 0'i32:
    return
  let n = (if size > int32(cSuiMaxControls): int32(cSuiMaxControls) else: size)
  let anchor = readCString(cSwAnchorFloat())
  for i in 0 ..< int(n):
    if result >= cSwMaxRelabels:
      break
    swCrumb("STAGE: swRelabelTab tab=" & tabName & " control[" & $i & "] of " &
            $n)
    let slot = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) == 0'i32:
      continue
    let control = cReadPtrAt(slot, 0'i32)
    if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
      continue
    let tmp = swControlTmp(control)
    if tmp == nil:
      continue
    let label = suiReadString(cReadPtrAt(tmp, cSuiOffTmpMText()))
    # Learn the type census from every control we pass, branded or not: this is
    # the cheapest place to do it and Phase 2b/3 need it.
    swLearnKlass(label, cast[uint64](cReadPtrAt(control, 0'i32)))
    # Match the STOCK label or the label we already branded. Matching only the
    # stock one meant that after a successful write the host could never find
    # its own row again -- so it could never re-apply it, and could never notice
    # that the game had put the stock string back.
    if label != anchor and label != anchor & cSwBrandSuffix:
      continue
    if swEndsWithBrand(label):
      gSwWatchTmp = tmp
      gSwWatchWant = label
      okLog "settings write: tab=" & tabName & " control[" & $i & "] is already " &
            "branded ('" & label & "'); nothing rewritten (still watching it)"
      return
    if swRelabelControl(control, tmp, label & cSwBrandSuffix):
      gSwWatchTmp = tmp
      gSwWatchWant = label & cSwBrandSuffix
      gSwWatchChecks = 0
      okLog "settings write: PHASE 2a tab=" & tabName & " control[" & $i &
            "] relabelled '" & label & "' -> '" & label & cSwBrandSuffix &
            "' (tmp=0x" & hexOf(cast[uint64](tmp)) & ") via " & gSwLastRoutes
      result = result + 1
  if result == 0 and not revisit:
    okLog "settings write: PHASE 2a tab=" & tabName & " has no control " &
          "labelled '" & anchor & "'; nothing was written (this is expected on " &
          "every tab but Game)"

# ---------------------------------------------------------------------------
# PHASE 2b -- bind a real control to a value, both directions
#
# A TOGGLE first: its value is one bool at a known offset on the widget the
# control already hands us at +0xA8, so there is nothing to quantise, clamp or
# reformat, and a wrong answer is unambiguous rather than merely off by a bit.
#
# READ is unconditional when the flag is on -- reading is what proves the offset.
# WRITE is the second half and is done only to a control the host is certain of,
# and only to flip it to a value taken from the host config, so the round trip
# is observable: set the flag, open the tab, read the log, and the value the
# config asked for is the value the widget now holds.
# ---------------------------------------------------------------------------

proc swReadToggle(control: Il2CppPtr; ok: var bool): bool =
  ## The bool behind a SettingToggle: control.Toggle(+0xA8) -> UpdatableToggle ->
  ## m_IsOn(+0x120). `ok` distinguishes "read false" from "could not read",
  ## which a bare bool cannot and which is the whole reason the byte reader
  ## returns -1 rather than 0 on a miss.
  ok = false
  result = false
  if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
    return
  let widget = cReadPtrAt(control, cSuiOffCtrlValue())
  if widget == nil or cIsReadable(widget, cSwOffToggleIsOn() + 4'i32) == 0'i32:
    return
  let b = cSwReadU8(widget, cSwOffToggleIsOn())
  if b < 0'i32:
    return
  ok = true
  result = (b != 0'i32)

proc swWriteToggle(control: Il2CppPtr; value: bool): bool =
  ## Set one bool on a SettingToggle's widget -- BY CALLING THE GAME, not by
  ## storing (INTERACTION-LAYER-MAP M3, and the settings map).
  ##
  ## THIS USED TO BE A RAW `m_IsOn@0x120` STORE, and its own comment admitted
  ## the defect: "the checkmark does NOT move". A model that is right while the
  ## screen is wrong, reported as success, is the check-that-cannot-fail shape
  ## (CLAUDE.md 9b) -- and it is the third time this exact trap appeared in
  ## this feature. `Toggle::Set(value, sendCallback: FALSE)` @0x55BA450 moves
  ## the checkmark and runs the Animator; sendCallback stays FALSE because
  ## nothing the host issues may present itself to the game as a player press.
  ##
  ## `frRecvOk` is the type gate: there is no offset to bound when the callee
  ## chooses it, so the receiver's TYPE is the whole of the protection, and it
  ## is the thing that was missing in both 2026-09-02 crash dumps.
  result = false
  if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
    return
  let widget = cReadPtrAt(control, cSuiOffCtrlValue())
  if widget == nil or cIsReadable(widget, cSwOffToggleIsOn() + 4'i32) == 0'i32:
    return
  # The widget is the control's own declared value component, so its klass is a
  # fact about the layout rather than a guess about the contents.
  discard frAdmit("settingswrite/toggle", frToggleIsOn(), widget)
  if not frRecvOk("settingswrite/toggle", frToggleIsOn(), widget):
    return
  result = nuToggleSetQuiet(widget, value)

proc swReadFloatSlider(control: Il2CppPtr; ok: var bool;
                       value, lo, hi: var float64) =
  ## The float behind a SettingFloatSlider: control.Slider(+0xA8) -> NumberSlider
  ## -> _slider(+0x80) -> UnityEngine.UI.Slider -> m_Value(+0x120), with the
  ## bounds beside it. Read-only; every hop guarded.
  ok = false
  value = 0.0
  lo = 0.0
  hi = 0.0
  if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
    return
  let ns = cReadPtrAt(control, cSuiOffCtrlValue())
  if ns == nil or cIsReadable(ns, cSwOffNsSlider() + 8'i32) == 0'i32:
    return
  let sl = cReadPtrAt(ns, cSwOffNsSlider())
  if sl == nil or cIsReadable(sl, cSwOffSliderValue() + 4'i32) == 0'i32:
    return
  value = cReadF32At(suiPtrAdd(sl, cSwOffSliderValue()))
  lo = cReadF32At(suiPtrAdd(sl, cSwOffSliderMin()))
  hi = cReadF32At(suiPtrAdd(sl, cSwOffSliderMax()))
  ok = true

proc swBindTab(tabPtr: Il2CppPtr; tabName: string) =
  ## Phase 2b: for every control on the tab whose type this session has learned,
  ## READ its live value and log it beside its label. This is the half that
  ## validates the widget offsets against real, user-visible state -- if the log
  ## says 'Enable VoIP = false' and the screen shows it unchecked, the offset is
  ## right, and no amount of further reasoning is worth more than that.
  ##
  ## Pure reads. The write half is `swWriteToggle`, which Phase 3 drives from a
  ## schema; nothing here writes a value.
  if tabPtr == nil or cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) == 0'i32:
    return
  let lst = cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    return
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if arr == nil or size <= 0'i32:
    return
  let n = (if size > int32(cSuiMaxControls): int32(cSuiMaxControls) else: size)
  var toggles = 0
  var sliders = 0
  for i in 0 ..< int(n):
    swCrumb("STAGE: swBindTab tab=" & tabName & " control[" & $i & "] of " &
            $n)
    let slot = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) == 0'i32:
      continue
    let control = cReadPtrAt(slot, 0'i32)
    if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
      continue
    let klass = cast[uint64](cReadPtrAt(control, 0'i32))
    let tmp = swControlTmp(control)
    let label = (if tmp != nil:
                   suiReadString(cReadPtrAt(tmp, cSuiOffTmpMText()))
                 else: "")
    swLearnKlass(label, klass)
    if gSwKlassToggle != 0'u64 and klass == gSwKlassToggle:
      var ok = false
      let v = swReadToggle(control, ok)
      if ok:
        okLog "settings write: PHASE 2b tab=" & tabName & " toggle '" & label &
              "' = " & (if v: "true" else: "false")
        toggles = toggles + 1
      else:
        okLog "settings write: PHASE 2b tab=" & tabName & " toggle '" & label &
              "' -- m_IsOn (+0x" & hexOf(uint64(cSwOffToggleIsOn())) &
              ") was not readable; skipped (nothing written)"
    elif gSwKlassFloat != 0'u64 and klass == gSwKlassFloat:
      var ok = false
      var v = 0.0
      var lo = 0.0
      var hi = 0.0
      swReadFloatSlider(control, ok, v, lo, hi)
      if ok:
        okLog "settings write: PHASE 2b tab=" & tabName & " float-slider '" &
              label & "' = " & swFmt(v) & " (range " & swFmt(lo) & ".." &
              swFmt(hi) & ")"
        sliders = sliders + 1
      else:
        okLog "settings write: PHASE 2b tab=" & tabName & " float-slider '" &
              label & "' -- the Slider hop was not readable; skipped"
  okLog "settings write: PHASE 2b tab=" & tabName & " read " & $toggles &
        " toggle(s) and " & $sliders & " float slider(s) live. Read-only."

# ---------------------------------------------------------------------------
# The entry point, called from the settings postfix
#
# It runs INSIDE `suiTabInitBody`, which is already wrapped in `aowl_p_p_seh`.
# So there is deliberately no second guard here -- `aowl_p_p_seh` is not
# re-entrant and nesting one would disarm the outer guard on return, leaving the
# rest of the settings body unprotected. The fault BUDGET is still enforced,
# from the outer guard's verdict, by `swNoteFault` below.
# ---------------------------------------------------------------------------

proc swLearnTabKlasses(tabPtr: Il2CppPtr) =
  ## Walk a tab READ-ONLY and teach the klass census from every control on it.
  ## Phase 3 calls this for itself so that `settingsPages` does not silently
  ## depend on a Phase 2 flag also being set -- which is exactly the kind of
  ## undeclared coupling that turns a feature into a silent no-op.
  if tabPtr == nil or cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) == 0'i32:
    return
  let lst = cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    return
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if arr == nil or size <= 0'i32:
    return
  let n = (if size > int32(cSuiMaxControls): int32(cSuiMaxControls) else: size)
  for i in 0 ..< int(n):
    let slot = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) == 0'i32:
      continue
    let control = cReadPtrAt(slot, 0'i32)
    if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
      continue
    let tmp = swControlTmp(control)
    if tmp == nil:
      continue
    swLearnKlass(suiReadString(cReadPtrAt(tmp, cSuiOffTmpMText())),
                 cast[uint64](cReadPtrAt(control, 0'i32)))

proc swOnTabBuilt(tabPtr: Il2CppPtr; tabName: string; revisit: bool) =
  ## Phase 2, driven off the same ShowScreen postfix the Phase-1.8 read probe
  ## uses. Does nothing at all unless a flag asks for it and the fault budget is
  ## intact.
  if swVisitBlocked() or tabPtr == nil:
    return
  if not (gSwRelabel or gSwBind):
    return
  if gSwRelabel:
    swCrumb("STAGE: swRelabelTab tab=" & tabName)
    discard swRelabelTab(tabPtr, tabName, revisit)
  if gSwBind and not revisit:
    swCrumb("STAGE: swBindTab tab=" & tabName)
    swBindTab(tabPtr, tabName)

proc swBeginVisit() =
  ## Called at the top of every settings-postfix firing. Re-arms the per-visit
  ## budget, so a tab that faulted last time gets a fresh chance this time.
  ## Only the SESSION ceiling is permanent.
  gSwVisitFaults = 0
  gSwCrumb = "(nothing attempted yet on this tab visit)"

proc swVisitBlocked(): bool =
  ## True when this visit has spent its own budget, or the session ceiling has
  ## been reached. The distinction matters: the first is temporary and the
  ## second is not.
  result = gSwOff or gSwVisitFaults >= cSwMaxFaultsPerVisit

proc swNoteFault() =
  ## Called when the outer VEH guard caught a fault while Phase 2/3 was armed.
  ##
  ## The old rule was two faults and the feature was over for the session. That
  ## is what happened live: two rows cloned, a fault, and everything after it
  ## declined with "the fault budget is spent". A renderer that builds dozens of
  ## rows needs a budget that survives one bad row, so the per-visit budget stops
  ## only THIS visit and the session ceiling is set far higher.
  gSwFaults = gSwFaults + 1
  gSwVisitFaults = gSwVisitFaults + 1
  warn "settings write: fault " & $gSwVisitFaults & " of " &
       $cSwMaxFaultsPerVisit & " on this tab visit (" & $gSwFaults & " of " &
       $cSwMaxFaultsTotal & " this session). LAST HOP ATTEMPTED: " & gSwCrumb
  if gSwFaults >= cSwMaxFaultsTotal and not gSwOff:
    gSwOff = true
    warn "settings write: DISABLED after " & $gSwFaults & " fault(s) this " &
         "session -- the session ceiling. The settings screen keeps working " &
         "and the game keeps its own labels and values; nothing further is " &
         "written this session."
  elif gSwVisitFaults >= cSwMaxFaultsPerVisit:
    warn "settings write: this TAB VISIT has spent its budget and will not " &
         "write again until the tab is re-opened. The feature is NOT disabled " &
         "for the session (" & $gSwFaults & " of " & $cSwMaxFaultsTotal &
         " faults used)."
