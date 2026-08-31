/* aowlspt_unitypp.h -- Unity Post Processing Stack v2, READ-ONLY DISCOVERY.
 *
 * ===========================================================================
 * WHY THIS FILE EXISTS
 * ===========================================================================
 *
 * `mods/graphics` renders nothing itself. The renderer is native D3D11 in
 * `abi/aowlspt_graphics.h`, hooked off the overlay's Present: it copies the
 * FINISHED back buffer and grades it. That is post-hoc -- it fights the game's
 * own rendering, it is ordered after everything including the UI, and it has
 * no honest access to depth or motion vectors. The standing instruction is to
 * stop doing that and drive the game's OWN post-processing instead.
 *
 * So the first question is not "how do we write the grade", it is "what post
 * processing does THIS build actually have". That was answered OFFLINE, before
 * a line of this file was written, with `tools/il2cpp_resolve.py` and
 * `tools/fldoff.py` against D:/Aowlspt/GameAssembly.dll and the decrypted
 * global-metadata. The answer:
 *
 *   Unity.Postprocessing.Runtime.dll IS PRESENT AND UNSTRIPPED.
 *
 * 118 types in namespace `UnityEngine.Rendering.PostProcessing`, including
 * every one that matters here:
 *
 *   PostProcessLayer  PostProcessVolume  PostProcessProfile  PostProcessManager
 *   PostProcessEffectSettings  PostProcessBundle  PostProcessRenderContext
 *   ColorGrading  Bloom  Vignette  Grain  ChromaticAberration  AmbientOcclusion
 *   DepthOfField  MotionBlur  LensDistortion  AutoExposure  ScreenSpaceReflections
 *   TemporalAntialiasing  SubpixelMorphologicalAntialiasing  Fog  Dithering
 *
 * plus the whole ParameterOverride family (FloatParameter, BoolParameter,
 * ColorParameter, Vector2/3/4Parameter, IntParameter, SplineParameter,
 * TextureParameter, and the enum-typed TonemapperParameter / GradingModeParameter
 * / VignetteModeParameter / KernelSizeParameter).
 *
 * That is the real answer to "does the stack exist", and it means the D3D11
 * path can eventually be retired rather than merely wrapped.
 *
 * ===========================================================================
 * THE OFFSETS -- AND THE ONE THAT IS NOT KNOWABLE OFFLINE
 * ===========================================================================
 *
 * All of these come from `Il2CppMetadataRegistration.fieldOffsets` via
 * `tools/fldoff.py fields <Type>`, whose mandatory self-check
 * (System.String._stringLength@0x10, _firstChar@0x14) passed. None is guessed.
 *
 *   PostProcessVolume            sharedProfile        @0x20   PostProcessProfile
 *                                isGlobal             @0x28   bool
 *                                blendDistance        @0x2C   float
 *                                weight               @0x30   float
 *                                priority             @0x34   float
 *                                m_InternalProfile    @0x48   PostProcessProfile
 *
 *   PostProcessProfile           settings             @0x18   List<PostProcessEffectSettings>
 *                                isDirty              @0x20   bool
 *
 *   PostProcessEffectSettings    active               @0x18   bool
 *                                enabled              @0x20   BoolParameter
 *                                parameters           @0x28   ReadOnlyCollection<ParameterOverride>
 *
 *   ColorGrading (: EffectSettings)
 *                                gradingMode          @0x30   temperature @0x88
 *                                tonemapper           @0x40   tint        @0x90
 *                                toneCurveToeStrength @0x48   colorFilter @0x98
 *                                ldrLutContribution   @0x80   hueShift    @0xA0
 *                                saturation           @0xA8   brightness  @0xB0
 *                                postExposure         @0xB8   contrast    @0xC0
 *                                lift @0x110  gamma @0x118  gain @0x120
 *
 *   Vignette (: EffectSettings)  mode      @0x30   color     @0x38  center @0x40
 *                                intensity @0x48   smoothness@0x50  roundness@0x58
 *                                rounded   @0x60   mask      @0x68  opacity @0x70
 *
 *   ParameterOverride (NON-generic base)
 *                                overrideState        @0x10   bool   <-- REAL
 *
 * ---- THE HOLE, STATED PLAINLY -------------------------------------------
 *
 * `FloatParameter` declares NO fields of its own. Its value lives in
 * `ParameterOverride<T>.value`, and `fldoff.py` reports that field as
 *
 *      GENERIC -- NO LAYOUT: uninstantiated generic type definition
 *
 * which is CLAUDE.md 5's three-state offset rule biting exactly where it says
 * it will. IL2CPP writes an all-zero fieldOffsets array for `ParameterOverride`1`;
 * the concrete layout of `ParameterOverride<float>` is built at runtime and
 * every `Il2CppGenericClass.cached_class` in GameAssembly.dll is null. It is
 * NOT reachable offline, and no amount of reading the file will change that.
 *
 * The obvious inference is `value @ 0x14` (bool at 0x10, float padded to its
 * natural 4-byte alignment). It is PROBABLY right. It is still an INFERENCE,
 * and a wrong offset here does not fault -- it reads a plausible float and then
 * a WRITE at that offset corrupts a live managed object every frame. That is
 * precisely the failure this project keeps paying for, so:
 *
 *   THIS FILE DOES NOT WRITE. NOT ONE BYTE.
 *
 * It PROBES: it walks to the live profile, names every effect it finds by
 * reading the object's own klass, and for ColorGrading it dumps the raw bytes
 * of `saturation` and `postExposure` at 0x10..0x20 into the host log. Two
 * FloatParameters with different, known-different authored values settle the
 * `value` offset from the log in ONE run, empirically, with no guess surviving.
 * Only after that run may a write path be built -- in a follow-up.
 *
 * ===========================================================================
 * BORROWED LAYOUTS (said out loud, as required)
 * ===========================================================================
 *
 *   List<T>   _items @0x10 -> T[],  _size @0x18 (int32)
 *   T[]       element 0 @0x20
 *
 * BORROWED from `abi/aowlspt_botdiag.h` and `abi/aowlspt_debugui.h`, which have
 * both used this shape against live objects in this client. It is an
 * instantiated generic layout and therefore, per the rule, not offline-derivable
 * either. Every element read below is bounds-checked against `_size` AND capped,
 * and every element pointer is klass-named before anything is read through it,
 * so a wrong borrow produces a refusal in the log rather than a fabricated tree.
 *
 * ===========================================================================
 * TYPE CONFUSION IS THE REAL ENEMY, NOT UNREADABILITY
 * ===========================================================================
 *
 * `aowl_admin_readable()` proves a page is mapped. It does not prove the object
 * is what you think, and Unity's FAKE NULL means a live-looking managed pointer
 * can wrap a destroyed native object. So every hop here is checked TWICE:
 * readable, and then IDENTIFIED by `aowl_comp_klass_fullname()` -- the same
 * klass->name/namespace reader the inspector's `component` verb uses. A pointer
 * whose klass does not name a PostProcessing type is refused by name in the log.
 * That is the check that can actually fail, which is the only kind worth having.
 *
 * ===========================================================================
 * THE EIGHT RULES
 * ===========================================================================
 *
 *  1. Prologue byte-verify -- inherited. The only game code called is
 *     `Component::GetComponent(String)` @0x52A48E0, bound and 16-byte verified
 *     by `abi/aowlspt_navui.h`, and the camera acquisition in
 *     `abi/aowlspt_admin.h` (AOWL_ADM_SIG_CAM_MAIN / _CAM_MGR). No new RVA is
 *     introduced and nothing new is bound.
 *  2. VirtualQuery on EVERY hop -- `aowl_admin_readable` before each read.
 *  3. ONE `aowl_p_p_seh`, opened by `aowl_upp_tick` around the whole body.
 *     `aowl_upp_scan_body` opens NONE. Nesting would disarm the outer guard.
 *  4. Capped -- AOWL_UPP_MAX_EFFECTS effects, AOWL_UPP_NAME_MAX name bytes.
 *  5. Flag-gated, default OFF -- `unityPostProbe`.
 *  6. Self-disable after AOWL_UPP_MAXFAULT faults.
 *  7. No managed allocation. Ever. No `il2cpp_string_new` in the tick either:
 *     the GetComponent argument string is created ONCE, on the first tick, and
 *     cached in a static.
 *  8. Never blind-write -- vacuously, since it never writes.
 *
 * The probe runs ONCE and latches. It is a survey, not a per-frame feature.
 *
 * ===========================================================================
 * PREREQUISITES
 * ===========================================================================
 *
 * Same translation unit as `aowlspt_admin.h` (for `aowl_admin_cam_object`,
 * `aowl_admin_readable`) and `aowlspt_components.h` (for the klass namer), and
 * after `aowlspt_region.h` for `aowl_region_sayf`. That is region.nim, and only
 * region.nim.
 */
