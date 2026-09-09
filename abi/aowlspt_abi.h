/* aowlspt_abi.h — the one contract between a compiled mod and its host.
 *
 * A mod is a native shared library (.dll). A host is whatever loaded it: the
 * aowlspt backend (the server process), the IL2CPP client host injected into
 * the game, or the out-of-game simulator. All three are nimony today, and the
 * two this file was first written for -- an SPT 4.x C# server and a BepInEx
 * plugin -- are gone: post-1.0 Tarkov is IL2CPP, so there are no managed
 * assemblies to plug into and nothing to write a C# host against. Neither side
 * knows the other's language; both know this file.
 *
 * Design rules, in the order they matter:
 *
 *  1. C ABI only. No C++, no name mangling, no exceptions across the boundary.
 *     Every cross-boundary function is `cdecl` and returns a status code.
 *
 *  2. One allocator. The host owns it. A mingw-built DLL and a .NET host do not
 *     share a CRT heap, so a buffer allocated on one side and freed on the other
 *     is a crash waiting for a busy raid. Anything that outlives a call is
 *     allocated with `AowlHostApi.alloc` and freed with `AowlHostApi.free`,
 *     whichever side does it.
 *
 *  3. Borrowed in, owned out. An `AowlSlice` passed *into* a function is valid
 *     only for that call — copy it if you need it later. To hand data back, fill
 *     an `AowlBuffer` using the host allocator; the receiver frees it.
 *
 *  4. Additive versioning. Structs carry their own `size` as the first field.
 *     New fields are appended, never inserted or reordered, and a peer checks
 *     `size` before touching anything added after v1. `AOWLSPT_ABI_VERSION`
 *     bumps only on a genuinely breaking change.
 *
 *  5. No SPT types here. The typed SPT model surface is generated per SPT
 *     version and travels as encoded payloads; this header stays stable while
 *     BSG and SPT churn underneath it.
 */

#ifndef AOWLSPT_ABI_H
#define AOWLSPT_ABI_H

#include <stdint.h>
#include <stddef.h>

/* The typed patch frame, for `patch_typed` below. Its own header because a mod
 * that only wants the fast hook path should not have to think about the rest of
 * this file, and because it is included by the detour engine's tests too. */
#include "aowlspt_frame.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ *
 * Versioning
 * ------------------------------------------------------------------ */

/* Breaking-change counter. A host refuses a mod whose major differs. */
#define AOWLSPT_ABI_VERSION 1u

/* Additive revision within version 1. A host may expose a higher revision than
 * a mod was built against; the mod uses struct `size` to tell what is present. */
#define AOWLSPT_ABI_REVISION 6u

#if defined(_WIN32)
#  define AOWLSPT_CALL __cdecl
#  define AOWLSPT_EXPORT __declspec(dllexport)
#else
#  define AOWLSPT_CALL
#  define AOWLSPT_EXPORT __attribute__((visibility("default")))
#endif

/* ------------------------------------------------------------------ *
 * Primitives
 * ------------------------------------------------------------------ */

typedef int32_t AowlStatus;

#define AOWLSPT_OK                 0
#define AOWLSPT_ERR_GENERIC       -1  /* unclassified failure; see error text  */
#define AOWLSPT_ERR_ABI          -2  /* version / struct-size mismatch        */
#define AOWLSPT_ERR_NOT_FOUND     -3  /* no such route, key, service, member   */
#define AOWLSPT_ERR_BAD_ARG       -4  /* null or malformed argument            */
#define AOWLSPT_ERR_DECODE        -5  /* payload did not parse                 */
#define AOWLSPT_ERR_UNSUPPORTED   -6  /* valid request, this host cannot do it */
#define AOWLSPT_ERR_WRONG_THREAD  -7  /* must be called on the main thread     */
#define AOWLSPT_ERR_DISPOSED      -8  /* handle already released               */
#define AOWLSPT_ERR_MOD_FAULT     -9  /* the mod raised past its own boundary  */
#define AOWLSPT_ERR_CONFIG_PARSE -10  /* the config file itself did not parse  */

