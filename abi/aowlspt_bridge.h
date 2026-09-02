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
 * `bindMainDrain`'s by-name path resolves a method through the runtime
 * (`il2cpp_class_from_name` -> `il2cpp_class_get_method_from_name` -> read
 * `MethodInfo.methodPointer`). On this build that returned nothing usable for
 * every candidate -- but NOT because the metadata is protected. Two real
 * reasons: one candidate, `EFT.MainApplication`, does not exist post-1.0 (the
 * root application MonoBehaviour is **`EFT.TarkovApplication`**); and, decisive,
 * `bindMainDrain` runs on the host's own boot thread, and reading IL2CPP
 * class/method metadata off the Unity main thread returns bogus pointers and
 * faults (see the repo memory `project_post1_menu_boot`). So `findClass` /
 * `findMethod` handed back garbage and `methodPointer` read garbage -> null.
 * That is a wrong-thread artifact, not proof of protected metadata.
 *
 * The decrypted metadata's per-module `methodPointers` tables are in fact
 * INTACT and reliable on this build. Proof: this file's resolver reproduces all
 * five BE-bypass RVAs in `aowlspt_beclient.h` byte-for-byte (they live in the
 * `Assembly-CSharp-firstpass.dll` module, table base 0x186BF1380 -- an EARLIER
 * misread used `Assembly-CSharp.dll`'s table for every type and so missed them,
 * which is where the false "the table is null for BE" note used to be), and it
 * reproduces every VA in `docs/SETTINGS.md` (SettingsScreen.Show 0x171FA00,
 * OpenGroup 0x1720C80, ...). Two independent ground truths, exact.
 *
 * So resolution is **static**, offline, the same mechanism as the BE patches:
 * type -> its image (from the metadata images table) -> that image's
 * `Il2CppCodeGenModule.methodPointers` -> `[token_rid - 1]` -> code RVA, then
 * byte-verify the prologue against `GameAssembly.dll` before use. No runtime
 * metadata read, no off-thread hazard.
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
    /* HOW MANY REGISTER SLOTS THE COMPILED CALL USES: `this` (0 for a
     * static), the declared arguments, and IL2CPP's trailing `MethodInfo*`.
     * Past FOUR they arrive ON THE STACK and a POSTFIX detour cannot serve
     * them -- the postfix thunk `sub`s its own frame before `call`ing the
     * original, so the original reads them out of the thunk's frame. See the
     * banner in `abi/aowlspt_uihooks.h` for the measured crash (three dead
     * boots, `EFT.UI.MenuScreen::Show(5-arg)`, 7 slots) and `attachDrain` in
     * `aowlhost.nim` for the gate that now refuses it.
     *
     * ZERO MEANS UNDECLARED, NOT ZERO SLOTS. A real method always uses at
     * least one (the `MethodInfo*` alone), so a row that a future edit adds
     * without filling this in reads as UNDECLARED and `attachDrain` REFUSES
     * a postfix on it rather than binding one on an unknown shape. That is
     * the fail-closed direction; a plain `int32_t` zero-fill could not fail
     * any other way.
     *
     * Every value below was resolved OFFLINE from
     * `Il2CppMethodDefinition.parameterCount@34` + `flags@28 & STATIC`, and
     * `tools/drainaudit.py` re-derives all of them from the metadata on every
     * build and fails the build if this column and the metadata disagree. */
    int32_t             slots;
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
        0x48,0x85,0xDB }, 16, 1, 2 },

    /* EFT.GameWorldUnityTickListener::Update @ 0x251C6C0 (raid only)
     * 40 57          push rdi
     * 48 83 EC 20    sub  rsp, 0x20
     * 80 3D D0 68 BA 04 00   cmp byte [rip+0x4BA68D0], 0                    */
    { "EFT.GameWorldUnityTickListener::Update", 0x251C6C0u,
      { 0x40,0x57, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0xD0,0x68,0xBA,0x04,0x00 },
      13, 1, 2 },
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
        0x48,0x8B,0xE9 }, 16, 1, 2 },

    /* EFT.CameraControl.CameraLodBiasController::OnPostRender @ 0x1263B10
     * 48 83 EC 38    sub  rsp, 0x38
     * 48 8B 05 4D F7 E6 05   mov rax, [rip+0x5E6F74D]
     * 0F 29 74 24 20 movaps [rsp+0x20], xmm6                               */
    { "EFT.CameraControl.CameraLodBiasController::OnPostRender", 0x1263B10u,
      { 0x48,0x83,0xEC,0x38, 0x48,0x8B,0x05,0x4D,0xF7,0xE6,0x05,
        0x0F,0x29,0x74,0x24,0x20 }, 16, 1, 2 },
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