#ifndef AOWLSPT_UNITYPP_H
#define AOWLSPT_UNITYPP_H

#ifndef AOWL_REGION_HOST
#error "aowlspt_unitypp.h belongs to the ONE region host TU (region.nim). \
Including it elsewhere would compile a SECOND copy of its static state, and \
two copies means two answers to one question."
#endif

/* ---- offsets: MEASURED offline, tools/fldoff.py, self-check passed ---- */
#define AOWL_UPP_VOL_SHAREDPROFILE   0x20
#define AOWL_UPP_VOL_ISGLOBAL        0x28
#define AOWL_UPP_VOL_WEIGHT          0x30
#define AOWL_UPP_VOL_PRIORITY        0x34
#define AOWL_UPP_VOL_INTERNALPROFILE 0x48

#define AOWL_UPP_PROF_SETTINGS       0x18

#define AOWL_UPP_SET_ACTIVE          0x18
#define AOWL_UPP_SET_ENABLED         0x20

#define AOWL_UPP_CG_SATURATION       0xA8
#define AOWL_UPP_CG_POSTEXPOSURE     0xB8
#define AOWL_UPP_CG_CONTRAST         0xC0

#define AOWL_UPP_PARAM_OVERRIDESTATE 0x10   /* REAL: non-generic base       */
/* NO AOWL_UPP_PARAM_VALUE. It is not knowable offline and is not guessed.  */

