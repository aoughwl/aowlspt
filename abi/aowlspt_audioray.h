/* aowlspt_audioray.h -- RAYTRACED AUDIO ("soundfx"), the pure-C half.
 *
 * WHAT THIS IS. A native<->native FFI binding of Vercidium Audio v1.7.0
 * (`vaudionative.dll`, a C ABI raytracing SDK) plus a bounded main-thread pump
 * and one occlusion query. It computes acoustic OCCLUSION -- a low-pass gain
 * pair (LF, HF) in [0,1] -- and EAX reverb parameters. IT DOES NOT PLAY AUDIO
 * and it does not touch the game's mixer; applying the result to EFT's own
 * audio is a separate, still-BLOCKED track (see `docs/AUDIORAY_RVA.md`).
 *
 * WHY NATIVE AND NOT THE C# WRAPPER. The shipped SDK also has a managed
 * wrapper. Using it would mean going through the IL2CPP export surface, which
 * on this build is token-gated and whose failure mode is a plausible random
 * uint64 rather than NULL. `LoadLibraryA` + `GetProcAddress` on a plain
 * KERNEL32-only DLL sidesteps that entirely: nothing here resolves an IL2CPP
 * name, calls an `il2cpp_*` export, installs a detour, or dereferences a game
 * pointer.
 *
 * SO THE EIGHT LIVE-PATH RULES LAND LIKE THIS:
 *   1. prologue byte-verify -- N/A. There is no game RVA here and no detour.
 *      The equivalent honesty check is `aowl_ar_bind`: every symbol is resolved
 *      by name and a SINGLE missing one refuses the whole feature by name,
 *      rather than leaving a NULL pointer to be called later.
 *   2. VirtualQuery every hop -- `aowl_is_readable` on the one pointer vaudio
 *      hands back that we dereference (`VALowPassFilter*`, 8 bytes), and on the
 *      module base before any call. vaudio's own handles are opaque and are
 *      never dereferenced by us.
 *   3. ONE `aowl_p_p_seh`, never nested. Taken by the Nim caller around
 *      `aowl_ar_tick_g` / `aowl_ar_occlusion_g`; NOTHING inside this file opens
 *      a second one. The `_g` suffix marks "must be called through the guard".
 *   4. Capped iteration. The pair cache is a fixed array; the pump does at most
 *      AOWL_AR_UPDATES_PER_TICK `vaWorldUpdate` calls per frame; the smoke test
 *      has a hard tick deadline and stops itself.
 *   5. Flag-gated, default OFF (`audioRay` in `aowlspt-host.json`).
 *   6. Self-disable after AOWL_AR_FAULT_BUDGET faults, latched and logged.
 *   7. No per-frame managed allocation -- no managed anything. All state is
 *      static; the only heap allocation is vaudio's own, at world/emitter
 *      creation, which happens once.
 *   8. Never blind-write. Every vaudio call's VAResult is checked and the first
 *      failing one latches an error code that the verdict prints.
 *
 * THE SMOKE TEST IS FALSIFIABLE, which is the point of it. It builds a world
 * with a concrete slab standing BETWEEN a source emitter and a listener
 * emitter, and a second source with NO slab between it and the listener. The
 * verdict is a comparison, not a self-report:
 *
 *     PASS   iff  blocked.gainHF < clear.gainHF - AOWL_AR_SMOKE_MARGIN
 *                 and both gains are finite and in [0,1]
 *     FAIL   iff  both filters read back but the wall made no difference
 *     INCONCLUSIVE iff either filter is still NULL at the deadline (vaudio
 *                 returns NULL until that pair has actually been raytraced),
 *                 with the last VAResult printed.
 *
 * A test that only asserted "the filter pointer is non-NULL" could not fail for
 * the reason we care about -- an empty world returns a perfectly valid filter
 * of (1.0, 1.0) forever. The wall is the negative control.
 *
 * WHAT THE OFFLINE HARNESS ALREADY MEASURED, so nobody repeats it. The whole
 * of this file was run against the real `vaudionative.dll` in a standalone
 * console process (no game, no IL2CPP), and the FFI is PROVEN: it arms, reports
 * "vaudio 1.7.0 production=1", accepts 3 emitters and the prism, and pumps
 * hundreds of `vaWorldUpdate` passes with zero faults. Rays ARE cast --
 * `vaWorldGetRaysCastThisFrame` reads 224 once an emitter MOVES (it reads 0 in
 * steady state, so vaudio evidently re-raytraces on movement, not every pump),
 * and the returned gains track distance: 0.9979 at 12m, 0.9977 at 13m.
 *
 * WHAT DOES NOT WORK YET, stated as the measurement and NOT as a cause: the
 * concrete slab makes NO difference. Blocked and clear read byte-identical
 * (LF=0.9979 HF=0.9943) at every sample, which is plain air absorption. Ruled
 * OUT by direct probe, each one measured rather than assumed:
 *   - the matrix layout is right (`vaMatrixCreateTranslation(1,2,3)` puts the
 *     translation at indices 12,13,14, exactly as `aowl_ar_translation` does);
 *   - the prism IS in the world (re-adding returns VA_ALREADY_EXISTS);
 *   - its transform reads back as translate(-6,0,0) and its size as
 *     (0.4, 8, 8), material 3 = concrete, i.e. squarely between the two;
 *   - the source has occlusionEnabled=1, 32 rays, castsAnyRays=1, is within
 *     world bounds, and neither world nor emitter is still initialising;
 *   - setting permeation rays/bounces to 32/4 changes nothing.
 * So the geometry reaches the world but not the occlusion result. The next
 * thing to try is the SDK's own C# 3d sample, to see what call this is missing;
 * do NOT guess further from the header.
 *
 * THE LICENCE. Vercidium Audio is licensed, not sold, and clause 5.1(c) of the
 * EULA forbids making "any library, binary, file or component of it available
 * as a standalone file or in any form outside an integrated, compiled Game or
 * Application build". Dropping `vaudionative.dll` next to the host DLL in the
 * install directory is exactly that. SO THIS FILE NEVER SHIPS THE DLL. It reads
 * a user-supplied path and refuses, loudly and by name, when it is absent. See
 * `aowl_ar_init`.
 */
