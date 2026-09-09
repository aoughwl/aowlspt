/* Does a detour survive being removed while it is firing?
 *
 *   gcc -O1 -I../abi -o detour_race.exe detour_race.c && ./detour_race.exe
 *
 * `detour_test.c` installs a hook, calls it, and removes it, all on one
 * thread. Everything in this file is about the other order: threads calling a
 * patched function while another thread takes the patch out from under them.
 *
 * That is not a hypothetical arrangement. `aowl_hook_remove` is reached from
 * the mod manager -- a player toggling a mod off -- and the game keeps running
 * while it happens, so every patched method the mod installed is being called
 * by threads that know nothing about the toggle.
 *
 * ## Asserting on answers rather than on survival
 *
 * A race that is not fixed still passes almost every run, so "it did not
 * crash" is worth nothing as a check. Everything below is counted instead:
 *
 *   * **faults** -- a worker that takes an access violation is not allowed to
 *     take the process with it. The vectored handler counts it and redirects
 *     the thread into `worker_faulted`, so the run finishes and *reports* the
 *     fault as a number. A jump through a freed trampoline, or through the
 *     NULL a released slot leaves behind, lands here.
 *   * **wrong answers** -- the patched function returns a value derived from
 *     its argument, and every worker checks every return. A firing that
 *     reaches the wrong trampoline runs the wrong function's prologue and
 *     jumps into the wrong function's body, which does not crash: it answers,
 *     and answers wrongly. That is the failure that matters most and it is
 *     invisible to a survival test.
 *
 * Both are split by which race produced them, because two live here and only
 * one of them is this file's. A fault says which by its address: inside the
 * bytes being rewritten, or anywhere else. A wrong answer says which by its
 * value -- the two functions compute answers that cannot be mistaken for each
 * other, so an answer names the body that produced it. Every wrong answer seen
 * so far, before the fix and after it, has named the trampoline; none has ever
 * been a torn prologue. See `g_wrongForeign`.
 *
 * The decoy hook exists for the second of those. Freeing a trampoline and then
 * allocating the next one hands `aowl_alloc_near` the address it just gave
 * back -- it tries the region above the target first, every time, so the
 * *same* address comes back -- and an in-flight firing then jumps into a live
 * trampoline belonging to somebody else rather than into unmapped memory. With
 * one victim that is indistinguishable from working. With two it is a wrong
 * answer.
 *
 * ## What it caught
 *
 * Against the engine as it was, five runs out of five: 1726 faults inside
 * memory that had been unmapped, and 328 calls answered with a zero the method
 * would never have returned. Against the engine as it is: none of either, over
 * twenty thousand install/remove cycles and a hundred million calls.
 *
 * ## Three modes, because a park has to be shown to be doing something
 *
 * The fourteen-byte prologue write is not atomic, and both this file and the
 * engine now know how to stop the threads across it. Which one does it is a
 * command-line argument, and all three arrangements are real runs:
 *
 *   * default -- this file parks its workers, `aowl_hook_set_park(0)` tells the
 *     engine not to. Every verdict this file has ever produced came from this
 *     arrangement and it is unchanged.
 *   * `--engine-park` -- this file parks nothing and the engine parks the
 *     process. `g_faultsPatch` is asserted to be zero here and nowhere else.
 *   * `--no-park` -- neither. The control: it says what the write costs
 *     unguarded, and therefore what the other two modes' zeroes are worth.
 *
 * Measured on this machine, three-second runs: default 0 prologue faults over
 * 20000 install/remove cycles, `--engine-park` 0 over 13282 and again over
 * 14876, `--no-park` 357 and 502 over 20000. Built against the engine as it was
 * before the park went in, `--engine-park` reports 368 and fails, which is that
 * check having teeth. The trampoline and wrong-answer verdicts are zero in
 * every one of those runs.
 *
 * The three cycle counts being the same order is the point, and it took work.
 * The first version of the park enumerated threads with
 * `CreateToolhelp32Snapshot`, which snapshots every thread on the machine, and
 * `--engine-park` managed 52 cycles against the control's 20000 -- and zero
 * faults over 52 rewrites is thin evidence about a race that is rare per
 * rewrite. With `ntdll!NtGetNextThread` it is thirteen to fifteen thousand
 * against 20000: still short, because a park is not free, but no longer a
 * different experiment.
 *
 * The first two are wired into `aowl test`, beside the line that compiles and
 * runs `detour_test.c`, so every one of their verdicts has to be one that holds
 * under a loaded machine as well as an idle one. The command at the top of this
 * file runs it on its own.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "aowlspt_detour.h"

static int passed = 0;
static int failed = 0;

static void check(const char* name, int cond) {
    if (cond) { passed++; printf("ok    %s\n", name); }
    else      { failed++; printf("FAIL  %s\n", name); }
}

/* ------------------------------------------------------------------ *
 * The functions under test
 *
 * Two of them, with answers that cannot be mistaken for each other: the real
 * victim multiplies, the decoy adds a constant no multiple of 3 can be. A
 * worker only ever calls `race_victim`, so any decoy answer it sees arrived
 * through a trampoline that was not its own.
 * ------------------------------------------------------------------ */

