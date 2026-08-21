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
 * ## Fix 1b -- Closing the OS window hangs too (this file, a WndProc subclass)
 *
 * The Exit-BUTTON patch (Fix 1) intercepts the confirm-accept lambda, but that
 * is only reached from the in-game menu "Exit" flow. Closing the window any
 * OTHER way -- the title-bar X, right-click-taskbar-Close, Alt+F4 -- never runs
 * that lambda. Windows posts WM_CLOSE to the game's top window; Unity's window
 * proc turns that into `Application.Quit`, which funnels into the SAME async
 * exit-loading shutdown (logout / save / matchmaker-leave / launcher handoff)
 * that hangs forever with no BsgLauncher. So the OS-close path hangs exactly
 * like the pre-fix Exit button did, and the .text patch above does not cover it
 * because a different caller (Unity's WndProc, not the confirm lambda) reaches
 * the hang.
 *
 * RE of the path: WM_CLOSE -> Unity/GameAssembly window proc -> Application.Quit
 * -> EFT quit -> the async shutdown state-machine (the same one Fix 1 bypasses)
 * -> hang on the exit-loading screen. Rather than chase and byte-patch that
 * managed WndProc/Quit chain (build-specific, several methods, and the hang is
 * inside async continuations that are awkward to neuter), we cut it off at the
 * cleanest choke point: the WIN32 window message itself. `ExitProcess(0)` on the
 * close message terminates cleanly before Unity ever acts on it and before any
 * async shutdown can start, covering the X button, taskbar Close, Alt+F4 and
 * session logoff/shutdown.
 *
 * HOW that is done has changed three times under live evidence, and the current
 * answer is NOT a WndProc subclass. The full history and the mechanism now in
 * use are documented at the implementation below ("Fix 1b" section); in short:
 *
 *   1. A one-shot subclass at il2cpp-init never installed at all -- the game's
 *      top-level window does not exist that early, so EnumWindows found nothing.
 *   2. Retrying the subclass from the host tick loop fixed the menu case but not
 *      the raid case: entering a raid re-creates the window and re-installs
 *      Unity's own proc, so the subclass was silently gone.
 *   3. Re-subclassing continuously to compensate CRASHED the client -- swapping
 *      another thread's WndProc is unsupported and races its pump.
 *
 * So there is no subclass any more. Nobody's WndProc is modified. The close
 * messages are observed with thread-scoped `SetWindowsHookExW` hooks
 * (WH_GETMESSAGE + WH_CALLWNDPROC) on the game's UI thread -- the supported way
 * to act on the messages of a window you do not own -- with the
 * message-independent console-control handler beside it. The whole feature is
 * behind the `osCloseFix` config flag.
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
 * Fix 1b: OS window-close -> ExitProcess(0)
 *         (thread-scoped message hooks -- NOT a WndProc subclass)
 * ------------------------------------------------------------------ */

/* LIVE FINDING #2 (raid): a once-armed subclass is not enough. It armed at the
 * menu, and closing the window IN A RAID still hung, because entering a raid
 * changes display mode: Unity destroys and re-creates its top-level window (a
 * new HWND) and re-installs its own WndProc. By the time the user clicks the X,
 * our proc is on a dead window or has been overwritten.
 *
 * LIVE FINDING #3 (CRASH -- why this is no longer a subclass at all): the
 * obvious fix, re-subclassing from the host tick loop, KILLED THE CLIENT a few
 * seconds into boot. The log ends immediately after the second re-arm line, on
 * a third distinct HWND. The cause is that `SetWindowLongPtrW(GWLP_WNDPROC)` on
 * a window owned by ANOTHER thread is not supported: Windows documents
 * subclassing as a same-thread operation, and swapping the proc pointer from the
 * host thread races the owning thread's pump -- a message can be dispatched
 * against a half-swapped pair, or `CallWindowProcW` can chain into a proc that
 * has already been replaced or freed. Doing it every second, across up to eight
 * windows including hidden helper/IME/message-only windows that were never the
 * game's UI, made that race a certainty. (The original one-shot install survived
 * only because it wrote once, very early, to one window.)
 *
 * So the subclass is GONE. Nobody's WndProc is modified any more. Instead we use
 * the mechanism Windows provides for exactly this -- observing another thread's
 * messages without owning its windows:
 *
 *   * `SetWindowsHookExW(WH_GETMESSAGE, ..., NULL, tid)` sees messages POSTED to
 *     that thread as its pump retrieves them -- the title-bar X and taskbar
 *     Close arrive here as `WM_CLOSE`, Alt+F4 as a posted `WM_SYSCOMMAND`.
 *   * `SetWindowsHookExW(WH_CALLWNDPROC, ..., NULL, tid)` sees messages SENT to
 *     that thread's windows before the proc runs -- the X button's
 *     `WM_SYSCOMMAND`/`SC_CLOSE`, which `DefWindowProc` sends before it turns
 *     into `WM_CLOSE`, arrives here.
 *
 * Both are IN-PROCESS, THREAD-SCOPED hooks (hMod = NULL, an explicit thread id),
 * which is a fully supported configuration; the callbacks run ON the UI thread,
 * so there is no cross-thread write anywhere. They observe, they do not replace:
 * anything that is not a close is passed straight to `CallNextHookEx` and the
 * game never knows they exist. A close calls `ExitProcess(0)` -- from the UI
 * thread, before Unity's quit path can start the async shutdown that hangs.
 *
 * Because a thread hook covers the THREAD, not one HWND, the raid's window
 * re-creation is a non-event: the new window is pumped by the same UI thread and
 * is covered the instant it exists, with nothing re-armed and nothing written.
 * The arm is re-checked only against the UI thread id, and in the steady state
 * it does exactly one `GetWindowThreadProcessId` and returns -- no writes at all,
 * which is the property the crashing version lacked.
 *
 * Window choice is conservative now: only the MAIN visible, unowned top-level
 * window (largest area wins if several qualify) -- never "all of them". The
 * hidden helper windows that the previous version happily subclassed are ignored.
 *
 * The `SC_CLOSE` insight from that version is kept, and is the reason
 * WH_CALLWNDPROC is installed alongside WH_GETMESSAGE: a WndProc that handles
 * `SC_CLOSE` itself and calls straight into `Application.Quit` never produces the
 * `WM_CLOSE` a posted-message-only hook would be waiting for.
 *
 * Fail-safe throughout: if no window is found yet, nothing is installed and the
 * caller retries. If `SetWindowsHookExW` fails, nothing is installed and OS-close
 * behaves exactly as it did before this file existed. Nothing else in the process
 * is modified either way, and the Exit-button byte patch is entirely independent.
 * The whole feature is behind the `osCloseFix` config flag so it can be turned
 * off without a rebuild. */

/* Diagnostics, read by the host after arming. */
static int32_t aowl_ux_close_hooked = 0;  /* hooks are installed               */
static int32_t aowl_ux_close_seen   = 0;  /* a candidate window was found      */
static int32_t aowl_ux_close_rearms = 0;  /* times the UI thread changed       */

/* The installed hooks and the UI thread they cover. */
static HHOOK aowl_ux_hook_getmsg = NULL;
static HHOOK aowl_ux_hook_cwp    = NULL;
static DWORD aowl_ux_hook_tid    = 0;

/* The main window we picked the thread from, for the host's log line. */
static HWND aowl_ux_close_hwnd = NULL;

/* Is this message the user asking the process to go away?
 *
 * `SC_CLOSE` is masked with 0xFFF0 because the low four bits of a
 * `WM_SYSCOMMAND` wParam carry mouse/accelerator detail, not the command. */
static int aowl_ux_is_close_msg(UINT msg, WPARAM wp) {
    if (msg == WM_CLOSE || msg == WM_QUIT || msg == WM_ENDSESSION) return 1;
    if (msg == WM_SYSCOMMAND && (wp & 0xFFF0) == SC_CLOSE) return 1;
    return 0;
}

/* WH_GETMESSAGE: posted messages, seen as the UI thread's pump retrieves them.
 * Runs on the UI thread. Observation only -- everything that is not a close is
 * forwarded untouched. */
static LRESULT CALLBACK aowl_ux_getmsg_hook(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION && lp) {
        MSG* m = (MSG*)lp;
        if (aowl_ux_is_close_msg(m->message, m->wParam))
            ExitProcess(0);
    }
    return CallNextHookEx(NULL, code, wp, lp);
}

