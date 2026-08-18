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

/* ------------------------------------------------------------------ *
 * Small Win32 services the host needs and nimony's stdlib does not have
 * ------------------------------------------------------------------ */

/* Where this DLL is on disk. The host reads its mods and writes its log
 * relative to itself, so that an install can be moved without reconfiguring
 * anything. Resolved from the address of a function in this module rather than
 * from a stored HINSTANCE, since a constructor is not handed one. */
static int32_t aowl_sys_module_path(char* buf, int32_t cap) {
    HMODULE self = NULL;
    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCSTR)(void*)&aowl_host_boot, &self)) {
        return 0;
    }
    return (int32_t)GetModuleFileNameA(self, buf, (DWORD)cap);
}

static uint64_t aowl_sys_now_ms(void) {
    return (uint64_t)GetTickCount64();
}

static void aowl_sys_sleep(int32_t ms) {
    Sleep((DWORD)ms);
}

static uint32_t aowl_sys_thread_id(void) {
    return (uint32_t)GetCurrentThreadId();
}

/* Loading a mod. Kept here beside the rest of the Win32 surface rather than
 * imported separately in nimony, so there is one place that knows how a mod
 * becomes a module. */
static void* aowl_sys_load_library(const char* path) {
    return (void*)LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
}
static void aowl_sys_free_library(void* h) {
    if (h) FreeLibrary((HMODULE)h);
}
static void* aowl_sys_get_proc(void* h, const char* name) {
    if (!h) return NULL;
    return (void*)GetProcAddress((HMODULE)h, name);
}
static uint32_t aowl_sys_last_error(void) {
    return (uint32_t)GetLastError();
}

#endif /* AOWLSPT_HOSTBOOT_H */
