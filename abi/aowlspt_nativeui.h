/* aowlspt_nativeui.h -- the NATIVE UNITY UI CONSTRUCTION LAYER.
 *
 * ===========================================================================
 * WHAT THIS IS, AND WHY IT IS NOT THE INVOKE2 LADDER
 * ===========================================================================
 *
 * `aowlspt_invoke2.h` proved, live, that managed Unity code can be CALLED
 * directly at a static RVA from inside a detour: a real GameObject was
 * allocated, constructed, named, round-tripped through `get_name`, given a
 * RectTransform, cloned, parented and activated. Every one of those steps was
 * verified, not merely "returned non-null".
 *
 * And nothing appeared on screen.
 *
 * That is the whole reason this file exists, and the shape of the bug is the
 * one CLAUDE.md 9b names: eight checks that could each only say yes.
 *
 * THE FIRST HYPOTHESIS WAS WRONG, AND THIS LAYER MEASURED IT WRONG ITSELF
 * ----------------------------------------------------------------------
 * The hypothesis was: creation works, LAYOUT is missing -- a `RectTransform`
 * fresh out of `AddComponent` has `sizeDelta == (0,0)`, and a zero-area rect
 * renders nothing while every call reports success.
 *
 * `nuProofRun` was written to MEASURE that rather than assume it: read the
 * rect back before laying out, and again after. Live, first run, it read
 *
 *     rect BEFORE layout = (-50.0, -50.0, 100.0, 100.0)  renderable=true
 *
 * So a fresh RectTransform on this build is Unity's default 100x100 centred on
 * its anchor -- NOT zero-area, and renderable by any measure this layer has.
 * The zero-area hypothesis is FALSIFIED. Whatever made the invoke2 label
 * invisible, it was not a zero-size rect.
 *
 * That is the before/after measurement doing its job, and it is worth being
 * blunt about: had the proof asserted the hypothesis instead of measuring it,
 * this file would now contain a confident, wrong explanation with live
 * "evidence" behind it. Layout is still REQUIRED -- an element at Unity's
 * default position and size is not where a caller wants it -- but it is no
 * longer claimed as the cause of anything. The cause is still open; the log
 * lines that would narrow it are in `nuProofRun`.
 *
 * So this layer is built around three commitments:
 *
 *   1. Every element it creates is LAID OUT before it is shown -- anchors,
 *      pivot, size and position are not optional arguments, they are part of
 *      creating a thing at all. (Not because a missing layout was proven to
 *      cause invisibility -- see above, it was not -- but because Unity's
 *      default 100x100 at the anchor centre is never what a caller meant.)
 *   2. Every element it creates is PROVED against the finished state: read the
 *      rect back, read the text back, read `activeInHierarchy` back. A
 *      self-comparison ("the size I wrote is the size I meant") is banned.
 *   3. Nothing is trusted because it is named plausibly. A component slot is
 *      refused until the component it produced has been shown to be of the
 *      class it claims.
 *
 * ===========================================================================
 * THE API, IN ONE PARAGRAPH
 * ===========================================================================
 *
 * `aowl_nu_create(name)` makes a GameObject with a RectTransform.
 * `aowl_nu_add(go, kind)` attaches a component by KIND (an enum, never a
 * name and never a `System.Type`). `aowl_nu_parent(child, parentTransform)`
 * puts it in a live hierarchy. `aowl_nu_layout(rt, ...)` sets anchors, pivot,
 * size and position through the `_Injected` setters. `aowl_nu_set_text` writes
 * TMP text through the real setters. `aowl_nu_clone(obj)` duplicates a live
 * element. `aowl_nu_destroy(obj)` tears one down, and `aowl_nu_destroy_all()`
 * tears down everything this layer ever made. All of it is read-back-verified
 * by the Nim surface in `nativeui.nim`.
 *
 * ===========================================================================
 * THE COMPONENT PROBLEM, AND HOW IT IS GENERALISED
 * ===========================================================================
 *
 * `GameObject::AddComponent<T>()` at 0x2A9AE90 is SHARED GENERIC CODE: one
 * body serves every T, and T lives entirely in the hidden trailing
 * `MethodInfo*`. A NULL MethodInfo is an immediate access violation there (the
 * body dereferences it at +0x38), so the generic route needs a real one.
 *
 * We do not synthesise it and we do not ask reflection for it. Per
 * docs/IL2CPP_EXPORTS.md the reflection exports are TOKEN-GATED: 38 of them
 * take a trailing 32-byte token we never pass, and on mismatch they return a
 * uniform random non-zero uint64 from a per-thread MT19937-64. That value
 * passes a nil check and kills the client on first dereference. `AddComponent
 * (System.Type)` sits behind exactly that door (`il2cpp_class_get_type` +
 * `il2cpp_type_get_object`), which is why the invoke2 ladder's step 4b
 * faulted. It is still the only step that ever faulted.
 *
 * Instead we read the pointer THE GAME ITSELF COMPUTED. IL2CPP never embeds a
 * `MethodInfo*` as an immediate; it emits a load from a per-token `.data` slot
 * that a metadata initialiser fills the first time the owning method runs:
 *
 *     mov rcx, [rip+X]        ; the receiver's Il2CppClass*
 *     mov rdx, [rip+Y]        ; <- Y is the MethodInfo* slot for THIS T
 *     call 0x2A9AE90          ; AddComponent<T>
 *
 * The invoke2 ladder hardcoded ONE such slot, for `RectTransform`, found by
 * hand inside `TMP_DefaultControls::CreateUIElementRoot`. `tools/addcompslots.py`
 * generalises that: it finds every `E8 rel32` in the `il2cpp` section whose
 * destination is 0x2A9AE90, recovers the last `mov rdx,[rip+X]` before each,
 * range-checks the result into a data section, and attributes each call site
 * to its enclosing method from the per-image `methodPointers` tables. It
 * reproduces 0x6E19580 for RectTransform independently, which is what makes
 * its other answers worth reading.
 *
 * MEASURED, 500 call sites, this build (1.1.0.1.46777). The attribution below
 * is by INTERSECTION of the call sites' enclosing methods against Unity's
 * documented `TMP_DefaultControls` / `Dropdown` sources -- i.e. the only
 * component every listed creator has in common:
 *
 *   0x6E19580  RectTransform     8 sites: CreateUIElementRoot, CreateUIObject,
 *                                CreateButton, TextMeshProUGUI::Awake,
 *                                TextContainer::OnRectTransformDimensionsChange,
 *                                TMP_Dropdown::CreateBlocker,
 *                                UI.Dropdown::CreateBlocker
 *   0x6D50040  TextMeshProUGUI   6 sites: CreateText (which adds ONLY this),
 *                                CreateButton, CreateInputField x2,
 *                                CreateDropdown x2
 *   0x6D50070  Image            12 sites: CreateScrollbar x2 (bg + handle),
 *                                CreateButton, CreateInputField, CreateDropdown x4
 *   0x6D50038  Button            3 sites: CreateButton, TMP_Dropdown::CreateBlocker,
 *                                UI.Dropdown::CreateBlocker -- Button is the
 *                                only component all three add
 *
 * There is deliberately NO CanvasRenderer slot: `Image` derives from `Graphic`,
 * which carries `[RequireComponent(typeof(CanvasRenderer))]`, and Unity's
 * native `AddComponent` honours RequireComponent. Adding one by hand would be
 * a second, unverifiable slot for no gain.
 *
 * ===========================================================================
 * WHY THE ATTRIBUTION ABOVE IS NOT TRUSTED, AND WHAT SETTLES IT
 * ===========================================================================
 *
 * All of that is EVIDENCE. None of it is proof, because the slot holds a
 * runtime pointer whose generic argument is not knowable offline, and because
 * "the enclosing method is called CreateText" is precisely the kind of
 * name-shaped reasoning that produced `ForceMeshUpdate` landing on a universal
 * empty stub shared by 6,438 methods.
 *
 * So the last step is settled at RUNTIME, against the finished state:
 *
 *   * a slot starts UNVERIFIED and is REFUSED;
 *   * the host registers a REFERENCE INSTANCE for a kind -- a live object of
 *     that class, reached by WALKING from something already validated, never
 *     by an offset that can read null -- via `aowl_nu_ref_set`. The class
 *     pointer is the object header's first qword, which is what
 *     `il2cpp_object_get_class` itself is (`mov rax,[rcx]; ret`, three
 *     instructions, no gate, no validation);
 *   * the first `AddComponent` through a slot compares the RESULT's header
 *     klass against that reference klass. Equal -> the slot is VERIFIED and
 *     usable. Unequal -> the slot is POISONED, permanently, and every later
 *     use of that kind is refused with the two class pointers logged.
 *
 * A kind with no reference instance is INCONCLUSIVE, not "probably fine": the
 * component is created, checked as far as it can be, then DESTROYED again and
 * the kind stays refused. Three outcomes, never two.
 *
 * That is the falsifiable check the whole design turns on. Ask what input
 * makes it fail: a slot attributed to the wrong T attaches the wrong
 * component, whose klass differs from the reference, and the layer disables
 * that kind. It cannot silently succeed.
 *
 * ===========================================================================
 * STRUCT ABI: WHY EVERY VECTOR GOES THROUGH `_Injected`
 * ===========================================================================
 *
 * `UnityEngine.RectTransform` declares exactly ONE il2cpp field
 * (`reapplyDrivenProperties`, static). `m_AnchoredPosition`, `m_SizeDelta`,
 * `m_Pivot`, `m_AnchorMin`, `m_AnchorMax` are NATIVE-side -- there is no field
 * offset to write. They must go through property setters.
 *
 * The by-value setters (`set_sizeDelta(Vector2)` @0x52B5550 and friends) put
 * an 8-byte struct in an integer register and a 16-byte one behind a hidden
 * sret buffer, and getting that subtly wrong yields a call that returns
 * cleanly having written garbage. The `_Injected` variants take a POINTER
 * instead -- `(this, Vector2* value, MethodInfo*)` -- so there is no struct
 * ABI left to get wrong in either direction. This layer uses ONLY those:
 *
 *   set_anchorMin_Injected        0x52B6D80
 *   set_anchorMax_Injected        0x52B6E40
 *   set_anchoredPosition_Injected 0x52B6F00
 *   set_sizeDelta_Injected        0x52B6FC0
 *   set_pivot_Injected            0x52B7080
 *   get_anchoredPosition_Injected 0x52B6EA0   (this, Vector2* ret, MethodInfo*)
 *   get_sizeDelta_Injected        0x52B6F60   (this, Vector2* ret, MethodInfo*)
 *   get_rect_Injected             0x52B6CC0   (this, Rect*    ret, MethodInfo*)
 *
 * The `_Injected` GETTERS are what make the visual proof possible at all: the
 * finished rect comes back in a buffer we own, with no RAX-packing and no
 * sret shape to decode.
 *
 * ===========================================================================
 * TEXT
 * ===========================================================================
 *
 * Writing `m_text` raw does not stick: `LocalizedText` clobbers it. The real
 * setters are `TMP_Text::set_text` @0x51BC1E0 and, when a `LocalizedText`
 * component is present, `LocalizedText::SetLabelText` @0x140FE70 -- and the
 * write must be RE-APPLIED, because the clobber can land after ours.
 * `aowl_nu_set_text` therefore only does the call; `nuSetText` in
 * `nativeui.nim` does the re-apply and reads back through
 * `TMP_Text::get_text` @0x51BC100.
 *
 * `ForceMeshUpdate` is NOT called anywhere here. Resolving it lands on
 * 0x628110, which is `C2 00 00` (`ret 0`) -- this build's universal empty-body
 * stub, shared by 6,438 methods. It is not that method's code and calling it
 * has no effect. A stub that passes a signature check is the worst case there
 * is, so it is named here rather than quietly omitted.
 *
 * ===========================================================================
 * INPUT
 * ===========================================================================
 *
 * There is NO delegate path in v1, on purpose. Hooking a `Button.onClick`
 * needs a managed `UnityAction`, and a hand-built delegate needs both a valid
 * `invoke_impl` and a valid `MethodInfo*` for a method that does not exist in
 * any assembly. Nothing about that has been demonstrated on this build, and
 * an unproven delegate handed to Unity's event system is a fault on a frame we
 * do not control.
 *
 * v1 uses POLLED state instead: the host already runs every frame on the Unity
 * thread through the `TarkovApplication::Update` bridge, so a control's
 * interaction is a per-frame read (pointer-over / pressed state, or a key), not
 * a callback. `aowl_nu_poll_rect_contains` supports that with pure arithmetic.
 * This is a documented v1 limitation, not an oversight.
 *
 * ===========================================================================
 * SAFETY (CLAUDE.md 5, all eight, non-negotiable)
 * ===========================================================================
 *
 *  1. Every RVA is 16-byte prologue-verified through `aowl_pro_verify` --
 *     against the STARTUP SNAPSHOT, never live memory, so a target another
 *     feature has already detoured does not make this layer self-reject.
 *  2. `VirtualQuery` on every hop: `aowl_nu_fn` checks committed+executable
 *     before it compares bytes; `aowl_nu_data_ptr` checks committed+readable
 *     and range-checks into `.data` before it dereferences a slot.
 *  3. ONE `aowl_p_p_seh` per body, never nested -- the guard is not re-entrant
 *     and an inner guard DISARMS the outer one. This header contains no guard
 *     at all; `nativeui.nim` wraps whole operations, once.
 *  4. Every loop is capped (`AOWL_NU_MAX_OWNED`, `AOWL_NU_MAX_KINDS`).
 *  5. Flag-gated, default OFF (`nativeUi`, `nativeUiProof`).
 *  6. Self-disables after `AOWL_NU_MAX_FAULTS`, and per-kind on a klass
 *     mismatch.
 *  7. NO per-frame managed allocation. Managed strings are allocated ONCE at
 *     first use and cached (`aowl_nu_intern`); the Vector2/Rect marshalling
 *     buffers are file-scope statics, reused. A UI layer is exactly where a
 *     per-frame `il2cpp_string_new` would bite.
 *  8. Never blind-write. Every setter here is a CALL into the game's own
 *     property setter; the only raw writes this layer performs are into its
 *     own C structs.
 *
 * SHAREDNESS: measured with the fixed `Resolver.sharedness` (three outcomes:
 * shared / unique / unknown). All 24 managed targets below report `unique, 1`.
 * 0x2A9AE90 reports `unknown, 0` -- it is shared generic code and is not in
 * the methodPointers histogram at all. That is fine here because this layer
 * CALLS it and never detours it; calling a shared address is correct code for
 * the receiver you pass. It would be unacceptable as a patch target.
 *
 * THREADING: every entry point must be called on the Unity main thread. The
 * marshalling buffers are file-scope and not re-entrant.
 */

#ifndef AOWLSPT_NATIVEUI_H
#define AOWLSPT_NATIVEUI_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* `aowl_pro_verify` / `aowl_pro_capture` come from aowlspt_prologue.h, which
 * aowlhost.nim emits before this file. */

/* ------------------------------------------------------------------ *
 * 1. The target table
 * ------------------------------------------------------------------ */

typedef struct AowlNuTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlNuTarget;

#define AOWL_NU_GO_CTOR_STRING        0
#define AOWL_NU_GO_SETACTIVE          1
#define AOWL_NU_GO_GET_TRANSFORM      2
#define AOWL_NU_GO_ACTIVE_INHIER      3
#define AOWL_NU_GO_SET_LAYER          4
#define AOWL_NU_ADDCOMPONENT_GEN      5
#define AOWL_NU_OBJ_GET_NAME          6
#define AOWL_NU_OBJ_DESTROY           7
#define AOWL_NU_OBJ_INSTANTIATE       8
#define AOWL_NU_OBJ_ALIVE             9
#define AOWL_NU_TR_SETPARENT2        10
#define AOWL_NU_TR_SETASFIRSTSIB     11
#define AOWL_NU_RT_SET_ANCHORMIN     12
#define AOWL_NU_RT_SET_ANCHORMAX     13
#define AOWL_NU_RT_SET_ANCHOREDPOS   14
#define AOWL_NU_RT_SET_SIZEDELTA     15
#define AOWL_NU_RT_SET_PIVOT         16
#define AOWL_NU_RT_GET_ANCHOREDPOS   17
#define AOWL_NU_RT_GET_SIZEDELTA     18
#define AOWL_NU_RT_GET_RECT          19
#define AOWL_NU_TMP_SET_TEXT         20
#define AOWL_NU_TMP_GET_TEXT         21
#define AOWL_NU_TMP_SET_FONTSIZE     22
#define AOWL_NU_LOC_SET_LABEL_TEXT   23
#define AOWL_NU_SET_PARENT_ALIGN     24
/* il2cpp_codegen_initialize_runtime_metadata(uintptr_t* slot). NOT an
 * il2cpp_* export, so ungated: it is the codegen helper the game itself calls
 * at the top of every method that uses a metadata-usage slot. Resolves the
 * slot's encoded token to a real pointer IN PLACE and returns it in RAX.
 * Measured from TMP_DefaultControls::CreateText@0x5191200: at +0xF
 * `lea rcx,[slot]` then at +0x16 `call 0x5251C0`. Body confirmed a real
 * function (atomic `lock xadd`, kind decode `shr eax,0x1d`, jump-table
 * dispatch) -- not the 0x628110 empty stub. */
