/* aowlspt_mqpolicy.h -- WHO MAY RUN MAIN-THREAD WORK, AND WHEN.
 *
 * ## The crash this makes impossible
 *
 * MEASURED 2026-09-02, two deaths at ~8.7 s into boot (Unity crash reports
 * Crash_2026-09-02_204346544 and Crash_2026-09-02_211541986).
 *
 * The host detours `EFT.TarkovApplication::Update` and drains the `invoke_main`
 * queue from inside it, on Unity's main thread. The detour BINDS at ~0:00:01 --
 * as soon as the runtime can resolve the method -- but the game does not CALL
 * it until the preloader has built the TarkovApplication behaviour, measured at
 * ~15 s. For those fourteen seconds the queue had work in it and the drain had
 * never fired.
 *
 * The host's tick loop treated that as a stall: after 2 s it logged "the
 * main-thread drain has not fired for 2s with work queued; running it on the
 * host thread until it comes back" and ran the queued callbacks ON THE HOST'S
 * OWN THREAD, while `aowlspt.host::main_thread`.`bound` stayed the mod-visible
 * answer. A mod's queued tick then called `UnityEngine.Input::GetKey`, whose
 * native body dereferences Unity's input manager -- a per-thread table slot
 * that is NULL off the main thread, with no null test. Access violation.
 *
 * The fallback was wrong in two independent ways and both are fixed:
 *
 *   1. A 2 s patience against a first firing that is fifteen seconds away is
 *      not a stall detector, it is a stopwatch that always expires. "Bound but
 *      never fired" is now its OWN state and is not a stall at all.
 *   2. Even a genuine stall is not a licence to run main-thread work somewhere
 *      else. There is no thread other than the drain's on which a callback that
 *      touches the engine is correct, so the only safe response is to DEFER and
 *      say so.
 *
 * ## The property, in one function
 *
 * `aowl_mq_may_run_here` is the whole safety rule and there is exactly one copy
 * of it. Work runs iff the caller is the thread the drain claimed, or the entry
 * was queued through the explicitly-named host-safe path (`enqueueHostSafe`) --
 * which carries no mod code and makes no managed call. Nothing else, ever, on
 * any thread, in any drain state.
 *
 * Deliberately free of <windows.h> and of every host type: `tools/test_mqpolicy.py`
 * compiles THIS FILE with a tiny main and executes the real function against a
 * fake stalled drain and a fake healthy one. A rule that only exists inside a
 * DLL injected into a game cannot be tested; this one can.
 */

#ifndef AOWLSPT_MQPOLICY_H
#define AOWLSPT_MQPOLICY_H

#include <stdint.h>

/* What the host can say about the main-thread drain. Four states, and the two
 * middle ones are the entire point: collapsing them into "not firing" is what
 * produced the boot fallback. */
typedef enum {
    AOWL_DRAIN_UNBOUND     = 0, /* no per-frame method was detoured at all */
    AOWL_DRAIN_NEVER_FIRED = 1, /* bound, and the game has not called it YET --
                                 * the ordinary state of the first ~15 s of a
                                 * boot. NOT a stall: nothing has stopped. */
    AOWL_DRAIN_STALLED     = 2, /* it fired before and has now gone quiet --
                                 * a raid-only target, or a scene teardown */
    AOWL_DRAIN_LIVE        = 3  /* firing */
} AowlDrainHealth;

/* `slot`      the engine slot the drain hook claimed, or < 0 for none
 * `fires`     how many times the hook has fired (0 = never)
 * `since_ms`  milliseconds since the fire count last moved
 * `stall_ms`  how long a live drain may go quiet before it counts as stalled
 *
 * `since_ms` is only consulted once `fires > 0`, because before the first
 * firing there is no clock that means anything: the host would be measuring
 * how long ago IT started, not how long ago the GAME stopped. */
static AowlDrainHealth aowl_mq_health(int32_t slot, int32_t fires,
                                      uint64_t since_ms, uint64_t stall_ms) {
    if (slot < 0) return AOWL_DRAIN_UNBOUND;
    if (fires <= 0) return AOWL_DRAIN_NEVER_FIRED;
    if (since_ms > stall_ms) return AOWL_DRAIN_STALLED;
    return AOWL_DRAIN_LIVE;
}

/* THE RULE. 1 = this entry may be invoked on this thread, 0 = defer it.
 *
 * `owner_tid` is the thread the drain CLAIMED, which is 0 until it has fired
 * once. So before the first firing no thread matches and no mod callback runs
 * anywhere -- which is exactly the boot case above, answered correctly by
 * construction rather than by a timer.
 *
 * `host_safe` is the escape hatch, and it is narrow on purpose: it is set only
 * by `enqueueHostSafe`, whose entries carry no mod function pointer and make no
 * managed call. It is NOT reachable from `invoke_main` or `schedule`.
 *
 * Note what is absent: the drain's health. A stalled drain does not widen who
 * may run; it only changes what the host SAYS. */
static int32_t aowl_mq_may_run_here(uint32_t caller_tid, uint32_t owner_tid,
                                    int32_t host_safe) {
    if (host_safe) return 1;
    if (owner_tid == 0) return 0;
    return caller_tid == owner_tid ? 1 : 0;
}

/* Why the drain has not fired, as a stable string for the host log. The host
 * used to say only "has not fired for 2s", which cannot distinguish a hook that
 * never bound from one the game stopped calling -- three very different faults
 * with one sentence between them. */
static const char* aowl_mq_health_text(AowlDrainHealth h) {
    switch (h) {
    case AOWL_DRAIN_UNBOUND:
        return "no per-frame method is detoured at all";
    case AOWL_DRAIN_NEVER_FIRED:
        return "the detour is bound but the game has not called the method yet";
    case AOWL_DRAIN_STALLED:
        return "the detour is bound and fired before, and the game has stopped "
               "calling it";
    case AOWL_DRAIN_LIVE:
        return "the drain is firing";
    default:
        /* Not one of the four. Never "the drain is firing" by default: a
         * caller passing a sentinel it has not set yet would read back the
         * healthiest sentence in the file. */
        return "the drain's state has not been established";
    }
}

#endif /* AOWLSPT_MQPOLICY_H */
