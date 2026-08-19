/* aowlspt_inject.h — starting the game with the host inside it.
 *
 * The client host is a native DLL and something has to put it in the game's
 * process. The usual answer in Unity modding is DLL hijacking: drop a fake
 * `winhttp.dll` or `version.dll` next to the executable, let the loader pick it
 * up, and forward every export to the real system copy. It works, and it has
 * two properties worth avoiding — it depends on the exact set of exports the
 * system DLL has on the machine it runs on, and it leaves a file in the install
 * that impersonates a Windows component.
 *
 * This does it explicitly instead: start the process suspended, load the DLL
 * into it, resume. The game starts with the host already inside and nothing in
 * the install pretends to be something it is not.
 *
 * The mechanism is the standard one, and the ordering is what matters:
 *
 *   1. `CreateProcess` with CREATE_SUSPENDED. The process exists, its main
 *      thread has not run an instruction, and kernel32 is already mapped.
 *   2. Write the DLL path into the target with `VirtualAllocEx` +
 *      `WriteProcessMemory`.
 *   3. `CreateRemoteThread` at `LoadLibraryA`. This works because kernel32 is
 *      loaded at the same base address in every process in a session, so our
 *      `LoadLibraryA` and theirs are the same address.
 *   4. Wait for that thread, and read its exit code — which is the low 32 bits
 *      of the returned HMODULE. Zero means the load failed, and finding that
 *      out here rather than from a silent no-op later is the point of waiting.
 *   5. Resume the main thread.
 *
 * Step 4 is the one people skip. Without it a failed injection looks exactly
 * like a successful one until the mods do not appear.
 */

#ifndef AOWLSPT_INJECT_H
#define AOWLSPT_INJECT_H

#include <windows.h>
#include <stdint.h>
/* `calloc`/`free` for the launch record and for the mutable command line
 * `CreateProcess` insists on; `strlen`/`memcpy` for building it. Named here
 * rather than relied on: on the UCRT headers `windows.h` reaches `string.h`
 * and `stdlib.h` on its own -- `gcc -H` shows the chain -- which is why this
 * has always compiled with neither line present. That is a property of one
 * toolchain's headers and not of this file, and the day it stops being true
 * the failure is `calloc` implicitly declared as returning `int`, which on a
 * 64-bit target truncates the pointer rather than refusing to build. */
#include <stdlib.h>
#include <string.h>

typedef struct AowlLaunch {
    uint32_t pid;
    void*    process;
    void*    thread;
    uint32_t error;
    int32_t  injected;
} AowlLaunch;

static int32_t aowl_launch_sizeof(void) { return (int32_t)sizeof(AowlLaunch); }

static void* aowl_launch_new(void) {
    AowlLaunch* l = (AowlLaunch*)calloc(1, sizeof(AowlLaunch));
    return l;
}
static void     aowl_launch_free(void* p)      { free(p); }
static uint32_t aowl_launch_pid(void* p)       { return ((AowlLaunch*)p)->pid; }
static uint32_t aowl_launch_error(void* p)     { return ((AowlLaunch*)p)->error; }
static int32_t  aowl_launch_injected(void* p)  { return ((AowlLaunch*)p)->injected; }

/* Start `exePath` suspended, with `workDir` as its working directory. The game
 * resolves its data directory relative to the working directory, so getting
 * this wrong produces a client that starts and then cannot find itself. */
static int32_t aowl_launch_start(void* handle, const char* exePath,
                                 const char* workDir, const char* cmdLine) {
    AowlLaunch* l = (AowlLaunch*)handle;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    char* mutableCmd = NULL;

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    /* CreateProcessA may write to its command line argument, so it cannot be
     * given a literal or a const buffer. */
    if (cmdLine && cmdLine[0]) {
        size_t n = strlen(cmdLine);
        mutableCmd = (char*)calloc(1, n + 1);
        if (!mutableCmd) { l->error = ERROR_OUTOFMEMORY; return 0; }
        memcpy(mutableCmd, cmdLine, n);
    }

    BOOL ok = CreateProcessA(exePath, mutableCmd, NULL, NULL, FALSE,
                             CREATE_SUSPENDED, NULL, workDir, &si, &pi);
    if (!ok) {
        l->error = GetLastError();
        free(mutableCmd);
        return 0;
    }
    free(mutableCmd);

    l->pid     = (uint32_t)pi.dwProcessId;
    l->process = (void*)pi.hProcess;
    l->thread  = (void*)pi.hThread;
    l->error   = 0;
    return 1;
}

