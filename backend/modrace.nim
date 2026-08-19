## modrace -- a mod taken away while worker threads are inside its handler.
##
##     modrace [--workers 8] [--cycles 40] [--hold-ms 40] [--gap-us 400]
##             [--passes 24] [--mod PATH] [--unguarded]
##
## The last known use-after-free in this system is not in a table: it is in a
## **stack**. `matchRoute` copies a route out under the registration lock and
## lets go -- deliberately, because a handler may register a route and a walk
## holding the lock across the call would wait on itself -- and from that point
## the worker is carrying a function pointer into a mod's library with nothing
## holding the library open. The serve loop is free to reach `unloadOne` and
## `FreeLibrary` while that worker is between the copy and the call, or inside
## the call. Live mod control means this is a thing a player does from a panel,
## not a thing a fuzzer does.
##
## Every other gate here drives the backend over a socket, and none of them can
## see this: `livectl` toggles a mod between requests, so its unload never
## overlaps a handler. This is the missing shape -- workers calling into a mod
## while another thread takes it out from under them -- in one process, with no
## sockets in the way, exactly as `dbrace.nim` is for the database.
##
## **What it checks is not "did it survive".** A run of the broken code
## survives more often than not, and the survivals are worth nothing:
##
##  * **faults** -- a worker that takes an access violation is not allowed to
##    take the process with it. A vectored handler counts it, records where it
##    landed, and redirects the thread into `mr_worker_faulted`, so the run
##    *finishes* and reports the fault as a number rather than as an exit code
##    nobody can attribute. A call through a route into an unmapped image lands
##    here.
##  * **wrong answers** -- and this is the one a survival test can never see.
##    `LoadLibrary` of a path that was just freed maps the image at the same
##    base address, so a call that arrives late need not fault at all: it can
##    land in the *next* incarnation's live code and answer perfectly. Every
##    reply carries the generation the library was loaded as, and every worker
##    checks it against the generation it copied the route with. An answer from
##    the wrong incarnation is a wrong answer even though nothing crashed.
##  * **clean refusals are a pass, not a failure.** A worker that is turned
##    away because the mod is draining, and a worker that finds no route
##    because the mod is gone, have both been answered correctly -- that is a
##    503 and a 404 in the server. What may never happen is a worker that is
##    admitted and then handed something that is not a whole, current answer.
##
## `--unguarded` skips `modEnter`/`modLeave` and nothing else, which is exactly
## the code as it stood before the fix: the drain in `unloadOne` still runs, and
## still reads a count of zero because nobody took a reference. That is how the
## before-and-after is one binary and one command rather than two builds.
##
## The gap between copying the route and calling it is modelled rather than
## assumed. In the server that gap contains the **session lock**, which is
## allowed to wait ten seconds; `--gap-us` gives each worker a random slice of
## one up to the value given (400 us by default, a thousandth of what the real
## one allows) so that the window is entered from both halves -- some workers
## caught before the call, some inside it.

import std/[cmdline, syncio]
import aowlsptinstall/winfs
import modhost