#define AOWL_NU_META_INIT            25
/* --- the IMAGE-VISIBILITY trio (spike `nativeUiImageProof`) ---------------
 *
 * An `Image` that EXISTS and shows nothing is this project's signature false
 * positive, so the spike does not stop at AddComponent. Three things decide
 * whether a Graphic puts pixels on screen, and each has a target here:
 *
 *   set_color            -- alpha 0 is invisible and every readback still says
 *                           "the component is there". MEASURED ABI, from the
 *                           prologue bytes themselves: `0F 10 12` is
 *                           `movups xmm2,[rdx]`, so RDX is a POINTER to the
 *                           Color (Win64 passes a 16-byte struct by reference),
 *                           and `F3 0F 10 41 28` is `movss xmm0,[rcx+0x28]`,
 *                           which independently CONFIRMS m_Color@0x28 from
 *                           fldoff. Shape-compatible with the `_Injected`
 *                           setters, so aowl_nu_call_v_pp serves it unchanged.
 *   get_canvasRenderer   -- Graphic carries [RequireComponent(CanvasRenderer)]
 *                           and Unity's native AddComponent is supposed to
 *                           honour it. "Supposed to" is not measured; this is
 *                           how the spike ASKS instead of assuming, and a null
 *                           answer is the single most likely reason a created
 *                           Image renders nothing.
 *   SetAllDirty          -- a raw m_Color store would not mark the mesh dirty.
 *                           We call the setter, but a from-scratch Graphic that
 *                           was activated after layout has no guaranteed dirty
 *                           pass, so this is called ONCE, explicitly.
 *
 * All three: sharedness UNIQUE / owners=1 (Resolver.sharedness, three-state),
 * and none is the 0x628110 universal `C2 00 00` stub. */
#define AOWL_NU_GR_SET_COLOR         26
#define AOWL_NU_GR_GET_CANVASREND    27
#define AOWL_NU_GR_SETALLDIRTY       28
/* --- CANVAS CREATION (natesp's third outcome: CREATED) -------------------
 *
 * WHY THESE EXIST. natesp's phase-0 root ask can now say ABSENT over EVERY
 * root, exhaustively -- which turns "there is no canvas" from a truncation
 * artifact into an answer, and leaves the feature with nothing to parent to.
 * Rather than refuse forever, natesp builds its own screen-space Canvas. That
 * needs exactly three things beyond what this table already had: attach the
 * component (a kind row, below), tell it to render to the screen, and put it
 * above the game's own HUD.
 *
 * ALL THREE, MEASURED against THIS build's GameAssembly.dll (2026-08-30):
 *   il2cpp_resolve.py type UnityEngine.Canvas   -> the RVAs below
 *   il2cpp_resolve.py shared <RVA>              -> sharedness=UNIQUE owners=1
 *                                                  for each (three-state; none
 *                                                  came back `unknown`)
 *   il2cpp_resolve.py bytes  <RVA>              -> the 16 bytes below, and NONE
 *                                                  is 0xC2,0x00,0x00 (the
 *                                                  6,438-method empty stub at
 *                                                  0x628110)
 *
 * get_renderMode is here for the READBACK, not for symmetry: a canvas that
 * exists in ScreenSpaceCamera or WorldSpace mode renders our boxes somewhere
 * in the map, which is the invisible-success this project keeps producing.
 * Asking the live object which mode it is in is the falsifiable check.
 *
 * DELIBERATELY ABSENT: CanvasScaler and GraphicRaycaster. Their AddComponent
 * slots were resolved at the same time (0x6D586E8 and 0x6D58700, both
 * offline-attested) and are NOT used. A raycaster only makes UI clickable and
 * ESP boxes are non-interactive; a scaler only rescales, and WITHOUT one an
 * overlay canvas's units are screen pixels 1:1, which is exactly what
 * `nePlace` already computes from WorldToScreenPoint. Adding either would be
 * two more ways to be wrong for no pixel gained. */
#define AOWL_NU_CANVAS_SET_RENDERMODE 29
#define AOWL_NU_CANVAS_GET_RENDERMODE 30
#define AOWL_NU_CANVAS_SET_SORTORDER  31
/* --- polled pointer input, for the native colour widget ------------------ */
#define AOWL_NU_INPUT_GET_MOUSEBTN    32
#define AOWL_NU_INPUT_GET_MOUSEPOS    33
#define AOWL_NU_TR_GET_POSITION       34
#define AOWL_NU_TR_GET_LOSSYSCALE     35

/* --- THE NATIVE SETTINGS-ROW PREFAB PATH (indices 36..45) ------------------
 *
 * WHY THESE EXIST. The PostFX rows were built from scratch (nuikit labels) and
 * before that by CLONING a stock row. Both were workarounds for not knowing
 * how the game itself builds a settings row. `docs/NATIVE-CONTROLS.md` maps
 * that path: every `SettingsTab` holds SERIALIZED PREFAB references
 * (`_toggleTemplate`, `_floatSliderTemplate`, `_dropDownTemplate`,
 * `_selectSliderTemplate`) and instantiates them with
 * `SettingsTab.CreateControl<T>` -- a GENERIC method with no entry in
 * `methodPointers` and therefore NO RVA. The non-generic substitute is
 * `Object.Instantiate(Object, Transform, bool)`, which is here.
 *
 * PROVENANCE, every row, measured 2026-09-01 against THIS build:
 *   python tools/il2cpp_resolve.py D:/Aowlspt/GameAssembly.dll
 *          .cache/global-metadata.dec.dat bytes  <RVA> 16   -> the sig below
 *   ... shared <RVA>  -> sharedness=UNIQUE owners=1 for EVERY row (three-state;
 *                        none came back `unknown`)
 * None is 0x628110, the 6,438-method `C2 00 00` universal empty-body stub.
 * Every one is in the `il2cpp` section, not `.text`.
 *
 * TWO OF THESE SIGS ARE ALSO ABI EVIDENCE, not merely an identity check:
 *   SetText@0x16FA890 begins `48 8B D9  48 8B 89 80 00 00 00`
 *     = mov rbx,rcx ; mov rcx,[rcx+0x80] -- it reads `SettingControl.Text`
 *       at +0x80, INDEPENDENTLY confirming that field offset from fldoff.
 *   NumberSlider::CurrentValue@0x16B5850 begins `48 8B 89 80 00 00 00`
 *     = mov rcx,[rcx+0x80] -- `NumberSlider._slider` at +0x80, the same
 *       confirmation.
 * A prologue that is merely real code proves identity, not behaviour; these
 * two additionally AGREE with the field table, which is a real cross-check.
 *
 * WHAT IS DELIBERATELY ABSENT, and it is the honest half of this change:
 *   * `SettingToggle::BindTo(GameSetting<bool>)` @0x16FD0D0 and
 *     `SettingFloatSlider::BindTo(GameSetting<float>,...)` @0x16FB810 both
 *     have real unique RVAs -- but a `GameSetting<T>` is an INSTANTIATED
 *     GENERIC whose layout is NOT reachable offline (all 33,464
 *     Il2CppGenericClass entries have a null cached_class), and constructing
 *     one is a GAP. A mod-owned row has nothing to bind TO. Not bound.
 *   * `SetChangeAction(Action)` @0x16FAFC0 IS here and IS callable -- but it
 *     needs a managed `Action` delegate, and building one requires type
 *     injection, which is PLAUSIBLE and UNPROVEN on this build. It is in the
 *     table so the gap is one object away rather than one investigation away;
 *     it is called with a real delegate or not at all, never with NULL.
 *   * Every DROPDOWN and SELECT-SLIDER bind is generic and has NO code entry.
 *     Those row kinds are refused out loud by the caller rather than
 *     counterfeited out of a toggle. */
#define AOWL_NU_SETCTRL_SETTEXT       36
#define AOWL_NU_SETCTRL_SETNAME       37
#define AOWL_NU_SETCTRL_SETSIBIDX     38
#define AOWL_NU_SETCTRL_SETCHANGEACT  39
#define AOWL_NU_OBJ_INSTANTIATE3      40
#define AOWL_NU_NUMSLIDER_SHOW        41
#define AOWL_NU_NUMSLIDER_SETCUR      42
#define AOWL_NU_NUMSLIDER_CURVAL      43
/* The SUBTAB-HIGHLIGHT pair. `modsSetToggleQuiet` writes `Toggle.m_IsOn`
 * (+0x120) and that is exactly what the strip verdict reads back -- so the
 * verdict PASSes while the player sees GRAPHICS highlighted over an open
 * POSTFX panel. These tab widgets are `AnimatedToggle`s, whose VISUAL state
 * is driven by an Animator trigger fired from `set_IsToggled`; a raw m_IsOn
 * store never runs it. Calling the setter is the only way the animation can
 * happen.
 * STATUS: INFERRED from the construction map plus the shape of the defect.
 * NOT live-verified -- the client is unbootable this pass. */
#define AOWL_NU_ANIMTOGGLE_SETTOGGLED  44
#define AOWL_NU_SPAWNTOG_SETTOGGLED    45
/* --- THE ROW-GEOMETRY READ (indices 46..48) -------------------------------
 *
 * WHY THESE EXIST, measured live 2026-09-01 and not inferred: the prefab rows
 * SHIP, RENDER and are real native controls -- and they do not agree with each
 * other on width. The two SettingToggle rows sat near the horizontal centre
 * while every SettingFloatSlider row put its label far left and pushed its
 * control column off the RIGHT EDGE of the panel, clipped. Nothing was setting
 * the fresh row's geometry at all, so each kind kept whatever its own prefab
 * shipped with, and those two prefabs disagree.
 *
 * The fix is to COPY a stock row's geometry rather than invent one, which
 * needs the three GETTERS this table was missing. It already carried
 * `get_anchoredPosition_Injected`, `get_sizeDelta_Injected` and
 * `get_rect_Injected`, and all five SETTERS -- but no way to READ anchorMin,
 * anchorMax or pivot, so "copy the donor" was not expressible.
 *
 * A HARDCODED WIDTH WOULD BE WRONG HERE FOR A SPECIFIC REASON: this user runs
 * Windows at 1.5x display scaling, so any pixel constant measured on one
 * machine is a different fraction of the panel on the next. A donor row read
 * live is resolution-independent by construction.
 *
 * PROVENANCE, all three, measured against THIS build:
 *   python tools/il2cpp_resolve.py <asm> <metadec> typemethods
 *          UnityEngine.RectTransform    -> the RVAs below, sharedness=UNIQUE
 *   ... bytes <RVA> 16                  -> the 16 bytes below
 * None is the 0x628110 `C2 00 00` universal stub. Shape is identical to the
 * getters already here: (this, Vector2* ret, MethodInfo*), so `aowl_nu_call_v_pp`
 * and `nuGetV2` serve them unchanged. */
#define AOWL_NU_RT_GET_ANCHORMIN      46
#define AOWL_NU_RT_GET_ANCHORMAX      47
#define AOWL_NU_RT_GET_PIVOT          48
/* --- OPTING OUT OF A LAYOUT GROUP (index 49) ------------------------------
 *
 * MEASURED LIVE, twice, which is why this row replaces a fix rather than
 * adding one.
 *
 * The subtab strip is cloned into the Graphics panel's content container,
 * whose LayoutGroup then allocated it space and took that space from the stock
 * scroll view. The host baseline caught it with numbers:
 *
 *   Graphics Settings/SettingsList
 *     was  sizeDelta=(850,755)    anchoredPosition=(0,-20)
 *     now  sizeDelta=(850,354.5)  anchoredPosition=(0,-420.5)
 *
 * The FIRST attempt tried to make the strip's preferred height small enough
 * (an explicit LayoutElement height measured off the donor button). It did not
 * work. That was the wrong shape of fix: as long as the strip is a layout
 * CHILD, the group allocates it space, and we were negotiating with the layout
 * system when what we want is to leave it.
 *
 * `LayoutElement.ignoreLayout = true` is Unity's own answer -- the group skips
 * the element entirely when measuring and arranging, so it allocates nothing
 * and the stock children keep their geometry. The element is then positioned
 * absolutely by us.
 *
 * THE SETTER, NOT THE FIELD, and this is the same lesson as the m_IsOn store
 * that never fired the Animator trigger. `m_IgnoreLayout` is at +0x20
 * (tools/fldoff.py, System.String self-check passed), but a raw store does not
 * call `LayoutElement::SetDirty` @0x5598490, so the group never re-runs and
 * nothing changes. Unity's own property does both. So we call the property.
 *
 * PROVENANCE: il2cpp_resolve.py typemethods UnityEngine.UI.LayoutElement ->
 * set_ignoreLayout RVA=0x5598100 sharedness=UNIQUE (note get_ignoreLayout is
 * SHARED x66 and is deliberately NOT bound here -- calling a shared RVA is
 * safe, but we have no need to read it back and every unneeded row is another
 * positional index to get wrong). bytes <RVA> 16 -> the sig below; not the
 * 0x628110 universal stub. */
#define AOWL_NU_LAYOUTELEM_SET_IGNORE 49
/* --- MAKING ROOM FOR THE STRIP, THE GROUP'S OWN WAY (indices 50..52) ------
 *
 * MEASURED LIVE. Attempt 4 (parent the strip to the panel, wear the stock
 * strip's geometry) FIXED the displacement -- the backstop reported all 7
 * stock objects unchanged and SettingsList read back byte-for-byte stock at
 * anchoredPosition=(0,-20) sizeDelta=(850,755). But the copied position
 * (0,-128) put the strip on top of the third row: Control Settings' content
 * starts lower than Graphics', so there is no free band under the panel top.
 *
 * WHY NOT SIMPLY WRITE THE LIST'S anchoredPosition. Because a LayoutGroup
 * DRIVES its children's positions on every rebuild, and we have direct
 * evidence that one drives this list: attempts 1-3 moved it from -20 to
 * -420.5 and resized it 755 -> 354.5 purely by adding a sibling. A direct
 * write to a driven child is reverted at the next rebuild -- which may be
 * seconds later, on a tab switch -- so it would look correct in a screenshot
 * and snap back in play. That is a worse defect than the one being fixed.
 *
 * So we change the GROUP'S OWN INPUT instead: `LayoutGroup.padding.top`. The
 * group then moves and resizes the list itself, correctly, and the change
 * survives every rebuild because it IS what the group reads.
 *
 * `padding` is a `RectOffset` -- a managed wrapper over a NATIVE pointer
 * (`m_Ptr` @0x10), so `top` is NOT a raw field and there is no offset to poke.
 * It has to go through the property, and `LayoutGroup::SetDirty` has to be
 * called afterwards or the group will not re-run. `get_padding` is
 * deliberately NOT bound: it is SHARED x479, and we read `m_Padding` @0x20 as
 * a plain reference field instead, which needs no call at all.
 *
 * PROVENANCE, all three: il2cpp_resolve.py typemethods -> RVA and
 * sharedness=UNIQUE; bytes <RVA> 16 -> the sig below; none is the 0x628110
 * universal stub.
 *
 * THIS IS AN OWNED WRITE, AND IT IS RESTORED. The original `top` is captured
 * before the first write and put back on fault or self-disable. The
 * stock-geometry backstop is told to expect exactly this shift and nothing
 * more -- see `gGfxStockExpectShift` -- so a drift of any other size still
 * fails it. That is the difference from attempts 1-3: those were an
 * uncontrolled side-effect of unknown size with no restore. */
#define AOWL_NU_RECTOFFSET_GET_TOP    50
#define AOWL_NU_RECTOFFSET_SET_TOP    51
#define AOWL_NU_LAYOUTGROUP_SETDIRTY  52
/* --- DRAW ORDER AND RAYCAST ORDER (indices 53..54) ------------------------
 *
 * MEASURED LIVE, by the user: the subtab strip renders BEHIND the panel's
 * background and cannot be clicked. Not a disabled control -- the buttons were
 * separately confirmed `m_Interactable=true` with `raycastTarget=true`, which
 * is exactly what "behind" looks like as opposed to "off".
 *
 * In a Unity canvas, SIBLING ORDER IS BOTH DRAW ORDER AND RAYCAST ORDER. The
 * strip is parented to the panel and was moved to sibling 0 -- deliberately,
 * back when it was a layout child and sibling index decided WHERE it sat. It
 * is no longer a layout child; it is absolutely positioned. So sibling 0 now
 * only means "drawn first, under everything else", and the panel background's
 * raycast target swallows every click.
 *
 * `SetAsLastSibling` is the whole fix. `GetSiblingIndex` is bound alongside it
 * so the result can be ASSERTED rather than assumed -- the index is read back
 * and compared against the panel's child count, which is a check that can
 * fail.
 *
 * PROVENANCE, both: il2cpp_resolve.py typemethods UnityEngine.Transform ->
 * RVA and sharedness=UNIQUE; bytes <RVA> 16 -> the sig below. Neither is the
 * 0x628110 universal stub. Both are CALLED, never detoured. */
