/* aowlspt_invoke2.h -- DIRECT invocation of managed IL2CPP methods by static
 * RVA, with no reflection anywhere.
 *
 * ===========================================================================
 * WHY THIS EXISTS
 * ===========================================================================
 *
 * Post-1.0 this client's IL2CPP *reflection* surface is dead: the live P2-P5
 * probe proved `il2cpp_object_get_class`, `il2cpp_class_get_name`,
 * `il2cpp_value_box` and field iteration all FAULT, even on the Unity main
 * thread, and `il2cpp_runtime_invoke` crashed outright. Everything the host has
 * built since -- the version brand, botcap, the settings control walk -- is
 * therefore raw field reads and writes at fixed offsets.
 *
 * Raw fields are enough to CHANGE the UI. They are not enough to CREATE it: a
 * new GameObject, a component attached to it, a Canvas child -- all of that is
 * managed code, and the only door left is to call that managed code.
 *
 * The hypothesis this header implements: **IL2CPP AOT-compiles every managed
 * method into an ordinary native function, so it can be called directly at its
 * RVA as a native function pointer.** No MethodInfo lookup, no metadata query,
 * no reflection -- just a `call`, exactly as the game itself does.
 *
 * ===========================================================================
 * THE CALLING CONVENTION FOR THIS BUILD (1.1.0.1.46777), WITH EVIDENCE
 * ===========================================================================
 *
 * It is Win64 (Microsoft x64) with ONE addition: IL2CPP appends a hidden
 * trailing `const MethodInfo*` argument after the declared ones, in the next
 * free INTEGER register (and on the stack past the fourth). It is passed as a
 * literal NULL by the compiler for every ordinary (non-generic) method.
 *
 *   instance:  RCX = this,  RDX/R8/R9 = arg0..arg2,  then MethodInfo*
 *   static:                 RCX/RDX/R8/R9 = arg0..arg3, then MethodInfo*
 *   floats:    XMM0..XMM3 by POSITION, per Win64 (a float in slot 1 is XMM1)
 *   returns:   RAX (integer/reference) or XMM0 (float/double), per Win64
 *
 * Evidence 1 -- an INSTANCE method with one reference argument. From
 * `TMPro.TMP_DefaultControls::CreateUIElementRoot` @ RVA 0x5190080, which is
 * literally "make a new UI GameObject":
 *
 *     51900c9: mov  rcx, [rip+0x1c52f88]   ; Il2CppClass* UnityEngine.GameObject
 *     51900d0: call 0x1805d9e20            ; il2cpp::vm::Object::New(klass)
 *     51900d5: xor  r8d, r8d               ; <-- R8 = MethodInfo* = NULL
 *     51900d8: mov  rdx, rdi               ; RDX = arg0, the name String*
 *     51900db: mov  rcx, rax               ; RCX = this, the fresh GameObject
 *     51900de: mov  rbx, rax
 *     51900e1: call 0x1852a8f40            ; UnityEngine.GameObject::.ctor(string)
 *
 * `.ctor(string)` declares ONE parameter, and the call site sets THREE integer
 * registers. The third is the hidden MethodInfo*, and it is zero.
 *
 * Evidence 2 -- a STATIC method with two reference arguments, from the same
 * function (`TMP_DefaultControls::SetParentAndAlign(GameObject, GameObject)`):
 *
 *     519020e: xor  r8d, r8d               ; <-- R8 = MethodInfo* = NULL
 *     5190211: mov  rdx, rdi               ; RDX = arg1, the parent
 *     5190214: mov  rcx, rbx               ; RCX = arg0, the child
 *     5190217: call 0x1851903a0            ; ...::SetParentAndAlign
 *
 * Two declared args in RCX/RDX -- no `this` shift, because it is static -- and
 * the MethodInfo* in the next register, again NULL.
 *
 * Evidence 3 -- the callee side confirms it is genuinely ignored. Every simple
 * accessor compiles to a body that reads RCX and never touches the MethodInfo
 * register at all, e.g. `UnityEngine.Component::get_gameObject` @ 0x11F57E0:
 *
 *     11f57e0: push rbx ; sub rsp,0x20
 *     11f57e6: mov  rax, [rip+0x5edecfb]   ; cached icall pointer
 *     11f57ed: mov  rbx, rcx               ; RCX = this  (RDX never read)
 *     ...      test rax,rax / jne -> resolve the icall by name on first use
 *     11f580d: mov  rcx, rbx ; add rsp,0x20 ; pop rbx ; jmp rax
 *
 * and `UnityEngine.Time::get_frameCount` @ 0x52B3400 (static, zero args) never
 * reads RCX either. Note the lazy-resolve shape: an unresolved icall resolves
 * itself on first call, so calling these cold from a detour is safe.
 *
 * Evidence 4 -- the ONE case where the MethodInfo* is load-bearing: a shared
 * generic instantiation. `UnityEngine.GameObject::AddComponent<T>` @ 0x2A9AE90:
 *
 *     2a9aea4: cmp  qword [rdx+0x38], 0    ; <-- RDX *is* the MethodInfo*
 *     2a9aea9: mov  rdi, rdx
 *     2a9aeac: mov  rbp, rcx               ; RCX = this
 *     ...      call 0x180563290            ; initialise its RGCTX if unset
 *     2a9aed8: mov  rbx, [rdi+0x38]        ; the runtime generic context
 *
 * An instance method with ZERO declared parameters, and RDX is the MethodInfo*
 * -- which it dereferences. So a generic method cannot be called with NULL; it
 * needs the real `MethodInfo*` for that exact instantiation. The game keeps
 * those in .data cache slots (see AOWL_MI2_DATA_ADDCOMP_RECTTRANSFORM below).
 *
 * ===========================================================================
 * WHAT THIS HEADER PROVIDES
 * ===========================================================================
 *
 *  * A build-pinned target table: name + RVA + 16 prologue bytes, verified the
 *    same way `aowlspt_bridge.h` verifies a detour target -- VirtualQuery for
 *    committed executable memory, then memcmp of the prologue. On any other
 *    build the lookup returns NULL and every step simply does not run.
 *  * Typed call thunks, one per shape used by the ladder. They exist in C
 *    because casting a pointer to a function type is not expressible in nimony,
 *    and because the hidden MethodInfo* must be a real argument of the callee
 *    type rather than something bolted on afterwards.
 *  * The two IL2CPP *allocation* exports (`il2cpp_object_new`,
 *    `il2cpp_string_new`) plus the two *type-object* exports the AddComponent
 *    (Type) route would need. Allocation is proven to work on this build (the
 *    version brand allocates a String on the Unity thread); the type-object
 *    pair is UNPROVEN and is probed, not assumed.
 *  * A guarded reader for the game's own .data metadata cache slots, which is
 *    how a real generic `MethodInfo*` is obtained without reflection.
 *
 * NOTHING here calls anything on its own. It is a table and a set of thunks;
 * `host/Aowlspt.Host.Il2Cpp/invoke2.nim` drives it, from inside a proven
 * Unity-thread detour, one step at a time, under the VEH/SEH guard.
 *
 * All RVAs are for `GameAssembly.dll` imagebase 0x180000000, build
 * 1.1.0.1.46777, and were resolved offline by `tools/il2cpp_resolve.py` +
 * the 185k-entry RVA map, then confirmed by disassembly of real call sites.
 */