static int32_t aowl_launch_inject(void* handle, const char* dllPath) {
    AowlLaunch* l = (AowlLaunch*)handle;
    HANDLE proc = (HANDLE)l->process;
    size_t bytes = strlen(dllPath) + 1;

    void* remote = VirtualAllocEx(proc, NULL, bytes, MEM_COMMIT | MEM_RESERVE,
                                  PAGE_READWRITE);
    if (!remote) { l->error = GetLastError(); return 0; }

    SIZE_T written = 0;
    if (!WriteProcessMemory(proc, remote, dllPath, bytes, &written) ||
        written != bytes) {
        l->error = GetLastError();
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        return 0;
    }

    /* kernel32 sits at the same base in every process in a session, so this
     * address is valid in the target. */
    HMODULE k32 = GetModuleHandleA("kernel32.dll");
    FARPROC loadLibrary = k32 ? GetProcAddress(k32, "LoadLibraryA") : NULL;
    if (!loadLibrary) { l->error = GetLastError(); return 0; }

    HANDLE rt = CreateRemoteThread(proc, NULL, 0,
                                   (LPTHREAD_START_ROUTINE)loadLibrary,
                                   remote, 0, NULL);
    if (!rt) {
        l->error = GetLastError();
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        return 0;
    }

    /* 30s is generous for a LoadLibrary; the host's own constructor returns
     * immediately, since all it does is start a thread. */
    DWORD waited = WaitForSingleObject(rt, 30000);
    DWORD exitCode = 0;
    GetExitCodeThread(rt, &exitCode);
    CloseHandle(rt);
    VirtualFreeEx(proc, remote, 0, MEM_RELEASE);

    if (waited != WAIT_OBJECT_0) {
        l->error = ERROR_TIMEOUT;
        return 0;
    }

    /* The remote thread's exit code is the low 32 bits of the HMODULE that
     * LoadLibraryA returned. Zero means it failed -- and on a 64-bit target a
     * non-zero value here is the truncated handle, which is fine as a
     * success/failure signal and useless as a handle. */
    if (exitCode == 0) {
        l->error = ERROR_MOD_NOT_FOUND;
        return 0;
    }

    l->injected = 1;
    l->error = 0;
    return 1;
}

static int32_t aowl_launch_resume(void* handle) {
    AowlLaunch* l = (AowlLaunch*)handle;
    if (ResumeThread((HANDLE)l->thread) == (DWORD)-1) {
        l->error = GetLastError();
        return 0;
    }
    return 1;
}

static void aowl_launch_kill(void* handle) {
    AowlLaunch* l = (AowlLaunch*)handle;
    if (l->process) TerminateProcess((HANDLE)l->process, 1);
}

static void aowl_launch_close(void* handle) {
    AowlLaunch* l = (AowlLaunch*)handle;
    if (l->thread) { CloseHandle((HANDLE)l->thread); l->thread = NULL; }
    if (l->process) { CloseHandle((HANDLE)l->process); l->process = NULL; }
}

/* Whether the target is still running, so the launcher can report an early
 * exit rather than claiming success and disappearing. */
static int32_t aowl_launch_alive(void* handle) {
    AowlLaunch* l = (AowlLaunch*)handle;
    DWORD code = 0;
    if (!l->process) return 0;
    if (!GetExitCodeProcess((HANDLE)l->process, &code)) return 0;
    return code == STILL_ACTIVE;
}

/* Starting a companion process — the backend — and leaving it running.
 *
 * Separate from `aowl_launch_start` because nothing is injected into it and it
 * must not be suspended: the client will try to reach it as soon as it starts,
 * so it has to be up first. */
