## tickrace -- the SDK's scheduler table under callbacks arriving on many
## threads at once.
##
##     tickrace [--sched 8] [--drains 4] [--seconds 4] [--chains 6]
##
## Every other gate drives a mod one callback at a time. That is the wrong
## shape for the question this asks, because a mod's callbacks are *not*
## delivered one at a time by design: the backend serves requests on sixteen
## workers, so two route handlers in the same mod run at once; the client host
## calls `on_update` on its own thread while a detour fires on the game's; and a
## timer or an event subscriber may arrive on either. `after`, `every`,
## `everyMain` and `onMainThread` are exactly what a mod calls from inside those
## handlers, and every one of them mutates `gTicks`, `gTickRepeat`, `gTickFree`
## and `gTickFreeN` -- four plain globals, three of them `seq`.
##
## **What it checks is not "did it survive".** A torn `seq` is loudest when it
## trips a bounds assertion, and that is not the likeliest outcome; the likeliest
## is two threads handed the *same* slot by `claimTick`, which is a scheduler
## that quietly runs one mod callback twice and another never. So every armed
## callback here has an identity -- one of eight distinct handlers, one per
## scheduling thread -- and the check is equality:
##
##   * handler `k` must fire exactly as many times as thread `k` armed it. A
##     shared slot shows up as one handler short and another long; a slot whose
##     repeat marker was written by the wrong thread shows up as a one-shot that
##     fired twice.
##   * the table must never hold more slots than there were callbacks in flight
##     at once. A slot's life -- claimed inside `after`, released inside its
##     firing -- is contained in that window, so `scheduledSlots()` can never
##     exceed the high-water mark unless the free list has been corrupted.
##   * once everything has quiesced, arming and firing one more callback must
##     leave `scheduledSlots()` exactly where it was. That is the free list
##     being intact rather than merely non-fatal.
##   * `stopMainRepeats()` must return exactly the number of `everyMain` chains
##     that are running, and after it, the chains must fire once more and then
##     stop dead. A repeat marker lost to a race is a per-frame callback that
##     either never stops or was never running.
##
## The host under it is a real one in the only sense that matters here: it
## queues `(callback, cookie)` pairs the way `aowlspt_shim.h` does and hands
## them back on other threads. It never drops one, so an arm that returned `Ok`
## has been queued, and a callback that never fires is the library's doing.
##
## Run against the library with the lock taken out of `claimTick`,
## `releaseTick` and `tickTrampoline`, it does not survive two seconds. Run
## against this one it passes with four million callbacks through the table and
## a thousand slots held throughout.
##
## **Every check here has been made to fail on purpose**, because a check that
## has never failed is a check nobody has read. Three mutations of the library,
## each built and run:
##
##   * `releaseTickLocked` turned into a no-op, so the free list never refills:
##     fails the slot bound and the free-list check in both phases and the
##     single-threaded reuse check -- five -- and nothing else.
##   * `claimTick` made to hand out a live slot without taking it off the free
##     list once in every 4096 claims -- which is what two unguarded threads do
##     to each other, minus the memory corruption: fails the identity counts in
##     both phases, one handler short and another long, which is one mod
##     callback run twice and another never run at all.
##   * `stopMainRepeats` made to miss one chain: fails the chain count, "fires
##     no more", the drained-to-empty check, the queue-empty checks and the slot
##     bound the leftover chain pushes past.
##
## The unguarded library itself does not get far enough to fail a count. One
## scheduling thread against one draining thread dies on
## `seqimpl.nim(169): i < s.len and 0 <= i [AssertionDefect]` -- the free-list
## index gone negative -- and two or more die on `__fastfail` with the heap
## corrupted instead.
##
## The chain mutation is also why the drain is capped rather than run until
## empty: a chain that will not stop re-arms once per firing, so an uncapped
## drain never returns and the check that would have caught it never runs. A
## hang is not a test result.
##
## It also times the guarded paths, because a lock on a path that runs once a
## frame is a cost somebody has to have decided is worth paying: `--bench` alone
## prints the per-arm, per-firing and per-lock-pair numbers with nothing racing.

import std/[cmdline, syncio]
import aowlspt
import aowlspt/sync

{.emit: """#include <windows.h>""".}
{.emit: """#include <stdint.h>""".}
{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_abi.h" """.}

