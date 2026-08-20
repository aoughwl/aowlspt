/* aowlspt_il2cppready.h — knowing when IL2CPP is actually up.
 *
 * The host is injected into a suspended process and has to wait for the game
 * to build its runtime before it can resolve a single type. The obvious way to
 * wait is to poll: is `GameAssembly.dll` loaded, and does `il2cpp_domain_get`
 * return a domain yet?
 *
 * That is what `waitForIl2Cpp` did, and on the first real client it crashed
 * the game. From `Player.log`, 2026-08-19:
 *
 *     0x00007FFD822A5639 (GameAssembly)        mono_class_has_parent
 *     0x00007FFE13555DA5 (aowlspt-host-il2cpp) domainGet
 *     0x00007FFE1354135A (aowlspt-host-il2cpp) waitForIl2Cpp
 *     0x00007FFE1354E40C (aowlspt-host-il2cpp) aowlspt_nim_host_main
 *
 * The module is mapped and its exports are resolvable a long time before
 * `il2cpp_init` has run. `il2cpp_domain_get` in that window does not return
 * NULL politely -- it reads a global that has not been written yet and faults
 * inside the runtime. The old comment knew the first half of this ("the module
 * appears well before the domain does") and drew the wrong conclusion from it:
 * that asking is safe as long as you are willing to be told no. Asking *is*
 * the unsafe act. There is no answer that can be polled for here, because the
 * question itself is what crashes.
 *
 * ## What is watched instead
 *
 * `UnityPlayer.dll` does not import `il2cpp_init`; it looks it up with
 * `GetProcAddress` and calls it. So this replaces `GetProcAddress` in
 * `UnityPlayer.dll`'s import table -- and only there -- and watches what is
 * asked for. When UnityPlayer asks `GameAssembly.dll` for `il2cpp_init` -- or
 * for `il2cpp_init_utf16`, since both are exported and which one a build calls
 * is not knowable from here -- it is handed a wrapper instead of the real
 * function. The wrapper calls through, and what it records is a *successful*
 * return: not that the runtime was asked to initialise, and not merely that
 * the call came back, but that it came back saying it worked.
 *
 * That distinction is not academic. On the first real client this watched for
 * any return at all, and `il2cpp_init` answered 0 -- a failure -- 100ms into
 * the process. The host believed it, asked for the domain, and faulted in
 * precisely the place the polling version had. The fix and the original bug
 * are the same shape one layer apart, which is worth saying plainly here: a
 * signal that fires whether or not the thing happened is not a signal.
 *
 * Nothing is patched in `GameAssembly.dll`, no instruction is rewritten, and
 * no thread is parked. One pointer in one module's IAT is swapped in the
 * constructor, and one flag is set some seconds later on the game's own
 * thread.
 *
 * ## Why this and not the alternatives
 *
 * *Polling with an exception handler around the probe* -- a vectored handler
 * that swallows the fault and retries -- would work often enough to look
 * correct. It also swallows real faults, in the one component whose crashes
 * are hardest to attribute, and it leaves the runtime having been entered
 * mid-initialisation, which is not a state anyone has promised is recoverable.
 *
 * *Detouring `il2cpp_init` in GameAssembly* is deterministic but cannot be
 * armed in the constructor: `GameAssembly.dll` is loaded dynamically and is
 * not mapped yet at that point (it is not in the import table of
 * `EscapeFromTarkov.exe`, which imports only `UnityPlayer.dll` and
 * `KERNEL32.dll`, nor of `UnityPlayer.dll`). Arming it later means noticing
 * the load and installing a code patch before the very next call -- a race
 * with no upper bound on how badly it can lose. Watching the lookup has no
 * race at all: the pointer is in place before the game runs an instruction,
 * and UnityPlayer cannot call what it has not yet looked up.
 *
 * ## What happens when this does not fire
 *
 * It fails *closed*, and that is the whole reason it reports separately from
 * the wait. If a future client initialises IL2CPP some other way, the flag
 * never sets, the host waits out its timeout and says so, and mods load with
 * the runtime reported unavailable -- which is the documented behaviour for a
 * host that has no runtime, and is what `hostharness` exercises. It does not
 * fall back to asking `il2cpp_domain_get` directly. That is the call that
 * crashed the game, and a fallback to it would reintroduce the crash on
 * exactly the machines where the primary mechanism had already failed.
 */

#ifndef AOWLSPT_IL2CPPREADY_H
#define AOWLSPT_IL2CPPREADY_H

#include <windows.h>
#include <stdint.h>
#include "aowlspt_iat.h"

/* Set on the game's thread when `il2cpp_init` returns; read by the host's boot
 * thread. `volatile` is the whole synchronisation: it is a one-way flag, and
 * the reader does nothing but spin until it flips. */
static volatile LONG aowl_il2_ready   = 0;

static int32_t aowl_il2_armed         = 0;  /* GetProcAddress was swapped     */
static int32_t aowl_il2_looked        = 0;  /* named imports examined         */
static int32_t aowl_il2_module        = 0;  /* UnityPlayer.dll was found      */
static int32_t aowl_il2_lookups       = 0;  /* lookups seen after arming      */
static int32_t aowl_il2_init_seen     = 0;  /* il2cpp_init was handed out     */
static int32_t aowl_il2_init_result   = 0;  /* what the last init returned    */
static int32_t aowl_il2_init_calls    = 0;  /* how many times init was called */

