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

proc cNuV3OutPtr(): Il2CppPtr {.importc: "aowl_nu_v3out_ptr", nodecl.}
proc cNuV3OutX(): float32 {.importc: "aowl_nu_v3out_x", nodecl.}
proc cNuV3OutY(): float32 {.importc: "aowl_nu_v3out_y", nodecl.}
proc cNuV3OutZ(): float32 {.importc: "aowl_nu_v3out_z", nodecl.}
proc cNuCallVPBB(fn, self: Il2CppPtr; a0, a1: int32) {.
  importc: "aowl_nu_call_v_pbb", nodecl.}
proc cNuCallPS3PPB(fn, a0, a1: Il2CppPtr; a2: int32): Il2CppPtr {.
  importc: "aowl_nu_call_p_s3ppb", nodecl.}
proc cNuCallVPFFP(fn, self: Il2CppPtr; a0, a1: float32; a2: Il2CppPtr) {.
  importc: "aowl_nu_call_v_pffp", nodecl.}
proc cNuCallFP(fn, self: Il2CppPtr; defVal: float32): float32 {.
  importc: "aowl_nu_call_f_p", nodecl.}
proc cNuCallBSi(fn: Il2CppPtr; a0: int32): int32 {.
  importc: "aowl_nu_call_b_si", nodecl.}
proc cNuTargetName(i: int32): cstring {.importc: "aowl_nu_target_name", nodecl.}
proc cNuTargetRva(i: int32): uint32 {.importc: "aowl_nu_target_rva", nodecl.}
# `cNuTargetCount` is already declared at the top of this file -- do not
# re-declare it here; nimony reports the duplicate as an AMBIGUOUS CALL at the
# use site rather than as a redefinition, which reads like a name collision
# with something else entirely.

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
  NuTInputMouseBtn   = 32'i32  ## UnityEngine.Input::GetMouseButton
  NuTInputMousePos   = 33'i32  ## UnityEngine.Input::get_mousePosition_Injected
  NuTTrGetPosition   = 34'i32  ## UnityEngine.Transform::get_position_Injected
  NuTTrGetLossyScale = 35'i32  ## UnityEngine.Transform::get_lossyScale_Injected
  # --- the settings-row PREFAB path. Provenance, sharedness and the two
  # cross-checked prologues are on the rows themselves in
  # `abi/aowlspt_nativeui.h`; do not restate a number here, restate the index.
  NuTSetCtrlSetText   = 36'i32  ## EFT.UI.Settings.SettingControl::SetText
  NuTSetCtrlSetName   = 37'i32  ## EFT.UI.Settings.SettingControl::SetName
  NuTSetCtrlSetSibIdx = 38'i32  ## EFT.UI.Settings.SettingControl::SetSiblingIndex
  NuTSetCtrlSetChange = 39'i32  ## EFT.UI.Settings.SettingControl::SetChangeAction
  NuTObjInstantiate3  = 40'i32  ## UnityEngine.Object::Instantiate(Object,Transform,bool)
  NuTNumSliderShow    = 41'i32  ## EFT.UI.NumberSlider::Show
  NuTNumSliderSetCur  = 42'i32  ## EFT.UI.NumberSlider::SetCurrentValue
  NuTNumSliderCurVal  = 43'i32  ## EFT.UI.NumberSlider::CurrentValue
  NuTAnimTogSetToggled= 44'i32  ## EFT.UI.AnimatedToggle::set_IsToggled
  NuTSpawnTogSetToggled=45'i32  ## EFT.UI.UISpawnableToggle::set_IsToggled
  # The three geometry GETTERS this table was missing. Same
  # (this, Vector2* ret, MethodInfo*) shape as the two it already had, so
  # `nuGetV2` serves them unchanged. Added for `nuCopyGeometry`.
  NuTRtGetAnchorMin  = 46'i32  ## UnityEngine.RectTransform::get_anchorMin_Injected
  NuTRtGetAnchorMax  = 47'i32  ## UnityEngine.RectTransform::get_anchorMax_Injected
  NuTRtGetPivot      = 48'i32  ## UnityEngine.RectTransform::get_pivot_Injected
  NuTLayoutElemIgnore= 49'i32  ## UnityEngine.UI.LayoutElement::set_ignoreLayout
  NuTRectOffGetTop   = 50'i32  ## UnityEngine.RectOffset::get_top
  NuTRectOffSetTop   = 51'i32  ## UnityEngine.RectOffset::set_top
  NuTLayoutGrpDirty  = 52'i32  ## UnityEngine.UI.LayoutGroup::SetDirty
  NuTTrSetAsLastSib  = 53'i32  ## UnityEngine.Transform::SetAsLastSibling
  NuTTrGetSiblingIdx = 54'i32  ## UnityEngine.Transform::GetSiblingIndex
  # --- native tabs (docs/NATIVETABS.md). Two are SHARED and are CALLED only.
  NuTBehaviourEnable = 55'i32  ## UnityEngine.Behaviour::set_enabled
  NuTSpawnerSpawn    = 56'i32  ## EFT.UI.UIAnimatedToggleSpawner::SpawnObject
  NuTSpawnerHeader   = 57'i32  ## EFT.UI.UIAnimatedToggleSpawner::SetHeaderText
  NuTSpawnerActive   = 58'i32  ## EFT.UI.UIAnimatedToggleSpawner::SetActive
  NuTTabCleanupCtrls = 59'i32  ## EFT.UI.Settings.SettingsTab::CleanupCreatedControls
  NuTToggleSetGroup  = 60'i32  ## UnityEngine.UI.Toggle::set_group
  NuTToggleSet       = 61'i32  ## UnityEngine.UI.Toggle::Set
  NuTCgGetAlpha      = 62'i32  ## UnityEngine.CanvasGroup::get_alpha
  NuTCgSetAlpha      = 63'i32  ## UnityEngine.CanvasGroup::set_alpha
  NuTCgGetInteract   = 64'i32  ## UnityEngine.CanvasGroup::get_interactable
  NuTCgSetInteract   = 65'i32  ## UnityEngine.CanvasGroup::set_interactable
  NuTCgSetBlocksRay  = 66'i32  ## UnityEngine.CanvasGroup::set_blocksRaycasts

