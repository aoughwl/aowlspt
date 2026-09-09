/* aowlspt_nativepostfx.h -- the byte-verified call table for the POSTFX
 * subtab's NATIVE rows: the ones that drive the GAME'S OWN post-processing and
 * shading rather than a D3D pass of ours.
 *
 * ===========================================================================
 * WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
 * ===========================================================================
 *
 * `mods/graphics` composites our own shader over the back buffer. That is now
 * LEGACY and default OFF. Everything below instead reaches the pipeline the
 * game already runs: CameraManager's own appliers, PostFxSettingsController's
 * own Update path, and the Prism AO script that is already on the raid camera.
 *
 * There is NO detour in this file. Every row is CALLED, never patched, so the
 * double-detour hazard (the second bind overwrites the first's trampoline)
 * cannot arise here at all. The prologue verify is still mandatory and still
 * runs against the STARTUP SNAPSHOT (`aowlspt_prologue.h`), never against live
 * memory -- verifying against live memory reads another feature's trampoline
 * and self-rejects.
 *
 * ===========================================================================
 * PROVENANCE -- every number below was MEASURED, none was copied on trust
 * ===========================================================================
 *
 * Build 1.1.0.1.46777. Imagebase 0x180000000; runtime = GameAssemblyBase + RVA.
 * Instrument, from the repo root, with the System.String self-check
 * (`_stringLength@0x10`, `_firstChar@0x14`) PASSING before any number was
 * believed:
 *
 *     $g="D:\Games\Tarkov\GameAssembly.dll"; $m=".cache\global-metadata.dec.dat"
 *     python tools\il2cpp_resolve.py $g $m typemethods <Type>
 *     python tools\il2cpp_resolve.py $g $m disasm <RVA> --len N
 *     python tools\fldoff.py         $g $m fields <Type>
 *
 * Every row below was checked for all four of: the RVA, the 16 prologue bytes,
 * `sharedness == UNIQUE` (owners=1), and `section == il2cpp`. A SHARED RVA is
 * safe to CALL but the check is recorded anyway, because a row that later
 * gains a detour would need it and nobody would re-derive it then.
 *
 * `docs/NATIVE-POSTFX-MAP.md` is the map this table implements. THREE of its
 * claims did not survive measurement, and the corrections are load-bearing:
 *
 *   1. `ChangedShadowQuality` is **STATIC**, not an instance method on
 *      GraphicsSettingsController (map section 2.3 reads as instance). See
 *      row [10]. Passing a receiver in RCX would apply that pointer's low
 *      dword as the shadow quality -- a plausible number, not a crash.
 *   2. `SetSharpen`'s read-back is `CC_Sharpen.strength@0x38`, NOT
 *      `GradingPostFX._lumaSharpenStrength@0x90` (map section 3 step 5). See
 *      row [1].
 *   3. `SetSharpen` **THROWS A MANAGED EXCEPTION** when its target is null,
 *      rather than being a silent no-op. See row [1]; this one decides the
 *      shape of the caller.
 *
 * ===========================================================================
 * THE MANAGED-THROW HAZARD, which is why row [1] has a mandatory pre-check
 * ===========================================================================
 *
 * MEASURED `disasm 0x126BCF0 --len 0x50` -- SetSharpen is FOUR instructions:
 *
 *     48 83 EC 28              sub  rsp, 0x28
 *     48 8B 81 D0 00 00 00     mov  rax, [rcx + 0xD0]   ; _ccSharpen : CC_Sharpen
 *     48 85 C0                 test rax, rax
 *     74 0A                    je   0x126BD0A           ; --> throw
 *     F3 0F 11 48 38           movss [rax + 0x38], xmm1 ; CC_Sharpen.strength
 *     48 83 C4 28              add  rsp, 0x28
 *     C3                       ret
 *   0x126BD0A:
 *     E8 21 68 36 FF           call 0x5D2530            ; NullReference throw helper
 *     CC                       int3
 *
 * So a null `_ccSharpen` raises a MANAGED NullReferenceException. `aowl_p_p_seh`
 * is an SEH guard: it catches an access violation, NOT a managed throw. There
 * is therefore NO guard on our side that makes this call safe after the fact --
 * the only safe construction is to READ `CameraManager._ccSharpen@0xD0` and
 * refuse the call when it is null. `aowl_npf_call_set_sharpen` takes the
 * already-read target as an argument for exactly that reason: the null check
 * is not something the caller may forget, because the caller cannot express
 * the call without having done it.
 *
 * This is the OPPOSITE failure mode to `CameraManager::SetFov` @0x1268D20,
 * which `aowlspt_camera.h` records as a silent no-op on a null `<Camera>@0x70`.
 * Two appliers on the same class, two different behaviours on null; neither
 * may be assumed from the other.
 *
 * ===========================================================================
 * SLOT COUNTS, DERIVED FROM SIGNATURES -- never inferred from a name
 * ===========================================================================
 *
 * Each `arity` below is `parameterCount@34` of the method's
 * Il2CppMethodDefinition, and each `static` bit is `flags@28 & 0x0010`, both
 * read by `il2cpp_resolve.py`. The frame follows from those two facts plus the
 * hidden trailing `const MethodInfo*`:
 *
 *   instance, arity 0 -> RCX=this, RDX=MethodInfo*                    2 slots
 *   instance, arity 1 -> RCX=this, RDX/XMM1=arg, R8=MethodInfo*       3 slots
 *   static,   arity 0 -> RCX=MethodInfo*                              1 slot
 *   static,   arity 1 -> RCX=arg, RDX=MethodInfo*                     2 slots
 *
 * Nothing here is generic, so a NULL MethodInfo* is correct (the restriction
 * is on SHARED GENERIC code). It is passed EXPLICITLY in every wrapper rather
 * than left to whatever happens to be in the register.
 *
 * A float argument takes the XMM register matching its INTEGER slot index, so
 * `SetSharpen(float)` -- slot 1 -- passes in XMM1, not XMM0. Declaring the
 * wrapper's parameter as `float` lets the compiler place it, which is why the
 * typedefs below spell the real types instead of casting everything to
 * uint64_t.
 *
 * ===========================================================================
 * WHAT IS NOT IN THIS TABLE, AND WHY
 * ===========================================================================
 *
 * `QualityLevelPreset::Apply()` @0xC03890 (UNIQUE, il2cpp, prologue
 * `48 89 5C 24 08 57 48 83 EC 40 80 3D FC 64 4B 06`) is deliberately ABSENT.
 * MEASURED `disasm 0xBF5570 --len 0x1F0`: `ChangedShadowQuality` already calls
 * it as its only IL2CPP-owned call. A second caller here would apply the
 * preset twice per change -- the expensive half of the most expensive row --
 * and would let a future edit call Apply WITHOUT the preset selection that
 * ChangedShadowQuality performs first, which is a shadow config the game
 * itself never produces. The RVA is recorded in this comment so nobody has to
 * re-derive it before deciding otherwise.
 *
 * The `PostFxSettingsController.Update*` (non-`Try`) forms are absent for the
 * reason the map gives and that measurement confirms: `TryUpdateBrightness`
 * @0xBE9350 null-checks `Group@0x10` and returns silently when it is null, so
 * the `Try*` form is the game's own null-check and beats one we add. The cost
 * is that a `Try*` call which "succeeded" proves NOTHING -- which is why every
 * caller reads the finished state back off `GradingPostFX` instead.
 */
