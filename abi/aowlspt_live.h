/* aowlspt_live.h — the revision-3 live-object entry points, for the one host
 * that has live objects.
 *
 * `handle_pointer` and `handle_pin` turn a host handle into the address of the
 * managed object behind it. That only means anything where there *is* a managed
 * heap, which is the IL2CPP client host: the backend and the server host hand
 * out handles over their own objects and have no such address to give.
 *
 * Hence a separate header rather than two more entries in `aowlspt_shim.h`.
 * Everything in the shim is compiled into every nimony binary that includes it,
 * and a `static` wrapper there would name two `aowlspt_nim_*` functions that
 * only the client host defines -- so the backend would stop linking on an entry
 * point that would answer "unsupported" if it existed. Keeping the pair here
 * means a host opts into them by including this file, and `aowl_hostapi_new`
 * reports the revision-2 size until `aowl_hostapi_arm_live` says otherwise.
 *
 * Include *after* `aowlspt_shim.h`, or on its own -- it pulls the shim in
 * either way and the include guard sorts the rest out.
 */

#ifndef AOWLSPT_LIVE_H
#define AOWLSPT_LIVE_H

#include "aowlspt_shim.h"

/* Both are implemented in nimony, in the client host. Out-parameters are
 * `void*` for the same reason every other one in the shim is: that is what
 * nimony emits for a pointer-to-out, and a mismatched extern is a compile error
 * rather than something to find at run time. */
extern int32_t aowlspt_nim_handle_pointer(void* ctx, uint64_t handle,
                                          void* outAddress);
extern int32_t aowlspt_nim_handle_pin(void* ctx, uint64_t handle,
                                      void* outHandle);
/* Revision 4's typed patch, here for the same reason the pair above is: it
 * needs a detour engine and a runtime whose signatures can be read, which is
 * this host and no other. */
extern int32_t aowlspt_nim_patch_typed(void* ctx, void* target, int32_t targetLen,
                                       int32_t kind, void* cb, void* user);
/* Revision 6's render-phase callback, here for the same reason: it needs an
 * IL2CPP render loop to detour, which is this host and no other. */
extern int32_t aowlspt_nim_invoke_render(void* ctx, void* cb, void* user);

/* Both write through an out-parameter and return a status, rather than
 * returning the address, so that "no address for that handle" is a code the
 * caller must look at instead of a zero it may not. */
static AowlStatus AOWLSPT_CALL aowl_host_handle_pointer(void* ctx, AowlHandle h,
                                                        uint64_t* out) {
    uint64_t v = 0;
    int32_t st;
    if (out) *out = 0;
    st = aowlspt_nim_handle_pointer(ctx, (uint64_t)h, (void*)&v);
    if (out && st == AOWLSPT_OK) *out = v;
    return st;
}

static AowlStatus AOWLSPT_CALL aowl_host_handle_pin(void* ctx, AowlHandle h,
                                                    AowlHandle* out) {
    uint64_t v = 0;
    int32_t st;
    if (out) *out = AOWLSPT_NULL_HANDLE;
    st = aowlspt_nim_handle_pin(ctx, (uint64_t)h, (void*)&v);
    if (out && st == AOWLSPT_OK) *out = (AowlHandle)v;
    return st;
}

static AowlStatus AOWLSPT_CALL aowl_host_patch_typed(void* ctx, AowlSlice target,
                                                     int32_t kind,
                                                     AowlTypedPatchFn h,
                                                     void* user) {
    return aowlspt_nim_patch_typed(ctx, (void*)target.ptr, target.len, kind,
                                   (void*)h, user);
}

/* Calling a typed handler from the host, which cannot form a `proc` type it did
 * not declare.
 *
 * Its own trampoline for the reason every other one in the shim has one: an
 * `AowlTypedPatchFn` takes two parameters where an `AowlPatchFn` takes four,
 * and calling one through the other is not a type error anywhere -- both are
 * `void*` by the time they reach here -- it is a handler reading its frame
 * pointer out of a register nobody set. */
static int32_t aowl_invoke_typed_patch(void* cb, void* user, void* frame) {
    return (int32_t)((AowlTypedPatchFn)cb)(user, (const AowlPatchFrame*)frame);
}

/* Fills the two fields and only then grows `size` to match.
 *
 * The order matters and is not decorative: `size` is the one thing a mod is
 * told it may trust before dereferencing an appended function pointer, so it
 * must never be the larger value while either pointer is still null. */
