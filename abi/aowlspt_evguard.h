/* THE EVENT-DISPATCH GUARD -- a mod's event handler must not be able to kill
 * the client.
 *
 * WHY THIS EXISTS (measured, not inferred). Unity crash report
 * `Crash_2026-09-02_030042716\Player.log`, stack section only: sain.dll
 * `toJson <- schemaJson <- onPageQuery <- eventTrampoline`, called from
 * `aowlspt-host-il2cpp` with `KERNEL32!BaseThreadInitThunk` under it -- i.e.
 * the HOST'S OWN TICK THREAD, inside an `aowlspt.settings.pageQuery`
 * broadcast (`settingsbridge.nim` `sbCollect` -> `hostEmit` ->
 * `deliverEvent`). The handler faulted and took the whole process down,
 * because `deliverEvent` invoked it through the bare `aowl_invoke_callback`
 * trampoline, which has no guard of any kind.
 *
 * A settings query is a QUESTION. A mod that cannot answer it should produce
 * no answer, not a dead client.
 *
 * ---------------------------------------------------------------------------
 * THE NESTING PROBLEM, AND WHY THIS FILE READS `aowl_seh_active`
 * ---------------------------------------------------------------------------
 * `aowl_p_p_seh` (aowlspt_shim.h) is NOT re-entrant: it sets the thread-local
 * `aowl_seh_active` to 1 on entry and to 0 on exit, unconditionally. A guard
 * opened INSIDE another guard therefore DISARMS THE OUTER ONE when it returns
 * -- adding an inner guard removes protection rather than adding it.
 *
 * An emit reaches `deliverEvent` from two places with genuinely different
 * answers to "am I already guarded?":
 *
 *   - the host tick thread, via `sbTick`/`sbCollect` -- NOT guarded, which is
 *     the crash above; and
 *   - the game thread, from inside a patch handler, where a rider may well
 *     already hold a guard.
 *
 * So the question is answered AT RUNTIME rather than assumed. When a guard is
 * already armed on this thread, this file opens NO second guard: it calls the
 * handler directly and reports `AOWL_EV_NESTED`. The outer guard still catches
 * the fault (it just unwinds further than we would like), and the caller logs
 * that it could not attribute the fault to a single handler. That is a
 * three-outcome answer -- OK / FAULTED / NESTED -- never a two-outcome one that
 * would have to lie about the case it cannot see.
 *
 * WHAT A CAUGHT FAULT COSTS. `aowl_p_p_seh` recovers by `longjmp`, so the
 * handler's frames are abandoned where they stood: anything it had locked stays
 * locked and anything it was half-way through writing stays half-written. That
 * is survivable ONCE and is not something to keep doing, which is precisely why
 * the caller unsubscribes the handler after N faults instead of catching for
 * ever. Catching is damage control, not a feature.
 *
 * THIS FILE OPENS EXACTLY ONE GUARD, at `aowl_ev_invoke`, and nothing inside
 * `aowl_ev_body` opens another. It dereferences no game pointer, resolves no
 * il2cpp name and installs no detour. Nothing here allocates.
 */
#ifndef AOWLSPT_EVGUARD_H
#define AOWLSPT_EVGUARD_H

/* Three outcomes. Never two. */
#define AOWL_EV_OK      0
#define AOWL_EV_FAULTED 1
#define AOWL_EV_NESTED  2
#define AOWL_EV_REFUSED 3

typedef struct AowlEvCall {
    void*          cb;
    void*          user;
    const uint8_t* payload;
    int32_t        len;
    int32_t        status;   /* the handler's own return; valid only if reached */
    int32_t        reached;  /* 1 only if control came back off the handler */
} AowlEvCall;

/* The guarded body. `reached` is set AFTER the call returns, so a fault leaves
 * it 0 -- the flag is a property of the FINISHED STATE, not a prediction made
 * before the call. There is no way for this to report success without the
 * handler actually having returned. */
static void* aowl_ev_body(void* p) {
    AowlEvCall* q = (AowlEvCall*)p;
    AowlSlice s;
    s.ptr = q->payload;
    s.len = q->len;
    q->status = (int32_t)((AowlCallbackFn)q->cb)(q->user, s, NULL);
    q->reached = 1;
    return 0;
}

/* Is a `aowl_p_p_seh` guard already armed on THIS thread? Read-only; it never
 * clears the flag, which is the thing that would break the outer guard. */
static int32_t aowl_ev_in_guard(void) { return aowl_seh_active ? 1 : 0; }

/* Invoke one subscriber. `statusOut` receives the handler's own AowlStatus and
 * is meaningless unless the return is OK or NESTED. */
static int32_t aowl_ev_invoke(void* cb, void* user, void* payload, int32_t len,
                              void* statusOut) {
    AowlEvCall q;
    if (statusOut) *(int32_t*)statusOut = 0;
    if (!cb) return AOWL_EV_REFUSED;
    q.cb = cb;
    q.user = user;
    q.payload = (const uint8_t*)payload;
    q.len = len;
    q.status = 0;
    q.reached = 0;
    if (aowl_ev_in_guard()) {
        /* NESTED: opening a guard here would disarm the caller's. */
        aowl_ev_body(&q);
        if (statusOut) *(int32_t*)statusOut = q.status;
        return AOWL_EV_NESTED;
    }
    aowl_p_p_seh((void*)aowl_ev_body, &q);
    if (statusOut) *(int32_t*)statusOut = q.status;
    return q.reached ? AOWL_EV_OK : AOWL_EV_FAULTED;
}

/* ---------------------------------------------------------------------------
 * THE FALSIFICATION
 * ---------------------------------------------------------------------------
 * A guard that has never caught anything is indistinguishable from a guard that
 * cannot catch anything. This handler faults DELIBERATELY, on purpose, every
 * time: a store to address 0x10, which is inside the reserved null page on
 * Win64 and raises EXCEPTION_ACCESS_VIOLATION -- the one code
 * `aowl_seh_veh` acts on. It is reachable only by subscribing it, which the
 * host does only under the `eventGuardSelfTest` flag (default OFF).
 *
 * If the self-test prints its FAULTED line and the client is still running the
 * next line, the guard demonstrably works on this build. If the process dies,
 * it demonstrably does not -- and that is a result too. */
static AowlStatus AOWLSPT_CALL aowl_ev_selftest_fault(void* user,
                                                      AowlSlice payload,
                                                      AowlBuffer* out) {
    volatile int32_t* p = (volatile int32_t*)(uintptr_t)0x10;
    (void)user;
    (void)payload;
    (void)out;
    *p = 0x5EFA; /* deliberate access violation */
    return 0;
}
static void* aowl_ev_selftest_cb(void) { return (void*)aowl_ev_selftest_fault; }

#endif /* AOWLSPT_EVGUARD_H */