## Field offsets for the tab machinery. MEASURED (tools/fldoff.py, String
## self-check passing) and written up in docs/NATIVETABS.md. All NULL-CAPABLE.
const
  NuOffSpawnerToggleGroup = 0xb0'i32  ## UIAnimatedToggleSpawner._toggleGroup
  NuOffSpawnerSiblingIdx  = 0xbc'i32  ## ._siblingIndex : int
  NuOffSpawnerPrefab      = 0xc0'i32  ## ._spawnableToggle : UISpawnableToggle
  NuOffToggleGroup        = 0x110'i32 ## UnityEngine.UI.Toggle.m_Group
  NuOffToggleIsOn         = 0x120'i32 ## UnityEngine.UI.Toggle.m_IsOn
  NuOffTabCreatedControls = 0x88'i32  ## SettingsTab._createdControls
  NuOffGameTabSettingsRoot = 0x98'i32 ## GameSettingsTab._settingsRoot

## `LayoutGroup.m_Padding` @0x20 : RectOffset. A plain reference field, so it
## is READ raw -- no call, and in particular not `get_padding`, which is
## SHARED x479. MEASURED via tools/fldoff.py, System.String self-check passed.
## NULL-CAPABLE: a group with no padding assigned reads null here.
const NuOffLayoutGroupPadding = 0x20'i32

# ---- field offsets on the settings-row prefabs --------------------------
#
# MEASURED offline from Il2CppMetadataRegistration.fieldOffsets
# (`tools/il2cpp_resolve.py ... fields <Type>`, System.String self-check
# passed), 2026-09-01, and written up in `docs/NATIVE-CONTROLS.md`.
#
# `NuOffSettingCtrlText` is CROSS-CONFIRMED by disassembly and not only by the
# field table: `SettingControl::SetText` @0x16FA890 opens
# `mov rbx,rcx ; mov rcx,[rcx+0x80]`, which is this exact field. Two
# independent sources agreeing is the only reason an offset is trusted here.
#
# Every one of these is NULL-CAPABLE -- they are serialized Unity references
# populated when the prefab loads, so a read before the owning tab's Awake
# gets null. Nothing below may be dereferenced without a readability check.
const
  NuOffSettingCtrlText   = 0x80'i32  ## SettingControl.Text : LocalizedText
  NuOffSettingToggleTog  = 0xa8'i32  ## SettingToggle.Toggle : UpdatableToggle
  NuOffFloatSliderSlider = 0xa8'i32  ## SettingFloatSlider.Slider : NumberSlider
  NuOffSettingsTabMade   = 0x88'i32  ## SettingsTab._createdControls : List<SettingControl>

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

type
  NuGeom* = object
    ## One RectTransform's layout, read off a LIVE object. `ok` is false when
    ## any single getter refused -- a partially-read geometry is worse than
    ## none, because it looks like a measurement.
    ok*: bool
    aMinX*, aMinY*, aMaxX*, aMaxY*: float32
    pivX*, pivY*: float32
    sdX*, sdY*: float32
    ## anchoredPosition. Carried because the DISPLACEMENT check needs it: a
    ## LayoutGroup that pushes a sibling down moves this, not sizeDelta.
    posX*, posY*: float32
    ## The RESOLVED width/height from `get_rect`, which is NOT `sizeDelta`:
    ## for a stretched anchor sizeDelta is an INSET, and a row that stretches
    ## edge-to-edge legitimately reports sizeDelta.x = 0 while rect.width is
    ## the panel width. Both are carried because the copy needs sizeDelta and
    ## the CHECK needs rect.
    rectW*, rectH*: float32
    ## rect.x / rect.y -- the rect's ORIGIN in this object's own local space,
    ## which for a centre-pivoted object is negative. Needed to place a child
    ## edge in a parent's coordinates; discarding it was why the first attempt
    ## at that arithmetic could only work for top-anchored parents.
    rectX*, rectY*: float32