#ifndef AOWLSPT_AUDIORAY_H
#define AOWLSPT_AUDIORAY_H

#include <stdint.h>
#include <string.h>
#include <math.h>

/* ------------------------------------------------------------------ tuning */

#define AOWL_AR_FAULT_BUDGET      8      /* faults before permanent disable   */
#define AOWL_AR_UPDATES_PER_TICK  1      /* vaWorldUpdate calls per frame     */
#define AOWL_AR_SMOKE_TICKS       1800   /* ~3 min at 10fps, then give up     */
#define AOWL_AR_SMOKE_MARGIN      0.02f  /* min HF gain drop to call it PASS  */
#define AOWL_AR_CACHE_SLOTS       128    /* occlusion pair cache, fixed       */
#define AOWL_AR_CACHE_TTL_TICKS   30     /* re-query a pair at most this often */
#define AOWL_AR_QUANT             0.5f   /* metres; cache key quantisation    */

/* ------------------------------------------------------------ the vaudio ABI
 *
 * Declared here rather than by including the SDK's `vaudio.h`: that header is
 * 131KB, uses C11 `_Generic` dispatch macros we do not want, and is the
 * licensor's file. These are the exact prototypes from
 * `3d/native/include/vaudio.h` v1.7.0 for the 26 entry points we use.
 *
 * ABI NOTE, load-bearing: `VAVector` is 12 bytes, so under the Win64 ABI it is
 * passed BY HIDDEN REFERENCE, and `VAMatrix` is 64 bytes so it is RETURNED via
 * a caller-provided sret buffer. Declaring the prototypes faithfully is what
 * makes gcc emit the right thing; hand-rolling a `void*` thunk here would get
 * both wrong silently. */

typedef struct AowlVAVector { float x, y, z; } AowlVAVector;
typedef struct AowlVALowPass { float gainLF, gainHF; } AowlVALowPass;

#define AOWL_VA_SUCCESS        0
#define AOWL_VA_STILL_RUNNING  21
#define AOWL_VA_ALREADY_EXISTS 3

/* VACoordinateSystem, MEASURED from vaudio.h v1.7.0: Default=0, Blender=1,
 * Godot=2, Unity=3, Unreal=4.
 *
 * READ THE DOC COMMENT, not the enum name. `vaWorldSetCoordinateSystem` says it
 * is "Used when calculating listener-relative reverb directionality with
 * vaWorldCalculateListenerRelativePan()" -- it governs THAT ONE CALL and
 * nothing else. It does NOT re-interpret the positions handed to
 * `vaEmitterSetPosition` or to a primitive transform, which stay in vaudio's
 * internal right-handed Z-forward-negative space.
 *
 * So the earlier C#/BepInEx port's manual Z negation is STILL REQUIRED for every
 * position that crosses from Unity, and setting Unity mode here is NOT a
 * substitute for it. An earlier draft of this file asserted the opposite. Both
 * are needed and they cover different things: the flag fixes panning, the
 * negation fixes geometry. `aowl_ar_from_unity` below is the ONE place the
 * conversion happens, so it cannot be applied twice or forgotten once. */
#define AOWL_VA_COORD_UNITY    3

#define AOWL_VA_MAT_CONCRETE   3     /* VAMaterialConcrete */

typedef void  (*AowlVaGetVersion)(int*, int*, int*);
/* C `bool` RETURNS ARE ONE BYTE. MEASURED: declaring one of these as returning
 * `int` reads the undefined upper 24 bits of EAX -- a probe of
 * `vaEmitterGetCastsAnyRays` typed that way returned -1208820223 for what is a
 * true/false answer. `vaIsProduction` happened to come back as 1 and would have
 * hidden this indefinitely. Every bool-returning entry point below is typed
 * `unsigned char` and compared != 0. */
typedef unsigned char (*AowlVaIsProduction)(void);
typedef void* (*AowlVaWorldCreate)(void);
typedef int32_t (*AowlVaWorldDestroy)(void*);
typedef int32_t (*AowlVaWorldUpdate)(void*);
typedef int32_t (*AowlVaWorldSetCoordinateSystem)(void*, int);
typedef int32_t (*AowlVaWorldSetPosition)(void*, AowlVAVector);
typedef int32_t (*AowlVaWorldSetSize)(void*, AowlVAVector);
typedef int32_t (*AowlVaWorldAddEmitter)(void*, void*);
typedef int32_t (*AowlVaWorldAddPrimitive_)(void*, void*);
typedef int32_t (*AowlVaWorldSetPendingShutdown)(void*, int);
typedef unsigned char (*AowlVaWorldGetThreadsRunning)(const void*);
typedef unsigned char (*AowlVaWorldGetInitialising)(const void*);
typedef void* (*AowlVaEmitterCreate)(void);
typedef int32_t (*AowlVaEmitterDestroy)(void*);
typedef int32_t (*AowlVaEmitterSetPosition)(void*, AowlVAVector);
typedef int32_t (*AowlVaEmitterAddTarget)(void*, void*);
typedef void* (*AowlVaEmitterGetTargetFilter)(void*, void*);
typedef int32_t (*AowlVaEmitterSetOcclusionRayCount)(void*, int);
typedef int32_t (*AowlVaEmitterSetOcclusionBounceCount)(void*, int);
typedef int32_t (*AowlVaEmitterSetReverbRayCount)(void*, int);
typedef int32_t (*AowlVaEmitterSetReverbBounceCount)(void*, int);
typedef int32_t (*AowlVaEmitterSetHasRelativeReverb)(void*, int);
typedef int32_t (*AowlVaEmitterSetName)(void*, const char*);
typedef unsigned char (*AowlVaEmitterGetInitialising)(const void*);
typedef void* (*AowlVaPrismPrimitiveCreate)(void);
typedef int32_t (*AowlVaPrismPrimitiveSetSize)(void*, AowlVAVector);
typedef int32_t (*AowlVaPrismPrimitiveSetTransform)(void*, const void*);
typedef int32_t (*AowlVaPrismPrimitiveSetMaterial)(void*, int);

