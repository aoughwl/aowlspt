/* aowlspt_hostboot.h — getting the client host running inside the game.
 *
 * The host is a native DLL injected into `EscapeFromTarkov.exe`. Something has
 * to start it once it is in there, and that something cannot be nimony: the
 * entry point is `DllMain`, which nimony's `--app:lib` output already owns and
 * uses to initialise its runtime.
 *
 * So a C constructor starts a thread, and the thread calls into nimony.
 *
 * Two details matter and both are deliberate:
 *
 *   * The work happens on a *new thread*, not in the constructor. Constructors
 *     run under the loader lock, where almost everything -- LoadLibrary, most
 *     of the CRT, anything that might wait on another thread -- deadlocks.
 *     `CreateThread` is one of the few calls that is safe there, and the thread
 *     it creates does not begin running until the lock is released.
 *
 *   * Because it does not begin running until then, nimony's own `DllMain` has
 *     already initialised its runtime by the time any nimony code executes.
 *     Getting this backwards is the difference between a mod loader and a
 *     crash-on-launch.
 */

#ifndef AOWLSPT_HOSTBOOT_H
#define AOWLSPT_HOSTBOOT_H

#include <windows.h>
#include <stdint.h>

/* The one thing that cannot wait for the thread. A post-1.0 client refuses to
 * start unless the BattlEye service is running, and it decides that before
 * Unity brings IL2CPP up -- so before the boot thread below has run a single
 * instruction. `aowlspt_beguard.h` explains the check, the evidence for it,
 * and why it is answered by patching one module's import table from here
 * rather than by the detour engine from there. */
#include "aowlspt_beguard.h"

/* And the other thing that cannot wait, for the opposite reason. The host has
 * to know when IL2CPP has finished initialising, and the only safe way to know
 * is to watch `UnityPlayer.dll` look `il2cpp_init` up -- which it does long
 * after this runs, but through a pointer that has to be in place before it
 * runs. `aowlspt_il2cppready.h` has the crash that established this. */
#include "aowlspt_il2cppready.h"

/* The `aowl_sys_*` helpers this used to carry now live in `aowlspt_shim.h`:
 * the backend needs them too and does not want the constructor below, which
 * calls a symbol only the client host defines. */

/* Implemented in nimony. */
extern void aowlspt_nim_host_main(void);

static DWORD WINAPI aowl_host_thread(LPVOID param) {
    (void)param;
    aowlspt_nim_host_main();
    return 0;
}

__attribute__((constructor))
static void aowl_host_boot(void) {
    HANDLE t;
    /* Before the thread, and deliberately: the injector resumes the game's
     * main thread as soon as `LoadLibrary` returns, and the thread created
     * below does not start until the loader lock is released. Anything the
     * guard has to beat has to be beaten here. It reads PE headers and writes
     * pointers -- no loader call, nothing that can wait -- which is the whole
     * reason it is safe in a constructor when nothing else here is. */
    aowl_be_guard_arm();
    aowl_il2_ready_arm();
    t = CreateThread(NULL, 0, aowl_host_thread, NULL, 0, NULL);
    if (t) CloseHandle(t);
}

#endif /* AOWLSPT_HOSTBOOT_H */
