/* aowlspt_abi.h — the one contract between a compiled mod and its host.
 *
 * A mod is a native shared library (.dll). A host is whatever loaded it: the
 * SPT 4.x C# server, the BepInEx client plugin, or the out-of-game simulator.
 * Neither side knows the other's language; both know this file.
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
#define AOWLSPT_ABI_REVISION 1u

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
    AOWLSPT_SIDE_SERVER = 1,  /* SPT 4.x C# server process                  */
    AOWLSPT_SIDE_CLIENT = 2,  /* BepInEx plugin inside the Unity game        */
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
 * to suppress the original. */
typedef AowlStatus (AOWLSPT_CALL *AowlPatchFn)(
    void* user,
    AowlSlice target,
    AowlSlice args,
    AowlBuffer* out);

/* Returned by a prefix patch to skip the original method. Distinct from OK so
 * that "ran fine, continue" stays the zero value. */
#define AOWLSPT_PATCH_SKIP 1

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

    /* Read this mod's config value at a dotted `key` path. */
    AowlStatus (AOWLSPT_CALL *config_get)(void* ctx, AowlSlice key, AowlBuffer* out);
    AowlStatus (AOWLSPT_CALL *config_set)(void* ctx, AowlSlice key, AowlSlice value_json);

    /* -- the SPT database -------------------------------------------------- */

    /* Read/patch the loaded server database by dotted path, e.g.
     * "templates.items.5447a9cd4bdc2dbd208b4567._props.Weight". `patch_json` is
     * merged, not replaced, so two mods editing sibling fields do not clobber
     * one another. Server side only. */
    AowlStatus (AOWLSPT_CALL *db_get)(void* ctx, AowlSlice path, AowlBuffer* out);
    AowlStatus (AOWLSPT_CALL *db_patch)(void* ctx, AowlSlice path, AowlSlice patch_json);

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
} AowlHostApi;

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
