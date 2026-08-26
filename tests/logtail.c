/* logtail -- does a log sink lose its tail when the process dies hard?
 *
 * The host log is written by `modhost.logLine`, which on this toolchain
 * lowers to the Win32 sequence in `std/syncio`'s nimNativeIo path:
 *     CreateFileW(FILE_APPEND_DATA, OPEN_ALWAYS) / WriteFile / CloseHandle
 * per line. The leading hypothesis for the missing tail was that the sink is
 * a buffered stream whose last partial buffer dies with the process.
 *
 * This harness reproduces THREE sink shapes and, for each, kills the writer
 * two ways: a clean exit (control -- nothing may be lost) and a hard death
 * (TerminateProcess of self, and an access violation with no handler --
 * the two shapes a live client dies in). It then counts surviving records.
 *
 * A shape that survives the hard death cannot be the mechanism. A shape that
 * loses records under hard death and not under clean exit IS one, and the
 * harness prints how many it lost, so the claim is a number and not a story.
 *
 * Scope, stated because it bounds every conclusion drawn from it: this
 * measures the OS/CRT layer that `syncio` emits. It does NOT exercise
 * nimony codegen. A defect in the nimony layer would not show up here, and
 * this harness must never be quoted as proving one absent.
 *
 * build:  gcc -O2 -o logtail.exe tests/logtail.c
 * run:    logtail.exe            (parent: runs the whole matrix)
 *         logtail.exe child MODE DEATH N PATH   (one writer)
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REC_CAP 100000

/* ---- sink shapes ------------------------------------------------------- */

/* 0: "closepl" -- open/write/close per line, Win32, no CRT stream.
 *    This is what `modhost.logLine` compiles to today. */
static void sink_closepl(const char *path, const char *text) {
    wchar_t wpath[MAX_PATH];
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, MAX_PATH);
    HANDLE h = CreateFileW(wpath, FILE_APPEND_DATA,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;   /* silently dropped -- see report */
    DWORD wrote = 0;
    WriteFile(h, text, (DWORD)strlen(text), &wrote, NULL);
    CloseHandle(h);
}

/* 1: "stream" -- one FILE* held open, default buffering. The hypothesis. */
static FILE *g_stream = NULL;
static void sink_stream(const char *path, const char *text) {
    if (!g_stream) g_stream = fopen(path, "ab");
    if (!g_stream) return;
    fputs(text, g_stream);
}

/* 2: "crumb" -- one handle held open, WriteFile + FlushFileBuffers per
 *    record. What the hand-rolled breadcrumb file did, and what the
 *    first-class facility does. Write-through to the device. */
static HANDLE g_crumb = INVALID_HANDLE_VALUE;
static void sink_crumb(const char *path, const char *text) {
    if (g_crumb == INVALID_HANDLE_VALUE) {
        wchar_t wpath[MAX_PATH];
        MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, MAX_PATH);
        g_crumb = CreateFileW(wpath, FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (g_crumb == INVALID_HANDLE_VALUE) return;
    }
    DWORD wrote = 0;
    WriteFile(g_crumb, text, (DWORD)strlen(text), &wrote, NULL);
    FlushFileBuffers(g_crumb);
}

/* 3: "held" -- one handle held open, WriteFile per record, NO
 *    FlushFileBuffers. The write leaves the process on every record and
 *    lands in the OS file cache, which outlives the process; only losing
 *    the machine loses it. This is what the fix uses. */
static HANDLE g_held = INVALID_HANDLE_VALUE;
static void sink_held(const char *path, const char *text) {
    if (g_held == INVALID_HANDLE_VALUE) {
        wchar_t wpath[MAX_PATH];
        MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, MAX_PATH);
        g_held = CreateFileW(wpath, FILE_APPEND_DATA,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                             OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (g_held == INVALID_HANDLE_VALUE) return;
    }
    DWORD wrote = 0;
    WriteFile(g_held, text, (DWORD)strlen(text), &wrote, NULL);
}

typedef void (*SinkFn)(const char *, const char *);
#define NSINK 4
static const char *kSinkName[NSINK] = { "closepl", "stream", "crumb", "held" };
static SinkFn kSink[NSINK] = { sink_closepl, sink_stream, sink_crumb, sink_held };