/* On -10, and why it is a status rather than a struct field.
 *
 * `config_get` answered `AOWLSPT_ERR_NOT_FOUND` for two different facts, and
 * only one of them is about the key. "There is no such setting, use your
 * default" is ordinary and every mod handles it by carrying on. "This file did
 * not parse, so *none* of this mod's settings are real" is a broken install,
 * and a mod that carries on there runs the whole session on defaults while its
 * config sits on disk being ignored.
 *
 * That is not hypothetical. A three-byte UTF-8 BOM -- which Notepad and
 * `Set-Content -Encoding utf8` write by default -- put the mod manager in
 * exactly that state: `activeLists` read as empty, nothing resolved, and it
 * wrote a selection file naming only itself, so the next start loaded one mod
 * out of ten with no error anywhere. `readTextFile` strips that BOM now. A
 * trailing comma, a half-finished write and a UTF-16 save all reproduce it,
 * and the ambiguity is what made any of them silent.
 *
 * The compatibility rule this obeys: a mod that only tests `!= AOWLSPT_OK`
 * behaves **exactly as it did**, because -10 is as non-OK as -3 was. A mod
 * that tests `== AOWLSPT_ERR_NOT_FOUND` to mean "absent, use my default" now
 * stops matching on a broken file -- which is the fix, not a regression: it
 * was matching on a broken file and calling it absent. Nothing that used to
 * be answered `AOWLSPT_ERR_NOT_FOUND` and *was* a missing key changes status,
 * so no mod loses a case it was handling.
 *
 * No revision bump: status codes live outside `AowlHostApi`, nothing was
 * appended to the host block, and `size` is untouched. A mod built against an
 * older header simply never sees the constant by name.
 *
 * Every host that has a config file answers this the same way, and each one
 * sets `last_error` to a sentence naming the **file** and the fault -- the
 * offset and what was found there -- rather than the key, because the key was
 * never the problem. Each also logs it once per mod, at warn, so that the
 * breakage is visible to whoever is reading the host log even when the mod
 * swallows the status.
 */

/* A borrowed, non-owning view of bytes. `ptr` may be NULL iff `len` is 0.
 * Text is UTF-8 and is NOT required to be NUL-terminated. */
typedef struct AowlSlice {
    const uint8_t* ptr;
    int32_t        len;
} AowlSlice;

/* An owned buffer. Whoever receives it frees it with the host allocator.
 * A zeroed AowlBuffer is the valid "nothing returned" value. */
typedef struct AowlBuffer {
    uint8_t* ptr;
    int32_t  len;
} AowlBuffer;

/* An opaque reference to a host-side object (a profile, a service, a Unity
 * component). 0 is the null handle. Release with `AowlHostApi.handle_release`. */
typedef uint64_t AowlHandle;

#define AOWLSPT_NULL_HANDLE ((AowlHandle)0)

/* How a payload is encoded. JSON is the lingua franca and every host must
 * support it; the others are negotiated via `AowlHostInfo.encodings`. */
typedef enum AowlEncoding {
    AOWLSPT_ENC_JSON  = 0,  /* UTF-8 JSON — always supported                */
    AOWLSPT_ENC_CBOR  = 1,  /* compact binary, same data model as JSON      */
    AOWLSPT_ENC_RAW   = 2,  /* opaque bytes, meaning fixed by the endpoint  */
    AOWLSPT_ENC_NIF   = 3   /* aoughwl NIF term — host-native aowl values   */
} AowlEncoding;

typedef enum AowlLogLevel {
    AOWLSPT_LOG_TRACE   = 0,
    AOWLSPT_LOG_DEBUG   = 1,
    AOWLSPT_LOG_INFO    = 2,
    AOWLSPT_LOG_SUCCESS = 3,
    AOWLSPT_LOG_WARN    = 4,
    AOWLSPT_LOG_ERROR   = 5
} AowlLogLevel;

/* Which host is on the other end. A mod may support any subset. */
typedef enum AowlSide {
    AOWLSPT_SIDE_SERVER = 1,  /* aowlspt-backend: the server process         */
    AOWLSPT_SIDE_CLIENT = 2,  /* the host injected into the IL2CPP game       */
    AOWLSPT_SIDE_SIM    = 3   /* aowlspt-sim: no game, for tests + debugging  */
} AowlSide;

/* ------------------------------------------------------------------ *
 * Callback shapes
 * ------------------------------------------------------------------ */

/* Every mod-side callback takes the `user` cookie it was registered with, so a
 * mod never needs globals to find its own state. `out` is optional: a callback
 * that has nothing to return leaves it zeroed. */
typedef AowlStatus (AOWLSPT_CALL *AowlCallbackFn)(
    void* user,
    AowlSlice payload,
    AowlBuffer* out);

/* An HTTP route handler. `url` is the matched URL, `body` the request body,
 * `session` the SPT session id (empty when the request carries none). */
