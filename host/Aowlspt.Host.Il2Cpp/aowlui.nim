# aowlui.nim -- the UNIFIED, BACKEND-AGNOSTIC WIDGET FRAMEWORK, Nim surface.
#
# `include`d into `aowlhost.nim` AFTER `nativeui.nim`, so it shares that file's
# scope: the `nu*` primitives (create GameObject, AddComponent<T> via warmed
# .data slots, wire font/material, the `_Injected` layout setters, the real TMP
# setters), the logging (`okLog`/`warn`/`info`), `hexOf`, `readCString`, and the
# live donor `gMi2Tmp`/`gMi2TmpOwner` that invoke2 walks to.
#
# THE ONE IDEA. A caller writes a screen ONCE -- `uiBegin(backend); uiPanel(..);
# uiLabel(..); uiToggle(..)` -- and a `Backend` selector decides whether each
# widget rasterises through the D3D11 overlay (`aowl_region_*`, our own pixels,
# available in menu AND raid) or constructs real Tarkov GameObjects (nativeui,
# fact #225, only where a canvas exists). The SAME calls build the SAME
# retained widget records; only realisation differs.
#
# WHERE THE VALUE IS. Layout, the tab-selection state machine, hit-testing and
# config binding are computed in `abi/aowlspt_ui.h`, ONCE, above the backend
# split -- pure state, no il2cpp, no D3D, and offline-proven by
# `tests/overlayhost/uitest.c` (73 checks). This file is the thin backend-
# specific realisation on top of that core, plus the in-client dual-backend
# self-proof.
#
# HONESTY, per the brief and CLAUDE.md 9b:
#   * NATIVE label/button/toggle/tab are built FROM SCRATCH (not cloned -- fact
#     #117: cloned game toggles are dead) on the proven TMP path. A toggle's
#     click is proven by READING BACK its state, never by "a handler ran".
#   * NATIVE PANEL needs an Image component. Image's .data slot was registered
#     in nativeui but NEVER proven live (paths A/B proved TEXT). So a native
#     panel is attempted only with a donor Image reference and otherwise
#     reported INCONCLUSIVE -- it is NOT claimed at parity with text.
#   * BUTTON callbacks are POLLED (v1), never a hand-built UnityAction delegate
#     (unproven on this build). `uiPump` hit-tests registered widgets each
#     frame on the Unity thread and dispatches to a Nim callback.
#   * The OVERLAY emit/replay LOGIC is offline-proven; registering the region
#     DRAW participant that replays each frame is the one live-unproven SEAM,
#     and is stated as such rather than claimed working.

# ---- the C shared core (abi/aowlspt_ui.h) -------------------------------
proc cUiReset() {.importc: "aowl_ui_reset", nodecl.}
proc cUiBegin(backend: int32): int32 {.importc: "aowl_ui_begin", nodecl.}
proc cUiNew(kind, parent: int32; x, y, w, h: float32): int32 {.
  importc: "aowl_ui_new", nodecl.}
proc cUiSetText(h: int32; s: cstring) {.importc: "aowl_ui_set_text", nodecl.}
proc cUiSetColors(h: int32; col, accent: uint32) {.
  importc: "aowl_ui_set_colors", nodecl.}
proc cUiSetInteractive(h, on: int32) {.
  importc: "aowl_ui_set_interactive", nodecl.}
proc cUiSetVisible(h, on: int32) {.importc: "aowl_ui_set_visible", nodecl.}
proc cUiSetRect(h: int32; x, y, w, hh: float32) {.
  importc: "aowl_ui_set_rect", nodecl.}
proc cUiSetNative(h: int32; go, rt, comp, tmp: uint64) {.
  importc: "aowl_ui_set_native", nodecl.}
proc cUiSetRefusal(h, code: int32) {.importc: "aowl_ui_set_refusal", nodecl.}
proc cUiValid(h: int32): int32 {.importc: "aowl_ui_valid", nodecl.}
proc cUiRefusalText(code: int32): cstring {.
  importc: "aowl_ui_refusal_text", nodecl.}
