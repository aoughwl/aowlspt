/* aowlspt_beguard.h — letting a post-1.0 client boot without BattlEye.
 *
 * Post-1.0 `EscapeFromTarkov.exe` will not start unless the BattlEye service
 * is running. That is not BattlEye refusing; it is BSG's own code, in a
 * modified `UnityPlayer.dll`, and it is checked before Unity brings IL2CPP up.
 * The evidence is in the binary itself:
 *
 *     BEService
 *     The required BattlEye service does not exist.
 *     The required BattlEye service is not running.
 *     .?AV?$_Fake_no_copy_callable_adapter@P8BattlEyeService@Guard@BSG@@...
 *
 * and in its import table, which stock Unity does not have:
 *
 *     ADVAPI32.dll  OpenSCManagerA, OpenServiceA,
 *                   QueryServiceStatusEx, CloseServiceHandle
 *
 * `BSG::Guard::BattlEyeService` opens the service manager, opens `BEService`,
 * asks for its status, and refuses to continue unless it reads
 * `SERVICE_RUNNING`. Both of its failure messages were observed on this
 * machine on 2026-08-19: "does not exist" against a target with no `BattlEye\`
 * directory, and "is not running" once the directory was copied in.
 *
 * ## What this does, and what it deliberately does not
 *
 * It answers that one question, for that one caller, and nothing else. The
 * modded client plays against a backend on `127.0.0.1` and never contacts
 * BSG, so there is no live service being deceived here -- the alternative to
 * this file is not "BattlEye protects something", it is "the game does not
 * start". What it replaces is the *other* way to get a post-1.0 client to
 * boot, which is to install and run BattlEye for real, let it load into a
 * process with an injected DLL in it, and let it report that to BattlEye's
 * infrastructure keyed to the machine. This avoids all of that: BattlEye is
 * never installed, never started, and never loaded.
 *
 * ## Why the import table and not the functions
 *
 * Two reasons, and the second is the one that decides it.
 *
 * Patching `QueryServiceStatusEx` itself would change the answer for every
 * caller in the process. Patching `UnityPlayer.dll`'s IAT changes it for
 * `UnityPlayer.dll` alone, which is the only module in the install that
 * imports those four symbols at all. A mod, the overlay or the CRT asking the
 * service manager a real question still gets a real answer.
 *
 * And this has to run in the constructor, under the loader lock, which rules
 * out the detour engine and rules out `GetProcAddress`. `QueryServiceStatusEx`
 * is a *forwarded* export on modern Windows -- advapi32 forwards it to
 * sechost.dll -- and resolving a forwarder can make the loader map a module,
 * which under its own lock is a deadlock. Reading an already-mapped PE's
 * import descriptors and writing one pointer through `VirtualProtect` touches
 * the loader not at all.
 *
 * It has to be the constructor rather than the host's boot thread because of
 * how injection is ordered (`aowlspt_inject.h`): the injector waits for
 * `LoadLibrary` to return before it resumes the game's main thread, so
 * anything done here is done before the guard can run. The boot thread does
 * not start until the loader lock is released, which is a race with that
 * resume -- and the guard would win it.
 *
 * ## Why there is no configuration switch
 *
 * The condition is its own switch. If the client in front of it does not
 * import those symbols into `UnityPlayer.dll` -- any Unity build that is not
 * BSG's -- there is nothing to patch and nothing is patched. Arming is
 * evidence that the guard is there.
 *
 * Nothing is logged from here: the host's log does not exist yet. Every
 * outcome is recorded in the counters below and `aowlhost.nim` reports them
 * once there is somewhere to report to. A guard that patched nothing and a
 * guard that was never reached must not look alike in that log, so "not
 * armed" and "no such import" are different states rather than one absence.
 */

#ifndef AOWLSPT_BEGUARD_H
#define AOWLSPT_BEGUARD_H

#include <windows.h>
#include <stdint.h>
#include "aowlspt_iat.h"