/* WH_CALLWNDPROC: sent messages, seen before the target proc runs. Runs on the
 * UI thread. This is the one that catches the X button's SC_CLOSE. */
static LRESULT CALLBACK aowl_ux_cwp_hook(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION && lp) {
        CWPSTRUCT* c = (CWPSTRUCT*)lp;
        if (aowl_ux_is_close_msg(c->message, c->wParam))
            ExitProcess(0);
    }
    return CallNextHookEx(NULL, code, wp, lp);
}

/* Pick the MAIN game window: a visible, unowned top-level window of this
 * process, largest area winning if there is more than one. Deliberately narrow
 * -- the hidden helper/IME/message-only windows the previous version subclassed
 * are exactly what we must not touch. lp is a HWND* receiving the choice. */
static BOOL CALLBACK aowl_ux_close_enum(HWND h, LPARAM lp) {
    DWORD pid = 0;
    HWND* out = (HWND*)lp;
    RECT r;
    GetWindowThreadProcessId(h, &pid);
    if (pid != GetCurrentProcessId()) return TRUE;
    if (!IsWindowVisible(h)) return TRUE;
    if (GetWindow(h, GW_OWNER) != NULL) return TRUE;   /* a tool/dialog window */
    if (!GetWindowRect(h, &r)) return TRUE;
    {
        long area = (long)(r.right - r.left) * (long)(r.bottom - r.top);
        if (area <= 0) return TRUE;
        aowl_ux_close_seen = 1;
        if (*out == NULL) { *out = h; return TRUE; }
        {
            RECT o;
            if (GetWindowRect(*out, &o)) {
                long oa = (long)(o.right - o.left) * (long)(o.bottom - o.top);
                if (area > oa) *out = h;
            }
        }
    }
    return TRUE;
}