/* VAMatrix, 4x4 row-major floats. We only ever need a translation, so rather
 * than call `vaMatrixCreateTranslation` (a 64-byte struct return through a
 * function pointer -- correct, but one more ABI shape to get right for no gain)
 * we build the identity-plus-translation here. The layout is m11..m44 in
 * declaration order, and the SDK's own `vaMatrixCreateTranslation` writes the
 * offset into m41/m42/m43, which is what this mirrors. */
typedef struct AowlVAMatrix { float m[16]; } AowlVAMatrix;

static void aowl_ar_translation(AowlVAMatrix* out, float x, float y, float z) {
    memset(out, 0, sizeof(*out));
    out->m[0] = 1.0f; out->m[5] = 1.0f; out->m[10] = 1.0f; out->m[15] = 1.0f;
    out->m[12] = x;   out->m[13] = y;   out->m[14] = z;
}

/* ------------------------------------------------------------------- state */

typedef struct AowlArFns {
    AowlVaGetVersion                     getVersion;
    AowlVaIsProduction                   isProduction;
    AowlVaWorldCreate                    worldCreate;
    AowlVaWorldDestroy                   worldDestroy;
    AowlVaWorldUpdate                    worldUpdate;
    AowlVaWorldSetCoordinateSystem       worldSetCoord;
    AowlVaWorldSetPosition               worldSetPos;
    AowlVaWorldSetSize                   worldSetSize;
    AowlVaWorldAddEmitter                worldAddEmitter;
    AowlVaWorldAddPrimitive_             worldAddPrim;
    AowlVaWorldSetPendingShutdown        worldShutdown;
    AowlVaWorldGetThreadsRunning         worldThreads;
    AowlVaWorldGetInitialising           worldInit;
    AowlVaEmitterCreate                  emCreate;
    AowlVaEmitterDestroy                 emDestroy;
    AowlVaEmitterSetPosition             emSetPos;
    AowlVaEmitterAddTarget               emAddTarget;
    AowlVaEmitterGetTargetFilter         emGetFilter;
    AowlVaEmitterSetOcclusionRayCount    emOccRays;
    AowlVaEmitterSetOcclusionBounceCount emOccBounces;
    AowlVaEmitterSetReverbRayCount       emRevRays;
    AowlVaEmitterSetReverbBounceCount    emRevBounces;
    AowlVaEmitterSetHasRelativeReverb    emRelReverb;
    AowlVaEmitterSetName                 emSetName;
    AowlVaEmitterGetInitialising         emInit;
    AowlVaPrismPrimitiveCreate           prismCreate;
    AowlVaPrismPrimitiveSetSize          prismSetSize;
    AowlVaPrismPrimitiveSetTransform     prismSetXform;
    AowlVaPrismPrimitiveSetMaterial      prismSetMat;
} AowlArFns;

/* The occlusion pair cache. Fixed array, quantised key, TTL in ticks -- so a
 * caller may ask every frame for every bot without the pump seeing more than
 * one new pair per slot per TTL. A miss returns the LAST known value if the
 * slot is warm, and AOWL_AR_UNAVAILABLE if it has never been answered; it never
 * blocks and never allocates. */
typedef struct AowlArPair {
    int32_t used;
    int32_t kx, ky, kz, kex, key_, kez;   /* quantised listener/emitter */
    float   gainLF, gainHF;
    int64_t stamp;                        /* tick this was last refreshed */
    void*   src;                          /* the vaudio emitter for it    */
} AowlArPair;

typedef struct AowlAudioRay {
    int32_t   armed;          /* flag on AND bind succeeded                */
    int32_t   disabled;       /* latched: budget spent, or a hard refusal  */
    int32_t   faults;
    int32_t   bound;
    void*     dll;            /* HMODULE, kept as void* so the header is
                               * includable before <windows.h> ordering    */
    char      dllPath[512];
    char      missing[64];    /* the FIRST symbol that did not resolve     */
    int       verMajor, verMinor, verPatch;
    int32_t   production;

    void*     world;
    void*     listener;       /* vaudio has no "listener" type: the listener
                               * is simply another emitter used as a target */
    void*     srcBlocked;
    void*     srcClear;
    void*     slab;
    int32_t   worldReady;
    int32_t   lastResult;     /* last non-SUCCESS VAResult seen            */
    const char* lastCall;     /* which call produced it                    */

    int64_t   ticks;
    int64_t   updates;        /* vaWorldUpdate calls that returned SUCCESS */
    int32_t   smokeState;     /* 0 idle 1 running 2 done                   */
    int32_t   smokeVerdict;   /* 0 none 1 PASS 2 FAIL 3 INCONCLUSIVE       */
    float     smokeBlockedLF, smokeBlockedHF;
    float     smokeClearLF,   smokeClearHF;
    int32_t   smokeSawBlocked, smokeSawClear;

    int32_t   occRays, occBounces, revRays, revBounces, maxPairs;
    AowlArPair cache[AOWL_AR_CACHE_SLOTS];
    int32_t   pairsLive;
    int64_t   occQueries, occHits, occMisses;
} AowlAudioRay;