/* The sentinels handed back in place of real service-manager handles. They are
 * never passed to the service manager, so their only requirement is that they
 * cannot collide with a real SC_HANDLE. Odd values do that: a real handle is
 * a kernel object pointer and is machine-word aligned. */
#define AOWL_BE_SCM_SENTINEL  ((SC_HANDLE)(ULONG_PTR)0xBE5C0001u)
#define AOWL_BE_SVC_SENTINEL  ((SC_HANDLE)(ULONG_PTR)0xBE5C0003u)

/* What the guard did, read by `aowlhost.nim` once the log is open. */
static int32_t aowl_be_armed      = 0;  /* IAT entries successfully patched   */
static int32_t aowl_be_looked     = 0;  /* import descriptors examined        */
static int32_t aowl_be_module     = 0;  /* UnityPlayer.dll was found         */
static int32_t aowl_be_scm_calls  = 0;  /* OpenSCManagerA went through us     */
static int32_t aowl_be_svc_calls  = 0;  /* OpenServiceA asked for BEService   */
static int32_t aowl_be_answered   = 0;  /* a status query was answered by us  */
static int32_t aowl_be_passed     = 0;  /* a call we let through untouched    */

/* The originals, captured as the IAT is patched. A slot we failed to patch
 * leaves its pointer NULL, and every replacement below checks that before
 * calling through -- a guard that crashed the client on the way to helping it
 * would be worse than the refusal it exists to remove. */
typedef SC_HANDLE (WINAPI *AowlOpenSCManagerA)(LPCSTR, LPCSTR, DWORD);
typedef SC_HANDLE (WINAPI *AowlOpenServiceA)(SC_HANDLE, LPCSTR, DWORD);
typedef BOOL      (WINAPI *AowlQueryServiceStatusEx)(SC_HANDLE, SC_STATUS_TYPE,
                                                     LPBYTE, DWORD, LPDWORD);
typedef BOOL      (WINAPI *AowlCloseServiceHandle)(SC_HANDLE);

static AowlOpenSCManagerA       aowl_be_real_scm   = NULL;
static AowlOpenServiceA         aowl_be_real_open  = NULL;
static AowlQueryServiceStatusEx aowl_be_real_query = NULL;
static AowlCloseServiceHandle   aowl_be_real_close = NULL;

/* --- the replacements -------------------------------------------------- */

/* The service manager handle is passed through when the real call works, so
 * that a genuine handle keeps flowing to any caller we did not intend to
 * intercept. Only when the real call fails do we hand back a sentinel, which
 * keeps `BSG::Guard` walking forward to the question we can actually answer.
 */
static SC_HANDLE WINAPI aowl_be_OpenSCManagerA(LPCSTR machine, LPCSTR db,
                                               DWORD access) {
    SC_HANDLE h;
    aowl_be_scm_calls++;
    if (!aowl_be_real_scm) return AOWL_BE_SCM_SENTINEL;
    h = aowl_be_real_scm(machine, db, access);
    return h ? h : AOWL_BE_SCM_SENTINEL;
}

/* `BEService` is answered; every other service name is none of our business
 * and goes to the real service manager, including from this same module. */
static SC_HANDLE WINAPI aowl_be_OpenServiceA(SC_HANDLE scm, LPCSTR name,
                                             DWORD access) {
    if (!aowl_iat_eq_ci(name, "BEService")) {
        aowl_be_passed++;
        if (!aowl_be_real_open || scm == AOWL_BE_SCM_SENTINEL) {
            SetLastError(ERROR_SERVICE_DOES_NOT_EXIST);
            return NULL;
        }
        return aowl_be_real_open(scm, name, access);
    }
    aowl_be_svc_calls++;
    /* The real service is not consulted even when it exists. Asking would make
     * the answer depend on whether BattlEye happens to be installed on this
     * machine, which is exactly the dependency this removes -- and on a
     * machine where it *is* installed and running, consulting it would arm
     * nothing and quietly leave the behaviour untested. */
    return AOWL_BE_SVC_SENTINEL;
}

