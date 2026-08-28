/* aowlspt_scene.h -- the LIVE SCENE surface, native half.
 *
 * ===========================================================================
 * WHAT THIS IS
 * ===========================================================================
 *
 * The guarded native primitives beneath `aowlscene.nim`, the "talk to the
 * running Unity scene" library that the UI framework and mods build on. It adds
 * NOTHING to the calling-convention story that `aowlspt_invoke2.h` and
 * `aowlspt_nativeui.h` already proved -- it REUSES their machinery (the shaped
 * call thunks, the byte-verify discipline, the SEH guard from shim.h) and adds
 * the small, verified set of Transform-hierarchy and Component RVAs a scene API
 * needs, plus the liveness / typed-field / struct-decode / sharedness helpers.
 *
 * Every RVA below was resolved OFFLINE against build 1.1.0.1.46777
 * (GameAssembly.dll imagebase 0x180000000) with `tools/il2cpp_resolve.py`
 * (`type UnityEngine.Transform` / `UnityEngine.Component`, then `bytes <rva>`
 * for the 16 prologue bytes), the same resolver+ground-truth path that produced
 * `abi/aowlspt_invoke2.h`. The 16 prologue bytes are re-verified at runtime,
 * exactly as `aowl_mi2_fn` does, so a stale RVA on any other build simply
 * yields NULL and every call declines.
 *
 * NOTHING here calls anything on its own. It is a table, a set of thunks and a
 * set of pure helpers; `host/Aowlspt.Host.Il2Cpp/aowlscene.nim` drives it, from
 * inside a proven Unity-thread context, under ONE non-nested `aowl_p_p_seh`.
 * ===========================================================================
 */
#ifndef AOWLSPT_SCENE_H
#define AOWLSPT_SCENE_H

/* shim.h brings <windows.h>, aowl_is_readable (the VirtualQuery gate every hop
 * goes through) and aowl_p_p_seh (the ONE, non-re-entrant guard). invoke2.h
 * brings the proven target table + shaped call thunks + il2cpp_string_new. Both
 * are include-guarded, so pulling them in from more than one translation unit is
 * safe. */
#include "aowlspt_shim.h"
#include "aowlspt_invoke2.h"

/* ------------------------------------------------------------------ *
 * The scene target table.
 *
 * Same struct and same verify discipline as aowlspt_invoke2.h's, kept SEPARATE
 * so this file never has to edit that one. These are the hierarchy-walk and
 * component-lookup entry points a scene API needs and invoke2 does not carry.
 * ------------------------------------------------------------------ */
typedef struct AowlSceneTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlSceneTarget;

#define AOWL_SCENE_GET_PARENT       0
#define AOWL_SCENE_GET_CHILDCOUNT   1
#define AOWL_SCENE_GET_CHILD        2
#define AOWL_SCENE_FIND             3
#define AOWL_SCENE_GET_COMPONENT    4

static const AowlSceneTarget aowl_scene_targets[] = {
    /* UnityEngine.Transform::get_parent() -- instance, 0 args -> Transform.
     * rid=3204. Returns nil at a scene root, which is a legitimate answer the
     * Nim side reports as "no parent", not a fault. */
    { "UnityEngine.Transform::get_parent", 0x52B81D0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xB3,0xC9,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.Transform::get_childCount() -- instance, 0 args -> int32.
     * rid=3238. Bounds every child walk; a corrupt count cannot loop past it
     * because the Nim side caps the iteration regardless. */
    { "UnityEngine.Transform::get_childCount", 0x52B9CA0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x03,0xAF,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.Transform::GetChild(int index) -- instance, 1 int arg ->
     * Transform. rid=3250. The index is bounds-checked against get_childCount
     * on the Nim side before the call. */
    { "UnityEngine.Transform::GetChild", 0x52BA180u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x6F,0xAA,0xE1 }, 16 },

    /* UnityEngine.Transform::Find(string n) -- instance, 1 String arg ->
     * Transform (nil if not found). rid=3244. Unity's own hierarchy-path
     * lookup ("Panel/Row/Label"), which turns "find a named descendant" into
     * one verified call instead of a hand-rolled recursive walk. */
    { "UnityEngine.Transform::Find", 0x52B9EB0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0xDA,
        0x48,0x8B,0xF9 }, 16 },

    /* UnityEngine.Component::GetComponent(string type) -- instance, 1 String
     * arg -> Component (nil if absent). rid=2678. MEASURED-LIVE working from
     * modstab.nim (modsComponent). THE TRAP (fact #68): GetComponent is
     * declared on Component; handing it a GameObject puts the wrong `this` in
     * RCX and FAULTS inside Unity. The Nim wrapper refuses a receiver that is
     * not a live Component before it ever reaches here. */
    { "UnityEngine.Component::GetComponent(string)", 0x52A48E0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x07,0xFC,0xE2 }, 16 },
};