/* Arm (or re-arm) the close hooks on the game's UI thread.
 *
 * Designed to be called repeatedly from the host tick loop. In the steady state
 * -- the UI thread unchanged -- it does one EnumWindows plus one thread-id
 * comparison and WRITES NOTHING; there is no per-tick modification of any window
 * or proc anywhere in the process.
 *
 * Returns 1 if the hooks are installed on the current UI thread, else 0.
 * `*rearmed`, when non-NULL, receives 1 if THIS call installed them (a first
 * arm, or a re-arm because the UI thread id changed), which is what the host
 * logs. Fail-safe: on any failure nothing is installed and nothing is changed. */
static int32_t aowl_uxpatch_close_arm(int32_t* rearmed) {
    HWND  main_wnd = NULL;
    DWORD tid = 0;
    HHOOK hg, hc;

    if (rearmed) *rearmed = 0;

    EnumWindows(aowl_ux_close_enum, (LPARAM)&main_wnd);
    if (main_wnd == NULL) return 0;      /* no window yet; caller retries      */

    tid = GetWindowThreadProcessId(main_wnd, NULL);
    if (tid == 0) return 0;

    /* Steady state: same UI thread, hooks already up. Nothing to do, and --
     * critically -- nothing written. A thread hook already covers any window
     * that thread creates later, including the raid's re-created one. */
    if (tid == aowl_ux_hook_tid && aowl_ux_hook_getmsg != NULL) {
        aowl_ux_close_hwnd = main_wnd;
        return 1;
    }

    /* The UI thread changed (or this is the first arm). Install on the new
     * thread FIRST, so a failure leaves the old hooks in place rather than
     * leaving the process uncovered. */
    hg = SetWindowsHookExW(WH_GETMESSAGE, aowl_ux_getmsg_hook, NULL, tid);
    hc = SetWindowsHookExW(WH_CALLWNDPROC, aowl_ux_cwp_hook, NULL, tid);
    if (hg == NULL && hc == NULL) {
        return aowl_ux_close_hooked;     /* unchanged; keep whatever we had    */
    }

    if (aowl_ux_hook_getmsg) UnhookWindowsHookEx(aowl_ux_hook_getmsg);
    if (aowl_ux_hook_cwp)    UnhookWindowsHookEx(aowl_ux_hook_cwp);
    aowl_ux_hook_getmsg = hg;
    aowl_ux_hook_cwp    = hc;
    if (aowl_ux_hook_tid != 0) aowl_ux_close_rearms++;
    aowl_ux_hook_tid    = tid;
    aowl_ux_close_hwnd  = main_wnd;
    aowl_ux_close_hooked = 1;
    if (rearmed) *rearmed = 1;
    return 1;
}

/* Back-compat one-shot wrapper for the boot-time attempt. */
static int32_t aowl_uxpatch_close_hook(void) {
    return aowl_uxpatch_close_arm(NULL);
}

/* The main window whose thread we hooked, as an integer, for the host's log
 * line. 0 until the hooks arm. */
static uint64_t aowl_uxpatch_close_hwnd(void) {
    return (uint64_t)(uintptr_t)aowl_ux_close_hwnd;
}

/* The UI thread id the hooks are installed on, for the host's log line. */
static uint64_t aowl_uxpatch_close_tid(void) {
    return (uint64_t)aowl_ux_hook_tid;
}

/* A second, message-INDEPENDENT close path: the console control handler.
 *
 * The message hooks above cover everything that arrives as a window message.
 * They cannot cover a close that never becomes one -- a console
 * CTRL_CLOSE_EVENT (when a console is attached, e.g. launched from a terminal),
 * a CTRL_LOGOFF/CTRL_SHUTDOWN, or Ctrl+C/Ctrl+Break. Those funnel through the
 * console control handler instead, which Windows calls on its own thread with
 * no dependence on Unity's message pump or on which HWND is current. Handling
 * them the same way (ExitProcess(0)) means those routes cannot reach the
 * hanging async shutdown either.
 *
 * On a pure GUI launch with no console this registers and simply never fires --
 * costless. Registration failure is ignored: nothing is worse than before. */
static BOOL WINAPI aowl_ux_close_ctrl(DWORD type) {
    (void)type;                          /* every control event means "go away" */
    ExitProcess(0);
    return TRUE;                         /* unreachable                        */
}
static int32_t aowl_ux_ctrl_armed = 0;
static int32_t aowl_uxpatch_close_ctrl_arm(void) {
    if (aowl_ux_ctrl_armed) return 1;
    if (SetConsoleCtrlHandler(aowl_ux_close_ctrl, TRUE)) {
        aowl_ux_ctrl_armed = 1;
        return 1;
    }
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