static AowlAudioRay g_ar;

#define AOWL_AR_UNAVAILABLE (-1.0f)

/* ------------------------------------------------------------- bookkeeping */

static void aowl_ar_note(int32_t r, const char* call) {
    if (r != AOWL_VA_SUCCESS && r != AOWL_VA_STILL_RUNNING &&
        r != AOWL_VA_ALREADY_EXISTS) {
        g_ar.lastResult = r;
        g_ar.lastCall   = call;
    }
}

static void aowl_ar_fault(void) {
    if (g_ar.disabled) return;
    if (++g_ar.faults >= AOWL_AR_FAULT_BUDGET) {
        g_ar.disabled = 1;
        g_ar.armed    = 0;
    }
}

static int32_t aowl_ar_finite01(float v) {
    /* A NaN compares false against everything, so this rejects it without a
     * separate isnan -- and rejecting is the point: a NaN gain propagated into
     * a bot's hearing radius would be a silently wrong sense, not a crash. */
    return (v >= 0.0f && v <= 1.0f) ? 1 : 0;
}

/* THE ONE resolved-function table. Defined before `aowl_ar_bind` so there is
 * exactly one of it: an earlier draft had bind filling a second `static` local
 * that nothing else could see, which is the silent-partial-bind failure this
 * whole all-or-nothing scheme exists to prevent. */
static AowlArFns g_ar_fns_store;
static AowlArFns* aowl_ar_fns(void) { return &g_ar_fns_store; }

/* ------------------------------------------------------------------- bind */

/* Resolve every entry point by name. ALL-OR-NOTHING on purpose: a partial bind
 * leaves a NULL function pointer that is called minutes later from inside a
 * guard, which reports as "audioray faulted" and names nothing. Here the first
 * absent symbol is recorded by name and the feature refuses before it has
 * created anything. */
static int32_t aowl_ar_bind(void) {
    HMODULE h = (HMODULE)g_ar.dll;
    AowlArFns* f = &g_ar_fns_store;
    memset(f, 0, sizeof(*f));

#define AOWL_AR_SYM(field, name, type)                                        \
    do {                                                                      \
        FARPROC p = GetProcAddress(h, name);                                  \
        if (!p) {                                                             \
            strncpy(g_ar.missing, name, sizeof(g_ar.missing) - 1);            \
            g_ar.missing[sizeof(g_ar.missing) - 1] = 0;                       \
            return 0;                                                         \
        }                                                                     \
        f->field = (type)(void*)p;                                            \
    } while (0)

    AOWL_AR_SYM(getVersion,   "vaGetVersion",     AowlVaGetVersion);
    AOWL_AR_SYM(isProduction, "vaIsProduction",   AowlVaIsProduction);
    AOWL_AR_SYM(worldCreate,  "vaWorldCreate",    AowlVaWorldCreate);
    AOWL_AR_SYM(worldDestroy, "vaWorldDestroy",   AowlVaWorldDestroy);
    AOWL_AR_SYM(worldUpdate,  "vaWorldUpdate",    AowlVaWorldUpdate);
    AOWL_AR_SYM(worldSetCoord,"vaWorldSetCoordinateSystem", AowlVaWorldSetCoordinateSystem);
    AOWL_AR_SYM(worldSetPos,  "vaWorldSetPosition", AowlVaWorldSetPosition);
    AOWL_AR_SYM(worldSetSize, "vaWorldSetSize",   AowlVaWorldSetSize);
    AOWL_AR_SYM(worldAddEmitter, "vaWorldAddEmitter", AowlVaWorldAddEmitter);
    AOWL_AR_SYM(worldAddPrim, "vaWorldAddPrimitive_", AowlVaWorldAddPrimitive_);
    AOWL_AR_SYM(worldShutdown,"vaWorldSetPendingShutdown", AowlVaWorldSetPendingShutdown);
    AOWL_AR_SYM(worldThreads, "vaWorldGetThreadsRunning", AowlVaWorldGetThreadsRunning);
    AOWL_AR_SYM(worldInit,    "vaWorldGetInitialising", AowlVaWorldGetInitialising);
    AOWL_AR_SYM(emCreate,     "vaEmitterCreate",  AowlVaEmitterCreate);
    AOWL_AR_SYM(emDestroy,    "vaEmitterDestroy", AowlVaEmitterDestroy);
    AOWL_AR_SYM(emSetPos,     "vaEmitterSetPosition", AowlVaEmitterSetPosition);
    AOWL_AR_SYM(emAddTarget,  "vaEmitterAddTarget", AowlVaEmitterAddTarget);
    AOWL_AR_SYM(emGetFilter,  "vaEmitterGetTargetFilter", AowlVaEmitterGetTargetFilter);
    AOWL_AR_SYM(emOccRays,    "vaEmitterSetOcclusionRayCount", AowlVaEmitterSetOcclusionRayCount);
    AOWL_AR_SYM(emOccBounces, "vaEmitterSetOcclusionBounceCount", AowlVaEmitterSetOcclusionBounceCount);
    AOWL_AR_SYM(emRevRays,    "vaEmitterSetReverbRayCount", AowlVaEmitterSetReverbRayCount);
    AOWL_AR_SYM(emRevBounces, "vaEmitterSetReverbBounceCount", AowlVaEmitterSetReverbBounceCount);
    AOWL_AR_SYM(emRelReverb,  "vaEmitterSetHasRelativeReverb", AowlVaEmitterSetHasRelativeReverb);
    AOWL_AR_SYM(emSetName,    "vaEmitterSetName", AowlVaEmitterSetName);
    AOWL_AR_SYM(emInit,       "vaEmitterGetInitialising", AowlVaEmitterGetInitialising);
    AOWL_AR_SYM(prismCreate,  "vaPrismPrimitiveCreate", AowlVaPrismPrimitiveCreate);
    AOWL_AR_SYM(prismSetSize, "vaPrismPrimitiveSetSize", AowlVaPrismPrimitiveSetSize);
    AOWL_AR_SYM(prismSetXform,"vaPrismPrimitiveSetTransform", AowlVaPrismPrimitiveSetTransform);
    AOWL_AR_SYM(prismSetMat,  "vaPrismPrimitiveSetMaterial", AowlVaPrismPrimitiveSetMaterial);
#undef AOWL_AR_SYM

    g_ar.bound = 1;
    return 1;
}

