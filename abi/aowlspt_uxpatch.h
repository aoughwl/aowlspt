/* aowlspt_uxpatch.h -- two small client-side UX fixes for the injected host.
 *
 * Both are resolved the same proven way as `aowlspt_beclient.h` and the
 * `aowlspt_bridge.h` targets: a managed method's code RVA is resolved offline by
 * `tools/il2cpp_resolve.py` (type -> its image -> that image's
 * Il2CppCodeGenModule.methodPointers[token_rid-1] -> VA -> RVA), byte-verified
 * against GameAssembly.dll, and used at runtime relative to the mapped
 * GameAssembly.dll base. RVAs are for imagebase 0x180000000 and this exact
 * client build (1.1.0.1.46777). Every patch checks the bytes it expects before
 * writing, so a wrong offset is a skipped patch rather than corrupted code.
 *
 * ## Fix 1 -- Exit hangs the game (this file, a static .text byte patch)
 *
 * Our setup runs `EscapeFromTarkov.exe` directly with no BsgLauncher, so the
 * client's Exit path blocks forever. LIVE FINDING: pressing Exit shows an "exit
 * loading" screen and hangs THERE -- i.e. the hang is in the *async shutdown
 * work* kicked off the instant the user confirms, and the flow never reaches
 * `ExitApplication`. So patching `ExitApplication` (the earlier attempt) did
 * nothing; the terminate has to fire at the confirm-accept point, before the
 * async work starts.
 *
 * The menu "Exit" button flows:
 *   EFT.TarkovApplication.ExitApplicationWithConfirm  (shows the confirm dialog)
 *     -> on accept (user clicks "Yes"), the dialog invokes the confirm lambda
 *   <ExitApplicationWithConfirm>b__186_0 @ RVA 0x9881D0  <-- PATCHED (primary)
 *     -> this starts the exit-loading screen + async shutdown (logout / save /
 *        matchmaker-leave / launcher handoff) that HANGS with no launcher, and
 *        only eventually would call
 *   EFT.TarkovApplication.ExitApplication @ 0x982610      <-- PATCHED (backstop)
 *     -> <ExitApplication>g__ForceShutdown|187_0 @ 0x988410
 *
 * `b__186_0` is the sole compiler lambda of `ExitApplicationWithConfirm` and its
 * body immediately builds the exit/shutdown state (the same struct-init pattern
 * as ExitApplication/ForceShutdown), so it is unambiguously the "user confirmed
 * Exit, now do it" accept handler -- and its FIRST instruction runs before the
 * async work it launches. Overwriting its entry with a clean native
 * `ExitProcess(0)` terminates the instant the user clicks Yes, skipping the
 * whole async shutdown and its hang, while the confirm dialog still shows first.
 * `ExitApplication` is patched too as a harmless backstop (if a flow ever
 * reaches it, it also cleanly quits). Both are native, no managed dependency,
 * and cannot themselves hang.
 *
 * Each entry is overwritten with, at its first byte:
 *     31 C9                 xor ecx, ecx           ; uExitCode = 0
 *     48 B8 <ExitProcess>   mov rax, imm64
 *     FF E0                 jmp rax                ; tail-jump; never returns
 * 14 bytes. The original is never called (these do not return anyway), so no
 * trampoline is needed. Guarded: each prologue is verified to be
 * `40 53 48 83 EC 70` (push rbx ; sub rsp,0x70) before writing, and an
 * already-patched entry (first byte 0x31) is treated as done. `ExitProcess` is
 * resolved from kernel32.dll at patch time. On a prologue mismatch that site is
 * skipped (Exit stays as it was, nothing worse).
 *
 * ## Fix 2 -- version-label branding (target accessor only; the rewrite is in
 *            the Nim host, on the Unity thread)
 *
 * The bottom-left version label ("1.1.0.1.46777") is composed and set once in
 *   EFT.UI.PreloaderUI.Awake  @ RVA 0x1569a20
 * which reads EFT.Version.get_Current (0x2532f10, its only two callers being
 * this Awake and the character-creation screen) and calls the label component's
 * `set_text` with the version. The label component is the reference field at
 * `this + 0x20` (from Awake's `mov rbx,rcx ; ... ; mov rbp,[rbx+0x20]` feeding
 * the `set_text` receiver).
 *
 * The version text is a runtime-allocated managed String built from a
 * global-metadata string literal, present nowhere in GameAssembly.dll, so there
 * is nothing static to overwrite -- branding is a managed edit on the Unity
 * thread. This header only *locates and verifies* the PreloaderUI.Awake code
 * pointer (like `aowl_bridge_settings_target_at`); the host installs a POSTFIX
 * detour there.
 *
 * LIVE FINDING (this build): a managed WRITE via `il2cpp_runtime_invoke`
 * (get_text/set_text) from inside the detour CRASHES the client, even though the
 * same postfix reaches the Unity thread and a read-only detour (the settings
 * probe) is fine -- runtime_invoke needs a MethodInfo/method-pointer this build
 * protects. So the host does NOT use runtime_invoke. Instead the postfix handler
 * (`versionBrandFired`) runs in two stages: a READ-ONLY probe that logs the
 * thread, the readability of `this + 0x20` (the label component), its class, and
 * the component's `System.String` fields; and an opt-in FIELD-WRITE brand that
 * allocates a branded String and stores its pointer straight into the
 * text-backing field by offset -- no runtime_invoke, no findMethod, the same
 * kind of raw field write `fov`/`sain` use. `aowl_uxpatch_write_ptr` below is
 * the VirtualQuery-guarded store for that path.
 *
 * Fail-safe throughout: the prologue is verified before the pointer is handed
 * out, every dereference is `aowl_is_readable`-guarded, and any doubt leaves the
 * stock version -- a wrong offset, a missed firing, or an unwritable slot is an
 * unbranded version, never a crash.
 */