{.emit: """#include <windows.h>""".}
{.emit: """#include <stdint.h>""".}
{.emit: """#include <stdio.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include <stdlib.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}

{.emit: """
/* The host surface the shim calls back into. The backend implements all of
 * these against a real server; a mod that only registers a route and answers
 * it needs none of them, and a stub that is never called is more honest here
 * than a second implementation that could drift. `alloc` and `free` are the
 * exceptions and they are the shim's own, not these. */
void    aowlspt_nim_log(void* ctx, int32_t level, void* msg, int32_t len) {
    (void)ctx; (void)level; (void)msg; (void)len;
}
void    aowlspt_nim_last_error(void* ctx, void* outPtr, void* outLen) {
    (void)ctx; *(void**)outPtr = NULL; *(int32_t*)outLen = 0;
}
int32_t aowlspt_nim_config_get(void* ctx, void* key, int32_t keyLen,
                               void* outPtr, void* outLen) {
    (void)ctx; (void)key; (void)keyLen;
    *(void**)outPtr = NULL; *(int32_t*)outLen = 0; return -3;
}
int32_t aowlspt_nim_config_set(void* ctx, void* key, int32_t keyLen,
                               void* val, int32_t valLen) {
    (void)ctx; (void)key; (void)keyLen; (void)val; (void)valLen; return -6;
}
int32_t aowlspt_nim_call(void* ctx, void* target, int32_t targetLen,
                         void* args, int32_t argsLen,
                         void* outPtr, void* outLen) {
    (void)ctx; (void)target; (void)targetLen; (void)args; (void)argsLen;
    *(void**)outPtr = NULL; *(int32_t*)outLen = 0; return -6;
}
int32_t aowlspt_nim_resolve(void* ctx, void* typeName, int32_t nameLen,
                            void* outHandle) {
    (void)ctx; (void)typeName; (void)nameLen; *(uint64_t*)outHandle = 0; return -6;
}
void    aowlspt_nim_handle_release(void* ctx, uint64_t handle) {
    (void)ctx; (void)handle;
}
int32_t aowlspt_nim_event_emit(void* ctx, void* name, int32_t nameLen,
                               void* payload, int32_t payloadLen) {
    (void)ctx; (void)name; (void)nameLen; (void)payload; (void)payloadLen;
    return 0;
}
int64_t aowlspt_nim_now_ms(void* ctx) { (void)ctx; return (int64_t)GetTickCount64(); }
int32_t aowlspt_nim_invoke_main(void* ctx, void* cb, void* user) {
    (void)ctx; (void)cb; (void)user; return -6;
}
int32_t aowlspt_nim_schedule(void* ctx, int32_t delayMs, void* cb, void* user) {
    (void)ctx; (void)delayMs; (void)cb; (void)user; return -6;
}
int32_t aowlspt_nim_event_subscribe(void* ctx, void* name, int32_t nameLen,
                                    void* cb, void* user) {
    (void)ctx; (void)name; (void)nameLen; (void)cb; (void)user; return 0;
}
int32_t aowlspt_nim_patch(void* ctx, void* target, int32_t targetLen,
                          int32_t kind, void* cb, void* user) {
    (void)ctx; (void)target; (void)targetLen; (void)kind; (void)cb; (void)user;
    return -6;
}
int32_t aowlspt_nim_db_get(void* ctx, void* path, int32_t pathLen,
                           void* outPtr, void* outLen) {
    (void)ctx; (void)path; (void)pathLen;
    *(void**)outPtr = NULL; *(int32_t*)outLen = 0; return -3;
}
int32_t aowlspt_nim_db_patch(void* ctx, void* path, int32_t pathLen,
                             void* patch, int32_t patchLen) {
    (void)ctx; (void)path; (void)pathLen; (void)patch; (void)patchLen; return -6;
}
int32_t aowlspt_nim_store_get(void* ctx, void* key, int32_t keyLen,
                              void* outPtr, void* outLen) {
    (void)ctx; (void)key; (void)keyLen;
    *(void**)outPtr = NULL; *(int32_t*)outLen = 0; return -3;
}
int32_t aowlspt_nim_store_set(void* ctx, void* key, int32_t keyLen,
                              void* val, int32_t valLen) {
    (void)ctx; (void)key; (void)keyLen; (void)val; (void)valLen; return -6;
}
int32_t aowlspt_nim_store_list(void* ctx, void* prefix, int32_t prefixLen,
                               void* outPtr, void* outLen) {
    (void)ctx; (void)prefix; (void)prefixLen;
    *(void**)outPtr = NULL; *(int32_t*)outLen = 0; return -3;
}

/* ------------------------------------------------------------------ *
 * The route table, in the shape the backend's is
 * ------------------------------------------------------------------ */

/* One SRWLOCK, shared for the walk and exclusive for a registration or a
 * teardown, because that is what `gRoutes` has. The point of copying the
 * entry out under it and letting go before the call is the whole subject of
 * this test: it is correct, and it is what leaves the pointer on a stack. */
static SRWLOCK  mr_lock;
static int32_t  mr_lock_ready = 0;

typedef struct mr_route {
    int32_t used;
    void*   cb;
    void*   user;
    int64_t modIndex;
    int32_t gen;      /* which incarnation of the library registered it */
} mr_route;

#define MR_ROUTES 8
static mr_route mr_table[MR_ROUTES];
static int32_t  mr_cur_gen = 0;

/* Defined by nimony below -- the two calls this whole exercise is about. */
int32_t aowl_mr_enter(int64_t index);
void    aowl_mr_leave(int64_t index);

static LONG64 mr_ok        = 0;  /* a whole, current answer                  */
static LONG64 mr_refused   = 0;  /* turned away because the mod was draining */
static LONG64 mr_noroute   = 0;  /* nothing registered: the mod is gone      */
static LONG64 mr_wrong_gen = 0;  /* answered by another incarnation          */
static LONG64 mr_bad_text  = 0;  /* an answer that is not one                */
static LONG64 mr_bad_stat  = 0;  /* the handler returned a failure           */
static LONG   mr_faults    = 0;  /* a worker that touched unmapped memory    */
static LONG   mr_fault_seen = 0; /* index into the fault log, kept separate  */
static LONG   mr_stop      = 0;
static LONG   mr_alive     = 0;
static int32_t mr_guarded  = 1;
static int32_t mr_gap_us   = 400;

#define MR_FAULT_LOG 8
static void* mr_fault_at[MR_FAULT_LOG];
static DWORD mr_fault_code[MR_FAULT_LOG];

static int64_t mr_get(LONG64* p) { return (int64_t)InterlockedCompareExchange64(p, 0, 0); }
static int64_t mr_get_ok(void)        { return mr_get(&mr_ok); }
static int64_t mr_get_refused(void)   { return mr_get(&mr_refused); }
static int64_t mr_get_noroute(void)   { return mr_get(&mr_noroute); }
static int64_t mr_get_wrong_gen(void) { return mr_get(&mr_wrong_gen); }
static int64_t mr_get_bad_text(void)  { return mr_get(&mr_bad_text); }
static int64_t mr_get_bad_stat(void)  { return mr_get(&mr_bad_stat); }
static int32_t mr_get_faults(void)    { return (int32_t)InterlockedCompareExchange(&mr_faults, 0, 0); }
static int32_t mr_running(void)       { return InterlockedCompareExchange(&mr_stop, 0, 0) ? 0 : 1; }

static void mr_configure(int32_t guarded, int32_t gapUs) {
    mr_guarded = guarded;
    mr_gap_us = gapUs;
}

static void mr_begin_gen(int32_t gen) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", (int)gen);
    SetEnvironmentVariableA("AOWL_RACEMOD_GEN", buf);
    mr_cur_gen = gen;
}