#define AOWL_SCENE_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_scene_targets) / sizeof(aowl_scene_targets[0])))

static int32_t aowl_scene_base_found = 0;
static int32_t aowl_scene_verified   = 0;
static int32_t aowl_scene_rejected   = 0;

/* One target's verified code pointer, or NULL. Identical discipline to
 * aowl_mi2_fn: the RVA must land in COMMITTED EXECUTABLE memory before the
 * prologue is compared, or the memcmp itself could fault on a stale build. */
static void* aowl_scene_fn(int32_t i) {
    HMODULE ga;
    const AowlSceneTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_SCENE_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_scene_base_found = 1;
    t = &aowl_scene_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) {
        aowl_scene_rejected++;
        return NULL;
    }
    aowl_scene_verified++;
    return (void*)p;
}
static const char* aowl_scene_name(int32_t i) {
    if (i < 0 || i >= AOWL_SCENE_TARGET_COUNT) return "";
    return aowl_scene_targets[i].name;
}
static uint32_t aowl_scene_rva(int32_t i) {
    if (i < 0 || i >= AOWL_SCENE_TARGET_COUNT) return 0u;
    return aowl_scene_targets[i].rva;
}
static int32_t aowl_scene_target_count(void) { return AOWL_SCENE_TARGET_COUNT; }
static int32_t aowl_scene_base_ok(void)  { return aowl_scene_base_found; }
static int32_t aowl_scene_ok_count(void) { return aowl_scene_verified; }
static int32_t aowl_scene_bad_count(void){ return aowl_scene_rejected; }

/* ------------------------------------------------------------------ *
 * Call thunks for the shapes this table needs that invoke2 does not carry.
 *
 * Everything else reuses invoke2's thunks directly:
 *   get_parent, GetComponent, Find  -> aowl_mi2_call_p_p / aowl_mi2_call_p_pp
 *   get_childCount                  -> aowl_mi2_call_i_p
 * Only GetChild(int) has no invoke2 equivalent (int arg -> reference). Its
 * hidden trailing MethodInfo* is a real parameter of the callee type, exactly
 * as invoke2 documents. */
typedef void* (*AowlScene_P_PI)(void*, int32_t, void*);
static void* aowl_scene_call_p_pi(void* fn, void* self, int32_t a0) {
    if (!fn) return NULL;
    return ((AowlScene_P_PI)fn)(self, a0, NULL);
}

/* ------------------------------------------------------------------ *
 * Liveness -- Unity's fake-null.  (fact #182/#184)
 *
 * A managed GameObject/Component wrapper carries the C++ engine object pointer
 * `m_CachedPtr` at +0x10. When Unity has destroyed the underlying object the
 * wrapper still exists and reads as a valid il2cpp reference, but m_CachedPtr
 * is 0. EVERY engine call dereferences it, so a "!= nil" check on the wrapper
 * is exactly the check-that-cannot-fail: it passes and the call faults. The
 * only honest liveness gate is m_CachedPtr != 0.
 * ------------------------------------------------------------------ */
#define AOWL_SCENE_CACHEDPTR_OFF 0x10

/* PURE predicate, offline-testable: a cached native pointer is "alive" iff it
 * is non-zero. Split out so the rule can be tested without a live object. */
static int32_t aowl_scene_cachedptr_alive(uint64_t cached) {
    return cached != 0u ? 1 : 0;
}

/* Guarded read of m_CachedPtr for a live wrapper. Returns 0 (dead/unreadable)
 * or 1 (alive). Validates readability of the 8 bytes at +0x10 first. */
static int32_t aowl_scene_alive(void* obj) {
    unsigned char* q;
    uint64_t cached;
    if (!obj) return 0;
    q = (unsigned char*)obj + AOWL_SCENE_CACHEDPTR_OFF;
    if (!aowl_is_readable(q, 8)) return 0;
    memcpy(&cached, q, 8);
    return aowl_scene_cachedptr_alive(cached);
}