static void aowl_hostapi_arm_live(void* p) {
    AowlHostBlock* b = (AowlHostBlock*)p;
    if (!b) return;
    b->api.handle_pointer = aowl_host_handle_pointer;
    b->api.handle_pin     = aowl_host_handle_pin;
    b->api.size           = AOWLSPT_HOSTAPI_SIZE_REV3;
}

/* And revision 4, separately.
 *
 * Separate from `arm_live` rather than folded into it because the two are not
 * the same capability: `handle_pointer` needs a managed heap, `patch_typed`
 * needs a working detour engine, and a host could have the first without the
 * second -- an install where every patch slot is taken, or a build where the
 * engine refused every candidate. Arming them together would have `size` claim
 * a function that cannot work.
 *
 * Called after `arm_live`, and `size` only ever grows. */
static void aowl_hostapi_arm_typed(void* p) {
    AowlHostBlock* b = (AowlHostBlock*)p;
    if (!b) return;
    b->api.patch_typed = aowl_host_patch_typed;
    b->api.size        = AOWLSPT_HOSTAPI_SIZE_REV4;
}

/* Revision 6: the render-phase callback.
 *
 * `invoke_render` sits at the end of the struct, past `notify_push` (revision
 * 5), which the client host does not implement. The watermark rule is that
 * `size` may only reach an entry when every entry below it is real -- so to
 * claim `invoke_render` this must first fill the `notify_push` slot it is
 * skipping. It does exactly what the note at the bottom of this file said a host
 * growing past revision 4 would have to: install an `ErrUnsupported` stub for
 * the entry it does not implement, then raise `size` last. The client host has
 * no notifier socket, so its `notify_push` honestly answers `ErrUnsupported` --
 * the same answer a size-4 `notifyReady()` conveyed, now said through the entry
 * instead of through the watermark. */
static AowlStatus AOWLSPT_CALL aowl_host_invoke_render(void* ctx,
                                                       AowlCallbackFn cb,
                                                       void* user) {
    return (AowlStatus)aowlspt_nim_invoke_render(ctx, (void*)cb, user);
}

static AowlStatus AOWLSPT_CALL aowl_host_notify_unsupported(void* ctx,
                                                            AowlSlice session,
                                                            AowlSlice payload) {
    (void)ctx; (void)session; (void)payload;
    return AOWLSPT_ERR_UNSUPPORTED;
}

/* Armed only when a render-phase drain is available on this build. Called after
 * `arm_typed`; `size` only ever grows. If the render drain never binds this is
 * not called, `size` stays at revision 4/5, and a mod's read of `invoke_render`
 * is gated off by the watermark -- the honest "no render loop here". */
static void aowl_hostapi_arm_render(void* p) {
    AowlHostBlock* b = (AowlHostBlock*)p;
    if (!b) return;
    if (!b->api.notify_push) b->api.notify_push = aowl_host_notify_unsupported;
    b->api.invoke_render = aowl_host_invoke_render;
    b->api.size          = AOWLSPT_HOSTAPI_SIZE_REV6;
}

/* Where the client host stops, and why 216 against a mod's 224 is not a bug.
 * ---------------------------------------------------------------------------
 *
 * This is the last thing the IL2CPP host arms, so the block it hands a mod
 * reports `size == AOWLSPT_HOSTAPI_SIZE_REV4`, which is 216. A mod is compiled
 * against the current header and therefore has `sizeof(AowlHostApi) == 224`,
 * which is `AOWLSPT_HOSTAPI_SIZE_REV5`. The two numbers differ on purpose and
 * neither of them is stale: revision 5 is `notify_push`, the notifier needs a
 * socket and a connected client, and the thing that has those is the backend.
 * The client host has no notifier, so it does not claim one.
 *
 * `size` is a **watermark, not a version**: it says "there is a real function
 * at every offset below this", and nothing else. A client mod's `notifyReady()`
 * is therefore false, by size, and that is the truth about this host rather
 * than a mismatch to be fixed. Raising `size` here without filling
 * `notify_push` would turn an honest "no" into a null pointer a mod is entitled
 * to call.
 *
 * The backend reaches 224 by the other road: `aowlspt_notify.h` installs
 * `ErrUnsupported` stubs for the live-object entries it cannot implement, and
 * only *then* raises `size`. Both patterns are honest and the rule they share
 * is the one that matters -- `size` is raised last, never past an entry that is
 * still null. A host that grows a reason to reach revision 5 arms it the same
 * way: stubs first, `size` last.
 */

#endif /* AOWLSPT_LIVE_H */