static void mr_set_wedge(int32_t ms) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", (int)ms);
    SetEnvironmentVariableA("AOWL_RACEMOD_WEDGE_MS", buf);
}

static void mr_set_passes(int32_t passes) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", (int)passes);
    SetEnvironmentVariableA("AOWL_RACEMOD_PASSES", buf);
}

/* Called from nimony's `aowlspt_nim_route_register`, on the thread that is
 * loading the mod. */
static int32_t mr_register(int64_t modIndex, void* cb, void* user) {
    int32_t got = 0;
    AcquireSRWLockExclusive(&mr_lock);
    for (int i = 0; i < MR_ROUTES; i++) {
        if (!mr_table[i].used) {
            mr_table[i].used = 1;
            mr_table[i].cb = cb;
            mr_table[i].user = user;
            mr_table[i].modIndex = modIndex;
            mr_table[i].gen = mr_cur_gen;
            got = 1;
            break;
        }
    }
    ReleaseSRWLockExclusive(&mr_lock);
    return got;
}

/* The teardown, in the shape `dropModRegistrations` has: under the exclusive
 * lock, before the library is freed. */
static void mr_drop(int64_t modIndex) {
    AcquireSRWLockExclusive(&mr_lock);
    for (int i = 0; i < MR_ROUTES; i++) {
        if (mr_table[i].used && mr_table[i].modIndex == modIndex) {
            mr_table[i].used = 0;
            mr_table[i].cb = NULL;
            mr_table[i].user = NULL;
        }
    }
    ReleaseSRWLockExclusive(&mr_lock);
}

static int32_t mr_copy_route(mr_route* into) {
    int32_t got = 0;
    AcquireSRWLockShared(&mr_lock);
    for (int i = 0; i < MR_ROUTES; i++) {
        if (mr_table[i].used) { *into = mr_table[i]; got = 1; break; }
    }
    ReleaseSRWLockShared(&mr_lock);
    return got;
}

/* ------------------------------------------------------------------ *
 * Workers
 * ------------------------------------------------------------------ */

static __thread int mr_is_worker = 0;

static void mr_worker_faulted(void) {
    InterlockedIncrement(&mr_faults);
    InterlockedDecrement(&mr_alive);
    ExitThread(0);
}