{.emit: """
/* ------------------------------------------------------------------ *
 * Counters.
 *
 * Atomic even though this is only a test: a mismatch counted with `++`
 * from twelve threads is a mismatch count that can read zero, which is
 * the exact failure mode the thing under test has.
 * ------------------------------------------------------------------ */
#define AOWL_TR_KINDS 8

static LONG64 aowl_tr_armed[AOWL_TR_KINDS];
static LONG64 aowl_tr_fired[AOWL_TR_KINDS];
static LONG64 aowl_tr_chain_fired = 0;
static LONG64 aowl_tr_arm_fail    = 0;
static LONG64 aowl_tr_inflight    = 0;
static LONG64 aowl_tr_inflight_hi = 0;
static LONG   aowl_tr_running     = 0;

static void aowl_tr_bump_armed(int32_t k) {
    if (k >= 0 && k < AOWL_TR_KINDS) InterlockedIncrement64(&aowl_tr_armed[k]);
}
static void aowl_tr_bump_fired(int32_t k) {
    if (k >= 0 && k < AOWL_TR_KINDS) InterlockedIncrement64(&aowl_tr_fired[k]);
}
static void aowl_tr_bump_chain(void)     { InterlockedIncrement64(&aowl_tr_chain_fired); }
static void aowl_tr_bump_armfail(void)   { InterlockedIncrement64(&aowl_tr_arm_fail); }

static int64_t aowl_tr_get_armed(int32_t k) {
    if (k < 0 || k >= AOWL_TR_KINDS) return -1;
    return (int64_t)InterlockedCompareExchange64(&aowl_tr_armed[k], 0, 0);
}
static int64_t aowl_tr_get_fired(int32_t k) {
    if (k < 0 || k >= AOWL_TR_KINDS) return -1;
    return (int64_t)InterlockedCompareExchange64(&aowl_tr_fired[k], 0, 0);
}
static int64_t aowl_tr_get_chain(void)   { return (int64_t)InterlockedCompareExchange64(&aowl_tr_chain_fired, 0, 0); }
static int64_t aowl_tr_get_armfail(void) { return (int64_t)InterlockedCompareExchange64(&aowl_tr_arm_fail, 0, 0); }
static int64_t aowl_tr_get_hi(void)      { return (int64_t)InterlockedCompareExchange64(&aowl_tr_inflight_hi, 0, 0); }
static int64_t aowl_tr_get_inflight(void){ return (int64_t)InterlockedCompareExchange64(&aowl_tr_inflight, 0, 0); }

/* The high-water mark of callbacks in flight -- armed but not yet finished
 * firing. The slot bound is asserted against this, so it is tracked exactly
 * rather than sampled. */
static void aowl_tr_inflight_inc(void) {
    LONG64 now = InterlockedIncrement64(&aowl_tr_inflight);
    for (;;) {
        LONG64 hi = InterlockedCompareExchange64(&aowl_tr_inflight_hi, 0, 0);
        if (now <= hi) break;
        if (InterlockedCompareExchange64(&aowl_tr_inflight_hi, now, hi) == hi) break;
    }
}
static void aowl_tr_inflight_dec(void) { InterlockedDecrement64(&aowl_tr_inflight); }

static int32_t aowl_tr_is_running(void) { return InterlockedCompareExchange(&aowl_tr_running, 0, 0); }
static void    aowl_tr_set_running(int32_t v) { InterlockedExchange(&aowl_tr_running, v); }

/* ------------------------------------------------------------------ *
 * The queue the fake host schedules onto.
 *
 * Its own critical section, deliberately not the mod's: the subject of the
 * test must not be load-bearing for the harness that tests it. It never
 * drops a callback -- a full queue spins rather than refusing -- so "armed
 * and returned Ok" always means "will be delivered", and a callback that
 * goes missing is the library's doing and nobody else's.
 *
 * Short on purpose. A deep queue is a *weaker* test: the schedulers run far
 * ahead, the drains work through a backlog of old cookies, and the free list
 * -- which is where two threads actually collide -- barely turns over, while
 * the table grows to the depth of the queue. A shallow one keeps every arm
 * close to its firing, so slots are claimed and released continuously, which
 * is the state `claimTick` has to survive.
 * ------------------------------------------------------------------ */
#define AOWL_TR_CAP 1024

typedef AowlStatus (AOWLSPT_CALL *aowl_tr_fn)(void*, AowlSlice, AowlBuffer*);

static aowl_tr_fn        aowl_tr_qcb[AOWL_TR_CAP];
static void*             aowl_tr_quser[AOWL_TR_CAP];
static int32_t           aowl_tr_qhead = 0;   /* next to pop  */
static int32_t           aowl_tr_qtail = 0;   /* next to push */
static int32_t           aowl_tr_qn    = 0;
static CRITICAL_SECTION  aowl_tr_qcs;
static LONG              aowl_tr_qready = 0;

static void aowl_tr_qinit(void) {
    if (InterlockedCompareExchange(&aowl_tr_qready, 1, 0) == 0) {
        InitializeCriticalSection(&aowl_tr_qcs);
        InterlockedExchange(&aowl_tr_qready, 2);
    }
    while (InterlockedCompareExchange(&aowl_tr_qready, 2, 2) != 2) Sleep(0);
}

static void aowl_tr_push(aowl_tr_fn cb, void* user) {
    for (;;) {
        EnterCriticalSection(&aowl_tr_qcs);
        if (aowl_tr_qn < AOWL_TR_CAP) {
            aowl_tr_qcb[aowl_tr_qtail] = cb;
            aowl_tr_quser[aowl_tr_qtail] = user;
            aowl_tr_qtail = (aowl_tr_qtail + 1) % AOWL_TR_CAP;
            aowl_tr_qn++;
            LeaveCriticalSection(&aowl_tr_qcs);
            return;
        }
        LeaveCriticalSection(&aowl_tr_qcs);
        Sleep(0);
    }
}

/* Pops one and runs it *outside* the queue lock -- the shape every real host
 * has, and the reason an `everyMain` re-arm lands on the next drain rather
 * than spinning inside this one. */
static int32_t aowl_tr_run_one(void) {
    aowl_tr_fn cb = NULL;
    void* user = NULL;
    EnterCriticalSection(&aowl_tr_qcs);
    if (aowl_tr_qn > 0) {
        cb = aowl_tr_qcb[aowl_tr_qhead];
        user = aowl_tr_quser[aowl_tr_qhead];
        aowl_tr_qhead = (aowl_tr_qhead + 1) % AOWL_TR_CAP;
        aowl_tr_qn--;
    }
    LeaveCriticalSection(&aowl_tr_qcs);
    if (!cb) return 0;
    {
        AowlSlice payload;
        payload.ptr = NULL;
        payload.len = 0;
        cb(user, payload, NULL);
    }
    return 1;
}

static int32_t aowl_tr_pending(void) {
    int32_t n;
    EnterCriticalSection(&aowl_tr_qcs);
    n = aowl_tr_qn;
    LeaveCriticalSection(&aowl_tr_qcs);
    return n;
}

/* ------------------------------------------------------------------ *
 * The host the library is bound to.
 * ------------------------------------------------------------------ */
static AowlHostApi  aowl_tr_api;
static AowlHostInfo aowl_tr_info;
static AowlModApi   aowl_tr_modapi;

static void* AOWLSPT_CALL aowl_tr_alloc(void* ctx, int32_t n) { (void)ctx; return malloc((size_t)n); }
static void  AOWLSPT_CALL aowl_tr_free(void* ctx, void* p)    { (void)ctx; free(p); }
static void  AOWLSPT_CALL aowl_tr_log(void* ctx, int32_t lvl, AowlSlice msg) {
    (void)ctx; (void)lvl; (void)msg;
}

static AowlStatus AOWLSPT_CALL aowl_tr_schedule(void* ctx, int32_t delay_ms,
                                                AowlCallbackFn cb, void* user) {
    (void)ctx; (void)delay_ms;
    aowl_tr_push((aowl_tr_fn)cb, user);
    return AOWLSPT_OK;
}

static AowlStatus AOWLSPT_CALL aowl_tr_invoke_main(void* ctx, AowlCallbackFn cb, void* user) {
    (void)ctx;
    aowl_tr_push((aowl_tr_fn)cb, user);
    return AOWLSPT_OK;
}

static void* aowl_tr_host_new(void) {
    aowl_tr_qinit();
    memset(&aowl_tr_api, 0, sizeof(aowl_tr_api));
    memset(&aowl_tr_info, 0, sizeof(aowl_tr_info));
    memset(&aowl_tr_modapi, 0, sizeof(aowl_tr_modapi));
    aowl_tr_info.size         = (int32_t)sizeof(AowlHostInfo);
    aowl_tr_info.abi_version  = AOWLSPT_ABI_VERSION;
    aowl_tr_info.abi_revision = AOWLSPT_ABI_REVISION;
    aowl_tr_info.side         = AOWLSPT_SIDE_SIM;
    aowl_tr_api.size        = (int32_t)sizeof(AowlHostApi);
    aowl_tr_api.ctx         = NULL;
    aowl_tr_api.info        = &aowl_tr_info;
    aowl_tr_api.alloc       = aowl_tr_alloc;
    aowl_tr_api.free        = aowl_tr_free;
    aowl_tr_api.log         = aowl_tr_log;
    aowl_tr_api.schedule    = aowl_tr_schedule;
    aowl_tr_api.invoke_main = aowl_tr_invoke_main;
    return (void*)&aowl_tr_api;
}

static void* aowl_tr_modapi_ptr(void) { return (void*)&aowl_tr_modapi; }

/* ------------------------------------------------------------------ *
 * Threads.
 *
 * Schedulers and drains are started interleaved rather than in blocks: with
 * every scheduler started first, the table has already grown past the point
 * where `claimTick` takes its free-list path, and the free list is where the
 * two threads meet.
 * ------------------------------------------------------------------ */
int32_t aowl_tr_sched_thread(int32_t which);   /* nimony, below */
int32_t aowl_tr_chain_thread(int32_t which);   /* nimony, below */

static DWORD WINAPI aowl_tr_sched_thunk(LPVOID p) {
    return (DWORD)aowl_tr_sched_thread((int32_t)(intptr_t)p);
}
static DWORD WINAPI aowl_tr_drain_thunk(LPVOID p) {
    (void)p;
    while (aowl_tr_is_running()) {
        if (!aowl_tr_run_one()) Sleep(0);
    }
    return 0;
}
static DWORD WINAPI aowl_tr_chain_thunk(LPVOID p) {
    return (DWORD)aowl_tr_chain_thread((int32_t)(intptr_t)p);
}

#define AOWL_TR_MAXT 64
static HANDLE  aowl_tr_threads[AOWL_TR_MAXT];
static int32_t aowl_tr_nthreads = 0;

static void aowl_tr_spawn(LPTHREAD_START_ROUTINE fn, int32_t arg) {
    if (aowl_tr_nthreads < AOWL_TR_MAXT) {
        aowl_tr_threads[aowl_tr_nthreads++] =
            CreateThread(NULL, 0, fn, (LPVOID)(intptr_t)arg, 0, NULL);
    }
}

static void aowl_tr_start(int32_t sched, int32_t drains) {
    int32_t s = 0, d = 0;
    aowl_tr_nthreads = 0;
    aowl_tr_set_running(1);
    while (s < sched || d < drains) {
        if (s < sched) { aowl_tr_spawn(aowl_tr_sched_thunk, s); s++; }
        if (d < drains) { aowl_tr_spawn(aowl_tr_drain_thunk, d); d++; }
    }
}

static void aowl_tr_start_chains(int32_t chains) {
    int32_t i;
    for (i = 0; i < chains; i++) aowl_tr_spawn(aowl_tr_chain_thunk, i);
}

static void aowl_tr_sleep(int32_t ms) { Sleep((DWORD)ms); }

/* Stops the threads and waits for them, **draining while it waits**.
 *
 * Not a detail: a scheduling thread blocked in `aowl_tr_push` on a full queue
 * cannot see the stop flag until something makes room, and the threads that
 * would have made room are the drains, which stopped first. Joining without
 * draining is a deadlock between the harness and itself, and it looks exactly
 * like the library hanging -- which is the one thing a test of a lock must not
 * report by mistake. */
static void aowl_tr_join(void) {
    int32_t i;
    aowl_tr_set_running(0);
    for (i = 0; i < aowl_tr_nthreads; i++) {
        if (aowl_tr_threads[i]) {
            while (WaitForSingleObject(aowl_tr_threads[i], 0) == WAIT_TIMEOUT) {
                if (!aowl_tr_run_one()) Sleep(0);
            }
            CloseHandle(aowl_tr_threads[i]);
            aowl_tr_threads[i] = NULL;
        }
    }
    aowl_tr_nthreads = 0;
}

/* Runs everything the queue holds, including whatever the firings queue in
 * turn, until it has been empty for `settle` consecutive passes -- or until
 * `max_runs` firings, whichever comes first.
 *
 * The cap is the difference between a failing test and a hanging one. A chain
 * that will not stop re-arms once per firing, so "drain until empty" never
 * returns, and the check that would have caught it never gets to run. Hitting
 * the cap raises a flag the checks read, so a scheduler that cannot be stopped
 * is reported as exactly that. */
static LONG aowl_tr_stuck = 0;

static int64_t aowl_tr_drain_all(int32_t settle, int64_t max_runs) {
    int64_t ran = 0;
    int32_t empty = 0;
    while (empty < settle) {
        if (aowl_tr_run_one()) {
            ran++;
            empty = 0;
            if (max_runs > 0 && ran >= max_runs) {
                InterlockedExchange(&aowl_tr_stuck, 1);
                return ran;
            }
        } else {
            empty++;
            Sleep(0);
        }
    }
    return ran;
}

static int32_t aowl_tr_get_stuck(void)   { return InterlockedCompareExchange(&aowl_tr_stuck, 0, 0); }
static void    aowl_tr_clear_stuck(void) { InterlockedExchange(&aowl_tr_stuck, 0); }

static int64_t aowl_tr_qpc(void) {
    LARGE_INTEGER v;
    QueryPerformanceCounter(&v);
    return (int64_t)v.QuadPart;
}
static int64_t aowl_tr_qpf(void) {
    LARGE_INTEGER v;
    QueryPerformanceFrequency(&v);
    return (int64_t)v.QuadPart;
}
""".}