typedef AowlStatus (AOWLSPT_CALL *AowlRouteFn)(
    void* user,
    AowlSlice url,
    AowlSlice body,
    AowlSlice session,
    AowlBuffer* out);

/* A patch on a host method. `args` is the encoded argument list; a prefix
 * patch may write `out` to replace the result and return AOWLSPT_PATCH_SKIP
 * to suppress the original.
 *
 * A **postfix** patch is handed the same shape with one more member, `result`,
 * holding what the original returned, and returns AOWLSPT_PATCH_SKIP with a
 * replacement in `out` to change it. Same status, same buffer, and the same
 * "the host decides whether that value can be produced" rule -- it means
 * "suppress" before the original and "replace" after it, because in both cases
 * it is the one decision available: what the caller ends up with. */
typedef AowlStatus (AOWLSPT_CALL *AowlPatchFn)(
    void* user,
    AowlSlice target,
    AowlSlice args,
    AowlBuffer* out);

/* Returned by a prefix patch to skip the original method, or by a postfix patch
 * to replace what it returned. Distinct from OK so that "ran fine, continue"
 * stays the zero value. */
#define AOWLSPT_PATCH_SKIP 1

/* OR this into `kind` to ask for the original arguments.
 *
 * A flag rather than a fourth patch kind, because it is orthogonal to prefix
 * and postfix -- and opt-in rather than always-on, because decoding arguments
 * costs a JSON build inside a method the game may call thousands of times a
 * frame. A patch that only wants to count calls should not pay for one. */
#define AOWLSPT_PATCH_ARGS 0x10

/* A postfix asks for the arguments the same way a prefix does. It is worth
 * saying which way round the values are: the arguments reported to a postfix are
 * the ones the method was *entered* with, read from the registers saved on the
 * way in, because that is the only place they still exist once the original has
 * run. `result` is the value it produced. */
/* A **typed** patch handler. Same decision, none of the payload.
 *
 * `frame` is a borrowed view of the registers the thunk saved, plus the shapes
 * the host worked out when the patch was registered -- see `aowlspt_frame.h`.
 * The handler reads argument `i` by index and by declared kind, reads or
 * replaces the return value the same way, and returns the same two statuses an
 * `AowlPatchFn` does: `AOWLSPT_OK` to carry on and `AOWLSPT_PATCH_SKIP` to
 * suppress (prefix) or replace (postfix), having written the value with
 * `aowl_frame_set_ret_*`.
 *
 * There is no `AowlBuffer` because there is nothing to allocate: a replacement
 * is eight bytes written into the saved frame rather than a JSON string built
 * on one side of the ABI and freed on the other.
 *
 * `frame` is valid **only for the duration of this call**, and that is enforced
 * rather than asked for: the host clears the frame when the handler returns and
 * every accessor refuses a cleared one, naming the mistake. */
typedef AowlStatus (AOWLSPT_CALL *AowlTypedPatchFn)(
    void* user,
    const AowlPatchFrame* frame);

typedef enum AowlPatchKind {
    AOWLSPT_PATCH_PREFIX   = 0,
    AOWLSPT_PATCH_POSTFIX  = 1,
    AOWLSPT_PATCH_FINALIZER = 2
} AowlPatchKind;

typedef enum AowlRouteKind {
    AOWLSPT_ROUTE_STATIC  = 0,  /* exact URL match                          */
    AOWLSPT_ROUTE_DYNAMIC = 1   /* prefix match, URL carries parameters      */
} AowlRouteKind;

/* ------------------------------------------------------------------ *
 * Host → mod: what the mod may ask for
 * ------------------------------------------------------------------ */

typedef struct AowlHostInfo {
    int32_t     size;         /* sizeof(AowlHostInfo)                        */
    uint32_t    abi_version;  /* AOWLSPT_ABI_VERSION the host implements     */
    uint32_t    abi_revision; /* AOWLSPT_ABI_REVISION                        */
    int32_t     side;         /* AowlSide                                    */
    AowlSlice   host_name;    /* e.g. "aowlspt-server"                       */
    AowlSlice   host_version; /* the host's own version                      */
    AowlSlice   spt_version;  /* SPT version, empty on the sim               */
    AowlSlice   game_version; /* EFT build, empty server-side                */
    uint32_t    encodings;    /* bitmask: 1<<AowlEncoding for each supported */
    AowlSlice   mod_dir;      /* absolute path to this mod's own directory   */
    AowlSlice   data_dir;     /* writable scratch owned by this mod          */
} AowlHostInfo;