/* ------------------------------------------------------------------- init */

/* `path` is the FULL path to `vaudionative.dll`, supplied by the user through
 * `audioRayDllPath` in `aowlspt-host.json`. There is deliberately NO fallback
 * that ships the DLL: see the licence note at the top of this file.
 *
 * Returns: 1 armed, 0 refused. `aowl_ar_refusal()` says which of the four
 * refusals it was, by name, always -- an audio feature that declines silently
 * is indistinguishable from one that is working on a map with no walls. */
static int32_t aowl_ar_init(const char* path, int occRays, int occBounces,
                            int revRays, int revBounces, int maxPairs) {
    memset(&g_ar, 0, sizeof(g_ar));
    g_ar.occRays    = occRays;
    g_ar.occBounces = occBounces;
    g_ar.revRays    = revRays;
    g_ar.revBounces = revBounces;
    g_ar.maxPairs   = maxPairs;
    g_ar.lastCall   = "";

    if (!path || !path[0]) return 0;              /* refusal: no path set     */
    strncpy(g_ar.dllPath, path, sizeof(g_ar.dllPath) - 1);

    g_ar.dll = (void*)LoadLibraryA(g_ar.dllPath);
    if (!g_ar.dll) return 0;                      /* refusal: not loadable    */
    if (!aowl_is_readable(g_ar.dll, 64)) {        /* rule 2, before any call  */
        g_ar.dll = 0;
        return 0;
    }
    if (!aowl_ar_bind()) return 0;                /* refusal: names g_ar.missing */

    {
        AowlArFns* f = aowl_ar_fns();
        f->getVersion(&g_ar.verMajor, &g_ar.verMinor, &g_ar.verPatch);
        g_ar.production = (f->isProduction() != 0) ? 1 : 0;
    }
    /* A version read that returns 0.0.0 means we resolved something that is not
     * this SDK -- refuse rather than build a world on it. */
    if (g_ar.verMajor == 0 && g_ar.verMinor == 0 && g_ar.verPatch == 0) {
        strncpy(g_ar.missing, "vaGetVersion returned 0.0.0",
                sizeof(g_ar.missing) - 1);
        return 0;
    }
    g_ar.armed = 1;
    return 1;
}

/* 0 armed, 1 no path configured, 2 LoadLibrary failed, 3 a symbol is missing,
 * 4 self-disabled after the fault budget. Never "something went wrong". */
static int32_t aowl_ar_refusal(void) {
    if (g_ar.disabled)      return 4;
    if (g_ar.armed)         return 0;
    if (!g_ar.dllPath[0])   return 1;
    if (!g_ar.dll)          return 2;
    return 3;
}
static const char* aowl_ar_missing(void)  { return g_ar.missing; }
static const char* aowl_ar_dllpath(void)  { return g_ar.dllPath; }
static int32_t aowl_ar_ver_major(void)    { return g_ar.verMajor; }
static int32_t aowl_ar_ver_minor(void)    { return g_ar.verMinor; }
static int32_t aowl_ar_ver_patch(void)    { return g_ar.verPatch; }
static int32_t aowl_ar_production(void)   { return g_ar.production; }
static int32_t aowl_ar_armed(void)        { return g_ar.armed; }
static int32_t aowl_ar_faults(void)       { return g_ar.faults; }
static int64_t aowl_ar_ticks(void)        { return g_ar.ticks; }
static int64_t aowl_ar_updates(void)      { return g_ar.updates; }
static int32_t aowl_ar_last_result(void)  { return g_ar.lastResult; }
static const char* aowl_ar_last_call(void){ return g_ar.lastCall ? g_ar.lastCall : ""; }
static int32_t aowl_ar_smoke_state(void)  { return g_ar.smokeState; }
static int32_t aowl_ar_smoke_verdict(void){ return g_ar.smokeVerdict; }
static int32_t aowl_ar_smoke_blocked_lf(void){ return (int32_t)(g_ar.smokeBlockedLF * 1000.0f); }
static int32_t aowl_ar_smoke_blocked_hf(void){ return (int32_t)(g_ar.smokeBlockedHF * 1000.0f); }
static int32_t aowl_ar_smoke_clear_lf(void)  { return (int32_t)(g_ar.smokeClearLF   * 1000.0f); }
static int32_t aowl_ar_smoke_clear_hf(void)  { return (int32_t)(g_ar.smokeClearHF   * 1000.0f); }
static int32_t aowl_ar_pairs_live(void)   { return g_ar.pairsLive; }
static int64_t aowl_ar_occ_queries(void)  { return g_ar.occQueries; }
static int64_t aowl_ar_occ_hits(void)     { return g_ar.occHits; }
static int64_t aowl_ar_occ_misses(void)   { return g_ar.occMisses; }

