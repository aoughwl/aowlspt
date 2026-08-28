# graphicssubtabs.nim -- native Graphics > {General, PostFX} subtabs.
#
# STATUS: increment 1 of N. This ships the two pieces that can be established
# WITHOUT running the game -- the polled-mouse interaction primitive (in
# nativeui.nim) and the pure strip/selection state machine
# (graphicssubtabs_pure.nim, offline-tested) -- plus a DISCOVERY-ONLY live hook
# that walks to the Graphics tab's content and LOGS what is really there.
#
# It deliberately BUILDS NOTHING yet. This feature has failed twice, both times
# by assuming a tree shape that was not there (fact #104: a `Graphics/Settings`
# child that does not exist, faulted 4-of-4 and self-disabled) or by cloning
# native toggles that came out dead (fact #117: m_Group=0, no ToggleGroup, so a
# real click never set m_IsOn). The lesson both taught is: DISCOVER the real
# tree from a live object and confirm it on screen BEFORE building against it.
# So increment 1 discovers and reports; the coordinator confirms the logged
# tree live; increment 2 builds the strip from scratch (real ToggleGroup or
# host-driven selection via the polled mouse) against a tree we have seen.
#
# Because it builds nothing, it cannot self-disable destructively the way #104's
# did -- there is no stock control it hides, nothing to leave the player without.
#
# Included AFTER modstab.nim, so it stands on: nativeui's nuGameObjectOf /
# nuTransformOf / nuMousePos / nuHitTest; inspect's iChildCount / iChildAt /
# iObjName; settingsui's createdCtrls offset; and this file's own pure core.

include "graphicssubtabs_pure.nim"

const GfxSubMaxFaults = 4

var gGfxSubtabs = false        ## the `graphicsSubtabs` flag; default OFF
var gGfxSubDone = false        ## discovery has run for the Graphics group once
var gGfxSubFaults = 0
var gGfxSubSel = GfxSubGeneral ## host-tracked active subtab (increment 2 uses it)
var gGfxProbeTab: Il2CppPtr = nil

proc gfxSubtabsWanted(): bool =
  ## Riders on invoke2's postfix ask this before doing anything. OFF by default,
  ## and one-shot: once the Graphics group has been discovered it stops.
  gGfxSubtabs and not gGfxSubDone and gGfxSubFaults < GfxSubMaxFaults