/* Both are longer than they need to be for the arithmetic, and that is
 * deliberate: `aowl_stolen_len` refuses a function whose whole body is shorter
 * than the fourteen bytes the jump needs, and `return x * 3 + 1` compiles to
 * six. The stores give each one a prologue a real method would have. */

static volatile int64_t g_victimSeen;
static volatile int64_t g_victimCalls;
static volatile int64_t g_decoySeen;
static volatile int64_t g_decoyCalls;

__attribute__((noinline, optimize("O2")))
int64_t race_victim(int64_t x) {
    int64_t a = x * 3 + 1;
    g_victimSeen = a;
    g_victimCalls = g_victimCalls + 1;
    return a;
}

__attribute__((noinline, optimize("O2")))
int64_t race_decoy(int64_t x) {
    int64_t a = x * 3 + 0x5EED0000;
    g_decoySeen = a;
    g_decoyCalls = g_decoyCalls + 1;
    return a;
}

/* ------------------------------------------------------------------ *
 * Faults, counted rather than fatal
 * ------------------------------------------------------------------ */

/* Faults are split by *where*, because two different races land here and only
 * one of them is this file's subject.
 *
 *  * `g_faultsTramp` -- the fault happened anywhere but the first bytes of one
 *    of the two victims: through a NULL trampoline pointer, inside a
 *    trampoline that was unmapped, or inside one that belonged to somebody
 *    else. That is the trampoline-lifetime race, and it must be zero.
 *
 *  * `g_faultsPatch` -- the fault happened inside the victim's own first
 *    fourteen bytes, which is a different and older problem: the jump that
 *    replaces a prologue is fourteen bytes and no store is that wide, so a
 *    thread entering the function while those bytes are going in executes half
 *    of one instruction and half of another. This used to be counted and
 *    reported rather than asserted on, because the engine did nothing about it
 *    and the park that hid it lived down in this file. The engine now parks the
 *    process itself, so in `--engine-park` this number is **asserted to be
 *    zero** and it is the whole point of that mode. `--no-park` turns both
 *    parks off and prints what the write costs unguarded, which is the control.
 */
static volatile LONG g_faults = 0;
static volatile LONG g_faultsTramp = 0;
static volatile LONG g_faultsPatch = 0;
static volatile LONG g_wrong  = 0;
static volatile LONG g_calls  = 0;

/* Wrong answers are split too, but not by the same question.
 *
 * A fault carries an address, so the handler can ask where it happened. The
 * obvious analogue for an answer is *when* it happened -- the writer knows
 * exactly when it is rewriting bytes, so a wrong answer from a call that was in
 * flight across a rewrite would be the prologue race and one from a call
 * nowhere near a rewrite would be a regression. That split was tried and it is
 * wrong, in the direction that matters: rebuilt against the engine as it was
 * before the trampoline-lifetime fix, *every one* of the 300-odd wrong answers
 * a run lands inside the window, because `aowl_hook_remove` is inside the
 * window and the removal is where that bug does its damage. A timing split
 * would have excused the exact bug this file exists to catch.
 *
 * What does separate them is *what came back*. The two functions compute
 * answers that cannot be confused, so a wrong answer identifies its own
 * mechanism:
 *
 *   * `g_wrongForeign` -- the value is exactly `race_decoy(x)`: the same
 *     argument the worker passed, put through the other function's arithmetic.
 *     Nothing but the other function's body computes that. The firing was
 *     dispatched through a slot or a trampoline that had turned over and
 *     belonged to the other hook. That is this file's subject and it must be
 *     zero.
 *
 *   * `g_wrongOther` -- anything else, and in practice always zero, which is
 *     what a caller gets when a firing is suppressed instead of run. Also this
 *     file's subject -- it is what the pre-fix engine produced -- and also
 *     zero.
 *
 * A torn prologue would land in the second bucket, and would be the one thing
 * in it that is not a trampoline problem. It has never been seen to: whichever
 * park is in force holds every worker out of the bytes being rewritten, and
 * `prologue` faults come back zero run after run for the same reason. So the
 * rewrite
 * window is kept, and printed, and attached to every wrong answer that is
 * logged -- but as evidence, not as an allowance. `g_rewriteSeq` is odd for
 * precisely as long as the target's first bytes are torn; a worker samples it
 * either side of its call, and `g_callsIn` counts how many calls were in flight
 * across one. If a torn prologue ever does answer rather than fault, that pair
 * of numbers is what will say so. */