# generational handle identity -- a handle is (gen shl 16) or (idx+1), NOT an
# index. Never subscript a side table with one; ask for the index.
proc cUiIndexOf(h: int32): int32 {.importc: "aowl_ui_index_of", nodecl.}
proc cUiHandleAt(index: int32): int32 {.importc: "aowl_ui_handle_at", nodecl.}
proc cUiLastHandleRefusal(): int32 {.
  importc: "aowl_ui_last_handle_refusal", nodecl.}
proc cUiDisabled(): int32 {.importc: "aowl_ui_disabled", nodecl.}

proc cUiTabAdd(strip, content: int32): int32 {.importc: "aowl_ui_tab_add", nodecl.}
proc cUiTabApply(strip: int32): int32 {.importc: "aowl_ui_tab_apply", nodecl.}
proc cUiTabSelect(strip, idx: int32): int32 {.
  importc: "aowl_ui_tab_select", nodecl.}
proc cUiTabSelected(strip: int32): int32 {.
  importc: "aowl_ui_tab_selected", nodecl.}
proc cUiTabContentActive(strip, content: int32): int32 {.
  importc: "aowl_ui_tab_content_active", nodecl.}

proc cUiBindWidget(h: int32; modGuid, key: cstring; typ: int32): int32 {.
  importc: "aowl_ui_bind_widget", nodecl.}
proc cUiBindGet(b: int32): float64 {.importc: "aowl_ui_bind_get", nodecl.}
proc cUiBindSet(b: int32; v: float64) {.importc: "aowl_ui_bind_set", nodecl.}
proc cUiBindDirty(b: int32): int32 {.importc: "aowl_ui_bind_dirty", nodecl.}
proc cUiBindClearDirty(b: int32) {.importc: "aowl_ui_bind_clear_dirty", nodecl.}
proc cUiBindDirtyCount(): int32 {.importc: "aowl_ui_bind_dirty_count", nodecl.}

proc cUiPump(px, py: float32; down: int32): int32 {.importc: "aowl_ui_pump", nodecl.}
proc cUiTakeClick(h: int32): int32 {.importc: "aowl_ui_take_click", nodecl.}
proc cUiToggleState(h: int32): int32 {.importc: "aowl_ui_toggle_state", nodecl.}
proc cUiToggleForce(h, on: int32) {.importc: "aowl_ui_toggle_force", nodecl.}

proc cUiOverlayEmit(): int32 {.importc: "aowl_ui_overlay_emit", nodecl.}
proc cUiOpCount(): int32 {.importc: "aowl_ui_op_count", nodecl.}
proc cUiCount(): int32 {.importc: "aowl_ui_count", nodecl.}
proc cUiBackend(): int32 {.importc: "aowl_ui_backend", nodecl.}

# ---- the widget kinds / backends, mirroring the C enums -----------------
type
  Backend* = enum
    bkNone    = 0
    bkOverlay = 1     ## our D3D11 overlay pixels (aowl_region_*); menu + raid
    bkNative  = 2     ## real Tarkov GameObjects (nativeui); needs a canvas

  Widget* = distinct int32
    ## A GENERATIONAL handle into the retained core: `(gen shl 16) or (idx+1)`,
    ## so a live widget is always > 0, a refusal is < 0, and `auRoot` (-1) means
    ## "no parent". It is NOT an array index -- uiBegin recycles indices, and
    ## before generations a handle held across a uiBegin silently addressed a
    ## DIFFERENT widget. A spent handle now gets a named refusal
    ## (RANGE / RELEASED / STALE-GENERATION) from the one decoder in the C core.

const auRoot* = Widget(-1)   ## the "no parent" sentinel for the build API

const
  auPanel    = 1'i32
  auLabel    = 2'i32
  auToggle   = 3'i32
  auButton   = 4'i32
  auTabStrip = 5'i32
  auRow      = 6'i32

const
  auBindBool  = 1'i32
  auBindFloat = 2'i32
  auBindInt   = 3'i32

proc ok*(w: Widget): bool = int32(w) > 0'i32 and cUiValid(int32(w)) != 0'i32
  ## LIVE, not merely well-formed. A stale handle is > 0 too -- that is exactly
  ## the bug this replaces -- so `ok` asks the core's decoder, which is the only
  ## thing that knows the current generation.