static LONG CALLBACK mr_veh(EXCEPTION_POINTERS* ep) {
    if (!mr_is_worker) return EXCEPTION_CONTINUE_SEARCH;
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION &&
        code != EXCEPTION_ILLEGAL_INSTRUCTION &&
        code != EXCEPTION_PRIV_INSTRUCTION &&
        code != EXCEPTION_IN_PAGE_ERROR &&
        code != EXCEPTION_BREAKPOINT) return EXCEPTION_CONTINUE_SEARCH;
    CONTEXT* c = ep->ContextRecord;
    /* The count itself is `mr_worker_faulted`'s, so that a fault is counted on
     * the far side of the redirect and never twice. This one only says which
     * slot of the log to write. */
    LONG n = InterlockedIncrement(&mr_fault_seen) - 1;
    if (n < MR_FAULT_LOG) {
        mr_fault_at[n] = (void*)(uintptr_t)c->Rip;
        mr_fault_code[n] = code;
    }
    /* A fresh, aligned frame well below the current stack pointer: the thread
     * is abandoning everything above it and nothing will return through what
     * is left behind, so the only requirements are committed stack and the
     * ABI's alignment on entry. Same trick as `tests/detour_race.c`. */
    DWORD64 sp = (c->Rsp - 4096) & ~(DWORD64)0xF;
    c->Rsp = sp - 8;
    c->Rip = (DWORD64)(void*)&mr_worker_faulted;
    return EXCEPTION_CONTINUE_EXECUTION;
}

static void mr_spin_us(uint32_t us) {
    if (us == 0) return;
    LARGE_INTEGER f, a, b;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&a);
    double want = (double)us * (double)f.QuadPart / 1000000.0;
    for (;;) {
        QueryPerformanceCounter(&b);
        if ((double)(b.QuadPart - a.QuadPart) >= want) return;
    }
}

/* The answer, checked rather than merely received. */
static void mr_check(int32_t st, void* outPtr, int32_t outLen, int32_t gen) {
    if (st != 0) { InterlockedIncrement64(&mr_bad_stat); return; }
    if (!outPtr || outLen <= 0) { InterlockedIncrement64(&mr_bad_text); return; }
    char want[96];
    int n = snprintf(want, sizeof(want),
                     "{\"mod\":\"racemod\",\"gen\":%d,\"url\":\"/race/hit\",\"acc\":",
                     (int)gen);
    const char* got = (const char*)outPtr;
    if (outLen > n && memcmp(got, want, (size_t)n) == 0 &&
        got[outLen - 1] == '}') {
        InterlockedIncrement64(&mr_ok);
        return;
    }
    /* Not the answer this incarnation owed. If it is a well-formed answer from
     * another generation, say so separately: that is the failure that survives
     * a survival test, and it means a call landed in a library that had been
     * freed and mapped again at the same address. */
    int otherGen = -1;
    if (outLen > 22 && memcmp(got, "{\"mod\":\"racemod\",\"gen\":", 23) == 0) {
        otherGen = atoi(got + 23);
    }
    if (otherGen >= 0 && otherGen != gen) InterlockedIncrement64(&mr_wrong_gen);
    else InterlockedIncrement64(&mr_bad_text);
}

static DWORD WINAPI mr_worker(LPVOID p) {
    mr_is_worker = 1;
    unsigned rnd = (unsigned)(uintptr_t)p * 2654435761u + 12345u;
    while (mr_running()) {
        mr_route rt;
        if (!mr_copy_route(&rt)) {
            InterlockedIncrement64(&mr_noroute);
            Sleep(0);
            continue;
        }
        /* The window between the copy and the call. The server's is the
         * session lock, which may wait ten seconds; this is microseconds of
         * the same shape, so that some workers are caught here and the rest
         * inside the handler. */
        rnd = rnd * 1103515245u + 12345u;
        if (mr_gap_us > 0) mr_spin_us(rnd % (unsigned)mr_gap_us);

        if (mr_guarded && !aowl_mr_enter(rt.modIndex)) {
            InterlockedIncrement64(&mr_refused);
            continue;
        }
        void* outPtr = NULL;
        int32_t outLen = 0;
        int32_t st = aowl_invoke_route(rt.cb, rt.user,
                                       (void*)"/race/hit", 9,
                                       (void*)"", 0,
                                       (void*)"", 0,
                                       (void*)&outPtr, (void*)&outLen);
        if (mr_guarded) aowl_mr_leave(rt.modIndex);
        mr_check(st, outPtr, outLen, rt.gen);
        if (outPtr) aowl_host_release(outPtr);
    }
    InterlockedDecrement(&mr_alive);
    return 0;
}