/* ---- child ------------------------------------------------------------- */

static int child(int mode, int death, int n, const char *path) {
    char line[128];
    DeleteFileA(path);
    for (int i = 1; i <= n; i++) {
        snprintf(line, sizeof line, "record %d\n", i);
        kSink[mode](path, line);
    }
    if (death == 0) {                       /* clean: the control */
        if (g_stream) fclose(g_stream);
        if (g_crumb != INVALID_HANDLE_VALUE) CloseHandle(g_crumb);
        if (g_held != INVALID_HANDLE_VALUE) CloseHandle(g_held);
        return 0;
    }
    if (death == 1) {                       /* the hard death the brief names */
        TerminateProcess(GetCurrentProcess(), 3);
    }
    { volatile int *p = (int *)0; *p = 1; } /* unhandled AV */
    return 0;
}

/* ---- parent ------------------------------------------------------------ */

static int count_records(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    int n = 0, c;
    while ((c = fgetc(f)) != EOF) if (c == '\n') n++;
    fclose(f);
    return n;
}

static int run_one(const char *self, int mode, int death, int n,
                   const char *path) {
    char cmd[1024];
    snprintf(cmd, sizeof cmd, "\"%s\" child %d %d %d \"%s\"",
             self, mode, death, n, path);
    STARTUPINFOA si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof si); si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);
    /* No WER dialog for the AV child, and no debugger attach. */
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE,
                        CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) return -2;
    WaitForSingleObject(pi.hProcess, 30000);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return count_records(path);
}

/* Cost, measured rather than assumed: microseconds per record for each
 * shape, since this sink runs on the Unity main thread. */
static void cost(int mode, int n, const char *path) {
    DeleteFileA(path);
    g_stream = NULL; g_crumb = INVALID_HANDLE_VALUE; g_held = INVALID_HANDLE_VALUE;
    LARGE_INTEGER f, a, b; QueryPerformanceFrequency(&f);
    char line[128];
    QueryPerformanceCounter(&a);
    for (int i = 1; i <= n; i++) {
        snprintf(line, sizeof line, "record %d\n", i);
        kSink[mode](path, line);
    }
    QueryPerformanceCounter(&b);
    if (g_stream) { fclose(g_stream); g_stream = NULL; }
    if (g_crumb != INVALID_HANDLE_VALUE) { CloseHandle(g_crumb); g_crumb = INVALID_HANDLE_VALUE; }
    if (g_held != INVALID_HANDLE_VALUE) { CloseHandle(g_held); g_held = INVALID_HANDLE_VALUE; }
    double us = (double)(b.QuadPart - a.QuadPart) * 1e6 / (double)f.QuadPart;
    printf("  %-8s %8.1f us/record  (%d records)\n", kSinkName[mode], us / n, n);
}

int main(int argc, char **argv) {
    if (argc >= 6 && strcmp(argv[1], "child") == 0)
        return child(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), argv[5]);

    const int n = 200;
    char self[MAX_PATH]; GetModuleFileNameA(NULL, self, MAX_PATH);
    char tmp[MAX_PATH], path[MAX_PATH];
    GetTempPathA(MAX_PATH, tmp);
    snprintf(path, sizeof path, "%slogtail-probe.txt", tmp);

    static const char *deathName[3] = { "clean exit", "TerminateProcess", "access violation" };
    int fail = 0;
    printf("logtail: %d records pending, then the writer dies.\n\n", n);
    printf("  %-8s %-18s %8s %8s   %s\n", "sink", "death", "wrote", "survived", "verdict");
    for (int mode = 0; mode < NSINK; mode++) {
        for (int death = 0; death < 3; death++) {
            int got = run_one(self, mode, death, n, path);
            const char *verdict;
            if (got < 0) { verdict = "INCONCLUSIVE (no file)"; fail = 1; }
            else if (got == n) verdict = "kept the tail";
            else { verdict = "LOST THE TAIL"; }
            printf("  %-8s %-18s %8d %8d   %s\n",
                   kSinkName[mode], deathName[death], n, got, verdict);
        }
    }
    printf("\ncost per record (this machine, warm):\n");
    for (int mode = 0; mode < NSINK; mode++) cost(mode, 2000, path);
    DeleteFileA(path);
    return fail;
}