#ifndef AOWLSPT_NATIVEPOSTFX_H
#define AOWLSPT_NATIVEPOSTFX_H

#include <windows.h>
#include <stdint.h>

/* ---- the call targets ---------------------------------------------------- */
#define AOWL_NPF_GET_INSTANCE_RVA   0x1263BD0u
#define AOWL_NPF_SET_SHARPEN_RVA    0x126BCF0u
#define AOWL_NPF_SET_SSAO_RVA       0x126B930u
#define AOWL_NPF_TRY_CLARITY_RVA    0xBE9730u
#define AOWL_NPF_TRY_BRIGHTNESS_RVA 0xBE9350u
#define AOWL_NPF_TRY_SATURATION_RVA 0xBE9560u
#define AOWL_NPF_TRY_COLOURFUL_RVA  0xBE9930u
#define AOWL_NPF_TRY_LUMASHARP_RVA  0xBE9B00u
#define AOWL_NPF_TRY_ADAPTSHARP_RVA 0xBE9D00u
#define AOWL_NPF_TRY_FORCE_RVA      0xBE8880u
#define AOWL_NPF_SHADOW_QUALITY_RVA 0xBF5570u
#define AOWL_NPF_GET_CASCADES_RVA   0x5273110u

/* ---- field offsets, MEASURED `tools/fldoff.py fields <Type>` -------------
 * Not one of these is guessed, and each is READ THROUGH A VALIDATED HOP by
 * the Nim caller -- an offset that can read null is a coin flip, not a path
 * (CLAUDE.md 5). They are `#define`d here rather than spelled in the Nim so
 * that the table and the walk cannot drift apart.                          */