#define MR_MAX_WORKERS 64
static HANDLE mr_threads[MR_MAX_WORKERS];
static int32_t mr_nthreads = 0;
static PVOID  mr_veh_handle = NULL;

static void mr_start(int32_t workers) {
    InitializeSRWLock(&mr_lock);
    mr_lock_ready = 1;
    mr_veh_handle = AddVectoredExceptionHandler(1, mr_veh);
    if (workers > MR_MAX_WORKERS) workers = MR_MAX_WORKERS;
    mr_nthreads = 0;
    for (int32_t i = 0; i < workers; i++) {
        InterlockedIncrement(&mr_alive);
        mr_threads[mr_nthreads] =
            CreateThread(NULL, 0, mr_worker, (LPVOID)(uintptr_t)(i + 1), 0, NULL);
        if (mr_threads[mr_nthreads] == NULL) InterlockedDecrement(&mr_alive);
        else mr_nthreads++;
    }
}

static void mr_join(void) {
    InterlockedExchange(&mr_stop, 1);
    for (int32_t i = 0; i < mr_nthreads; i++) {
        if (mr_threads[i]) {
            WaitForSingleObject(mr_threads[i], 15000);
            CloseHandle(mr_threads[i]);
        }
    }
    if (mr_veh_handle) RemoveVectoredExceptionHandler(mr_veh_handle);
}

/* Where the first faults landed, so a failing run says which window it fell
 * into rather than only that it fell into one. */
static void* mr_fault_addr(int32_t i) { return (i < MR_FAULT_LOG) ? mr_fault_at[i] : NULL; }
static uint32_t mr_fault_kind(int32_t i) { return (i < MR_FAULT_LOG) ? (uint32_t)mr_fault_code[i] : 0u; }
""".}

proc cRegisterRoute(modIndex: int64; cb, user: HostPtr): int32 {.
  importc: "mr_register", nodecl.}
proc cDropRoutes(modIndex: int64) {.importc: "mr_drop", nodecl.}
proc cConfigure(guarded, gapUs: int32) {.importc: "mr_configure", nodecl.}
proc cBeginGen(gen: int32) {.importc: "mr_begin_gen", nodecl.}
proc cSetPasses(passes: int32) {.importc: "mr_set_passes", nodecl.}
proc cSetWedge(ms: int32) {.importc: "mr_set_wedge", nodecl.}
proc cStart(workers: int32) {.importc: "mr_start", nodecl.}
proc cJoin() {.importc: "mr_join", nodecl.}
proc cOk(): int64 {.importc: "mr_get_ok", nodecl.}
proc cRefused(): int64 {.importc: "mr_get_refused", nodecl.}
proc cNoRoute(): int64 {.importc: "mr_get_noroute", nodecl.}
proc cWrongGen(): int64 {.importc: "mr_get_wrong_gen", nodecl.}
proc cBadText(): int64 {.importc: "mr_get_bad_text", nodecl.}
proc cBadStatus(): int64 {.importc: "mr_get_bad_stat", nodecl.}
proc cFaults(): int32 {.importc: "mr_get_faults", nodecl.}
proc cFaultAddr(i: int32): HostPtr {.importc: "mr_fault_addr", nodecl.}
proc cFaultKind(i: int32): uint32 {.importc: "mr_fault_kind", nodecl.}

# The two calls the fix is made of, reachable from the C workers above.
# `modEnter` and `modLeave` are nimony procs in `host/common/modhost.nim`, and
# a `static` C function cannot see them: this is the seam, and it is the same
# pair the backend puts around `runRoute`.
proc mrEnter(index: int64): int32 {.exportc: "aowl_mr_enter", cdecl.} =
  result = (if modhost.modEnter(int(index)): 1'i32 else: 0'i32)

proc mrLeave(index: int64) {.exportc: "aowl_mr_leave", cdecl.} =
  modhost.modLeave(int(index))

# The host surface the mod actually uses. Everything else is a stub in the
# emit block above; this one is real, because a route the test cannot see is a
# test that measures nothing.
proc hostRouteRegister(ctx: HostPtr; url: HostPtr; urlLen: int32; kind: int32;
                       cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_route_register", cdecl.} =
  if cb == nil:
    return ErrBadArg
  if cRegisterRoute(int64(cast[uint](ctx)), cb, user) == 0'i32:
    return ErrGeneric
  result = StatusOk

proc dropModRegistrations(index: int) =
  ## What the backend's teardown does, for the one table this has.
  cDropRoutes(int64(index))

const
  Usage = """