/* ---- BORROWED instantiated-generic layout (see header text) ---- */
#define AOWL_UPP_LIST_ITEMS          0x10
#define AOWL_UPP_LIST_SIZE           0x18
#define AOWL_UPP_ARR_ELEM0           0x20

/* ---- caps (rule 4) ---- */
#define AOWL_UPP_MAX_EFFECTS         48
#define AOWL_UPP_MAXFAULT            3

/* ---------------------------------------------------------------------------
 * THE ONE GAME CALL, BOUND HERE AND VERIFIED HERE
 *
 * `UnityEngine.Component::GetComponent(System.String)` @ 0x52A48E0. The RVA and
 * the 16 prologue bytes below are COPIED VERBATIM from the already-verified
 * entry in `abi/aowlspt_navui.h` -- they are not re-derived, and they are not
 * read from live memory (CLAUDE.md 5: verify against the STARTUP SNAPSHOT, not
 * memory another feature may have trampolined). navui.h itself is deliberately
 * NOT included: it carries a large body of static state whose second copy in
 * this TU would be exactly the "two answers to one question" this repo forbids.
 *
 * The string overload is chosen for the same reason navui.h chose it:
 * GetComponent(Type) needs a live System.Type (reflection, token-gated), and
 * GetComponent<T> is shared generic code where a NULL MethodInfo* is not legal.
 * The string overload needs neither.
 * ------------------------------------------------------------------------- */
#define AOWL_UPP_RVA_GETCOMPONENT 0x52A48E0u
static const unsigned char AOWL_UPP_SIG_GETCOMPONENT[16] = {
    0x48,0x89,0x5C,0x24,0x08,
    0x57,
    0x48,0x83,0xEC,0x20,
    0x48,0x8B,0x05,0x07,0xFC,0xE2 };

typedef void* (*AowlUppGetCompFn)(void* self, void* name, void* mi);
typedef void* (*AowlUppStrNewFn)(const char* s);

static AowlUppGetCompFn aowl_upp_getcomp_fn = 0;
static AowlUppStrNewFn  aowl_upp_strnew_fn  = 0;
static int32_t          aowl_upp_bind_tried = 0;
static int32_t          aowl_upp_bind_ok    = 0;

/* `il2cpp_string_new` is an UNGATED export (CLAUDE.md 5) -- it takes no trailing
 * token and cannot return the uniform-random value the 40 gated exports do. */