static BOOL WINAPI aowl_be_QueryServiceStatusEx(SC_HANDLE h, SC_STATUS_TYPE lvl,
                                                LPBYTE buf, DWORD cb,
                                                LPDWORD needed) {
    SERVICE_STATUS_PROCESS* st;
    if (h != AOWL_BE_SVC_SENTINEL) {
        aowl_be_passed++;
        if (!aowl_be_real_query) {
            SetLastError(ERROR_INVALID_HANDLE);
            return FALSE;
        }
        return aowl_be_real_query(h, lvl, buf, cb, needed);
    }
    if (lvl != SC_STATUS_PROCESS_INFO) {
        SetLastError(ERROR_INVALID_LEVEL);
        return FALSE;
    }
    if (!buf || cb < sizeof(SERVICE_STATUS_PROCESS)) {
        if (needed) *needed = (DWORD)sizeof(SERVICE_STATUS_PROCESS);
        SetLastError(ERROR_INSUFFICIENT_BUFFER);
        return FALSE;
    }
    st = (SERVICE_STATUS_PROCESS*)buf;
    st->dwServiceType             = SERVICE_WIN32_OWN_PROCESS;
    st->dwCurrentState            = SERVICE_RUNNING;
    st->dwControlsAccepted        = SERVICE_ACCEPT_STOP;
    st->dwWin32ExitCode           = NO_ERROR;
    st->dwServiceSpecificExitCode = 0;
    st->dwCheckPoint              = 0;
    st->dwWaitHint                = 0;
    st->dwProcessId               = GetCurrentProcessId();
    st->dwServiceFlags            = 0;
    if (needed) *needed = (DWORD)sizeof(SERVICE_STATUS_PROCESS);
    aowl_be_answered++;
    return TRUE;
}

static BOOL WINAPI aowl_be_CloseServiceHandle(SC_HANDLE h) {
    if (h == AOWL_BE_SVC_SENTINEL || h == AOWL_BE_SCM_SENTINEL) return TRUE;
    aowl_be_passed++;
    if (!aowl_be_real_close) return TRUE;
    return aowl_be_real_close(h);
}

/* --- patching the import table ----------------------------------------- */

static const AowlIatPatch aowl_be_patches[] = {
    { "OpenSCManagerA",     (void*)aowl_be_OpenSCManagerA,
      (void**)&aowl_be_real_scm },
    { "OpenServiceA",       (void*)aowl_be_OpenServiceA,
      (void**)&aowl_be_real_open },
    { "QueryServiceStatusEx", (void*)aowl_be_QueryServiceStatusEx,
      (void**)&aowl_be_real_query },
    { "CloseServiceHandle", (void*)aowl_be_CloseServiceHandle,
      (void**)&aowl_be_real_close },
};

/* Called from the constructor. `GetModuleHandleA` on an already-mapped module
 * is a lookup in the loader's list and does not load anything, which is what
 * makes it usable here where `GetProcAddress` on a forwarder is not. */
static void aowl_be_guard_arm(void) {
    HMODULE m = GetModuleHandleA("UnityPlayer.dll");
    if (!m) return;
    aowl_be_module = 1;
    aowl_be_armed = aowl_iat_patch(m, aowl_be_patches, 4, &aowl_be_looked);
}

/* Read by the host once its log exists. */
static int32_t aowl_be_guard_armed(void)    { return aowl_be_armed; }
static int32_t aowl_be_guard_module(void)   { return aowl_be_module; }
static int32_t aowl_be_guard_looked(void)   { return aowl_be_looked; }
static int32_t aowl_be_guard_answered(void) { return aowl_be_answered; }
static int32_t aowl_be_guard_scm(void)      { return aowl_be_scm_calls; }
static int32_t aowl_be_guard_opened(void)   { return aowl_be_svc_calls; }
static int32_t aowl_be_guard_passed(void)   { return aowl_be_passed; }

#endif /* AOWLSPT_BEGUARD_H */