#ifndef AOWLSPT_INVOKE2_H
#define AOWLSPT_INVOKE2_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * The target table
 * ------------------------------------------------------------------ */

typedef struct AowlMi2Target {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlMi2Target;

/* Indices into `aowl_mi2_targets`. Named so the Nim side never carries a bare
 * number: a ladder step that calls the wrong function is exactly the failure
 * this whole exercise cannot afford to debug live. */
#define AOWL_MI2_GET_GAMEOBJECT      0
#define AOWL_MI2_GET_INSTANCE_ID     1
#define AOWL_MI2_GET_NAME            2
#define AOWL_MI2_SET_NAME            3
#define AOWL_MI2_GET_FRAMECOUNT      4
#define AOWL_MI2_GET_SCREEN_WIDTH    5
#define AOWL_MI2_GET_SCREEN_HEIGHT   6
#define AOWL_MI2_GO_CTOR_STRING      7
#define AOWL_MI2_GO_SETACTIVE        8
#define AOWL_MI2_GO_GET_TRANSFORM    9
#define AOWL_MI2_SET_PARENT_ALIGN   10
#define AOWL_MI2_INSTANTIATE        11
#define AOWL_MI2_ADDCOMPONENT_TYPE  12
#define AOWL_MI2_ADDCOMPONENT_GEN   13
#define AOWL_MI2_SET_AS_FIRST_SIBLING 14

static const AowlMi2Target aowl_mi2_targets[] = {
    /* UnityEngine.Component::get_gameObject -- instance, 0 args -> GameObject.
     * The anchor of the whole ladder: every EFT UI script is a Component, so a
     * detour's `this` yields a live GameObject with one direct call. */
    { "UnityEngine.Component::get_gameObject", 0x11F57E0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xFB,0xEC,0xED,0x05,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.Object::GetInstanceID -- instance, 0 args -> int32. A
     * side-effect-free getter whose answer is self-validating: a live Unity
     * object's instance id is never 0. */
    { "UnityEngine.Object::GetInstanceID", 0x52ACFD0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x12,0x77,0xE2,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.Object::get_name -- instance, 0 args -> System.String. The
     * strongest read-only proof available: the returned pointer is decoded by
     * the FIXED String layout the host already trusts, so a wrong call cannot
     * produce readable text by accident. */
    { "UnityEngine.Object::get_name", 0x52AD4B0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x36,0x72,0xE2,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.Object::set_name -- instance, 1 arg (String). */
    { "UnityEngine.Object::set_name", 0x52AD540u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xA3,
        0x71,0xE2,0x01 }, 16 },

    /* UnityEngine.Time::get_frameCount -- STATIC, 0 args -> int32. The static
     * half of the convention proof: RCX holds only the MethodInfo*, and the
     * body never reads it. */
    { "UnityEngine.Time::get_frameCount", 0x52B3400u,
      { 0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0x5D,0x16,0xE2,0x01,0x48,0x85,
        0xC0,0x75,0x18 }, 16 },

    /* UnityEngine.Screen::get_width / get_height -- STATIC, 0 args -> int32.
     * Two more statics whose answers are checkable against the window. */
    { "UnityEngine.Screen::get_width", 0x501B760u,
      { 0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0x9D,0x78,0x0B,0x02,0x48,0x85,
        0xC0,0x75,0x18 }, 16 },
    { "UnityEngine.Screen::get_height", 0x501B7B0u,
      { 0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0x55,0x78,0x0B,0x02,0x48,0x85,
        0xC0,0x75,0x18 }, 16 },

    /* UnityEngine.GameObject::.ctor(String) -- instance, 1 arg. THE crux for
     * UI creation, and the exact function whose call site (Evidence 1 above)
     * established the convention. */
    { "UnityEngine.GameObject::.ctor(String)", 0x52A8F40u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x8F,
        0xB6,0xE2,0x01 }, 16 },

    /* UnityEngine.GameObject::SetActive -- instance, 1 arg (bool). */
    { "UnityEngine.GameObject::SetActive", 0x52A8BE0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xA7,0xB9,0xE2 }, 16 },

    /* UnityEngine.GameObject::get_transform -- instance, 0 args -> Transform. */
    { "UnityEngine.GameObject::get_transform", 0x52A8AE0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x93,0xBA,0xE2,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* TMPro.TMP_DefaultControls::SetParentAndAlign(GameObject child,
     * GameObject parent) -- STATIC, 2 args. Unity's own UI-parenting helper,
     * compiled into this build: it does SetParent(false), resets the local
     * transform and copies the layer. Reaching it means a new GameObject can
     * be put into a live Canvas hierarchy with ONE call and no System.Type,
     * no generic instantiation and no reflection. */
    { "TMPro.TMP_DefaultControls::SetParentAndAlign", 0x51903A0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x68,
        0x13,0xF4,0x01 }, 16 },

    /* UnityEngine.Object::Instantiate(Object original) -- STATIC, 1 arg. The
     * CLONE path: the fallback that needs neither a Type nor a generic
     * MethodInfo, and the one that makes a UI element out of an existing one. */
    { "UnityEngine.Object::Instantiate(Object)", 0x52ADBE0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x06,
        0x6B,0xE2,0x01 }, 16 },

    /* UnityEngine.GameObject::AddComponent(Type) -- instance, 1 arg. Reaching
     * this needs an `Il2CppReflectionType*` (a live System.Type), which on this
     * build means `il2cpp_class_get_type` + `il2cpp_type_get_object`. Both are
     * UNPROVEN here -- probed by the ladder, never assumed. */
    { "UnityEngine.GameObject::AddComponent(Type)", 0x52A8A80u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xE7,0xBA,0xE2 }, 16 },

    /* UnityEngine.GameObject::AddComponent<T>() -- instance, 0 declared args,
     * RDX = the instantiation's MethodInfo* (Evidence 4). Shared generic code,
     * so ONE function serves every T; the T is entirely in the MethodInfo. */
    { "UnityEngine.GameObject::AddComponent<T>", 0x2A9AE90u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,
        0x24,0x18,0x57 }, 16 },

    /* UnityEngine.Transform::SetAsFirstSibling() -- instance, 0 args -> void.
     * Resolved offline (tools/il2cpp_resolve.py, type UnityEngine.Transform,
     * rid=3239) against the same GameAssembly.dll/global-metadata pair used
     * for every other entry in this table; not shared (no --shared
     * annotation). Real body in the `il2cpp` section, not a thunk. Called via
     * aowl_mi2_call_p_p (its void* return is discarded) to reorder a strip
     * WE cloned to sibling index 0 within its parent -- nothing about the
     * parent or its other children is touched. */
    { "UnityEngine.Transform::SetAsFirstSibling", 0x52B9CF0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xBB,0xAE,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_MI2_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_mi2_targets) / sizeof(aowl_mi2_targets[0])))

