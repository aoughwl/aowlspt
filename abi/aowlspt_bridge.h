/* aowlspt_bridge.h -- getting host-side work onto Unity's main thread.
 *
 * ## The problem this closes
 *
 * `il2cpp_runtime_invoke` from the host's own injected thread crashes this
 * client. IL2CPP/Unity managed code -- the GC, the managed heap, every Unity
 * object -- is affine to the Unity **main thread** (the one that runs the
 * player loop). A managed call, a box, or a field read issued from a foreign
 * thread faults inside the runtime. The host boots on a thread of its own, so
 * everything it wants to do to a live game object is on the wrong thread.
 *
 * The fix already lives in `host/Aowlspt.Host.Il2Cpp/aowlhost.nim`: detour a
 * method Unity calls once per frame on its main thread and drain the
 * `invoke_main` queue from inside the detour (`bindMainDrain` / `mainDrain`).
 * A closure pushed from any thread then runs, on the Unity thread, the next
 * frame. What was missing was a per-frame method the host could actually get a
 * usable code pointer for.
 *
 * ## Why the by-name path was not enough, and what this adds
 *
 * `bindMainDrain` resolves a method by name through the runtime
 * (`il2cpp_class_from_name` -> `il2cpp_class_get_method_from_name` -> read
 * `MethodInfo.methodPointer`). On this hardened build that returned nothing
 * usable for every candidate it tried -- and one candidate, `EFT.
 * MainApplication`, does not even exist: the post-1.0 root application
 * MonoBehaviour is **`EFT.TarkovApplication`**, and the old list named the
 * pre-1.0 type. Two failure modes, one file: the wrong name, and a
 * `MethodInfo.methodPointer` field this build does not populate the way the
 * reader assumes (the BE client's own methods show the same null in the
 * decrypted metadata's `methodPointers` table, so the field being null is a
 * property of this build, not of the reader).
 *
 * So this header resolves the target the same way the BE-bypass RVAs in
 * `aowlspt_beclient.h` were resolved: **statically**, as a fixed RVA into
 * `GameAssembly.dll` for this exact client build, verified byte-for-byte
 * against the compiled prologue before it is ever used. No metadata read, no
 * `methodPointer` field, no runtime resolution -- the same mechanism that made
 * the BE patches reliable when live detours were not.
 *
 * ## The target
 *
 *   `EFT.TarkovApplication::Update`  @ RVA 0x977B10  (imagebase 0x180000000,
 *   build 1.1.0.1.46777, in the `il2cpp` PE section at VA 0x628000+).
 *
 * It is the root application MonoBehaviour's per-frame `Update`. It is the best
 * of the candidates on all four counts a drain target needs:
 *   - once per frame,
 *   - on the Unity main thread only (a MonoBehaviour `Update` is a player-loop
 *     callback and runs nowhere else),
 *   - alive for the whole session, menu to desktop (the application root
 *     outlives every scene, unlike `GameWorld`, which exists only in a raid),
 *   - and its compiled prologue relocates cleanly -- `push rbx ; sub rsp,0x20 ;
 *     mov rbx,[rcx+0x110] ; test rbx,rbx`, sixteen bytes with no RIP-relative
 *     operand and no relative branch, which is exactly what the detour engine's
 *     length decoder in `aowlspt_detour.h` needs to steal a whole number of
 *     instructions for the trampoline.
 *
 * How the RVA was found: the decrypted `global-metadata.dat` gives the method's
 * token RID within `Assembly-CSharp`, and the module's `Il2CppCodeGenModule.
 * methodPointers` table in `GameAssembly.dll`'s `.data` maps RID -> code RVA,
 * exactly as Il2CppDumper does. `EFT.TarkovApplication` is type index 7933; its
 * `Update` resolves to 0x977B10 and its `LateUpdate` to the adjacent 0x977C80,
 * the tight monotonic clustering a real compiler emits for one type's methods.
 *
 * A secondary, raid-only target -- `EFT.GameWorldUnityTickListener::Update` @
 * RVA 0x251C6C0 -- is included as a fallback: it is present only inside a raid,
 * but a raid is where a mod most wants the main thread, and binding it late
 * beats not binding at all if the primary's prologue ever fails its guard.
 *
 * ## Safe by default
 *
 * Every target checks the bytes it expects before it is handed out. On any
 * other build the prologue will not match, and this returns NULL -- the host
 * then falls through to its by-name candidates and, failing those, to the
 * existing host-thread behaviour, which is the documented fallback. A wrong
 * offset is a missed bind, never a corrupted game. Nothing here writes to the
 * game; it only *locates and verifies* a function pointer. The detour itself is
 * installed by the host through the same `aowl_hook_*` engine and slot table a
 * mod's patch uses, so it inherits that engine's thread-park write safety.
 *
 * RVAs are for imagebase 0x180000000 and build 1.1.0.1.46777.
 */