proc nuBehaviourEnable*(behaviour: Il2CppPtr; on: bool): bool =
  ## `Behaviour.enabled = value`. SHARED x32 -- CALLED, never detoured: it is
  ## the correct code for whatever receiver is in RCX, and detouring a shared
  ## RVA fires for every one of its 32 owners.
  result = false
  if not gNuOn or not nuOk(behaviour, 0x18'i32): return
  let fn = nuFn(NuTBehaviourEnable)
  if fn == nil: return
  cNuCallVPB(fn, behaviour, (if on: 1'i32 else: 0'i32))
  true

proc nuSpawnerSpawn*(spawner: Il2CppPtr): Il2CppPtr =
  ## `UIAnimatedToggleSpawner.SpawnObject()` -> AnimatedToggle. The game's own
  ## tab-button factory; the spawned toggle is a genuine prefab instance of
  ## `_spawnableToggle @0xC0`, not a relabelled donor.
  result = nil
  if not gNuOn or not nuOk(spawner, NuOffSpawnerPrefab + 8'i32): return
  let fn = nuFn(NuTSpawnerSpawn)
  if fn == nil: return
  result = cNuCallPP(fn, spawner)
  if not nuOk(result, 0x10'i32): result = nil

proc nuSpawnerHeader*(spawner: Il2CppPtr; caption: string; size: int32): bool =
  result = false
  if not gNuOn or not nuOk(spawner, 0x10'i32): return
  let fn = nuFn(NuTSpawnerHeader)
  if fn == nil: return
  let sp = nuStr(caption)
  if sp == nil: return
  cNuCallVPPB(fn, spawner, sp, size)
  true

proc nuSpawnerActive*(spawner: Il2CppPtr; on: bool): bool =
  result = false
  if not gNuOn or not nuOk(spawner, 0x10'i32): return
  let fn = nuFn(NuTSpawnerActive)
  if fn == nil: return
  cNuCallVPB(fn, spawner, (if on: 1'i32 else: 0'i32))
  true

proc nuTabCleanupControls*(tab: Il2CppPtr): bool =
  ## `SettingsTab.CleanupCreatedControls()` -- destroys everything in the tab's
  ## own `_createdControls @0x88`. Called on a panel WE cloned, to empty it of
  ## the stock rows it was cloned with. Never on a panel the game owns.
  result = false
  if not gNuOn or not nuOk(tab, NuOffTabCreatedControls + 8'i32): return
  let fn = nuFn(NuTTabCleanupCtrls)
  if fn == nil: return
  discard cNuCallPP(fn, tab)
  true

proc nuToggleSetGroup*(toggle, group: Il2CppPtr): bool =
  ## `Toggle.group = value` -- the PROPERTY, so the group's own bookkeeping
  ## runs. Joining the stock ToggleGroup is what makes tab exclusivity NATIVE:
  ## the game turns the other tabs off for us and we enforce nothing.
  result = false
  if not gNuOn or not nuOk(toggle, NuOffToggleGroup + 8'i32): return
  let fn = nuFn(NuTToggleSetGroup)
  if fn == nil: return
  cNuCallVPP(fn, toggle, group)
  true

proc nuCgRead*(cg: Il2CppPtr): (bool, float32, bool) =
  ## (ok, alpha, interactable) off a live CanvasGroup. READ FIRST: a clone that
  ## inherited alpha 0 / interactable false from a hidden donor is invisible
  ## and inert while every call we make on it still succeeds.
  result = (false, 0.0'f32, false)
  if not gNuOn or not nuOk(cg, 0x18'i32): return
  let fa = nuFn(NuTCgGetAlpha)
  let fi = nuFn(NuTCgGetInteract)
  if fa == nil or fi == nil: return
  let a = cNuCallFP(fa, cg, -1.0'f32)
  if not (a > -0.5'f32): return
  result = (true, a, cNuCallBP(fi, cg) != 0'i32)

proc nuCgMakeUsable*(cg: Il2CppPtr): bool =
  ## alpha 1, interactable, blocksRaycasts -- on a CanvasGroup WE cloned.
  ## Read-validate-write: only written when it is not already usable.
  result = false
  if not gNuOn or not nuOk(cg, 0x18'i32): return
  let fA = nuFn(NuTCgSetAlpha)
  let fI = nuFn(NuTCgSetInteract)
  let fB = nuFn(NuTCgSetBlocksRay)
  if fA == nil or fI == nil or fB == nil: return
  cNuCallVPF(fA, cg, 1.0'f32)
  cNuCallVPB(fI, cg, 1'i32)
  cNuCallVPB(fB, cg, 1'i32)
  true

proc nuTogglePress*(toggle: Il2CppPtr; on: bool): bool =
  ## `Toggle::Set(value, sendCallback: true)` -- a REAL press.
  ##
  ## sendCallback=true is the whole point: it runs the game's own
  ## onValueChanged and lets the ToggleGroup enforce exclusivity, which is what
  ## a proof of selection has to exercise. Writing `m_IsOn` raw would prove
  ## nothing about the screen -- that is the mistake the subtab strip made, and
  ## it is why its verdict passed while the wrong panel was showing.
  ##
  ## Our own `Toggle::Set` postfix ignores sendCallback=false, so this press
  ## DOES re-enter it -- which is correct here: the tick must see the press it
  ## just made exactly as it would see the player's.
  result = false
  if not gNuOn or not nuOk(toggle, NuOffToggleIsOn + 4'i32): return
  let fn = nuFn(NuTToggleSet)
  if fn == nil: return
  cNuCallVPBB(fn, toggle, (if on: 1'i32 else: 0'i32), 1'i32)
  true

proc nuToggleIsOn*(toggle: Il2CppPtr): (bool, bool) =
  ## `m_IsOn @0x120`, read raw. A read, so the field is fine; the WRITE path is
  ## the property, because a raw store never fires the Animator (measured).
  ## Read through `cNuGetRef`-style pointer arithmetic done here rather than
  ## with a u8 accessor: the byte reader lives in `settingswrite.nim`, which is
  ## included AFTER this file, and `duPtrAdd` in `debugui.nim`, likewise. So the
  ## address is formed locally and read as i32 -- m_IsOn is a bool at 0x120
  ## with further fields after it, so a 4-byte read is in bounds once `nuOk`
  ## has cleared it, and only the low byte is used.
  result = (false, false)
  if not nuOk(toggle, NuOffToggleIsOn + 4'i32): return
  let addr2 = cast[Il2CppPtr](cast[uint64](toggle) + uint64(NuOffToggleIsOn))
  result = (true, (cReadI32At(addr2) and 0xFF'i32) != 0'i32)

proc nuSetAsLastSibling*(rt: Il2CppPtr): bool =
  ## `Transform::SetAsLastSibling()` -- LAST in the parent's child list.
  ##
  ## In a Unity canvas sibling order is BOTH draw order and raycast order, so
  ## this is what puts an absolutely-positioned overlay in front of its
  ## siblings AND makes it clickable. A child at sibling 0 renders under every
  ## later sibling and the one on top swallows the click, which reads exactly
  ## like a disabled control while `m_Interactable` is true.
  result = false
  if not gNuOn or not nuOk(rt, 0x10'i32): return
  let fn = nuFn(NuTTrSetAsLastSib)
  if fn == nil: return
  # arity 0: the frame is (this, MethodInfo*). `p_p`, and the void return is
  # discarded -- `v_pp` would shift the MethodInfo* into R8.
  discard cNuCallPP(fn, rt)
  true

proc nuSiblingIndex*(rt: Il2CppPtr): (bool, int32) =
  ## `Transform::GetSiblingIndex()`. The READBACK, so a reordering can be
  ## asserted rather than assumed. The sentinel is negative because a real
  ## sibling index never is.
  const NuSibNoRead = -1'i32
  result = (false, 0'i32)
  if not gNuOn or not nuOk(rt, 0x10'i32): return
  let fn = nuFn(NuTTrGetSiblingIdx)
  if fn == nil: return
  let v = cNuCallIP(fn, rt, NuSibNoRead)
  if v < 0'i32 or v > 4096'i32: return
  result = (true, v)

proc nuGroupPadding*(layoutGroup: Il2CppPtr): Il2CppPtr =
  ## `LayoutGroup.m_Padding` @0x20 -> RectOffset. Read raw on purpose: the
  ## property getter is SHARED x479 and this is an ordinary reference field.
  result = nil
  if not nuOk(layoutGroup, NuOffLayoutGroupPadding + 8'i32): return
  result = cNuGetRef(layoutGroup, NuOffLayoutGroupPadding)
  if not nuOk(result, 0x18'i32): result = nil

proc nuPaddingTop*(rectOffset: Il2CppPtr): (bool, int32) =
  ## `RectOffset.top`. A RectOffset is a managed wrapper over a NATIVE pointer
  ## (`m_Ptr` @0x10), so `top` is not a field anywhere -- it has to be the
  ## property. The sentinel is a value no padding can hold, so "could not ask"
  ## is never mistaken for 0, which IS a legal padding.
  const NuPadNoRead = -999999'i32
  result = (false, 0'i32)
  if not gNuOn or not nuOk(rectOffset, 0x18'i32): return
  let fn = nuFn(NuTRectOffGetTop)
  if fn == nil: return
  let v = cNuCallIP(fn, rectOffset, NuPadNoRead)
  if v == NuPadNoRead: return
  if v < -10000'i32 or v > 10000'i32: return
  result = (true, v)

proc nuSetPaddingTop*(rectOffset, layoutGroup: Il2CppPtr; v: int32): bool =
  ## Write `RectOffset.top` and then mark the group dirty.
  ##
  ## THE SetDirty IS NOT OPTIONAL. `RectOffset` is a shared native object; the
  ## group caches its arrangement and will not re-read padding until something
  ## invalidates it. Writing the padding alone changes nothing on screen and
  ## every call reports success -- the same shape as the `m_IsOn` store that
  ## never fired the Animator and the raw `m_IgnoreLayout` store that never
  ## re-ran the group. Third time this exact trap has appeared in this feature.
  result = false
  if not gNuOn or not nuOk(rectOffset, 0x18'i32): return
  if v < -10000'i32 or v > 10000'i32: return
  let fnSet = nuFn(NuTRectOffSetTop)
  let fnDirty = nuFn(NuTLayoutGrpDirty)
  if fnSet == nil or fnDirty == nil: return
  cNuCallVPI(fnSet, rectOffset, v)
  if nuOk(layoutGroup, 0x10'i32):
    # arity 0, so the frame is (this, MethodInfo*) -- `p_p`, not `v_pp`. The
    # void return is discarded; `v_pp` would shift the MethodInfo* into R8 and
    # leave a stray value in RDX, which happens to be harmless here and would
    # be a real bug on any callee that reads it.
    discard cNuCallPP(fnDirty, layoutGroup)
  true

proc nuSetIgnoreLayout*(layoutElement: Il2CppPtr; on: bool): bool =
  ## `LayoutElement.ignoreLayout = value` -- the PROPERTY, never the field.
  ##
  ## Setting `m_IgnoreLayout` @0x20 raw would compile, run, and change nothing
  ## the player can see: the property also calls `LayoutElement::SetDirty`
  ## @0x5598490, which is what makes the parent LayoutGroup re-run. A raw store
  ## leaves the group holding its old arrangement -- the same class of mistake
  ## as writing `Toggle.m_IsOn` and expecting the Animator to notice.
  ##
  ## This is how our subtab strip stops being something the group MEASURES.
  ## Making the strip's preferred height small was tried first and failed live:
  ## a layout child is allocated space no matter how small it claims to be, and
  ## that space comes out of the stock scroll view.
  result = false
  if not gNuOn or not nuOk(layoutElement, 0x24'i32): return
  let fn = nuFn(NuTLayoutElemIgnore)
  if fn == nil: return
  cNuCallVPB(fn, layoutElement, (if on: 1'i32 else: 0'i32))
  true

proc nuNoGeom*(): NuGeom =
  ## The "nothing was measured" value. Exists so a caller never has to declare
  ## an uninitialised NuGeom: `ok = false` is the only honest starting state,
  ## and a zeroed geometry that read as ok would be a fabricated rectangle.
  NuGeom(ok: false, aMinX: 0'f32, aMinY: 0'f32, aMaxX: 0'f32, aMaxY: 0'f32,
         pivX: 0'f32, pivY: 0'f32, sdX: 0'f32, sdY: 0'f32,
         posX: 0'f32, posY: 0'f32, rectW: 0'f32, rectH: 0'f32,
         rectX: 0'f32, rectY: 0'f32)

proc nuReadGeom*(rt: Il2CppPtr): NuGeom =
  ## Read a RectTransform's whole layout. Every getter is byte-verified through
  ## `nuFn`; a refusal anywhere makes the whole result `ok = false`.
  result = nuNoGeom()
  if not gNuOn or not nuOk(rt, 0x10'i32): return
  let (o1, a1, b1) = nuGetV2(rt, NuTRtGetAnchorMin)
  if not o1: return
  let (o2, a2, b2) = nuGetV2(rt, NuTRtGetAnchorMax)
  if not o2: return
  let (o3, a3, b3) = nuGetV2(rt, NuTRtGetPivot)
  if not o3: return
  let (o4, a4, b4) = nuGetV2(rt, NuTRtGetSizeDelta)
  if not o4: return
  let (o6, a6, b6) = nuGetV2(rt, NuTRtGetAnchoredPos)
  if not o6: return
  let (o5, rxx, ryy, rw, rh) = nuGetRect(rt)
  if not o5: return
  # NaN-safe bounds. A getter that did not write leaves whatever was in the
  # buffer, and "a plausible number" is the failure mode this whole layer
  # exists to refuse.
  if not (rw > -1.0e6'f32) or not (rw < 1.0e6'f32): return
  if not (rh > -1.0e6'f32) or not (rh < 1.0e6'f32): return
  result = NuGeom(ok: true, aMinX: a1, aMinY: b1, aMaxX: a2, aMaxY: b2,
                  pivX: a3, pivY: b3, sdX: a4, sdY: b4, posX: a6, posY: b6,
                  rectW: rw, rectH: rh, rectX: rxx, rectY: ryy)

proc nuChildEdgeInParent*(parentG, childG: NuGeom): (bool, float32, float32) =
  ## Where are a child's TOP and LEFT edges, expressed in its PARENT's local
  ## coordinates? Returns (ok, top, left).
  ##
  ## WHY THIS EXISTS. The first version of this arithmetic read the child's
  ## `anchoredPosition` as if it were an offset from the parent's top edge.
  ## That is only true for a top-anchored, top-pivoted child, and the real
  ## container is centre-pivoted and vertically STRETCHED
  ## (anchorMin=(0.5,0) anchorMax=(0.5,1) pivot=(0.5,0.5) sizeDelta=(850,0)),
  ## whose `anchoredPosition` is (0,0) BY CONSTRUCTION and says nothing about
  ## where any edge is. Refusing was correct; this is the general answer.
  ##
  ## Unity's own model, and it needs no special cases:
  ##   the anchor rect is the parent's rect sampled at anchorMin..anchorMax;
  ##   `anchoredPosition` positions the child's PIVOT relative to that rect
  ##   sampled again at the pivot;
  ##   the child's size is whatever `get_rect` says it resolved to.
  ## So every term is read off the two live objects and nothing is assumed
  ## about how either is anchored.
  result = (false, 0'f32, 0'f32)
  if not parentG.ok or not childG.ok: return
  if parentG.rectH <= 0'f32 or parentG.rectW <= 0'f32: return
  let aMinY = parentG.rectY + childG.aMinY * parentG.rectH
  let aMaxY = parentG.rectY + childG.aMaxY * parentG.rectH
  let refY  = aMinY + (aMaxY - aMinY) * childG.pivY
  let top   = refY + childG.posY + (1.0'f32 - childG.pivY) * childG.rectH
  let aMinX = parentG.rectX + childG.aMinX * parentG.rectW
  let aMaxX = parentG.rectX + childG.aMaxX * parentG.rectW
  let refX  = aMinX + (aMaxX - aMinX) * childG.pivX
  let left  = refX + childG.posX - childG.pivX * childG.rectW
  # NaN-safe bounds: a getter that did not write leaves whatever was in the
  # buffer, and a plausible number is the failure mode this layer refuses.
  if not (top > -100000'f32) or not (top < 100000'f32): return
  if not (left > -100000'f32) or not (left < 100000'f32): return
  result = (true, top, left)

proc nuGeomMoved*(a, b: NuGeom; tol: float32): bool =
  ## Did this RectTransform MOVE or RESIZE between two readings? Both must be
  ## readable: an unreadable second reading is not evidence of "no change", so
  ## it answers TRUE (something is wrong and should be reported) rather than
  ## quietly passing.
  if not a.ok or not b.ok: return true
  let dx = a.posX - b.posX
  let dy = a.posY - b.posY
  let dw = a.rectW - b.rectW
  let dh = a.rectH - b.rectH
  dx > tol or dx < -tol or dy > tol or dy < -tol or
    dw > tol or dw < -tol or dh > tol or dh < -tol

proc nuGeomNote*(g: NuGeom): string =
  ## One line, for a log that has to be readable a week later.
  if not g.ok: return "UNREADABLE"
  "anchorMin=(" & nuF(g.aMinX) & "," & nuF(g.aMinY) & ") anchorMax=(" &
    nuF(g.aMaxX) & "," & nuF(g.aMaxY) & ") pivot=(" & nuF(g.pivX) & "," &
    nuF(g.pivY) & ") sizeDelta=(" & nuF(g.sdX) & "," & nuF(g.sdY) &
    ") anchoredPosition=(" & nuF(g.posX) & "," & nuF(g.posY) &
    ") rect=" & nuF(g.rectW) & "x" & nuF(g.rectH)

proc nuApplyGeomX*(rt: Il2CppPtr; g: NuGeom): bool =
  ## Copy a donor's HORIZONTAL geometry onto another RectTransform: anchorMin.x,
  ## anchorMax.x, pivot.x and sizeDelta.x.
  ##
  ## HORIZONTAL ONLY, and that is the whole design decision. The row parent is
  ## driven by the game's own vertical LayoutGroup, which owns each child's Y
  ## and height; writing those would fight it every relayout and lose. Width and
  ## horizontal anchoring are what the group does NOT drive and what the two
  ## prefab kinds disagreed about, so they are exactly what is copied.
  ##
  ## The Y components are read back off the TARGET first and written back
  ## unchanged, because `set_anchorMin` takes a whole Vector2 -- there is no
  ## per-component setter, so preserving Y means reading it, not assuming it.
  result = false
  if not gNuOn or not g.ok: return
  if not nuOk(rt, 0x10'i32): return
  let (oMin, _, curMinY) = nuGetV2(rt, NuTRtGetAnchorMin)
  let (oMax, _, curMaxY) = nuGetV2(rt, NuTRtGetAnchorMax)
  let (oPiv, _, curPivY) = nuGetV2(rt, NuTRtGetPivot)
  let (oSd,  _, curSdY)  = nuGetV2(rt, NuTRtGetSizeDelta)
  if not oMin or not oMax or not oPiv or not oSd: return
  result = nuSetV2(rt, NuTRtSetAnchorMin, g.aMinX, curMinY) and
           nuSetV2(rt, NuTRtSetAnchorMax, g.aMaxX, curMaxY) and
           nuSetV2(rt, NuTRtSetPivot, g.pivX, curPivY) and
           nuSetV2(rt, NuTRtSetSizeDelta, g.sdX, curSdY)

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

# --- THE POINTER SOURCE. Added 2026-08-31 for the native colour widget. ------
#
# Until now this section was arithmetic only and the comment above said so:
# "the caller supplies the pointer position it already has". NOTHING supplied
# one -- `nuHitTest` had zero call sites in the whole host -- so interaction was
# a half-built primitive, not a capability. These four calls are the missing
# half, and they are polled from the Update drain exactly as that comment
# prescribes: no delegate, no `UnityAction`, no EventSystem participation.
#
# All four RVAs are byte-verified against the STARTUP SNAPSHOT through the
# ordinary `nuFn` path, and all four are sharedness=UNIQUE. Provenance is on
# the rows themselves in `abi/aowlspt_nativeui.h`.

proc nuTargetsBindOk(): bool =
  ## THE POSITIONAL-BINDING SELF-CHECK for `aowl_nu_targets`.
  ##
  ## `aowl_du_targets` has had one since the 2026-08-24 defect (a row inserted
  ## mid-table re-pointed `DuGetParent` at `Transform::set_localPosition`, a
  ## byte-verified function of the wrong shape called with the wrong frame).
  ## This table -- indexed the same way, by the `NuT*` constants -- had NONE,
  ## and the change that adds this comment appends four rows to it. That is the
  ## precise edit that causes that bug, so the check ships with it.
  ##
  ## Deliberately checks the rows a WRONG ANSWER WOULD BE SILENT ON: the input
  ## trio (an int-shaped call to a pointer-shaped method), and one interior
  ## `_Injected` setter, because those are near-identical for pages and a
  ## mis-index there lays an element out wrongly while every call succeeds.
  result = true
  var bad = ""
  var idx: seq[int32] = @[]
  var want: seq[string] = @[]
  idx.add NuTRtSetSizeDelta
  want.add "UnityEngine.RectTransform::set_sizeDelta_Injected"
  idx.add NuTGrSetColor
  want.add "UnityEngine.UI.Graphic::set_color"
  idx.add NuTInputMouseBtn
  want.add "UnityEngine.Input::GetMouseButton"
  idx.add NuTInputMousePos
  want.add "UnityEngine.Input::get_mousePosition_Injected"
  idx.add NuTTrGetPosition
  want.add "UnityEngine.Transform::get_position_Injected"
  idx.add NuTTrGetLossyScale
  want.add "UnityEngine.Transform::get_lossyScale_Injected"
  # The prefab-path rows. `SetText` and `SetName` are adjacent, take the same
  # (this, String*, MethodInfo*) frame and BOTH return `this` -- so a
  # mis-index between them writes a caption into the GameObject name and every
  # call still succeeds. That is exactly the silent kind, so both are named.
  idx.add NuTSetCtrlSetText
  want.add "EFT.UI.Settings.SettingControl::SetText"
  idx.add NuTSetCtrlSetName
  want.add "EFT.UI.Settings.SettingControl::SetName"
  # The three-arg static. Reached through a thunk no other row uses, so a
  # mis-index here calls a one-arg instance method with a 3-arg static frame.
  idx.add NuTObjInstantiate3
  want.add "UnityEngine.Object::Instantiate(Object,Transform,bool)"
  # SetCurrentValue and CurrentValue are adjacent, differ only in direction,
  # and both are float-shaped -- a swap silently writes the slider instead of
  # reading it, which would make the finished-state readback self-fulfilling.
  idx.add NuTNumSliderSetCur
  want.add "EFT.UI.NumberSlider::SetCurrentValue"
  idx.add NuTNumSliderCurVal
  want.add "EFT.UI.NumberSlider::CurrentValue"
  idx.add NuTAnimTogSetToggled
  want.add "EFT.UI.AnimatedToggle::set_IsToggled"
  # The geometry getters sit immediately after a block of same-shaped setters
  # and take an identical frame. A mis-index between get_anchorMin and
  # set_anchorMin would WRITE the donor's anchors from an uninitialised buffer
  # while every call succeeded -- the exact silent class.
  idx.add NuTRtGetAnchorMin
  want.add "UnityEngine.RectTransform::get_anchorMin_Injected"
  idx.add NuTRtGetPivot
  want.add "UnityEngine.RectTransform::get_pivot_Injected"
  idx.add NuTLayoutElemIgnore
  want.add "UnityEngine.UI.LayoutElement::set_ignoreLayout"
  # get_top and set_top are adjacent rows on the same type with near-identical
  # frames. Swapping them would READ where we meant to WRITE -- the padding
  # would never change and the capture would record garbage as the original,
  # so the restore would put back the wrong number. Both named.
  idx.add NuTRectOffGetTop
  want.add "UnityEngine.RectOffset::get_top"
  idx.add NuTRectOffSetTop
  want.add "UnityEngine.RectOffset::set_top"
  # SetAsFirstSibling and SetAsLastSibling are the same shape and adjacent in
  # the table; swapping them would put the strip back UNDER the panel
  # background, which is the exact defect this pair was added to fix, and every
  # call would still succeed.
  idx.add NuTTrSetAsFirstSib
  want.add "UnityEngine.Transform::SetAsFirstSibling"
  idx.add NuTTrSetAsLastSib
  want.add "UnityEngine.Transform::SetAsLastSibling"
  # The three spawner rows are adjacent and same-shaped; a mis-index would call
  # SetActive with SpawnObject's frame and every call would still "succeed".
  idx.add NuTSpawnerSpawn
  want.add "EFT.UI.UIAnimatedToggleSpawner::SpawnObject"
  idx.add NuTSpawnerActive
  want.add "EFT.UI.UIAnimatedToggleSpawner::SetActive"
  # The DETOUR target. A mis-index here patches the wrong function, which is
  # the single most expensive mistake available in this file.
  idx.add NuTToggleSet
  want.add "UnityEngine.UI.Toggle::Set"
  var i = 0
  while i < idx.len:                      # capped: idx is built right here
    let ix = idx[i]
    if ix >= cNuTargetCount():
      result = false
      if bad.len == 0:
        bad = "index " & $ix & " is past the end of the table (" &
              $cNuTargetCount() & " rows)"
    else:
      let got = $cNuTargetName(ix)
      if got != want[i]:
        result = false
        if bad.len == 0:
          bad = "index " & $ix & " should be '" & want[i] & "' and is '" &
                got & "' (RVA 0x" & hexOf(uint64(cNuTargetRva(ix))) & ")"
    i = i + 1
  if not result:
    warn "nativeui: the aowl_nu_targets POSITIONAL binding self-check FAILED " &
         "-- " & bad & ". Every NuT* call would be to the wrong method with " &
         "the wrong frame. Nothing that indexes this table may run."

# ---------------------------------------------------------------------------
# THE SETTINGS-ROW PREFAB PATH
#
# Everything here is a CALL at a byte-verified, sharedness-UNIQUE RVA. Nothing
# here detours anything, and nothing here opens a guard: every one of these is
# reached from inside `modsBody`'s single `aowl_p_p_seh`, which is NOT
# re-entrant.
#
# WHAT THIS REPLACES. Rows used to be CLONED from a live donor row and
# relabelled, which is what produced the whole family of relabel defects (a
# clone inherits the donor's serialized wiring -- its ToggleGroup, its
# LayoutElement sizing, its already-spawned children -- and every one of those
# had to be found and undone by hand). A prefab instance inherits the PREFAB's
# wiring, which is what the game's own rows inherit. That is the entire point.
# ---------------------------------------------------------------------------

proc nuInstantiateUnder*(prefab, parent: Il2CppPtr): Il2CppPtr =
  ## `Object.Instantiate(prefab, parent, worldPositionStays: false)`.
  ##
  ## `worldPositionStays = false` is not a preference: it is what the game
  ## itself passes from `CreateControl<T>`, and it is what makes the fresh row
  ## adopt the parent's layout instead of keeping the prefab's world pose.
  ##
  ## Refuses on a null OR unreadable prefab and on a null OR unreadable
  ## parent, separately and out loud, because "the template field was null"
  ## and "the row container was null" are different bugs with different fixes
  ## and an Instantiate with no parent SUCCEEDS while rendering nowhere.
  result = nil
  if not gNuOn: return
  if not nuOk(prefab, 0x10'i32):
    warn "nativeui: prefab-row REFUSED -- the tab's serialized template field " &
         "read null or unreadable. That field is populated when the prefab " &
         "loads, so this is 'asked too early', not 'wrong offset'. Nothing " &
         "was instantiated."
    return
  if not nuOk(parent, 0x10'i32):
    warn "nativeui: prefab-row REFUSED -- the row container (the tab's " &
         "_settingsRoot / _settingsContainer) read null or unreadable. An " &
         "Instantiate with no parent lands the row at the scene root, where " &
         "it renders nothing and reports success. Nothing was instantiated."
    return
  let fn = nuFn(NuTObjInstantiate3)
  if fn == nil: return
  result = cNuCallPS3PPB(fn, prefab, parent, 0'i32)
  if not nuOk(result, 0x10'i32):
    warn "nativeui: prefab-row REFUSED -- Instantiate(Object,Transform,bool) " &
         "returned null or an unreadable pointer. Nothing is on screen and " &
         "nothing is owned."
    result = nil

proc nuRowSetText*(row: Il2CppPtr; s: string): bool =
  ## `SettingControl.SetText(localizationKey)`. The game passes a LOCALIZATION
  ## KEY, not a caption: the row's `LocalizedText` looks it up. A key with no
  ## entry renders as the key itself, which is ugly but HONEST and is exactly
  ## why a literal caption is passed here -- an aowlspt setting has no BSG
  ## locale entry and never will, so there is nothing to look up.
  ##
  ## This is the reason raw `m_text` stores are not used: `LocalizedText`
  ## clobbers them. Calling the game's own setter is the documented path.
  result = false
  if not gNuOn or not nuOk(row, 0x10'i32): return
  let fn = nuFn(NuTSetCtrlSetText)
  if fn == nil: return
  let sp = nuStr(s)
  if sp == nil: return
  discard cNuCallPPP(fn, row, sp)
  result = true

proc nuRowSetName*(row: Il2CppPtr; s: string): bool =
  ## `SettingControl.SetName(newName)` -- the GameObject name, which is what
  ## the live inspector's `find` searches on. Distinct from SetText, and the
  ## positional self-check names both because they are adjacent rows with an
  ## identical frame.
  result = false
  if not gNuOn or not nuOk(row, 0x10'i32): return
  let fn = nuFn(NuTSetCtrlSetName)
  if fn == nil: return
  let sp = nuStr(s)
  if sp == nil: return
  discard cNuCallPPP(fn, row, sp)
  result = true

proc nuRowSetSiblingIndex*(row: Il2CppPtr; idx: int32): bool =
  ## `SettingControl.SetSiblingIndex(index)`. Order inside the row container is
  ## the container's LayoutGroup's business; this is how the game orders its
  ## own rows and therefore the only ordering that survives a relayout.
  result = false
  if not gNuOn or not nuOk(row, 0x10'i32): return
  let fn = nuFn(NuTSetCtrlSetSibIdx)
  if fn == nil: return
  cNuCallVPI(fn, row, idx)
  true

proc nuRowSlider*(row: Il2CppPtr): Il2CppPtr =
  ## `SettingFloatSlider.Slider` @0xA8 -> `NumberSlider`. NULL-CAPABLE by
  ## construction (a serialized reference), so it is read through `nuOk` and a
  ## null answer is returned as null rather than dereferenced.
  result = nil
  if not nuOk(row, NuOffFloatSliderSlider + 8'i32): return
  result = cNuGetRef(row, NuOffFloatSliderSlider)
  if not nuOk(result, 0x10'i32): result = nil

proc nuSliderShow*(slider: Il2CppPtr; lo, hi: float32; format: string): bool =
  ## `NumberSlider.Show(minValue, maxValue, format)` -- the range and the
  ## display format, with NO `GameSetting<float>` involved. This is the whole
  ## reason a mod-owned float row is possible at all: `SettingFloatSlider.
  ## BindTo(GameSetting<float>,...)` has a real RVA but nothing to bind to,
  ## while the inner widget takes plain floats.
  ##
  ## `lo >= hi` is refused: an inverted range gives a slider that cannot move
  ## and looks identical to one that is merely disabled.
  result = false
  if not gNuOn or not nuOk(slider, 0x10'i32): return
  if not (lo < hi): return
  let fn = nuFn(NuTNumSliderShow)
  if fn == nil: return
  let fp = nuStr(format)
  if fp == nil: return
  cNuCallVPFFP(fn, slider, lo, hi, fp)
  true

proc nuSliderSetValue*(slider: Il2CppPtr; v: float32): bool =
  result = false
  if not gNuOn or not nuOk(slider, 0x10'i32): return
  let fn = nuFn(NuTNumSliderSetCur)
  if fn == nil: return
  cNuCallVPF(fn, slider, v)
  true

proc nuSliderValue*(slider: Il2CppPtr): (bool, float32) =
  ## THE FINISHED-STATE READ. The sentinel is a value no slider on this screen
  ## can legally hold, so "could not ask" is never folded into "the answer is
  ## 0" -- which for most of these settings IS a legal value and would make the
  ## check unable to fail.
  const NuSliderNoRead = -1.0e30'f32
  result = (false, 0.0'f32)
  if not gNuOn or not nuOk(slider, 0x10'i32): return
  let fn = nuFn(NuTNumSliderCurVal)
  if fn == nil: return
  let v = cNuCallFP(fn, slider, NuSliderNoRead)
  if not (v > NuSliderNoRead * 0.5'f32): return   # NaN-safe: NaN fails this
  if not (v > -1.0e9'f32) or not (v < 1.0e9'f32): return
  result = (true, v)

proc nuAnimToggleSetToggled*(tog: Il2CppPtr; on: bool): bool =
  ## `AnimatedToggle.set_IsToggled(bool)`.
  ##
  ## THE POINT, said plainly: writing `UnityEngine.UI.Toggle.m_IsOn` (+0x120)
  ## sets the LOGICAL state and nothing else. On an `AnimatedToggle` the
  ## VISIBLE selected state is an Animator trigger, fired from this setter. A
  ## feature that writes m_IsOn and then reads m_IsOn back has written a check
  ## that cannot fail while the player looks at the wrong highlight.
  ##
  ## STATUS: this is INFERRED from `docs/NATIVE-CONTROLS.md` plus the shape of
  ## the reported defect. It has NOT been live-verified; the client is
  ## unbootable this pass for an unrelated reason.
  result = false
  if not gNuOn or not nuOk(tog, 0x10'i32): return
  let fn = nuFn(NuTAnimTogSetToggled)
  if fn == nil: return
  cNuCallVPB(fn, tog, (if on: 1'i32 else: 0'i32))
  true

proc nuMouseDown(button: int32): bool =
  ## `UnityEngine.Input::GetMouseButton(int)` -- the LEGACY STATIC API in
  ## UnityEngine.InputLegacyModule, not `UnityEngine.UIElements.Input`, whose
  ## same-named member is an INSTANCE method on a SHARED (4-owner) RVA.
  ##
  ## "is held", not "went down this frame": a drag needs the held state, and
  ## the press edge is derived from it here rather than binding a second RVA.
  if not gNuOn: return false
  let fn = nuFn(NuTInputMouseBtn)
  if fn == nil: return false
  cNuCallBSi(fn, button) != 0'i32

proc nuMousePos(x, y: var float32): bool =
  ## `Input::get_mousePosition_Injected(Vector3* ret)`, static: RCX = the out
  ## buffer, RDX = MethodInfo* (NULL is fine; this is not a shared generic).
  ##
  ## Unity's screen origin is BOTTOM-LEFT, and it stays that way here -- an
  ## overlay canvas's world space uses the same origin, so converting would
  ## only create a second convention to get wrong.
  x = 0.0'f32
  y = 0.0'f32
  if not gNuOn: return false
  let fn = nuFn(NuTInputMousePos)
  if fn == nil: return false
  let buf = cNuV3OutPtr()
  if buf == nil: return false
  cNuCallVS1(fn, buf)
  let px = cNuV3OutX()
  let py = cNuV3OutY()
  # NaN-safe, and a bounds check rather than a nil check: a pointer position
  # off in the millions is what a getter that did not write looks like, and it
  # would map to a channel value just as happily as a real one.
  if not (px > -32768.0'f32) or not (px < 32768.0'f32): return false
  if not (py > -32768.0'f32) or not (py < 32768.0'f32): return false
  x = px
  y = py
  true

proc nuScreenRectOf(rt: Il2CppPtr; sx, sy, sw, sh: var float32): bool =
  ## The element's rect in SCREEN pixels, for an overlay canvas.
  ##
  ## For `RenderMode.ScreenSpaceOverlay` Unity places the canvas so that world
  ## space IS screen space, so centre = `Transform::get_position` and the
  ## half-extent = local `rect` size * `lossyScale`. Three `_Injected` getters,
  ## no managed allocation.
  ##
  ## `RectTransform::GetWorldCorners(Vector3[])` would be the direct answer and
  ## is NOT used: it takes a managed Vector3[], and allocating one on a frame
  ## breaks rule 7 while caching a pinned one adds a GC-handle mechanism this
  ## build has not demonstrated.
  ##
  ## This is only valid for an OVERLAY canvas. The caller must have established
  ## that (`Canvas::get_renderMode` == 0); this proc cannot see the canvas and
  ## deliberately does not guess at one.
  sx = 0.0'f32; sy = 0.0'f32; sw = 0.0'f32; sh = 0.0'f32
  if not gNuOn: return false
  if not nuOk(rt, 0x20'i32): return false
  let fnPos = nuFn(NuTTrGetPosition)
  let fnScl = nuFn(NuTTrGetLossyScale)
  if fnPos == nil or fnScl == nil: return false
  let (okR, _, _, rw, rh) = nuGetRect(rt)
  if not okR: return false
  if cNuRectRenderable(rw, rh) == 0'i32: return false

  var buf = cNuV3OutPtr()
  if buf == nil: return false
  cNuCallVPP(fnPos, rt, buf)
  let cx = cNuV3OutX()
  let cy = cNuV3OutY()
  buf = cNuV3OutPtr()
  cNuCallVPP(fnScl, rt, buf)
  let kx = cNuV3OutX()
  let ky = cNuV3OutY()
  # A zero or absurd lossyScale means the element is under a collapsed or
  # not-yet-laid-out parent. Mapping a pointer through it produces a finite,
  # entirely fictional channel value -- refuse instead.
  if not (kx > 0.0001'f32) or not (kx < 1000.0'f32): return false
  if not (ky > 0.0001'f32) or not (ky < 1000.0'f32): return false
  if not (cx > -65536.0'f32) or not (cx < 65536.0'f32): return false
  if not (cy > -65536.0'f32) or not (cy < 65536.0'f32): return false
  sw = rw * kx
  sh = rh * ky
  if cNuRectRenderable(sw, sh) == 0'i32: return false
  sx = cx - sw * 0.5'f32
  sy = cy - sh * 0.5'f32
  true

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
