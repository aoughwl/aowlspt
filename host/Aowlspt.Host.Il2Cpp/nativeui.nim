# nativeui.nim -- the NATIVE UNITY UI CONSTRUCTION LAYER, Nim surface.
#
# `include`d into `aowlhost.nim` (NOT a separate module) so it shares that
# file's guarded raw primitives (`cIsReadable`, `cReadPtrAt`), its logging
# (`okLog`/`warn`/`info`), `hexOf`, the VEH/SEH guard -- and, because it is
# included AFTER `settingsui.nim` and `invoke2.nim`, that file's
# `suiReadString` plus invoke2's `mi2FindTmp` anchor walk.
#
# WHAT THIS IS FOR
# ----------------
# `abi/aowlspt_nativeui.h` holds the byte-verified targets, the call thunks,
# the component-slot registry and the pure arithmetic. This file is the API
# mods call, and the part that enforces the discipline the C side cannot:
#
#   * ONE `aowl_p_p_seh` around a WHOLE operation, never nested. The guard is
#     not re-entrant -- an inner guard DISARMS the outer one -- so every public
#     entry point here is either already inside a guard or wraps itself once,
#     and this is stated per proc.
#   * every returned pointer re-validated by the code that consumes it, because
#     a step that faulted returns nil and the next step must NOTICE rather than
#     dereference it.
#   * read-back verification of the FINISHED STATE, never of our own write.
#
# THE BUG THIS LAYER EXISTS TO FIX
# --------------------------------
# The invoke2 ladder created a real GameObject, named it, round-tripped
# `get_name`, attached a RectTransform, cloned a live label, parented it into
# the settings canvas and activated it. Eight steps, each verified. Nothing
# appeared on screen, and `findtext` over 60k+ nodes found no trace.
#
# The hypothesis was that the missing piece was LAYOUT -- that a `RectTransform`
# fresh out of `AddComponent` has `sizeDelta == (0,0)`, and a zero-area rect
# renders nothing while every call on the way there reports success.
#
# `nuProofRun` MEASURES that rather than asserting it, and on the first live run
# it came back:
#
#   nativeui PROOF: rect BEFORE layout = (-50.0, -50.0, 100.0, 100.0) renderable=true
#
# So a fresh RectTransform on this build is Unity's default 100x100, NOT
# zero-area. THE HYPOTHESIS IS FALSIFIED, and this file says so rather than
# keeping a tidy story. Layout is still required -- Unity's default position and
# size is not what any caller means -- but it is no longer offered as the
# explanation for the invisible invoke2 label. That cause is still open.
#
# The same run proved something that IS settled, and it is the bigger result:
# the `.data` cache-slot route for generic `AddComponent<T>` works live. The
# component it produced had the same header klass as an independently walked
# live RectTransform. See `nuAdd`.

# ---------------------------------------------------------------------------
# The C surface (abi/aowlspt_nativeui.h)
# ---------------------------------------------------------------------------
proc cNuFn(i: int32): Il2CppPtr {.importc: "aowl_nu_fn", nodecl.}
proc cNuName(i: int32): Il2CppPtr {.importc: "aowl_nu_name", nodecl.}
proc cNuRva(i: int32): uint32 {.importc: "aowl_nu_rva", nodecl.}
proc cNuTargetCount(): int32 {.importc: "aowl_nu_target_count", nodecl.}
proc cNuOkCount(): int32 {.importc: "aowl_nu_ok_count", nodecl.}
proc cNuBadCount(): int32 {.importc: "aowl_nu_bad_count", nodecl.}
proc cNuNoteFault() {.importc: "aowl_nu_note_fault", nodecl.}
proc cNuFaultCount(): int32 {.importc: "aowl_nu_fault_count", nodecl.}
proc cNuDisabled(): int32 {.importc: "aowl_nu_disabled", nodecl.}
proc cNuBaseOk(): int32 {.importc: "aowl_nu_base_ok", nodecl.}
proc cNuWhyOf(i: int32): int32 {.importc: "aowl_nu_why_of", nodecl.}
proc cNuMismatchCount(): int32 {.importc: "aowl_nu_mismatch_count", nodecl.}

proc cNuCallVPP(fn, self, a0: Il2CppPtr) {.importc: "aowl_nu_call_v_pp", nodecl.}
proc cNuCallVPB(fn, self: Il2CppPtr; a0: int32) {.
  importc: "aowl_nu_call_v_pb", nodecl.}
proc cNuCallVPI(fn, self: Il2CppPtr; a0: int32) {.
  importc: "aowl_nu_call_v_pi", nodecl.}
proc cNuCallVPF(fn, self: Il2CppPtr; a0: float32) {.
  importc: "aowl_nu_call_v_pf", nodecl.}
proc cNuCallVPPB(fn, self, a0: Il2CppPtr; a1: int32) {.
  importc: "aowl_nu_call_v_ppb", nodecl.}