#define AOWL_NU_TR_SETASLASTSIB       53
#define AOWL_NU_TR_GETSIBLINGINDEX    54
/* --- NATIVE TABS (indices 55..61) -- see docs/NATIVETABS.md ---------------
 *
 * The foundation that replaces the clone-a-strip approach: a tab is a real
 * `UIAnimatedToggleSpawner` in the stock ToggleGroup plus a real cloned
 * SettingsTab panel, emptied of its stock rows, whose own LayoutGroup lays out
 * the prefab rows we add. Geometry stops being ours to negotiate.
 *
 * PROVENANCE, every row: il2cpp_resolve.py typemethods <T> -> RVA and
 * sharedness; bytes <RVA> 16 -> the sig below. None is the 0x628110 universal
 * stub; all are in the `il2cpp` section.
 *
 * TWO ARE SHARED AND ARE CALLED, NEVER DETOURED. `Behaviour::set_enabled` is
 * SHARED x32. Calling a shared RVA is correct -- it is the right code for the
 * receiver in RCX. Detouring one has unbounded blast radius. These are calls.
 *
 * THE TOGGLE EVENT TARGET IS `Set`, NOT `set_isOn`, AND THAT IS A CORRECTION.
 * `set_isOn` @0x55BA430 is an ELEVEN-BYTE TAIL-JUMP THUNK:
 *     45 33 C9  41 B0 01  E9 15 00 00 00  CC CC CC CC CC
 *     xor r9d,r9d ; mov r8b,1 ; jmp +0x15   then padding
 * `SetIsOnWithoutNotify` @0x55BA440 is the same shape. Stealing 16 bytes there
 * would overwrite past the end of the function and the trampoline would have
 * to relocate a rel32 -- a detour engine that does not is silently wrong.
 * Both thunks jump to `Toggle::Set(bool value, bool sendCallback)`
 * @0x55BA450, which is UNIQUE and has a real 16-byte prologue. That is the
 * hook, and it is SELF-GUARDING: `sendCallback` (R8B) is TRUE for a real user
 * press and FALSE for `SetIsOnWithoutNotify`, which is what our own
 * `modsSetToggleQuiet` calls -- so our writes cannot re-enter our own hook. */
#define AOWL_NU_BEHAVIOUR_SET_ENABLED 55
#define AOWL_NU_SPAWNER_SPAWNOBJECT   56
#define AOWL_NU_SPAWNER_SETHEADER     57
#define AOWL_NU_SPAWNER_SETACTIVE     58
#define AOWL_NU_TAB_CLEANUPCONTROLS   59
#define AOWL_NU_TOGGLE_SET_GROUP      60
#define AOWL_NU_TOGGLE_SET            61
/* --- CANVASGROUP (indices 62..66) -----------------------------------------
 *
 * WHY. The subtab strip is cloned from `Control Settings/Toggles` while that
 * panel is HIDDEN, so the clone inherits whatever CanvasGroup state the donor
 * had at clone time -- plausibly alpha 0 and blocksRaycasts false. That is a
 * precise fit for the reported defect: the strip renders (its children have
 * their own graphics) but POSTFX "does not take a mouse click", because a
 * CanvasGroup with blocksRaycasts=false swallows nothing and interactable=
 * false makes every Selectable under it inert -- while `Toggle::Set` called
 * from our own code still works, which is exactly what was observed.
 *
 * CanvasGroup has NO managed fields (all native), so these have to be calls.
 * `get_blocksRaycasts` is SHARED x2 -- safe to CALL, never to detour.
 *
 * PROVENANCE: il2cpp_resolve.py typemethods UnityEngine.CanvasGroup -> RVA and
 * sharedness; bytes <RVA> 16 -> the sigs below. */
#define AOWL_NU_CG_GET_ALPHA          62
#define AOWL_NU_CG_SET_ALPHA          63
#define AOWL_NU_CG_GET_INTERACTABLE   64
#define AOWL_NU_CG_SET_INTERACTABLE   65
#define AOWL_NU_CG_SET_BLOCKSRAYCASTS 66

/* --- THE PANEL SWITCH AND THE SILENT SELECT (indices 67..70) --------------
 *
 * docs/SETTINGS-UI-MAP.md §7.9 named exactly this gap: this table carried
 * `Toggle::Set` and `Toggle::set_group` but NOT the panel-switch API, so the
 * host had no way to switch a stock tab except by pressing a toggle -- which
 * is how the phantom "subtab pressed by the player" line was produced.
 *
 * ShowScreen (§2.4, `R disasm 0x1720de0`) does OLD-OFF -> EnsureTabInitialized
 * -> `_currentTab@0x118 = _tabs[group].Tab` -> NEW-ON, and keeps
 * `ScreenController[+0x60]` consistent. `<Awake>b__1` passes exactly
 * (rcx=screen, edx=group, r8=NULL), so a NULL MethodInfo* is what the game
 * itself passes.
 *
 * ToggleSilently (§1.6) is the ONE correct way to move a subtab highlight:
 * MEASURED `R disasm 0x16bcba0` -- get_SpawnedObject, then
 * `Toggle::Set(tog, value, sendCallback=0)` (`xor r8d,r8d`), then, iff
 * `m_Transition@0x50 == 3`, `AnimatedToggle::TriggerAnimation`. It is
 * byte-for-byte `AnimatedToggle::set_IsToggled` @0x16AD190 with the callback
 * flag flipped -- and set_IsToggled's `mov r8b,1` is MEASURED to be why every
 * highlight we applied re-entered our own drain as a fresh player press.
 * NOTE: it THROWS (call 0x5D2530, the null-ref helper) when the spawner has no
 * spawned object, and a managed throw does not trip aowl_p_p_seh (§5 T9), so
 * the caller must establish the spawned toggle exists first.
 *
 * SetToggleGroup (§6.2.1) is the REGISTERING join -- unregister-from-old,
 * store m_Group, register-into-new. `set_group` @0x55B9D30 writes the field
 * only, which is precisely the §5 T3 throw on the next Set().
 *
 * All four MEASURED UNIQUE (`R shared`), bytes from `R bytes <RVA> 16`. */
#define AOWL_NU_SCREEN_SHOWSCREEN     67
#define AOWL_NU_TAB_SET_ISSELECTED    68
#define AOWL_NU_SPAWNER_TOGGLESILENT  69
#define AOWL_NU_TOGGLE_SETTOGGLEGROUP 70

/* --- THE CLOSE PATH (indices 71..72) --------------------------------------
 *
 * Three client deaths on 2026-09-02 (12:11, 12:42, 14:52) each followed
 * CLOSING the settings screen with objects of ours in it, and at 14:51 the
 * inspector's press of BackButton reported a fault inside `UnityEvent::Invoke`
 * with NO managed exception in the client's own log. `CloseAll` (§2.8,
 * `R disasm 0x17207a0`) calls each initialized tab's `Close()` -> vtable
 * `klass+0x288` -> `CleanupCreatedControls` -> `Object::Destroy` on every entry
 * of `_createdControls@0x88`, then clears `_initializedTabs` and nulls
 * `_currentTab@0x118`. It never calls `set_IsSelected(false)`.
 *
 * MEASURED `R disasm 0x1720b10`: `SettingsScreen::Close()` calls
 * `CloseAll()` at +0x2F and then nulls `_session@0x120` and
 * `_profileInfo@0x128`. Both UNIQUE (`R shared`).
 *
 * SO THE PAIR IS TWO DETOURS ON TWO DIFFERENT FUNCTIONS, never two on one:
 * a PREFIX on `Close` ("entered", and the moment to unregister our toggles
 * while everything is still alive) and a POSTFIX on `CloseAll` ("the cleanup
 * returned"). "Entered" without "returned" is a throw or fault unwound
 * through the close, which is exactly the shape that was invisible before. */
#define AOWL_NU_SCREEN_CLOSE          71
#define AOWL_NU_SCREEN_CLOSEALL       72

/* --- APPENDED (dlssrows.nim). Provenance is on the table rows themselves. */
#define AOWL_NU_SLIDER_SET            73
#define AOWL_NU_SAVESETTINGS          74
#define AOWL_NU_TR_SETSIBLINGIDX      75
#define AOWL_NU_GFXTAB_RESTARTMSG     76

/* --- APPENDED 2026-09-04 (dlssrows.nim DROPDOWNS + TOOLTIPS). Provenance is
 * on the table rows themselves. APPEND ONLY: this table is indexed by
 * POSITION from nativeui.nim. */
#define AOWL_NU_DDB_SET_CURIDX        77
#define AOWL_NU_DDB_GET_CURIDX        78
#define AOWL_NU_SC_SETTOOLTIP         79
#define AOWL_NU_DDB_SHOW              80
#define AOWL_NU_DDBNS_SHOW            81
#define AOWL_NU_BDDB_SHOW             82

/* The vtable slot `Show(IEnumerable<string>, Func<int,bool>)` occupies, and
 * the byte offset of `Il2CppClass.vtable`. NEITHER IS GUESSED.
 *
 * SLOT: MEASURED from `Il2CppMethodDefinition.slot@32` for all three bodies --
 * EFT.UI.DropDownBox::Show, EFT.UI.DropDownBoxNewStyle::Show and
 * EFT.UI.BaseDropDownBox::Show all report slot 24, which is what an override
 * of one base method must look like.
 *
 * VTABLE BASE: MEASURED by disassembling THIS BUILD'S OWN interface-dispatch
 * stub at RVA 0x52D0 (`il2cpp_resolve.py disasm 0x52d0 --len 200`), which the
 * game's own BaseDropDownBox::Show calls twice. Its tail is
 *   shl rax,4 ; add rax,0x138 ; add rax,r11 ; mov r8,[rax] ; mov rdx,[rax+8]
 * i.e. entry = klass + 0x138 + 16*index, entry[0] = methodPtr,
 * entry[8] = const MethodInfo*. The same routine reads the interface-offset
 * table at klass+0xB0 with its count in the u16 at klass+0x12E and a 16-byte
 * stride (`cmp qword ptr [r10 + rcx*8], rdx` with rcx = 2*i).
 *
 * WHY VIRTUAL DISPATCH AT ALL, when a direct call at a byte-verified RVA is
 * this host's normal move: `DropDownBoxNewStyle` is a SIBLING of
 * `DropDownBox`, not a subclass of it (both derive `BaseDropDownBox` --
 * MEASURED via Resolver.parent_chain). `Show` is PUBLIC|VIRTUAL. So a direct
 * call to DropDownBox::Show on a NewStyle receiver would run a body that
 * reads `_button@0xF8` and writes `_overlayLayer@0x148` on an object of a
 * different layout. The dispatch below cannot make that mistake, and the
 * identity check in nativeui.nim -- the resolved pointer must equal one of the
 * three INDEPENDENTLY byte-verified Show targets -- is what makes the vtable
 * read falsifiable instead of merely plausible. */
#define AOWL_NU_VSLOT_SHOW            24
#define AOWL_NU_KLASS_VTABLE_OFF      0x138
#define AOWL_NU_KLASS_IFOFFS_PTR      0xB0
#define AOWL_NU_KLASS_IFOFFS_CNT      0x12E
#define AOWL_NU_IFOFF_STRIDE          16
#define AOWL_NU_MAX_IFACES            512

/* `Il2CppArray`: max_length in the u32 at +0x18, first element at +0x20.
 * MEASURED from this build's own bounds-checked array-store helper at RVA
 * 0x5360 (`cmp edx,[rcx+0x18]` then `mov [rdx+rcx+0x20], r8b`), reached from
 * the same disassembly window as the dispatch stub above. */
#define AOWL_NU_ARR_LEN_OFF           0x18
#define AOWL_NU_ARR_DATA_OFF          0x20

/* The `.data` slot holding `Il2CppClass* IEnumerable<string>`, read out of the
 * ONE instruction that uses it: `BaseDropDownBox::Show` +0x178 is
 * `mov rdx, qword ptr [rip + 0x5747C29]` -> RVA 0x6DF5A38, and rdx is the
 * value the dispatch stub compares against each `interfaceOffsets[i]`. It is a
 * metadata-usage slot: before the game first runs Show it holds the raw token
 * 0x2000964F (`il2cpp_resolve.py bytes 0x6df5a38 8`), which is not a mappable
 * address -- so "has it been initialised" is answered by asking whether it
 * points at committed memory, and never assumed. */
#define AOWL_NU_IENUM_STRING_SLOT_RVA 0x6DF5A38u

/* UnityEngine.RenderMode. Named, because `0` appearing bare in a refusal is
 * indistinguishable from "we did not read anything". */
#define AOWL_NU_RENDERMODE_OVERLAY   0
#define AOWL_NU_RENDERMODE_CAMERA    1
#define AOWL_NU_RENDERMODE_WORLD     2
#define AOWL_NU_RENDERMODE_UNKNOWN (-1)

/* Every prologue below was read out of THIS build's GameAssembly.dll with
 * `tools/il2cpp_resolve.py bytes <RVA> 16`, and every RVA with
 * `il2cpp_resolve.py type <Type> --shared`. Nothing here was inferred from a
 * method name; the five entries that also appear in `aowlspt_invoke2.h`
 * (ctor, SetActive, get_transform, get_name, Instantiate, SetParentAndAlign)
 * were re-resolved independently and agree byte-for-byte, which is a free
 * cross-check on the whole table. */