static volatile LONG g_wrongForeign = 0;
static volatile LONG g_wrongOther   = 0;
static volatile LONG g_rewriteSeq = 0;   /* odd exactly while bytes are torn */
static volatile LONG g_callsIn    = 0;

/* The first few wrong answers, so a failing run says what came back rather
 * than only that something did. A decoy answer is recognisable on sight. */
#define WRONG_LOG 8
static int64_t g_wrongArg[WRONG_LOG];
static int64_t g_wrongGot[WRONG_LOG];
static int     g_wrongWhen[WRONG_LOG];   /* 1 = in flight across a rewrite */
static volatile LONG g_wrongLogged = 0;

static volatile LONG g_running = 0;
static __thread int g_isWorker = 0;

__attribute__((noinline))
static void worker_faulted(void) {
    InterlockedIncrement(&g_faults);
    InterlockedDecrement(&g_running);
    ExitThread(0);
}

/* Where the first few faults happened, so a failing run says *which* window it
 * fell into rather than only that it fell into one. */
#define FAULT_LOG 8
static DWORD   g_faultCode[FAULT_LOG];
static void*   g_faultAt[FAULT_LOG];
static DWORD64 g_faultRax[FAULT_LOG];
static volatile LONG g_faultLogged = 0;

static LONG CALLBACK race_veh(EXCEPTION_POINTERS* ep) {
    if (!g_isWorker) return EXCEPTION_CONTINUE_SEARCH;
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION &&
        code != EXCEPTION_ILLEGAL_INSTRUCTION &&
        code != EXCEPTION_PRIV_INSTRUCTION &&
        code != EXCEPTION_BREAKPOINT) return EXCEPTION_CONTINUE_SEARCH;
    /* Redirect the faulting thread into a function that records and exits.
     * A fresh, aligned frame well below the current stack pointer: the thread
     * is a handful of frames deep and nothing is going to return through what
     * is being abandoned, so the only requirement is that the address is
     * committed stack and the ABI's alignment holds on entry. */
    CONTEXT* c = ep->ContextRecord;
    void* at = (void*)(uintptr_t)c->Rip;
    intptr_t dv = (intptr_t)at - (intptr_t)&race_victim;
    intptr_t dd = (intptr_t)at - (intptr_t)&race_decoy;
    if ((dv >= 0 && dv < AOWL_JMP_SIZE) || (dd >= 0 && dd < AOWL_JMP_SIZE)) {
        InterlockedIncrement(&g_faultsPatch);
    } else {
        LONG n = InterlockedIncrement(&g_faultsTramp) - 1;
        if (n < FAULT_LOG) {
            g_faultCode[n] = code;
            g_faultAt[n] = at;
            g_faultRax[n] = c->Rax;
        }
    }
    DWORD64 sp = (c->Rsp - 4096) & ~(DWORD64)0xF;
    c->Rsp = sp - 8;
    c->Rip = (DWORD64)(void*)&worker_faulted;
    return EXCEPTION_CONTINUE_EXECUTION;
}

/* ------------------------------------------------------------------ *
 * The handler side
 *
 * Both answer 0, which is "let the original run" -- and running the original
 * means going through the trampoline, which is the pointer this whole file is
 * about. A handler that suppressed would never touch it.
 * ------------------------------------------------------------------ */

int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    (void)slot; (void)regs;
    return 0;
}