proc cNuCallPP(fn, self: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_call_p_p", nodecl.}
proc cNuCallPPP(fn, self, a0: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_call_p_pp", nodecl.}
proc cNuCallPS1(fn, a0: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_call_p_s1", nodecl.}
proc cNuCallVS1(fn, a0: Il2CppPtr) {.importc: "aowl_nu_call_v_s1", nodecl.}
proc cNuCallVS2(fn, a0, a1: Il2CppPtr) {.importc: "aowl_nu_call_v_s2", nodecl.}
proc cNuCallBP(fn, self: Il2CppPtr): int32 {.importc: "aowl_nu_call_b_p", nodecl.}
proc cNuCallIP(fn, self: Il2CppPtr; defVal: int32): int32 {.
  importc: "aowl_nu_call_i_p", nodecl.}
proc cNuCallBS1(fn, a0: Il2CppPtr): int32 {.
  importc: "aowl_nu_call_b_s1", nodecl.}
proc cNuCallGeneric0(fn, self, mi: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_call_generic0", nodecl.}

proc cNuV2InSet(x, y: float32) {.importc: "aowl_nu_v2in_set", nodecl.}
proc cNuV2InPtr(): Il2CppPtr {.importc: "aowl_nu_v2in_ptr", nodecl.}
proc cNuV2OutPtr(): Il2CppPtr {.importc: "aowl_nu_v2out_ptr", nodecl.}
proc cNuV2OutX(): float32 {.importc: "aowl_nu_v2out_x", nodecl.}
proc cNuV2OutY(): float32 {.importc: "aowl_nu_v2out_y", nodecl.}
proc cNuC4InSet(r, g, b, a: float32) {.importc: "aowl_nu_c4in_set", nodecl.}
proc cNuC4InPtr(): Il2CppPtr {.importc: "aowl_nu_c4in_ptr", nodecl.}
proc cNuGetF32(obj: Il2CppPtr; off: int32; ok: ptr int32): float32 {.
  importc: "aowl_nu_get_f32", nodecl.}
proc cNuRectPtr(): Il2CppPtr {.importc: "aowl_nu_rect_ptr", nodecl.}
proc cNuRectX(): float32 {.importc: "aowl_nu_rect_x", nodecl.}
proc cNuRectY(): float32 {.importc: "aowl_nu_rect_y", nodecl.}
proc cNuRectW(): float32 {.importc: "aowl_nu_rect_w", nodecl.}
proc cNuRectH(): float32 {.importc: "aowl_nu_rect_h", nodecl.}
proc cNuRectContains(rx, ry, rw, rh, px, py: float32): int32 {.
  importc: "aowl_nu_rect_contains", nodecl.}
proc cNuRectRenderable(w, h: float32): int32 {.
  importc: "aowl_nu_rect_renderable", nodecl.}

proc cNuKindName(k: int32): Il2CppPtr {.importc: "aowl_nu_kind_name", nodecl.}
proc cNuKindEvidence(k: int32): Il2CppPtr {.
  importc: "aowl_nu_kind_evidence", nodecl.}
proc cNuKindSlotRva(k: int32): uint32 {.
  importc: "aowl_nu_kind_slot_rva", nodecl.}
proc cNuKindAttested(k: int32): int32 {.
  importc: "aowl_nu_kind_attested", nodecl.}
proc cNuKindCount(): int32 {.importc: "aowl_nu_kind_count", nodecl.}
proc cNuKindMi(k: int32): Il2CppPtr {.importc: "aowl_nu_kind_mi", nodecl.}
proc cNuWarmSlot(k: int32; metaInitFn: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_warm_slot", nodecl.}
proc cNuTokenKind(tok: uint32): int32 {.importc: "aowl_nu_token_kind", nodecl.}
proc cNuTokenIndex(tok: uint32): uint32 {.
  importc: "aowl_nu_token_index", nodecl.}
proc cNuSlotState(k: int32): int32 {.importc: "aowl_nu_slot_state", nodecl.}
proc cNuSlotJudge(k: int32; got: Il2CppPtr): int32 {.
  importc: "aowl_nu_slot_judge", nodecl.}
proc cNuRefSet(k: int32; live: Il2CppPtr): int32 {.
  importc: "aowl_nu_ref_set", nodecl.}
proc cNuRefKlass(k: int32): Il2CppPtr {.importc: "aowl_nu_ref_klass", nodecl.}
proc cNuGotKlass(k: int32): Il2CppPtr {.importc: "aowl_nu_got_klass", nodecl.}
proc cNuKlassOf(o: Il2CppPtr): Il2CppPtr {.importc: "aowl_nu_klass_of", nodecl.}

proc cNuIntern(s: cstring): Il2CppPtr {.importc: "aowl_nu_intern", nodecl.}
proc cNuInternCount(): int32 {.importc: "aowl_nu_intern_count", nodecl.}
proc cNuInternOverflowed(): int32 {.
  importc: "aowl_nu_intern_overflowed", nodecl.}

proc cNuOwn(go: Il2CppPtr): int32 {.importc: "aowl_nu_own", nodecl.}
proc cNuDisown(go: Il2CppPtr) {.importc: "aowl_nu_disown", nodecl.}
proc cNuOwnedCount(): int32 {.importc: "aowl_nu_owned_count", nodecl.}
proc cNuOwnedAt(i: int32): Il2CppPtr {.importc: "aowl_nu_owned_at", nodecl.}
proc cNuOwnedClear() {.importc: "aowl_nu_owned_clear", nodecl.}
proc cNuObjectNew(klass: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_object_new", nodecl.}
proc cNuGetRef(obj: Il2CppPtr; off: int32): Il2CppPtr {.
  importc: "aowl_nu_get_ref", nodecl.}
proc cNuSetRef(obj: Il2CppPtr; off: int32; val: Il2CppPtr): int32 {.
  importc: "aowl_nu_set_ref", nodecl.}

# ---- target indices, mirroring the AOWL_NU_* defines --------------------
#
# Each carries the EXACT row name from `aowl_nu_targets`, checked by
# `tools/idxbind.py`. That check is not ceremony here: this table is twenty-five
# rows of near-identical `_Injected` setters and getters, so a row inserted
# above `set_sizeDelta` would silently point it at `set_pivot`, every call would
# still succeed, and the element would simply be laid out wrongly -- exactly the
# invisible-but-successful failure this whole layer exists to end.
const
  NuTGoCtorString    =  0'i32  ## UnityEngine.GameObject::.ctor(String)
  NuTGoSetActive     =  1'i32  ## UnityEngine.GameObject::SetActive
  NuTGoGetTransform  =  2'i32  ## UnityEngine.GameObject::get_transform
  NuTGoActiveInHier  =  3'i32  ## UnityEngine.GameObject::get_activeInHierarchy
  NuTGoSetLayer      =  4'i32  ## UnityEngine.GameObject::set_layer
  NuTAddComponentGen =  5'i32  ## UnityEngine.GameObject::AddComponent<T>
  NuTObjGetName      =  6'i32  ## UnityEngine.Object::get_name
  NuTObjDestroy      =  7'i32  ## UnityEngine.Object::Destroy(Object)
  NuTObjInstantiate  =  8'i32  ## UnityEngine.Object::Instantiate(Object)
  NuTObjAlive        =  9'i32  ## UnityEngine.Object::op_Implicit(Object)
  NuTTrSetParent2    = 10'i32  ## UnityEngine.Transform::SetParent(Transform,bool)
  NuTTrSetAsFirstSib = 11'i32  ## UnityEngine.Transform::SetAsFirstSibling
  NuTRtSetAnchorMin  = 12'i32  ## UnityEngine.RectTransform::set_anchorMin_Injected
  NuTRtSetAnchorMax  = 13'i32  ## UnityEngine.RectTransform::set_anchorMax_Injected
  NuTRtSetAnchoredPos= 14'i32  ## UnityEngine.RectTransform::set_anchoredPosition_Injected
  NuTRtSetSizeDelta  = 15'i32  ## UnityEngine.RectTransform::set_sizeDelta_Injected
  NuTRtSetPivot      = 16'i32  ## UnityEngine.RectTransform::set_pivot_Injected
  NuTRtGetAnchoredPos= 17'i32  ## UnityEngine.RectTransform::get_anchoredPosition_Injected
  NuTRtGetSizeDelta  = 18'i32  ## UnityEngine.RectTransform::get_sizeDelta_Injected
  NuTRtGetRect       = 19'i32  ## UnityEngine.RectTransform::get_rect_Injected
  NuTTmpSetText      = 20'i32  ## TMPro.TMP_Text::set_text
  NuTTmpGetText      = 21'i32  ## TMPro.TMP_Text::get_text
  NuTTmpSetFontSize  = 22'i32  ## TMPro.TMP_Text::set_fontSize
  NuTLocSetLabelText = 23'i32  ## LocalizedText::SetLabelText
  NuTSetParentAlign  = 24'i32  ## TMPro.TMP_DefaultControls::SetParentAndAlign
  NuTMetaInit        = 25'i32  ## il2cpp_codegen_initialize_runtime_metadata
  NuTGrSetColor      = 26'i32  ## UnityEngine.UI.Graphic::set_color
  NuTGrGetCanvasRend = 27'i32  ## UnityEngine.UI.Graphic::get_canvasRenderer
  NuTGrSetAllDirty   = 28'i32  ## UnityEngine.UI.Graphic::SetAllDirty
  NuTCanvasSetMode   = 29'i32  ## UnityEngine.Canvas::set_renderMode
  NuTCanvasGetMode   = 30'i32  ## UnityEngine.Canvas::get_renderMode
  NuTCanvasSetSort   = 31'i32  ## UnityEngine.Canvas::set_sortingOrder

const
  NuRenderModeOverlay = 0'i32  ## ScreenSpaceOverlay -- the only one we accept
  NuRenderModeUnknown = -1'i32 ## "we could not ask", never a legal answer

# ---- field offsets for wiring a from-scratch TMP's dependencies ---------
#
# MEASURED offline from Il2CppMetadataRegistration.fieldOffsets via
# `tools/fldoff.py fields "TMPro.TMP_Text"` (self-check on System.String
# passed), 2026-08-28. These are the reference fields TMP's Awake/OnEnable
# dereferences; a from-scratch component has them NULL and faults, so they are
# copied from a live donor BEFORE the component is activated. Read/written raw
# because they are native-side references with no by-name accessor a mod may
# safely call (set_font is not exercised on this build).
const
  NuOffTmpFontAsset      = 0x100'i32  ## TMPro.TMP_Text.m_fontAsset (TMP_FontAsset)
  NuOffTmpSharedMaterial = 0x118'i32  ## TMPro.TMP_Text.m_sharedMaterial (Material)
  NuOffGraphicMaterial   = 0x20'i32   ## UnityEngine.UI.Graphic.m_Material (Material)

# ---- field offsets for the IMAGE VISIBILITY proof -----------------------
#
# MEASURED offline, `tools/fldoff.py fields UnityEngine.UI.Image` (String
# self-check passed), 2026-08-30. m_Color@0x28 is CROSS-CONFIRMED by
# disassembly and not only by the table: `Graphic::set_color`'s prologue
# contains `F3 0F 10 41 28` = `movss xmm0,[rcx+0x28]`, i.e. the method itself
# reads m_Color at +0x28. Two independent derivations agreeing is what makes
# these safe to read back through.
const
  NuOffGraphicColor      = 0x28'i32   ## Graphic.m_Color -- Color, 4 floats
  NuOffGraphicColorA     = 0x34'i32   ## ...its alpha channel (0x28 + 3*4)
  NuOffGraphicRaycast    = 0x3a'i32   ## Graphic.m_RaycastTarget (bool)
  NuOffGraphicCanvasRend = 0x58'i32   ## Graphic.m_CanvasRenderer (lazy cache)
  NuOffGraphicCanvas     = 0x60'i32   ## Graphic.m_Canvas (lazy cache)
  NuOffImageSprite       = 0xe0'i32   ## Image.m_Sprite -- NULL is legal, see below
  NuOffImageType         = 0xf0'i32   ## Image.m_Type -- 0 == Simple

# ---- component kinds, mirroring the AOWL_NU_KIND_* defines --------------
const
  NuKindRectTransform = 0'i32
  NuKindTmpText       = 1'i32
  NuKindImage         = 2'i32
  NuKindButton        = 3'i32
  NuKindCanvas        = 4'i32

# ---- slot verdicts, mirroring the AOWL_NU_SLOT_* defines ----------------
const
  NuSlotUnknown  = 0'i32
  NuSlotVerified = 1'i32
  NuSlotPoisoned = 2'i32
  NuSlotNoRef    = 3'i32
  NuSlotAttested = 4'i32

proc nuSlotStateName(s: int32): string =
  case int(s)
  of 0: "UNKNOWN (not exercised yet)"
  of 1: "VERIFIED (produced the reference class)"
  of 2: "POISONED (produced the WRONG class -- refused for the session)"
  of 3: "INCONCLUSIVE (no live reference instance to check against)"
  of 4: "ATTESTED (offline token proof says the slot is right; the live donor " &
        "was mistyped -- proceeded)"
  else: "?"

# ---------------------------------------------------------------------------
# Flags. Default OFF, both of them.
#   nativeUi       -- the layer answers at all
#   nativeUiProof  -- additionally run the one-shot visual self-proof
# ---------------------------------------------------------------------------
#   nativeUiImageProof -- additionally run STAGE C, the Image-from-scratch
#                         spike. Independent of `nativeUiProof`: it answers a
#                         different question (does a uGUI *Graphic* built from
#                         nothing render) and the native ESP is blocked on it.
var gNuOn = false
var gNuProof = false
var gNuImgProof = false
var gNuProofDone = false

proc nuProofWanted(): bool = (gNuProof or gNuImgProof) and not gNuProofDone

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------
proc nuWhyName(w: int32): string =
  ## The five distinct reasons `aowl_nu_fn` can refuse. Naming them apart is
  ## not cosmetic: the first live run reported all of them as "did not verify
  ## on this build", which blamed the game build for a host start-order bug.
  case int(w)
  of 0: "verified"
  of 1: "GameAssembly.dll is NOT LOADED YET -- a start-order problem in the " &
        "host, NOT a bad RVA and NOT a stale build"
  of 2: "the address is not committed memory"
  of 3: "the address is committed but not executable"
  of 4: "PROLOGUE MISMATCH -- the bytes are not what this build's metadata " &
        "says; this is the real 'wrong build' signal"
  of 5: "the layer has self-disabled after repeated faults"
  else: "index out of range"

proc nuFn(i: int32): Il2CppPtr =
  ## A verified code pointer, or nil. Refusal is LOGGED WITH ITS REASON: a
  ## target that never bound must not be indistinguishable from a step that ran
  ## and did nothing -- and, equally, "the module is not loaded yet" must not be
  ## reported as "the bytes are wrong".
  result = cNuFn(i)
  if result == nil:
    warn "nativeui: target " & readCString(cNuName(i)) & " @ 0x" &
         hexOf(uint64(cNuRva(i))) & " refused: " &
         nuWhyName(cNuWhyOf(i)) & ". The operation needing it is refused."

proc nuOk(p: Il2CppPtr; n: int32): bool =
  ## Every hop, not just the first. `a->b->c` is three of these.
  p != nil and cIsReadable(p, n) != 0'i32

proc nuF(v: float32): string = formatFloat(float64(v), ffDecimal, 1)

proc nuStr(s: string): Il2CppPtr =
  ## An INTERNED managed string. Allocated at most once per distinct text for
  ## the life of the process -- rule 7, no per-frame managed allocation.
  ## `toCString`, not a `cstring` cast: nimony converts only a string LITERAL
  ## to a cstring, and every text this layer is asked for arrives as a runtime
  ## string. The C side copies the bytes into its own intern table before it
  ## allocates, so the borrowed buffer does not have to outlive the call.
  ## `toCString` takes its argument by `var`, hence the local copy.
  var tmp = s
  cNuIntern(toCString(tmp))

proc nuKlassOf(o: Il2CppPtr): Il2CppPtr = cNuKlassOf(o)

proc nuTransformOf(go: Il2CppPtr): Il2CppPtr =
  ## The GameObject's Transform (a RectTransform, for a UI object).
  let fn = nuFn(NuTGoGetTransform)
  if fn == nil or not nuOk(go, 0x10'i32): return nil
  result = cNuCallPP(fn, go)
  if not nuOk(result, 0x10'i32): result = nil

proc nuGameObjectOf(component: Il2CppPtr): Il2CppPtr =
  ## `Component::get_gameObject`. Reuses invoke2's byte-verified target rather
  ## than duplicating a 26th row for a function that is already proven live.
  let fn = mi2Fn(Mi2GetGameObject)
  if fn == nil or not nuOk(component, 0x10'i32): return nil
  result = cMi2CallPP(fn, component)
  if not nuOk(result, 0x10'i32): result = nil

proc nuAlive(obj: Il2CppPtr): bool =
  ## `Object::op_Implicit` -- Unity's OWN liveness test. NOT the same question
  ## as "is the pointer non-null": a destroyed Unity object keeps a live
  ## managed shell that reads back perfectly and answers false here.
  let fn = nuFn(NuTObjAlive)
  if fn == nil or not nuOk(obj, 0x10'i32): return false
  cNuCallBS1(fn, obj) != 0'i32

proc nuActiveInHierarchy(go: Il2CppPtr): bool =
  ## One third of the visual proof. `activeSelf` is NOT this question: a node
  ## can be active while an ancestor is not, and then it renders nothing.
  let fn = nuFn(NuTGoActiveInHier)
  if fn == nil or not nuOk(go, 0x10'i32): return false
  cNuCallBP(fn, go) != 0'i32

proc nuSetActive(go: Il2CppPtr; on: bool): bool =
  let fn = nuFn(NuTGoSetActive)
  if fn == nil or not nuOk(go, 0x10'i32): return false
  cNuCallVPB(fn, go, (if on: 1'i32 else: 0'i32))
  true

proc nuSetLayer(go: Il2CppPtr; layer: int32): bool =
  ## Layer 5 is Unity's `UI` layer. A UI element on the wrong layer can be
  ## culled by the canvas camera and render nothing -- a second, independent
  ## way to be invisible while every call succeeds.
  let fn = nuFn(NuTGoSetLayer)
  if fn == nil or not nuOk(go, 0x10'i32): return false
  cNuCallVPI(fn, go, layer)
  true

# ---------------------------------------------------------------------------
# CANVAS -- the three calls that turn an attached `Canvas` COMPONENT into one
# that actually puts pixels on the screen.
#
# TYPES. All three take the CANVAS COMPONENT, not its GameObject and not its
# RectTransform. Passing the RectTransform would still be readable, still be
# Unity-alive and still be the wrong object -- the confusion this whole file
# names at every hop.
# ---------------------------------------------------------------------------
proc nuCanvasSetRenderMode(canvas: Il2CppPtr; mode: int32): bool =
  ## `set_renderMode(this, RenderMode, MethodInfo*)`. Writing it is NOT proof;
  ## `nuCanvasRenderMode` is the readback that decides.
  let fn = nuFn(NuTCanvasSetMode)
  if fn == nil or not nuOk(canvas, 0x10'i32): return false
  cNuCallVPI(fn, canvas, mode)
  true

proc nuCanvasRenderMode(canvas: Il2CppPtr): int32 =
  ## The live canvas's own answer, or `NuRenderModeUnknown` when it could not
  ## be asked. Three-state on purpose: "could not ask" must not read back as
  ## ScreenSpaceOverlay(0), which is the very value we are trying to prove.
  let fn = nuFn(NuTCanvasGetMode)
  if fn == nil or not nuOk(canvas, 0x10'i32): return NuRenderModeUnknown
  cNuCallIP(fn, canvas, NuRenderModeUnknown)

proc nuCanvasSetSortingOrder(canvas: Il2CppPtr; order: int32): bool =
  ## Overlay canvases are composited in `sortingOrder`; a canvas at or below
  ## the game's HUD is drawn UNDER it and is invisible while every call here
  ## succeeds.
  let fn = nuFn(NuTCanvasSetSort)
  if fn == nil or not nuOk(canvas, 0x10'i32): return false
  cNuCallVPI(fn, canvas, order)
  true

# ---------------------------------------------------------------------------
# CREATE
# ---------------------------------------------------------------------------
proc nuCreate(name: string; klassDonor: Il2CppPtr): Il2CppPtr =
  ## A new, empty GameObject called `name`.
  ##
  ## `klassDonor` is a LIVE GameObject whose object header supplies the
  ## `Il2CppClass*`. That is the whole trick and it is why no metadata lookup
  ## and no token-gated export is involved: holding one instance of a type
  ## makes its class pointer free. Passing a donor that is not a GameObject
  ## allocates the wrong class -- so the ctor round-trip below is the check,
  ## not a formality.
  ##
  ## The caller must already be inside a guard. Returns nil on any refusal.
  if not gNuOn or cNuDisabled() != 0'i32: return nil
  if not nuOk(klassDonor, 0x10'i32):
    warn "nativeui: create(\"" & name & "\"): the class donor is null or " &
         "unreadable; refusing (an offset that can read null is not a path)"
    return nil
  let klass = nuKlassOf(klassDonor)
  if klass == nil: return nil
  let obj = cNuObjectNew(klass)
  if not nuOk(obj, 0x10'i32):
    warn "nativeui: create(\"" & name & "\"): il2cpp_object_new returned " &
         "null or unreadable"
    return nil
  if nuKlassOf(obj) != klass:
    warn "nativeui: create(\"" & name & "\"): the allocation's header klass " &
         "0x" & hexOf(cast[uint64](nuKlassOf(obj))) & " is not the class " &
         "requested 0x" & hexOf(cast[uint64](klass)) & "; refusing to construct it"
    return nil
  let fnCtor = nuFn(NuTGoCtorString)
  let nameStr = nuStr(name)
  if fnCtor == nil or nameStr == nil:
    if nameStr == nil:
      warn "nativeui: create(\"" & name & "\"): no managed string (intern " &
           "table full=" & $int(cNuInternOverflowed()) & ", used " &
           $int(cNuInternCount()) & ")"
    return nil
  cNuCallVPP(fnCtor, obj, nameStr)
  # THE CHECK. A raw allocation that was never constructed has no native Unity
  # object behind it and cannot answer get_name. Comparing against the string
  # we passed is a round-trip through the game, not a self-comparison.
  let fnName = nuFn(NuTObjGetName)
  if fnName != nil:
    let back = suiReadString(cNuCallPP(fnName, obj))
    if back != name:
      warn "nativeui: create(\"" & name & "\"): get_name round-trip read \"" &
           back & "\" -- the object was allocated but not constructed; refusing"
      return nil
  discard cNuOwn(obj)
  result = obj

proc nuClone(original: Il2CppPtr): Il2CppPtr =
  ## `Object::Instantiate(Object)` -- STATIC, RCX=original, RDX=MethodInfo*=0.
  ## Proven live by the invoke2 ladder. Still the cheapest way to get a UI
  ## element that already has every styling component the game configured.
  ## The clone's klass must match the original's, or it is not a clone.
  if not gNuOn or cNuDisabled() != 0'i32: return nil
  let fn = nuFn(NuTObjInstantiate)
  if fn == nil or not nuOk(original, 0x10'i32): return nil
  let c = cNuCallPS1(fn, original)
  if not nuOk(c, 0x10'i32): return nil
  if nuKlassOf(c) != nuKlassOf(original):
    warn "nativeui: clone: the clone's klass 0x" &
         hexOf(cast[uint64](nuKlassOf(c))) & " differs from the original's 0x" &
         hexOf(cast[uint64](nuKlassOf(original))) & "; refusing it"
    return nil
  result = c

# ---------------------------------------------------------------------------
# ADD COMPONENT -- the generalised slot route
# ---------------------------------------------------------------------------
proc nuRegisterReference(kind: int32; liveInstance: Il2CppPtr): bool =
  ## Record the reference class for `kind` from a LIVE instance reached by
  ## walking from something already validated. Without this, `nuAdd` for that
  ## kind can only ever return INCONCLUSIVE.
  if not nuOk(liveInstance, 0x10'i32): return false
  result = cNuRefSet(kind, liveInstance) != 0'i32
  if result:
    okLog "nativeui: reference instance for " & readCString(cNuKindName(kind)) &
          " registered from a live object 0x" &
          hexOf(cast[uint64](liveInstance)) & "; its klass = 0x" &
          hexOf(cast[uint64](cNuRefKlass(kind)))
  else:
    warn "nativeui: refusing the reference instance for " &
         readCString(cNuKindName(kind)) & ": either its class pointer is " &
         "unreadable, or a DIFFERENT reference was already recorded for this " &
         "kind -- which means one of the two walks is wrong"

proc nuAdd(go: Il2CppPtr; kind: int32): Il2CppPtr =
  ## Attach a component of `kind` and return it, or nil.
  ##
  ## The route is `AddComponent<T>()` at the shared generic body, with the
  ## `MethodInfo*` READ FROM THE GAME'S OWN `.data` cache slot -- the pointer
  ## the game computed for itself. No `System.Type`, so none of the
  ## token-gated exports is touched. (`AddComponent(Type)` needs
  ## `il2cpp_class_get_type` + `il2cpp_type_get_object`; those are gated, and
  ## they are the only thing that has ever faulted on this path.)
  ##
  ## The result is JUDGED against the kind's reference class before it is
  ## handed back. A slot attributed to the wrong T returns a component of the
  ## wrong class, the kind is poisoned for the session, and this returns nil.
  ## A kind with no reference is INCONCLUSIVE and also returns nil -- "I could
  ## not look" is not a pass.
  if not gNuOn or cNuDisabled() != 0'i32: return nil
  if kind < 0'i32 or kind >= cNuKindCount(): return nil
  let kname = readCString(cNuKindName(kind))
  if cNuSlotState(kind) == NuSlotPoisoned:
    warn "nativeui: add(" & kname & "): this kind is POISONED (its slot 0x" &
         hexOf(uint64(cNuKindSlotRva(kind))) & " produced klass 0x" &
         hexOf(cast[uint64](cNuGotKlass(kind))) & " where the live reference " &
         "is 0x" & hexOf(cast[uint64](cNuRefKlass(kind))) &
         "); refusing for the rest of the session"
    return nil
  let fn = nuFn(NuTAddComponentGen)
  if fn == nil or not nuOk(go, 0x10'i32): return nil
  var mi = cNuKindMi(kind)
  if mi == nil:
    warn "nativeui: add(" & kname & "): the game's MethodInfo* cache slot at " &
         ".data 0x" & hexOf(uint64(cNuKindSlotRva(kind))) & " is still NULL. " &
         "That is LAZY-NOT-YET, not an error -- IL2CPP fills it the first " &
         "time the owning method runs. Refusing rather than passing a NULL " &
         "MethodInfo, which the shared generic body dereferences at +0x38."
    return nil
  # ROUTE 1 -- WARM A COLD SLOT. If the slot holds not a readable MethodInfo but
  # an unresolved metadata-usage TOKEN (bit0 set, fits in 32 bits), ask the
  # runtime's OWN codegen resolver to fill it, exactly as the game does at the
  # top of TMP_DefaultControls::CreateText -- no method body, no UI, no gated
  # export. Then re-read the slot. The §9b refusal below is UNCHANGED and is
  # still the last word: if warming did not produce a readable pointer, we do
  # not call AddComponent<T>.
  if not nuOk(mi, 0x48'i32):
    let tok = cast[uint32](cast[uint64](mi) and 0xFFFFFFFF'u64)
    let metaInit = nuFn(NuTMetaInit)
    if metaInit == nil:
      warn "nativeui: add(" & kname & "): slot 0x" &
           hexOf(uint64(cNuKindSlotRva(kind))) & " is COLD (mi=0x" &
           hexOf(cast[uint64](mi)) & ") and the metadata resolver " &
           "il2cpp_codegen_initialize_runtime_metadata could not be verified " &
           "(prologue mismatch or module not loaded); cannot warm it."
    else:
      okLog "nativeui: add(" & kname & "): slot 0x" &
            hexOf(uint64(cNuKindSlotRva(kind))) & " is COLD -- mi=0x" &
            hexOf(cast[uint64](mi)) & " is an unresolved usage token (kind=" &
            $int(cNuTokenKind(tok)) & ", index=0x" &
            hexOf(uint64(cNuTokenIndex(tok))) & "). Warming via " &
            "il2cpp_codegen_initialize_runtime_metadata @0x5251C0 on the slot " &
            "address (resolves in place, returns the MethodInfo*)."
      let warmed = cNuWarmSlot(kind, metaInit)
      mi = cNuKindMi(kind)   # re-read what the resolver wrote into the slot
      if warmed != nil and nuOk(mi, 0x48'i32):
        okLog "nativeui: add(" & kname & "): WARMED -- slot 0x" &
              hexOf(uint64(cNuKindSlotRva(kind))) & " now holds mi=0x" &
              hexOf(cast[uint64](mi)) & ", a readable MethodInfo. Proceeding."
      else:
        warn "nativeui: add(" & kname & "): warm attempt did NOT yield a " &
             "readable MethodInfo (slot now 0x" & hexOf(cast[uint64](mi)) &
             "). Refusing below, unchanged."
  # THE §9b CHECK THAT DID NOT FIRE. A non-NULL slot value is not yet a usable
  # MethodInfo*. Before its owning method has run this session, IL2CPP leaves an
  # UNRESOLVED metadata-usage TOKEN in the slot -- a small, tagged, NON-POINTER
  # value (measured live: TMP's slot 0x6D50040 held 0xc00804f3, high dword zero,
  # top bits set, while RectTransform's warm slot held a real 0x17b_ heap
  # pointer). Passing that token as `const MethodInfo*` makes the shared generic
  # body dereference it at +0x38 and faults. A MethodInfo* is always a readable
  # heap/metadata pointer, so VirtualQuery over its header is the discriminator:
  # a real one is readable, a cold token is not. REFUSE the token; never call.
  if not nuOk(mi, 0x48'i32):
    warn "nativeui: add(" & kname & "): the .data slot 0x" &
         hexOf(uint64(cNuKindSlotRva(kind))) & " holds mi=0x" &
         hexOf(cast[uint64](mi)) & ", which is NOT a readable MethodInfo " &
         "pointer -- on this build that is the shape of an UNRESOLVED IL2CPP " &
         "metadata-usage token, i.e. the slot is COLD: its owning method (for " &
         kname & ", TMP_DefaultControls::CreateText and 5 siblings) has NOT " &
         "run this session, so IL2CPP has not filled it. The RectTransform " &
         "slot works only because the game keeps it warm. REFUSING to call " &
         "AddComponent<T> with a non-pointer MethodInfo (that is the crash " &
         "the breadcrumbs just localised). This kind cannot be built from " &
         "scratch until its slot is warmed."
    return nil
  okLog "nativeui: add(" & kname & "): mi=0x" & hexOf(cast[uint64](mi)) &
        " fn=0x" & hexOf(cast[uint64](fn)) & " -- readable MethodInfo, " &
        "about to call AddComponent<T>"
  let comp = cNuCallGeneric0(fn, go, mi)
  okLog "nativeui: add(" & kname & "): AddComponent<T> returned comp=0x" &
        hexOf(cast[uint64](comp)) & " -- survived the call; about to validate"
  if not nuOk(comp, 0x10'i32):
    warn "nativeui: add(" & kname & "): AddComponent<T> returned null or " &
         "unreadable"
    return nil
  okLog "nativeui: add(" & kname & "): comp readable -- about to judge its klass"
  let verdict = cNuSlotJudge(kind, comp)
  if verdict == NuSlotVerified:
    if cNuSlotState(kind) == NuSlotVerified:
      okLog "nativeui: add(" & kname & "): slot 0x" &
            hexOf(uint64(cNuKindSlotRva(kind))) &
            " VERIFIED -- the component's klass 0x" &
            hexOf(cast[uint64](cNuGotKlass(kind))) &
            " equals the live reference instance's"
    return comp
  if verdict == NuSlotAttested:
    # The produced class does NOT equal the live donor's, but the slot's T is
    # OFFLINE-PROVEN (its static .data token decodes to AddComponent<this-T>;
    # reproduce with `tools/addcompslots.py --slottype 0x...`). AddComponent<T>
    # with that MethodInfo cannot return a non-T, so the DONOR is the mistyped
    # object, not the slot. Proceed -- loudly, and the finished-state proof (the
    # label on screen) remains the real gate.
    warn "nativeui: add(" & kname & "): ATTESTED, not poisoned. The component's " &
         "klass 0x" & hexOf(cast[uint64](cNuGotKlass(kind))) &
         " differs from the live reference 0x" &
         hexOf(cast[uint64](cNuRefKlass(kind))) & ", but slot 0x" &
         hexOf(uint64(cNuKindSlotRva(kind))) & " is offline-proven to be " &
         "AddComponent<" & kname & ">, so the WALKED DONOR is the mistyped " &
         "object (it is not really a " & kname & "), not the slot. Proceeding " &
         "with the produced component; the rendered label is the final gate."
    return comp
  if verdict == NuSlotNoRef:
    warn "nativeui: add(" & kname & "): INCONCLUSIVE. A component came back " &
         "with klass 0x" & hexOf(cast[uint64](cNuGotKlass(kind))) &
         ", but there is no live reference instance of " & kname &
         " to check it against, so we cannot say it is the right class. " &
         "Refusing to use it. Evidence for this slot: " &
         readCString(cNuKindEvidence(kind))
    return nil
  warn "nativeui: add(" & kname & "): FAILED. The slot produced klass 0x" &
       hexOf(cast[uint64](cNuGotKlass(kind))) & " but a live " & kname &
       " has klass 0x" & hexOf(cast[uint64](cNuRefKlass(kind))) &
       ". The slot attribution is WRONG -- this kind is now refused for the " &
       "session. Re-derive it with tools/addcompslots.py."
  result = nil

# ---------------------------------------------------------------------------
# HIERARCHY
# ---------------------------------------------------------------------------
proc nuParentAligned(childGo, parentGo: Il2CppPtr): bool =
  ## `TMP_DefaultControls::SetParentAndAlign(child, parent)` -- Unity's own UI
  ## parenting helper, compiled into this build. It does SetParent(false),
  ## resets the local transform and copies the LAYER, which is the third
  ## invisible-but-successful failure mode this avoids.
  if not gNuOn: return false
  let fn = nuFn(NuTSetParentAlign)
  if fn == nil or not nuOk(childGo, 0x10'i32) or not nuOk(parentGo, 0x10'i32):
    return false
  cNuCallVS2(fn, childGo, parentGo)
  true

proc nuParentTransform(childTr, parentTr: Il2CppPtr; worldPositionStays: bool): bool =
  ## `Transform::SetParent(Transform, bool)`. The lower-level route, for a
  ## caller that has transforms rather than GameObjects.
  if not gNuOn: return false
  let fn = nuFn(NuTTrSetParent2)
  if fn == nil or not nuOk(childTr, 0x10'i32) or not nuOk(parentTr, 0x10'i32):
    return false
  cNuCallVPPB(fn, childTr, parentTr, (if worldPositionStays: 1'i32 else: 0'i32))
  true

proc nuFirstSibling(tr: Il2CppPtr): bool =
  if not gNuOn: return false
  let fn = nuFn(NuTTrSetAsFirstSib)
  if fn == nil or not nuOk(tr, 0x10'i32): return false
  discard cNuCallPP(fn, tr)
  true

# ---------------------------------------------------------------------------
# LAYOUT -- through the `_Injected` setters ONLY
#
# `UnityEngine.RectTransform` declares exactly ONE il2cpp field
# (`reapplyDrivenProperties`, static). Every geometry property is native-side,
# so there is no offset to write and no blind write to make. The `_Injected`
# variants take `(this, Vector2* value, MethodInfo*)`, which removes the
# by-value struct ABI from the problem entirely -- in both directions.
# ---------------------------------------------------------------------------
proc nuSetV2(rt: Il2CppPtr; target: int32; x, y: float32): bool =
  let fn = nuFn(target)
  if fn == nil or not nuOk(rt, 0x10'i32): return false
  cNuV2InSet(x, y)
  cNuCallVPP(fn, rt, cNuV2InPtr())
  true

proc nuGetV2(rt: Il2CppPtr; target: int32): (bool, float32, float32) =
  let fn = nuFn(target)
  if fn == nil or not nuOk(rt, 0x10'i32): return (false, 0'f32, 0'f32)
  cNuCallVPP(fn, rt, cNuV2OutPtr())
  (true, cNuV2OutX(), cNuV2OutY())

proc nuGetRect(rt: Il2CppPtr): (bool, float32, float32, float32, float32) =
  ## `get_rect_Injected(this, Rect* ret, MethodInfo*)` -- x, y, width, height,
  ## written into a buffer we own. This is the read that decides whether an
  ## element renders, and it is why the proof can be conclusive from the log
  ## alone.
  let fn = nuFn(NuTRtGetRect)
  if fn == nil or not nuOk(rt, 0x10'i32):
    return (false, 0'f32, 0'f32, 0'f32, 0'f32)
  cNuCallVPP(fn, rt, cNuRectPtr())
  (true, cNuRectX(), cNuRectY(), cNuRectW(), cNuRectH())

proc nuGetSize(rt: Il2CppPtr): (bool, float32, float32) =
  nuGetV2(rt, NuTRtGetSizeDelta)
proc nuGetPos(rt: Il2CppPtr): (bool, float32, float32) =
  nuGetV2(rt, NuTRtGetAnchoredPos)

proc nuLayout(rt: Il2CppPtr;
              anchorMinX, anchorMinY, anchorMaxX, anchorMaxY: float32;
              pivotX, pivotY: float32;
              width, height: float32;
              posX, posY: float32): bool =
  ## The whole geometry of an element, in one call, in the order Unity itself
  ## uses: anchors, then pivot, then size, then position. Position is applied
  ## LAST because `anchoredPosition` is interpreted relative to the anchors and
  ## the pivot -- setting it first and then moving the anchors silently moves
  ## the element.
  ##
  ## This is not optional. An element created without it has
  ## `sizeDelta == (0,0)` and renders nothing while every call succeeds, which
  ## is exactly what the invoke2 ladder produced.
  if not gNuOn: return false
  if not nuOk(rt, 0x10'i32):
    warn "nativeui: layout: the RectTransform is null or unreadable; refusing"
    return false
  if cNuRectRenderable(width, height) == 0'i32:
    warn "nativeui: layout: refusing a size of " & nuF(width) & "x" &
         nuF(height) & " -- it is zero-area, non-finite or absurd, and would " &
         "render nothing while every call reported success"
    return false
  result = nuSetV2(rt, NuTRtSetAnchorMin, anchorMinX, anchorMinY) and
           nuSetV2(rt, NuTRtSetAnchorMax, anchorMaxX, anchorMaxY) and
           nuSetV2(rt, NuTRtSetPivot, pivotX, pivotY) and
           nuSetV2(rt, NuTRtSetSizeDelta, width, height) and
           nuSetV2(rt, NuTRtSetAnchoredPos, posX, posY)

# ---------------------------------------------------------------------------
# TEXT
# ---------------------------------------------------------------------------
proc nuGetText(tmp: Il2CppPtr): string =
  ## `TMP_Text::get_text`, decoded by the FIXED System.String layout the host
  ## already trusts. Reading the PROPERTY rather than the `m_text` field is
  ## deliberate: the field is what LocalizedText clobbers, so reading it back
  ## would be reading our own write.
  let fn = nuFn(NuTTmpGetText)
  if fn == nil or not nuOk(tmp, 0x10'i32): return ""
  suiReadString(cNuCallPP(fn, tmp))

proc nuSetText(tmp: Il2CppPtr; s: string; localized: Il2CppPtr = nil): bool =
  ## Set TMP text through the REAL setters and re-apply.
  ##
  ## Writing `m_text` raw does not stick: `LocalizedText` clobbers it. When a
  ## LocalizedText component is present it must be told too, and the TMP write
  ## is then RE-APPLIED, because the clobber can land after ours.
  ##
  ## `ForceMeshUpdate` is deliberately NOT called: it resolves to 0x628110,
  ## which is `C2 00 00` -- this build's universal empty-body stub shared by
  ## 6,438 methods, not that method's code. Calling it would look like a
  ## refresh and do nothing.
  if not gNuOn: return false
  let fnSet = nuFn(NuTTmpSetText)
  let str = nuStr(s)
  if fnSet == nil or str == nil or not nuOk(tmp, 0x10'i32): return false
  cNuCallVPP(fnSet, tmp, str)
  if localized != nil and nuOk(localized, 0x10'i32):
    let fnLoc = nuFn(NuTLocSetLabelText)
    if fnLoc != nil:
      cNuCallVPP(fnLoc, localized, str)
      cNuCallVPP(fnSet, tmp, str)          # re-apply after the clobber
  result = true

proc nuSetFontSize(tmp: Il2CppPtr; size: float32): bool =
  ## `TMP_Text::set_fontSize(float)` -- the float goes in XMM1, the hidden
  ## MethodInfo* in R8.
  if not gNuOn: return false
  let fn = nuFn(NuTTmpSetFontSize)
  if fn == nil or not nuOk(tmp, 0x10'i32): return false
  cNuCallVPF(fn, tmp, size)
  true

# ---------------------------------------------------------------------------
# WIRE DEPENDENCIES -- the from-scratch gap
#
# A cloned TMP (Stage A) works because it inherits a fully-wired component: a
# font asset, a material, mesh/renderer state. A component built from scratch
# has `m_fontAsset` / `m_sharedMaterial` / (Graphic) `m_Material` NULL, and
# TMP's Awake/OnEnable dereferences them -- LoadFontAsset reaches for the
# default font through TMP_Settings and faults. This copies those references
# out of a LIVE donor TMP so the fresh one has them BEFORE it renders.
#
# It MUST be called while the target GameObject is INACTIVE. On this build the
# fault fires synchronously from AddComponent when the GameObject is active
# (run 1 died "on or immediately after AddComponent<TextMeshProUGUI>", which is
# Awake/OnEnable firing inline), so there is no window to set fields "after
# AddComponent, before render" on an active object -- the render IS the add.
# Deferring Awake by keeping the GameObject inactive is the only place the
# wiring fits. See Stage B.
# ---------------------------------------------------------------------------
proc nuWireTextDeps(fresh, donor: Il2CppPtr): bool =
  ## Copy font asset + materials from a live donor TMP into a from-scratch TMP.
  ## Returns false (and logs) if the donor's font asset is unreadable -- that
  ## is the one reference whose absence provably faults, so a missing font is a
  ## refusal, not a maybe. The materials are best-effort: a null donor material
  ## is copied as null only if it was already null (TMP rebuilds it from the
  ## font in that case), never fabricated.
  okLog "nativeui: wireTextDeps: ENTER fresh=0x" & hexOf(cast[uint64](fresh)) &
        " donor=0x" & hexOf(cast[uint64](donor)) & " -- VirtualQuerying both"
  if not nuOk(fresh, 0x120'i32) or not nuOk(donor, 0x120'i32):
    warn "nativeui: wireTextDeps: the fresh or donor TMP is null/too-small to " &
         "hold m_sharedMaterial@0x118; refusing (fresh readable=" &
         $(nuOk(fresh, 0x120'i32)) & " donor readable=" &
         $(nuOk(donor, 0x120'i32)) & ")"
    return false

  okLog "nativeui: wireTextDeps: about to GET m_fontAsset@0x100 from the DONOR"
  let font = cNuGetRef(donor, NuOffTmpFontAsset)
  okLog "nativeui: wireTextDeps: got font=0x" & hexOf(cast[uint64](font)) &
        " from donor"
  if not nuOk(font, 0x10'i32):
    warn "nativeui: wireTextDeps: the donor's m_fontAsset@0x100 is null or " &
         "unreadable -- without it TMP's Awake faults on the default-font " &
         "path, so refusing to build a TMP that cannot render"
    return false

  okLog "nativeui: wireTextDeps: about to GET m_sharedMaterial@0x118 from DONOR"
  let sharedMat = cNuGetRef(donor, NuOffTmpSharedMaterial)
  okLog "nativeui: wireTextDeps: got sharedMat=0x" &
        hexOf(cast[uint64](sharedMat)) & "; about to GET Graphic m_Material@0x20"
  let gMat = cNuGetRef(donor, NuOffGraphicMaterial)
  okLog "nativeui: wireTextDeps: got gMat=0x" & hexOf(cast[uint64](gMat)) &
        "; about to SET m_fontAsset on the FRESH component"

  if cNuSetRef(fresh, NuOffTmpFontAsset, font) == 0'i32:
    warn "nativeui: wireTextDeps: m_fontAsset slot on the fresh TMP is not " &
         "writable; refusing"
    return false
  okLog "nativeui: wireTextDeps: SET m_fontAsset ok (font 0x" &
        hexOf(cast[uint64](font)) & " copied from donor 0x" &
        hexOf(cast[uint64](donor)) & ")"

  if nuOk(sharedMat, 0x10'i32):
    okLog "nativeui: wireTextDeps: about to SET m_sharedMaterial on the FRESH"
    if cNuSetRef(fresh, NuOffTmpSharedMaterial, sharedMat) != 0'i32:
      okLog "nativeui: wireTextDeps: SET m_sharedMaterial ok (0x" &
            hexOf(cast[uint64](sharedMat)) & ")"
  else:
    okLog "nativeui: wireTextDeps: donor m_sharedMaterial null/unreadable -- " &
          "leaving the fresh one null (TMP rebuilds it from the font)"

  if nuOk(gMat, 0x10'i32):
    okLog "nativeui: wireTextDeps: about to SET Graphic m_Material on the FRESH"
    discard cNuSetRef(fresh, NuOffGraphicMaterial, gMat)
    okLog "nativeui: wireTextDeps: SET Graphic m_Material ok (0x" &
          hexOf(cast[uint64](gMat)) & ")"
  okLog "nativeui: wireTextDeps: DONE -- all reachable deps copied"
  result = true

# ---------------------------------------------------------------------------
# INPUT -- POLLED, v1
#
# There is no delegate path here on purpose. A Button.onClick handler needs a
# managed `UnityAction`, and a hand-built delegate needs a valid `invoke_impl`
# AND a valid `MethodInfo*` for a method that exists in no assembly. Nothing
# about that is demonstrated on this build, and an unproven delegate handed to
# Unity's event system faults on a frame we do not control.
#
# The host already runs every frame on the Unity thread through the
# TarkovApplication::Update bridge, so interaction is a per-frame READ. This is
# the arithmetic half; the caller supplies the pointer position it already has.
# ---------------------------------------------------------------------------
proc nuHitTest(rt: Il2CppPtr; px, py: float32): bool =
  ## Is (px, py), in the element's own local rect space, inside it?
  ## A zero-area rect contains nothing -- so an element that failed layout
  ## cannot be "clicked" by accident either.
  let (ok, rx, ry, rw, rh) = nuGetRect(rt)
  if not ok: return false
  cNuRectContains(rx, ry, rw, rh, px, py) != 0'i32

# ---------------------------------------------------------------------------
# TEARDOWN -- creating UI that cannot be torn down is a leak
# ---------------------------------------------------------------------------
proc nuDestroy(go: Il2CppPtr): bool =
  ## `Object::Destroy(Object)`, once, only if Unity still considers it alive.
  if not gNuOn: return false
  let fn = nuFn(NuTObjDestroy)
  if fn == nil or not nuOk(go, 0x10'i32): return false
  if not nuAlive(go): return false
  cNuCallVS1(fn, go)
  cNuDisown(go)
  true

proc nuDestroyAll(): int =
  ## Tear down everything this layer created. Capped by construction (the
  ## owned table is a fixed 64 entries), and each entry is liveness-checked
  ## before it is destroyed, so a second call cannot double-destroy.
  result = 0
  if not gNuOn: return
  let fn = nuFn(NuTObjDestroy)
  if fn == nil: return
  let n = int(cNuOwnedCount())
  for i in 0 ..< n:                       # capped: n <= AOWL_NU_MAX_OWNED
    let go = cNuOwnedAt(int32(i))
    if go != nil and nuOk(go, 0x10'i32) and nuAlive(go):
      cNuCallVS1(fn, go)
      inc result
  cNuOwnedClear()
  okLog "nativeui: destroyAll destroyed " & $result & " of " & $n &
        " owned object(s); the rest were already gone"

# ---------------------------------------------------------------------------
# THE VISUAL SELF-PROOF
#
# CLAUDE.md 9b, applied literally. The invoke2 ladder logged eight successes
# and produced nothing on screen, because every one of its checks compared a
# call against itself. This asserts the FINISHED STATE instead, and states one
# of THREE verdicts.
#
# WHAT THE FIRST LIVE RUN TAUGHT US, AND WHAT CHANGED BECAUSE OF IT
# -----------------------------------------------------------------
# Run 1 got as far as
#
#   nativeui PROOF: rect BEFORE layout = (-50.0, -50.0, 100.0, 100.0) renderable=true
#   nativeui PROOF: FAULTED -- the VEH guard caught it and the game survived.
#
# Two findings, and they pull in opposite directions:
#
#   * GOOD: the `.data` cache-slot route for generic `AddComponent<T>` is
#     PROVEN LIVE. `add(UnityEngine.RectTransform)` returned a component whose
#     header klass equalled that of an independently walked live RectTransform.
#     The whole slot mechanism, the reference-instance check and the refusal
#     paths all work. None of that is touched below.
#   * The zero-area hypothesis is FALSIFIED: a fresh RectTransform is Unity's
#     default 100x100, not (0,0). See the header comment.
#
# And the fault landed on the FIRST call after that read. Structurally, the
# problem is that run 1 combined two independent unknowns into one guarded body
# -- building a TextMeshProUGUI FROM SCRATCH (`AddComponent<TextMeshProUGUI>`
# on a bare GameObject, which runs TMP's `Awake`) AND laying it out -- so a
# fault in either hid the answer to both, and the log could not say which.
#
# So the proof is now TWO STAGES, each with its OWN single `aowl_p_p_seh`,
# run one after the other. Sequential, never nested: the guard is not
# re-entrant and an inner guard disarms the outer one.
#
#   STAGE A -- CLONE + LAYOUT. Everything here except the layout was already
#     proven live by invoke2 step 5: `Object::Instantiate` on a live label's
#     GameObject, parented with `SetParentAndAlign`. The ONE new variable is
#     the layout call. If Stage A passes, a mod can build visible UI today.
#   STAGE B -- FROM SCRATCH. `il2cpp_object_new` + ctor + `AddComponent
#     <RectTransform>` + `AddComponent<TextMeshProUGUI>`. This is where run 1
#     faulted, and running it SECOND means it can no longer take Stage A's
#     verdict down with it.
#
# Every risky call is now preceded by its own breadcrumb line, so the next run
# names the exact call that faulted instead of leaving a gap between "rect
# BEFORE layout" and the guard's report.
#
# What the human should see in aowlspt-host.log:
#
#   nativeui PROOF A: rect BEFORE layout = (-50.0, -50.0, 100.0, 100.0)
#   nativeui PROOF A: rect AFTER  layout = (..., 520.0, 44.0)  renderable=true
#   nativeui PROOF A: get_text round-trip = "AOWLSPT NATIVE UI PROOF"
#   nativeui PROOF A: activeInHierarchy = true
#   nativeui PROOF A: VERDICT = PASS
#   nativeui PROOF B: ... (and, if it faults, the breadcrumb naming where)
#   nativeui PROOF: OVERALL A=PASS B=<...>
#
# and, on screen, that text in the settings panel. Also findable by the text it
# DISPLAYS:  findtext AOWLSPT NATIVE UI
# ---------------------------------------------------------------------------

const NuProofText  = "AOWLSPT NATIVE UI PROOF"
const NuProofTextB = "AOWLSPT NATIVE UI SCRATCH"
const NuProofName  = "aowlspt-nativeui-proof"

var gNuVerdictA = "not run"
var gNuVerdictB = "not run"

proc nuStep(stage, what: string) =
  ## A breadcrumb before every call that could fault. The cost of one log line
  ## is nothing; the cost of NOT having it was a whole live run that could only
  ## say the fault was somewhere after `rect BEFORE layout`.
  okLog "nativeui PROOF " & stage & ": -> " & what

proc nuReportFinished(stage: string; go, rt, tmp: Il2CppPtr;
                      want: string): string =
  ## The FINISHED STATE, read back three independent ways, none of them a
  ## comparison against our own write. Returns PASS / FAIL / INCONCLUSIVE.
  nuStep(stage, "reading the finished state back")
  let (okA, ax, ay, aw, ah) = nuGetRect(rt)
  let back = nuGetText(tmp)
  let active = nuActiveInHierarchy(go)
  let renderable = okA and cNuRectRenderable(aw, ah) != 0'i32
  if okA:
    okLog "nativeui PROOF " & stage & ": rect AFTER  layout = (" & nuF(ax) &
          ", " & nuF(ay) & ", " & nuF(aw) & ", " & nuF(ah) &
          ")  renderable=" & $renderable
  else:
    warn "nativeui PROOF " & stage & ": the rect could not be read back"
  okLog "nativeui PROOF " & stage & ": get_text round-trip = \"" & back & "\"" &
        (if back == want: "  <-- EXACT MATCH"
         else: "  <-- does NOT match what was set")
  okLog "nativeui PROOF " & stage & ": activeInHierarchy = " & $active
  let (okP, px, py) = nuGetPos(rt)
  if okP:
    okLog "nativeui PROOF " & stage & ": anchoredPosition = (" & nuF(px) &
          ", " & nuF(py) & ")"
  if not okA:
    warn "nativeui PROOF " & stage & ": VERDICT = INCONCLUSIVE -- the rect " &
         "could not be read back, so nothing is settled. This is NOT a pass."
    return "INCONCLUSIVE"
  if renderable and active and back == want:
    okLog "nativeui PROOF " & stage & ": VERDICT = PASS. The element is " &
          "parented into the live settings canvas, has a non-zero rect, is " &
          "active in the hierarchy, and reports the text it was given. " &
          "Confirm on screen and with `findtext " & want & "`."
    return "PASS"
  warn "nativeui PROOF " & stage & ": VERDICT = FAIL -- renderable=" &
       $renderable & " activeInHierarchy=" & $active & " textMatches=" &
       $(back == want) & ". The element exists and does not render. Left in " &
       "place so the inspector can be pointed at it: 0x" &
       hexOf(cast[uint64](go))
  result = "FAIL"

# ---------------------------------------------------------------------------
# STAGE A -- clone a live label, then LAY IT OUT
#
# Everything but the layout was proven live by invoke2 step 5. This isolates
# the one variable that has never been exercised.
# ---------------------------------------------------------------------------
proc nuProofStageA(tabPtr: Il2CppPtr) =
  gNuVerdictA = "INCONCLUSIVE"
  okLog "nativeui PROOF A: BEGIN -- clone a live label and lay it out. " &
        $int(cNuOkCount()) & " of " & $int(cNuTargetCount()) &
        " targets verified so far, " & $int(cNuMismatchCount()) &
        " prologue mismatch(es)."

  # A live anchor, reached by WALKING from something already validated.
  nuStep("A", "mi2FindTmp: walk the tab for a TextMeshProUGUI with real text")
  mi2FindTmp(tabPtr)
  if gMi2Tmp == nil or gMi2TmpOwner == nil:
    warn "nativeui PROOF A: INCONCLUSIVE -- no readable TextMeshProUGUI on " &
         "this tab, so there is no validated live object to walk from. " &
         "Nothing was created. Open another settings tab to retry."
    return
  let anchorGo = nuGameObjectOf(gMi2Tmp)
  let parentGo = nuGameObjectOf(gMi2TmpOwner)
  if anchorGo == nil or parentGo == nil:
    warn "nativeui PROOF A: INCONCLUSIVE -- the anchor TMP or its owner has " &
         "no readable GameObject; nothing was created"
    return
  okLog "nativeui PROOF A: anchor TMP=0x" & hexOf(cast[uint64](gMi2Tmp)) &
        " anchorGO=0x" & hexOf(cast[uint64](anchorGo)) &
        " parentGO=0x" & hexOf(cast[uint64](parentGo))

  # Reference instances, so Stage B's slot checks can be conclusive. Registered
  # here because this is where the live objects are; both are read-only.
  discard nuRegisterReference(NuKindTmpText, gMi2Tmp)
  nuStep("A", "get_transform on the anchor (a TMP is a Graphic, so its " &
              "transform is necessarily a RectTransform)")
  let anchorRt = nuTransformOf(anchorGo)
  if anchorRt != nil:
    discard nuRegisterReference(NuKindRectTransform, anchorRt)

  # THE CLONE. Proven live; the clone's klass must equal the original's.
  nuStep("A", "Object::Instantiate on the anchor's GameObject")
  let cloneGo = nuClone(anchorGo)
  if cloneGo == nil:
    warn "nativeui PROOF A: INCONCLUSIVE -- Instantiate did not return a " &
         "usable clone; nothing to lay out"
    return
  discard cNuOwn(cloneGo)
  okLog "nativeui PROOF A: cloneGO=0x" & hexOf(cast[uint64](cloneGo))

  nuStep("A", "SetParentAndAlign the clone into the live canvas")
  if not nuParentAligned(cloneGo, parentGo):
    warn "nativeui PROOF A: INCONCLUSIVE -- could not parent the clone; " &
         "tearing it down"
    discard nuDestroy(cloneGo)
    return

  nuStep("A", "get_transform on the clone -> its RectTransform")
  let rt = nuTransformOf(cloneGo)
  if rt == nil:
    warn "nativeui PROOF A: INCONCLUSIVE -- the clone has no readable " &
         "transform; tearing it down"
    discard nuDestroy(cloneGo)
    return

  # THE MEASUREMENT. Read the rect BEFORE any layout call. Run 1 measured
  # (-50,-50,100,100) here, which is what falsified the zero-area hypothesis;
  # it is read again because it is the control for the "after" below.
  nuStep("A", "get_rect_Injected BEFORE layout")
  let (okB, bx, by, bw, bh) = nuGetRect(rt)
  if okB:
    okLog "nativeui PROOF A: rect BEFORE layout = (" & nuF(bx) & ", " &
          nuF(by) & ", " & nuF(bw) & ", " & nuF(bh) & ")  renderable=" &
          $(cNuRectRenderable(bw, bh) != 0'i32)

  # The clone is a TMP COMPONENT's GameObject, so the component is on it. The
  # anchor component's class is the reference we already registered.
  nuStep("A", "set_text on the clone's TMP")
  # The clone of a GameObject carries a clone of its TextMeshProUGUI. We hold
  # the ORIGINAL component, and the clone's copy sits at the same class; the
  # honest way to reach it without GetComponent<T> is the transform we already
  # have plus the component pointer Instantiate returned for the COMPONENT
  # clone. invoke2 step 5 cloned the component directly, so do that too -- it
  # is the pointer we can actually name.
  let tmpClone = nuClone(gMi2Tmp)
  if tmpClone == nil:
    warn "nativeui PROOF A: INCONCLUSIVE -- could not clone the TMP component " &
         "itself, so there is no text object to verify; tearing down"
    discard nuDestroy(cloneGo)
    return
  let tmpCloneGo = nuGameObjectOf(tmpClone)
  if tmpCloneGo == nil:
    warn "nativeui PROOF A: INCONCLUSIVE -- the cloned TMP has no GameObject"
    discard nuDestroy(cloneGo)
    return
  discard cNuOwn(tmpCloneGo)
  # The GameObject clone above was only ever the control for the rect read; the
  # element we actually show is this one. Destroy the first so the screen is
  # not ambiguous -- two near-identical labels would make the visual evidence
  # useless.
  discard nuDestroy(cloneGo)

  nuStep("A", "SetParentAndAlign the cloned TMP into the live canvas")
  if not nuParentAligned(tmpCloneGo, parentGo):
    warn "nativeui PROOF A: INCONCLUSIVE -- could not parent the cloned TMP"
    discard nuDestroy(tmpCloneGo)
    return
  discard nuSetLayer(tmpCloneGo, 5'i32)          # Unity's built-in `UI` layer

  nuStep("A", "get_transform on the cloned TMP")
  let rt2 = nuTransformOf(tmpCloneGo)
  if rt2 == nil:
    warn "nativeui PROOF A: INCONCLUSIVE -- the cloned TMP has no transform"
    discard nuDestroy(tmpCloneGo)
    return

  nuStep("A", "set_text")
  discard nuSetText(tmpClone, NuProofText)
  nuStep("A", "set_fontSize")
  discard nuSetFontSize(tmpClone, 28.0'f32)

  nuStep("A", "nuLayout -- THE ONE NEW VARIABLE in this stage")
  if not nuLayout(rt2,
                  0.0'f32, 1.0'f32,      # anchorMin  (left, top)
                  0.0'f32, 1.0'f32,      # anchorMax  (left, top)
                  0.0'f32, 1.0'f32,      # pivot      (left, top)
                  520.0'f32, 44.0'f32,   # size
                  24.0'f32, -24.0'f32):  # position
    warn "nativeui PROOF A: FAIL -- layout refused; tearing down"
    gNuVerdictA = "FAIL"
    discard nuDestroy(tmpCloneGo)
    return

  nuStep("A", "SetActive(true)")
  discard nuSetActive(tmpCloneGo, true)
  nuStep("A", "re-apply set_text after activation (LocalizedText clobbers it)")
  discard nuSetText(tmpClone, NuProofText)

  gNuVerdictA = nuReportFinished("A", tmpCloneGo, rt2, tmpClone, NuProofText)
  okLog "nativeui PROOF A: END (verdict " & gNuVerdictA & ")"

# ---------------------------------------------------------------------------
# STAGE B -- build one FROM SCRATCH
#
# This is where run 1 faulted, immediately after the rect read. Running it
# second, under its own guard, means it can no longer take Stage A down with
# it -- and every call now has a breadcrumb, so the next run names the exact
# one rather than leaving a gap.
#
# Run 1's fault was `AddComponent<TextMeshProUGUI>` running TMP's Awake, which
# reaches for a default font asset (through TMP_Settings) and a material a
# from-scratch component has as NULL. THE FIX, implemented below: keep the
# GameObject INACTIVE across the add so Awake is deferred, copy the font asset
# and material out of the live donor TMP into the fresh one, THEN activate --
# at which point Awake runs with its dependencies already set. The activation
# is the new, breadcrumbed fault point: if TMP needs more than font+material,
# the log stops at "SetActive(true)" and names it.
# ---------------------------------------------------------------------------
proc nuProofStageB(tabPtr: Il2CppPtr) =
  gNuVerdictB = "INCONCLUSIVE"
  okLog "nativeui PROOF B: BEGIN -- build a label FROM SCRATCH " &
        "(il2cpp_object_new + ctor + AddComponent<T>)"
  if gMi2Tmp == nil or gMi2TmpOwner == nil:
    warn "nativeui PROOF B: INCONCLUSIVE -- Stage A never found a live anchor"
    return
  let parentGo = nuGameObjectOf(gMi2TmpOwner)
  if parentGo == nil:
    warn "nativeui PROOF B: INCONCLUSIVE -- no parent GameObject"
    return

  nuStep("B", "il2cpp_object_new + GameObject::.ctor(String) + get_name round-trip")
  let go = nuCreate(NuProofName, parentGo)
  if go == nil:
    warn "nativeui PROOF B: FAIL -- creation refused (reason logged above)"
    gNuVerdictB = "FAIL"
    return

  nuStep("B", "AddComponent<RectTransform> via the .data cache slot " &
              "(PROVEN LIVE in run 1 -- klass matched the live reference)")
  let rt = nuAdd(go, NuKindRectTransform)
  if rt == nil:
    gNuVerdictB = (if cNuSlotState(NuKindRectTransform) == NuSlotPoisoned:
                     "FAIL" else: "INCONCLUSIVE")
    warn "nativeui PROOF B: " & gNuVerdictB & " -- the RectTransform slot " &
         "could not be settled; tearing down"
    discard nuDestroy(go)
    return

  nuStep("B", "SetParentAndAlign into the live canvas")
  if not nuParentAligned(go, parentGo):
    warn "nativeui PROOF B: INCONCLUSIVE -- could not parent; tearing down"
    discard nuDestroy(go)
    return
  discard nuSetLayer(go, 5'i32)

  nuStep("B", "get_rect_Injected BEFORE layout")
  let (okB2, bx, by, bw, bh) = nuGetRect(rt)
  if okB2:
    okLog "nativeui PROOF B: rect BEFORE layout = (" & nuF(bx) & ", " &
          nuF(by) & ", " & nuF(bw) & ", " & nuF(bh) & ")  renderable=" &
          $(cNuRectRenderable(bw, bh) != 0'i32)

  # DEFER TMP's Awake. Run 1 faulted on/just after AddComponent<TMP> while the
  # GameObject was active -- which means Awake/OnEnable fired SYNCHRONOUSLY from
  # the add, reached for a null default font asset, and died. There is no
  # "after AddComponent, before render" window on an active object: the add IS
  # the render. So deactivate the GameObject first; Unity then holds Awake and
  # OnEnable until re-activation, giving us a place to wire the dependencies.
  nuStep("B", "SetActive(false) -- defer TMP's Awake so its NULL font/material " &
              "are not dereferenced on the add (this is the diagnosis: the " &
              "fault is at Awake, not first render)")
  if not nuSetActive(go, false):
    warn "nativeui PROOF B: INCONCLUSIVE -- could not deactivate before the " &
         "TMP add; refusing to add TMP to an active object; tearing down"
    discard nuDestroy(go)
    return

  nuStep("B", "AddComponent<TextMeshProUGUI> on the INACTIVE object -- Awake " &
              "is deferred, so this no longer runs TMP's font-loading path")
  let tmp = nuAdd(go, NuKindTmpText)
  if tmp == nil:
    let st = cNuSlotState(NuKindTmpText)
    gNuVerdictB = (if st == NuSlotPoisoned: "FAIL" else: "INCONCLUSIVE")
    # State the ACTUAL post-warm reason, not the old COLD-slot guess: the slot
    # is warmed and offline-attested this run, so a refusal now is either the
    # add producing an unreadable component (POISONED) or an earlier guard
    # declining (INCONCLUSIVE). The exact reason is the last nuAdd line above.
    warn "nativeui PROOF B: " & gNuVerdictB & " -- AddComponent<TMP> did not " &
         "yield a usable component (slot state " & nuSlotStateName(st) &
         "). The slot WAS warmed and is offline-proven AddComponent<" &
         "TextMeshProUGUI>, so this is NOT a cold slot; the exact reason is the " &
         "last `add(TMPro.TextMeshProUGUI)` line above. Tearing down."
    discard nuDestroy(go)
    return
  okLog "nativeui PROOF B: AddComponent<TextMeshProUGUI> on the inactive " &
        "object SURVIVED -- the slot was WARM this run"

  # THE FIX. Copy font asset + materials from the live donor TMP (gMi2Tmp,
  # the anchor Stage A walked to and registered as the reference instance)
  # BEFORE the component is activated, so its deferred Awake finds them set.
  nuStep("B", "wireTextDeps -- copy font asset + material from the live donor")
  if not nuWireTextDeps(tmp, gMi2Tmp):
    warn "nativeui PROOF B: FAIL -- could not wire the TMP's font/material " &
         "dependencies; activating it would fault. Tearing down."
    gNuVerdictB = "FAIL"
    discard nuDestroy(go)
    return

  nuStep("B", "set_fontSize (still inactive, no render yet)")
  discard nuSetFontSize(tmp, 28.0'f32)

  nuStep("B", "nuLayout")
  if not nuLayout(rt,
                  0.0'f32, 1.0'f32,
                  0.0'f32, 1.0'f32,
                  0.0'f32, 1.0'f32,
                  520.0'f32, 44.0'f32,
                  24.0'f32, -80.0'f32):   # below Stage A's label
    warn "nativeui PROOF B: FAIL -- layout refused; tearing down"
    gNuVerdictB = "FAIL"
    discard nuDestroy(go)
    return

  # NOW Awake/OnEnable fires -- with font and material wired. This is the new
  # fault point if the deps are still insufficient; it is breadcrumbed so the
  # next run names it rather than leaving a gap.
  nuStep("B", "SetActive(true) -- TMP's Awake/OnEnable runs HERE now, with " &
              "font+material wired. If the log stops here, TMP needs more than " &
              "font+material.")
  discard nuSetActive(go, true)
  okLog "nativeui PROOF B: SetActive(true) returned -- TMP's Awake/OnEnable " &
        "SURVIVED with font+material wired"
  nuStep("B", "set_text through the real setter + re-apply after activation")
  discard nuSetText(tmp, NuProofTextB)
  discard nuSetText(tmp, NuProofTextB)

  gNuVerdictB = nuReportFinished("B", go, rt, tmp, NuProofTextB)
  okLog "nativeui PROOF B: END (verdict " & gNuVerdictB & ")"

# ---------------------------------------------------------------------------
# STAGE C -- THE IMAGE SPIKE
#
# THE QUESTION, and why it is worth its own stage: the native uGUI ESP draws
# pooled `UnityEngine.UI.Image` boxes, and Image construction has NEVER been
# proven live on this build. Only TextMeshProUGUI has. Everything the ESP does
# rests on an assumption nobody has measured, so its first live outcome would
# have been INCONCLUSIVE by construction.
#
# WHAT IS ALREADY SETTLED, OFFLINE, AND IS NOT RE-DERIVED HERE:
#   * the Image AddComponent<T> slot is .data 0x6D50070, whose STATIC token
#     0xC008040B decodes to AddComponent<UnityEngine.UI.Image> -- so the kind is
#     `attested`, and `aowl_nu_verdict` returns ATTESTED (proceed, loudly)
#     rather than NOREF even with no live donor Image to compare klasses
#     against. That is the ONLY reason this stage can run in the settings
#     screen, where a walked Image donor is not guaranteed.
#   * `Graphic` carries [RequireComponent(typeof(CanvasRenderer))] and Unity's
#     native AddComponent is documented to honour it. DOCUMENTED IS NOT
#     MEASURED. This stage asks `get_canvasRenderer` and reports the answer; a
#     null there is the most likely single cause of "created but invisible".
#
# WHAT MAKES AN IMAGE VISIBLE (the false-positive shape this stage refuses to
# fall into -- an Image can exist, pass every structural check, and paint
# nothing):
#   1. a live parent Canvas. Without one a Graphic is inert. Read back from
#      Graphic.m_Canvas@0x60, which OnEnable populates.
#   2. a CanvasRenderer on the SAME GameObject. See above.
#   3. a rect with real area. `nuLayout` + `get_rect_Injected` read-back.
#   4. colour ALPHA > 0. This is the quiet one: the default Color for a
#      from-scratch Graphic is whatever the managed ctor left, and an alpha of 0
#      is invisible while every other check still says yes. So the stage SETS a
#      known opaque colour and reads m_Color back RAW -- through a path that is
#      not the setter under test.
#   5. `sprite` may be NULL. That is not a defect: with m_Type == Simple and no
#      sprite, `Image.OnPopulateMesh` falls through to `Graphic.OnPopulateMesh`,
#      which emits a single quad over the rect in m_Color against the white
#      texture. A solid rectangle is exactly what an ESP box is. The stage reads
#      m_Sprite and m_Type back and SAYS what it found rather than assuming.
#   6. raycastTarget is IRRELEVANT to whether pixels appear -- it only decides
#      whether the box eats clicks. Read and reported so the ESP author knows
#      to turn it OFF, never used in the verdict.
#
# AND THE LIMIT OF THIS STAGE, STATED IN THE LOG ITSELF: even PASS does not
# prove a human would SEE the box. Every check here is a field read. Only a
# screenshot or a person settles pixels.
# ---------------------------------------------------------------------------

const NuImgProofName = "aowlspt-image-proof"
var gNuVerdictC = "not run"

proc nuImgSetColor(img: Il2CppPtr; r, g, b, a: float32): bool =
  ## `Graphic::set_color(Color)`. Win64 passes a 16-byte struct BY REFERENCE;
  ## that is not an assumption -- the method's first instruction is
  ## `movups xmm2,[rdx]`. Shape-identical to the `_Injected` setters, so the
  ## same v_pp thunk carries it, with a NULL MethodInfo (not a shared generic).
  let fn = nuFn(NuTGrSetColor)
  if fn == nil or not nuOk(img, 0x40'i32): return false
  cNuC4InSet(r, g, b, a)
  cNuCallVPP(fn, img, cNuC4InPtr())
  result = true

proc nuImgReadColor(img: Il2CppPtr): (bool, float32, float32, float32, float32) =
  ## m_Color read back RAW at 0x28. Deliberately NOT via `get_color`: reading a
  ## value back through the same property that wrote it is a self-comparison,
  ## and a self-comparison cannot fail.
  var okR = 0'i32
  var okG = 0'i32
  var okB = 0'i32
  var okA = 0'i32
  let r = cNuGetF32(img, NuOffGraphicColor,          addr okR)
  let g = cNuGetF32(img, NuOffGraphicColor + 4'i32,  addr okG)
  let b = cNuGetF32(img, NuOffGraphicColor + 8'i32,  addr okB)
  let a = cNuGetF32(img, NuOffGraphicColorA,         addr okA)
  result = (okR != 0 and okG != 0 and okB != 0 and okA != 0, r, g, b, a)

proc nuProofStageC(tabPtr: Il2CppPtr) =
  gNuVerdictC = "INCONCLUSIVE"
  okLog "nativeui PROOF C: BEGIN -- build a UnityEngine.UI.Image FROM SCRATCH " &
        "and ask the finished object whether it can render. This is the " &
        "question the native uGUI ESP is blocked on."

  nuStep("C", "mi2FindTmp: walk the tab for a live control to parent into")
  mi2FindTmp(tabPtr)
  if gMi2TmpOwner == nil:
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = INCONCLUSIVE -- no readable " &
         "control on this tab, so there is no validated live object to walk " &
         "from and no canvas to parent into. NOTHING was created; this says " &
         "nothing at all about AddComponent<Image>."
    return
  let parentGo = nuGameObjectOf(gMi2TmpOwner)
  if parentGo == nil:
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = INCONCLUSIVE -- the walked " &
         "owner has no readable GameObject; nothing was created"
    return
  okLog "nativeui PROOF C: parentGO=0x" & hexOf(cast[uint64](parentGo))

  nuStep("C", "il2cpp_object_new + GameObject::.ctor(String)")
  let go = nuCreate(NuImgProofName, parentGo)
  if go == nil:
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = INCONCLUSIVE -- the " &
         "GameObject could not be created at all, so AddComponent<Image> was " &
         "never reached (reason logged above)"
    return

  nuStep("C", "AddComponent<RectTransform> (proven live; this is the control)")
  let rt = nuAdd(go, NuKindRectTransform)
  if rt == nil:
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = INCONCLUSIVE -- even the " &
         "PROVEN RectTransform slot refused this run, so a refusal on Image " &
         "would say nothing about Image. Tearing down."
    discard nuDestroy(go)
    return

  nuStep("C", "SetParentAndAlign into the live canvas")
  if not nuParentAligned(go, parentGo):
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = INCONCLUSIVE -- could not " &
         "parent; a Graphic with no Canvas ancestor is inert and the test " &
         "would be meaningless. Tearing down."
    discard nuDestroy(go)
    return
  discard nuSetLayer(go, 5'i32)          # Unity's built-in `UI` layer

  # Same lesson Stage B paid for with a fault: on an ACTIVE GameObject the add
  # IS the render -- Awake/OnEnable fire synchronously from AddComponent, and a
  # Graphic's Awake reaches for its material/canvas. Deactivate first so there
  # is a window between "the component exists" and "the component runs".
  nuStep("C", "SetActive(false) -- defer the Graphic's Awake/OnEnable so the " &
              "add is separable from the first render")
  if not nuSetActive(go, false):
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = INCONCLUSIVE -- could not " &
         "deactivate; refusing to add a Graphic to an active object. Tearing down."
    discard nuDestroy(go)
    return

  # ------------------------------------------------------------------ THE ASK
  nuStep("C", "AddComponent<UnityEngine.UI.Image> via .data slot 0x6D50070 " &
              "(static token 0xC008040B -> AddComponent<UI.Image>). If the log " &
              "stops HERE, the answer to the whole spike is 'it faults'.")
  let img = nuAdd(go, NuKindImage)
  if img == nil:
    let st = cNuSlotState(NuKindImage)
    gNuVerdictC = (if st == NuSlotPoisoned: "FAIL" else: "INCONCLUSIVE")
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = " & gNuVerdictC &
         " -- AddComponent<Image> did not yield a usable component (slot " &
         "state " & nuSlotStateName(st) & "). The exact reason is the last " &
         "`add(UnityEngine.UI.Image)` line above. THE FALLBACK, if this " &
         "repeats: do NOT build the ESP box from scratch -- CLONE a live " &
         "Image-bearing GameObject out of the tree (Object::Instantiate, the " &
         "route Stage A and the settings-tab work both use successfully) and " &
         "re-colour/re-size the clone. That path needs no AddComponent at all."
    discard nuDestroy(go)
    return
  okLog "nativeui PROOF C: AddComponent<Image> SURVIVED -- comp=0x" &
        hexOf(cast[uint64](img)) & ", slot state " &
        nuSlotStateName(cNuSlotState(NuKindImage))

  # What the fresh component came with, BEFORE we touch anything. Diagnostics,
  # not assertions -- a NULL sprite is legal and expected.
  let sprite0 = cNuGetRef(img, NuOffImageSprite)
  let mat0    = cNuGetRef(img, NuOffGraphicMaterial)
  let (okC0, r0, g0, b0, a0) = nuImgReadColor(img)
  okLog "nativeui PROOF C: as created -- m_Sprite=0x" &
        hexOf(cast[uint64](sprite0)) & " (NULL is LEGAL: with m_Type=Simple " &
        "and no sprite, Graphic::OnPopulateMesh emits one quad over the rect " &
        "in m_Color -- a solid box, which is what an ESP box is), " &
        "m_Material=0x" & hexOf(cast[uint64](mat0)) &
        " (NULL means the Graphic will use defaultGraphicMaterial), m_Color=" &
        (if okC0: "(" & nuF(r0) & ", " & nuF(g0) & ", " & nuF(b0) & ", " &
                  nuF(a0) & ")" else: "UNREADABLE")

  nuStep("C", "nuLayout -- a KNOWN size and position, so 'nothing on screen' " &
              "cannot be blamed on a zero-area or off-screen rect")
  if not nuLayout(rt,
                  0.0'f32, 1.0'f32,      # anchorMin  (top-left)
                  0.0'f32, 1.0'f32,      # anchorMax
                  0.0'f32, 1.0'f32,      # pivot
                  240.0'f32, 120.0'f32,  # sizeDelta
                  180.0'f32, -140.0'f32): # anchoredPosition, clear of A and B
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = FAIL -- layout refused, so " &
         "the Image cannot be given a renderable rect. Tearing down."
    gNuVerdictC = "FAIL"
    discard nuDestroy(go)
    return

  nuStep("C", "SetActive(true) -- the Graphic's Awake/OnEnable runs HERE. If " &
              "the log stops here, Image construction succeeds but ACTIVATION " &
              "faults, and the fallback is the clone route.")
  discard nuSetActive(go, true)
  okLog "nativeui PROOF C: SetActive(true) returned -- the Graphic's " &
        "Awake/OnEnable SURVIVED"

  nuStep("C", "set_color(1, 0.15, 0.15, 1) -- OPAQUE. Alpha 0 is the invisible " &
              "success this stage exists to rule out.")
  let colorCalled = nuImgSetColor(img, 1.0'f32, 0.15'f32, 0.15'f32, 1.0'f32)
  nuStep("C", "SetAllDirty -- a Graphic activated after layout has no " &
              "guaranteed dirty pass; ask for one explicitly, once.")
  let dirtyFn = nuFn(NuTGrSetAllDirty)
  if dirtyFn != nil and nuOk(img, 0x40'i32):
    discard cNuCallPP(dirtyFn, img)   # void(this, MethodInfo*): RAX is ignored

  # -------------------------------------------------------- THE FINISHED STATE
  nuStep("C", "reading the finished state back")
  let (okC, cr, cg, cb, ca) = nuImgReadColor(img)
  let crFn = nuFn(NuTGrGetCanvasRend)
  var canvasRend: Il2CppPtr = nil
  if crFn != nil and nuOk(img, 0x40'i32):
    canvasRend = cNuCallPP(crFn, img)
  let canvasCache = cNuGetRef(img, NuOffGraphicCanvas)
  let (okRect, rx, ry, rw, rh) = nuGetRect(rt)
  let (okSz, sw, sh) = nuGetSize(rt)
  let active = nuActiveInHierarchy(go)
  let alive = nuAlive(img)
  let renderable = okRect and cNuRectRenderable(rw, rh) != 0'i32
  let hasCr = nuOk(canvasRend, 0x10'i32)
  let hasCanvas = nuOk(canvasCache, 0x10'i32)
  let colorOk = okC and ca > 0.01'f32 and
                cr > 0.9'f32 and cg < 0.3'f32 and cb < 0.3'f32
  let sizeOk = okSz and sw > 239.0'f32 and sw < 241.0'f32 and
               sh > 119.0'f32 and sh < 121.0'f32

  okLog "nativeui PROOF C: CanvasRenderer = 0x" &
        hexOf(cast[uint64](canvasRend)) & " readable=" & $hasCr &
        "  <-- this is the [RequireComponent] question: true means Unity's " &
        "native AddComponent DID auto-add it and no explicit add is needed"
  okLog "nativeui PROOF C: Graphic.m_Canvas = 0x" &
        hexOf(cast[uint64](canvasCache)) & " readable=" & $hasCanvas &
        "  (OnEnable fills this from the parent chain; null means the object " &
        "is not under a live Canvas and cannot render whatever else is true)"
  okLog "nativeui PROOF C: m_Color read back RAW @0x28 = " &
        (if okC: "(" & nuF(cr) & ", " & nuF(cg) & ", " & nuF(cb) & ", " &
                 nuF(ca) & ")" else: "UNREADABLE") &
        "  setterCalled=" & $colorCalled & " matchesWhatWasSet=" & $colorOk
  if okRect:
    okLog "nativeui PROOF C: rect AFTER layout = (" & nuF(rx) & ", " &
          nuF(ry) & ", " & nuF(rw) & ", " & nuF(rh) & ")  renderable=" &
          $renderable
  else:
    warn "nativeui PROOF C: the rect could not be read back"
  okLog "nativeui PROOF C: sizeDelta = " &
        (if okSz: "(" & nuF(sw) & ", " & nuF(sh) & ")" else: "UNREADABLE") &
        " matches240x120=" & $sizeOk
  okLog "nativeui PROOF C: activeInHierarchy=" & $active & " aliveByUnity=" &
        $alive & " (a destroyed Unity object stays READABLE with m_CachedPtr " &
        "zeroed, so readability is not liveness)"

  if not okRect or not okC or not okSz:
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = INCONCLUSIVE -- a required " &
         "read-back failed (rect=" & $okRect & " color=" & $okC & " size=" &
         $okSz & "), so nothing is settled. 'I could not look' is NOT a pass. " &
         "The object is left in place at 0x" & hexOf(cast[uint64](go)) &
         " for the inspector."
    gNuVerdictC = "INCONCLUSIVE"
    okLog "nativeui PROOF C: END (verdict " & gNuVerdictC & ")"
    return

  if renderable and active and alive and hasCr and hasCanvas and
     colorOk and sizeOk:
    gNuVerdictC = "PASS"
    okLog "nativeui PROOF C: IMAGEPROOF VERDICT = PASS -- a " &
          "UnityEngine.UI.Image was built FROM SCRATCH (object_new + ctor + " &
          "AddComponent<Image>), it carries an auto-added CanvasRenderer, it " &
          "sits under a live Canvas, its rect is 240x120 with real area, and " &
          "its colour reads back opaque red. THIS DOES NOT PROVE A HUMAN " &
          "WOULD SEE IT. Every check above is a field read; only a screenshot " &
          "or a person settles pixels. Look for a solid red 240x120 box near " &
          "the top-left of the settings panel, or run " &
          "`find " & NuImgProofName & "` in the live inspector."
  else:
    gNuVerdictC = "FAIL"
    warn "nativeui PROOF C: IMAGEPROOF VERDICT = FAIL -- the Image was " &
         "CREATED but a finished-state read disagrees: renderable=" &
         $renderable & " activeInHierarchy=" & $active & " aliveByUnity=" &
         $alive & " canvasRenderer=" & $hasCr & " underLiveCanvas=" &
         $hasCanvas & " colorAsSet=" & $colorOk & " sizeAsSet=" & $sizeOk &
         ". Whichever of those is false is the reason the ESP would draw " &
         "nothing. Left in place at 0x" & hexOf(cast[uint64](go)) &
         " so the inspector can be pointed at it."
  okLog "nativeui PROOF C: END (verdict " & gNuVerdictC & ")"

# ---- the guards ------------------------------------------------------------
# ONE `aowl_p_p_seh` per stage, run SEQUENTIALLY. Not nested: the guard is not
# re-entrant and an inner guard disarms the outer one. Two sequential guards
# are two separate protected regions, which is exactly what lets a fault in B
# leave A's verdict standing.
{.emit: """
extern void* aowl_nu_proof_body(void* a);
static int g_aowl_nu_stage = 0;
static int aowl_nu_stage_get(void) { return g_aowl_nu_stage; }
static void* aowl_nu_proof_guarded(void* a, int stage) {
    g_aowl_nu_stage = stage;
    return aowl_p_p_seh((void*)aowl_nu_proof_body, a);
}
""".}
proc cNuStageGet(): int32 {.importc: "aowl_nu_stage_get", nodecl.}
proc cNuProofGuarded(a: Il2CppPtr; stage: int32): Il2CppPtr {.
  importc: "aowl_nu_proof_guarded", nodecl.}

proc nuProofBodyC(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_nu_proof_body", cdecl.} =
  case int(cNuStageGet())
  of 1: nuProofStageA(a)
  of 2: nuProofStageB(a)
  of 3: nuProofStageC(a)
  else: discard
  result = cast[Il2CppPtr](1)

proc nuProofRun(tab: Il2CppPtr) =
  ## Runs at most once per session, whatever the outcome -- a second run would
  ## build a second label and the screen would stop being evidence.
  if not gNuOn or (not gNuProof and not gNuImgProof) or gNuProofDone: return
  if cNuDisabled() != 0'i32:
    warn "nativeui: the layer has self-disabled after " &
         $int(cNuFaultCount()) & " fault(s); the proof will not run"
    return
  gNuProofDone = true

  if gNuProof and cNuProofGuarded(tab, 1'i32) == nil:
    cNuNoteFault()
    gNuVerdictA = "FAULTED"
    warn "nativeui PROOF A: FAULTED -- the VEH guard caught it and the game " &
         "survived. The last `nativeui PROOF A: ->` breadcrumb above names " &
         "the exact call it died in. Fault count is now " &
         $int(cNuFaultCount()) & " of 6."

  # Stage B runs even if A faulted: they are independent questions, and the
  # fault budget (6) is what stops a genuinely broken build from retrying
  # forever.
  if gNuProof:
    if cNuDisabled() == 0'i32:
      if cNuProofGuarded(tab, 2'i32) == nil:
        cNuNoteFault()
        gNuVerdictB = "FAULTED"
        warn "nativeui PROOF B: FAULTED -- the VEH guard caught it and the " &
             "game survived. The last `nativeui PROOF B: ->` breadcrumb above " &
             "names the exact call it died in. Fault count is now " &
             $int(cNuFaultCount()) & " of 6."
    else:
      warn "nativeui PROOF B: skipped -- the layer self-disabled during Stage A"

  # STAGE C -- the Image spike. A THIRD sequential guarded region, never a
  # nested one: `aowl_p_p_seh` is not re-entrant and an inner guard would
  # disarm the outer. Sequential is what lets C fault without erasing A and B.
  # Gated on its own flag so it can be run ALONE, which is the cheapest way to
  # settle the ESP question without also rebuilding two labels on screen.
  if gNuImgProof:
    if cNuDisabled() == 0'i32:
      if cNuProofGuarded(tab, 3'i32) == nil:
        cNuNoteFault()
        gNuVerdictC = "FAULTED"
        warn "nativeui PROOF C: IMAGEPROOF VERDICT = FAULTED -- the VEH guard " &
             "caught it and the game survived. The last `nativeui PROOF C: ->` " &
             "breadcrumb above names the exact call it died in; if that " &
             "breadcrumb is the AddComponent<Image> one, the answer to the " &
             "spike is that Image CANNOT be constructed from scratch on this " &
             "build and the ESP must clone a live Image instead. Fault count " &
             "is now " & $int(cNuFaultCount()) & " of 6."
    else:
      warn "nativeui PROOF C: IMAGEPROOF VERDICT = INCONCLUSIVE -- skipped, " &
           "the layer had already self-disabled after " &
           $int(cNuFaultCount()) & " fault(s). Nothing was attempted."

  okLog "nativeui PROOF: OVERALL  A=" & gNuVerdictA & "  B=" & gNuVerdictB &
        "  C(image)=" & gNuVerdictC &
        ".  A is the CLONE+LAYOUT path (everything but the layout was already " &
        "proven live); B is the FROM-SCRATCH path. A passing while B does not " &
        "still means mods can build visible UI today."

  # The slot census, so the log alone says which kinds are usable.
  for k in 0 ..< int(cNuKindCount()):     # capped: AOWL_NU_MAX_KINDS
    okLog "nativeui PROOF: slot " & readCString(cNuKindName(int32(k))) &
          " @ .data 0x" & hexOf(uint64(cNuKindSlotRva(int32(k)))) & " -> " &
          nuSlotStateName(cNuSlotState(int32(k)))

proc bindNativeUi(verbose: bool) =
  ## No detour of its own, by design. Two detours on one function have the
  ## second overwrite the first's trampoline and silently kill the first
  ## feature, and the only proven Unity-thread point where a live SettingsScreen
  ## AND built controls both exist is already taken by invoke2's POSTFIX hook on
  ## `SettingsScreen::EnsureTabInitialized`. So this RIDES that detour as a
  ## drain instead of binding a second one.
  ##
  ## All this does is report the target census, once, so an unverified build is
  ## obvious in the log before any operation is attempted rather than as
  ## twenty-five separate refusals.
  if not gNuOn: return
  # ORDER MATTERS, and getting it wrong is what the first live run reported.
  # This census must run AFTER `cProPrimeAll()` and after GameAssembly.dll is
  # loaded -- i.e. from the same `gReady` bind region every other feature binds
  # in, not from the flag-reading pass. Run early, every `aowl_nu_fn` refuses
  # with WHY_NO_MODULE, and the old census called that "25 REJECTED" and
  # blamed the build. Ask the question once, here, and say so plainly.
  if cNuBaseOk() == 0'i32:
    warn "nativeui: GameAssembly.dll is not loaded, so no target can be " &
         "verified yet. This is a START-ORDER problem in the host, NOT a bad " &
         "RVA and NOT a stale game build. Refusing to run the census -- " &
         "reporting 25 rejections here would be a confidently wrong " &
         "diagnostic, which is worse than none."
    return
  var ok = 0
  var bad = 0
  for i in 0 ..< int(cNuTargetCount()):   # capped by the table size
    if cNuFn(int32(i)) != nil: inc ok else: inc bad
  let mism = int(cNuMismatchCount())
  okLog "nativeui: " & $ok & " of " & $int(cNuTargetCount()) &
        " managed targets verified by RVA + startup-snapshot prologue on this " &
        "build" &
        (if bad > 0: " (" & $bad & " refused, of which " & $mism &
                     " for a PROLOGUE MISMATCH)" else: "")
  if mism > 0:
    warn "nativeui: " & $mism & " target(s) failed the BYTE COMPARE against " &
         "the startup snapshot. That is the real 'this is not the build these " &
         "RVAs came from' signal, and the operations needing them are refused " &
         "rather than calling an address whose bytes are not what this " &
         "build's metadata says."
  elif bad > 0:
    warn "nativeui: " & $bad & " target(s) were refused, but NONE of them for " &
         "a byte mismatch -- so this is not a wrong-build problem. Each " &
         "refusal above names its own reason."
  for k in 0 ..< int(cNuKindCount()):
    if verbose:
      info "nativeui: component kind " & readCString(cNuKindName(int32(k))) &
           " -> AddComponent<T> MethodInfo* cache slot .data 0x" &
           hexOf(uint64(cNuKindSlotRva(int32(k)))) & "; evidence: " &
           readCString(cNuKindEvidence(int32(k)))
  if gNuProof:
    okLog "nativeui: the visual self-proof is ARMED. It rides invoke2's " &
          "POSTFIX detour on SettingsScreen::EnsureTabInitialized, so it needs " &
          "`managedInvokeProbe` on as well; open Settings and click a tab."