modrace -- a mod unloaded while workers are inside its route handler

  modrace [options]

  --workers N   worker threads calling the route (default 8)
  --cycles N    load/unload cycles to run (default 40)
  --hold-ms N   how long a mod stays loaded before it is taken out (default 40)
  --gap-us N    upper bound on the gap between copying a route and calling it,
                which is where the server's session lock sits (default 400)
  --passes N    how long the handler stays inside the library (default 24;
                about 400 us, which is what a real route handler costs)
  --mod PATH    the library to load (default: racemod.dll beside this exe)
  --unguarded   skip modEnter/modLeave -- the code as it was before the fix
  --wedge-ms N  the other half: a handler that does not come back for N ms.
                One cycle, and what is asserted is the deadline -- the unload
                must be refused rather than freeing the library under the
                threads inside it, the mod must keep answering afterwards, and
                the same unload must then succeed once they are out
  -h, --help    this
"""

proc intOf(s: string; fallback: int): int =
  ## `parseInt` raises, and a test binary whose argument parsing can throw is a
  ## test binary that reports a bad flag as a crash.
  result = 0
  var any = false
  for ch in s:
    if ch >= chr(48) and ch <= chr(57):
      result = result * 10 + (ord(ch) - 48)
      any = true
    else:
      return fallback
  if not any: return fallback

proc hex(p: HostPtr): string =
  var v = cast[uint](p)
  if v == 0'u: return "0"
  let digits = "0123456789abcdef"
  var acc = ""
  while v > 0'u:
    var one = ""
    one.add digits[int(v and 15'u)]
    acc = one & acc
    v = v shr 4
  result = "0x" & acc

proc main(): int =
  var workers = 8
  var cycles = 40
  var holdMs = 40
  var gapUs = 400
  var passes = 24
  var guarded = true
  var wedgeMs = 0
  var modPath = ""

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--workers" and i < paramCount():
      inc i
      workers = intOf(paramStr(i), workers)
    elif a == "--cycles" and i < paramCount():
      inc i
      cycles = intOf(paramStr(i), cycles)
    elif a == "--hold-ms" and i < paramCount():
      inc i
      holdMs = intOf(paramStr(i), holdMs)
    elif a == "--gap-us" and i < paramCount():
      inc i
      gapUs = intOf(paramStr(i), gapUs)
    elif a == "--passes" and i < paramCount():
      inc i
      passes = intOf(paramStr(i), passes)
    elif a == "--mod" and i < paramCount():
      inc i
      modPath = paramStr(i)
    elif a == "--wedge-ms" and i < paramCount():
      inc i
      wedgeMs = intOf(paramStr(i), wedgeMs)
    elif a == "--unguarded":
      guarded = false
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      echo "unknown option: " & a
      return 1
    inc i

  if workers < 1: workers = 1
  if cycles < 1: cycles = 1
  if holdMs < 1: holdMs = 1
  if wedgeMs > 0:
    # One cycle, because what is under test is a single deadline expiring and
    # what happens on either side of it. Repeating it would only repeat the
    # wait.
    cycles = 1

  startClock()
  if modPath.len == 0:
    modPath = joinPath(ownDirectory(), "racemod.dll")

  echo "modrace"
  echo "-------"
  echo "  mod       " & modPath
  echo "  threads   " & $workers & " workers"
  echo "  cycles    " & $cycles & " load/unload, " & $holdMs & " ms apart"
  echo "  window    up to " & $gapUs & " us between the copy and the call"
  echo "  guard     " & (if guarded: "modEnter/modLeave around every call"
                         else: "NONE -- the code as it was before the fix")
  if wedgeMs > 0:
    echo "  wedge     the handler does not return for " & $wedgeMs & " ms"
  echo ""

  setModTeardown(dropModRegistrations)
  cSetPasses(int32(passes))
  cSetWedge(0'i32)
  cConfigure((if guarded: 1'i32 else: 0'i32), int32(gapUs))

  # One load, one call, one unload, single-threaded first. A test whose checks
  # are wrong passes concurrently for the wrong reason, and this is the
  # cheapest way to know they are right before anything is racing.
  cBeginGen(0'i32)
  if not loadOne(modPath, SideServer, "modrace", "1.0.0"):
    echo "error the mod would not load: " & modPath
    return 1
  var err = ""
  if not unloadOne(modCount() - 1, err):
    echo "error the mod would not unload single-threaded: " & err
    return 1
  echo "ok    the mod loads, registers its route and unloads single-threaded"

  if wedgeMs > 0:
    cSetWedge(int32(wedgeMs))
  cStart(int32(workers))
  var loadFailures = 0
  var unloadFailures = 0
  var lastErr = ""
  var gen = 1
  while gen <= cycles:
    cBeginGen(int32(gen))
    if not loadOne(modPath, SideServer, "modrace", "1.0.0"):
      inc loadFailures
      break
    let index = modCount() - 1
    cSysSleep(int32(holdMs))
    var e = ""
    if not unloadOne(index, e):
      inc unloadFailures
      lastErr = e
    inc gen
  # The deadline, from both sides. The unload above must have been refused --
  # freeing the library with threads inside it is the bug, and a refusal is the
  # only other answer available -- and once the handlers come back the very
  # same unload must succeed, because a drain that gave up must have left the
  # mod open rather than half-closed.
  var wedgeRefused = false
  var wedgeAnswered = false
  var wedgeUnloaded = false
  if wedgeMs > 0:
    wedgeRefused = unloadFailures > 0
    cSetWedge(0'i32)
    # Past the wedge, with room for the last handler to return.
    cSysSleep(int32(wedgeMs + 500))
    let before = cOk()
    cSysSleep(500'i32)
    wedgeAnswered = cOk() > before
    var e2 = ""
    wedgeUnloaded = unloadOne(modCount() - 1, e2)
    if not wedgeUnloaded:
      lastErr = e2
    unloadFailures = 0

  cJoin()

  let ok = cOk()
  let refused = cRefused()
  let noroute = cNoRoute()
  let wrongGen = cWrongGen()
  let badText = cBadText()
  let badStat = cBadStatus()
  let faults = cFaults()

  echo ""
  echo "Result"
  echo "------"
  echo "  cycles    " & $(gen - 1) & " load/unload while workers called in"
  echo "  answered  " & $ok & " whole, current answers"
  echo "  refused   " & $refused & " turned away by the drain (a 503)"
  echo "  no route  " & $noroute & " found nothing registered (a 404)"

  var bad = 0
  if faults > 0'i32:
    echo "error " & $faults & " of " & $workers &
         " workers faulted -- a call into a freed image. A faulted worker" &
         " leaves the pool, so the cycles after the first fault ran with" &
         " fewer callers than were asked for."
    var k = 0
    while k < 8 and k < int(faults):
      echo "        at " & hex(cFaultAddr(int32(k))) &
           " code " & hex(cast[HostPtr](uint(cFaultKind(int32(k)))))
      inc k
    bad = 1
  if wrongGen > 0:
    echo "error " & $wrongGen & " answers came from another incarnation of the mod"
    bad = 1
  if badText > 0:
    echo "error " & $badText & " answers were not whole answers"
    bad = 1
  if badStat > 0:
    echo "error " & $badStat & " calls returned a failure status"
    bad = 1
  if loadFailures > 0:
    echo "error the mod stopped loading part way through"
    bad = 1
  if wedgeMs > 0:
    if wedgeRefused:
      echo "ok    the unload was refused rather than freeing a library with" &
           " threads inside it"
    else:
      echo "error the unload went ahead while a handler was still in the mod"
      bad = 1
    if wedgeAnswered:
      echo "ok    and the mod that stayed loaded went on answering"
    else:
      echo "error the mod stayed loaded but stopped answering: the drain that" &
           " gave up left it closed"
      bad = 1
    if wedgeUnloaded:
      echo "ok    and unloaded cleanly once the handlers were out"
    else:
      echo "error it could not be unloaded afterwards either: " & lastErr
      bad = 1
  if unloadFailures > 0:
    echo "error " & $unloadFailures & " unloads were refused: " & lastErr
    bad = 1
  if ok == 0:
    echo "error no worker ever got an answer -- the test proved nothing"
    bad = 1
  if bad == 0:
    echo "ok    " & $ok & " answers, " & $refused & " clean refusals, " &
         $noroute & " empty tables, no fault and no stale answer across " &
         $(gen - 1) & " unloads under " & $workers & " threads"
    return 0
  result = 1

quit(main())