/* Diagnostics, read by the host so a refusal can name its reason. */
static int32_t aowl_mi2_base_found = 0;
static int32_t aowl_mi2_verified   = 0;   /* how many prologues matched */
static int32_t aowl_mi2_rejected   = 0;   /* how many did not           */

/* The verified code pointer for one target, or NULL. Same discipline as
 * `aowl_bridge_settings_target_at`: the RVA must land in COMMITTED EXECUTABLE
 * memory before the prologue is compared, because a stale RVA on another build
 * can point at an uncommitted page and `memcmp` there faults. */
static void* aowl_mi2_fn(int32_t i) {
    HMODULE ga;
    const AowlMi2Target* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_MI2_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_mi2_base_found = 1;
    t = &aowl_mi2_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) {
        aowl_mi2_rejected++;
        return NULL;
    }
    aowl_mi2_verified++;
    return (void*)p;
}
static const char* aowl_mi2_name(int32_t i) {
    if (i < 0 || i >= AOWL_MI2_TARGET_COUNT) return "";
    return aowl_mi2_targets[i].name;
}
static uint32_t aowl_mi2_rva(int32_t i) {
    if (i < 0 || i >= AOWL_MI2_TARGET_COUNT) return 0u;
    return aowl_mi2_targets[i].rva;
}
static int32_t aowl_mi2_target_count(void) { return AOWL_MI2_TARGET_COUNT; }
static int32_t aowl_mi2_base_ok(void)  { return aowl_mi2_base_found; }
static int32_t aowl_mi2_ok_count(void) { return aowl_mi2_verified; }
static int32_t aowl_mi2_bad_count(void){ return aowl_mi2_rejected; }