typedef FARPROC (WINAPI *AowlGetProcAddress)(HMODULE, LPCSTR);
typedef int     (*AowlIl2CppInit)(const char*);
typedef int     (*AowlIl2CppInitW)(const wchar_t*);

static AowlGetProcAddress aowl_il2_real_gpa    = NULL;
static AowlIl2CppInit     aowl_il2_real_init   = NULL;
static AowlIl2CppInitW    aowl_il2_real_init_w = NULL;

/* The wrapper handed to UnityPlayer in place of `il2cpp_init`.
 *
 * The flag is set *after* the call returns, deliberately. A host that started
 * resolving types while the runtime was still building them would be the same
 * bug one layer down, and harder to see because it would usually work. */
static int aowl_il2_init_thunk(const char* domainName) {
    int rc;
    if (!aowl_il2_real_init) return 0;
    rc = aowl_il2_real_init(domainName);
    aowl_il2_init_calls++;
    aowl_il2_init_result = (int32_t)rc;
    /* Only a *successful* init means there is a domain.
     *
     * Setting the flag on any return was this file's own version of the bug it
     * was written to fix. On the first real client `il2cpp_init` returned 0 --
     * a failure -- 100ms into the process, the host took that as ready, asked
     * for the domain and faulted in exactly the place the polling version had.
     * A signal that fires whether or not the thing happened is not a signal.
     *
     * `il2cpp_init` returns non-zero on success. A zero is recorded and
     * counted and deliberately does not arm anything: if a later call
     * succeeds, that one arms it, and if none ever does, the host waits out
     * its timeout and reports how many times init was called and what the last
     * one answered. That is a diagnosis. A crash is not. */
    if (rc != 0) InterlockedExchange(&aowl_il2_ready, 1);
    return rc;
}

/* The same, for the wide entry point. Two thunks rather than one with a flag,
 * because the argument types genuinely differ and calling a `const char*`
 * function through a `const wchar_t*` pointer is undefined however carefully
 * it is spelled. */
static int aowl_il2_init_thunk_w(const wchar_t* domainName) {
    int rc;
    if (!aowl_il2_real_init_w) return 0;
    rc = aowl_il2_real_init_w(domainName);
    aowl_il2_init_calls++;
    aowl_il2_init_result = (int32_t)rc;
    if (rc != 0) InterlockedExchange(&aowl_il2_ready, 1);
    return rc;
}

static FARPROC WINAPI aowl_il2_GetProcAddress(HMODULE mod, LPCSTR name) {
    FARPROC real;
    if (!aowl_il2_real_gpa) return NULL;
    real = aowl_il2_real_gpa(mod, name);
    /* `name` is an ordinal rather than a string when its upper bits are zero;
     * dereferencing one as a pointer is a fault. This is the documented test
     * and it has to come before any read of the characters. */
    if (real && name && ((ULONG_PTR)name >> 16) != 0) {
        aowl_il2_lookups++;
        if (aowl_iat_eq_ci((const char*)name, "il2cpp_init")) {
            aowl_il2_real_init = (AowlIl2CppInit)real;
            aowl_il2_init_seen++;
            return (FARPROC)aowl_il2_init_thunk;
        }
        /* `GameAssembly.dll` exports both spellings -- `il2cpp_init` at
         * ordinal 154 and `il2cpp_init_utf16` at 155 -- and which one a build
         * calls is not knowable from here. Watching only one would mean a
         * client that used the other waited out its timeout with the arming
         * reported as successful, which is the most misleading report this
         * file could produce. */
        if (aowl_iat_eq_ci((const char*)name, "il2cpp_init_utf16")) {
            aowl_il2_real_init_w = (AowlIl2CppInitW)real;
            aowl_il2_init_seen++;
            return (FARPROC)aowl_il2_init_thunk_w;
        }
    }
    return real;
}

static const AowlIatPatch aowl_il2_patches[] = {
    { "GetProcAddress", (void*)aowl_il2_GetProcAddress,
      (void**)&aowl_il2_real_gpa },
};

/* Called from the constructor, before the game's main thread is resumed. */
static void aowl_il2_ready_arm(void) {
    HMODULE m = GetModuleHandleA("UnityPlayer.dll");
    if (!m) return;
    aowl_il2_module = 1;
    aowl_il2_armed = aowl_iat_patch(m, aowl_il2_patches, 1, &aowl_il2_looked);
}

/* Read by the host's wait loop and its log. */
static int32_t aowl_il2_is_ready(void)    { return aowl_il2_ready ? 1 : 0; }
static int32_t aowl_il2_guard_armed(void) { return aowl_il2_armed; }
static int32_t aowl_il2_guard_module(void){ return aowl_il2_module; }
static int32_t aowl_il2_guard_seen(void)  { return aowl_il2_init_seen; }
static int32_t aowl_il2_guard_rc(void)    { return aowl_il2_init_result; }
static int32_t aowl_il2_guard_calls(void) { return aowl_il2_init_calls; }

#endif /* AOWLSPT_IL2CPPREADY_H */