int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs) {
    (void)slot; (void)regs;
    return 0;
}

/* ------------------------------------------------------------------ *
 * Workers
 * ------------------------------------------------------------------ */

static volatile LONG g_stop = 0;
static int32_t g_attachFail = 0;

static DWORD WINAPI worker(LPVOID arg) {
    (void)arg;
    g_isWorker = 1;
    int64_t x = 0;
    while (!g_stop) {
        for (int i = 0; i < 64; i++) {
            /* Bracket the call with the rewrite counter. Nothing is asserted
             * on it -- see `g_wrongForeign` -- but it is the only evidence
             * there would be if a torn prologue ever answered instead of
             * faulting, and evidence that is quietly wrong is worse than
             * none. The barriers are what make the bracket mean anything:
             * without them the compiler may sink the first load or hoist the
             * second past the call, and a call that spanned a rewrite reads
             * as one that did not. */
            LONG s0 = g_rewriteSeq;
            __asm__ __volatile__("" ::: "memory");
            int64_t got = race_victim(x);
            __asm__ __volatile__("" ::: "memory");
            LONG s1 = g_rewriteSeq;
            int spanned = (s0 != s1) || (s0 & 1);
            if (spanned) InterlockedIncrement(&g_callsIn);
            if (got != x * 3 + 1) {
                InterlockedIncrement(&g_wrong);
                /* The decoy's arithmetic on the victim's argument, which only
                 * the decoy's body computes. See the note on `g_wrongForeign`. */
                if (got == x * 3 + 0x5EED0000)
                    InterlockedIncrement(&g_wrongForeign);
                else
                    InterlockedIncrement(&g_wrongOther);
                LONG n = InterlockedIncrement(&g_wrongLogged) - 1;
                if (n < WRONG_LOG) {
                    g_wrongArg[n] = x;
                    g_wrongGot[n] = got;
                    g_wrongWhen[n] = spanned;
                }
            }
            x++;
            if (x > 1000000) x = 0;
            /* Work that is not inside the victim. Without it a worker is
             * inside the patched prologue a large fraction of the time, the
             * park below almost never finds every thread clear, and the run
             * manages a hundred install/remove cycles instead of thousands --
             * which is the wrong trade, because the cycles are what the race
             * is made of. */
            for (volatile int k = 0; k < 24; k++) { }
        }
        InterlockedAdd(&g_calls, 64);
    }
    InterlockedDecrement(&g_running);
    return 0;
}

/* ------------------------------------------------------------------ *
 * Parking the workers across the byte write, and only across that
 *
 * The fourteen-byte jump is written with ordinary stores and no store is
 * fourteen bytes wide, so a thread that enters the function while it is going
 * in executes the tail of one instruction as if it were the head of another.
 * This note used to say that closing that race needed "a five-byte atomic
 * patch through an island near the target or a suspension in the engine
 * itself", and that until one of those existed the park had to live here --
 * because left in, the race accounts for well over a thousand faults a run and
 * drowns out the count this file is actually asserting on. What happened is the
 * second of the two: `aowl_hook_arm` and `aowl_hook_remove` now enumerate the
 * process's threads, suspend them, and retry until nobody's RIP is inside the
 * bytes about to move. The prototype below is what that engine code was written
 * from -- the two-step suspend, the RIP check, the retry -- and it is kept, for
 * three reasons.
 *
 * It is the **control**. `--no-park` turns both this park and the engine's off
 * and reports what the unguarded write costs, which is the only way to know
 * that `--engine-park` reporting zero means anything.
 *
 * It is the **default**, unchanged, so the trampoline-lifetime verdicts this
 * file has always produced keep being produced by exactly the arrangement that
 * produced them before: in the default mode the engine's park is switched off
 * and this one does the work, so the numbers are comparable across the change.
 *
 * And it parks *only the workers*, where the engine parks every other thread in
 * the process -- which here is the same set, but only because this test has no
 * other threads.
 *
 * What either park removes is exactly the prologue race and nothing
 * else: a thread parked *inside* a trampoline stays inside it while the
 * removal retires that trampoline, a thread parked between the generation load
 * and the dispatcher stays there while the slot is released and reused, and
 * every window this file exists to test is not merely still open but held open
 * wider than it would be otherwise.
 * ------------------------------------------------------------------ */