static void aowl_upp_bind(void) {
    HMODULE ga;
    if (aowl_upp_bind_tried) return;
    aowl_upp_bind_tried = 1;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_upp_bind_tried = 0; return; }   /* retry next tick */
    aowl_upp_getcomp_fn = (AowlUppGetCompFn)aowl_admin_bind_rva(
        (unsigned char*)ga, AOWL_UPP_RVA_GETCOMPONENT,
        AOWL_UPP_SIG_GETCOMPONENT);
    aowl_upp_strnew_fn = (AowlUppStrNewFn)GetProcAddress(ga,
        "il2cpp_string_new");
    aowl_upp_bind_ok = (aowl_upp_getcomp_fn && aowl_upp_strnew_fn) ? 1 : 0;
    if (!aowl_upp_bind_ok) {
        aowl_region_sayf(
            "unity post: REFUSED to survey -- %s. Nothing was called.",
            aowl_upp_getcomp_fn
              ? "il2cpp_string_new is not exported"
              : "the 16 prologue bytes at Component::GetComponent(String) "
                "@0x52A48E0 do NOT match the startup snapshot (another feature "
                "may have trampolined it, which is a hook-order problem, not a "
                "bad RVA)");
    }
}

/* ---- state ---- */
static int32_t  aowl_upp_done      = 0;  /* survey has produced a verdict   */
static int32_t  aowl_upp_disabled  = 0;  /* self-disabled (rule 6)          */
static int32_t  aowl_upp_faults    = 0;
static int32_t  aowl_upp_ticks     = 0;
static int32_t  aowl_upp_found     = 0;  /* effects named                   */
static int32_t  aowl_upp_have_cg   = 0;  /* a live ColorGrading was reached */
static void    *aowl_upp_str_layer = 0;  /* cached il2cpp string, made once */
static void    *aowl_upp_str_vol   = 0;

static int32_t aowl_upp_is_done(void)     { return aowl_upp_done; }
static int32_t aowl_upp_is_disabled(void) { return aowl_upp_disabled; }
static int32_t aowl_upp_effect_count(void){ return aowl_upp_found; }
static int32_t aowl_upp_has_grading(void) { return aowl_upp_have_cg; }
static int32_t aowl_upp_fault_count(void) { return aowl_upp_faults; }

/* Readable AND identified. Returns the klass full name in aowl_comp_name_buf()
 * on success, 0 on either failure -- the caller must distinguish those in its
 * log line, and below it always does. */
static int32_t aowl_upp_identify(const void *obj) {
    void *klass;
    if (!obj) return 0;
    if (!aowl_admin_readable(obj, 8)) return 0;
    klass = *(void * const *)obj;                 /* Il2CppObject.klass @0x0 */
    if (!klass) return 0;
    if (!aowl_admin_readable(klass, 0x20)) return 0;
    return aowl_comp_klass_fullname(klass, aowl_comp_namebuf,
                                    AOWL_COMP_FULL_MAX);
}

/* Dump a ParameterOverride's first 16 bytes, IDENTIFIED first. This is the
 * whole point of the probe: `value`'s offset is settled from these bytes, not
 * from a guess in a header. */
static void aowl_upp_dump_param(const char *what, const void *p) {
    const unsigned char *b;
    int i;
    char hex[64];
    if (!aowl_upp_identify(p)) {
        aowl_region_sayf("unity post: %s -- REFUSED, the pointer at that "
                         "offset is unreadable or carries no klass name, so "
                         "nothing was read through it", what);
        return;
    }
    if (!aowl_admin_readable((const unsigned char *)p + 0x10, 16)) {
        aowl_region_sayf("unity post: %s is a live '%s' but +0x10..0x20 is "
                         "NOT readable -- refused", what, aowl_comp_namebuf);
        return;
    }
    b = (const unsigned char *)p + 0x10;
    for (i = 0; i < 16; i++) {
        static const char *d = "0123456789abcdef";
        hex[i * 3 + 0] = d[(b[i] >> 4) & 0xF];
        hex[i * 3 + 1] = d[b[i] & 0xF];
        hex[i * 3 + 2] = ' ';
    }
    hex[48] = 0;
    aowl_region_sayf(
        "unity post: %s -- klass '%s', overrideState@0x10 = %d, raw +0x10: %s "
        "(f32@0x14 = %.4f, f32@0x18 = %.4f). ParameterOverride<T>.value is "
        "GENERIC-NO-LAYOUT offline; THESE BYTES settle which of 0x14/0x18 it "
        "is, and no write path exists until they do.",
        what, aowl_comp_namebuf, (int)b[0], hex,
        (double)*(const float *)(b + 4), (double)*(const float *)(b + 8));
}