/* ------------------------------------------------------------------ *
 * The call thunks
 *
 * One per SHAPE, not one per method. Every one of them passes the hidden
 * `MethodInfo*` explicitly as the last parameter, because that is what the
 * convention is -- passing it implicitly (by declaring one argument fewer and
 * hoping the register happens to be zero) is the kind of thing that works in
 * testing and corrupts a generic call in the field.
 *
 * Naming: `aowl_mi2_<ret>_<args>`, where p = pointer/reference, i = int32,
 * b = bool(int32), v = void/none. The MethodInfo* is not in the name; it is
 * always there.
 * ------------------------------------------------------------------ */

/* instance, 0 declared args -> reference.  (this, MethodInfo*) */
typedef void* (*AowlMi2_P_P)(void*, void*);
static void* aowl_mi2_call_p_p(void* fn, void* self) {
    if (!fn) return NULL;
    return ((AowlMi2_P_P)fn)(self, NULL);
}
/* instance, 0 declared args -> int32. */
typedef int32_t (*AowlMi2_I_P)(void*, void*);
static int32_t aowl_mi2_call_i_p(void* fn, void* self) {
    if (!fn) return 0;
    return ((AowlMi2_I_P)fn)(self, NULL);
}
/* STATIC, 0 declared args -> int32.  (MethodInfo*) */
typedef int32_t (*AowlMi2_I_V)(void*);
static int32_t aowl_mi2_call_i_v(void* fn) {
    if (!fn) return 0;
    return ((AowlMi2_I_V)fn)(NULL);
}
/* instance, 1 reference arg -> void.  (this, a0, MethodInfo*) */
typedef void (*AowlMi2_V_PP)(void*, void*, void*);
static void aowl_mi2_call_v_pp(void* fn, void* self, void* a0) {
    if (!fn) return;
    ((AowlMi2_V_PP)fn)(self, a0, NULL);
}
/* instance, 1 bool arg -> void.  (this, a0, MethodInfo*) */
typedef void (*AowlMi2_V_PB)(void*, int32_t, void*);
static void aowl_mi2_call_v_pb(void* fn, void* self, int32_t a0) {
    if (!fn) return;
    ((AowlMi2_V_PB)fn)(self, a0, NULL);
}
/* instance, 1 reference arg -> reference. */
typedef void* (*AowlMi2_P_PP)(void*, void*, void*);
static void* aowl_mi2_call_p_pp(void* fn, void* self, void* a0) {
    if (!fn) return NULL;
    return ((AowlMi2_P_PP)fn)(self, a0, NULL);
}
/* STATIC, 1 reference arg -> reference.  (a0, MethodInfo*) */
typedef void* (*AowlMi2_P_S1)(void*, void*);
static void* aowl_mi2_call_p_s1(void* fn, void* a0) {
    if (!fn) return NULL;
    return ((AowlMi2_P_S1)fn)(a0, NULL);
}
/* STATIC, 2 reference args -> void.  (a0, a1, MethodInfo*) */
typedef void (*AowlMi2_V_S2)(void*, void*, void*);
static void aowl_mi2_call_v_s2(void* fn, void* a0, void* a1) {
    if (!fn) return;
    ((AowlMi2_V_S2)fn)(a0, a1, NULL);
}
/* instance, 0 declared args, REAL MethodInfo* -> reference. The generic shape:
 * the MethodInfo is the instantiation, so it is a parameter here rather than a
 * hardcoded NULL. Refuses a NULL MethodInfo outright, because the callee
 * dereferences it at +0x38 and a NULL there is an immediate access violation
 * with nothing gained. */