static const AowlNuTarget aowl_nu_targets[] = {
    { "UnityEngine.GameObject::.ctor(String)", 0x52A8F40u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x8F,
        0xB6,0xE2,0x01 }, 16 },
    { "UnityEngine.GameObject::SetActive", 0x52A8BE0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xA7,0xB9,0xE2 }, 16 },
    { "UnityEngine.GameObject::get_transform", 0x52A8AE0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x93,0xBA,0xE2,0x01,
        0x48,0x8B,0xD9 }, 16 },
    /* The finished-state question "is it actually on screen" starts here. */
    { "UnityEngine.GameObject::get_activeInHierarchy", 0x52A8C90u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x0B,0xB9,0xE2,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.GameObject::set_layer", 0x52A8B80u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xFF,0xB9,0xE2 }, 16 },
    /* SHARED GENERIC BODY -- one function for every T, selected by the
     * MethodInfo* in RDX. Called, never detoured. */
    { "UnityEngine.GameObject::AddComponent<T>", 0x2A9AE90u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,
        0x24,0x18,0x57 }, 16 },
    { "UnityEngine.Object::get_name", 0x52AD4B0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x36,0x72,0xE2,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },
    /* Teardown. A UI layer without one is a leak by construction. */
    { "UnityEngine.Object::Destroy(Object)", 0x52AE0A0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x5B,0x66,0xE2,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.Object::Instantiate(Object)", 0x52ADBE0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x06,
        0x6B,0xE2,0x01 }, 16 },
    /* op_Implicit(Object) -> bool: Unity's OWN "is this still alive" test,
     * which is not the same question as "is this pointer non-null" -- a
     * destroyed Unity object keeps a live managed shell. Used so
     * `aowl_nu_destroy_all` cannot double-destroy. */
    { "UnityEngine.Object::op_Implicit(Object)", 0x52AD320u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0xC4,0x73,0xE2,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.Transform::SetParent(Transform,bool)", 0x52B8380u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,
        0xEC,0x20,0x48 }, 16 },
    { "UnityEngine.Transform::SetAsFirstSibling", 0x52B9CF0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xBB,0xAE,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },
    /* --- the layout setters. (this, Vector2* value, MethodInfo*) --- */
    { "UnityEngine.RectTransform::set_anchorMin_Injected", 0x52B6D80u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xAF,0xDD,0xE1 }, 16 },
    { "UnityEngine.RectTransform::set_anchorMax_Injected", 0x52B6E40u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xFF,0xDC,0xE1 }, 16 },
    { "UnityEngine.RectTransform::set_anchoredPosition_Injected", 0x52B6F00u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x4F,0xDC,0xE1 }, 16 },
    { "UnityEngine.RectTransform::set_sizeDelta_Injected", 0x52B6FC0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x9F,0xDB,0xE1 }, 16 },
    { "UnityEngine.RectTransform::set_pivot_Injected", 0x52B7080u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xEF,0xDA,0xE1 }, 16 },
    /* --- the layout GETTERS: the finished-state read. (this, T* ret, MI) --- */
    { "UnityEngine.RectTransform::get_anchoredPosition_Injected", 0x52B6EA0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xA7,0xDC,0xE1 }, 16 },
    { "UnityEngine.RectTransform::get_sizeDelta_Injected", 0x52B6F60u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xF7,0xDB,0xE1 }, 16 },
    { "UnityEngine.RectTransform::get_rect_Injected", 0x52B6CC0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x5F,0xDE,0xE1 }, 16 },
    /* --- text --- */
    { "TMPro.TMP_Text::set_text", 0x51BC1E0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0xB9,0xE8,
        0x00,0x00,0x00 }, 16 },
    { "TMPro.TMP_Text::get_text", 0x51BC100u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0xB9,0xE8,0x00,0x00,0x00,0x00,
        0x48,0x8B,0xD9 }, 16 },
    /* float arg -> XMM1, MethodInfo* -> R8. */
    { "TMPro.TMP_Text::set_fontSize", 0x51BD650u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0xF3,0x0F,0x10,0x81,0xEC,0x01,0x00,
        0x00,0x48,0x8B }, 16 },
    { "LocalizedText::SetLabelText", 0x140FE70u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x60,0x48,0x8B,0xFA,
        0x48,0x8B,0xD9 }, 16 },
    { "TMPro.TMP_DefaultControls::SetParentAndAlign", 0x51903A0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x68,
        0x13,0xF4,0x01 }, 16 },
    /* The codegen metadata-usage resolver -- warms a COLD AddComponent<T>
     * slot without running the owning method's body. See AOWL_NU_META_INIT. */
    { "il2cpp_codegen_initialize_runtime_metadata", 0x5251C0u,
      { 0x88,0x54,0x24,0x10,0x41,0x56,0x48,0x83,0xEC,0x30,0x45,0x33,0xC9,
        0x4C,0x8B,0xF1 }, 16 },
    /* --- image visibility. (this, Color* value, MethodInfo*) --- */
    { "UnityEngine.UI.Graphic::set_color", 0x53AD780u,
      { 0x0F,0x10,0x12,0xF3,0x0F,0x10,0x41,0x28,0x0F,0x2E,0xC2,0x7A,0x38,
        0x75,0x36,0xF3 }, 16 },
    { "UnityEngine.UI.Graphic::get_canvasRenderer", 0x53AE5A0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x3A,0x88,0xD2,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.UI.Graphic::SetAllDirty", 0x53ADA90u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x79,0x38,0x00,0x48,0x8B,0xD9,
        0x75,0x15,0x48 }, 16 },
    /* --- canvas creation. (this, int32 value, MethodInfo*) --- */
    { "UnityEngine.Canvas::set_renderMode", 0x55840D0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x27,0x3E,0xB5 }, 16 },
    { "UnityEngine.Canvas::get_renderMode", 0x5584080u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x73,0x3E,0xB5,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.Canvas::set_sortingOrder", 0x5584590u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xD7,0x39,0xB5 }, 16 },
    /* --- POLLED POINTER INPUT (indices 32..35), added for the native colour
     * widget. There is no delegate path on this build (see the INPUT header
     * comment in nativeui.nim), so interaction is a per-frame READ made from
     * the TarkovApplication::Update drain, on the Unity main thread.
     *
     * PROVENANCE, all four, measured with
     *   tools/il2cpp_resolve.py <asm> <metadec> type <T>   (RVA)
     *   ... shared <RVA>                                   (sharedness)
     *   ... bytes  <RVA>                                   (the 16 bytes below)
     * Every one is sharedness=UNIQUE (owners=1) and has a real body -- none is
     * the 0x628110 `C2 00 00` universal empty-body stub.
     *
     * NOTE ON THE TYPE. This is `UnityEngine.Input` in
     * UnityEngine.InputLegacyModule.dll -- the STATIC legacy API. It is NOT
     * `UnityEngine.UIElements.Input`, an unrelated INSTANCE class in
     * UIElementsModule whose `get_mousePosition` at 0xCF96D0 is SHARED by 4
     * methods. Resolving "Input::get_mousePosition" by member name finds that
     * one first; binding it would have been an instance call with no `this`. */
    { "UnityEngine.Input::GetMouseButton", 0x531EBD0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x53,0x71,0xDB,0x01,
        0x8B,0xD9,0x48 }, 16 },
    { "UnityEngine.Input::get_mousePosition_Injected", 0x531F740u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x73,0x66,0xDB,0x01,
        0x48,0x8B,0xD9 }, 16 },
    /* The screen-rect mapper. An overlay canvas puts world space AT screen
     * space, so centre = get_position and half-extent = rect * lossyScale is
     * the whole mapping -- and it needs NO managed array, which is why
     * `RectTransform::GetWorldCorners(Vector3[])` was NOT used: it takes a
     * managed Vector3[] and allocating one per frame breaks rule 7. */
    { "UnityEngine.Transform::get_position_Injected", 0x52BA1E0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x17,0xAA,0xE1 }, 16 },
    { "UnityEngine.Transform::get_lossyScale_Injected", 0x52BAA50u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x4F,0xA2,0xE1 }, 16 },
    /* --- the settings-row prefab path. See AOWL_NU_SETCTRL_SETTEXT. --- */
    { "EFT.UI.Settings.SettingControl::SetText", 0x16FA890u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0xD9,0x48,0x8B,0x89,0x80,
        0x00,0x00,0x00 }, 16 },
    { "EFT.UI.Settings.SettingControl::SetName", 0x16FA9D0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x07,0x9B,0x9D }, 16 },
    { "EFT.UI.Settings.SettingControl::SetSiblingIndex", 0x16FA910u,
      { 0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xBF,0x9B,0x9D }, 16 },
    { "EFT.UI.Settings.SettingControl::SetChangeAction", 0x16FAFC0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57,0x48,0x83,
        0xEC,0x20,0x80 }, 16 },
    /* STATIC, 3 args: (Object original, Transform parent, bool worldPosStays)
     * -> Object. RCX/RDX/R8 then the MethodInfo* in R9. This is the whole
     * substitute for the generic, no-code `SettingsTab.CreateControl<T>`. */
    { "UnityEngine.Object::Instantiate(Object,Transform,bool)", 0x52ADDA0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x6C,0x24,0x18,0x57,0x48,0x83,
        0xEC,0x20,0x80 }, 16 },
    /* EFT.UI.NumberSlider -- the widget INSIDE a SettingFloatSlider row
     * (`SettingFloatSlider.Slider` @0xA8). Driving it directly is how a row
     * gets a range and a displayed value WITHOUT a GameSetting<float>, which
     * is not constructible here. `Show` is (this, XMM1=min, XMM2=max,
     * R9=format string, MethodInfo* on the stack): the two floats ride XMM by
     * ARGUMENT POSITION, which is why the C thunk declares them as real float
     * parameters instead of marshalling them by hand. */
    { "EFT.UI.NumberSlider::Show", 0x16B4EA0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57,0x48,0x83,
        0xEC,0x60,0x80 }, 16 },
    { "EFT.UI.NumberSlider::SetCurrentValue", 0x16B5300u,
      { 0x48,0x89,0x5C,0x24,0x10,0x57,0x48,0x83,0xEC,0x60,0x80,0x3D,0x67,
        0x8E,0xA0,0x05 }, 16 },
    /* The READBACK. A row told to show 0.35 that reads back 0.35 off the LIVE
     * slider is the only finished-state check available here; the value we
     * passed in a moment ago proves nothing about what the widget holds. */
    { "EFT.UI.NumberSlider::CurrentValue", 0x16B5850u,
      { 0x48,0x83,0xEC,0x28,0x48,0x8B,0x89,0x80,0x00,0x00,0x00,0x48,0x85,
        0xC9,0x74,0x18 }, 16 },
    /* --- the subtab-highlight pair. See AOWL_NU_ANIMTOGGLE_SETTOGGLED. --- */
    { "EFT.UI.AnimatedToggle::set_IsToggled", 0x16AD190u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x0F,0xB6,0xFA,
        0x45,0x33,0xC9 }, 16 },
    { "EFT.UI.UISpawnableToggle::set_IsToggled", 0x1435A50u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x99,
        0xD0,0x00,0x00 }, 16 },
    /* --- the row-geometry read. See AOWL_NU_RT_GET_ANCHORMIN. --- */
    { "UnityEngine.RectTransform::get_anchorMin_Injected", 0x52B6D20u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x07,0xDE,0xE1 }, 16 },
    { "UnityEngine.RectTransform::get_anchorMax_Injected", 0x52B6DE0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x57,0xDD,0xE1 }, 16 },
    { "UnityEngine.RectTransform::get_pivot_Injected", 0x52B7020u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x47,0xDB,0xE1 }, 16 },
    /* --- opting out of a layout group. See AOWL_NU_LAYOUTELEM_SET_IGNORE. --- */
    { "UnityEngine.UI.LayoutElement::set_ignoreLayout", 0x5598100u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x75,
        0xFF,0xB3,0x01 }, 16 },
    /* --- making room. See AOWL_NU_RECTOFFSET_GET_TOP. --- */
    { "UnityEngine.RectOffset::get_top", 0x526AFF0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x2B,0x7F,0xE6,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.RectOffset::set_top", 0x526B040u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xDF,0x7E,0xE6 }, 16 },
    { "UnityEngine.UI.LayoutGroup::SetDirty", 0x5599FD0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0xBD,0xE0,0xB3,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },
    /* --- draw/raycast order. See AOWL_NU_TR_SETASLASTSIB. --- */
    { "UnityEngine.Transform::SetAsLastSibling", 0x52B9D40u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x73,0xAE,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.Transform::GetSiblingIndex", 0x52B9DF0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xD3,0xAD,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },
    /* --- native tabs. See AOWL_NU_BEHAVIOUR_SET_ENABLED. --- */
    { "UnityEngine.Behaviour::set_enabled", 0xC4C760u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x4F,0x7D,0x48 }, 16 },
    { "EFT.UI.UIAnimatedToggleSpawner::SpawnObject", 0x16BC7F0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xAC,
        0x19,0xA0,0x05 }, 16 },
    { "EFT.UI.UIAnimatedToggleSpawner::SetHeaderText", 0x16BCC30u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x30,0x83,0x3D,0xFF,
        0x98,0x9F,0x05 }, 16 },
    { "EFT.UI.UIAnimatedToggleSpawner::SetActive", 0x16BCCE0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,
        0xEC,0x20,0x80 }, 16 },
    { "EFT.UI.Settings.SettingsTab::CleanupCreatedControls", 0x171BE50u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x4C,0x24,0x08,0x57,0x48,0x83,
        0xEC,0x60,0x48 }, 16 },
    { "UnityEngine.UI.Toggle::set_group", 0x55B9D30u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x45,0x33,0xC9,0x41,0xB0,0x01,0x48,
        0x8B,0xD9,0xE8 }, 16 },
    /* THE TOGGLE EVENT. `Set`, not `set_isOn` -- see the block comment. */
    { "UnityEngine.UI.Toggle::Set", 0x55BA450u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,
        0xEC,0x20,0x80 }, 16 },
    /* --- CanvasGroup. See AOWL_NU_CG_GET_ALPHA. --- */
    { "UnityEngine.CanvasGroup::get_alpha", 0x5580A20u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x7B,0x73,0xB5,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.CanvasGroup::set_alpha", 0x5580A70u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x33,0x73,0xB5,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.CanvasGroup::get_interactable", 0x5580AD0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xDB,0x72,0xB5,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.CanvasGroup::set_interactable", 0x5580B20u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x8F,0x72,0xB5 }, 16 },
    { "UnityEngine.CanvasGroup::set_blocksRaycasts", 0x5580BD0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xEF,0x71,0xB5 }, 16 },
    /* --- the panel switch. See AOWL_NU_SCREEN_SHOWSCREEN. --- */
    { "EFT.UI.Settings.SettingsScreen::ShowScreen", 0x1720DE0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,
        0xEC,0x30,0x80 }, 16 },
    { "EFT.UI.Settings.SettingsTab::set_IsSelected", 0x171BCA0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x56,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x37,0x88,0x9B }, 16 },
    { "EFT.UI.UIAnimatedToggleSpawner::ToggleSilently", 0x16BCBA0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xFD,
        0x15,0xA0,0x05 }, 16 },
    { "UnityEngine.UI.Toggle::SetToggleGroup", 0x55BA150u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,
        0x24,0x18,0x57 }, 16 },
    /* --- the close path. See AOWL_NU_SCREEN_CLOSE. --- */
    { "EFT.UI.Settings.SettingsScreen::Close", 0x1720B10u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x02,0xD9,0x99,0x05,0x00,
        0x48,0x8B,0xD9 }, 16 },
    { "EFT.UI.Settings.SettingsScreen::CloseAll", 0x17207A0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x70,0xDC,0x99,0x05,0x00,
        0x48,0x8B,0xD9 }, 16 },
    /* --- THE VALUE BINDING (settingsbind.nim). Two rows, APPENDED: this table
     * is indexed POSITIONALLY by the `NuT*` constants, so a row inserted in
     * the middle silently re-points every constant after it. Appending is the
     * only safe edit, and the positional self-check below covers the rest.
     *
     * `UnityEngine.UI.Slider::Set(float input, bool sendCallback)` -- the
     * general slider-changed event. MEASURED 2026-09-03 with
     * `il2cpp_resolve.py typemethods UnityEngine.UI.Slider` (arity 2),
     * `shared 0x55b44a0` -> UNIQUE owners=1, and `bytes 0x55b44a0` for the
     * prologue below. NOT `set_value` and NOT `SetValueWithoutNotify`: both
     * are thin wrappers that funnel here, and `Set` is where sendCallback --
     * the flag that separates a player's drag from a programmatic restore --
     * actually exists as an argument.
     *
     * `SettingsScreenController::SaveSettings()` -- the persist edge.
     * `shared 0x1721e20` -> UNIQUE owners=1; arity 0, so 2 register slots. */
    { "UnityEngine.UI.Slider::Set", 0x55B44A0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x30,0x80,0x3D,0x86,
        0x3C,0xB2,0x01 }, 16 },
    { "EFT.UI.Settings.SettingsScreenController::SaveSettings", 0x1721E20u,
      { 0x40,0x53,0x48,0x83,0xEC,0x70,0x80,0x3D,0xFE,0xC5,0x99,0x05,0x00,
        0x48,0x8B,0xD9 }, 16 },
    /* --- DLSS ROW PLACEMENT AND THE GAME'S OWN RESTART MODAL (dlssrows.nim).
     * APPENDED at the END, which is the only safe edit to a POSITIONALLY
     * indexed table -- another agent may append after these; do not insert
     * above them.
     *
     * `UnityEngine.Transform::SetSiblingIndex(int index)`. MEASURED 2026-09-04
     * `il2cpp_resolve.py type UnityEngine.Transform` -> rid=3241 arity=1
     * RVA=0x52b9d90; `shared 0x52b9d90` -> UNIQUE owners=1; `bytes 0x52b9d90
     * 16` -> the prologue below. Section `il2cpp`, NOT the 0x628110 universal
     * stub.
     *
     * WHY IT IS HERE WHEN `SettingControl::SetSiblingIndex` @0x16FA910 ALREADY
     * IS: MEASURED `disasm 0x16fa910` -- that method is
     * `get_transform(this)` then this very function, and it THROWS (call
     * 0x5d2530, the null-ref helper) if the transform reads null. It is also
     * only callable on a receiver that IS a SettingControl. A CLONED row is
     * reached as a Transform, so the Transform-level call is the one that
     * works for both shapes and takes no throw path we cannot pre-check.
     *
     * `EFT.UI.Settings.GraphicsSettingsTab::ShowTextureQualityChangedMessage()`
     * -- THE GAME'S OWN "applied after game restart" modal, not a panel of
     * ours. MEASURED `type EFT.UI.Settings.GraphicsSettingsTab` -> rid=94756
     * arity=0 RVA=0x1714ea0; `shared` -> UNIQUE owners=1; `bytes` -> below.
     * MEASURED `disasm 0x1714ea0 --len 520`: it tests
     * `_textureMessageShown@0x141`, returns immediately when set, otherwise
     * calls `LocalizationManager::get_Instance` -> `LocalizedValue(id)` ->
     * `ItemUiContext::ShowMessageWindow(string description, Action accept,
     * ...)` @0x1517C00 and then sets `_textureMessageShown = 1`.
     *
     * So calling it gives the player the identical dialog, with BSG's own
     * localized header and body and BSG's own OK button, on BSG's own
     * ItemUiContext -- there is no text of ours and no window of ours. The one
     * stock side effect is that `_textureMessageShown` latches, exactly as it
     * does when the player changes texture quality; the game clears it itself.
     * arity 0 instance -> the frame is (this, MethodInfo*). */
    { "UnityEngine.Transform::SetSiblingIndex", 0x52B9D90u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x27,0xAE,0xE1 }, 16 },
    { "EFT.UI.Settings.GraphicsSettingsTab::ShowTextureQualityChangedMessage",
      0x1714EA0u,
      { 0x40,0x57,0x48,0x83,0xEC,0x60,0x80,0x3D,0x18,0x95,0x9A,0x05,0x00,
        0x48,0x8B,0xF9 }, 16 },
    /* --- DLSS DROPDOWNS AND TOOLTIPS (dlssrows.nim). APPENDED at the END.
     *
     * `EFT.UI.BaseDropDownBox::set_CurrentIndex(int)` @0x698560 and
     * `get_CurrentIndex()` @0x698550. MEASURED `typemethods
     * EFT.UI.BaseDropDownBox`: arity 1 / arity 0, both SHARED x2 -- which is
     * fine here because this layer CALLS them and detours nothing. The bytes
     * say what they are without any name being trusted: `89 91 E8 00 00 00 C3`
     * is `mov [rcx+0xE8], edx ; ret` and `8B 81 E8 00 00 00 C3` is
     * `mov eax, [rcx+0xE8] ; ret` -- exactly
     * `<CurrentIndex>k__BackingField@0xE8` (`tools/fldoff.py fields
     * EFT.UI.BaseDropDownBox`, String self-check passing). siglen is SEVEN,
     * not sixteen: everything past the `ret` is `CC` alignment padding that
     * belongs to no method, and asserting on padding is asserting on the
     * linker.
     *
     * `EFT.UI.Settings.SettingControl::SetTooltip(SettingsTooltipData,
     * SettingsTooltip)` @0x16FAC00. MEASURED sharedness=UNIQUE, non-virtual,
     * section `il2cpp`. MEASURED `disasm 0x16fac00 --len 940`: it reads
     * `_blocker@0x88` and RETURNS `this` when it is null; calls
     * `UiElementBlocker::TryGetTooltip` and returns when that is false;
     * returns when the data argument is null. Only then does it construct its
     * OWN `SettingsTooltipData` through `.ctor(ESettingsOption)` @0x16FCD70,
     * copy the fields across, and store the hover area into
     * `_tooltipSettingsHover@0x98`. Three no-op paths, no throw path -- which
     * is why the object we hand it is a TEMPLATE and why the verdict has to
     * read `_tooltipSettingsHover@0x98 -> _tooltipData@0x20 -> Text@0x20`
     * back rather than trust the call's return.
     *
     * The three `Show(IEnumerable<string>, Func<int,bool>)` bodies. All three
     * are in the table ONLY so that each is byte-verified through the ordinary
     * `aowl_nu_fn` path; NONE of them is called directly by index. The pointer
     * actually called comes from the receiver's own vtable slot 24 and must
     * COMPARE EQUAL to one of these three. DropDownBox and DropDownBoxNewStyle
     * share their first 16 prologue bytes -- that is why the positional
     * self-check in nativeui.nim compares NAMES, which differ. */
    { "EFT.UI.BaseDropDownBox::set_CurrentIndex", 0x698560u,
      { 0x89,0x91,0xE8,0x00,0x00,0x00,0xC3 }, 7 },
    { "EFT.UI.BaseDropDownBox::get_CurrentIndex", 0x698550u,
      { 0x8B,0x81,0xE8,0x00,0x00,0x00,0xC3 }, 7 },
    { "EFT.UI.Settings.SettingControl::SetTooltip", 0x16FAC00u,
      { 0x40,0x55,0x56,0x41,0x57,0x48,0x83,0xEC,0x30,0x80,0x3D,0x29,0x37,
        0x9C,0x05,0x00 }, 16 },
    { "EFT.UI.DropDownBox::Show", 0x16AFC80u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57,0x48,0x83,
        0xEC,0x20,0x80 }, 16 },
    { "EFT.UI.DropDownBoxNewStyle::Show", 0x16B1080u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57,0x48,0x83,
        0xEC,0x20,0x80 }, 16 },
    { "EFT.UI.BaseDropDownBox::Show", 0x16ADC90u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57,0x41,0x54,
        0x41,0x55,0x41 }, 16 },
    /* --- THE DROPDOWN LABEL REFRESH. APPENDED at the END.
     *
     * `EFT.UI.BaseDropDownBox::SetLabelText(string)` @0x16AEE60. MEASURED
     * `typemethods EFT.UI.BaseDropDownBox` -> arity 1, non-virtual, PUBLIC,
     * `shared 0x16AEE60` -> sharedness=UNIQUE owners=1, section `il2cpp`, and
     * it is NOT the 0x628110 universal empty-body stub.
     *
     * WHAT IT ACTUALLY IS, and why it is the right call rather than a
     * plausible-sounding one. MEASURED `disasm 0x16aee60 --len 120`, the whole
     * body is seventeen bytes:
     *
     *     4C 8B 01                mov r8, [rcx]            ; the Il2CppClass*
     *     49 8B 80 08 03 00 00    mov rax, [r8+0x308]      ; a code pointer
     *     4D 8B 80 10 03 00 00    mov r8,  [r8+0x310]      ; its MethodInfo*
     *     48 FF E0                jmp rax
     *
     * -- a TAIL-DISPATCH through the RECEIVER'S OWN class at byte offsets
     * 0x308/0x310, i.e. the virtual `SetTextInternal(string)`. That matters
     * twice over: it is correct for `DropDownBox` AND for its sibling
     * `DropDownBoxNewStyle` without this host having to know which it holds,
     * and it is the SAME two loads the game itself makes.
     *
     * That last clause is the measurement that settles the 2026-09-04 "Blank
     * item" defect, and it is not an inference from a name. MEASURED `disasm
     * 0x16aeac0 --len 470` (`BaseDropDownBox::UpdateValue`), at +0x121:
     *
     *     mov [rsi+0xE8], edi                 ; <CurrentIndex>k__BackingField
     *     ...
     *     mov r8, [rsi]                       ; the Il2CppClass*
     *     movups xmm0, [rcx+rax*8]            ; _values[i] (DropDownItem, 16B)
     *     mov rax, [r8+0x308]                 ; THE SAME SLOT
     *     mov r8,  [r8+0x310]                 ; THE SAME SLOT
     *     movq rdx, xmm0                      ; ...its first 8 bytes: a string
     *     call rax
     *
     * So the game's own `UpdateValue` writes the index and then refreshes the
     * visible label through EXACTLY the dispatch this one instruction-triple
     * performs. `set_CurrentIndex` @0x698560 is `mov [rcx+0xE8], edx ; ret` and
     * does NOT refresh anything -- which is why five dropdowns whose
     * CurrentIndex read back correctly still displayed the prefab's authored
     * "Blank item" caption.
     *
     * `SetLabelText` is called INSTEAD OF mirroring `UpdateValue` because
     * UpdateValue has SEVEN argument slots, two of them `Nullable<int>` value
     * structs, three of them on the caller's stack -- a frame this host would
     * have to construct by hand -- while `SetLabelText` is (this, string,
     * MethodInfo*) and reaches the identical slot. The one thing UpdateValue
     * does that this does not is fire `_onValueChanged@0xb0`, which is exactly
     * what we do NOT want: our rows are filled at build time and a callback
     * there would run the game's graphics-apply path on a value nobody chose.
     *
     * The FINISHED-STATE readback is a different object again -- the label TMP
     * `DropDownBox._currentValueText@0xf0` (MEASURED `fldoff.py fields
     * EFT.UI.DropDownBox`, String self-check passing; and `disasm 0x16b0c40`,
     * `DropDownBox::SetTextInternal`, reads exactly that field twice) -- so
     * the check reads what the GAME wrote, never what we passed. */
    { "EFT.UI.BaseDropDownBox::SetLabelText", 0x16AEE60u,
      { 0x4C,0x8B,0x01,0x49,0x8B,0x80,0x08,0x03,0x00,0x00,0x4D,0x8B,0x80,
        0x10,0x03,0x00 }, 16 },
};