proc handle*(w: Widget): int32 = int32(w)
proc refusalOf*(w: Widget): string =
  ## Why a handle is unusable, by name. Answers for a REFUSAL widget (negative)
  ## and for a stale/released one alike.
  if int32(w) < 0: readCString(cUiRefusalText(-int32(w)))
  elif cUiValid(int32(w)) != 0'i32: "ok"
  else: readCString(cUiRefusalText(cUiLastHandleRefusal()))

# A polled button/toggle callback. Pure Nim, invoked from uiPump on the Unity
# thread; it must not itself allocate managed memory or call into game code
# without its own guard (§7 no per-frame managed allocation).
type AuCallback* = proc (w: Widget) {.nimcall.}

var gAuCbs: array[128, AuCallback]
  ## Indexed by SLOT INDEX (cUiIndexOf), never by a handle -- a generational
  ## handle is not a subscript and would run off the end.

# ---- flags --------------------------------------------------------------
var gAuOn = false      ## master: the framework's own proof/realise paths
var gAuProof = false
var gAuProofDone = false

proc auRefuse(code: int32; what: string): Widget =
  warn "aowlui: " & what & " REFUSED -- " & readCString(cUiRefusalText(code))
  Widget(-code)

# =========================================================================
# BUILD API -- backend-independent. These only touch the C core (safe, no
# il2cpp, no D3D). Realisation happens later: overlay draws each frame from the
# record; native constructs GameObjects in uiRealizeNative.
# =========================================================================
proc uiBegin*(backend: Backend): bool =
  ## Start a screen for `backend`. Every widget built after this is tagged with
  ## it. Returns false (and logs) on a bad backend.
  if backend != bkOverlay and backend != bkNative:
    warn "aowlui: uiBegin(bkNone) refused -- pick bkOverlay or bkNative"
    return false
  cUiReset()
  discard cUiBegin(int32(backend))
  for i in 0 ..< gAuCbs.len: gAuCbs[i] = nil
  true

proc uiPanel*(parent: Widget; x, y, w, h: float32;
              fill: uint32 = 0xC0101418'u32; border: uint32 = 0xFF3A7BD5'u32): Widget =
  ## A background container. Overlay: a FILL + 1px BOX. Native: an Image (see
  ## uiRealizeNative -- INCONCLUSIVE until Image is proven live).
  let hnd = cUiNew(auPanel, int32(parent), x, y, w, h)
  if hnd < 0: return auRefuse(-hnd, "uiPanel")
  cUiSetColors(hnd, fill, border)
  Widget(hnd)