/* ------------------------------------------------------------------ *
 * The settings-injection probe target
 *
 * `EFT.UI.Settings.SettingsScreen::Show` @ RVA 0x171FA00 -- the method that
 * builds the settings UI, called on the Unity main thread when the user opens
 * the settings screen. A read-only detour here is the decisive test of native
 * settings injection: it fires on a definite user action, so if it fires at all
 * it fires on the Unity thread, and its `this` is the live `SettingsScreen`
 * whose children a mod would parent a control into. Validated: RVA and prologue
 * match `docs/SETTINGS.md` (VA 0x18171FA00) exactly.
 *
 * Prologue `push rbx ; sub rsp,0x20 ; cmp byte[rip+..],0 ; mov rbx,rcx` --
 * relocatable (the RIP-relative displacement is fixed up by the detour copier).
 */
static const AowlBridgeTarget aowl_bridge_settings_targets[] = {
    { "EFT.UI.Settings.SettingsScreen::Show", 0x171FA00u,
      { 0x40,0x53, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0x0C,0xEA,0x99,0x05,0x00,
        0x48,0x8B,0xD9 }, 16, 0, 2 },
};
#define AOWL_BRIDGE_SETTINGS_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_bridge_settings_targets) / \
               sizeof(aowl_bridge_settings_targets[0])))

static void* aowl_bridge_settings_target_at(int32_t i) {
    HMODULE ga;
    const AowlBridgeTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_BRIDGE_SETTINGS_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_bridge_base_found = 1;
    t = &aowl_bridge_settings_targets[i];
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
static const char* aowl_bridge_settings_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_BRIDGE_SETTINGS_TARGET_COUNT) return "";
    return aowl_bridge_settings_targets[i].name;
}
static int32_t aowl_bridge_settings_target_count(void) {
    return AOWL_BRIDGE_SETTINGS_TARGET_COUNT;
}