proc cHostNew(): pointer {.importc: "aowl_tr_host_new", nodecl.}
proc cModApiPtr(): pointer {.importc: "aowl_tr_modapi_ptr", nodecl.}
proc cBumpArmed(k: int32) {.importc: "aowl_tr_bump_armed", nodecl.}
proc cBumpFired(k: int32) {.importc: "aowl_tr_bump_fired", nodecl.}
proc cBumpChain() {.importc: "aowl_tr_bump_chain", nodecl.}
proc cBumpArmFail() {.importc: "aowl_tr_bump_armfail", nodecl.}
proc cArmed(k: int32): int64 {.importc: "aowl_tr_get_armed", nodecl.}
proc cFired(k: int32): int64 {.importc: "aowl_tr_get_fired", nodecl.}
proc cChain(): int64 {.importc: "aowl_tr_get_chain", nodecl.}
proc cArmFail(): int64 {.importc: "aowl_tr_get_armfail", nodecl.}
proc cInflightHi(): int64 {.importc: "aowl_tr_get_hi", nodecl.}
proc cInflight(): int64 {.importc: "aowl_tr_get_inflight", nodecl.}
proc cInflightInc() {.importc: "aowl_tr_inflight_inc", nodecl.}
proc cInflightDec() {.importc: "aowl_tr_inflight_dec", nodecl.}
proc cRunning(): int32 {.importc: "aowl_tr_is_running", nodecl.}
proc cSetRunning(v: int32) {.importc: "aowl_tr_set_running", nodecl.}
proc cStart(sched, drains: int32) {.importc: "aowl_tr_start", nodecl.}
proc cStartChains(chains: int32) {.importc: "aowl_tr_start_chains", nodecl.}
proc cJoin() {.importc: "aowl_tr_join", nodecl.}
proc cSleep(ms: int32) {.importc: "aowl_tr_sleep", nodecl.}
proc cDrainAll(settle: int32; maxRuns: int64): int64 {.importc: "aowl_tr_drain_all", nodecl.}
proc cStuck(): int32 {.importc: "aowl_tr_get_stuck", nodecl.}
proc cClearStuck() {.importc: "aowl_tr_clear_stuck", nodecl.}
proc cRunOne(): int32 {.importc: "aowl_tr_run_one", nodecl.}
proc cPending(): int32 {.importc: "aowl_tr_pending", nodecl.}
proc cQpc(): int64 {.importc: "aowl_tr_qpc", nodecl.}
proc cQpf(): int64 {.importc: "aowl_tr_qpf", nodecl.}