/* Walk one profile's settings list, naming every effect. Returns the count. */
static int32_t aowl_upp_walk_profile(const void *profile, const char *origin) {
    const void *list, *arr, *elem;
    int32_t size, i, n = 0;

    if (!aowl_upp_identify(profile)) return 0;
    aowl_region_sayf("unity post: %s profile is a live '%s'", origin,
                     aowl_comp_namebuf);

    if (!aowl_admin_readable((const unsigned char *)profile +
                             AOWL_UPP_PROF_SETTINGS, 8)) return 0;
    list = *(const void * const *)((const unsigned char *)profile +
                                   AOWL_UPP_PROF_SETTINGS);
    if (!aowl_admin_readable(list, AOWL_UPP_LIST_SIZE + 4)) {
        aowl_region_sayf("unity post: %s profile.settings@0x18 does not read "
                         "back as a List -- refused (the List<T> layout here "
                         "is BORROWED, so this is a real possible outcome)",
                         origin);
        return 0;
    }
    arr  = *(const void * const *)((const unsigned char *)list +
                                   AOWL_UPP_LIST_ITEMS);
    size = *(const int32_t *)((const unsigned char *)list + AOWL_UPP_LIST_SIZE);
    if (size < 0 || size > AOWL_UPP_MAX_EFFECTS) {
        aowl_region_sayf("unity post: %s profile.settings._size reads %d, "
                         "outside 0..%d -- refused as implausible rather than "
                         "iterated", origin, (int)size, AOWL_UPP_MAX_EFFECTS);
        return 0;
    }
    if (!aowl_admin_readable(arr, AOWL_UPP_ARR_ELEM0 + 8 * (size ? size : 1)))
        return 0;

    for (i = 0; i < size && i < AOWL_UPP_MAX_EFFECTS; i++) {
        elem = *(const void * const *)((const unsigned char *)arr +
                                       AOWL_UPP_ARR_ELEM0 + 8 * i);
        if (!aowl_upp_identify(elem)) {
            aowl_region_sayf("unity post:   [%d] unidentifiable -- skipped",
                             (int)i);
            continue;
        }
        n++;
        {
            int32_t act = 0;
            if (aowl_admin_readable((const unsigned char *)elem +
                                    AOWL_UPP_SET_ACTIVE, 1))
                act = *((const unsigned char *)elem + AOWL_UPP_SET_ACTIVE);
            aowl_region_sayf("unity post:   [%d] %s  active=%d",
                             (int)i, aowl_comp_namebuf, (int)act);
        }
        /* ColorGrading is the one we intend to drive, so probe its params. */
        {
            const char *nm = aowl_comp_namebuf;
            int k = 0, match = 0;
            static const char *want =
                "UnityEngine.Rendering.PostProcessing.ColorGrading";
            while (want[k] && nm[k] && want[k] == nm[k]) k++;
            match = (want[k] == 0 && nm[k] == 0);
            if (match) {
                const void *sat, *pe;
                aowl_upp_have_cg = 1;
                if (aowl_admin_readable((const unsigned char *)elem +
                                        AOWL_UPP_CG_SATURATION, 8)) {
                    sat = *(const void * const *)((const unsigned char *)elem +
                                                  AOWL_UPP_CG_SATURATION);
                    aowl_upp_dump_param("ColorGrading.saturation@0xA8", sat);
                }
                if (aowl_admin_readable((const unsigned char *)elem +
                                        AOWL_UPP_CG_POSTEXPOSURE, 8)) {
                    pe = *(const void * const *)((const unsigned char *)elem +
                                                 AOWL_UPP_CG_POSTEXPOSURE);
                    aowl_upp_dump_param("ColorGrading.postExposure@0xB8", pe);
                }
            }
        }
    }
    return n;
}