#define AOWL_NU_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_nu_targets) / sizeof(aowl_nu_targets[0])))

/* THE POSITIONAL-BINDING SELF-CHECK, and the measured defect it exists for.
 *
 * `nativeui.nim` indexes this table by POSITION, through the `NuT*` constants.
 * `aowl_du_targets` is indexed the same way and HAS had a self-check since the
 * 2026-08-24 defect, where inserting a row in the middle silently re-pointed
 * `DuGetParent` at `Transform::set_localPosition` -- a byte-verified function
 * of the wrong shape, called with the wrong frame. This table had NO such
 * check. Adding four rows is exactly the edit that causes that bug, so the
 * check comes with them.
 *
 * A name lookup, not an assertion, so the Nim side can report WHICH index is
 * wrong rather than failing anonymously. */
static const char* aowl_nu_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_NU_TARGET_COUNT) return "";
    return aowl_nu_targets[i].name;
}
static uint32_t aowl_nu_target_rva(int32_t i) {
    if (i < 0 || i >= AOWL_NU_TARGET_COUNT) return 0u;
    return aowl_nu_targets[i].rva;
}

static int32_t aowl_nu_verified = 0;
static int32_t aowl_nu_rejected = 0;
/* Verifies refused because the SHARED prologue snapshot table was full --
 * our capacity limit, not a client change. Kept apart from `rejected` so a
 * refusal can never be reported as "this build changed". */
static int32_t aowl_nu_profull = 0;
static int32_t aowl_nu_faults   = 0;

/* WHY A TARGET WAS REFUSED -- and the live bug that made this necessary.
 *
 * The first live run of this layer logged, at boot:
 *
 *   nativeui: 0 of 25 managed targets verified ... (25 REJECTED)
 *
 * and then, at the proof, went on to add a component and read back a real
 * rect. Both statements were true of different things, and the first one was
 * a LIE about the second. `aowl_nu_fn` returns NULL for five distinct
 * reasons, only ONE of which is "the bytes are not what this build's metadata
 * says"; the census counted all five as a rejection and named them all as a
 * failed prologue verify. The actual reason was the benign one --
 * GameAssembly.dll was not loaded yet, because the census ran too early in
 * host startup.
 *
 * Twenty-five confident, wrong warnings blaming the game build. That is the
 * P0 shape this repo keeps paying for: a diagnostic that asserts a cause it
 * did not measure. So the reason is now RECORDED per refusal, and the census
 * reports the breakdown rather than one number that flattens five causes into
 * the scariest of them. */
#define AOWL_NU_WHY_OK          0
#define AOWL_NU_WHY_NO_MODULE   1   /* GameAssembly.dll not loaded (yet)     */
#define AOWL_NU_WHY_NOT_COMMIT  2   /* the RVA is not committed memory       */
#define AOWL_NU_WHY_NOT_EXEC    3   /* committed, but not executable         */
#define AOWL_NU_WHY_MISMATCH    4   /* THE REAL ONE: bytes differ            */
#define AOWL_NU_WHY_DISABLED    5   /* the layer has self-disabled           */
#define AOWL_NU_WHY_BADINDEX    6
#define AOWL_NU_WHY_PROFULL     7   /* OURS: the shared prologue snapshot
                                     * table was full; the RVA was never
                                     * captured. NOT a client change. */

static int32_t aowl_nu_why[AOWL_NU_TARGET_COUNT];

/* Is GameAssembly.dll even loaded? The census must ask this ONCE, up front,
 * instead of letting 25 targets each discover it and each blame the build.
 * `aowl_mi2_base_ok` exists for exactly the same reason. */
static int32_t aowl_nu_base_ok(void) {
    return GetModuleHandleA("GameAssembly.dll") ? 1 : 0;
}
static int32_t aowl_nu_why_of(int32_t i) {
    if (i < 0 || i >= AOWL_NU_TARGET_COUNT) return AOWL_NU_WHY_BADINDEX;
    return aowl_nu_why[i];
}
/* How many targets were refused for THE REAL REASON -- a byte mismatch --
 * as opposed to "the module is not loaded yet". The census prints both, so a
 * stale-RVA build and an early call can never again read the same. */
static int32_t aowl_nu_mismatch_count(void) {
    int32_t i, n = 0;
    for (i = 0; i < AOWL_NU_TARGET_COUNT; i++)
        if (aowl_nu_why[i] == AOWL_NU_WHY_MISMATCH) n++;
    return n;
}

/* Six faults is enough to distinguish "one bad frame" from "this build is not
 * the build these RVAs came from"; past it the layer refuses everything. */
#define AOWL_NU_MAX_FAULTS 6

static int32_t aowl_nu_disabled(void) {
    return (aowl_nu_faults >= AOWL_NU_MAX_FAULTS) ? 1 : 0;
}
static void aowl_nu_note_fault(void) { aowl_nu_faults++; }
static int32_t aowl_nu_fault_count(void)  { return aowl_nu_faults; }
static int32_t aowl_nu_target_count(void) { return AOWL_NU_TARGET_COUNT; }
static int32_t aowl_nu_profull_count(void){ return aowl_nu_profull; }
static int32_t aowl_nu_ok_count(void)     { return aowl_nu_verified; }
static int32_t aowl_nu_bad_count(void)    { return aowl_nu_rejected; }

static const char* aowl_nu_name(int32_t i) {
    if (i < 0 || i >= AOWL_NU_TARGET_COUNT) return "";
    return aowl_nu_targets[i].name;
}
static uint32_t aowl_nu_rva(int32_t i) {
    if (i < 0 || i >= AOWL_NU_TARGET_COUNT) return 0u;
    return aowl_nu_targets[i].rva;
}

/* A verified code pointer, or NULL.
 *
 * VirtualQuery FIRST, insist on MEM_COMMIT and an executable protection, and
 * only then compare bytes -- a stale RVA on another build can address an
 * uncommitted page where `memcmp` itself faults.
 *
 * The comparison is against the STARTUP SNAPSHOT via `aowl_pro_verify`, not
 * against live memory. That matters even though this layer detours nothing:
 * `TMP_Text::set_text` and `LocalizedText::SetLabelText` are targets other
 * features touch, and a verify that reads a trampoline self-rejects with a
 * message blaming the game build. */
static void* aowl_nu_fn_full(int32_t i) {
    HMODULE ga;
    const AowlNuTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_NU_TARGET_COUNT) return NULL;
    if (aowl_nu_disabled()) { aowl_nu_why[i] = AOWL_NU_WHY_DISABLED; return NULL; }
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_nu_why[i] = AOWL_NU_WHY_NO_MODULE; return NULL; }
    t = &aowl_nu_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0 || mbi.State != MEM_COMMIT) {
        aowl_nu_why[i] = AOWL_NU_WHY_NOT_COMMIT;
        return NULL;
    }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_nu_why[i] = AOWL_NU_WHY_NOT_EXEC;
        return NULL;
    }
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        /* TWO DIFFERENT FAILURES, TWO DIFFERENT REASONS. A verify that failed
         * because OUR snapshot table had no free row says nothing about the
         * client, so it is counted separately and never latched as a
         * signature mismatch. See aowl_pro_last_reason_text(). */
        if (aowl_pro_last_was_table_full()) {
            aowl_nu_why[i] = AOWL_NU_WHY_PROFULL;
            aowl_nu_profull++;
            return NULL;
        }
        aowl_nu_why[i] = AOWL_NU_WHY_MISMATCH;
        aowl_nu_rejected++;
        return NULL;
    }
    aowl_nu_why[i] = AOWL_NU_WHY_OK;
    aowl_nu_verified++;
    return (void*)p;
}

/* ---- THE VERIFY CACHE, and why the verify is not weakened by it ---------
 *
 * MEASURED, not suspected: `aowl_nu_fn` was called on EVERY setter and EVERY
 * getter, and each call did `GetModuleHandleA("GameAssembly.dll")` -- which
 * takes the loader lock and walks the module list by name -- then a
 * `VirtualQuery`, then a linear scan of the prologue snapshot and a memcmp.
 * A steady natesp tick makes a few hundred of those. The natesp cost meter
 * priced the two phases that do nothing else at 4.6ms (apply) and 6.8ms
 * (verdict) out of a 14.5ms body, against sub-phases doing pure arithmetic at
 * 1-12us. The per-call preamble WAS the feature's cost.
 *
 * What is cached is the RESULT of a verify that really happened, for a bounded
 * time, and both the positive and the negative result -- a refused target must
 * not re-run the full check (and re-warn) on every call either.
 *
 * WHAT THIS DOES NOT WEAKEN. The bytes are still compared against the STARTUP
 * SNAPSHOT (`aowl_pro_verify`), the region is still required to be committed
 * and executable, and the module is still required to be loaded. Every one of
 * those is simply asked at most once per AOWL_NU_REVERIFY_MS per target
 * instead of hundreds of times per frame. The exposure a cache adds is a
 * window of at most that long in which a target patched by something else
 * would still be called with the old verdict -- and this layer detours
 * nothing, so nothing WE do can open that window.
 *
 * HONEST LIMIT: `GetTickCount64` has ~15ms resolution, so the window is
 * "about 2 seconds", not exactly. That is deliberate -- a QPC read per call
 * would put a clock back in the hot path this change exists to empty. */
#define AOWL_NU_REVERIFY_MS 2000
static void*    aowl_nu_cache[AOWL_NU_TARGET_COUNT];
static uint64_t aowl_nu_cache_at[AOWL_NU_TARGET_COUNT];
static int32_t  aowl_nu_cache_valid[AOWL_NU_TARGET_COUNT];
static int64_t  aowl_nu_cache_hits = 0;
static int64_t  aowl_nu_cache_verifies = 0;

static void* aowl_nu_fn(int32_t i) {
    uint64_t now;
    void* p;
    if (i < 0 || i >= AOWL_NU_TARGET_COUNT) return NULL;
    /* The self-disable is NOT cacheable: it must take effect on the very next
     * call, which is the whole point of a fault budget. */
    if (aowl_nu_disabled()) { aowl_nu_why[i] = AOWL_NU_WHY_DISABLED; return NULL; }
    now = (uint64_t)GetTickCount64();
    if (aowl_nu_cache_valid[i] && (now - aowl_nu_cache_at[i]) < AOWL_NU_REVERIFY_MS) {
        aowl_nu_cache_hits++;
        return aowl_nu_cache[i];   /* may be NULL: a cached REFUSAL */
    }
    p = aowl_nu_fn_full(i);
    aowl_nu_cache[i] = p;
    aowl_nu_cache_at[i] = now;
    aowl_nu_cache_valid[i] = 1;
    aowl_nu_cache_verifies++;
    return p;
}
static int64_t aowl_nu_cache_hit_count(void)    { return aowl_nu_cache_hits; }
static int64_t aowl_nu_cache_verify_count(void) { return aowl_nu_cache_verifies; }

/* Prime the snapshot for every target, at host startup, before any feature
 * has had a chance to patch one. Called from the same place the rest of the
 * priming happens. */
static void aowl_nu_prime_all(void) {
    int32_t i;
    for (i = 0; i < AOWL_NU_TARGET_COUNT; i++)
        aowl_pro_prime(aowl_nu_targets[i].rva);
}

/* ------------------------------------------------------------------ *
 * 2. Call thunks -- one per SHAPE, MethodInfo* always explicit
 *
 * Passing the hidden MethodInfo* implicitly (declaring one parameter fewer and
 * hoping the register happens to be zero) works in testing and corrupts a
 * generic call in the field. It is a parameter here, always.
 * ------------------------------------------------------------------ */

typedef void  (*AowlNu_V_P)   (void*, void*);                 /* this, MI     */
typedef void* (*AowlNu_P_P)   (void*, void*);
typedef void  (*AowlNu_V_PP)  (void*, void*, void*);          /* this,a0,MI   */
typedef void  (*AowlNu_V_PB)  (void*, int32_t, void*);
typedef void  (*AowlNu_V_PI)  (void*, int32_t, void*);
typedef void  (*AowlNu_V_PF)  (void*, float,  void*);
typedef void  (*AowlNu_V_PPB) (void*, void*, int32_t, void*);
typedef void* (*AowlNu_P_PP)  (void*, void*, void*);
typedef void* (*AowlNu_P_S1)  (void*, void*);                 /* static a0,MI */
typedef void  (*AowlNu_V_S1)  (void*, void*);
typedef void  (*AowlNu_V_S2)  (void*, void*, void*);
/* bool returns come back in AL. Declaring an int32 return would read the full
 * EAX, whose upper 24 bits the callee is not required to have set. */