const Kinds = 8

# ---------------------------------------------------------------------------
# The callbacks, one identity each
#
# Eight distinct procs rather than one closure per arm: nimony has no closures
# over enclosing locals, and identity is the whole point -- a slot handed to two
# threads at once shows up here as handler `a` short and handler `b` long, which
# a single shared counter could never see.
# ---------------------------------------------------------------------------

proc h0(payload: string): string =
  cBumpFired(0'i32)
  cInflightDec()
  result = ""

proc h1(payload: string): string =
  cBumpFired(1'i32)
  cInflightDec()
  result = ""

proc h2(payload: string): string =
  cBumpFired(2'i32)
  cInflightDec()
  result = ""

proc h3(payload: string): string =
  cBumpFired(3'i32)
  cInflightDec()
  result = ""

proc h4(payload: string): string =
  cBumpFired(4'i32)
  cInflightDec()
  result = ""

proc h5(payload: string): string =
  cBumpFired(5'i32)
  cInflightDec()
  result = ""

proc h6(payload: string): string =
  cBumpFired(6'i32)
  cInflightDec()
  result = ""

proc h7(payload: string): string =
  cBumpFired(7'i32)
  cInflightDec()
  result = ""

proc chainHandler(payload: string): string =
  ## The `everyMain` chains all share one handler: a chain has no fixed number
  ## of firings to be checked against, so what is asserted about it is that it
  ## fires at all and that it stops when told, not how often.
  cBumpChain()
  result = ""

proc armOne(kind: int32; useMain: bool) =
  ## One `after` or `onMainThread`, counted so that the count cannot outrun the
  ## firing: in flight goes up *before* the arm, because the callback can be
  ## delivered on a drain thread before the arming call has returned.
  cInflightInc()
  var st = ErrGeneric
  if useMain:
    case kind
    of 0'i32: st = onMainThread(h0)
    of 1'i32: st = onMainThread(h1)
    of 2'i32: st = onMainThread(h2)
    of 3'i32: st = onMainThread(h3)
    of 4'i32: st = onMainThread(h4)
    of 5'i32: st = onMainThread(h5)
    of 6'i32: st = onMainThread(h6)
    else: st = onMainThread(h7)
  else:
    case kind
    of 0'i32: st = after(0, h0)
    of 1'i32: st = after(0, h1)
    of 2'i32: st = after(0, h2)
    of 3'i32: st = after(0, h3)
    of 4'i32: st = after(0, h4)
    of 5'i32: st = after(0, h5)
    of 6'i32: st = after(0, h6)
    else: st = after(0, h7)
  if st == Ok:
    cBumpArmed(kind)
  else:
    # The harness queue never refuses, so this cannot happen for a reason the
    # test is willing to accept. It is counted rather than ignored, and the
    # count is asserted to be zero -- an arm that failed would otherwise turn
    # into a missing firing and be read as the bug.
    cInflightDec()
    cBumpArmFail()

proc schedThread(which: int32): int32 {.exportc: "aowl_tr_sched_thread", cdecl.} =
  ## One scheduling thread. Thread `k` arms handler `k` and nothing else, so
  ## every collision *between* threads is a collision between identities and
  ## therefore visible in the counts.
  let kind = which mod int32(Kinds)
  var n = 0
  while cRunning() != 0'i32:
    # `after` and `onMainThread` land on different host entry points and take
    # the same slot path; alternating exercises both against each other.
    armOne(kind, (n and 1) == 1)
    inc n
  result = 0'i32

proc chainThread(which: int32): int32 {.exportc: "aowl_tr_chain_thread", cdecl.} =
  ## Starts one `everyMain` chain and then leaves. The chain lives on in the
  ## drain threads, re-arming itself from *inside* a firing -- which is the
  ## path that mutates `gTickRepeat` while the schedulers are growing it.
  if everyMain(chainHandler) != Ok:
    cBumpArmFail()
  result = 0'i32

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

var failures = 0

proc say(msg: string) =
  ## Flushed, every line. A test whose subject can take the process down owes
  ## the reader the lines it had already printed: run unflushed, the buffer
  ## dies with the process and a crash in phase 2 is indistinguishable from a
  ## crash before phase 1.
  echo msg
  flushFile(stdout)

proc ok(msg: string) =
  say "ok    " & msg

proc bad(msg: string) =
  say "FAIL  " & msg
  inc failures

proc check(cond: bool; msg: string) =
  if cond: ok(msg) else: bad(msg)

proc intOf(s: string; fallback: int): int =
  ## `parseInt` raises, and a test binary whose argument parsing can throw
  ## reports a bad flag as a crash.
  result = 0
  var any = false
  for ch in s:
    if ch >= chr(48) and ch <= chr(57):
      result = result * 10 + (ord(ch) - 48)
      any = true
    else:
      return fallback
  if not any: return fallback

const Usage = """
tickrace -- the SDK scheduler table under concurrent mod callbacks

  tickrace [options]

  --sched N     scheduling threads (default 8, capped at 8 identities)
  --drains N    draining threads (default 4)
  --seconds N   how long each racing phase runs (default 4)
  --chains N    everyMain chains started during phase 2 (default 6)
  --bench       only time the guarded paths, single-threaded
  -h, --help    this
"""

# ---------------------------------------------------------------------------
# The benchmark
#
# A lock on a path that runs once per schedule is not worth arguing about; a
# lock on a path that runs once per *firing* is once per frame for `everyMain`,
# and that is a number somebody has to have looked at.
# ---------------------------------------------------------------------------

proc nsText(ticks, freq: int64; reps: int): string =
  ## Nanoseconds to one decimal, in integer arithmetic -- nimony has no `$`
  ## for a float, and a benchmark that prints its number wrong is worse than
  ## one that does not print it.
  if reps <= 0 or freq <= 0: return "?"
  let ps = ticks * 1_000_000_000 div (freq * int64(reps)) * 1000 +
           (ticks * 1_000_000_000 mod (freq * int64(reps))) * 1000 div
           (freq * int64(reps))
  result = $(ps div 1000) & "." & $((ps mod 1000) div 100) & " ns"

proc benchmark() =
  let freq = cQpf()

  # The lock pair on its own, uncontended. Timed through `lockMod`, which is
  # the mod's lock rather than the scheduler's -- they are two instances of the
  # same `aowlspt_lock.h` critical section, one per translation unit, and the
  # scheduler's is not reachable from outside `aowlspt.nim`. The number is what
  # one enter-and-leave costs, which is the number the guarded paths below are
  # to be read against.
  var reps = 2_000_000
  var t0 = cQpc()
  for i in 0 ..< reps:
    lockMod()
    unlockMod()
  var t1 = cQpc()
  say "  lock pair " & nsText(t1 - t0, freq, reps) &
      "  (one CRITICAL_SECTION enter and leave, uncontended)"

  # One `after` plus the firing it causes: the whole round trip a mod pays for
  # a queued callback.
  reps = 200_000
  t0 = cQpc()
  for i in 0 ..< reps:
    cInflightInc()
    if after(0, h0) == Ok:
      cBumpArmed(0'i32)
    else:
      cInflightDec()
      cBumpArmFail()
    discard cRunOne()
  t1 = cQpc()
  say "  arm+fire  " & nsText(t1 - t0, freq, reps) &
       "  (after + trampoline + handler + release)"

  # And the per-frame path: one `everyMain` firing, which is the trampoline,
  # the handler, and the re-arm.
  if everyMain(chainHandler) == Ok:
    discard cRunOne()
    reps = 200_000
    t0 = cQpc()
    for i in 0 ..< reps:
      discard cRunOne()
    t1 = cQpc()
    say "  everyMain " & nsText(t1 - t0, freq, reps) &
         "  per firing (trampoline + handler + re-arm)"
    discard stopMainRepeats()
    discard cDrainAll(4'i32, 1_000_000'i64)
  else:
    say "  everyMain refused by the harness host"

proc main(): int =
  var sched = 8
  var drains = 4
  var seconds = 4
  var chains = 6
  var benchOnly = false
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--sched" and i < paramCount():
      inc i
      sched = intOf(paramStr(i), sched)
    elif a == "--drains" and i < paramCount():
      inc i
      drains = intOf(paramStr(i), drains)
    elif a == "--seconds" and i < paramCount():
      inc i
      seconds = intOf(paramStr(i), seconds)
    elif a == "--chains" and i < paramCount():
      inc i
      chains = intOf(paramStr(i), chains)
    elif a == "--bench":
      benchOnly = true
    elif a == "--help" or a == "-h":
      say Usage
      return 0
    else:
      say "unknown option: " & a
      return 1
    inc i

  if sched < 1: sched = 1
  if sched > Kinds: sched = Kinds
  if drains < 1: drains = 1
  if seconds < 1: seconds = 1
  if chains < 0: chains = 0

  say "tickrace"
  say "--------"

  let hostPtr = cHostNew()
  let st = bindHost(cast[ptr HostApi](hostPtr), cast[ptr ModApi](cModApiPtr()))
  if st != Ok:
    say "error could not bind the harness host: status " & $st
    return 1
  ok "bound the harness host (schedule and invoke_main queue, never refuse)"

  if benchOnly:
    benchmark()
    return 0

  say "  threads   " & $sched & " scheduling, " & $drains & " draining"
  say "  duration  " & $seconds & " s per phase, " & $chains & " everyMain chains"
  say ""

  # ------------------------------------------------------------------ #
  # Nothing racing, first.
  #
  # A concurrency test whose checks are wrong passes concurrently for the
  # wrong reason. These establish that the counters, the identities and the
  # slot arithmetic say what they are about to be trusted to say -- and that
  # the failure the whole test looks for is one this harness *can* report.
  # ------------------------------------------------------------------ #
  armOne(0'i32, false)
  discard cDrainAll(2'i32, 1_000_000'i64)
  check(cFired(0'i32) == 1 and cArmed(0'i32) == 1,
        "single-threaded: one arm, one firing, on the handler that was armed")
  check(cFired(1'i32) == 0,
        "single-threaded: no other handler fired -- identities are distinct")

  let baseSlots = scheduledSlots()
  armOne(1'i32, true)
  discard cDrainAll(2'i32, 1_000_000'i64)
  check(scheduledSlots() == baseSlots,
        "single-threaded: a second callback reused the free slot rather than " &
        "growing the table")
  check(cFired(1'i32) == 1,
        "single-threaded: onMainThread reaches the same table by the same path")

  # An everyMain chain, stopped, checked, single-threaded.
  let beforeChain = cChain()
  discard everyMain(chainHandler)
  discard cRunOne()
  discard cRunOne()
  discard cRunOne()
  check(cChain() >= beforeChain + 3,
        "single-threaded: an everyMain chain fires once per drain")
  check(stopMainRepeats() == 1,
        "single-threaded: stopMainRepeats counts exactly the one live chain")
  discard cDrainAll(4'i32, 1_000_000'i64)
  let afterStop = cChain()
  discard cDrainAll(4'i32, 1_000_000'i64)
  check(cChain() == afterStop,
        "single-threaded: a stopped chain fires no more")
  check(stopMainRepeats() == 0,
        "single-threaded: nothing is left marked repeating")
  say ""

  # ------------------------------------------------------------------ #
  # Phase 1 -- one-shots from many threads, drained by many threads.
  # ------------------------------------------------------------------ #
  var p1ArmedBase = 0'i64
  for k in 0 ..< Kinds:
    p1ArmedBase += cArmed(int32(k))
  cStart(int32(sched), int32(drains))
  cSleep(int32(seconds * 1000))
  cSetRunning(0'i32)
  cJoin()
  let ranTail = cDrainAll(64'i32, 20_000_000'i64)

  var armedTotal = 0'i64
  var firedTotal = 0'i64
  var mismatched = 0
  for k in 0 ..< Kinds:
    let a = cArmed(int32(k))
    let f = cFired(int32(k))
    armedTotal += a
    firedTotal += f
    if a != f:
      bad("phase 1: handler " & $k & " was armed " & $a & " times and fired " &
          $f & " times")
      inc mismatched
  if mismatched == 0:
    ok("phase 1: every one of the " & $(armedTotal - p1ArmedBase) &
       " callbacks armed under contention fired exactly once, on the handler " &
       "it was armed with")
  check(cArmFail() == 0,
        "phase 1: no arm was refused (the harness host never refuses, so a " &
        "refusal would be the library losing one)")
  check(cInflight() == 0,
        "phase 1: nothing is left in flight -- in flight " & $cInflight())
  check(cPending() == 0,
        "phase 1: the host queue is empty -- pending " & $cPending())
  check(int64(scheduledSlots()) <= cInflightHi(),
        "phase 1: the table holds " & $scheduledSlots() & " slots, never more " &
        "than the " & $cInflightHi() & " callbacks that were in flight at once")
  let quiesced = scheduledSlots()
  armOne(0'i32, false)
  discard cDrainAll(4'i32, 1_000_000'i64)
  check(scheduledSlots() == quiesced,
        "phase 1: after quiescing, one more callback reuses a free slot -- " &
        "the free list survived the race intact")
  say "      (" & $armedTotal & " callbacks, " & $ranTail &
       " drained after the storm, " & $scheduledSlots() & " slots held)"
  say ""

  # ------------------------------------------------------------------ #
  # Phase 2 -- the same, with everyMain chains re-arming from inside the
  # drain while the schedulers claim and release around them.
  # ------------------------------------------------------------------ #
  let p2ChainBase = cChain()
  let p2ArmedBase = armedTotal
  cStart(int32(sched), int32(drains))
  cStartChains(int32(chains))
  cSleep(int32(seconds * 1000))
  cSetRunning(0'i32)
  cJoin()

  let stopped = stopMainRepeats()
  check(stopped == chains,
        "phase 2: stopMainRepeats found exactly the " & $chains &
        " chains that were started, and reported " & $stopped)
  cClearStuck()
  discard cDrainAll(64'i32, 20_000_000'i64)
  let chainAtStop = cChain()
  discard cDrainAll(64'i32, 20_000_000'i64)
  check(cStuck() == 0'i32,
        "phase 2: the queue drained to empty after the stop -- a chain still " &
        "re-arming itself never lets it")
  check(cChain() == chainAtStop,
        "phase 2: every chain stopped -- no firing after the queue emptied")
  check(chainAtStop > p2ChainBase,
        "phase 2: the chains were running before they were stopped (" &
        $(chainAtStop - p2ChainBase) & " firings)")

  armedTotal = 0
  firedTotal = 0
  mismatched = 0
  for k in 0 ..< Kinds:
    let a = cArmed(int32(k))
    let f = cFired(int32(k))
    armedTotal += a
    firedTotal += f
    if a != f:
      bad("phase 2: handler " & $k & " was armed " & $a & " times and fired " &
          $f & " times")
      inc mismatched
  if mismatched == 0:
    ok("phase 2: every one of the " & $(armedTotal - p2ArmedBase) &
       " callbacks armed alongside the chains fired exactly once")
  check(cArmFail() == 0, "phase 2: no arm was refused")
  check(cInflight() == 0, "phase 2: nothing left in flight")
  check(cPending() == 0, "phase 2: the host queue is empty")
  check(int64(scheduledSlots()) <= cInflightHi() + int64(chains),
        "phase 2: the table holds " & $scheduledSlots() & " slots, never more " &
        "than the " & $cInflightHi() & " one-shots in flight at once plus the " &
        $chains & " chains")
  let quiesced2 = scheduledSlots()
  armOne(0'i32, false)
  discard cDrainAll(4'i32, 1_000_000'i64)
  check(scheduledSlots() == quiesced2,
        "phase 2: the free list is still intact after the chains ran")
  say ""

  benchmark()
  say ""

  if failures == 0:
    say "tickrace: all checks passed"
    return 0
  say "tickrace: " & $failures & " check(s) failed"
  return 1

quit(main())