static uint64_t aowl_spawn(const char* exePath, const char* workDir,
                           const char* cmdLine) {
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    char* mutableCmd = NULL;

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    if (cmdLine && cmdLine[0]) {
        size_t n = strlen(cmdLine);
        mutableCmd = (char*)calloc(1, n + 1);
        if (!mutableCmd) return 0;
        memcpy(mutableCmd, cmdLine, n);
    }

    BOOL ok = CreateProcessA(exePath, mutableCmd, NULL, NULL, FALSE,
                             CREATE_NEW_CONSOLE, NULL, workDir, &si, &pi);
    free(mutableCmd);
    if (!ok) return 0;
    CloseHandle(pi.hThread);
    return (uint64_t)(uintptr_t)pi.hProcess;
}

/* The same spawn with no console of its own.
 *
 * `aowl_spawn` above asks for CREATE_NEW_CONSOLE, which is right for a tool
 * that starts one server and wants its log where a person can watch it. It is
 * wrong for a test that starts and kills a process dozens of times in a row:
 * that flashes a window across the screen of whoever happens to be using the
 * machine, and a test people turn off has stopped testing anything.
 */
static uint64_t aowl_spawn_quiet(const char* exePath, const char* workDir,
                                 const char* cmdLine) {
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    char* mutableCmd = NULL;

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    ZeroMemory(&pi, sizeof(pi));

    if (cmdLine && cmdLine[0]) {
        size_t n = strlen(cmdLine);
        mutableCmd = (char*)calloc(1, n + 1);
        if (!mutableCmd) return 0;
        memcpy(mutableCmd, cmdLine, n);
    }

    BOOL ok = CreateProcessA(exePath, mutableCmd, NULL, NULL, FALSE,
                             CREATE_NO_WINDOW, NULL, workDir, &si, &pi);
    free(mutableCmd);
    if (!ok) return 0;
    CloseHandle(pi.hThread);
    return (uint64_t)(uintptr_t)pi.hProcess;
}

static int32_t aowl_spawn_alive(uint64_t handle) {
    DWORD code = 0;
    if (!handle) return 0;
    if (!GetExitCodeProcess((HANDLE)(uintptr_t)handle, &code)) return 0;
    return code == STILL_ACTIVE;
}

/* Kill it, and wait for it to actually be dead before letting the handle go.
 *
 * `TerminateProcess` is asynchronous: it returns as soon as the kill is
 * requested, so a caller that immediately re-binds the port or re-opens the
 * store can lose a race against a process that is still exiting. One second is
 * far longer than that takes and far shorter than a hang.
 *
 * The handle is closed here, which means an exit code cannot be read
 * afterwards -- `aowl_spawn_alive` on a closed handle answers about nothing.
 * A tool that kills a child and then asks how it died must read the code
 * *before* calling this. That has already produced one wrong answer: a test
 * reported a server as having crashed when another agent's cleanup had killed
 * it by image name. */
static void aowl_spawn_kill(uint64_t handle) {
    if (handle) {
        TerminateProcess((HANDLE)(uintptr_t)handle, 0);
        WaitForSingleObject((HANDLE)(uintptr_t)handle, 1000);
        CloseHandle((HANDLE)(uintptr_t)handle);
    }
}

/* The exit code, while the handle is still open. `STILL_ACTIVE` (259) means it
 * has not exited; anything with the high bit set is a fault rather than an
 * ordinary exit, and the difference decides whether a request killed a server
 * or something outside the test did. */
static int32_t aowl_spawn_exit_code(uint64_t handle) {
    DWORD code = 0;
    if (!handle) return -1;
    if (!GetExitCodeProcess((HANDLE)(uintptr_t)handle, &code)) return -1;
    return (int32_t)code;
}

static int32_t aowl_launch_wait(void* handle, int32_t ms) {
    AowlLaunch* l = (AowlLaunch*)handle;
    if (!l->process) return 0;
    return WaitForSingleObject((HANDLE)l->process, (DWORD)ms) == WAIT_OBJECT_0;
}

#endif /* AOWLSPT_INJECT_H */