/* EFT.CameraControl.CameraManager */
#define AOWL_NPF_OFF_CM_POSTFX      0x58   /* <PostFX>k__BackingField : GradingPostFX */
#define AOWL_NPF_OFF_CM_CCSHARPEN   0xD0   /* _ccSharpen  : CC_Sharpen  (NULL => MANAGED THROW) */
#define AOWL_NPF_OFF_CM_PRISM       0xE8   /* _prismEffects : PrismEffects */

/* CC_Sharpen -- the object SetSharpen actually writes. */
#define AOWL_NPF_OFF_SHARPEN_STRENGTH 0x38 /* strength : float */

/* GradingPostFX -- the read-back floats for the six colour rows. These are
 * what the game's own Update* path STORES, so reading them is a property of
 * the finished state and not our own write read back. */
#define AOWL_NPF_OFF_GP_CLARITY     0x80   /* _clarityStrength         : float */
#define AOWL_NPF_OFF_GP_BRIGHTNESS  0x84   /* _brightness              : float */
#define AOWL_NPF_OFF_GP_SATURATION  0x88   /* _saturation              : float */
#define AOWL_NPF_OFF_GP_COLOURFUL   0x8C   /* _colourfulness           : float */
#define AOWL_NPF_OFF_GP_LUMASHARP   0x90   /* _lumaSharpenStrength     : float */
#define AOWL_NPF_OFF_GP_ADAPTSHARP  0x94   /* _adaptiveSharpenStrength : float */

/* GradingPostFX prefab MinMax pairs (Vector2: .x at off, .y at off+4). These
 * are INITONLY INSTANCE fields deserialised from the prefab, so their VALUES
 * are not in the DLL and are NOT guessed anywhere -- they are read off the
 * LIVE component when the verdict needs to explain a lerped result. */
#define AOWL_NPF_OFF_GP_MM_CLARITY    0xB8
#define AOWL_NPF_OFF_GP_MM_BRIGHTNESS 0xC0
#define AOWL_NPF_OFF_GP_MM_SATURATION 0xC8
#define AOWL_NPF_OFF_GP_MM_COLOURFUL  0xD8
#define AOWL_NPF_OFF_GP_MM_LUMASHARP  0xE0
#define AOWL_NPF_OFF_GP_MM_ADAPTSHARP 0xE8

/* PrismEffects -- the AO block. PUBLIC fields, so a write is a plain store
 * with no property call; it still goes through the typed FieldRef gate
 * (`tools/fieldrefs.py`), which is what refuses a wrong-klass receiver. The
 * READS below are ordinary guarded reads. */
#define AOWL_NPF_OFF_PE_USE_AO      0x268  /* useAmbientObscurance : bool */
#define AOWL_NPF_OFF_PE_AO_SAMPLES  0x26C  /* aoSampleCount : SampleCount (enum) */
#define AOWL_NPF_OFF_PE_AO_INTENS   0x27C  /* aoIntensity : float */
#define AOWL_NPF_OFF_PE_AO_RADIUS   0x284  /* aoRadius : float */
#define AOWL_NPF_OFF_PE_AO_BLURITER 0x290  /* aoBlurIterations : int */

/* ESSAOMode, MEASURED constants (`fldoff.py` enum decoder, its own 19-constant
 * self-check passing). SIX levels -- two more than the shipped dropdown
 * offers, which is the whole point of row 1. */
#define AOWL_NPF_SSAO_OFF            0
#define AOWL_NPF_SSAO_FASTEST        1
#define AOWL_NPF_SSAO_FAST           2
#define AOWL_NPF_SSAO_HIGH           3
#define AOWL_NPF_SSAO_HIGHEST        4
#define AOWL_NPF_SSAO_COLORED        5
#define AOWL_NPF_SSAO_COUNT          6

/* The 0..100 integer domain of PostFxSettingsController::Update*(int).
 * MEASURED, not assumed: `disasm 0xBE9420 --len 0x100` divides the incoming
 * int by the .rdata constant at 0x65B698C, and those four bytes decode as the
 * f32 100.0. This settles the question NATIVE-POSTFX-MAP.md section 5 left
 * open ("normalised 0..1 or raw?"). */
#define AOWL_NPF_PCT_MIN             0
#define AOWL_NPF_PCT_MAX           100

typedef struct AowlNpfTarget {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[16];
    int32_t       siglen;
} AowlNpfTarget;