#ifndef AOWLSPT_BRIDGE_H
#define AOWLSPT_BRIDGE_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* One statically-resolved per-frame target: a name for the log, its RVA, and
 * the leading bytes of its compiled prologue that pin it to this build. The
 * signature is deliberately long enough to include a build-specific field
 * displacement (the `mov rbx,[rcx+0x110]` disp32 / the `cmp [rip+..]` disp32),
 * so a same-shaped but different function on another build fails the guard. */
typedef struct AowlBridgeTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
    int32_t             perFrame;   /* runs once per frame (1) or more (0) */
} AowlBridgeTarget;

/* Diagnostics, read by the host after it asks for a target. */
static int32_t aowl_bridge_base_found = 0;  /* GameAssembly.dll located        */
static int32_t aowl_bridge_sig_ok     = 0;  /* a target's prologue matched      */
static int32_t aowl_bridge_last_rva   = 0;  /* the RVA last handed out (or 0)   */

/* The targets, most-preferred first. Primary is whole-session; the secondary is
 * raid-only and only reached if the primary's guard fails on a future build. */
static const AowlBridgeTarget aowl_bridge_targets[] = {
    /* EFT.TarkovApplication::Update @ 0x977B10
     * 40 53          push rbx
     * 48 83 EC 20    sub  rsp, 0x20
     * 48 8B 99 10 01 00 00   mov rbx, [rcx+0x110]
     * 48 85 DB       test rbx, rbx                                          */
    { "EFT.TarkovApplication::Update", 0x977B10u,
      { 0x40,0x53, 0x48,0x83,0xEC,0x20, 0x48,0x8B,0x99,0x10,0x01,0x00,0x00,
        0x48,0x85,0xDB }, 16, 1 },

    /* EFT.GameWorldUnityTickListener::Update @ 0x251C6C0 (raid only)
     * 40 57          push rdi
     * 48 83 EC 20    sub  rsp, 0x20
     * 80 3D D0 68 BA 04 00   cmp byte [rip+0x4BA68D0], 0                    */
    { "EFT.GameWorldUnityTickListener::Update", 0x251C6C0u,
      { 0x40,0x57, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0xD0,0x68,0xBA,0x04,0x00 },
      13, 1 },
};

#define AOWL_BRIDGE_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_bridge_targets) / sizeof(aowl_bridge_targets[0])))

/* ------------------------------------------------------------------ *
 * Render-phase targets
 *
 * The update-phase drain above runs inside `TarkovApplication.Update`, which is
 * the Unity main thread but the *wrong point in the frame* for immediate-mode
 * drawing: `UnityEngine.GL` calls only rasterize during the RENDER phase, and
 * post-1.0 has no `OnGUI`. So a mod that draws ESP boxes or a GL HUD from the
 * update drain is on the right thread at the wrong time and nothing appears.
 *
 * These targets are per-frame methods Unity calls during the render phase, on
 * the main thread, where `GL.*` issued from a detour lands on the frame being
 * drawn. Same discipline as the update targets: a fixed RVA, verified against
 * the compiled prologue, NULL on any other build.
 *
 *   Primary: `OnRenderObjectManager::OnRenderObject` @ RVA 0x1F46910.
 *   `OnRenderObject` is Unity's canonical immediate-mode-GL callback -- it fires
 *   once per active camera during rendering, after the scene is drawn, which is
 *   exactly where GL line/box drawing for ESP belongs. This type is a
 *   purpose-built manager (it also holds `OnRenderObjectConnectorAdd/Remove` and
 *   `FindAndAddOnRenderObjectConnectors`), so it is the render-dispatch object
 *   the game keeps alive for the whole of gameplay rather than a per-entity
 *   component. Prologue `push rbp ; sub rsp,0x20 ; cmp byte[rip+..],0 ;
 *   mov rbp,rcx` -- relocatable (the RIP-relative displacement is fixed up by
 *   the detour engine's copier).
 *
 *   Secondary: `EFT.CameraControl.CameraLodBiasController::OnPostRender` @ RVA
 *   0x1263B10. `OnPostRender` fires on a script attached to a camera, right
 *   after that camera finishes rendering -- the classic ESP overlay point. This
 *   one rides the main game camera's LOD controller, so it is a raid-time
 *   fallback if the primary's guard ever fails on a future build.
 *
 * Which of these actually fires every frame is the one thing that cannot be
 * settled by static analysis; both are verified to exist and to be relocatable,
 * and the host tries them in order, so the reliable one wins at runtime.
 */
static const AowlBridgeTarget aowl_bridge_render_targets[] = {
    /* OnRenderObjectManager::OnRenderObject @ 0x1F46910
     * 40 55          push rbp
     * 48 83 EC 20    sub  rsp, 0x20
     * 80 3D 83 A8 17 05 00   cmp byte [rip+0x517A883], 0
     * 48 8B E9       mov  rbp, rcx                                          */
    { "OnRenderObjectManager::OnRenderObject", 0x1F46910u,
      { 0x40,0x55, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0x83,0xA8,0x17,0x05,0x00,
        0x48,0x8B,0xE9 }, 16, 1 },

    /* EFT.CameraControl.CameraLodBiasController::OnPostRender @ 0x1263B10
     * 48 83 EC 38    sub  rsp, 0x38
     * 48 8B 05 4D F7 E6 05   mov rax, [rip+0x5E6F74D]
     * 0F 29 74 24 20 movaps [rsp+0x20], xmm6                               */
    { "EFT.CameraControl.CameraLodBiasController::OnPostRender", 0x1263B10u,
      { 0x48,0x83,0xEC,0x38, 0x48,0x8B,0x05,0x4D,0xF7,0xE6,0x05,
        0x0F,0x29,0x74,0x24,0x20 }, 16, 1 },
};