#ifndef AOWLSPT_UXPATCH_H
#define AOWLSPT_UXPATCH_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * Fix 1: Exit -> ExitProcess(0)
 * ------------------------------------------------------------------ */

/* RVAs from imagebase 0x180000000, build 1.1.0.1.46777. */
#define AOWL_UX_CONFIRM_ACCEPT_RVA 0x9881D0u  /* <ExitApplicationWithConfirm>b__186_0 (primary) */
#define AOWL_UX_EXITAPP_RVA        0x982610u  /* ExitApplication (backstop)      */
#define AOWL_UX_FORCESHUTDOWN_RVA  0x988410u  /* ForceShutdown (surgical alt.)   */

/* Diagnostics, read by the host after arming. */
static int32_t aowl_ux_base_found  = 0;  /* GameAssembly.dll was located        */
static int32_t aowl_ux_exit_seen   = 0;  /* at least one exit prologue matched  */
static int32_t aowl_ux_exit_ok     = 0;  /* how many exit sites are patched (0..2)*/

static int aowl_ux_write(unsigned char* at, const unsigned char* bytes, int n) {
    DWORD old = 0;
    if (!VirtualProtect(at, (SIZE_T)n, PAGE_EXECUTE_READWRITE, &old)) return 0;
    memcpy(at, bytes, (size_t)n);
    DWORD tmp = 0;
    VirtualProtect(at, (SIZE_T)n, old, &tmp);
    FlushInstructionCache(GetCurrentProcess(), at, (SIZE_T)n);
    return 1;
}

/* Overwrite one function entry with `xor ecx,ecx ; mov rax,ExitProcess ; jmp rax`.
 * Returns 1 if it landed or was already our stub, 0 on prologue mismatch or a
 * failed write. Expected prologue: 40 53 48 83 EC 70 (push rbx ; sub rsp,0x70). */
static int aowl_ux_patch_exit_site(unsigned char* p, FARPROC ep) {
    if (p[0] == 0x31 && p[1] == 0xC9) {   /* already ours */
        aowl_ux_exit_seen = 1;
        return 1;
    }
    static const unsigned char pro[6] = {0x40, 0x53, 0x48, 0x83, 0xEC, 0x70};
    if (memcmp(p, pro, 6) != 0) return 0;
    aowl_ux_exit_seen = 1;

    unsigned char stub[14];
    stub[0] = 0x31; stub[1] = 0xC9;       /* xor ecx, ecx       */
    stub[2] = 0x48; stub[3] = 0xB8;       /* mov rax, imm64     */
    uint64_t addr = (uint64_t)(uintptr_t)ep;
    memcpy(stub + 4, &addr, 8);
    stub[12] = 0xFF; stub[13] = 0xE0;     /* jmp rax            */
    return aowl_ux_write(p, stub, 14) ? 1 : 0;
}