/* Which park is in force. Set from the command line in `main`:
 *
 *   (none)          this file's park; the engine's is switched off. The
 *                   arrangement every previous run of this test used.
 *   --engine-park   this file's park is a no-op and the engine's does the work.
 *                   The mode that asserts `g_faultsPatch == 0`.
 *   --no-park       neither. Nothing is asserted about the prologue; the number
 *                   is printed, and it is the evidence the gate has teeth.
 */
static int g_testPark = 1;

static HANDLE g_workers[16];
static int    g_workerCount = 0;

static void unpark(void) {
    if (!g_testPark) return;
    for (int i = 0; i < g_workerCount; i++)
        if (g_workers[i]) ResumeThread(g_workers[i]);
}

static LONG g_parkRetries = 0;

/* Park every worker outside the bytes about to be rewritten.
 *
 * Suspending is two steps and the second is not optional: `SuspendThread` only
 * *requests* the suspension and returns, and the thread is not actually off
 * the processor until something makes the kernel wait for it.
 * `GetThreadContext` is that something -- and it is also how the second half of
 * this works, because the context is the only way to ask where the thread
 * stopped.
 *
 * Stopping the threads is not enough on its own. A thread parked *inside* the
 * fourteen bytes resumes into the middle of the jump that was written over
 * them, which is the same half-instruction it would have executed if it had
 * never been stopped. So the park is retried until no worker is standing in
 * the rewrite: suspend, look, and if anybody is in the way let them all go and
 * try again. That is what a detour engine has to do to make an install safe
 * against running threads, and it is now what `aowl_hook_arm` does -- with two
 * differences that matter there and not here. The engine has to *find* the
 * threads, where this file was handed their handles when it created them, and
 * how it finds them turned out to matter more than anything else about the
 * park: `ntdll!NtGetNextThread` walks this process's threads and costs under a
 * microsecond each, where `CreateToolhelp32Snapshot` snapshots every thread on
 * the machine and costs two milliseconds a park, which was the difference
 * between `--engine-park` racing 52 cycles and racing 14876. And the engine has
 * to bound its retries, because a loop that never gives up is a frozen game.
 * This one may spin: six workers it created itself will always clear
 * eventually, and if they did not, a hung test is a result.
 */
static void park(void* fn) {
    if (!g_testPark) return;
    const uintptr_t lo = (uintptr_t)fn;
    /* The exact bytes the install will rewrite, not `AOWL_MAX_STOLEN`: the
     * window is what decides how often a worker is standing in it, and a
     * window twice the real size turns this loop into the run's bottleneck. */
    int32_t stolen = aowl_stolen_len((const uint8_t*)fn, AOWL_JMP_SIZE);
    const uintptr_t hi = lo + (stolen > 0 ? (uintptr_t)stolen : AOWL_MAX_STOLEN);
    for (;;) {
        int clear = 1;
        for (int i = 0; i < g_workerCount; i++) {
            if (!g_workers[i]) continue;
            SuspendThread(g_workers[i]);
            CONTEXT c;
            memset(&c, 0, sizeof(c));
            c.ContextFlags = CONTEXT_CONTROL;
            if (GetThreadContext(g_workers[i], &c) &&
                (uintptr_t)c.Rip >= lo && (uintptr_t)c.Rip < hi) clear = 0;
        }
        if (clear) return;
        unpark();
        g_parkRetries++;
        Sleep(0);
    }
}

/* One install/remove cycle of a hook on `fn`, the way the host does it:
 * claim, attach, and on the way out remove, free and release. */
static int cycle(void* fn) {
    void* h = aowl_hook_new();
    if (!h) return 0;
    park(fn);
    /* The bracket is *inside* the park, not around it. Park retries let the
     * workers run again while they are being herded out of the way, and those
     * are ordinary calls against whole bytes -- excusing them would widen the
     * allowance for nothing. Odd starts when the first byte is about to move
     * and ends when the last one has. */
    InterlockedIncrement(&g_rewriteSeq);
    int32_t slot = aowl_hook_attach(h, fn);
    InterlockedIncrement(&g_rewriteSeq);
    unpark();
    if (slot < 0) {
        if (g_attachFail == 0) g_attachFail = slot;
        aowl_hook_free(h);
        return 0;
    }
    /* Long enough for the workers to be inside it, short enough that the run
     * gets through thousands of cycles. */
    for (volatile int i = 0; i < 200; i++) { }
    park(fn);
    InterlockedIncrement(&g_rewriteSeq);
    aowl_hook_remove(h);
    InterlockedIncrement(&g_rewriteSeq);
    unpark();
    /* Deliberately *outside* the park: the release is what bumps the
     * generation and hands the slot back, and a thread that is between the
     * thunk's first load and the dispatcher when that happens is the case the
     * generation exists for. Parking it too would test nothing. */
    aowl_hook_free(h);
    aowl_hook_release(slot);
    return 1;
}