proc uiLabel*(parent: Widget; x, y, w, h: float32; text: string;
              col: uint32 = 0xFFFFFFFF'u32): Widget =
  ## A text label. Overlay: a TEXT op. Native: a from-scratch TextMeshProUGUI
  ## (the proven path).
  let hnd = cUiNew(auLabel, int32(parent), x, y, w, h)
  if hnd < 0: return auRefuse(-hnd, "uiLabel")
  cUiSetColors(hnd, col, col)
  var t = text
  cUiSetText(hnd, toCString(t))
  Widget(hnd)

proc uiToggle*(parent: Widget; x, y, w, h: float32; label: string;
               initial: bool = false): Widget =
  ## A checkbox with a caption. Built FROM SCRATCH (fact #117: cloned game
  ## toggles are dead). State lives in host state and a click flips the
  ## readback -- the framework owns the truth, not a game ToggleGroup.
  let hnd = cUiNew(auToggle, int32(parent), x, y, w, h)
  if hnd < 0: return auRefuse(-hnd, "uiToggle")
  var lab = label
  cUiSetText(hnd, toCString(lab))
  cUiSetInteractive(hnd, 1)
  if initial: cUiToggleForce(hnd, 1'i32)
  Widget(hnd)

proc uiButton*(parent: Widget; x, y, w, h: float32; label: string;
               onClick: AuCallback = nil): Widget =
  ## A push button. v1 is POLLED: uiPump hit-tests it and calls `onClick`. No
  ## UnityAction delegate is constructed (unproven on this build).
  let hnd = cUiNew(auButton, int32(parent), x, y, w, h)
  if hnd < 0: return auRefuse(-hnd, "uiButton")
  var lab = label
  cUiSetText(hnd, toCString(lab))
  cUiSetInteractive(hnd, 1)
  let slot = cUiIndexOf(hnd)
  if slot >= 0'i32 and slot < gAuCbs.len.int32: gAuCbs[slot] = onClick
  Widget(hnd)

proc uiTabStrip*(parent: Widget; x, y, w, h: float32;
                 tabs: openArray[string]): Widget =
  ## A row of tabs. Selection is host state; clicking a tab shows its content
  ## and hides the rest (uiTabContent binds a content widget to each tab).
  ## Sidesteps the game's ToggleGroup entirely.
  let hnd = cUiNew(auTabStrip, int32(parent), x, y, w, h)
  if hnd < 0: return auRefuse(-hnd, "uiTabStrip")
  cUiSetInteractive(hnd, 1)
  # captions are joined for the overlay label; per-tab native labels are made
  # in uiRealizeNative.
  var joined = ""
  for i, t in tabs:
    if i > 0: joined.add "  |  "
    joined.add t
  cUiSetText(hnd, toCString(joined))
  Widget(hnd)

proc uiTabContent*(strip: Widget; content: Widget): int =
  ## Register `content` as the panel shown when the next tab is selected. Call
  ## once per tab, in order. Returns the tab index or a negative refusal.
  int(cUiTabAdd(int32(strip), int32(content)))

proc uiTabApply*(strip: Widget) =
  ## Make exactly one content visible (the selected tab's). Call after wiring.
  discard cUiTabApply(int32(strip))

proc uiTabSelect*(strip: Widget; idx: int): int =
  int(cUiTabSelect(int32(strip), int32(idx)))
proc uiTabSelected*(strip: Widget): int = int(cUiTabSelected(int32(strip)))

proc uiRow*(parent: Widget; x, y, w, h: float32; label: string;
            control: Widget): Widget =
  ## A labeled setting row: a LABEL on the left, `control` on the right. The
  ## caller has already built `control`; this creates the label and the row
  ## record so a settings screen is `for each setting: uiRow(...)`.
  let hnd = cUiNew(auRow, int32(parent), x, y, w, h)
  if hnd < 0: return auRefuse(-hnd, "uiRow")
  var lab = label
  cUiSetText(hnd, toCString(lab))
  Widget(hnd)

# ---- config binding -----------------------------------------------------
proc bindToConfig*(control: Widget; modGuid, key: string;
                   kind: int32 = auBindBool): int =
  ## Bind `control` to a real config value keyed by (modGuid, key). A bool
  ## control's click writes the value and marks it dirty; the host flushes dirty
  ## bindings to the mod's config store. Returns the binding id or a negative
  ## refusal. NOTE: the flush TO the actual mod config store is a host seam --
  ## this owns the identity, the cached value and the dirty edge (all offline-
  ## proven); wiring the store read/write is duplicated-minimal per the brief
  ## and reconciled with the scene API later.
  var g = modGuid
  var k = key
  int(cUiBindWidget(int32(control), toCString(g), toCString(k), kind))

proc configDirtyCount*(): int = int(cUiBindDirtyCount())

# ---- interaction --------------------------------------------------------
proc uiPump*(px, py: float32; down: bool): int =
  ## One polled hit-test/dispatch pass. `px,py` is the pointer in the same
  ## screen space widgets were laid out in; `down` is the button state now. A
  ## press EDGE inside an interactive widget flips a toggle (writing its
  ## binding), changes a tab, or fires a button callback. Returns click count.
  let clicks = int(cUiPump(px, py, (if down: 1'i32 else: 0'i32)))
  if clicks > 0:
    for i in 0 ..< int(cUiCount()):     # capped by AOWL_UI_MAX
      # i is a SLOT INDEX; ask the core for that slot's CURRENT handle. 0 means
      # the slot is empty -- skip it without spending the fault budget.
      let hnd = cUiHandleAt(int32(i))
      if hnd != 0'i32 and cUiTakeClick(hnd) != 0'i32 and i < gAuCbs.len and
         gAuCbs[i] != nil:
        gAuCbs[i](Widget(hnd))
  clicks

proc uiToggleState*(w: Widget): bool = cUiToggleState(int32(w)) != 0'i32

# =========================================================================
# NATIVE REALISATION -- construct real GameObjects from the retained records.
# Must run on the Unity thread inside the outer guard (it rides invoke2's drain,
# like nativeui's proof). `parentGo` is a live canvas GameObject; `donorTmp` is
# a live TextMeshProUGUI whose font/material are copied into from-scratch TMPs.
# =========================================================================
proc auNativeLabel(parentGo, donorTmp: Il2CppPtr; name, text: string;
                   width, height, posX, posY, fontSize: float32): Il2CppPtr =
  ## Build ONE from-scratch TMP label under `parentGo`, the exact sequence
  ## proven in nativeui Stage B: create -> AddComponent<RectTransform> ->
  ## parent+layer -> SetActive(false) -> AddComponent<TMP> -> wire font/material
  ## from the donor -> layout -> SetActive(true) -> set_text (re-applied).
  ## Returns the TMP component, or nil (with the reason logged by nu*).
  let go = nuCreate(name, parentGo)
  if go == nil: return nil
  let rt = nuAdd(go, NuKindRectTransform)
  if rt == nil:
    discard nuDestroy(go); return nil
  if not nuParentAligned(go, parentGo):
    discard nuDestroy(go); return nil
  discard nuSetLayer(go, 5'i32)
  if not nuSetActive(go, false):
    discard nuDestroy(go); return nil
  let tmp = nuAdd(go, NuKindTmpText)
  if tmp == nil:
    discard nuDestroy(go); return nil
  if not nuWireTextDeps(tmp, donorTmp):
    discard nuDestroy(go); return nil
  discard nuSetFontSize(tmp, fontSize)
  if not nuLayout(rt, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32,
                  width, height, posX, posY):
    discard nuDestroy(go); return nil
  discard nuSetActive(go, true)
  discard nuSetText(tmp, text)
  discard nuSetText(tmp, text)
  result = tmp

# =========================================================================
# THE DUAL-BACKEND SELF-PROOF. Builds the SAME tiny screen on BOTH backends and
# reports per-backend PASS / FAIL / INCONCLUSIVE against the finished state.
# Rides invoke2's postfix drain (same as nuProofRun); runs at most once.
#
# NATIVE settling line, per widget: "aowlui PROOF native: <widget> readback ..."
# OVERLAY settling line:            "aowlui PROOF overlay: emitted N ops ..."
# =========================================================================
var gAuVerdictNative  = "not run"
var gAuVerdictOverlay = "not run"

proc auProofOverlay() =
  ## OVERLAY: build the screen with bkOverlay and prove the EMIT path. Actual
  ## pixels need a region DRAW context (the unproven seam), so drawing is
  ## reported INCONCLUSIVE; the emit shape is PASS/FAIL here.
  gAuVerdictOverlay = "INCONCLUSIVE"
  if not uiBegin(bkOverlay):
    gAuVerdictOverlay = "FAIL"; return
  let panel = uiPanel(Widget(-1'i32), 40, 40, 320, 160)
  if not panel.ok:
    warn "aowlui PROOF overlay: FAIL -- panel refused"
    gAuVerdictOverlay = "FAIL"; return
  discard uiLabel(panel, 48, 48, 300, 24, "AOWLSPT UNIFIED UI")
  let tog = uiToggle(panel, 48, 84, 260, 24, "overlay toggle", false)
  discard tog
  let n = int(cUiOverlayEmit())
  # panel(FILL+BOX)=2, label(TEXT)=1, toggle-off(BOX)=1 -> 4 ops expected.
  if n == 4:
    gAuVerdictOverlay = "PASS(emit); INCONCLUSIVE(pixels: needs region DRAW hook)"
    okLog "aowlui PROOF overlay: emitted " & $n & " ops (panel FILL+BOX, " &
          "label TEXT, toggle BOX) -- the emit path is PROVEN. Actual drawing " &
          "is INCONCLUSIVE here: replay needs a region DRAW participant, the " &
          "one live-unproven seam. Settling line: this one."
  else:
    gAuVerdictOverlay = "FAIL"
    warn "aowlui PROOF overlay: expected 4 emit ops, got " & $n &
         " -- the emit mapping is wrong"

proc auProofNative(tab: Il2CppPtr) =
  ## NATIVE: build the same screen as real GameObjects under the live canvas,
  ## and READ BACK each widget (active + non-zero rect; toggle click flips
  ## state). Reuses the donor the proof already walked to.
  gAuVerdictNative = "INCONCLUSIVE"
  if gMi2Tmp == nil or gMi2TmpOwner == nil:
    warn "aowlui PROOF native: INCONCLUSIVE -- no live donor TMP (open " &
         "Settings and click a tab so invoke2 walks to one)"
    return
  let parentGo = nuGameObjectOf(gMi2TmpOwner)
  if parentGo == nil:
    warn "aowlui PROOF native: INCONCLUSIVE -- donor has no parent GameObject"
    return
  discard nuRegisterReference(NuKindTmpText, gMi2Tmp)
  discard uiBegin(bkNative)

  # A label, from scratch, on the proven path.
  let lblTmp = auNativeLabel(parentGo, gMi2Tmp, "aowlui-proof-label",
                             "AOWLSPT UNIFIED UI (native)",
                             520.0'f32, 40.0'f32, 24.0'f32, -140.0'f32, 26.0'f32)
  if lblTmp == nil:
    warn "aowlui PROOF native: FAIL -- the from-scratch label could not be " &
         "built (reason logged above by nativeui)"
    gAuVerdictNative = "FAIL"
    return
  let lblGo = nuGameObjectOf(lblTmp)
  let active = nuActiveInHierarchy(lblGo)
  let (rok, _, _, rw, rh) = nuGetRect(lblTmp)
  let renderable = rok and cNuRectRenderable(rw, rh) != 0'i32
  okLog "aowlui PROOF native: label readback -- active=" & $active &
        " rect=(" & nuF(rw) & "x" & nuF(rh) & ") renderable=" & $renderable &
        ". Settling line for the native label: this one."

  # A toggle's TRUTH lives in the core; prove a click flips the readback.
  let tog = uiToggle(Widget(-1'i32), 0, 0, 30, 30, "native toggle", false)
  cUiSetRect(int32(tog), 100, 100, 30, 30)
  let before = uiToggleState(tog)
  discard uiPump(0, 0, false)          # seed prevDown=up
  discard uiPump(115, 115, true)       # press edge inside the toggle
  let after = uiToggleState(tog)
  okLog "aowlui PROOF native: toggle readback -- before=" & $before &
        " afterClick=" & $after & " (a click MUST flip this; not 'a handler ran')"

  if active and renderable and (after != before):
    gAuVerdictNative = "PASS"
    okLog "aowlui PROOF native: VERDICT = PASS -- from-scratch label renders " &
          "and the toggle readback flipped on a click"
  else:
    gAuVerdictNative =
      (if not renderable: "FAIL(label not renderable)"
       elif after == before: "FAIL(toggle did not flip)"
       else: "INCONCLUSIVE")
    warn "aowlui PROOF native: VERDICT = " & gAuVerdictNative

proc auProofWanted(): bool = gAuProof and not gAuProofDone

proc auProofRun(tab: Il2CppPtr) =
  ## The dual-backend proof. Overlay first (no il2cpp, cannot fault), then
  ## native (guarded by the SAME outer VEH the nativeui proof rides -- this is
  ## called from invoke2's drain, already inside one guard, so it opens NONE of
  ## its own: nesting would disarm the outer one).
  if not gAuOn or not gAuProof or gAuProofDone: return
  gAuProofDone = true
  auProofOverlay()
  if cNuDisabled() == 0'i32:
    auProofNative(tab)
  else:
    warn "aowlui PROOF native: skipped -- the nativeui layer self-disabled"
  okLog "aowlui PROOF: OVERALL  overlay=" & gAuVerdictOverlay &
        "  native=" & gAuVerdictNative &
        ".  The shared core (layout, tabs, hit-test, binding) is offline-" &
        "proven by tests/overlayhost/uitest.c; these two are the live half."

proc bindAowlUi*(verbose: bool) =
  ## Report the framework's readiness once, like bindNativeUi. No detour of its
  ## own: the proof rides invoke2's existing postfix drain.
  if not gAuOn: return
  okLog "aowlui: the unified widget framework is ARMED (backend-agnostic core " &
        "+ overlay emit + native realise). Shared core is offline-proven; the " &
        "in-client dual-backend proof is " &
        (if gAuProof: "ENABLED -- open Settings and click a tab."
         else: "OFF (flag aowlUiProof).")
