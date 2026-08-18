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
    HANDLE t = CreateThread(NULL, 0, aowl_host_thread, NULL, 0, NULL);
    if (t) CloseHandle(t);
}

#endif /* AOWLSPT_HOSTBOOT_H */