/* ------------------------------------------------------------------ *
 * The settings CONTROL-TREE target (Phase 1.8)
 *
 * `EFT.UI.Settings.SettingsScreen::ShowScreen` @ RVA 0x1720DE0
 * (VA 0x181720DE0), hooked POSTFIX.
 *
 * WHY THIS AND NOT `Show` OR `EnsureTabInitialized`: settled offline in
 * `docs/timbuktu/SETTINGS-CONTROLS-RE.md`, from disassembly + metadata, after
 * three live cycles each disproved a guess. The chain that actually builds a
 * tab's controls is:
 *
 *   ShowScreen 0x1720DE0
 *     +0x1720EE0  call 0x171BCA0   set_IsSelected(oldTab, false)
 *     +0x1720F00  call 0x171FF10   EnsureTabInitialized(this, group)
 *                                    -- only calls each tab's Show(); builds
 *                                       NO controls. Phase 1.5 hooked here and
 *                                       correctly saw null.
 *     +0x1720F4E  mov [rbx+0x118], rcx      _currentTab = the new tab
 *     +0x1720FC1  jmp 0x171BCA0    set_IsSelected(newTab, TRUE)  <-- builds
 *
 *   set_IsSelected 0x171BCA0
 *     +0x171BD1C  cmp byte [rbx+0x90], 0    IsInitialized latch
 *     +0x171BD32  mov rax, [rdx+0x2C8]      vtable slot 25 -> OnFirstSelect
 *     +0x171BD40  call rax
 *
 *   <Tab>::OnFirstSelect -> CreateControls -> CreateControl<T> (gshared,
 *   0x2B86E20), whose +0x2B8706F does `mov [rsi+0x88], rdi` -- the one and only
 *   write of `_createdControls`.
 *
 * A pattern scan of `.text` + `il2cpp` for `mov r64,[reg+0x2C8]` followed by a
 * `+0x2D0` load finds exactly two invokers of that slot in the settings UI:
 * `set_IsSelected` (0x171BD32) and the dead `OnTabSelected` (0x171BDBC). And a
 * direct-E8 xref finds exactly one caller of `set_IsSelected`: ShowScreen. So
 * ShowScreen is the only live path to control creation, and a POSTFIX here runs
 * strictly after it -- the trailing `jmp` is a tail-call, so `set_IsSelected`'s
 * `ret` returns through this detour's trampoline.
 *
 * SIGNATURE (read off the disassembly):
 *   RCX = `this` (SettingsScreen)   -- `mov rbx, rcx` at +0x1720DF8
 *   EDX = `ESettingsGroup group`    -- `mov esi, edx` at +0x1720DF6
 * At postfix time `[RCX+0x118]` (`_currentTab`) is the tab whose controls were
 * just built -- written at +0x1720F4E, before the tail-jump. EDX maps to the
 * same tab through `aowl_sui_group_tab_offset`, which is a free cross-check.
 *
 * Prologue, byte-verified against GameAssembly.dll. This is the cleanest steal
 * of any settings target: AOWL_JMP_SIZE is 14 and the first instruction
 * boundary at or past 14 is 15, so the detour steals four instructions and NOT
 * ONE of them is RIP-relative -- no displacement fixup at all (unlike `Show`
 * and `EnsureTabInitialized`, whose steals both cut a `cmp byte [rip+..],0`):
 *   48 89 5C 24 08        mov [rsp+0x08], rbx     (5)
 *   48 89 74 24 10        mov [rsp+0x10], rsi     (5) -> 10
 *   57                    push rdi                (1) -> 11
 *   48 83 EC 30           sub rsp, 0x30           (4) -> 15
 *   80 3D 2B D6 99 05 00  cmp byte [rip+..], 0    (7) -> 22   (NOT stolen)
 * The 16-byte `sig` therefore ends one byte into that `cmp`; it is a memcmp
 * fingerprint, not the steal length, which the length decoder computes itself.
 */
static const AowlBridgeTarget aowl_bridge_settingstab_targets[] = {
    { "EFT.UI.Settings.SettingsScreen::ShowScreen", 0x1720DE0u,
      { 0x48,0x89,0x5C,0x24,0x08, 0x48,0x89,0x74,0x24,0x10, 0x57,
        0x48,0x83,0xEC,0x30, 0x80 }, 16, 0, 3 },
};
#define AOWL_BRIDGE_SETTINGSTAB_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_bridge_settingstab_targets) / \
               sizeof(aowl_bridge_settingstab_targets[0])))

static void* aowl_bridge_settingstab_target_at(int32_t i) {
    HMODULE ga;
    const AowlBridgeTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_BRIDGE_SETTINGSTAB_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_bridge_base_found = 1;
    t = &aowl_bridge_settingstab_targets[i];
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
static const char* aowl_bridge_settingstab_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_BRIDGE_SETTINGSTAB_TARGET_COUNT) return "";
    return aowl_bridge_settingstab_targets[i].name;
}
static int32_t aowl_bridge_settingstab_target_count(void) {
    return AOWL_BRIDGE_SETTINGSTAB_TARGET_COUNT;
}
/* The i'th settings-tab target's REGISTER-SLOT count -- what `attachDrain`'s
 * postfix gate needs. 0 for an out-of-range index, which reads as UNDECLARED
 * and is refused, rather than a plausible small number. Both postfix riders on
 * this table (settingsui kind 7, invoke2 kind 9) pass it. */