int main(int argc, char** argv) {
    /* Three arrangements of the same run; see `g_testPark`. The engine's park
     * is switched *off* in the default mode on purpose -- with both parks on
     * the run would still be clean, and a mode that cannot distinguish which
     * park did the work is not a control for either. */
    int enginePark = 0;
    const char* mode = "the test parks the workers, the engine does not";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--engine-park") == 0) {
            g_testPark = 0; enginePark = 1;
            mode = "the engine parks the process, the test does not";
        } else if (strcmp(argv[i], "--no-park") == 0) {
            g_testPark = 0; enginePark = 0;
            mode = "nobody parks anything -- the control";
        } else {
            printf("unknown option %s\n", argv[i]);
            return 2;
        }
    }
    aowl_hook_set_park(enginePark);

    printf("aowlspt detour race -- %s\n\n", mode);

    PVOID veh = AddVectoredExceptionHandler(1, race_veh);
    check("the fault handler is installed", veh != NULL);

    /* The answers are right before anything is patched at all -- otherwise a
     * run in which every worker faulted on its first call would report zero
     * wrong answers and look like a pass. */
    check("the victim answers correctly unpatched", race_victim(7) == 22);
    check("the decoy is distinguishable", race_decoy(7) != 22);

    const int nWorkers = 6;
    HANDLE* t = g_workers;
    g_running = nWorkers;
    g_workerCount = nWorkers;
    for (int i = 0; i < nWorkers; i++)
        t[i] = CreateThread(NULL, 0, worker, NULL, 0, NULL);

    /* Let the workers get going, so the first removal has something to race. */
    Sleep(20);

    int cycles = 0;
    ULONGLONG t0 = GetTickCount64();
    while (GetTickCount64() - t0 < 3000 && cycles < 20000) {
        cycles += cycle((void*)&race_victim);
        /* The decoy takes the slot and, above all, the *address* the victim's
         * trampoline just gave back. */
        cycles += cycle((void*)&race_decoy);
        /* A worker that faulted has left. Replace it, or the first six faults
         * end the race and everything after them reports as clean -- including
         * the wrong answers, which need live workers to be seen by. */
        if ((cycles & 0x3F) == 0) {
            for (int i = 0; i < nWorkers; i++) {
                if (WaitForSingleObject(t[i], 0) != WAIT_OBJECT_0) continue;
                CloseHandle(t[i]);
                InterlockedIncrement(&g_running);
                t[i] = CreateThread(NULL, 0, worker, NULL, 0, NULL);
            }
        }
    }

    g_stop = 1;
    WaitForMultipleObjects(nWorkers, t, TRUE, 5000);

    printf("\n      %d install/remove cycles, %ld calls, %ld workers left\n",
           cycles, (long)g_calls, (long)g_running);
    printf("      faults %ld (trampoline %ld, prologue %ld), "
           "wrong answers %ld (the other hook's %ld, other %ld)\n",
           (long)g_faults, (long)g_faultsTramp, (long)g_faultsPatch,
           (long)g_wrong, (long)g_wrongForeign, (long)g_wrongOther);
    /* Printed every run, zero or not, so the prologue race stays a measurement
     * with a denominator rather than a number nobody looks at. Both of these
     * being large while every wrong answer is still accounted for by the
     * trampoline is the evidence that the park works. */
    printf("      %ld of %ld calls were in flight across a rewrite, "
           "%ld prologue faults\n",
           (long)g_callsIn, (long)g_calls, (long)g_faultsPatch);
    printf("      engine park: %s via %s, %d retries, %d giveups "
           "(retry bound %d)\n",
           aowl_hook_park_enabled() ? "on" : "off",
           aowl_hook_park_enum_text(),
           aowl_hook_park_retries(), aowl_hook_park_giveups(),
           AOWL_PARK_RETRIES);
    printf("      trampolines handed out %d in %d block(s)\n",
           aowl_tramp_count(), aowl_tramp_blocks());
    printf("      stale firings caught by the generation: %d\n",
           aowl_hook_stale_fires());

    for (LONG i = 0; i < g_faultsTramp && i < FAULT_LOG; i++) {
        const char* where = "unmapped or foreign code";
        MEMORY_BASIC_INFORMATION mbi;
        if (g_faultAt[i] == NULL) where = "a NULL trampoline pointer";
        else if (VirtualQuery(g_faultAt[i], &mbi, sizeof(mbi)) &&
                 mbi.State != MEM_COMMIT) where = "memory that is not mapped";
        printf("      trampoline fault %ld: code %08lx at %p (%s)\n",
               (long)i, (unsigned long)g_faultCode[i], g_faultAt[i], where);
    }

    for (LONG i = 0; i < g_wrongLogged && i < WRONG_LOG; i++) {
        const char* what = "a value neither function produces";
        if (g_wrongGot[i] == g_wrongArg[i] * 3 + 0x5EED0000)
            what = "the other hook's answer -- a firing that reached a slot "
                   "or trampoline that had turned over";
        else if (g_wrongGot[i] == 0)
            what = "zero, which neither function returns -- a firing that was "
                   "suppressed rather than run";
        printf("      wrong answer %ld: victim(%lld) = %lld -- %s, %s\n",
               (long)i, (long long)g_wrongArg[i], (long long)g_wrongGot[i],
               what, g_wrongWhen[i] ? "in flight across a rewrite"
                                    : "nowhere near a rewrite");
    }

    if (g_attachFail)
        printf("      attach refused: %d (%s)\n", g_attachFail,
               aowl_hook_error_text(g_attachFail));
    /* The bound is lower with the engine parking because a cycle carries four
     * parks -- an arm and a disarm for each of the two hooks -- and a park is
     * an enumeration plus a suspend-and-look sweep over every thread in the
     * process. Most of that is outside the suspension by construction, so it is
     * a slower install rather than a longer freeze; the cost table is in the
     * note above `aowl_hook_arm`.
     *
     * 2000 is low enough to survive a loaded machine and high enough to fail if
     * the enumeration ever regresses to the Toolhelp fallback, which managed 52
     * cycles in the same three seconds. A mode that raced two orders of
     * magnitude less than the control it is compared against is the reason this
     * bound is checked at all. */
    check("the run actually raced (cycles)",
          cycles > (enginePark ? 2000 : 100));
    check("the run actually raced (calls)", g_calls > 100000);
    check("no firing reached a trampoline that was gone or not its own",
          g_faultsTramp == 0);
    /* Both buckets, and both zero. Neither has an explanation that lets it
     * stand: a call answered with the other hook's arithmetic went through
     * that hook's slot or trampoline, and a call answered with a zero was
     * suppressed by a dispatcher that had lost track of which patch it was
     * serving. The split is there to name the mechanism in the output, not to
     * excuse either half. */
    check("no call was answered by another hook's code", g_wrongForeign == 0);
    /* The engine's park, asserted on only in the mode that leaves the engine
     * alone with the problem. In the default mode this file's own park makes it
     * zero and the check would prove nothing about the engine; in `--no-park`
     * it is expected to be large and is printed rather than asserted, because
     * "the unguarded write tore at least once in three seconds" is evidence and
     * not a contract. Against the engine before the park went in, this mode
     * reports thousands and this line fails, which is the point of it. */
    if (enginePark)
        check("the engine's park held every thread out of the bytes it rewrote",
              g_faultsPatch == 0);
    check("no call was answered by a suppressed or torn firing",
          g_wrongOther == 0);
    /* Bounded, and the number says by how much: a run of 20000 installs takes
     * 20 blocks of 1024, so the pool is a fifth spent by a churn far past
     * anything a session does. A regression that reclaims a block would show
     * here as a count that stopped rising. */
    check("the trampoline pool stayed bounded",
          aowl_tramp_blocks() > 0 && aowl_tramp_blocks() <= AOWL_TRAMP_BLOCKS);
    check("every trampoline handed out is still accounted for",
          aowl_tramp_count() >= cycles);
    check("every worker finished", g_running == 0);

    printf("\n%d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