#define AOWL_BRIDGE_RENDER_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_bridge_render_targets) / \
               sizeof(aowl_bridge_render_targets[0])))

/* The i'th render-phase target's verified code pointer, or NULL. Identical
 * checks to `aowl_bridge_target_at`; a separate function so the host can keep
 * the two drains -- update and render -- entirely independent. */
static void* aowl_bridge_render_target_at(int32_t i) {
    HMODULE ga;
    const AowlBridgeTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_BRIDGE_RENDER_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_bridge_base_found = 1;

    t = &aowl_bridge_render_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;

    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) return NULL;

    aowl_bridge_sig_ok = 1;
    aowl_bridge_last_rva = (int32_t)t->rva;
    return (void*)p;
}

static const char* aowl_bridge_render_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_BRIDGE_RENDER_TARGET_COUNT) return "";
    return aowl_bridge_render_targets[i].name;
}

static int32_t aowl_bridge_render_target_count(void) {
    return AOWL_BRIDGE_RENDER_TARGET_COUNT;
}

/* The i'th target's verified code pointer, or NULL.
 *
 * NULL means one of: GameAssembly.dll is not mapped yet, the index is out of
 * range, the RVA does not resolve to committed executable memory, or -- the
 * common case on any build but this one -- the prologue bytes there are not the
 * ones recorded. Every one of those is a reason to move on to the next target
 * or to the host's by-name path, and none is a reason to write anything. */
static void* aowl_bridge_target_at(int32_t i) {
    HMODULE ga;
    const AowlBridgeTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_BRIDGE_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_bridge_base_found = 1;

    t = &aowl_bridge_targets[i];
    p = (unsigned char*)ga + t->rva;

    /* The bytes have to be readable+executable before they are compared: a bad
     * RVA can land in an uncommitted or data page, and memcmp there faults. */
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;

    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) return NULL;

    aowl_bridge_sig_ok = 1;
    aowl_bridge_last_rva = (int32_t)t->rva;
    return (void*)p;
}

/* Whether the i'th target runs once per frame (1) or more often (0). Read
 * alongside `aowl_bridge_target_at` so the host can tell a mod, through
 * `aowlspt.host::main_thread`, whether the drain's firing count is a frame
 * count. */
static int32_t aowl_bridge_target_perframe(int32_t i) {
    if (i < 0 || i >= AOWL_BRIDGE_TARGET_COUNT) return 0;
    return aowl_bridge_targets[i].perFrame;
}

static const char* aowl_bridge_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_BRIDGE_TARGET_COUNT) return "";
    return aowl_bridge_targets[i].name;
}

static int32_t aowl_bridge_target_count(void) { return AOWL_BRIDGE_TARGET_COUNT; }

/* Whether a pointer lands inside GameAssembly.dll's `il2cpp` PE section -- the
 * 85 MB section at RVA 0x628000 (size 0x510FA6C) that holds every AOT method
 * body (see the header comment and METADATA-RE.md). A real compiled method
 * pointer is in here; a vtable slot, a data pointer or a runtime stub is not.
 * This is the discriminator that makes scanning a `MethodInfo` for "the field
 * that holds the code" safe to act on: an executable page alone is not enough
 * (the CRT and UnityPlayer have plenty), but an executable pointer *into the
 * il2cpp section* is a compiled managed method with very high confidence. */
#define AOWL_IL2CPP_SEC_RVA  0x628000u
#define AOWL_IL2CPP_SEC_SIZE 0x510FA6Cu
static int32_t aowl_in_il2cpp_section(void* p) {
    HMODULE ga;
    uintptr_t base, lo, hi, x;
    if (!p) return 0;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return 0;
    base = (uintptr_t)ga;
    lo = base + AOWL_IL2CPP_SEC_RVA;
    hi = lo + AOWL_IL2CPP_SEC_SIZE;
    x = (uintptr_t)p;
    return (x >= lo && x < hi) ? 1 : 0;
}

/* The `il2cpp`-section RVA of a pointer, or -1 if it is not in that section --
 * for logging a found pointer as an RVA the way every other address in this
 * project is written. */
static int64_t aowl_il2cpp_rva_of(void* p) {
    HMODULE ga;
    if (!aowl_in_il2cpp_section(p)) return -1;
    ga = GetModuleHandleA("GameAssembly.dll");
    return (int64_t)((uintptr_t)p - (uintptr_t)ga);
}

#endif /* AOWLSPT_BRIDGE_H */