/* ------------------------------------------------------------- the world */

static AowlVAVector aowl_ar_v(float x, float y, float z) {
    AowlVAVector v; v.x = x; v.y = y; v.z = z; return v;
}

/* Unity (left-handed, +Z forward) -> vaudio internal (right-handed, -Z forward).
 * Negate Z, nothing else. THE ONLY conversion site: the smoke world is authored
 * directly in vaudio space and does not pass through here, so a reader can tell
 * at a glance which coordinates a call is in by whether it went through this. */
static AowlVAVector aowl_ar_from_unity(float x, float y, float z) {
    AowlVAVector v; v.x = x; v.y = y; v.z = -z; return v;
}

static void* aowl_ar_make_emitter(const char* name, int32_t castsRays) {
    AowlArFns* f = aowl_ar_fns();
    void* e = f->emCreate();
    if (!e) return 0;
    f->emSetName(e, name);
    if (castsRays) {
        aowl_ar_note(f->emOccRays(e, g_ar.occRays),       "SetOcclusionRayCount");
        aowl_ar_note(f->emOccBounces(e, g_ar.occBounces), "SetOcclusionBounceCount");
        aowl_ar_note(f->emRevRays(e, g_ar.revRays),       "SetReverbRayCount");
        aowl_ar_note(f->emRevBounces(e, g_ar.revBounces), "SetReverbBounceCount");
        aowl_ar_note(f->emRelReverb(e, 1),                "SetHasRelativeReverb");
    } else {
        /* The listener casts nothing: sources raytrace TOWARDS it. */
        aowl_ar_note(f->emOccRays(e, 0), "SetOcclusionRayCount(listener)");
        aowl_ar_note(f->emRevRays(e, 0), "SetReverbRayCount(listener)");
    }
    aowl_ar_note(f->worldAddEmitter(g_ar.world, e), "vaWorldAddEmitter");
    return e;
}

/* Build the smoke world: a 200m cube, a listener at the origin, a source 12m
 * to the -X with a 6x6x0.4m concrete slab halfway between them, and a second
 * source 12m to the +X with nothing in the way. Two sources rather than one
 * because a single reading cannot be falsified -- see the header note. */
static int32_t aowl_ar_world_build(void) {
    AowlArFns* f = aowl_ar_fns();
    AowlVAMatrix xf;

    g_ar.world = f->worldCreate();
    if (!g_ar.world) return 0;

    aowl_ar_note(f->worldSetCoord(g_ar.world, AOWL_VA_COORD_UNITY),
                 "vaWorldSetCoordinateSystem");
    aowl_ar_note(f->worldSetPos(g_ar.world, aowl_ar_v(-100.0f, -100.0f, -100.0f)),
                 "vaWorldSetPosition");
    aowl_ar_note(f->worldSetSize(g_ar.world, aowl_ar_v(200.0f, 200.0f, 200.0f)),
                 "vaWorldSetSize");

    g_ar.listener   = aowl_ar_make_emitter("aowl-listener", 0);
    g_ar.srcBlocked = aowl_ar_make_emitter("aowl-smoke-blocked", 1);
    g_ar.srcClear   = aowl_ar_make_emitter("aowl-smoke-clear",   1);
    if (!g_ar.listener || !g_ar.srcBlocked || !g_ar.srcClear) return 0;

    aowl_ar_note(f->emSetPos(g_ar.listener,   aowl_ar_v(  0.0f, 0.0f, 0.0f)), "emSetPos(listener)");
    aowl_ar_note(f->emSetPos(g_ar.srcBlocked, aowl_ar_v(-12.0f, 0.0f, 0.0f)), "emSetPos(blocked)");
    aowl_ar_note(f->emSetPos(g_ar.srcClear,   aowl_ar_v( 12.0f, 0.0f, 0.0f)), "emSetPos(clear)");

    /* THE NEGATIVE CONTROL. The slab sits at x = -6, between the blocked source
     * and the listener, and nowhere near the clear one. If the two sources come
     * back with the same gain, this feature is not simulating anything. */
    g_ar.slab = f->prismCreate();
    if (!g_ar.slab) return 0;
    aowl_ar_note(f->prismSetSize(g_ar.slab, aowl_ar_v(0.4f, 8.0f, 8.0f)),
                 "vaPrismPrimitiveSetSize");
    aowl_ar_translation(&xf, -6.0f, 0.0f, 0.0f);
    aowl_ar_note(f->prismSetXform(g_ar.slab, &xf), "vaPrismPrimitiveSetTransform");
    aowl_ar_note(f->prismSetMat(g_ar.slab, AOWL_VA_MAT_CONCRETE),
                 "vaPrismPrimitiveSetMaterial");
    aowl_ar_note(f->worldAddPrim(g_ar.world, g_ar.slab), "vaWorldAddPrimitive");

    /* Targets last: vaEmitterAddTarget returns VA_NOT_ADDED_TO_WORLD unless
     * both emitters are already in the same world, and VA_FEATURE_DISABLED
     * unless the caster has a non-zero ray count. Both are set above. */
    aowl_ar_note(f->emAddTarget(g_ar.srcBlocked, g_ar.listener), "emAddTarget(blocked)");
    aowl_ar_note(f->emAddTarget(g_ar.srcClear,   g_ar.listener), "emAddTarget(clear)");

    g_ar.worldReady = 1;
    g_ar.smokeState = 1;
    return 1;
}