typedef struct AowlHostApi {
    int32_t size;  /* sizeof(AowlHostApi) — check before reading late fields */

    /* Opaque host context. Pass back verbatim as the first argument of every
     * function below; a mod must never interpret it. */
    void* ctx;

    const AowlHostInfo* info;

    /* -- memory ---------------------------------------------------------- */

    /* The single cross-boundary allocator. `alloc(0)` returns NULL and is not
     * an error. `free(NULL)` is a no-op. */
    void* (AOWLSPT_CALL *alloc)(void* ctx, int32_t bytes);
    void  (AOWLSPT_CALL *free)(void* ctx, void* ptr);

    /* -- diagnostics ------------------------------------------------------ */

    void (AOWLSPT_CALL *log)(void* ctx, int32_t level, AowlSlice message);

    /* Text of the last failure on this thread, valid until the next host call.
     * Every non-OK status should be paired with a set error.
     *
     * Written through `out` rather than returned: a 16-byte struct return is
     * where the mingw and MSVC ABIs disagree about hidden-pointer handling, and
     * that disagreement corrupts silently instead of failing to link. */
    void (AOWLSPT_CALL *last_error)(void* ctx, AowlSlice* out);

    /* -- configuration ---------------------------------------------------- */

    /* Read this mod's config value at a dotted `key` path. An empty `key`
     * returns the whole document, which is how a mod with fifty settings reads
     * them in one round trip rather than fifty.
     *
     * Three answers, and the third is the one worth reading twice:
     *
     *   * `AOWLSPT_OK` -- the value is in `out`.
     *   * `AOWLSPT_ERR_NOT_FOUND` -- there is no config file, or it parses and
     *     does not hold that key. **Normal.** Use your default.
     *   * `AOWLSPT_ERR_CONFIG_PARSE` -- the file exists and is not readable
     *     JSON. **Not normal, and not about the key**: no key in this file can
     *     be answered, so every setting the mod thinks it read is a default.
     *     `last_error` names the file and the fault.
     *
     * A mod that treats the third like the second is the bug this status
     * exists to end. What to do with it is the mod's decision, and both
     * choices are defensible -- refuse to load, or run on defaults and say so
     * loudly at error level -- but it must be a decision, because silently
     * running on defaults with a config file present is not one. */
    AowlStatus (AOWLSPT_CALL *config_get)(void* ctx, AowlSlice key, AowlBuffer* out);
    AowlStatus (AOWLSPT_CALL *config_set)(void* ctx, AowlSlice key, AowlSlice value_json);

    /* -- the SPT database -------------------------------------------------- */

    /* Read/patch the loaded server database by dotted path, e.g.
     * "templates.items.5447a9cd4bdc2dbd208b4567._props.Weight". `patch_json` is
     * merged, not replaced, so two mods editing sibling fields do not clobber
     * one another. Server side only. */
    AowlStatus (AOWLSPT_CALL *db_get)(void* ctx, AowlSlice path, AowlBuffer* out);
    AowlStatus (AOWLSPT_CALL *db_patch)(void* ctx, AowlSlice path, AowlSlice patch_json);

    /* -- registration, and when it may happen ------------------------------
     *
     * `route_register`, `event_subscribe`, `patch` and `patch_typed` may be
     * called **from any thread and at any point in a mod's life**, not only
     * from `on_load`. That is not a concession, it is the normal case on the
     * client: a type that does not exist yet cannot be patched, so a mod waits
     * for the game's assemblies and registers from `on_update` -- both
     * `examples/clientprobe` and `examples/lesson` do exactly that. A route
     * handler or an event handler may also register, and those arrive on
     * whichever of the backend's workers took the request.
     *
     * Two obligations follow, one on each side.
     *
     * **The host** must be able to take a registration on any thread, and to
     * take one while a firing of an earlier registration is in progress on
     * another. It must not assume registration is quiescent.
     *
     * **A mod library** must be able to hand out a `user` cookie and have it
     * stay valid for a reader that is already running. The nimony SDK
     * (`aowl/src/aowlspt.nim`) does this by reserving each of its four handler
     * tables to a fixed capacity once and never growing them again, so a
     * cookie is an index into a buffer that cannot move, and the firing path
     * takes no lock at all -- which it cannot afford to, the typed patch being
     * around 21 ns end to end against 25-27 ns for a critical-section pair on
     * the same machine. Any other binding of this ABI has the same problem and
     * needs an answer to it; `tests/regrace.nim` is the test that says whether
     * the answer works, and the unguarded version of it faults inside a second.
     *
     * The cost of the SDK's answer is a bound: 1024 registrations of each kind
     * per mod. Past that the SDK refuses with `AOWLSPT_ERR_GENERIC` rather
     * than growing, and a mod is expected to check. The busiest mod in this
     * repository registers 95 routes.
     */

    /* -- routes ------------------------------------------------------------ */

    /* Register an HTTP route. The handler stays registered until unload. */
    AowlStatus (AOWLSPT_CALL *route_register)(
        void* ctx, AowlSlice url, int32_t kind,
        AowlRouteFn handler, void* user);

    /* -- events ------------------------------------------------------------ */

    AowlStatus (AOWLSPT_CALL *event_subscribe)(
        void* ctx, AowlSlice name, AowlCallbackFn handler, void* user);

    AowlStatus (AOWLSPT_CALL *event_emit)(
        void* ctx, AowlSlice name, AowlSlice payload);

    /* -- the escape hatch --------------------------------------------------
     *
     * Anything this ABI does not name explicitly is still reachable: `call`
     * invokes a host member by name through reflection.
     *
     *   target: "Namespace.Type::Member" for a static or DI-resolved service,
     *           or "#<handle>::Member" to call on a live handle.
     *   args:   an encoded positional argument array.
     *
     * This is deliberately the slow path. Use it to reach a corner of SPT the
     * fast path has not grown a door for yet — and when a call turns out to be
     * hot, promote it into this header rather than looping on reflection.
     */
    AowlStatus (AOWLSPT_CALL *call)(
        void* ctx, AowlSlice target, AowlSlice args, AowlBuffer* out);

    /* Resolve a host service (DI container server-side, component client-side)
     * to a handle usable as the `#<handle>` form of `call`. */
    AowlStatus (AOWLSPT_CALL *resolve)(void* ctx, AowlSlice type_name, AowlHandle* out);

    void (AOWLSPT_CALL *handle_release)(void* ctx, AowlHandle handle);

    /* -- patching ---------------------------------------------------------- */

    /* Harmony patch on a host method, by "Namespace.Type::Method" name. */
    AowlStatus (AOWLSPT_CALL *patch)(
        void* ctx, AowlSlice target, int32_t kind,
        AowlPatchFn handler, void* user);

    /* -- scheduling -------------------------------------------------------- */

    /* Run `cb` once, `delay_ms` from now, on the host's main thread. */
    AowlStatus (AOWLSPT_CALL *schedule)(
        void* ctx, int32_t delay_ms, AowlCallbackFn cb, void* user);

    /* Run `cb` on the main thread as soon as possible. Safe from any thread —
     * this is how a mod's worker thread touches Unity objects. */
    AowlStatus (AOWLSPT_CALL *invoke_main)(
        void* ctx, AowlCallbackFn cb, void* user);

    /* Monotonic milliseconds since host start. */
    int64_t (AOWLSPT_CALL *now_ms)(void* ctx);

    /* -- persistence (revision 2) ------------------------------------------
     *
     * A private key/value store per mod, held by the host and surviving a
     * restart. `db_get`/`db_patch` address the *shared* game database, which is
     * loaded from disk and common to every mod; this is where a mod keeps what
     * belongs to it alone — profiles, progress, anything it must still know
     * next time.
     *
     * A mod could open files itself, and then every mod would invent its own
     * layout inside the install and there would be no way for the host to move,
     * back up or clear a mod's data. Keys are flat, `[A-Za-z0-9._-]`, and a key
     * outside that set is rejected rather than sanitised: silently mapping two
     * keys onto one file is worse than refusing one of them.
     *
     * `store_list` returns a JSON array of the keys beginning with `prefix`,
     * which is what makes "every profile" expressible without the mod knowing
     * where the host put them. */
    AowlStatus (AOWLSPT_CALL *store_get)(void* ctx, AowlSlice key, AowlBuffer* out);
    AowlStatus (AOWLSPT_CALL *store_set)(void* ctx, AowlSlice key, AowlSlice value);
    AowlStatus (AOWLSPT_CALL *store_list)(void* ctx, AowlSlice prefix, AowlBuffer* out);

    /* -- live object addresses (revision 3) --------------------------------
     *
     * `resolve`, `call` and a patch's arguments all hand a mod an `AowlHandle`,
     * and a handle is the only safe *durable* reference to a managed object:
     * the collector moves objects, so the host holds a GC handle underneath and
     * asks it for the address afresh every time. That is what makes a handle
     * survive a frame.
     *
     * It is also what makes a handle useless to a mod's own fast path. Binding
     * a method or a field against `GameAssembly.dll` directly -- which is where
     * the order-of-magnitude win is, see docs/PERF.md -- needs the *address*,
     * and there was no way to get one. A hook that fired for an object could
     * therefore only reach it back through `call`, at roughly a microsecond a
     * time, which on a method the game runs per entity per frame is a frame tax
     * rather than a feature. Two mods measured it and left five features out.
     *
     * `handle_pointer` closes that. It writes the object's address *now*.
     *
     *   - It is an address, not a handle: nothing keeps it alive and nothing
     *     keeps it still. **Use it within the call you got it in and do not
     *     store it.** A collection between two frames moves the object and the
     *     saved address then names whatever moved into that space.
     *   - Inside a patch handler, `this` and every reference argument are host
     *     handles the host reclaims **when the handler returns**. Calling this
     *     with one afterwards is refused with `AOWLSPT_ERR_DISPOSED` rather
     *     than answered with the address it used to have -- the host asks the
     *     GC handle, and a reclaimed one has no target.
     *   - A handle from `resolve` names a *type*, not an object, and is refused
     *     with `AOWLSPT_ERR_BAD_ARG`. Handing back a class pointer where the
     *     caller expected an instance is the kind of confusion that produces a
     *     plausible number rather than a crash.
     *
     * `handle_pin` is the answer for a mod that must keep one. It takes a
     * **pinned** GC handle over the same object and returns a fresh handle for
     * it; the address of a pinned object does not move, so `handle_pointer` on
     * the *pinned* handle gives an address that stays correct for as long as
     * the pin lives. The cost is explicit and it is not small: the object is
     * immovable, and it is immovable **for the rest of the session** unless the
     * mod calls `handle_release` on the pinned handle. Pin the handful of
     * long-lived objects a mod really tracks -- the local player, the world --
     * and nothing else. */
    AowlStatus (AOWLSPT_CALL *handle_pointer)(
        void* ctx, AowlHandle handle, uint64_t* out_address);

    /* Written as `uint64_t*` rather than `void**` on purpose: this is an
     * address the *mod* will hand to its own binding of the IL2CPP runtime, and
     * nothing on the host side of the boundary ever dereferences it. Typing it
     * as a pointer would invite exactly that. */
    AowlStatus (AOWLSPT_CALL *handle_pin)(
        void* ctx, AowlHandle handle, AowlHandle* out_pinned);

    /* -- typed patches (revision 4) ----------------------------------------
     *
     * `patch` delivers a firing's arguments as JSON and takes a replacement
     * back the same way. That is a string built on the host side, a GC handle
     * per reference argument, a copy into the mod's heap, and a parse -- per
     * call, inside a method the game may run per entity per frame. Measured
     * against the stand-in runtime: 1144 ns for a postfix that reads the
     * arguments, 1615 ns for one that also replaces the result, and 645 ns for
     * a prefix -- against 3.3 ns for the unpatched call, and 25 ns for the
     * same postfix through `patch_typed`.
     *
     * `patch_typed` is the same detour with none of that. The handler is given
     * a borrowed view of the registers the thunk already saved, plus the
     * declared kind of every slot, worked out once here at registration. It
     * allocates nothing on either side of the boundary and asks the runtime
     * nothing per firing.
     *
     * It does *not* replace `patch`. JSON is self-describing, survives an
     * argument the host cannot classify, and is what a mod on a once-a-second
     * hook should keep using. This is for the mod that has measured a per-frame
     * hook and needs the machine words.
     *
     * `kind` is read exactly as `patch` reads it -- the low bits are the
     * `AowlPatchKind`, and a postfix is refused on the same two method shapes.
     * `AOWLSPT_PATCH_ARGS` is *not* consulted: a typed frame has the arguments
     * in it either way, because pointing at a register costs nothing and the
     * flag exists to avoid a cost that no longer applies. A typed prefix may
     * always suppress. */
    AowlStatus (AOWLSPT_CALL *patch_typed)(
        void* ctx, AowlSlice target, int32_t kind,
        AowlTypedPatchFn handler, void* user);

    /* -- server-pushed notifications (revision 5) --------------------------
     *
     * The game opens a websocket at login and expects the server to push down
     * it: new mail, an insurance return, a flea offer sold, a raid invitation.
     * Everything a server decides on its own has nowhere to go without one --
     * the profile can change all it likes and the player finds out on the next
     * screen that happens to reload.
     *
     * A mod should not have to know that a socket is what carries this, which
     * is the whole argument for the entry being this small: `session` is the
     * player, `payload` is the JSON event the client dispatches on, and where
     * it goes is the host's problem. `mods/tarkov` builds the event and calls
     * this; `backend/websocket.nim` finds the connection, frames it and writes
     * it; `abi/aowlspt_net.h` owns the socket and the lock.
     *
     * Two return values carry the whole contract:
     *
     *   * `AOWLSPT_OK` -- the frame went out on this session's websocket.
     *   * `AOWLSPT_ERR_NOT_FOUND` -- there is no websocket open for that
     *     session. **That is a normal answer, not a failure.** A client that
     *     has not upgraded, or has not logged in yet, or has just lost the
     *     connection is in this state, and the mod's job is to fall back to
     *     whatever it did before -- a queue drained by a poll, in the
     *     emulator's case. A host that answered `OK` for a notification it
     *     dropped would be telling the mod the player has been informed.
     *
     * `AOWLSPT_ERR_UNSUPPORTED` on a host with no websocket to push down,
     * which is every host that is not the backend: there is no notifier socket
     * inside the game process and none in the simulator. */
    AowlStatus (AOWLSPT_CALL *notify_push)(
        void* ctx, AowlSlice session, AowlSlice payload);

    /* -- render-phase main-thread callback (revision 6) --------------------
     *
     * `invoke_main` runs `cb` on Unity's main thread in the UPDATE phase, which
     * is the right thread but the wrong point in the frame for immediate-mode
     * `UnityEngine.GL` drawing: GL only rasterizes during the RENDER phase, and
     * post-1.0 has no `OnGUI`. So an ESP box or a GL HUD queued with
     * `invoke_main` is on the correct thread and draws nothing.
     *
     * `invoke_render` runs `cb` on Unity's thread DURING rendering -- the host
     * detours a render-phase per-frame method and drains a second queue from
     * inside it -- so `GL.*` issued from `cb` lands on the frame being drawn.
     * This is what a native ESP or GL-HUD mod uses.
     *
     *   * `AOWLSPT_OK` -- queued for the next render.
     *   * `AOWLSPT_ERR_UNSUPPORTED` -- no render-phase drain is bound: the host
     *     could not detour a render point on this build, or the game is not yet
     *     in a scene that has one (the callback the drain rides is raid-time).
     *     A mod gates on `call("aowlspt.host::render_thread")` -> `bound:true`
     *     and, until then, does not draw. This is a normal answer, not a bug.
     *
     * A host with no IL2CPP render loop (the backend, the simulator) leaves this
     * null and reports the revision-5 `size`; a client checks `size` before
     * calling it, exactly as for every appended entry. */
    AowlStatus (AOWLSPT_CALL *invoke_render)(
        void* ctx, AowlCallbackFn cb, void* user);
} AowlHostApi;