proc gfxDiscoverBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_gfx_discover_body", cdecl.} =
  ## `a` is the Graphics tab pointer the ladder already resolved. Everything
  ## here is READ-ONLY: no allocation, no SetActive, no write. Every hop is
  ## readability-checked; a missing node is a NAMED refusal, never a fault.
  result = cast[Il2CppPtr](1)   # non-nil => the guard saw us return normally
  let tab = a
  if tab == nil or cIsReadable(tab, 0x20'i32) == 0'i32:
    warn "graphicsSubtabs: REFUSE -- the Graphics tab pointer is null or " &
         "unreadable (SettingsScreen+0xF8 read nothing live). Nothing built."
    return

  # The tab is a SettingsTab component. Reach its GameObject, then its Transform,
  # by CALLING the game's own accessors -- not by an offset that can read null
  # (fact: SettingsTab._rectTransform@0x78 reads null; walk instead).
  let go = nuGameObjectOf(tab)
  if go == nil or cIsReadable(go, 0x10'i32) == 0'i32:
    warn "graphicsSubtabs: REFUSE -- Component::get_gameObject on the Graphics " &
         "tab did not yield a readable GameObject; cannot discover its content. " &
         "Nothing built."
    return
  let tr = nuTransformOf(go)
  if tr == nil or cIsReadable(tr, 0x20'i32) == 0'i32:
    warn "graphicsSubtabs: REFUSE -- GameObject::get_transform on the Graphics " &
         "tab GameObject did not yield a readable Transform. Nothing built."
    return

  okLog "graphicsSubtabs: DISCOVERY -- Graphics tab=0x" & hexOf(cast[uint64](tab)) &
        " go=0x" & hexOf(cast[uint64](go)) & " (\"" & iObjName(go) &
        "\") tr=0x" & hexOf(cast[uint64](tr))

  # The createdCtrls list count -- the controls the game built into this tab.
  # Zero would mean the postfix fired before the controls existed (it should
  # not, being a postfix), so it is worth stating either way.
  let ctrlsOff = cSuiOffCreatedCtrls()
  if cIsReadable(tab, ctrlsOff + 8'i32) != 0'i32:
    let lst = cReadPtrAt(tab, ctrlsOff)
    if lst != nil and cIsReadable(lst, 0x20'i32) != 0'i32:
      # List`1._size sits at 0x18 on this build's layout; read only its low 32
      # bits, and present it as INDICATIVE -- a raw slot read is evidence, not
      # proof (CLAUDE.md 9b), so it is logged, never iterated on.
      let raw = cast[uint64](cReadPtrAt(lst, 0x18'i32))
      let cnt = int32(raw and 0xFFFFFFFF'u64)
      okLog "graphicsSubtabs: DISCOVERY -- createdCtrls list=0x" &
            hexOf(cast[uint64](lst)) & " (raw _size-slot@0x18 reads " & $int(cnt) &
            "; indicative only, confirm live)"
    else:
      info "graphicsSubtabs: DISCOVERY -- createdCtrls list is null/unreadable"

  # The direct children of the Graphics tab transform, bounded. This is the tree
  # the coordinator confirms with the inspector before increment 2 builds a
  # strip and a PostFX panel as siblings of the General content.
  var n = 0
  if not iChildCount(tr, n):
    warn "graphicsSubtabs: REFUSE -- child count of the Graphics tab transform " &
         "could not be read. Nothing built."
    return
  okLog "graphicsSubtabs: DISCOVERY -- Graphics tab transform has " & $n &
        " direct child(ren); listing up to 24:"
  var i = 0
  let cap = (if n > 24: 24 else: n)
  while i < cap:
    let ch = iChildAt(tr, i)
    if ch != nil and cIsReadable(ch, 0x20'i32) != 0'i32:
      okLog "graphicsSubtabs:   child[" & $i & "] = \"" & iObjName(ch) &
            "\" @0x" & hexOf(cast[uint64](ch))
    else:
      info "graphicsSubtabs:   child[" & $i & "] unreadable"
    inc i
  okLog "graphicsSubtabs: DISCOVERY COMPLETE. This is READ-ONLY; no UI was " &
        "built. Confirm this tree live, then increment 2 builds the strip."
  gGfxProbeTab = tab

{.emit: """
extern void* aowl_gfx_discover_body(void* a);
static void* aowl_gfx_discover_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_gfx_discover_body, a);
}
""".}
proc cGfxDiscoverGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_gfx_discover_guarded", nodecl.}

proc gfxSubtabsProbe(group: int32; tab: Il2CppPtr) =
  ## Called from invoke2's ladder postfix (a drain, not a second hook). Acts
  ## only for the Graphics group; every other group is a silent no-op so this
  ## never interferes with the other tabs.
  if not gfxSubtabsWanted(): return
  if group != 0'i32:      # 0 == graphics, per aowl_sui_group_name
    return
  gGfxSubDone = true      # one discovery per session, whatever the outcome
  # ONE aowl_p_p_seh around the whole read-only body. Not nested: the ladder's
  # per-step guards and nuProofRun's guard have all returned before we get here.
  if cGfxDiscoverGuarded(tab) == nil:
    inc gGfxSubFaults
    warn "graphicsSubtabs: DISCOVERY FAULTED (fault " & $gGfxSubFaults & " of " &
         $GfxSubMaxFaults & ") -- the VEH guard caught it and the game " &
         "survived. The last `graphicsSubtabs: DISCOVERY` line above names how " &
         "far the walk got. Nothing was built, so nothing is left half-done."
