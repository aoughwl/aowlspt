/* aowlspt_lock.h — one process-wide lock, and nothing else.
 *
 * This is its own file because of who needs a lock and what they must not be
 * made to link. These primitives used to live in `aowlspt_net.h`, which starts
 * with `#include <winsock2.h>` and `#include <zlib.h>`; every translation unit
 * that wanted a critical section therefore acquired a dependency on ws2_32 and
 * zlib as well.
 *
 * For the backend that costs nothing — it is a socket server, it links both
 * anyway. For the IL2CPP client host it is wrong in kind: that binary is a DLL
 * injected into the running game, and a DLL loaded into someone else's process
 * should carry exactly the imports its job requires. Pulling in a socket
 * library and a compression library to guard a queue with `EnterCriticalSection`
 * is not a size problem so much as an honesty problem — an import table is a
 * statement about what a module does, and a mod host that appears to want the
 * network invites the obvious question at the worst moment.
 *
 * The cost of *not* splitting was a duplicate: the IL2CPP host carried its own
 * byte-identical copy of the one-time-init critical section, with a comment
 * explaining that it could not include the header that already had one. That
 * copy is now gone and both sides share this file.
 *
 * There is one lock **per translation unit that includes this header**, and
 * that is the whole design rather than an accident of it. The critical section
 * below is `static`, and nimony emits one TU per module, so each module that
 * includes this file gets a lock of its own that nothing else can contend for.
 * A mod today holds two: one for its own state (`aowlspt/sync`) and one for
 * the SDK's scheduler table (`aowlspt.nim`). They are unrelated and neither
 * can be taken while the other is held, so there is no order to get wrong.
 *
 * Within a TU it is coarse on purpose: what it guards — the host's own mutable
 * lists, the timer queue, the main-thread callback queue — is touched at human
 * rates, not in inner loops, and one lock nobody has to reason about the
 * ordering of is worth more here than a set of finer ones somebody eventually
 * takes in two different orders.
 *
 * It is **not reentrant** as a contract, whatever Windows' `CRITICAL_SECTION`
 * happens to allow. That is why the SDK's scheduler does not share the mod's
 * lock: `examples/lesson` samples `scheduledSlots()` from inside its own
 * `withModLock`, which on a shared lock would be a recursive take of exactly
 * the kind this file tells you not to rely on.
 *
 * Initialised on first use under a one-time flag rather than at load: the first
 * caller may be a mod's worker thread, and there is no earlier point in either
 * host that both sides are guaranteed to pass through. `DllMain` is not that
 * point — the loader lock rules out doing real work there.
 *
 * Everything here is `static`, like the rest of `abi/`: these headers are
 * included into the single translation unit nimony emits per module.
 */

#ifndef AOWLSPT_LOCK_H
#define AOWLSPT_LOCK_H

#include <windows.h>

static CRITICAL_SECTION aowl_host_cs;
static LONG aowl_host_cs_state = 0; /* 0 unset, 1 initialising, 2 ready */

static void aowl_lock(void) {
    LONG was = InterlockedCompareExchange(&aowl_host_cs_state, 1, 0);
    if (was == 0) {
        InitializeCriticalSection(&aowl_host_cs);
        InterlockedExchange(&aowl_host_cs_state, 2);
    } else {
        /* Another thread got there first and may still be inside
         * `InitializeCriticalSection`; spin until it publishes state 2 rather
         * than entering a section that does not exist yet. */
        while (InterlockedCompareExchange(&aowl_host_cs_state, 2, 2) != 2) {
            Sleep(0);
        }
    }
    EnterCriticalSection(&aowl_host_cs);
}

static void aowl_unlock(void) {
    if (InterlockedCompareExchange(&aowl_host_cs_state, 2, 2) == 2) {
        LeaveCriticalSection(&aowl_host_cs);
    }
}

#endif /* AOWLSPT_LOCK_H */