/* ------------------------------------------------------------------ *
 * Typed field access -- guarded, byte-granular.
 *
 * A read validates readability of the exact span; a write RE-QUERIES for WRITE
 * protection specifically, so a store into a read-only page is refused here,
 * not caught after the fault. `n` is 1/2/4/8. The value travels zero-extended
 * in a uint64; the Nim side sign-extends / reinterprets per the declared type,
 * with the float reinterpret helpers below.
 * ------------------------------------------------------------------ */
static int32_t aowl_scene_field_readable(void* obj, int32_t off, int32_t n) {
    if (!obj || n <= 0 || n > 8) return 0;
    return aowl_is_readable((unsigned char*)obj + off, n);
}

static uint64_t aowl_scene_read_bits(void* obj, int32_t off, int32_t n,
                                     int32_t* ok) {
    unsigned char* q;
    uint64_t v = 0;
    if (ok) *ok = 0;
    if (!obj || (n != 1 && n != 2 && n != 4 && n != 8)) return 0;
    q = (unsigned char*)obj + off;
    if (!aowl_is_readable(q, n)) return 0;
    memcpy(&v, q, (size_t)n);
    if (ok) *ok = 1;
    return v;
}

static int32_t aowl_scene_write_bits(void* obj, int32_t off, int32_t n,
                                     uint64_t val) {
    MEMORY_BASIC_INFORMATION mbi;
    unsigned char* q;
    if (!obj || (n != 1 && n != 2 && n != 4 && n != 8)) return 0;
    q = (unsigned char*)obj + off;
    if (VirtualQuery(q, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    if ((uintptr_t)q + (size_t)n >
        (uintptr_t)mbi.BaseAddress + mbi.RegionSize) return 0;
    memcpy(q, &val, (size_t)n);
    return 1;
}

/* Float reinterpretation -- a float stored in a FIELD arrives as raw bytes and
 * must be reinterpreted, not converted. (Same helpers as the inspector's.) */
static float  aowl_scene_bits_f32(uint32_t b) { float  v; memcpy(&v,&b,4); return v; }
static double aowl_scene_bits_f64(uint64_t b) { double v; memcpy(&v,&b,8); return v; }
static uint32_t aowl_scene_f32_bits(float  v) { uint32_t b; memcpy(&b,&v,4); return b; }
static uint64_t aowl_scene_f64_bits(double v) { uint64_t b; memcpy(&b,&v,8); return b; }

/* ------------------------------------------------------------------ *
 * Struct-return decode. (matches abi/aowlspt_debugui.h, proven live)
 *
 * On this build's Win64 ABI a Vector2 (8 bytes) comes back PACKED IN RAX -- x
 * in the low 32 bits, y in the high 32 -- so a 0-arg Vector2 getter is called
 * through an int-class thunk (aowl_mi2_call_p_p, read as uint64) and unpacked
 * here. A struct wider than 8 bytes (Vector3, Rect) uses the hidden-buffer
 * (sret) route, which aowlspt_debugui.h already carries; this file exposes only
 * the RAX case, which is the one a scene field/property getter needs most.
 * ------------------------------------------------------------------ */
static double aowl_scene_vec2_x(uint64_t packed) {
    float f[2]; memcpy(f, &packed, sizeof(f)); return (double)f[0];
}
static double aowl_scene_vec2_y(uint64_t packed) {
    float f[2]; memcpy(f, &packed, sizeof(f)); return (double)f[1];
}

/* ------------------------------------------------------------------ *
 * Sharedness verdict -- PURE, offline-testable.  (fact #57)
 *
 * 28.3% of by-name lookups fold onto a SHARED RVA (>1 owner); 0x628110 is the
 * 6,438-owner universal empty-body stub. CALLING a shared address is correct
 * code for the receiver you pass; DETOURING one is a write with unbounded blast
 * radius. UNKNOWN (owners not stated) is treated as REFUSE, never as safe.
 * ------------------------------------------------------------------ */
#define AOWL_SCENE_DETOUR_OK 0   /* owners == 1: unique, safe to detour     */
#define AOWL_SCENE_CALL_ONLY 1   /* owners  > 1: shared, call ok, no detour */
#define AOWL_SCENE_REFUSE    2   /* owners <= 0: unknown, refuse to detour  */

static int32_t aowl_scene_share_verdict(int32_t owners) {
    if (owners == 1) return AOWL_SCENE_DETOUR_OK;
    if (owners  > 1) return AOWL_SCENE_CALL_ONLY;
    return AOWL_SCENE_REFUSE;
}

/* ------------------------------------------------------------------ *
 * The in-client SELF-PROOF.
 *
 * A single body meant to run under ONE aowl_p_p_seh (the caller's -- never
 * nested), given a live Component `self` (a detour's `this` is exactly one).
 * It exercises the whole verified core read-only -- get_gameObject ->
 * get_transform -> get_name -> GetInstanceID -> liveness -> get_parent ->
 * get_childCount -> GetChild(0) -> a field read -- and records a PASS / FAIL /
 * INCONCLUSIVE code per step in statics the Nim side reads and LOGS. Nothing
 * here writes game state; it proves the READ path, which is what the UI
 * framework and mods stand on.
 *
 * Step codes: 0 = not run, 1 = PASS, 2 = FAIL, 3 = INCONCLUSIVE.
 * A step is INCONCLUSIVE (not FAIL) when the RVA did not verify on this build
 * or a hop legitimately returned nil (e.g. a root has no parent) -- "could not
 * look" is never a pass and never a failure.
 * ------------------------------------------------------------------ */
#define AOWL_SCENE_PROOF_STEPS 9
enum {
    AOWL_SCENE_STEP_GAMEOBJECT = 0,
    AOWL_SCENE_STEP_TRANSFORM  = 1,
    AOWL_SCENE_STEP_NAME       = 2,
    AOWL_SCENE_STEP_INSTANCEID = 3,
    AOWL_SCENE_STEP_ALIVE      = 4,
    AOWL_SCENE_STEP_PARENT     = 5,
    AOWL_SCENE_STEP_CHILDCOUNT = 6,
    AOWL_SCENE_STEP_GETCHILD   = 7,
    AOWL_SCENE_STEP_FIELD      = 8
};
static int32_t aowl_scene_proof_step[AOWL_SCENE_PROOF_STEPS] = {0,0,0,0,0,0,0,0,0};
static int32_t aowl_scene_proof_instanceid = 0;
static int32_t aowl_scene_proof_childcount = 0;
static int32_t aowl_scene_proof_ran = 0;

static int32_t aowl_scene_proof_step_get(int32_t i) {
    if (i < 0 || i >= AOWL_SCENE_PROOF_STEPS) return 0;
    return aowl_scene_proof_step[i];
}
static int32_t aowl_scene_proof_instanceid_get(void) { return aowl_scene_proof_instanceid; }
static int32_t aowl_scene_proof_childcount_get(void) { return aowl_scene_proof_childcount; }
static int32_t aowl_scene_proof_ran_get(void) { return aowl_scene_proof_ran; }

/* Callable through aowl_p_p_seh: (void* self) -> void* (ignored). */
static void* aowl_scene_proof_body(void* self) {
    int32_t i;
    void* fn;
    void* go;
    void* tr;
    void* nm;
    void* parent;
    void* child;
    int32_t id;
    int32_t cc;
    int32_t ok;
    for (i = 0; i < AOWL_SCENE_PROOF_STEPS; i++) aowl_scene_proof_step[i] = 0;
    aowl_scene_proof_instanceid = 0;
    aowl_scene_proof_childcount = 0;
    aowl_scene_proof_ran = 1;

    if (!self || !aowl_scene_alive(self)) {
        /* No live receiver -> nothing to prove; leave every step INCONCLUSIVE. */
        for (i = 0; i < AOWL_SCENE_PROOF_STEPS; i++) aowl_scene_proof_step[i] = 3;
        return NULL;
    }

    /* get_gameObject (invoke2). */
    fn = aowl_mi2_fn(AOWL_MI2_GET_GAMEOBJECT);
    if (!fn) { aowl_scene_proof_step[AOWL_SCENE_STEP_GAMEOBJECT] = 3; }
    else {
        go = aowl_mi2_call_p_p(fn, self);
        aowl_scene_proof_step[AOWL_SCENE_STEP_GAMEOBJECT] =
            (go && aowl_scene_alive(go)) ? 1 : 2;
    }
    go = fn ? aowl_mi2_call_p_p(fn, self) : NULL;

    /* get_transform (invoke2), from the GameObject. */
    fn = aowl_mi2_fn(AOWL_MI2_GO_GET_TRANSFORM);
    tr = NULL;
    if (!fn || !go) { aowl_scene_proof_step[AOWL_SCENE_STEP_TRANSFORM] = 3; }
    else {
        tr = aowl_mi2_call_p_p(fn, go);
        aowl_scene_proof_step[AOWL_SCENE_STEP_TRANSFORM] =
            (tr && aowl_scene_alive(tr)) ? 1 : 2;
    }

    /* get_name -> a non-nil String reference. */
    fn = aowl_mi2_fn(AOWL_MI2_GET_NAME);
    if (!fn) { aowl_scene_proof_step[AOWL_SCENE_STEP_NAME] = 3; }
    else {
        nm = aowl_mi2_call_p_p(fn, self);
        aowl_scene_proof_step[AOWL_SCENE_STEP_NAME] =
            (nm && aowl_is_readable(nm, 16)) ? 1 : 2;
    }

    /* GetInstanceID -> a live object's id is never 0. */
    fn = aowl_mi2_fn(AOWL_MI2_GET_INSTANCE_ID);
    if (!fn) { aowl_scene_proof_step[AOWL_SCENE_STEP_INSTANCEID] = 3; }
    else {
        id = aowl_mi2_call_i_p(fn, self);
        aowl_scene_proof_instanceid = id;
        aowl_scene_proof_step[AOWL_SCENE_STEP_INSTANCEID] = (id != 0) ? 1 : 2;
    }

    /* liveness re-check on self. */
    aowl_scene_proof_step[AOWL_SCENE_STEP_ALIVE] = aowl_scene_alive(self) ? 1 : 2;

    /* get_parent (scene table) -- nil at a root is INCONCLUSIVE, not FAIL. */
    fn = aowl_scene_fn(AOWL_SCENE_GET_PARENT);
    if (!fn || !tr) { aowl_scene_proof_step[AOWL_SCENE_STEP_PARENT] = 3; }
    else {
        parent = aowl_mi2_call_p_p(fn, tr);
        aowl_scene_proof_step[AOWL_SCENE_STEP_PARENT] =
            (parent == NULL) ? 3 : (aowl_scene_alive(parent) ? 1 : 2);
    }

    /* get_childCount (scene table). */
    fn = aowl_scene_fn(AOWL_SCENE_GET_CHILDCOUNT);
    cc = -1;
    if (!fn || !tr) { aowl_scene_proof_step[AOWL_SCENE_STEP_CHILDCOUNT] = 3; }
    else {
        cc = aowl_mi2_call_i_p(fn, tr);
        aowl_scene_proof_childcount = cc;
        aowl_scene_proof_step[AOWL_SCENE_STEP_CHILDCOUNT] =
            (cc >= 0 && cc < 100000) ? 1 : 2;
    }

    /* GetChild(0) if there is one. */
    fn = aowl_scene_fn(AOWL_SCENE_GET_CHILD);
    if (!fn || !tr || cc <= 0) { aowl_scene_proof_step[AOWL_SCENE_STEP_GETCHILD] = 3; }
    else {
        child = aowl_scene_call_p_pi(fn, tr, 0);
        aowl_scene_proof_step[AOWL_SCENE_STEP_GETCHILD] =
            (child && aowl_scene_alive(child)) ? 1 : 2;
    }

    /* a guarded field read: m_CachedPtr itself, via the typed reader. */
    ok = 0;
    (void)aowl_scene_read_bits(self, AOWL_SCENE_CACHEDPTR_OFF, 8, &ok);
    aowl_scene_proof_step[AOWL_SCENE_STEP_FIELD] = ok ? 1 : 2;

    return NULL;
}

/* Runs the proof body under the ONE SEH guard from shim.h. Exposed so the Nim
 * side never has to cast a proc value to void* (which Nimony refuses). This IS
 * the single guard for the proof -- the caller must not already be inside one. */
static void* aowl_scene_proof_guarded(void* self) {
    return aowl_p_p_seh((void*)aowl_scene_proof_body, self);
}

#endif /* AOWLSPT_SCENE_H */