static const AowlNpfTarget aowl_npf_targets[] = {
    /* [0] EFT.CameraControl.CameraManager::get_Instance()
     * STATIC (flags 0x0896 = SpecialName|HideBySig|Static|Public), arity 0,
     * returns CameraManager. Frame: RCX = MethodInfo*, nothing else.
     * UNIQUE(1), section il2cpp.
     *   48 83 EC 28  sub rsp,0x28
     *   80 3D E6 8B E5 05 00  cmp byte [rip+0x5E58BE6],0   ; cctor-ran latch
     *   75 18        jne ...
     *   48 8D 0D     lea rcx,[rip+...]
     * The RIP-relative operand is recorded because it would matter a great
     * deal to anyone stealing these bytes; this target is only ever CALLED,
     * never detoured, so nothing relocates them.
     *
     * A NULL return is the ordinary menu case -- there is no raid camera --
     * and the caller reports it INCONCLUSIVE, never "off". */
    { "EFT.CameraControl.CameraManager::get_Instance", AOWL_NPF_GET_INSTANCE_RVA,
      { 0x48,0x83,0xEC,0x28, 0x80,0x3D,0xE6,0x8B,0xE5,0x05,0x00,
        0x75,0x18, 0x48,0x8D,0x0D }, 16 },

    /* [1] EFT.CameraControl.CameraManager::SetSharpen(float strength)
     * Instance (flags 0x0086 = HideBySig|Public), arity 1, UNIQUE(1), il2cpp.
     * Frame: RCX = this, XMM1 = strength (slot 1 -> XMM1), R8 = MethodInfo*.
     *
     * READ THE MANAGED-THROW SECTION IN THIS FILE'S HEADER BEFORE TOUCHING
     * THIS ROW. A null `_ccSharpen@0xD0` does not no-op, it THROWS, and an SEH
     * guard cannot catch that. `aowl_npf_call_set_sharpen` therefore demands
     * the already-read CC_Sharpen pointer as an argument.
     *
     *   48 83 EC 28              sub rsp,0x28
     *   48 8B 81 D0 00 00 00     mov rax,[rcx+0xD0]
     *   48 85 C0                 test rax,rax
     *   74 0A                    je -> throw */
    { "EFT.CameraControl.CameraManager::SetSharpen", AOWL_NPF_SET_SHARPEN_RVA,
      { 0x48,0x83,0xEC,0x28, 0x48,0x8B,0x81,0xD0,0x00,0x00,0x00,
        0x48,0x85,0xC0, 0x74,0x0A }, 16 },

    /* [2] EFT.CameraControl.CameraManager::SetSSAO(ESSAOMode ssaoMode)
     * Instance (0x0086), arity 1, UNIQUE(1), il2cpp.
     * Frame: RCX = this, EDX = the enum, R8 = MethodInfo*.
     * An enum argument is passed in the INTEGER slot at its declared width;
     * ESSAOMode's underlying type is int32, so EDX and not RDX carries it --
     * the wrapper widens to uint64_t and the callee reads the low dword, which
     * is exactly what the Win64 convention delivers.
     *   48 89 5C 24 08 / 48 89 74 24 10 / 48 89 7C 24 18 / 55 */
    { "EFT.CameraControl.CameraManager::SetSSAO", AOWL_NPF_SET_SSAO_RVA,
      { 0x48,0x89,0x5C,0x24,0x08, 0x48,0x89,0x74,0x24,0x10,
        0x48,0x89,0x7C,0x24,0x18, 0x55 }, 16 },

    /* [3..8] EFT.Settings.PostFx.PostFxSettingsController::TryUpdate*(int value)
     * All instance, all flags 0x0081 (HideBySig|Private -- private is no
     * obstacle to a direct RVA call and, being non-virtual, there is no
     * override hazard), all arity 1, all UNIQUE(1), all section il2cpp.
     * Frame: RCX = this, EDX = value (0..100), R8 = MethodInfo*.
     *
     * Two of the six open `48 89 74 24 10 57 ...` and the other two-of-six
     * open `40 57 ...`; that difference is real and is why each row carries
     * its OWN sixteen bytes rather than a shared constant. Getting this wrong
     * would produce a verify that passes for the wrong function. */

    /* [3] TryUpdateClarity -> GradingPostFX._clarityStrength@0x80 */
    { "EFT.Settings.PostFx.PostFxSettingsController::TryUpdateClarity",
      AOWL_NPF_TRY_CLARITY_RVA,
      { 0x48,0x89,0x74,0x24,0x10, 0x57, 0x48,0x83,0xEC,0x20,
        0x80,0x3D,0x84,0x05,0x4D,0x06 }, 16 },

    /* [4] TryUpdateBrightness -> GradingPostFX._brightness@0x84 */
    { "EFT.Settings.PostFx.PostFxSettingsController::TryUpdateBrightness",
      AOWL_NPF_TRY_BRIGHTNESS_RVA,
      { 0x48,0x89,0x74,0x24,0x10, 0x57, 0x48,0x83,0xEC,0x20,
        0x80,0x3D,0x62,0x09,0x4D,0x06 }, 16 },

    /* [5] TryUpdateSaturation -> GradingPostFX._saturation@0x88 */
    { "EFT.Settings.PostFx.PostFxSettingsController::TryUpdateSaturation",
      AOWL_NPF_TRY_SATURATION_RVA,
      { 0x40,0x57, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0x57,0x07,0x4D,0x06,0x00,
        0x48,0x8B,0xF9 }, 16 },

    /* [6] TryUpdateColorfulness -> GradingPostFX._colourfulness@0x8C
     * NOTE the spelling difference, which is the game's and not a typo here:
     * the METHOD is "Colorfulness" and the FIELD is "_colourfulness". */
    { "EFT.Settings.PostFx.PostFxSettingsController::TryUpdateColorfulness",
      AOWL_NPF_TRY_COLOURFUL_RVA,
      { 0x40,0x57, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0x89,0x03,0x4D,0x06,0x00,
        0x48,0x8B,0xF9 }, 16 },

    /* [7] TryUpdateLumaSharpen -> GradingPostFX._lumaSharpenStrength@0x90 */
    { "EFT.Settings.PostFx.PostFxSettingsController::TryUpdateLumaSharpen",
      AOWL_NPF_TRY_LUMASHARP_RVA,
      { 0x48,0x89,0x74,0x24,0x10, 0x57, 0x48,0x83,0xEC,0x20,
        0x80,0x3D,0xB6,0x01,0x4D,0x06 }, 16 },

    /* [8] TryUpdateAdaptiveSharpen -> GradingPostFX._adaptiveSharpenStrength@0x94 */
    { "EFT.Settings.PostFx.PostFxSettingsController::TryUpdateAdaptiveSharpen",
      AOWL_NPF_TRY_ADAPTSHARP_RVA,
      { 0x48,0x89,0x74,0x24,0x10, 0x57, 0x48,0x83,0xEC,0x20,
        0x80,0x3D,0xB7,0xFF,0x4C,0x06 }, 16 },

    /* [9] EFT.Settings.PostFx.PostFxSettingsController::TryForceUpdate()
     * Instance (0x0086), arity 0, UNIQUE(1), il2cpp.
     * Frame: RCX = this, RDX = MethodInfo*.
     * Called ONCE after a batch of TryUpdate* calls rather than after each, so
     * a six-slider seed costs one force-update and not six.
     *   40 53 / 48 83 EC 20 / 80 3D 34 14 4D 06 00 / 48 8B D9 */
    { "EFT.Settings.PostFx.PostFxSettingsController::TryForceUpdate",
      AOWL_NPF_TRY_FORCE_RVA,
      { 0x40,0x53, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0x34,0x14,0x4D,0x06,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [10] EFT.Settings.Graphics.GraphicsSettingsController::ChangedShadowQuality(int)
     *
     * **STATIC.** This is correction (1) in this file's header and it is the
     * one that would have crashed or silently misapplied. MEASURED twice:
     *   * flags = 0x0091 = HideBySig | STATIC(0x10) | Private;
     *   * `il2cpp_resolve.py disasm 0xBF5570` derives, from the metadata
     *     signature, `args rcx=int value  rdx=<MethodInfo*>`;
     *   * and the body agrees -- `8B D9  mov ebx,ecx` at +0xD, then
     *     `85 DB  test ebx,ebx` at +0x5F. ECX **is** the integer argument.
     *
     * Frame: RCX = value, RDX = MethodInfo*. There is NO receiver. Passing one
     * would hand the low dword of a heap pointer to the shadow-quality switch.
     *
     * UNIQUE(1), section il2cpp. Its only IL2CPP-owned call is
     * QualityLevelPreset::Apply() @0xC03890 -- see "WHAT IS NOT IN THIS TABLE".
     *   40 53 / 48 83 EC 70 / 80 3D C0 47 4C 06 00 / 8B D9 / 75 */
    { "EFT.Settings.Graphics.GraphicsSettingsController::ChangedShadowQuality",
      AOWL_NPF_SHADOW_QUALITY_RVA,
      { 0x40,0x53, 0x48,0x83,0xEC,0x70, 0x80,0x3D,0xC0,0x47,0x4C,0x06,0x00,
        0x8B,0xD9, 0x75 }, 16 },

    /* [11] UnityEngine.QualitySettings::get_shadowCascades()
     * STATIC (0x0896), arity 0, returns int. UNIQUE(1), section il2cpp,
     * image UnityEngine.CoreModule.dll. Frame: RCX = MethodInfo*.
     *
     * This is the SHADOW ROW'S VERDICT, and it is here rather than a read of
     * `QualityLevelPreset._shadowCascades@0x34` on purpose: the preset object
     * is the thing the applier was ASKED to install, so reading it back is a
     * check that cannot fail (CLAUDE.md 9b). The ENGINE's own opinion can
     * disagree with the preset, and that disagreement is the only thing worth
     * printing.
     *   48 83 EC 28 / 48 8B 05 05 01 E6 01 / 48 85 C0 / 75 18 */
    { "UnityEngine.QualitySettings::get_shadowCascades", AOWL_NPF_GET_CASCADES_RVA,
      { 0x48,0x83,0xEC,0x28, 0x48,0x8B,0x05,0x05,0x01,0xE6,0x01,
        0x48,0x85,0xC0, 0x75,0x18 }, 16 },
};

#define AOWL_NPF_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_npf_targets) / sizeof(aowl_npf_targets[0])))

/* The positional names. `tools/idxbind.py` asserts at BUILD TIME that the Nim
 * constant naming each row still resolves to the row it names -- the check
 * that exists because a row inserted in the MIDDLE of a table silently
 * re-points every constant below it at a valid function of the wrong shape. */
#define AOWL_NPF_T_GET_INSTANCE   0
#define AOWL_NPF_T_SET_SHARPEN    1
#define AOWL_NPF_T_SET_SSAO       2
#define AOWL_NPF_T_TRY_CLARITY    3
#define AOWL_NPF_T_TRY_BRIGHTNESS 4
#define AOWL_NPF_T_TRY_SATURATION 5
#define AOWL_NPF_T_TRY_COLOURFUL  6
#define AOWL_NPF_T_TRY_LUMASHARP  7
#define AOWL_NPF_T_TRY_ADAPTSHARP 8
#define AOWL_NPF_T_TRY_FORCE      9
#define AOWL_NPF_T_SHADOW_QUALITY 10
#define AOWL_NPF_T_GET_CASCADES   11

static int32_t aowl_npf_verified = 0;
static int32_t aowl_npf_rejected = 0;
static int32_t aowl_npf_profull  = 0;

/* Resolve one row to callable code, or NULL. Same four gates every table in
 * this repo uses, in the same order, and for the same measured reasons:
 * VirtualQuery + MEM_COMMIT + an executable protection BEFORE the compare (so
 * a stale RVA on an uncommitted page cannot fault inside `memcmp`), then the
 * 16-byte compare against the STARTUP SNAPSHOT.
 *
 * "the snapshot table was full" is counted APART from "the bytes differ",
 * because only the second says anything about the client. Collapsing them
 * produces a refusal that blames the game for our own bookkeeping. */
static void* aowl_npf_fn(int32_t i) {
    HMODULE ga;
    const AowlNpfTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_NPF_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    t = &aowl_npf_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        if (aowl_pro_last_was_table_full()) { aowl_npf_profull++; return NULL; }
        aowl_npf_rejected++;
        return NULL;
    }
    aowl_npf_verified++;
    return (void*)p;
}

static const char* aowl_npf_name(int32_t i) {
    if (i < 0 || i >= AOWL_NPF_TARGET_COUNT) return "";
    return aowl_npf_targets[i].name;
}
static uint32_t aowl_npf_rva(int32_t i) {
    if (i < 0 || i >= AOWL_NPF_TARGET_COUNT) return 0u;
    return aowl_npf_targets[i].rva;
}
static int32_t aowl_npf_target_count(void) { return AOWL_NPF_TARGET_COUNT; }
static int32_t aowl_npf_ok_count(void)     { return aowl_npf_verified; }
static int32_t aowl_npf_bad_count(void)    { return aowl_npf_rejected; }
static int32_t aowl_npf_profull_count(void){ return aowl_npf_profull; }

/* The eager pass. Called from `aowl_pro_prime_all` at host startup, BEFORE any
 * bind exists, so no verify here can ever be fed another feature's trampoline.
 * Nothing in this host detours any of these twelve today; they are primed
 * anyway, because the eager pass exists precisely so that no verify has to
 * depend on "nothing else patches that". */
static void aowl_npf_prime_all(void) {
    int32_t i;
    for (i = 0; i < AOWL_NPF_TARGET_COUNT; i++)
        aowl_pro_prime(aowl_npf_targets[i].rva);
}

/* ---- the call wrappers ---------------------------------------------------
 * One per shape, each spelling the real parameter types so the compiler
 * places the argument in the register the callee reads. Every wrapper refuses
 * a NULL fn and a NULL receiver rather than calling into nothing, and every
 * one passes the trailing NULL MethodInfo* EXPLICITLY. None of these methods
 * is generic, so NULL is correct.                                          */

/* Static, arity 0, returns a pointer: RCX = MethodInfo*.
 * A NULL return is the ordinary "no raid camera" case, not an error. */
typedef void* (*AowlNpf_GetInstance)(void*);
static void* aowl_npf_call_get_instance(void* fn) {
    if (!fn) return NULL;
    return ((AowlNpf_GetInstance)fn)(NULL);
}

/* Instance, arity 1 (float): RCX = this, XMM1 = strength, R8 = MethodInfo*.
 *
 * `ccSharpen` is NOT passed to the game -- it is demanded here so that the
 * caller CANNOT express this call without having read and null-checked
 * `CameraManager._ccSharpen@0xD0` first. A null there makes the callee raise a
 * MANAGED NullReferenceException, which `aowl_p_p_seh` does not catch; see
 * this file's header. Returning 0 means "refused, nothing was called". */
typedef void (*AowlNpf_SetSharpen)(void*, float, void*);
static int32_t aowl_npf_call_set_sharpen(void* fn, void* cameraManager,
                                         void* ccSharpen, float strength) {
    if (!fn || !cameraManager || !ccSharpen) return 0;
    ((AowlNpf_SetSharpen)fn)(cameraManager, strength, NULL);
    return 1;
}

/* Instance, arity 1 (enum, int32 underlying): RCX = this, EDX = mode,
 * R8 = MethodInfo*. The mode is range-checked here as well as by the caller:
 * ESSAOMode has exactly six declared members and a value outside them is a
 * switch fallthrough in the callee, not a clamp. */
typedef void (*AowlNpf_SetSsao)(void*, uint64_t, void*);
static int32_t aowl_npf_call_set_ssao(void* fn, void* cameraManager, int32_t mode) {
    if (!fn || !cameraManager) return 0;
    if (mode < AOWL_NPF_SSAO_OFF || mode > AOWL_NPF_SSAO_COLORED) return 0;
    ((AowlNpf_SetSsao)fn)(cameraManager, (uint64_t)(uint32_t)mode, NULL);
    return 1;
}

/* Instance, arity 1 (int): RCX = this, EDX = value, R8 = MethodInfo*.
 * Shared by all six TryUpdate* rows -- they differ only in which row index is
 * resolved, never in shape, which is why one wrapper is correct here and a
 * wrapper per row would be six chances to get the frame wrong.
 *
 * The value is clamped to the MEASURED 0..100 domain (see AOWL_NPF_PCT_*).
 * Clamping rather than refusing is deliberate: this mirrors what the game's
 * own slider hands the same method, so an out-of-range value from a stale
 * cache produces the setting the game itself would produce, not a refusal the
 * player cannot act on. */
typedef void (*AowlNpf_TryUpdate)(void*, uint64_t, void*);
static int32_t aowl_npf_call_try_update(void* fn, void* controller, int32_t value) {
    if (!fn || !controller) return 0;
    if (value < AOWL_NPF_PCT_MIN) value = AOWL_NPF_PCT_MIN;
    if (value > AOWL_NPF_PCT_MAX) value = AOWL_NPF_PCT_MAX;
    ((AowlNpf_TryUpdate)fn)(controller, (uint64_t)(uint32_t)value, NULL);
    return 1;
}

/* Instance, arity 0: RCX = this, RDX = MethodInfo*. */
typedef void (*AowlNpf_TryForce)(void*, void*);
static int32_t aowl_npf_call_try_force(void* fn, void* controller) {
    if (!fn || !controller) return 0;
    ((AowlNpf_TryForce)fn)(controller, NULL);
    return 1;
}

/* **STATIC**, arity 1 (int): RCX = value, RDX = MethodInfo*. NO RECEIVER.
 * This signature is the whole reason row [10] carries the long comment it
 * does; see correction (1) in the header. */
typedef void (*AowlNpf_ShadowQuality)(uint64_t, void*);
static int32_t aowl_npf_call_shadow_quality(void* fn, int32_t value) {
    if (!fn) return 0;
    ((AowlNpf_ShadowQuality)fn)((uint64_t)(uint32_t)value, NULL);
    return 1;
}

/* Static, arity 0, returns int: RCX = MethodInfo*. The shadow verdict. */
typedef int32_t (*AowlNpf_GetCascades)(void*);
static int32_t aowl_npf_call_get_cascades(void* fn, int32_t* out) {
    if (!fn || !out) return 0;
    *out = ((AowlNpf_GetCascades)fn)(NULL);
    return 1;
}

/* ---- offset accessors, so the Nim never spells an offset -----------------*/
static int32_t aowl_npf_off_cm_postfx(void)    { return AOWL_NPF_OFF_CM_POSTFX; }
static int32_t aowl_npf_off_cm_ccsharpen(void) { return AOWL_NPF_OFF_CM_CCSHARPEN; }
static int32_t aowl_npf_off_cm_prism(void)     { return AOWL_NPF_OFF_CM_PRISM; }
static int32_t aowl_npf_off_sharpen_strength(void) {
    return AOWL_NPF_OFF_SHARPEN_STRENGTH;
}
static int32_t aowl_npf_off_pe_use_ao(void)    { return AOWL_NPF_OFF_PE_USE_AO; }
static int32_t aowl_npf_off_pe_ao_samples(void){ return AOWL_NPF_OFF_PE_AO_SAMPLES; }
static int32_t aowl_npf_off_pe_ao_intens(void) { return AOWL_NPF_OFF_PE_AO_INTENS; }
static int32_t aowl_npf_off_pe_ao_radius(void) { return AOWL_NPF_OFF_PE_AO_RADIUS; }
static int32_t aowl_npf_off_pe_ao_bluriter(void){ return AOWL_NPF_OFF_PE_AO_BLURITER; }

/* The six colour rows' READ-BACK offsets on GradingPostFX, and their prefab
 * MinMax pairs, KEYED BY THE TABLE ROW INDEX of the TryUpdate* that writes
 * them. Keying by row index rather than exposing six separate accessors is
 * deliberate: it makes "which field does row N's applier actually store?" a
 * single fact in a single place. Getting that pairing wrong is precisely the
 * check-that-cannot-fail this repo keeps paying for -- reading back the WRONG
 * float would report brightness as applied when saturation moved.
 *
 * The pairing was MEASURED, not assumed from the names: `disasm 0xBE9420`
 * (UpdateBrightness, the body TryUpdateBrightness tail-calls) reads
 * `_technicolorBrightnessMinMax.x@0xC0` / `.y@0xC4` and stores `[rbx+0x84]`,
 * which is `_brightness`. Returns -1 for a row that writes no such float, and
 * the caller treats -1 as "no read-back available" -- INCONCLUSIVE, never a
 * pass. */
static int32_t aowl_npf_off_gp_value(int32_t row) {
    switch (row) {
        case AOWL_NPF_T_TRY_CLARITY:    return AOWL_NPF_OFF_GP_CLARITY;
        case AOWL_NPF_T_TRY_BRIGHTNESS: return AOWL_NPF_OFF_GP_BRIGHTNESS;
        case AOWL_NPF_T_TRY_SATURATION: return AOWL_NPF_OFF_GP_SATURATION;
        case AOWL_NPF_T_TRY_COLOURFUL:  return AOWL_NPF_OFF_GP_COLOURFUL;
        case AOWL_NPF_T_TRY_LUMASHARP:  return AOWL_NPF_OFF_GP_LUMASHARP;
        case AOWL_NPF_T_TRY_ADAPTSHARP: return AOWL_NPF_OFF_GP_ADAPTSHARP;
        default: return -1;
    }
}

static int32_t aowl_npf_off_gp_minmax(int32_t row) {
    switch (row) {
        case AOWL_NPF_T_TRY_CLARITY:    return AOWL_NPF_OFF_GP_MM_CLARITY;
        case AOWL_NPF_T_TRY_BRIGHTNESS: return AOWL_NPF_OFF_GP_MM_BRIGHTNESS;
        case AOWL_NPF_T_TRY_SATURATION: return AOWL_NPF_OFF_GP_MM_SATURATION;
        case AOWL_NPF_T_TRY_COLOURFUL:  return AOWL_NPF_OFF_GP_MM_COLOURFUL;
        case AOWL_NPF_T_TRY_LUMASHARP:  return AOWL_NPF_OFF_GP_MM_LUMASHARP;
        case AOWL_NPF_T_TRY_ADAPTSHARP: return AOWL_NPF_OFF_GP_MM_ADAPTSHARP;
        default: return -1;
    }
}

#endif /* AOWLSPT_NATIVEPOSTFX_H */