/* Read one pair's filter. Returns 1 and fills lf/hf only when vaudio has
 * actually raytraced the pair AND the eight bytes it points at are readable AND
 * both gains are finite and in range. Three outcomes, never two: 0 here means
 * "not answered yet", not "no occlusion". */
static int32_t aowl_ar_read_filter(void* src, void* dst, float* lf, float* hf) {
    AowlArFns* f = aowl_ar_fns();
    void* p;
    AowlVALowPass v;
    if (!src || !dst) return 0;
    p = f->emGetFilter(src, dst);
    if (!p) return 0;                                   /* not raytraced yet */
    if (!aowl_is_readable(p, (int32_t)sizeof(v))) return 0;
    memcpy(&v, p, sizeof(v));
    if (!aowl_ar_finite01(v.gainLF) || !aowl_ar_finite01(v.gainHF)) return 0;
    /* MEASURED, and the reason this check exists: vaudio returns a NON-NULL
     * filter pointer as soon as the pair is registered, whose contents are
     * still all-zero until a raytracing pass has actually completed. An earlier
     * revision accepted that, read (0.000, 0.000) for BOTH sources on the very
     * first tick, and reported FAIL -- a verdict about our own impatience
     * dressed up as a measurement.
     *
     * An exact double zero is not a physical answer for a source with line of
     * sight, so it is treated as "not answered yet" and the caller keeps
     * waiting. This deliberately makes the deadline reachable -- INCONCLUSIVE
     * is the correct verdict for "vaudio never finished", and it is a verdict
     * this function can now actually produce. */
    if (v.gainLF == 0.0f && v.gainHF == 0.0f) return 0;
    *lf = v.gainLF; *hf = v.gainHF;
    return 1;
}

/* ------------------------------------------------------------- the pump
 *
 * CALL THROUGH `aowl_p_p_seh` ONLY -- the `_g` suffix. Bounded: at most
 * AOWL_AR_UPDATES_PER_TICK `vaWorldUpdate` calls, which is the entire per-frame
 * cost on the main thread (vaudio does the raytracing on its own background
 * threads and `vaWorldUpdate` returns VA_STILL_RUNNING while they work). */
static void* aowl_ar_tick_g(void* unused) {
    AowlArFns* f = aowl_ar_fns();
    int i;
    (void)unused;
    if (!g_ar.armed || g_ar.disabled) return 0;

    if (!g_ar.worldReady) {
        if (!aowl_ar_world_build()) { aowl_ar_fault(); return 0; }
    }
    g_ar.ticks++;

    for (i = 0; i < AOWL_AR_UPDATES_PER_TICK; i++) {
        int32_t r = f->worldUpdate(g_ar.world);
        if (r == AOWL_VA_SUCCESS) g_ar.updates++;
        else aowl_ar_note(r, "vaWorldUpdate");
    }

    /* The smoke test, while it is running. It reads the two filters and stops
     * itself the moment BOTH have been answered, or at the tick deadline. */
    if (g_ar.smokeState == 1) {
        float lf, hf;
        if (!g_ar.smokeSawBlocked &&
            aowl_ar_read_filter(g_ar.srcBlocked, g_ar.listener, &lf, &hf)) {
            g_ar.smokeBlockedLF = lf; g_ar.smokeBlockedHF = hf;
            g_ar.smokeSawBlocked = 1;
        }
        if (!g_ar.smokeSawClear &&
            aowl_ar_read_filter(g_ar.srcClear, g_ar.listener, &lf, &hf)) {
            g_ar.smokeClearLF = lf; g_ar.smokeClearHF = hf;
            g_ar.smokeSawClear = 1;
        }
        if (g_ar.smokeSawBlocked && g_ar.smokeSawClear) {
            g_ar.smokeState = 2;
            /* PASS requires the WALL to have made a measurable difference.
             * Equal gains is FAIL, not PASS: an empty world answers (1,1)
             * forever and would otherwise read as success. */
            g_ar.smokeVerdict =
                (g_ar.smokeBlockedHF < g_ar.smokeClearHF - AOWL_AR_SMOKE_MARGIN)
                ? 1 : 2;
        } else if (g_ar.ticks > AOWL_AR_SMOKE_TICKS) {
            g_ar.smokeState   = 2;
            g_ar.smokeVerdict = 3;      /* INCONCLUSIVE -- could not look     */
        }
    }
    return 0;
}

/* ------------------------------------------ Phase 1: the occlusion query
 *
 * `aowl_audio_occlusion_g` answers "how much of a sound at `e` reaches a
 * listener at `l`", as a gain in [0,1], or AOWL_AR_UNAVAILABLE when it does not
 * know. It is a CACHE READ plus at most one emitter creation; it never pumps
 * and never blocks, so a caller may ask once per bot per frame.
 *
 * WHAT IT CANNOT DO TODAY, stated here rather than discovered later: the vaudio
 * world this queries contains only the smoke geometry. Feeding EFT's map
 * colliders into it is unbuilt, so in a real raid every pair is unoccluded and
 * this returns 1.0. It therefore returns AOWL_AR_UNAVAILABLE unless
 * `g_ar.geometryFed` is set, which nothing sets yet -- a wrong number delivered
 * confidently is worse than a refusal. */