typedef unsigned char (*AowlNu_B_P) (void*, void*);
/* (this, MethodInfo*) -> int32 in EAX. Distinct from AowlNu_B_P only in that
 * the result is a VALUE, not a truth: `Canvas::get_renderMode` returns the
 * RenderMode enum, and reading it through the bool thunk would collapse
 * ScreenSpaceCamera(1) and WorldSpace(2) into the same "true". */
typedef int32_t (*AowlNu_I_P) (void*, void*);
typedef unsigned char (*AowlNu_B_S1)(void*, void*);

static void aowl_nu_call_v_pp(void* fn, void* self, void* a0) {
    if (!fn || !self) return;
    ((AowlNu_V_PP)fn)(self, a0, NULL);
}
static void aowl_nu_call_v_pb(void* fn, void* self, int32_t a0) {
    if (!fn || !self) return;
    ((AowlNu_V_PB)fn)(self, a0, NULL);
}
static void aowl_nu_call_v_pi(void* fn, void* self, int32_t a0) {
    if (!fn || !self) return;
    ((AowlNu_V_PI)fn)(self, a0, NULL);
}
static void aowl_nu_call_v_pf(void* fn, void* self, float a0) {
    if (!fn || !self) return;
    ((AowlNu_V_PF)fn)(self, a0, NULL);
}
static void aowl_nu_call_v_ppb(void* fn, void* self, void* a0, int32_t a1) {
    if (!fn || !self) return;
    ((AowlNu_V_PPB)fn)(self, a0, a1, NULL);
}
static void* aowl_nu_call_p_p(void* fn, void* self) {
    if (!fn || !self) return NULL;
    return ((AowlNu_P_P)fn)(self, NULL);
}
static void* aowl_nu_call_p_pp(void* fn, void* self, void* a0) {
    if (!fn || !self) return NULL;
    return ((AowlNu_P_PP)fn)(self, a0, NULL);
}
static void* aowl_nu_call_p_s1(void* fn, void* a0) {
    if (!fn || !a0) return NULL;
    return ((AowlNu_P_S1)fn)(a0, NULL);
}
static void aowl_nu_call_v_s1(void* fn, void* a0) {
    if (!fn || !a0) return;
    ((AowlNu_V_S1)fn)(a0, NULL);
}
static void aowl_nu_call_v_s2(void* fn, void* a0, void* a1) {
    if (!fn || !a0) return;
    ((AowlNu_V_S2)fn)(a0, a1, NULL);
}
static int32_t aowl_nu_call_b_p(void* fn, void* self) {
    if (!fn || !self) return 0;
    return ((AowlNu_B_P)fn)(self, NULL) ? 1 : 0;
}
/* `defVal` is returned when the call cannot be made at all, and callers pass a
 * value that is NOT a legal answer (-1 for a RenderMode) so "could not ask" can
 * never be mistaken for "the answer is 0" -- which for renderMode would be the
 * exact value we are trying to prove. */
static int32_t aowl_nu_call_i_p(void* fn, void* self, int32_t defVal) {
    if (!fn || !self) return defVal;
    return ((AowlNu_I_P)fn)(self, NULL);
}
static int32_t aowl_nu_call_b_s1(void* fn, void* a0) {
    if (!fn || !a0) return 0;
    return ((AowlNu_B_S1)fn)(a0, NULL) ? 1 : 0;
}
/* STATIC, ONE int32 ARG -> bool. `Input::GetMouseButton(0)` is the whole
 * reason this exists and cannot use `aowl_nu_call_b_s1`: that one REFUSES a
 * NULL a0, and button 0 -- the left mouse button, the only one this widget
 * cares about -- is exactly the argument it would refuse. Passing an int
 * through a void* parameter would have "worked" and been a lie about the ABI
 * in the signature, which is the kind of thing that reads as correct for a
 * year. */
typedef unsigned char (*AowlNu_B_SI)(int32_t, void*);
static int32_t aowl_nu_call_b_si(void* fn, int32_t a0) {
    if (!fn) return 0;
    return ((AowlNu_B_SI)fn)(a0, NULL) ? 1 : 0;
}
/* STATIC, (Object*, Transform*, bool) -> Object*. `worldPositionStays` is
 * passed as the game itself passes it from CreateControl<T>: FALSE, so the
 * fresh row takes the parent layout instead of keeping a prefab world pose.
 * `a1` (the parent) is REFUSED when NULL -- an Instantiate with no parent
 * lands the row at the scene root, which renders nowhere and reports success,
 * and that is precisely this repository signature false positive. */
typedef void* (*AowlNu_P_S3PPB)(void*, void*, unsigned char, void*);
static void* aowl_nu_call_p_s3ppb(void* fn, void* a0, void* a1, int32_t a2) {
    if (!fn || !a0 || !a1) return NULL;
    return ((AowlNu_P_S3PPB)fn)(a0, a1, (unsigned char)(a2 ? 1 : 0), NULL);
}
/* INSTANCE, (float, float, void*) -> void. Declared with real float
 * parameters so the compiler places them in XMM1/XMM2 BY POSITION, which is
 * the ABI; pushing them through an integer register would compile, run, and
 * silently give NumberSlider::Show two garbage bounds. */
typedef void (*AowlNu_V_PFFP)(void*, float, float, void*, void*);
static void aowl_nu_call_v_pffp(void* fn, void* self, float a0, float a1,
                                void* a2) {
    if (!fn || !self) return;
    ((AowlNu_V_PFFP)fn)(self, a0, a1, a2, NULL);
}
/* INSTANCE, 0 args -> float (XMM0). `defVal` is returned when the call cannot
 * be made at all, and callers pass a value no slider can legally hold, so
 * "could not ask" is never mistaken for a reading. */
typedef float (*AowlNu_F_P)(void*, void*);
static float aowl_nu_call_f_p(void* fn, void* self, float defVal) {
    if (!fn || !self) return defVal;
    return ((AowlNu_F_P)fn)(self, NULL);
}
/* INSTANCE, (bool, bool) -> void. `Toggle::Set(value, sendCallback)`.
 * sendCallback=1 is a REAL press: it runs the game's own onValueChanged and
 * the ToggleGroup's exclusivity, which is exactly what a proof of selection
 * must exercise -- setting m_IsOn raw proves nothing about the screen. */
typedef void (*AowlNu_V_PBB)(void*, unsigned char, unsigned char, void*);
static void aowl_nu_call_v_pbb(void* fn, void* self, int32_t a0, int32_t a1) {
    if (!fn || !self) return;
    ((AowlNu_V_PBB)fn)(self, (unsigned char)(a0 ? 1 : 0),
                       (unsigned char)(a1 ? 1 : 0), NULL);
}
/* The generic shape. A NULL MethodInfo* is REFUSED rather than passed: the
 * shared body dereferences it at +0x38, so a NULL there is an immediate access
 * violation with nothing learned. */
static void* aowl_nu_call_generic0(void* fn, void* self, void* mi) {
    if (!fn || !self || !mi) return NULL;
    return ((AowlNu_P_P)fn)(self, mi);
}

/* ------------------------------------------------------------------ *
 * 3. Vector2 / Rect marshalling
 *
 * File-scope buffers, allocated ONCE. The `_Injected` entry points take a
 * pointer, so this is the entire struct ABI story -- there is no by-value
 * shape to get wrong, in either direction.
 *
 * NOT re-entrant, and not thread-safe: Unity main thread only, one operation
 * at a time. Both callers (`nativeui.nim`) hold these only across a single
 * call.
 * ------------------------------------------------------------------ */

static float g_nu_v2in[2];      /* what we pass to a setter   */
static float g_nu_v2out[2];     /* what a getter wrote back   */
static float g_nu_rect[4];      /* x, y, width, height        */

static void  aowl_nu_v2in_set(float x, float y) { g_nu_v2in[0]=x; g_nu_v2in[1]=y; }
static void* aowl_nu_v2in_ptr(void)  { return (void*)g_nu_v2in;  }
static void* aowl_nu_v2out_ptr(void) { g_nu_v2out[0]=0.0f; g_nu_v2out[1]=0.0f;
                                       return (void*)g_nu_v2out; }
static float aowl_nu_v2out_x(void)   { return g_nu_v2out[0]; }
static float aowl_nu_v2out_y(void)   { return g_nu_v2out[1]; }
static void* aowl_nu_rect_ptr(void)  { g_nu_rect[0]=0.0f; g_nu_rect[1]=0.0f;
                                       g_nu_rect[2]=0.0f; g_nu_rect[3]=0.0f;
                                       return (void*)g_nu_rect; }
/* A Color (4 floats, 16 bytes). Win64 passes a 16-byte struct BY REFERENCE, so
 * `set_color(Color)` reads it through RDX -- which is not an inference, it is
 * the first instruction of the method (`movups xmm2,[rdx]`). Same file-scope,
 * allocate-once discipline as the Vector2 buffers above. */
static float g_nu_c4in[4];
static void  aowl_nu_c4in_set(float r, float g, float b, float a) {
    g_nu_c4in[0]=r; g_nu_c4in[1]=g; g_nu_c4in[2]=b; g_nu_c4in[3]=a;
}
static void* aowl_nu_c4in_ptr(void) { return (void*)g_nu_c4in; }

/* A Vector3 (12 bytes) out-buffer for the three `_Injected` getters the colour
 * widget's pointer mapping uses: `Input::get_mousePosition_Injected`,
 * `Transform::get_position_Injected`, `Transform::get_lossyScale_Injected`.
 * Zeroed on hand-out for the same reason `aowl_nu_v2out_ptr` is: a getter that
 * does not write leaves the PREVIOUS reading in place, and a stale pointer
 * position that happens to be plausible is worse than no reading at all.
 * Same not-re-entrant, main-thread-only, one-call-at-a-time contract as the
 * Vector2 buffers above. */
static float g_nu_v3out[3];
static void* aowl_nu_v3out_ptr(void) { g_nu_v3out[0]=0.0f; g_nu_v3out[1]=0.0f;
                                       g_nu_v3out[2]=0.0f;
                                       return (void*)g_nu_v3out; }
static float aowl_nu_v3out_x(void) { return g_nu_v3out[0]; }
static float aowl_nu_v3out_y(void) { return g_nu_v3out[1]; }
static float aowl_nu_v3out_z(void) { return g_nu_v3out[2]; }

static float aowl_nu_rect_x(void) { return g_nu_rect[0]; }
static float aowl_nu_rect_y(void) { return g_nu_rect[1]; }
static float aowl_nu_rect_w(void) { return g_nu_rect[2]; }
static float aowl_nu_rect_h(void) { return g_nu_rect[3]; }

/* Pure arithmetic, no game state: is (px,py) inside the rect a
 * `get_rect_Injected` just produced, given the element's world-space origin?
 * Split out precisely so it is testable offline -- see tests/nativeui. */
static int32_t aowl_nu_rect_contains(float rx, float ry, float rw, float rh,
                                     float px, float py) {
    if (rw <= 0.0f || rh <= 0.0f) return 0;   /* a zero-area rect contains nothing */
    if (px < rx || px > rx + rw) return 0;
    if (py < ry || py > ry + rh) return 0;
    return 1;
}

/* A rect is "renderable" only if it has real area and finite, sane numbers.
 * The zero-area case is the exact failure the invoke2 ladder hit, so it is a
 * named predicate rather than an inline `> 0` somewhere. NaN fails every
 * comparison, so `!(w > MIN)` catches it where `w <= MIN` would not. */
#define AOWL_NU_MIN_EXTENT 0.5f
#define AOWL_NU_MAX_EXTENT 16384.0f
static int32_t aowl_nu_rect_renderable(float w, float h) {
    if (!(w > AOWL_NU_MIN_EXTENT) || !(h > AOWL_NU_MIN_EXTENT)) return 0;
    if (!(w < AOWL_NU_MAX_EXTENT) || !(h < AOWL_NU_MAX_EXTENT)) return 0;
    return 1;
}

/* ------------------------------------------------------------------ *
 * 4. The component-kind registry
 *
 * The generalisation of invoke2's single hardcoded RectTransform slot. Adding
 * a type is a row here plus a reference instance -- not another disassembly
 * session. See the header comment for how each slot was found and attributed,
 * and `tools/addcompslots.py` to reproduce it.
 * ------------------------------------------------------------------ */

#define AOWL_NU_KIND_RECTTRANSFORM 0
#define AOWL_NU_KIND_TMPTEXT       1
#define AOWL_NU_KIND_IMAGE         2
#define AOWL_NU_KIND_BUTTON        3
#define AOWL_NU_KIND_CANVAS        4
#define AOWL_NU_MAX_KINDS          5

/* Per-kind verification state. Four outcomes, and "refused" is not a synonym
 * for "failed": UNKNOWN means we have not looked yet. */
#define AOWL_NU_SLOT_UNKNOWN   0
#define AOWL_NU_SLOT_VERIFIED  1   /* produced a component of the right class */
#define AOWL_NU_SLOT_POISONED  2   /* produced the WRONG class -- never again */
#define AOWL_NU_SLOT_NOREF     3   /* no reference instance -- INCONCLUSIVE   */
#define AOWL_NU_SLOT_ATTESTED  4   /* got != the live donor, but the slot's T
                                    * is OFFLINE-PROVEN (its static token decodes
                                    * to AddComponent<this-T>), so the DONOR is
                                    * the suspect, not the slot. Proceed, loudly. */

typedef struct AowlNuKind {
    const char* type;       /* for the log only; never used to resolve      */
    uint32_t    slotRva;    /* .data slot holding MethodInfo* AddComponent<T> */
    int32_t     attested;   /* 1 if the slot's static token was OFFLINE-resolved
                             * to AddComponent<`type`>; see the token comment.  */
    const char* evidence;   /* which call sites attributed it, from addcompslots */
} AowlNuKind;

/* The `attested` column is PROVEN, not asserted. Reproduce with:
 *   python tools/addcompslots.py <GameAssembly.dll> <global-metadata.dec.dat> \
 *       --slottype 0x6E19580 --slottype 0x6D50040 \
 *       --slottype 0x6D50070 --slottype 0x6D50038
 * which reads each slot's STATIC .data token, decodes kind/index the same way
 * the runtime resolver 0x5251C0 does, and names T from methodSpecs. Measured
 * 2026-08-28: 0x6E19580->AddComponent<RectTransform> (token 0xC0080485),
 * 0x6D50040->AddComponent<TextMeshProUGUI> (0xC00804F3), 0x6D50070->
 * AddComponent<UI.Image> (0xC008040B), 0x6D50038->AddComponent<UI.Button>
 * (0xC0080391). Each token decodes to a DISTINCT, correct T -- that is the
 * falsifiability: a swapped RVA would name a different type. This is why a
 * klass mismatch against a mistyped live donor is downgraded to ATTESTED, not
 * treated as a poisoned slot. */
static const AowlNuKind aowl_nu_kinds[AOWL_NU_MAX_KINDS] = {
    { "UnityEngine.RectTransform", 0x6E19580u, 1,
      "8 sites: TMP_DefaultControls::CreateUIElementRoot/CreateUIObject/"
      "CreateButton, TextMeshProUGUI::Awake, TMP_Dropdown::CreateBlocker, "
      "UI.Dropdown::CreateBlocker. Static token 0xC0080485 -> "
      "AddComponent<RectTransform>." },
    { "TMPro.TextMeshProUGUI", 0x6D50040u, 1,
      "6 sites: TMP_DefaultControls::CreateText (whose ONLY AddComponent is "
      "this one), CreateButton, CreateInputField x2, CreateDropdown x2. Static "
      "token 0xC00804F3 -> AddComponent<TextMeshProUGUI>." },
    { "UnityEngine.UI.Image", 0x6D50070u, 1,
      "12 sites: CreateScrollbar x2 (background + handle), CreateButton, "
      "CreateInputField, CreateDropdown x4. Static token 0xC008040B -> "
      "AddComponent<UI.Image>. Brings CanvasRenderer via [RequireComponent]." },
    { "UnityEngine.UI.Button", 0x6D50038u, 1,
      "3 sites: TMP_DefaultControls::CreateButton, TMP_Dropdown::CreateBlocker, "
      "UI.Dropdown::CreateBlocker. Static token 0xC0080391 -> "
      "AddComponent<UI.Button>." },
    /* THE ONE KIND THAT MUST WORK WITH NO LIVE DONOR. Every other row is used
     * in a scene that already contains an instance of its type, so
     * `nuRegisterReference` can supply a reference klass and the verdict is
     * VERIFIED. This row exists precisely for the case where the raid contains
     * NO Canvas at all -- so there is nothing to register, `refKlass` is NULL,
     * and `aowl_nu_verdict` returns ATTESTED on the strength of the offline
     * token proof alone. That is why `attested` being genuinely PROVEN matters
     * more here than anywhere else in this table, and why the readback in
     * natesp (get_renderMode + activeInHierarchy + a rect >= the minimum) is
     * the gate rather than the klass comparison.
     *
     * Reproduce:
     *   python tools/addcompslots.py <GameAssembly.dll> <metadata.dec.dat> \
     *       --slottype 0x6D586F8
     *   -> slot 0x6D586F8  static-token=0xC0080397  kind=6  index=0x401CB
     *      -> AddComponent<UnityEngine.Canvas>
     * The neighbouring slots decode to DISTINCT types in the same run
     * (0x6D586E8 -> UI.CanvasScaler, 0x6D58700 -> UI.GraphicRaycaster), which
     * is the falsifiability: an off-by-one RVA names a different T. */
    { "UnityEngine.Canvas", 0x6D586F8u, 1,
      "11 sites incl. GPUGraphData::UpdateUI. Static token 0xC0080397 -> "
      "AddComponent<UnityEngine.Canvas>. Its two neighbours decode to "
      "CanvasScaler (0x6D586E8) and GraphicRaycaster (0x6D58700), neither of "
      "which natesp attaches." },
};