static void* aowl_mi2_call_generic0(void* fn, void* self, void* mi) {
    if (!fn || !mi) return NULL;
    return ((AowlMi2_P_P)fn)(self, mi);
}

/* ------------------------------------------------------------------ *
 * IL2CPP runtime exports
 *
 * Resolved by name from the already-loaded GameAssembly.dll. These are the
 * runtime's ALLOCATION and TYPE-OBJECT entry points, not its reflection ones:
 * `il2cpp_string_new` is already proven to work on the Unity thread by the
 * version brand, and `il2cpp_object_new` is the same class of call (it is what
 * the game itself reaches at 0x5D9E20 from every `new`).
 *
 * `il2cpp_class_get_type` / `il2cpp_type_get_object` are the two the
 * AddComponent(Type) route needs. They are resolved here so the ladder can
 * PROBE them under the guard; nothing assumes they work, because the P2-P5
 * verdict on this build is that most of the reflection surface faults.
 * ------------------------------------------------------------------ */

/* `il2cpp_class_get_type` is a STATIC-token gate (argidx 1) in
 * `abi/aowlspt_il2cpp_gates_data.h`. It is DELIBERATELY not bound here: called
 * without its token it returns MT19937-64 output, which passed the `if (!t)`
 * on the next line and was fed straight to `il2cpp_type_get_object` -- the
 * shape that killed the client on 2026-09-02 18:49. It now goes through
 * `aowl_gate_call`, which supplies the token, byte-verifies the export against
 * the startup snapshot, VirtualQueries the argument and runs the call under
 * one SEH guard. `il2cpp_object_new`, `il2cpp_string_new` and
 * `il2cpp_type_get_object` are UNGATED (checked against the row table), so a
 * raw bind of those three is correct. */