static int32_t g_ar_geometry_fed = 0;

static int32_t aowl_ar_q(float v) {
    return (int32_t)floorf(v / AOWL_AR_QUANT);
}

typedef struct AowlArQuery {
    float lx, ly, lz, ex, ey, ez;
    float out;
} AowlArQuery;

static void* aowl_audio_occlusion_g(void* arg) {
    AowlArQuery* q = (AowlArQuery*)arg;
    AowlArFns* f = aowl_ar_fns();
    int32_t kx, ky, kz, ex, ey, ez;
    int i, freeSlot = -1;

    if (!q) return 0;
    q->out = AOWL_AR_UNAVAILABLE;
    if (!g_ar.armed || g_ar.disabled || !g_ar.worldReady) return 0;
    if (!g_ar_geometry_fed) return 0;      /* honest refusal, see above */

    g_ar.occQueries++;
    /* The listener emitter follows the caller's listener. Unity coordinates in,
     * converted once, here. */
    aowl_ar_note(f->emSetPos(g_ar.listener,
                             aowl_ar_from_unity(q->lx, q->ly, q->lz)),
                 "emSetPos(listener)");
    kx = aowl_ar_q(q->lx); ky = aowl_ar_q(q->ly); kz = aowl_ar_q(q->lz);
    ex = aowl_ar_q(q->ex); ey = aowl_ar_q(q->ey); ez = aowl_ar_q(q->ez);

    for (i = 0; i < AOWL_AR_CACHE_SLOTS; i++) {     /* capped, rule 4 */
        AowlArPair* p = &g_ar.cache[i];
        if (!p->used) { if (freeSlot < 0) freeSlot = i; continue; }
        if (p->kx != kx || p->ky != ky || p->kz != kz ||
            p->kex != ex || p->key_ != ey || p->kez != ez) continue;
        /* Warm slot. Refresh from vaudio at most once per TTL; between
         * refreshes hand back the last measured value rather than re-reading,
         * so the cost of asking every frame is one array scan. */
        if (g_ar.ticks - p->stamp >= AOWL_AR_CACHE_TTL_TICKS) {
            float lf, hf;
            if (aowl_ar_read_filter(p->src, g_ar.listener, &lf, &hf)) {
                p->gainLF = lf; p->gainHF = hf; p->stamp = g_ar.ticks;
            }
        }
        g_ar.occHits++;
        /* ONE scalar for a caller that wants one: the HF gain, which is what
         * "muffled" means perceptually and what the low-pass model uses. */
        q->out = p->gainHF;
        return 0;
    }

    /* Cold pair. Register it so a later frame can answer, and refuse THIS
     * frame -- creating an emitter and reading its filter in the same frame
     * would read NULL and we would have to invent a number. */
    g_ar.occMisses++;
    if (freeSlot < 0 || g_ar.pairsLive >= g_ar.maxPairs) return 0;
    {
        AowlArPair* p = &g_ar.cache[freeSlot];
        void* src = aowl_ar_make_emitter("aowl-src", 1);
        if (!src) { aowl_ar_fault(); return 0; }
        aowl_ar_note(f->emSetPos(src, aowl_ar_from_unity(q->ex, q->ey, q->ez)),
                     "emSetPos(pair)");
        aowl_ar_note(f->emAddTarget(src, g_ar.listener), "emAddTarget(pair)");
        p->used = 1; p->src = src;
        p->kx = kx; p->ky = ky; p->kz = kz;
        p->kex = ex; p->key_ = ey; p->kez = ez;
        p->gainLF = 1.0f; p->gainHF = 1.0f; p->stamp = -AOWL_AR_CACHE_TTL_TICKS;
        g_ar.pairsLive++;
    }
    return 0;
}

/* THE MOD-FACING EXPORT. One `aowl_p_p_seh` is taken HERE and nowhere inside,
 * because a mod calling this is not already inside the host's guard. Returns
 * a gain in [0,1], or -1.0 meaning "no answer" -- which a caller must treat as
 * "fall back", never as "fully occluded". */
#define AOWL_AR_EXPORT __declspec(dllexport)
AOWL_AR_EXPORT float aowl_audio_occlusion(float lx, float ly, float lz,
                                          float ex, float ey, float ez) {
    AowlArQuery q;
    q.lx = lx; q.ly = ly; q.lz = lz;
    q.ex = ex; q.ey = ey; q.ez = ez;
    q.out = AOWL_AR_UNAVAILABLE;
    if (!g_ar.armed || g_ar.disabled) return AOWL_AR_UNAVAILABLE;
    aowl_p_p_seh((void*)aowl_audio_occlusion_g, &q);
    if (!aowl_ar_finite01(q.out)) return AOWL_AR_UNAVAILABLE;
    return q.out;
}

/* Whether the export will ever answer. A mod resolves this FIRST and logs which
 * path it took, so "sain used its scalar" and "sain used raytraced occlusion"
 * are distinguishable in the log rather than inferred. */
AOWL_AR_EXPORT int32_t aowl_audio_occlusion_ready(void) {
    return (g_ar.armed && !g_ar.disabled && g_ar.worldReady &&
            g_ar_geometry_fed) ? 1 : 0;
}

/* The guarded entry the Nim tick calls. Exactly one guard, here. */
static void aowl_ar_tick(void) {
    if (!g_ar.armed || g_ar.disabled) return;
    aowl_p_p_seh((void*)aowl_ar_tick_g, 0);
}

#endif /* AOWLSPT_AUDIORAY_H */