/* Runtime state, one row per kind. */
static int32_t g_nu_slot_state[AOWL_NU_MAX_KINDS];
static void*   g_nu_ref_klass[AOWL_NU_MAX_KINDS];   /* from a LIVE instance   */
static void*   g_nu_got_klass[AOWL_NU_MAX_KINDS];   /* what a slot produced   */

static const char* aowl_nu_kind_name(int32_t k) {
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return "";
    return aowl_nu_kinds[k].type;
}
static const char* aowl_nu_kind_evidence(int32_t k) {
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return "";
    return aowl_nu_kinds[k].evidence;
}
static uint32_t aowl_nu_kind_slot_rva(int32_t k) {
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return 0u;
    return aowl_nu_kinds[k].slotRva;
}
static int32_t aowl_nu_kind_attested(int32_t k) {
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return 0;
    return aowl_nu_kinds[k].attested;
}
static int32_t aowl_nu_kind_count(void) { return AOWL_NU_MAX_KINDS; }
static int32_t aowl_nu_slot_state(int32_t k) {
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return AOWL_NU_SLOT_POISONED;
    return g_nu_slot_state[k];
}
static void* aowl_nu_ref_klass(int32_t k) {
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return NULL;
    return g_nu_ref_klass[k];
}
static void* aowl_nu_got_klass(int32_t k) {
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return NULL;
    return g_nu_got_klass[k];
}

/* The .data qword at `rva`, or NULL.
 *
 * Range-checked into `.data` (0x6B61000..0x737BD74 on this build) so a typo
 * cannot read code and hand back something that looks like a pointer, and
 * VirtualQuery-guarded like every other raw read this host does.
 *
 * A NULL read is LAZY-NOT-YET, never an error: IL2CPP fills these the first
 * time the owning method runs, so before any TMP default control has been
 * built the slot is legitimately empty. It is never a reason to fall back to a
 * NULL MethodInfo. */
static void* aowl_nu_data_ptr(uint32_t rva) {
    HMODULE ga;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (rva < 0x6B61000u || rva >= 0x737BD74u) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    p = (unsigned char*)ga + rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return NULL;
    return *(void**)p;
}
static void* aowl_nu_kind_mi(int32_t k) {
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return NULL;
    return aowl_nu_data_ptr(aowl_nu_kinds[k].slotRva);
}

/* ------------------------------------------------------------------ *
 * 4b. WARM A COLD METADATA-USAGE SLOT  (Route 1: force the resolver)
 *
 * A `.data` AddComponent<T> slot is filled LAZILY: until the owning method
 * (TMP_DefaultControls::CreateText for TextMeshProUGUI) has run this session,
 * the slot holds not a MethodInfo* but an ENCODED metadata-usage TOKEN. Passing
 * that token as `const MethodInfo*` faults the shared generic body at +0x38.
 *
 * The runtime resolves such a slot with a single codegen helper,
 * `il2cpp_codegen_initialize_runtime_metadata(uintptr_t* slot)` @0x5251C0, that
 * the game calls at CreateText's own prologue. It reads the slot, and -- if the
 * low bit is set (the "unresolved token" marker; a real, aligned MethodInfo*
 * has bit0 == 0) -- decodes `kind = token>>29`, `index = (token>>1)&0x0FFFFFFF`,
 * resolves it, writes the pointer back IN PLACE, and returns it. Calling it with
 * `&slot` warms exactly one slot as a pure side effect, with no UI, no method
 * body, and -- since it is not an il2cpp_* export -- no token gate.
 *
 * The runtime's OWN discriminator is bit0. We additionally require the value to
 * fit in 32 bits (an encoded token does; a heap MethodInfo* does not) before
 * feeding it to the resolver, and -- because a token is genuinely all we have to
 * go on -- we re-read and re-validate the slot AFTER the call. The §9b guard in
 * aowl_nu_slot_judge / nuAdd is UNCHANGED and still refuses a non-pointer. */

/* The measured token layout, exported for the falsifiable unit test. */
static int32_t  aowl_nu_token_kind(uint32_t tok)  { return (int32_t)(tok >> 29); }
static uint32_t aowl_nu_token_index(uint32_t tok) { return (tok >> 1) & 0x0FFFFFFFu; }

/* Does `v` have the shape of an UNRESOLVED usage token (as opposed to a real
 * MethodInfo*)? bit0 set is the runtime's own test; the 32-bit fit rejects a
 * heap pointer that merely happens to be odd, and a random gated value (which
 * is a full 64-bit number). */
static int32_t aowl_nu_is_cold_token(uintptr_t v) {
    if (v == 0) return 0;                 /* NULL is LAZY-NOT-YET, not a token */
    if ((v & 1u) == 0) return 0;          /* aligned -> already a pointer      */
    if ((v >> 32) != 0) return 0;         /* real MethodInfo* is a heap ptr    */
    return 1;
}

typedef void* (*AowlNuMetaInit)(void* /* uintptr_t* slot */);

/* Warm kind `k`'s AddComponent<T> slot if it is cold, and return the resulting
 * mi (or NULL). MUST be called from inside the proof's single SEH region: it
 * calls into game code, which can fault, and there is exactly one guard.
 *
 * Returns:
 *   the resolved MethodInfo*      -- slot was warm, or we warmed it
 *   NULL                          -- unresolvable (still cold / null / refused)
 * The caller re-reads + VirtualQuery-guards the slot before using it; this
 * function never itself decides a value is safe to call. */
