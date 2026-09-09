/* aowlspt_notify.h — the revision-5 notification push, for the one host that
 * has a socket to push down.
 *
 * `notify_push` hands a mod's notification to the session's websocket. That
 * only means anything where there *is* a websocket, which is `aowlspt-backend`
 * and nowhere else: there is no notifier connection inside the game process
 * and none in the simulator.
 *
 * Hence a separate header, for exactly the reason `aowlspt_live.h` is one.
 * Everything in `aowlspt_shim.h` is compiled into every nimony binary that
 * includes it, and a `static` wrapper there would name an `aowlspt_nim_*`
 * function that only the backend defines — so the client host would stop
 * linking on an entry point it would answer "unsupported" from if it existed.
 * A host opts in by including this file.
 *
 * ------------------------------------------------------------------------
 * Why this also fills three entries that are not its own
 * ------------------------------------------------------------------------
 *
 * `AowlHostApi.size` is a **watermark**: it says how much of the struct the
 * host filled, and a peer reads everything below it as present. That was
 * enough while capabilities arrived in order, and revision 5 is where it stops
 * being enough — revisions 3 and 4 need a managed heap and a detour engine, so
 * only the client host fills them, and revision 5 needs a listening socket, so
 * only the backend fills it. The backend is the first host to have a later
 * capability without an earlier one, and one integer cannot say that.
 *
 * Both obvious answers are wrong. Reporting revision 2 hides `notify_push`
 * from the mod that needs it. Reporting revision 5 over three null pointers
 * tells a mod to call them, and nimony cannot compare a proc field against
 * null to find out otherwise (`aowl/src/aowlspt/abi.nim` says so, and it is
 * why every capability test in this project is a size test).
 *
 * So the third answer, which is the rule this ABI already follows everywhere
 * else: **a capability a host does not have returns
 * `AOWLSPT_ERR_UNSUPPORTED` rather than misbehaving.** `call`, `resolve` and
 * `patch` on the backend are already filled-and-refusing. These three become
 * the same, and only then does `size` rise. Nothing a mod can observe changes:
 * `pointerOf` on the backend answered `ErrUnsupported` from its guard before
 * and answers `ErrUnsupported` from the host now, and a size test keeps
 * meaning "there is a function here that will answer" — which is the only
 * thing a null check could have established either.
 *
 * Include *after* `aowlspt_shim.h`, or on its own; it pulls the shim in and
 * the include guard sorts the rest out.
 */

#ifndef AOWLSPT_NOTIFY_H
#define AOWLSPT_NOTIFY_H

#include "aowlspt_shim.h"

/* Implemented in nimony, in `backend/aowlbackend.nim`. Returns an `AowlStatus`
 * directly: `AOWLSPT_OK` when the frame went out, `AOWLSPT_ERR_NOT_FOUND` when
 * that session has no websocket open — which is an ordinary answer the mod
 * falls back from, not a failure. */
extern int32_t aowlspt_nim_notify_push(void* session, int32_t sessionLen,
                                       void* payload, int32_t payloadLen);

static AowlStatus AOWLSPT_CALL aowl_host_notify_push(void* ctx,
                                                     AowlSlice session,
                                                     AowlSlice payload) {
    (void)ctx;
    return (AowlStatus)aowlspt_nim_notify_push(
        (void*)session.ptr, session.len, (void*)payload.ptr, payload.len);
}

/* The three above the watermark. Each writes its out-parameter before
 * refusing, so a caller that ignores the status reads a zero rather than
 * whatever was on its stack. */
static AowlStatus AOWLSPT_CALL aowl_host_no_pointer(void* ctx, AowlHandle h,
                                                    uint64_t* outAddress) {
    (void)ctx; (void)h;
    if (outAddress) *outAddress = 0;
    return AOWLSPT_ERR_UNSUPPORTED;
}

static AowlStatus AOWLSPT_CALL aowl_host_no_pin(void* ctx, AowlHandle h,
                                                AowlHandle* outPinned) {
    (void)ctx; (void)h;
    if (outPinned) *outPinned = AOWLSPT_NULL_HANDLE;
    return AOWLSPT_ERR_UNSUPPORTED;
}

static AowlStatus AOWLSPT_CALL aowl_host_no_patch_typed(
        void* ctx, AowlSlice target, int32_t kind,
        AowlTypedPatchFn handler, void* user) {
    (void)ctx; (void)target; (void)kind; (void)handler; (void)user;
    return AOWLSPT_ERR_UNSUPPORTED;
}

static void aowl_hostapi_arm_notify(void* p) {
    AowlHostBlock* b = (AowlHostBlock*)p;
    if (!b) return;
    b->api.handle_pointer = aowl_host_no_pointer;
    b->api.handle_pin     = aowl_host_no_pin;
    b->api.patch_typed    = aowl_host_no_patch_typed;
    b->api.notify_push    = aowl_host_notify_push;
    /* Last, and that ordering is the invariant: the watermark rises only once
     * everything under it is a pointer somebody may call. */
    b->api.size           = AOWLSPT_HOSTAPI_SIZE_REV5;
}

#endif /* AOWLSPT_NOTIFY_H */