/* THE BODY. No guard here -- the caller owns the one guard (rule 3). */
static void *aowl_upp_scan_body(void *unused) {
    void *cam, *layer, *vol, *prof;
    (void)unused;

    if (aowl_upp_done || aowl_upp_disabled) return (void*)1;

    cam = aowl_admin_cam_object();
    if (!cam) return (void*)1;            /* not in a raid yet; try again    */
    if (!aowl_upp_identify(cam)) return (void*)1;

    aowl_upp_bind();
    if (!aowl_upp_bind_ok) { aowl_upp_done = 1; return (void*)1; }

    /* Make the two argument strings ONCE (rule 7: no per-frame managed alloc).*/
    if (!aowl_upp_str_layer) {
        aowl_upp_str_layer = aowl_upp_strnew_fn("PostProcessLayer");
        aowl_upp_str_vol   = aowl_upp_strnew_fn("PostProcessVolume");
    }
    if (!aowl_upp_str_layer || !aowl_upp_str_vol) return (void*)1;

    /* NULL MethodInfo* is legal here: GetComponent(String) is a plain
     * non-generic instance method, not shared generic code. */
    layer = aowl_upp_getcomp_fn(cam, aowl_upp_str_layer, 0);
    vol   = aowl_upp_getcomp_fn(cam, aowl_upp_str_vol,   0);

    aowl_upp_done = 1;                    /* one verdict, then latch          */

    if (!aowl_upp_identify(layer)) {
        aowl_region_sayf(
            "unity post: the live camera carries NO PostProcessLayer that "
            "GetComponent(String) can name. The PPv2 assembly IS present in "
            "this build (118 types in UnityEngine.Rendering.PostProcessing, "
            "measured offline), so this is an INCONCLUSIVE result about THIS "
            "camera, not evidence the stack is absent. The D3D11 Present path "
            "stays in charge.");
    } else {
        aowl_region_sayf("unity post: camera carries a live '%s'",
                         aowl_comp_namebuf);
    }

    if (!aowl_upp_identify(vol)) {
        aowl_region_sayf(
            "unity post: no PostProcessVolume on the camera object itself. "
            "PPv2 volumes are normally separate GameObjects found by "
            "PostProcessManager, so this is expected and NOT a failure; the "
            "next step is to reach the volume list through the layer.");
        return (void*)1;
    }
    aowl_region_sayf("unity post: camera carries a live '%s'",
                     aowl_comp_namebuf);

    if (aowl_admin_readable((const unsigned char *)vol +
                            AOWL_UPP_VOL_WEIGHT, 8)) {
        aowl_region_sayf("unity post: volume weight=%.3f priority=%.3f "
                         "isGlobal=%d",
            (double)*(const float *)((const unsigned char *)vol +
                                     AOWL_UPP_VOL_WEIGHT),
            (double)*(const float *)((const unsigned char *)vol +
                                     AOWL_UPP_VOL_PRIORITY),
            (int)*((const unsigned char *)vol + AOWL_UPP_VOL_ISGLOBAL));
    }

    prof = 0;
    if (aowl_admin_readable((const unsigned char *)vol +
                            AOWL_UPP_VOL_SHAREDPROFILE, 8))
        prof = *(void * const *)((const unsigned char *)vol +
                                 AOWL_UPP_VOL_SHAREDPROFILE);
    if (prof) aowl_upp_found += aowl_upp_walk_profile(prof, "shared");

    prof = 0;
    if (aowl_admin_readable((const unsigned char *)vol +
                            AOWL_UPP_VOL_INTERNALPROFILE, 8))
        prof = *(void * const *)((const unsigned char *)vol +
                                 AOWL_UPP_VOL_INTERNALPROFILE);
    if (prof) aowl_upp_found += aowl_upp_walk_profile(prof, "internal");

    aowl_region_sayf(
        "unity post: SURVEY COMPLETE -- %d effect settings object(s) named by "
        "their own klass, ColorGrading reached = %s. This is a READ-ONLY "
        "survey; nothing was written, because ParameterOverride<T>.value is an "
        "instantiated-generic offset that cannot be derived offline.",
        (int)aowl_upp_found, aowl_upp_have_cg ? "YES" : "no");
    return (void*)1;
}

static void aowl_upp_tick(void) {
    void *ok;
    if (aowl_upp_disabled || aowl_upp_done) return;
    if (aowl_upp_ticks < 1000000) aowl_upp_ticks++;

    ok = aowl_p_p_seh((void*)aowl_upp_scan_body, (void*)0);   /* THE guard */
    if (ok == 0) {
        if (aowl_upp_faults < 1000000) aowl_upp_faults++;
        if (aowl_upp_faults >= AOWL_UPP_MAXFAULT) {
            aowl_upp_disabled = 1;
            aowl_region_sayf(
                "unity post: DISABLED after %d faulting surveys. The D3D11 "
                "Present grading path is unaffected and stays in charge.",
                AOWL_UPP_MAXFAULT);
        }
    }
}

#endif /* AOWLSPT_UNITYPP_H */
