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
 * client's normal Exit path -- which hands back to the launcher / performs a
 * shutdown handshake -- blocks forever waiting for a launcher that is not there,
 * and the client goes unresponsive.
 *
 * The menu "Exit" button flows:
 *   EFT.TarkovApplication.ExitApplicationWithConfirm  (shows the confirm dialog)
 *     -> on accept, a delegate invokes
 *   EFT.TarkovApplication.ExitApplication  @ RVA 0x982610   <-- PATCHED HERE
 *     -> local func <ExitApplication>g__ForceShutdown|187_0 @ 0x988410 (the
 *        launcher handoff / shutdown handshake that actually blocks)
 *
 * `ExitApplication` is the earliest point on the *confirmed* exit path that
 * unambiguously means "quit the whole application" (its 0 direct E8 callers plus
 * its name and its ForceShutdown/LogOut locals confirm it is the app-quit
 * method, reached via the confirm-accept delegate -- never during normal play).
 * Patching its entry to a clean native `ExitProcess(0)` therefore turns "Exit
 * hangs forever" into "Exit closes the game" no matter where downstream the
 * handshake would have blocked, while the confirm dialog still shows first. It
 * is a native call with no managed dependency, guaranteed to terminate every
 * thread, so it cannot itself hang.
 *
 * The entry is overwritten with, at the function's first byte:
 *     31 C9                 xor ecx, ecx           ; uExitCode = 0
 *     48 B8 <ExitProcess>   mov rax, imm64
 *     FF E0                 jmp rax                ; tail-jump; never returns
 * 14 bytes. The original is never called (the function does not return anyway),
 * so no trampoline is needed. Guarded: the prologue is verified to be
 * `48 83 EC 70` (sub rsp,0x70) before writing, and an already-patched entry
 * (first byte 0x31) is treated as done. `ExitProcess` is resolved from
 * kernel32.dll at patch time.
 *
 * The surgical alternative -- patching only `ForceShutdown` @ 0x988410 (prologue
 * `48 83 EC 68`) so logout/save still run before termination -- is kept in the
 * RVA table below and is a one-line switch if a future build wants it.
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
 * Branding it cleanly means a managed edit on the Unity main thread (safe), not
 * a static byte patch: the version text is a runtime-allocated managed String
 * built from a global-metadata string literal, present nowhere in
 * GameAssembly.dll, so there is nothing static to overwrite. This header only
 * *locates and verifies* the PreloaderUI.Awake code pointer (exactly like
 * `aowl_bridge_settings_target_at`); the host installs a POSTFIX detour there
 * and, after the original has set the label, reads the label's text and rewrites
 * it to "aowlspt <U+2014> <version>" via the runtime's own get_text/set_text.
 * PreloaderUI.Awake is a MonoBehaviour callback, so the detour fires on the
 * Unity thread and the managed edit is safe. Fail-safe: the prologue is verified
 * before the pointer is handed out, and the host guards every dereference and
 * skips on any doubt, so a wrong offset or a missed firing is an unbranded
 * version, never a crash.
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
#define AOWL_UX_EXITAPP_RVA        0x982610u  /* ExitApplication (patched)       */
#define AOWL_UX_FORCESHUTDOWN_RVA  0x988410u  /* ForceShutdown (surgical alt.)   */

/* Diagnostics, read by the host after arming. */
static int32_t aowl_ux_base_found  = 0;  /* GameAssembly.dll was located        */
static int32_t aowl_ux_exit_seen   = 0;  /* the exit prologue matched           */
static int32_t aowl_ux_exit_ok     = 0;  /* the exit patch landed (or was done) */

static int aowl_ux_write(unsigned char* at, const unsigned char* bytes, int n) {
    DWORD old = 0;
    if (!VirtualProtect(at, (SIZE_T)n, PAGE_EXECUTE_READWRITE, &old)) return 0;
    memcpy(at, bytes, (size_t)n);
    DWORD tmp = 0;
    VirtualProtect(at, (SIZE_T)n, old, &tmp);
    FlushInstructionCache(GetCurrentProcess(), at, (SIZE_T)n);
    return 1;
}

/* Redirect EFT.TarkovApplication.ExitApplication to a clean ExitProcess(0).
 * Returns 1 if the patch landed or was already in place, 0 otherwise. Safe to
 * call more than once. Never writes unless the expected prologue is present. */
static int32_t aowl_uxpatch_exit_neuter(void) {
    HMODULE ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return 0;
    aowl_ux_base_found = 1;

    unsigned char* p = (unsigned char*)ga + AOWL_UX_EXITAPP_RVA;

    /* Already our stub? (first byte xor ecx,ecx). Treat as done. */
    if (p[0] == 0x31 && p[1] == 0xC9) {
        aowl_ux_exit_seen = 1;
        aowl_ux_exit_ok = 1;
        return 1;
    }

    /* Expected prologue: push rbx ; sub rsp,0x70 -> 40 53 48 83 EC 70. */
    static const unsigned char pro[6] = {0x40, 0x53, 0x48, 0x83, 0xEC, 0x70};
    if (memcmp(p, pro, 6) != 0) return 0;
    aowl_ux_exit_seen = 1;

    HMODULE k32 = GetModuleHandleA("kernel32.dll");
    if (!k32) return 0;
    FARPROC ep = GetProcAddress(k32, "ExitProcess");
    if (!ep) return 0;

    /* 31 C9                xor ecx, ecx        (uExitCode = 0)
     * 48 B8 <imm64>        mov rax, ExitProcess
     * FF E0                jmp rax                                              */
    unsigned char stub[14];
    stub[0] = 0x31; stub[1] = 0xC9;
    stub[2] = 0x48; stub[3] = 0xB8;
    uint64_t addr = (uint64_t)(uintptr_t)ep;
    memcpy(stub + 4, &addr, 8);
    stub[12] = 0xFF; stub[13] = 0xE0;

    if (aowl_ux_write(p, stub, 14)) { aowl_ux_exit_ok = 1; return 1; }
    return 0;
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

#endif /* AOWLSPT_UXPATCH_H */