static int32_t aowl_bridge_settingstab_target_slots(int32_t i) {
    if (i < 0 || i >= AOWL_BRIDGE_SETTINGSTAB_TARGET_COUNT) return 0;
    return aowl_bridge_settingstab_targets[i].slots;
}

/* ------------------------------------------------------------------ *
 * The settings-screen TICK target (Phase 1.7) -- a Unity-thread heartbeat
 *
 * `EFT.UI.Settings.GameSettingsTab::Update` @ RVA 0x1703680 (VA 0x181703680).
 *
 * WHY A TICK AND NOT A TRIGGER. Phase 1.6 hooked `SettingsTab::OnTabSelected`
 * and it NEVER FIRED across five real tab clicks. The reason is now proven: a
 * full-section cross-reference scan of the 81MB `il2cpp` segment (where the
 * generated code actually lives -- NOT `.text`) finds **zero** callers of
 * 0x171BDA0. It is dead code in this build. The same scan finds zero direct
 * callers of every tab's Show / OnFirstSelect / CreateControls too, because they
 * are all vtable-dispatched -- so "who calls it" cannot be answered statically,
 * and each guess costs a full deploy-and-click cycle to disprove.
 *
 * So we stop guessing the trigger and take a heartbeat instead. This is a
 * MonoBehaviour `Update`: Unity's runtime drives it every frame while the game
 * settings tab component is enabled, so it is a guaranteed Unity-main-thread
 * tick for as long as the settings screen is up, and it costs nothing when the
 * screen is closed (it simply is not called). From it the probe re-reads each
 * registered tab's `_createdControls` on a throttle and reports the census the
 * first time it becomes non-empty -- whatever ends up filling it, whenever.
 *
 * Hooked PREFIX: we want the tick, not the method's result, and a prefix is the
 * cheaper of the two. RCX = the GameSettingsTab (unused; the probe walks the
 * registry, not `this`).
 *
 * Prologue, byte-verified against GameAssembly.dll:
 *   40 57                   push rdi
 *   48 83 EC 40             sub  rsp, 0x40
 *   80 3D E2 AC 9B 05 00    cmp  byte [rip+0x59BACE2], 0
 *   48 8B F9                mov  rdi, rcx
 * = 2+4+7+3 = 16 exactly, ending immediately before `75 4B` (jne). The single
 * RIP-relative operand is the same class-init `cmp` every other target here
 * carries, which the detour copier fixes up.
 */
static const AowlBridgeTarget aowl_bridge_settingstick_targets[] = {
    { "EFT.UI.Settings.GameSettingsTab::Update", 0x1703680u,
      { 0x40,0x57, 0x48,0x83,0xEC,0x40,
        0x80,0x3D,0xE2,0xAC,0x9B,0x05,0x00, 0x48,0x8B,0xF9 }, 16, 0, 2 },
};
#define AOWL_BRIDGE_SETTINGSTICK_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_bridge_settingstick_targets) / \
               sizeof(aowl_bridge_settingstick_targets[0])))

static void* aowl_bridge_settingstick_target_at(int32_t i) {
    HMODULE ga;
    const AowlBridgeTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_BRIDGE_SETTINGSTICK_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_bridge_base_found = 1;
    t = &aowl_bridge_settingstick_targets[i];
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
static const char* aowl_bridge_settingstick_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_BRIDGE_SETTINGSTICK_TARGET_COUNT) return "";
    return aowl_bridge_settingstick_targets[i].name;
}
static int32_t aowl_bridge_settingstick_target_count(void) {
    return AOWL_BRIDGE_SETTINGSTICK_TARGET_COUNT;
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