/* How large `AowlHostApi` was at each revision.
 *
 * A mod tests `AowlHostApi.size` before touching an appended field, and the
 * obvious test -- `size >= sizeof(AowlHostApi)` -- is right exactly once and
 * then quietly wrong: the next revision grows `sizeof`, and a mod that only
 * wanted the revision-2 fields starts refusing a host that has them. So each
 * revision's boundary is named, and a capability is tested against the boundary
 * it appeared at rather than against the end of the struct.
 *
 * `tests/abi_layout.c` pins these to the real offsets, which is the only way
 * they stay true. */
#define AOWLSPT_HOSTAPI_SIZE_REV1 ((int32_t)offsetof(AowlHostApi, store_get))
#define AOWLSPT_HOSTAPI_SIZE_REV2 ((int32_t)offsetof(AowlHostApi, handle_pointer))
#define AOWLSPT_HOSTAPI_SIZE_REV3 ((int32_t)offsetof(AowlHostApi, patch_typed))
#define AOWLSPT_HOSTAPI_SIZE_REV4 ((int32_t)offsetof(AowlHostApi, notify_push))
#define AOWLSPT_HOSTAPI_SIZE_REV5 ((int32_t)offsetof(AowlHostApi, invoke_render))
#define AOWLSPT_HOSTAPI_SIZE_REV6 ((int32_t)sizeof(AowlHostApi))