#include "aowlspt_il2cpp_gates.h"
#include "aowlspt_handle.h"

typedef void* (*AowlMi2ObjectNew)(void*);
typedef void* (*AowlMi2StringNew)(const char*);
typedef void* (*AowlMi2TypeGetObject)(void*);

static AowlMi2ObjectNew     g_mi2_object_new     = 0;
static AowlMi2StringNew     g_mi2_string_new     = 0;
static AowlMi2TypeGetObject g_mi2_type_get_object= 0;
static int                  g_mi2_exports_done   = 0;

/* Why the last type-route attempt refused. Every refusal names itself; nobody
 * prints a counter. */
static const char* g_mi2_type_why = "not attempted";
static const char* aowl_mi2_type_route_why(void) { return g_mi2_type_why; }

static void aowl_mi2_exports_init(void) {
    HMODULE ga;
    if (g_mi2_exports_done) return;
    g_mi2_exports_done = 1;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return;
    g_mi2_object_new = (AowlMi2ObjectNew)(void*)
        GetProcAddress(ga, "il2cpp_object_new");
    g_mi2_string_new = (AowlMi2StringNew)(void*)
        GetProcAddress(ga, "il2cpp_string_new");
    g_mi2_type_get_object = (AowlMi2TypeGetObject)(void*)
        GetProcAddress(ga, "il2cpp_type_get_object");
}
static int32_t aowl_mi2_have_object_new(void) {
    aowl_mi2_exports_init(); return g_mi2_object_new ? 1 : 0;
}
/* "Reachable" now means: the ungated half is bound AND the gated half has a
 * row we can arm. `aowl_gate_is_gated` is a table lookup, not a call. */
static int32_t aowl_mi2_have_type_route(void) {
    aowl_mi2_exports_init();
    if (!g_mi2_type_get_object) {
        g_mi2_type_why = "il2cpp_type_get_object is not exported";
        return 0;
    }
    if (!aowl_gate_is_gated("il2cpp_class_get_type")) {
        g_mi2_type_why = "il2cpp_class_get_type has no gate row in this build";
        return 0;
    }
    return 1;
}
static void* aowl_mi2_object_new(void* klass) {
    aowl_mi2_exports_init();
    if (!g_mi2_object_new || !klass) return NULL;
    return g_mi2_object_new(klass);
}
static void* aowl_mi2_string_new(const char* s) {
    aowl_mi2_exports_init();
    if (!g_mi2_string_new || !s) return NULL;
    return g_mi2_string_new(s);
}
/* klass -> Il2CppType* -> System.Type object, in one hop so a fault inside
 * either half is one guarded step rather than two. */
static void* aowl_mi2_type_object_of(void* klass) {
    aowl_gate_call_t c;
    void* argv[1];
    void* t;
    void* obj;

    aowl_mi2_exports_init();
    if (!aowl_mi2_have_type_route()) return NULL;
    if (!klass) { g_mi2_type_why = "no klass"; return NULL; }
    if (!aowl_handle_shape_ok((uint64_t)(uintptr_t)klass) ||
        !aowl_is_readable(klass, 8)) {
        g_mi2_type_why = "the klass handed in is not shaped like a handle";
        return NULL;
    }

    argv[0] = klass;
    if (!aowl_gate_call("il2cpp_class_get_type", argv, 1, &c)) {
        /* `ret != NULL` is NOT success here: the trap never returns NULL. */
        g_mi2_type_why = aowl_gate_why(c.why);
        return NULL;
    }
    t = c.ret;
    if (!t) { g_mi2_type_why = "the gated call succeeded and returned no type";
              return NULL; }
    if (!aowl_handle_shape_ok((uint64_t)(uintptr_t)t) ||
        !aowl_is_readable(t, 8)) {
        g_mi2_type_why = "Il2CppType* failed the shape/readable filter";
        aowl_gate_note_fault();
        return NULL;
    }

    /* Ungated, and its argument has now been validated three ways. */
    obj = g_mi2_type_get_object(t);
    if (obj && (!aowl_handle_shape_ok((uint64_t)(uintptr_t)obj) ||
                !aowl_is_readable(obj, 8))) {
        g_mi2_type_why = "System.Type object failed the shape/readable filter";
        return NULL;
    }
    g_mi2_type_why = obj ? "ok" : "il2cpp_type_get_object returned null";
    return obj;
}