/* Redirect the confirmed-Exit path to a clean ExitProcess(0): the confirm-accept
 * lambda (primary, fires before the async shutdown that hangs) and
 * ExitApplication (backstop). Returns the number of sites now patched (0..2).
 * Safe to call more than once; never writes unless the expected prologue is
 * present at a site. */
static int32_t aowl_uxpatch_exit_neuter(void) {
    HMODULE ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return 0;
    aowl_ux_base_found = 1;

    HMODULE k32 = GetModuleHandleA("kernel32.dll");
    if (!k32) return 0;
    FARPROC ep = GetProcAddress(k32, "ExitProcess");
    if (!ep) return 0;

    unsigned char* base = (unsigned char*)ga;
    int landed = 0;
    landed += aowl_ux_patch_exit_site(base + AOWL_UX_CONFIRM_ACCEPT_RVA, ep);
    landed += aowl_ux_patch_exit_site(base + AOWL_UX_EXITAPP_RVA, ep);
    aowl_ux_exit_ok = landed;
    return landed;
}

/* ------------------------------------------------------------------ *
 * Fix 2: version-label target accessor (PreloaderUI.Awake)
 *
 * Same shape and safety as `aowl_bridge_settings_target_at` in
 * `aowlspt_bridge.h`: verify committed executable memory and the exact prologue,
 * then hand out the code pointer, else NULL. The host attaches a POSTFIX detour
 * on it and does the managed rewrite on the Unity thread.
 * ------------------------------------------------------------------ */

#define AOWL_UX_PRELOADER_AWAKE_RVA 0x1569a20u
/* The reference field offset on PreloaderUI holding the version-label component
 * (the `set_text` receiver in Awake: `mov rbp,[rbx+0x20]`). */
#define AOWL_UX_VERSION_LABEL_OFF   0x20

/* Diagnostics for the version target. */
static int32_t aowl_ux_ver_sig_ok  = 0;

static void* aowl_uxpatch_version_target(void) {
    HMODULE ga;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    /* PreloaderUI.Awake prologue (16 bytes, build-pinned by the cmp disp32):
     * 40 53          push rbx
     * 48 83 EC 20    sub  rsp, 0x20
     * 80 3D A6 3F B5 05 00   cmp byte [rip+0x5B53FA6], 0
     * 48 8B D9       mov  rbx, rcx                                             */
    static const unsigned char sig[16] = {
        0x40,0x53, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0xA6,0x3F,0xB5,0x05,0x00,
        0x48,0x8B,0xD9 };

    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_ux_base_found = 1;
    p = (unsigned char*)ga + AOWL_UX_PRELOADER_AWAKE_RVA;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (memcmp(p, sig, 16) != 0) return NULL;

    aowl_ux_ver_sig_ok = 1;
    return (void*)p;
}

static int32_t aowl_uxpatch_version_label_offset(void) {
    return AOWL_UX_VERSION_LABEL_OFF;
}

/* A pointer-sized field write at `p + off`, but only if that 8-byte slot is
 * inside one committed, writable region -- the write mirror of
 * `aowl_is_readable`. Used by the version brand's field-write path to set a
 * component's text-backing String field WITHOUT calling a managed method
 * (runtime_invoke faulted on this protected build; a raw field write is what
 * `fov`/`sain` do). Returns 1 on success, 0 if the slot is not safely writable
 * (in which case nothing is written and the caller leaves the stock version). */
static int32_t aowl_uxpatch_write_ptr(void* p, int32_t off, void* value) {
    MEMORY_BASIC_INFORMATION mbi;
    char* at;
    if (!p) return 0;
    at = (char*)p + off;
    if (VirtualQuery(at, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    {
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)at + (uintptr_t)sizeof(void*);
        if (need < (uintptr_t)at) return 0;
        if (need > end) return 0;
    }
    memcpy(at, &value, sizeof(void*));
    return 1;
}

#endif /* AOWLSPT_UXPATCH_H */