/* One consequence of `size` being a *watermark* rather than a set, which was
 * latent until revision 5 and is not any more.
 *
 * Revisions 3 and 4 need a managed heap and a detour engine, so only the
 * IL2CPP client host fills them. Revision 5 needs a listening socket, so only
 * the backend fills it. There is no way to say "the fifth and not the third"
 * in one integer, and the backend must say something: reporting revision 2
 * hides `notify_push`, and reporting revision 5 over three null pointers tells a
 * mod to call them.
 *
 * So the backend fills them -- with the refusal it already owes. Every host
 * already returns `AOWLSPT_ERR_UNSUPPORTED` from the rev-1 entries it cannot
 * honour (`call`, `resolve` and `patch` on the backend are exactly that), and
 * `aowl_hostapi_arm_notify` in `abi/aowlspt_notify.h` extends the same treatment
 * forward: it installs refusing implementations of `handle_pointer`,
 * `handle_pin` and `patch_typed` and only then raises `size` to
 * `AOWLSPT_HOSTAPI_SIZE_REV5`. A mod that asks the backend for a live address
 * gets `AOWLSPT_ERR_UNSUPPORTED` -- the same status, from the same call, as
 * before -- and the boundary test keeps meaning "there is a function here that
 * will answer" rather than "this capability works", which is the only thing a
 * null check could ever have established either. */