/* The two probe strings, and their allocation, kept HERE rather than on the Nim
 * side: nimony converts only a string LITERAL to a `cstring`, and a `const`
 * carrying the same text is not one. Defining them once in C and handing out
 * both the C text (for the log and the round-trip comparison) and the allocated
 * managed String (for the call) keeps a single source of truth -- the round-trip
 * check in step 4 is only meaningful if the two cannot drift apart. */
#define AOWL_MI2_PROBE_NAME "aowlspt-invoke-probe"
#define AOWL_MI2_PROBE_TEXT "aowlspt: direct RVA invoke OK"

static const char* aowl_mi2_probe_name(void) { return AOWL_MI2_PROBE_NAME; }
static const char* aowl_mi2_probe_text(void) { return AOWL_MI2_PROBE_TEXT; }
static void* aowl_mi2_probe_name_str(void) {
    return aowl_mi2_string_new(AOWL_MI2_PROBE_NAME);
}
static void* aowl_mi2_probe_text_str(void) {
    return aowl_mi2_string_new(AOWL_MI2_PROBE_TEXT);
}

/* ------------------------------------------------------------------ *
 * The game's own metadata cache slots (.data)
 *
 * IL2CPP does not embed an `Il2CppClass*` or a generic `MethodInfo*` as an
 * immediate; it emits a load from a per-token .data slot that a metadata
 * initialiser fills the first time the owning method runs. Reading those slots
 * is how a real generic `MethodInfo*` is obtained WITHOUT reflection -- the
 * game computed it, we just read the pointer it wrote.
 *
 * Both slots below were recovered from the RIP-relative operands inside
 * `TMPro.TMP_DefaultControls::CreateUIElementRoot`:
 *
 *   51900c9: mov rcx,[rip+0x1c52f88]  -> next=0x51900d0 -> RVA 0x6E03058
 *            = Il2CppClass* UnityEngine.GameObject
 *   51900eb: mov rdx,[rip+0x1c8948e]  -> next=0x51900f2 -> RVA 0x6E19580
 *            = MethodInfo* GameObject::AddComponent<RectTransform>
 *
 * Both are in `.data` (0x6B61000..0x737BD74), as expected.
 *
 * They are LAZY: NULL until TMP's default-control code has run at least once.
 * A NULL read is therefore a "not initialised yet" skip, never an error -- and
 * never a reason to call a generic method with a NULL MethodInfo.
 * ------------------------------------------------------------------ */

#define AOWL_MI2_DATA_GAMEOBJECT_CLASS       0x6E03058u
#define AOWL_MI2_DATA_ADDCOMP_RECTTRANSFORM  0x6E19580u

/* The qword in GameAssembly.dll's .data at `rva`, or NULL if that address is
 * not committed readable memory. VirtualQuery-guarded like every other raw read
 * this host does, and range-checked to .data so a typo cannot read code. */
static void* aowl_mi2_data_ptr(uint32_t rva) {
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
static void* aowl_mi2_go_class_slot(void) {
    return aowl_mi2_data_ptr(AOWL_MI2_DATA_GAMEOBJECT_CLASS);
}
static void* aowl_mi2_addcomp_rect_mi(void) {
    return aowl_mi2_data_ptr(AOWL_MI2_DATA_ADDCOMP_RECTTRANSFORM);
}

#endif /* AOWLSPT_INVOKE2_H */