static void* aowl_nu_warm_slot(int32_t k, void* metaInitFn) {
    HMODULE ga;
    uint32_t rva;
    void* slotAddr;
    uintptr_t v;
    MEMORY_BASIC_INFORMATION mbi;
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return NULL;
    if (!metaInitFn) return NULL;
    rva = aowl_nu_kinds[k].slotRva;
    if (rva < 0x6B61000u || rva >= 0x737BD74u) return NULL;   /* .data range   */
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    slotAddr = (unsigned char*)ga + rva;
    /* The slot must be committed AND writable -- the resolver stores back. */
    if (VirtualQuery(slotAddr, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return NULL;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    v = *(uintptr_t*)slotAddr;
    if ((v & 1u) == 0) return (void*)v;   /* already resolved (or NULL->NULL) */
    if (!aowl_nu_is_cold_token(v)) return NULL;   /* odd garbage, not a token */
    /* Cold token -> resolve in place. Returns the pointer in RAX and also
     * stores it into the slot. */
    ((AowlNuMetaInit)metaInitFn)(slotAddr);
    /* Trust the SLOT, not the return: re-read what the resolver wrote. */
    v = *(uintptr_t*)slotAddr;
    if ((v & 1u) != 0) return NULL;       /* still not a pointer -> refuse    */
    return (void*)v;
}

/* An object's Il2CppClass*: the first qword of the object header.
 *
 * This is EXACTLY what `il2cpp_object_get_class` is on this build -- three
 * instructions, `mov rax,[rcx]; ret`, ungated and validating nothing. Doing it
 * inline rather than through the export costs nothing and removes any question
 * of which side of the token gate we are on. The VirtualQuery is ours, since
 * the export would not have done one either. */
static void* aowl_nu_klass_of(void* obj) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!obj) return NULL;
    if (VirtualQuery(obj, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return NULL;
    return *(void**)obj;
}

/* Register the reference instance for a kind: a LIVE object of that class,
 * reached by walking from something already validated.
 *
 * Returns 1 if a usable class pointer was taken. Refuses to overwrite one
 * already recorded -- a second, different reference for the same kind means
 * one of the two walks is wrong, and silently taking the newer one would make
 * the check depend on call order. */
static int32_t aowl_nu_ref_set(int32_t k, void* liveInstance) {
    void* kl;
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return 0;
    if (g_nu_ref_klass[k]) return (g_nu_ref_klass[k] == aowl_nu_klass_of(liveInstance)) ? 1 : 0;
    kl = aowl_nu_klass_of(liveInstance);
    if (!kl) return 0;
    g_nu_ref_klass[k] = kl;
    return 1;
}

/* Record the verdict after a component came back. `got` is the component the
 * slot produced. Sets and returns the slot state.
 *
 * This is the whole falsifiable check. Its failing input is concrete: a slot
 * attributed to the wrong T returns a component whose header klass differs
 * from the reference, and the kind is poisoned for the rest of the session. */
/* The verdict, as pure arithmetic over three inputs -- extracted so BOTH the
 * attested and the unattested branch are exercised offline (aowl_nu_slot_judge
 * only ever sees attested==1 kinds on this build, which would leave the strict
 * poison path untestable -- a check that cannot fail). `gotKlass` is the
 * produced component's class (NULL if unreadable); `refKlass` the live donor's
 * (NULL if none registered); `attested` the offline token->T proof. */
static int32_t aowl_nu_verdict(int32_t attested, void* refKlass, void* gotKlass) {
    if (!gotKlass)                       return AOWL_NU_SLOT_POISONED;
    if (refKlass && gotKlass == refKlass) return AOWL_NU_SLOT_VERIFIED;
    if (attested)                        return AOWL_NU_SLOT_ATTESTED;
    if (!refKlass)                       return AOWL_NU_SLOT_NOREF;
    return AOWL_NU_SLOT_POISONED;
}

static int32_t aowl_nu_slot_judge(int32_t k, void* got) {
    void* gk;
    if (k < 0 || k >= AOWL_NU_MAX_KINDS) return AOWL_NU_SLOT_POISONED;
    gk = aowl_nu_klass_of(got);
    g_nu_got_klass[k] = gk;
    g_nu_slot_state[k] =
        aowl_nu_verdict(aowl_nu_kinds[k].attested, g_nu_ref_klass[k], gk);
    return g_nu_slot_state[k];
}

/* ------------------------------------------------------------------ *
 * 5. Interned managed strings -- rule 7, no per-frame allocation
 *
 * `il2cpp_string_new` allocates on the managed heap. A UI layer that called it
 * once per frame per label would be a garbage generator on the Unity thread.
 * Every string this layer passes to the game goes through here and is
 * allocated at most ONCE per distinct text, for the life of the process.
 *
 * The table is capped and NEVER evicts: an eviction would hand a stale managed
 * pointer to a caller holding one, and a fixed cap turns "too many labels"
 * into a clean refusal instead of unbounded growth.
 * ------------------------------------------------------------------ */

/* RAISED FROM 64 on 2026-09-01, because 64 was measured to be too small and the
 * failure it produced was a PARTIALLY BLANK SETTINGS PAGE:
 *
 *   nativeui: create("aowl-pfx-chroma"): no managed string (intern table
 *             full=1, used 64)
 *   nuikit: label("aowl-pfx-chroma") REFUSED
 *   postfx rows VERDICT FAIL: 37 of 40 element(s) are drawable ... 3 read back
 *             EMPTY text
 *
 * The PostFX page alone declares 43 settings, each needing at least a name and
 * a caption; the mod-loading screen adds ~18 more; the mods tab will add one
 * per mod. 64 was never going to hold them, and the exhaustion point moves with
 * whatever happened to be built first -- so the same page renders differently
 * depending on what the player opened before it. That is the worst kind of
 * bug: reproducible only in order.
 *
 * The table still NEVER EVICTS, which is the property that matters: an eviction
 * would hand a stale managed pointer to a caller still holding one. Raising a
 * never-evicting cap is safe; the only cost is static memory, and 512 entries
 * is 512 * (128 + 8) = ~70 KB. That is nothing against a 4 MB host, and it buys
 * roughly eight times the headroom.
 *
 * The cap is still FINITE on purpose: a fixed ceiling turns "too many labels"
 * into a clean, named refusal instead of unbounded growth on the Unity thread.
 */
#define AOWL_NU_MAX_INTERN     512
/* WAS 128, RAISED TO 512 on 2026-09-04, and the measurement that forced it is
 * worth keeping: the first live run of the DLSS tooltips reported "5 asked, 1
 * call(s) made, 1 READ BACK". Four of the five tooltip bodies are 156, 181,
 * 223 and 270 characters long and the fifth is 108. `aowl_nu_intern` returned
 * NULL for every string >= AOWL_NU_MAX_INTERN_LEN, so four templates were
 * never built -- and the caller's diagnosis blamed `il2cpp_object_new` or the
 * fieldref gate, neither of which had been anywhere near it. The length
 * refusal was SILENT and indistinguishable from a full table and from a failed
 * `il2cpp_string_new`; it is counted separately now (below) for that reason.
 *
 * Cost of the raise: the table is a flat array, so this is
 * 512 * (512 + 8) = 266,240 bytes of .bss in the host DLL. That is the whole
 * price, it is paid once, and it buys a cap no caption or tooltip in this
 * codebase can reach by accident. */
#define AOWL_NU_MAX_INTERN_LEN 512

typedef struct AowlNuIntern {
    char  text[AOWL_NU_MAX_INTERN_LEN];
    void* str;
} AowlNuIntern;

static AowlNuIntern g_nu_intern[AOWL_NU_MAX_INTERN];
static int32_t      g_nu_intern_n = 0;
static int32_t      g_nu_intern_full = 0;
/* THREE DIFFERENT REASONS `aowl_nu_intern` RETURNS NULL, counted apart:
 * the string is longer than the cap, the table is full, or il2cpp_string_new
 * itself refused. They used to be one silent NULL. */
static int32_t      g_nu_intern_toolong = 0;
static int32_t      g_nu_intern_newfail = 0;
static int32_t      g_nu_intern_maxseen = 0;

typedef void* (*AowlNuStringNew)(const char*);
static AowlNuStringNew g_nu_string_new = 0;
static int             g_nu_exports_done = 0;

/* `il2cpp_string_new` is NOT one of the 38 token-gated exports -- the version
 * brand has used it on the Unity thread since long before the gates were
 * understood. It is resolved by name here for that reason and no other. */
static void aowl_nu_exports_init(void) {
    HMODULE ga;
    if (g_nu_exports_done) return;
    g_nu_exports_done = 1;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return;
    g_nu_string_new = (AowlNuStringNew)(void*)
        GetProcAddress(ga, "il2cpp_string_new");
}

static void* aowl_nu_intern(const char* s) {
    int32_t i;
    size_t n;
    if (!s) return NULL;
    n = strlen(s);
    if ((int32_t)n > g_nu_intern_maxseen) g_nu_intern_maxseen = (int32_t)n;
    if (n >= AOWL_NU_MAX_INTERN_LEN) {
        g_nu_intern_toolong++;
        return NULL;
    }
    for (i = 0; i < g_nu_intern_n; i++)                 /* capped by n <= 64 */
        if (strcmp(g_nu_intern[i].text, s) == 0)
            return g_nu_intern[i].str;
    if (g_nu_intern_n >= AOWL_NU_MAX_INTERN) {
        g_nu_intern_full = 1;
        return NULL;
    }
    aowl_nu_exports_init();
    if (!g_nu_string_new) { g_nu_intern_newfail++; return NULL; }
    {
        void* v = g_nu_string_new(s);
        if (!v) { g_nu_intern_newfail++; return NULL; }
        memcpy(g_nu_intern[g_nu_intern_n].text, s, n + 1);
        g_nu_intern[g_nu_intern_n].str = v;
        g_nu_intern_n++;
        return v;
    }
}
static int32_t aowl_nu_intern_count(void) { return g_nu_intern_n; }
static int32_t aowl_nu_intern_toolong(void) { return g_nu_intern_toolong; }
static int32_t aowl_nu_intern_newfail(void) { return g_nu_intern_newfail; }
static int32_t aowl_nu_intern_maxseen(void) { return g_nu_intern_maxseen; }
static int32_t aowl_nu_intern_maxlen(void) { return AOWL_NU_MAX_INTERN_LEN; }
static int32_t aowl_nu_intern_overflowed(void) { return g_nu_intern_full; }

/* ------------------------------------------------------------------ *
 * 6. Ownership -- rule: creating UI that cannot be torn down is a leak
 *
 * Every GameObject this layer creates or clones is recorded. `destroy_all`
 * walks the list, asks Unity whether each is still alive (`op_Implicit`, which
 * is not the same question as "is the pointer non-null" -- a destroyed Unity
 * object keeps a live managed shell), destroys the survivors, and clears the
 * list. Capped, so a runaway caller refuses rather than overruns.
 * ------------------------------------------------------------------ */

#define AOWL_NU_MAX_OWNED 64

static void*   g_nu_owned[AOWL_NU_MAX_OWNED];
static int32_t g_nu_owned_n = 0;

static int32_t aowl_nu_own(void* go) {
    if (!go) return 0;
    if (g_nu_owned_n >= AOWL_NU_MAX_OWNED) return 0;
    g_nu_owned[g_nu_owned_n++] = go;
    return 1;
}
static int32_t aowl_nu_owned_count(void) { return g_nu_owned_n; }
/* Bounded by BOTH the live count and the array size. The count alone would be
 * enough if `g_nu_owned_n` could never be wrong -- which is exactly the kind of
 * assumption this host does not get to make about its own state after a
 * caught fault. gcc's -Warray-bounds flagged it, and it was right to. */
static void*   aowl_nu_owned_at(int32_t i) {
    if (i < 0 || i >= g_nu_owned_n || i >= AOWL_NU_MAX_OWNED) return NULL;
    return g_nu_owned[i];
}
static void aowl_nu_owned_clear(void) {
    int32_t i;
    for (i = 0; i < AOWL_NU_MAX_OWNED; i++) g_nu_owned[i] = NULL;
    g_nu_owned_n = 0;
}
/* Drop one entry without destroying it -- for a caller that handed ownership
 * of a subtree to Unity by parenting it under something it does not own. */
static void aowl_nu_disown(void* go) {
    int32_t i, j = 0;
    for (i = 0; i < g_nu_owned_n; i++)
        if (g_nu_owned[i] != go) g_nu_owned[j++] = g_nu_owned[i];
    for (i = j; i < g_nu_owned_n; i++) g_nu_owned[i] = NULL;
    g_nu_owned_n = j;
}

/* ------------------------------------------------------------------ *
 * 7. Object allocation
 *
 * `il2cpp_object_new` is ungated (measured, docs/IL2CPP_EXPORTS.md) and was
 * proven live by the invoke2 ladder: the allocation's header klass matched the
 * class requested. The class pointer comes from a LIVE GameObject's header,
 * not from any metadata lookup -- holding one instance of a type makes its
 * class pointer free.
 * ------------------------------------------------------------------ */

typedef void* (*AowlNuObjectNew)(void*);
static AowlNuObjectNew g_nu_object_new = 0;

static void* aowl_nu_object_new(void* klass) {
    HMODULE ga;
    if (!klass) return NULL;
    if (!g_nu_object_new) {
        ga = GetModuleHandleA("GameAssembly.dll");
        if (!ga) return NULL;
        g_nu_object_new = (AowlNuObjectNew)(void*)
            GetProcAddress(ga, "il2cpp_object_new");
        if (!g_nu_object_new) return NULL;
    }
    return g_nu_object_new(klass);
}

/* ------------------------------------------------------------------------
 * Reference-field read/write, for wiring a FROM-SCRATCH component's
 * dependencies (font asset, material) out of a LIVE donor BEFORE the
 * component's Awake/OnEnable runs and dereferences them.
 *
 * This is a raw pointer-sized field store, and it is NOT a blind write:
 *   * the source read is VirtualQuery-gated (aowl_is_readable);
 *   * the destination store is gated on the slot lying inside a COMMITTED,
 *     WRITABLE region -- aowl_nu_is_writable below rejects READONLY, guard
 *     and no-access pages, so a bad offset can never fault or clobber code.
 * No GC write barrier is issued: this build's IL2CPP uses a conservative
 * collector that scans without one, and both objects are independently kept
 * alive (the donor by the live label it belongs to, the target by
 * aowl_nu_own), so a plain store cannot create a dangling reference here.
 * ------------------------------------------------------------------------ */
/* Self-contained region check (does NOT depend on the shim, so the header
 * still compiles alone for the offline test). `needWrite` requires a
 * RW/WRITECOPY protection; otherwise READONLY is accepted too. */
static int32_t aowl_nu_region_ok(void* p, int32_t size, int32_t needWrite) {
    MEMORY_BASIC_INFORMATION mbi;
    DWORD readMask, writeMask;
    if (!p || size <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    writeMask = PAGE_READWRITE | PAGE_WRITECOPY |
                PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    readMask  = writeMask | PAGE_READONLY | PAGE_EXECUTE_READ;
    if (!(mbi.Protect & (needWrite ? writeMask : readMask))) return 0;
    {
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)p + (uintptr_t)size;
        if (need < (uintptr_t)p) return 0;   /* overflow */
        return need <= end ? 1 : 0;
    }
}
static int32_t aowl_nu_is_writable(void* p, int32_t size) {
    return aowl_nu_region_ok(p, size, 1);
}

static void* aowl_nu_get_ref(void* obj, int32_t off) {
    void* v;
    if (!obj || off < 0) return NULL;
    if (!aowl_nu_region_ok((char*)obj + off, (int32_t)sizeof(void*), 0))
        return NULL;
    v = NULL;
    memcpy(&v, (const char*)obj + off, sizeof(void*));
    return v;
}

static int32_t aowl_nu_set_ref(void* obj, int32_t off, void* val) {
    if (!obj || off < 0) return 0;
    if (!aowl_nu_is_writable((char*)obj + off, (int32_t)sizeof(void*))) return 0;
    memcpy((char*)obj + off, &val, sizeof(void*));
    return 1;
}

/* Read a float field RAW, VirtualQuery-guarded like every other hop. Used ONLY
 * to read a Graphic's m_Color BACK after calling set_color -- i.e. to check the
 * finished state through a path that is NOT the setter we are testing. `ok` is
 * an out-flag because 0.0f is a legitimate channel value and must not double as
 * "could not read": that conflation is exactly the check-that-cannot-fail this
 * repo keeps paying for. */
static float aowl_nu_get_f32(void* obj, int32_t off, int32_t* ok) {
    float v = 0.0f;
    if (ok) *ok = 0;
    if (!obj || off < 0) return 0.0f;
    if (!aowl_nu_region_ok((char*)obj + off, (int32_t)sizeof(float), 0))
        return 0.0f;
    memcpy(&v, (const char*)obj + off, sizeof(float));
    if (ok) *ok = 1;
    return v;
}

/* ------------------------------------------------------------------------
 * 8. THE DROPDOWN PATH -- a managed String[], the interface proof, and
 *    virtual dispatch on Show.
 *
 * Everything here exists to make ONE call safe:
 *   BaseDropDownBox::Show(IEnumerable<string> values, Func<int,bool> validator)
 *
 * `Show` does not type-test its argument with `isinst`; it INTERFACE-DISPATCHES
 * on it (RVA 0x52D0, disassembled with `il2cpp_resolve.py disasm 0x52d0
 * --len 200`). That routine walks the receiver's `interfaceOffsets` looking for
 * the interface class, and a MISS falls through to a slow path we do not
 * control. A managed throw is not catchable by `aowl_p_p_seh`, so "String[]
 * implements IEnumerable<string>" must not be assumed -- and it cannot be
 * settled offline either, because IL2CPP builds array classes at RUNTIME
 * (their `interfaceOffsets` are not in the metadata file at all, and every
 * `Il2CppGenericClass.cached_class` on disk is null).
 *
 * So it is settled AT RUNTIME, by asking the exact question the dispatch stub
 * asks, of the exact table the dispatch stub reads, BEFORE the call:
 * `aowl_nu_klass_has_iface(array, IEnumerable<string>)`. If the answer is no,
 * or if either klass cannot be read, nothing is called. That is a check that
 * CAN fail, which an offline assertion about il2cpp internals would not be.
 * ------------------------------------------------------------------------ */

/* `il2cpp_array_new(Il2CppClass* elementClass, uintptr_t length)`.
 * UNGATED -- MEASURED: it appears in `aowl_il2cpp_exports` in
 * abi/aowlspt_il2cpp_gates_data.h and NOT in `aowl_gate_rows`, so it takes no
 * trailing 32-byte token and cannot return MT19937-64 noise. */
typedef void* (*AowlNuArrayNew)(void*, uintptr_t);
static AowlNuArrayNew g_nu_array_new = 0;

static void* aowl_nu_array_new(void* elemKlass, int32_t n) {
    HMODULE ga;
    if (!elemKlass || n <= 0 || n > 64) return NULL;
    if (!g_nu_array_new) {
        ga = GetModuleHandleA("GameAssembly.dll");
        if (!ga) return NULL;
        g_nu_array_new = (AowlNuArrayNew)(void*)
            GetProcAddress(ga, "il2cpp_array_new");
        if (!g_nu_array_new) return NULL;
    }
    return g_nu_array_new(elemKlass, (uintptr_t)n);
}

/* The `System.String` Il2CppClass, taken from the OBJECT HEADER of a string
 * the runtime itself just made. No metadata lookup and no gated export:
 * holding one instance of a type makes its class pointer free (the same
 * reasoning as `aowl_nu_object_new`'s header comment). Cached;
 * `aowl_nu_intern` keeps the donor string alive. */
static void* g_nu_string_klass = 0;
static void* aowl_nu_string_klass(void) {
    void* s;
    void* k;
    if (g_nu_string_klass) return g_nu_string_klass;
    s = aowl_nu_intern("aowl");
    if (!s) return NULL;
    if (!aowl_nu_region_ok(s, (int32_t)sizeof(void*), 0)) return NULL;
    k = NULL;
    memcpy(&k, s, sizeof(void*));
    if (!k) return NULL;
    /* A klass pointer must at least address its own vtable base. */
    if (!aowl_nu_region_ok(k, AOWL_NU_KLASS_VTABLE_OFF, 0)) return NULL;
    g_nu_string_klass = k;
    return k;
}

/* Does `obj`'s class carry `iface` in the SAME interface-offset table the
 * game's own dispatch stub at 0x52D0 walks? Three outcomes, and the caller
 * must keep them apart: 1 = yes, 0 = no (the table was read and the interface
 * is not in it), -1 = INCONCLUSIVE (a pointer would not read; nothing was
 * decided). Bounded by AOWL_NU_MAX_IFACES as well as by the u16 count. */
static int32_t aowl_nu_klass_has_iface(void* obj, void* iface) {
    void* klass;
    void* tbl;
    uint16_t cnt;
    int32_t i;
    if (!obj || !iface) return -1;
    if (!aowl_nu_region_ok(obj, (int32_t)sizeof(void*), 0)) return -1;
    klass = NULL;
    memcpy(&klass, obj, sizeof(void*));
    if (!klass) return -1;
    if (!aowl_nu_region_ok((char*)klass + AOWL_NU_KLASS_IFOFFS_CNT,
                           (int32_t)sizeof(uint16_t), 0)) return -1;
    if (!aowl_nu_region_ok((char*)klass + AOWL_NU_KLASS_IFOFFS_PTR,
                           (int32_t)sizeof(void*), 0)) return -1;
    cnt = 0;
    memcpy(&cnt, (const char*)klass + AOWL_NU_KLASS_IFOFFS_CNT,
           sizeof(uint16_t));
    tbl = NULL;
    memcpy(&tbl, (const char*)klass + AOWL_NU_KLASS_IFOFFS_PTR, sizeof(void*));
    if (cnt == 0) return 0;
    if (cnt > AOWL_NU_MAX_IFACES) return -1;
    if (!tbl) return -1;
    if (!aowl_nu_region_ok(tbl, (int32_t)cnt * AOWL_NU_IFOFF_STRIDE, 0))
        return -1;
    for (i = 0; i < (int32_t)cnt; i++) {
        void* e = NULL;
        memcpy(&e, (const char*)tbl + (size_t)i * AOWL_NU_IFOFF_STRIDE,
               sizeof(void*));
        if (e == iface) return 1;
    }
    return 0;
}

/* `Il2CppClass* IEnumerable<string>` out of the metadata-usage slot the game's
 * own Show reads. NULL when the slot still holds its raw token, i.e. when the
 * game has not yet run Show even once -- which is a REFUSAL, never a guess. */
static void* aowl_nu_ienum_string_klass(void) {
    HMODULE ga;
    void* slot;
    void* k;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    slot = (void*)((char*)ga + AOWL_NU_IENUM_STRING_SLOT_RVA);
    if (!aowl_nu_region_ok(slot, (int32_t)sizeof(void*), 0)) return NULL;
    k = NULL;
    memcpy(&k, slot, sizeof(void*));
    if (!k) return NULL;
    if (!aowl_nu_region_ok(k, AOWL_NU_KLASS_VTABLE_OFF, 0)) return NULL;
    return k;
}

/* Build a managed String[] in two steps: allocate it, then fill one element at
 * a time. Both stores happen HERE, in C, over an array THIS LAYER allocated --
 * an array ELEMENT is not a field, so there is no offset for
 * `tools/fieldrefs.py` to type, and deliberately no Nim-visible raw-store
 * primitive is introduced by any of it.
 *
 * Each store is bounds-checked against the array's OWN `max_length` at +0x18
 * rather than against the caller's idea of the length, so a short allocation
 * refuses instead of writing past the object; and every element must read back
 * as a live managed String (its header must equal the String klass) before it
 * is stored.
 *
 * GC: this build's IL2CPP uses the conservative collector, which scans the
 * calling thread's stack and loaded modules' data segments. The array is live
 * in a local in the caller across the whole window, and each element is
 * additionally held by `aowl_nu_intern`'s static table. */
static void* aowl_nu_arr_new_string(int32_t n) {
    void* klass;
    void* arr;
    uint32_t len;
    if (n <= 0 || n > 64) return NULL;
    klass = aowl_nu_string_klass();
    if (!klass) return NULL;
    arr = aowl_nu_array_new(klass, n);
    if (!arr) return NULL;
    if (!aowl_nu_region_ok((char*)arr + AOWL_NU_ARR_LEN_OFF,
                           (int32_t)sizeof(uint32_t), 0)) return NULL;
    len = 0;
    memcpy(&len, (const char*)arr + AOWL_NU_ARR_LEN_OFF, sizeof(uint32_t));
    /* The array must be EXACTLY the length that was asked for. A shorter one
     * would let every later bounds check pass on a smaller object. */
    if (len != (uint32_t)n) return NULL;
    return arr;
}

static int32_t aowl_nu_arr_set_string(void* arr, int32_t i, const char* utf8) {
    void* klass;
    void* s;
    void* sk;
    uint32_t len;
    if (!arr || !utf8 || i < 0) return 0;
    klass = aowl_nu_string_klass();
    if (!klass) return 0;
    if (!aowl_nu_region_ok((char*)arr + AOWL_NU_ARR_LEN_OFF,
                           (int32_t)sizeof(uint32_t), 0)) return 0;
    len = 0;
    memcpy(&len, (const char*)arr + AOWL_NU_ARR_LEN_OFF, sizeof(uint32_t));
    /* Bounded by the array's OWN max_length, never by the caller's idea of
     * how long it is. */
    if ((uint32_t)i >= len) return 0;
    s = aowl_nu_intern(utf8);
    if (!s) return 0;
    if (!aowl_nu_region_ok(s, (int32_t)sizeof(void*), 0)) return 0;
    sk = NULL;
    memcpy(&sk, s, sizeof(void*));
    /* Not a System.String -- refuse rather than store something Show would
     * hand to a string cast. */
    if (sk != klass) return 0;
    if (!aowl_nu_is_writable((char*)arr + AOWL_NU_ARR_DATA_OFF +
                             (size_t)i * sizeof(void*),
                             (int32_t)sizeof(void*))) return 0;
    memcpy((char*)arr + AOWL_NU_ARR_DATA_OFF + (size_t)i * sizeof(void*),
           &s, sizeof(void*));
    return 1;
}

/* The receiver's own `vtable[slot]`: `fn` out, `mi` (the const MethodInfo* the
 * hidden trailing argument wants) out. Returns 1 only when BOTH read back out
 * of committed memory. */
static int32_t aowl_nu_vslot(void* obj, int32_t slot, void** fn, void** mi) {
    void* klass;
    char* e;
    if (fn) *fn = NULL;
    if (mi) *mi = NULL;
    if (!obj || !fn || !mi || slot < 0 || slot > 4095) return 0;
    if (!aowl_nu_region_ok(obj, (int32_t)sizeof(void*), 0)) return 0;
    klass = NULL;
    memcpy(&klass, obj, sizeof(void*));
    if (!klass) return 0;
    e = (char*)klass + AOWL_NU_KLASS_VTABLE_OFF + (size_t)slot * 16u;
    if (!aowl_nu_region_ok(e, 16, 0)) return 0;
    memcpy(fn, e, sizeof(void*));
    memcpy(mi, e + 8, sizeof(void*));
    return (*fn && *mi) ? 1 : 0;
}

/* Call an already-resolved `void (this, void*, void*, MethodInfo*)`. The
 * pointer is NOT taken from the target table by index: it came from
 * `aowl_nu_vslot`, and the caller has compared it against the three
 * byte-verified Show targets before getting here. */
/* (this, a0, a1, MethodInfo*) -> object. SetTooltip is non-generic and
 * non-virtual, so a NULL MethodInfo* is correct for it. */
typedef void* (*AowlNu_P_PPP)(void*, void*, void*, void*);
static void* aowl_nu_call_p_ppp(void* fn, void* self, void* a0, void* a1) {
    if (!fn || !self) return NULL;
    return ((AowlNu_P_PPP)fn)(self, a0, a1, NULL);
}

typedef void (*AowlNu_V_PPPP)(void*, void*, void*, void*);
static void aowl_nu_call_show(void* fn, void* self, void* values,
                              void* validator, void* mi) {
    if (!fn || !self) return;
    ((AowlNu_V_PPPP)fn)(self, values, validator, mi);
}

/* Read an int32 field RAW, VirtualQuery-guarded. Used ONLY for
 * `BaseDropDownBox.<CurrentIndex>k__BackingField` @0xE8 readbacks, where 0 is
 * a legitimate index and must not double as "could not read" -- hence the
 * out-flag, for the same reason `aowl_nu_get_f32` has one. */
static int32_t aowl_nu_get_i32(void* obj, int32_t off, int32_t* ok) {
    int32_t v = 0;
    if (ok) *ok = 0;
    if (!obj || off < 0) return 0;
    if (!aowl_nu_region_ok((char*)obj + off, (int32_t)sizeof(int32_t), 0))
        return 0;
    memcpy(&v, (const char*)obj + off, sizeof(int32_t));
    if (ok) *ok = 1;
    return v;
}

#endif /* AOWLSPT_NATIVEUI_H */