/* ------------------------------------------------------------------ *
 * Mod → host: what the mod provides
 * ------------------------------------------------------------------ */

typedef struct AowlModInfo {
    int32_t   size;        /* sizeof(AowlModInfo)                           */
    uint32_t  abi_version; /* AOWLSPT_ABI_VERSION the mod was built against  */
    uint32_t  abi_revision;
    AowlSlice guid;        /* reverse-dns unique id, e.g. "aowl.basement"    */
    AowlSlice name;
    AowlSlice author;
    AowlSlice version;     /* semver                                        */
    AowlSlice spt_range;   /* semver range, e.g. "~4.1.0"                   */
    uint32_t  sides;       /* bitmask: 1<<AowlSide for each side supported   */
    uint32_t  flags;       /* AowlModFlags                                  */
} AowlModInfo;

typedef enum AowlModFlags {
    /* The mod implements state_save/state_load and may be hot-reloaded in a
     * running host without a restart. */
    AOWLSPT_MOD_HOT_RELOADABLE = 1u << 0,
    /* The mod's callbacks are safe to call off the main thread. */
    AOWLSPT_MOD_THREAD_SAFE    = 1u << 1
} AowlModFlags;

typedef struct AowlModApi {
    int32_t size;  /* sizeof(AowlModApi) */

    /* The mod's own instance pointer, handed back to every entry below. */
    void* self;

    /* Called after init, once the host is ready to serve. */
    AowlStatus (AOWLSPT_CALL *on_load)(void* self);

    /* Periodic tick. `elapsed_ms` since the previous tick. Optional. */
    AowlStatus (AOWLSPT_CALL *on_update)(void* self, int64_t elapsed_ms);

    /* Called before unload. The mod must deregister nothing — the host drops
     * every registration itself — but must stop its own threads here. */
    AowlStatus (AOWLSPT_CALL *on_unload)(void* self);

    /* -- hot reload --------------------------------------------------------
     * Serialize everything the next incarnation needs into `out`, then take it
     * back in the freshly loaded library. Only consulted when the mod set
     * AOWLSPT_MOD_HOT_RELOADABLE. */
    AowlStatus (AOWLSPT_CALL *state_save)(void* self, AowlBuffer* out);
    AowlStatus (AOWLSPT_CALL *state_load)(void* self, AowlSlice state);
} AowlModApi;

/* ------------------------------------------------------------------ *
 * The exported entry points — every mod library exports exactly these
 * ------------------------------------------------------------------ */

/* Cheapest possible probe: the host calls this before anything else and
 * refuses the library on a major mismatch, without running mod code. */
typedef uint32_t (AOWLSPT_CALL *AowlAbiVersionFn)(void);

/* Fill in `out`. Called before `init`, so it must not depend on host services. */
typedef AowlStatus (AOWLSPT_CALL *AowlDescribeFn)(AowlModInfo* out);

/* Hand over the host API, take back the mod API. The mod stores `host` and may
 * call it from here on. Returning non-OK aborts the load cleanly. */
typedef AowlStatus (AOWLSPT_CALL *AowlInitFn)(const AowlHostApi* host, AowlModApi* out);

/* Symbol names the host looks up. Spelled out so both sides agree in one place. */
#define AOWLSPT_SYM_ABI_VERSION "aowlspt_abi_version"
#define AOWLSPT_SYM_DESCRIBE    "aowlspt_describe"
#define AOWLSPT_SYM_INIT        "aowlspt_init"

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* AOWLSPT_ABI_H */
