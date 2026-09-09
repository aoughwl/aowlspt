/* aowlspt_shim.h — the C side of the nimony hosts.
 *
 * nimony will not `cast` between a `pointer` and a `proc` type, in either
 * direction, and not through an integer either. Two things a host must do run
 * straight into that:
 *
 *   * calling a mod, whose entry points arrive as `GetProcAddress` results and
 *     as function-pointer fields inside `AowlModApi`;
 *   * being called by a mod, which needs the host's own functions as pointers
 *     inside `AowlHostApi`.
 *
 * So the indirect calls live here, in C, and everything above them is nimony.
 * That split is not a workaround so much as the right layering: `aowlspt_abi.h`
 * is a C header, and a C file that `#include`s it cannot disagree with it about
 * struct layout or field order. The alternative — restating the layout in
 * nimony — is exactly the mistake `tests/abi_layout.nim` exists to catch.
 *
 * Everything here is `static`: this header is included once, into the single
 * translation unit nimony emits.
 *
 * The naming convention is `aowl_<area>_<what>`. Functions the *nimony* side
 * implements and C calls back into are declared `extern` and named
 * `aowlspt_nim_*`.
 */

#ifndef AOWLSPT_SHIM_H
#define AOWLSPT_SHIM_H

#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

#include "aowlspt_abi.h"

/* ==================================================================== *
 * IL2CPP indirect calls
 *
 * One trampoline per distinct signature in the IL2CPP C API. Every handle in
 * that API is a pointer and the only scalars are int32/uint32/size_t, so this
 * small set covers all 242 entry points.
 * ==================================================================== */

static void*    aowl_p_v    (void* f)                                     { return ((void*(*)(void))f)(); }
static void*    aowl_p_p    (void* f, void* a)                            { return ((void*(*)(void*))f)(a); }
/* A one-pointer-arg call that returns NULL instead of taking the process down
 * when it faults. IL2CPP's `il2cpp_class_get_name` on a class handed back by a
 * blind enumeration (or by `classFromName` with an empty namespace) can
 * dereference into an unmapped page on the real client; a raw call there kills
 * the game. GCC (unlike MSVC) has no `__try`, so an access violation is caught
 * with a Vectored Exception Handler that `longjmp`s back here. Diagnostic-path
 * use only -- every real call site still goes through the unguarded helper, and
 * the longjmp-past-a-held-lock risk is why this is not on any hot path. */
static __thread jmp_buf aowl_seh_jmp;
static __thread int      aowl_seh_active = 0;
static LONG CALLBACK aowl_seh_veh(PEXCEPTION_POINTERS ep) {
    if (aowl_seh_active &&
        ep->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
        aowl_seh_active = 0;
        longjmp(aowl_seh_jmp, 1);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}
static void* aowl_p_p_seh(void* f, void* a) {
    static volatile LONG installed = 0;
    if (InterlockedCompareExchange(&installed, 1, 0) == 0)
        AddVectoredExceptionHandler(1, aowl_seh_veh);
    void* r = 0;
    aowl_seh_active = 1;
    if (setjmp(aowl_seh_jmp) == 0)
        r = ((void*(*)(void*))f)(a);
    else
        r = 0;
    aowl_seh_active = 0;
    return r;
}
static void*    aowl_p_pp   (void* f, void* a, void* b)                   { return ((void*(*)(void*,void*))f)(a,b); }
static void*    aowl_p_ppp  (void* f, void* a, void* b, void* c)          { return ((void*(*)(void*,void*,void*))f)(a,b,c); }
static void*    aowl_p_pppp (void* f, void* a, void* b, void* c, void* d) { return ((void*(*)(void*,void*,void*,void*))f)(a,b,c,d); }
static void*    aowl_p_ppi  (void* f, void* a, void* b, int32_t i)        { return ((void*(*)(void*,void*,int32_t))f)(a,b,i); }
static void*    aowl_p_pz   (void* f, void* a, uint64_t z)                { return ((void*(*)(void*,size_t))f)(a,(size_t)z); }
static void*    aowl_p_u    (void* f, uint32_t u)                         { return ((void*(*)(uint32_t))f)(u); }

static void     aowl_v_v    (void* f)                                     { ((void(*)(void))f)(); }
static void     aowl_v_p    (void* f, void* a)                            { ((void(*)(void*))f)(a); }
static void     aowl_v_pp   (void* f, void* a, void* b)                   { ((void(*)(void*,void*))f)(a,b); }
static void     aowl_v_ppp  (void* f, void* a, void* b, void* c)          { ((void(*)(void*,void*,void*))f)(a,b,c); }
static void     aowl_v_u    (void* f, uint32_t u)                         { ((void(*)(uint32_t))f)(u); }

static int32_t  aowl_i32_p  (void* f, void* a)                            { return ((int32_t(*)(void*))f)(a); }
static uint32_t aowl_u32_p  (void* f, void* a)                            { return ((uint32_t(*)(void*))f)(a); }
static uint64_t aowl_z_p    (void* f, void* a)                            { return (uint64_t)((size_t(*)(void*))f)(a); }
static uint32_t aowl_u32_pi (void* f, void* a, int32_t i)                 { return ((uint32_t(*)(void*,int32_t))f)(a,i); }
static uint32_t aowl_u32_pp (void* f, void* a, void* b)                   { return ((uint32_t(*)(void*,void*))f)(a,b); }

/* Reading memory the runtime owns. Copying into a nimony string on the other
 * side sidesteps every cstring-lifetime question, and the strings involved are
 * type and member names. */
static uint8_t  aowl_byte_at (void* p, uint64_t i) { return ((const uint8_t*)p)[i]; }
static uint16_t aowl_word_at (void* p, uint64_t i) { return ((const uint16_t*)p)[i]; }

/* ==================================================================== *
 * Reading AowlModInfo
 *
 * Accessors rather than a nimony copy of the struct, so there is exactly one
 * definition of the layout in the repo.
 * ==================================================================== */

static void* aowl_modinfo_new(void) {
    AowlModInfo* m = (AowlModInfo*)calloc(1, sizeof(AowlModInfo));
    if (m) m->size = (int32_t)sizeof(AowlModInfo);
    return m;
}
static void     aowl_modinfo_free(void* p)         { free(p); }
static int32_t  aowl_modinfo_size(void* p)         { return ((AowlModInfo*)p)->size; }
static uint32_t aowl_modinfo_abi_version(void* p)  { return ((AowlModInfo*)p)->abi_version; }
static uint32_t aowl_modinfo_abi_revision(void* p) { return ((AowlModInfo*)p)->abi_revision; }
static uint32_t aowl_modinfo_sides(void* p)        { return ((AowlModInfo*)p)->sides; }
static uint32_t aowl_modinfo_flags(void* p)        { return ((AowlModInfo*)p)->flags; }

/* Slices are returned as (ptr, len) through two calls rather than by value:
 * a 12-byte struct return is precisely where the mingw and MSVC ABIs disagree
 * about hidden-pointer handling, and that disagreement corrupts silently. */
static void*   aowl_modinfo_guid_ptr(void* p)      { return (void*)((AowlModInfo*)p)->guid.ptr; }
static int32_t aowl_modinfo_guid_len(void* p)      { return ((AowlModInfo*)p)->guid.len; }
static void*   aowl_modinfo_name_ptr(void* p)      { return (void*)((AowlModInfo*)p)->name.ptr; }
static int32_t aowl_modinfo_name_len(void* p)      { return ((AowlModInfo*)p)->name.len; }
static void*   aowl_modinfo_author_ptr(void* p)    { return (void*)((AowlModInfo*)p)->author.ptr; }
static int32_t aowl_modinfo_author_len(void* p)    { return ((AowlModInfo*)p)->author.len; }
static void*   aowl_modinfo_version_ptr(void* p)   { return (void*)((AowlModInfo*)p)->version.ptr; }
static int32_t aowl_modinfo_version_len(void* p)   { return ((AowlModInfo*)p)->version.len; }
static void*   aowl_modinfo_range_ptr(void* p)     { return (void*)((AowlModInfo*)p)->spt_range.ptr; }
static int32_t aowl_modinfo_range_len(void* p)     { return ((AowlModInfo*)p)->spt_range.len; }

/* ==================================================================== *
 * Calling into a mod
 * ==================================================================== */

static uint32_t aowl_mod_abi_version(void* fn) {
    return ((AowlAbiVersionFn)fn)();
}
static int32_t aowl_mod_describe(void* fn, void* info) {
    return (int32_t)((AowlDescribeFn)fn)((AowlModInfo*)info);
}
static int32_t aowl_mod_init(void* fn, void* host, void* out) {
    return (int32_t)((AowlInitFn)fn)((const AowlHostApi*)host, (AowlModApi*)out);
}

static void* aowl_modapi_new(void) {
    AowlModApi* a = (AowlModApi*)calloc(1, sizeof(AowlModApi));
    if (a) a->size = (int32_t)sizeof(AowlModApi);
    return a;
}
static void aowl_modapi_free(void* p) { free(p); }

static int32_t aowl_modapi_has_update(void* p) { return ((AowlModApi*)p)->on_update != NULL; }
static int32_t aowl_modapi_has_load(void* p)   { return ((AowlModApi*)p)->on_load   != NULL; }
static int32_t aowl_modapi_has_unload(void* p) { return ((AowlModApi*)p)->on_unload != NULL; }

static int32_t aowl_modapi_on_load(void* p) {
    AowlModApi* a = (AowlModApi*)p;
    if (!a->on_load) return AOWLSPT_OK;
    return (int32_t)a->on_load(a->self);
}
static int32_t aowl_modapi_on_update(void* p, int64_t elapsed) {
    AowlModApi* a = (AowlModApi*)p;
    if (!a->on_update) return AOWLSPT_OK;
    return (int32_t)a->on_update(a->self, elapsed);
}
static int32_t aowl_modapi_on_unload(void* p) {
    AowlModApi* a = (AowlModApi*)p;
    if (!a->on_unload) return AOWLSPT_OK;
    return (int32_t)a->on_unload(a->self);
}

/* ==================================================================== *
 * The host vtable
 *
 * These are the functions a mod calls. Each one unpacks the ABI's structs and
 * hands flat arguments to a nimony implementation, so no nimony code ever
 * needs to know what an AowlSlice looks like.
 * ==================================================================== */

/* Every out-parameter is declared `void*` rather than as a typed pointer,
 * because that is what nimony emits for one and a mismatched extern is a
 * compile error rather than something to discover at run time. The casts
 * happen at the call sites just below. */
extern void    aowlspt_nim_log(void* ctx, int32_t level, void* msg, int32_t len);
extern void    aowlspt_nim_last_error(void* ctx, void* outPtr, void* outLen);
extern int32_t aowlspt_nim_config_get(void* ctx, void* key, int32_t keyLen,
                                      void* outPtr, void* outLen);
extern int32_t aowlspt_nim_config_set(void* ctx, void* key, int32_t keyLen,
                                      void* val, int32_t valLen);
extern int32_t aowlspt_nim_call(void* ctx, void* target, int32_t targetLen,
                                void* args, int32_t argsLen,
                                void* outPtr, void* outLen);
extern int32_t aowlspt_nim_resolve(void* ctx, void* typeName, int32_t nameLen,
                                   void* outHandle);
extern void    aowlspt_nim_handle_release(void* ctx, uint64_t handle);
extern int32_t aowlspt_nim_event_emit(void* ctx, void* name, int32_t nameLen,
                                      void* payload, int32_t payloadLen);
extern int64_t aowlspt_nim_now_ms(void* ctx);
extern int32_t aowlspt_nim_invoke_main(void* ctx, void* cb, void* user);
extern int32_t aowlspt_nim_schedule(void* ctx, int32_t delayMs, void* cb, void* user);
extern int32_t aowlspt_nim_event_subscribe(void* ctx, void* name, int32_t nameLen,
                                           void* cb, void* user);
extern int32_t aowlspt_nim_patch(void* ctx, void* target, int32_t targetLen,
                                 int32_t kind, void* cb, void* user);
extern int32_t aowlspt_nim_db_get(void* ctx, void* path, int32_t pathLen,
                                  void* outPtr, void* outLen);
extern int32_t aowlspt_nim_db_patch(void* ctx, void* path, int32_t pathLen,
                                    void* patch, int32_t patchLen);
extern int32_t aowlspt_nim_route_register(void* ctx, void* url, int32_t urlLen,
                                          int32_t kind, void* cb, void* user);
extern int32_t aowlspt_nim_store_get(void* ctx, void* key, int32_t keyLen,
                                     void* outPtr, void* outLen);
extern int32_t aowlspt_nim_store_set(void* ctx, void* key, int32_t keyLen,
                                     void* val, int32_t valLen);
extern int32_t aowlspt_nim_store_list(void* ctx, void* prefix, int32_t prefixLen,
                                      void* outPtr, void* outLen);

/* The host allocator. One malloc for the whole boundary: the mod allocates
 * through this and the host frees through it, and neither side's CRT heap is
 * ever asked to free the other's pointer. */
static void* AOWLSPT_CALL aowl_host_alloc(void* ctx, int32_t bytes) {
    (void)ctx;
    if (bytes <= 0) return NULL;
    return calloc(1, (size_t)bytes);
}
static void AOWLSPT_CALL aowl_host_free(void* ctx, void* p) {
    (void)ctx;
    free(p);
}

static void AOWLSPT_CALL aowl_host_log(void* ctx, int32_t level, AowlSlice msg) {
    aowlspt_nim_log(ctx, level, (void*)msg.ptr, msg.len);
}

static void AOWLSPT_CALL aowl_host_last_error(void* ctx, AowlSlice* out) {
    void* p = NULL;
    int32_t n = 0;
    aowlspt_nim_last_error(ctx, (void*)&p, (void*)&n);
    if (out) { out->ptr = (const uint8_t*)p; out->len = n; }
}

static AowlStatus AOWLSPT_CALL aowl_host_config_get(void* ctx, AowlSlice key, AowlBuffer* out) {
    void* p = NULL; int32_t n = 0;
    int32_t st = aowlspt_nim_config_get(ctx, (void*)key.ptr, key.len,
                                        (void*)&p, (void*)&n);
    if (out) { out->ptr = (uint8_t*)p; out->len = n; }
    return st;
}
static AowlStatus AOWLSPT_CALL aowl_host_config_set(void* ctx, AowlSlice key, AowlSlice value) {
    return aowlspt_nim_config_set(ctx, (void*)key.ptr, key.len, (void*)value.ptr, value.len);
}

/* The database and routes belong to whichever host has them: the backend
 * implements both, the client host answers `ErrUnsupported`. Which is which is
 * decided by the host, not by this header — every binary defines its own
 * `aowlspt_nim_*`, so a capability is present exactly where it is real. */
static AowlStatus AOWLSPT_CALL aowl_host_db_get(void* ctx, AowlSlice path, AowlBuffer* out) {
    void* p = NULL;
    int32_t n = 0;
    int32_t st = aowlspt_nim_db_get(ctx, (void*)path.ptr, path.len,
                                    (void*)&p, (void*)&n);
    if (out) { out->ptr = (uint8_t*)p; out->len = n; }
    return st;
}
static AowlStatus AOWLSPT_CALL aowl_host_db_patch(void* ctx, AowlSlice path, AowlSlice patch) {
    return aowlspt_nim_db_patch(ctx, (void*)path.ptr, path.len,
                                (void*)patch.ptr, patch.len);
}
static AowlStatus AOWLSPT_CALL aowl_host_route_register(void* ctx, AowlSlice url, int32_t kind,
                                                        AowlRouteFn h, void* user) {
    return aowlspt_nim_route_register(ctx, (void*)url.ptr, url.len, kind,
                                      (void*)h, user);
}

static AowlStatus AOWLSPT_CALL aowl_host_event_subscribe(void* ctx, AowlSlice name,
                                                         AowlCallbackFn h, void* user) {
    return aowlspt_nim_event_subscribe(ctx, (void*)name.ptr, name.len, (void*)h, user);
}
static AowlStatus AOWLSPT_CALL aowl_host_event_emit(void* ctx, AowlSlice name, AowlSlice payload) {
    return aowlspt_nim_event_emit(ctx, (void*)name.ptr, name.len,
                                  (void*)payload.ptr, payload.len);
}

static AowlStatus AOWLSPT_CALL aowl_host_call(void* ctx, AowlSlice target, AowlSlice args,
                                              AowlBuffer* out) {
    void* p = NULL; int32_t n = 0;
    int32_t st = aowlspt_nim_call(ctx, (void*)target.ptr, target.len,
                                  (void*)args.ptr, args.len,
                                  (void*)&p, (void*)&n);
    if (out) { out->ptr = (uint8_t*)p; out->len = n; }
    return st;
}
static AowlStatus AOWLSPT_CALL aowl_host_resolve(void* ctx, AowlSlice typeName, AowlHandle* out) {
    uint64_t h = 0;
    int32_t st = aowlspt_nim_resolve(ctx, (void*)typeName.ptr, typeName.len,
                                     (void*)&h);
    if (out) *out = (AowlHandle)h;
    return st;
}
static void AOWLSPT_CALL aowl_host_handle_release(void* ctx, AowlHandle h) {
    aowlspt_nim_handle_release(ctx, (uint64_t)h);
}

static AowlStatus AOWLSPT_CALL aowl_host_patch(void* ctx, AowlSlice target, int32_t kind,
                                               AowlPatchFn h, void* user) {
    return aowlspt_nim_patch(ctx, (void*)target.ptr, target.len, kind,
                             (void*)h, user);
}

static AowlStatus AOWLSPT_CALL aowl_host_schedule(void* ctx, int32_t delayMs,
                                                  AowlCallbackFn cb, void* user) {
    return aowlspt_nim_schedule(ctx, delayMs, (void*)cb, user);
}
static AowlStatus AOWLSPT_CALL aowl_host_invoke_main(void* ctx, AowlCallbackFn cb, void* user) {
    return aowlspt_nim_invoke_main(ctx, (void*)cb, user);
}
static int64_t AOWLSPT_CALL aowl_host_now_ms(void* ctx) {
    return aowlspt_nim_now_ms(ctx);
}

static AowlStatus AOWLSPT_CALL aowl_host_store_get(void* ctx, AowlSlice key,
                                                   AowlBuffer* out) {
    void* p = NULL; int32_t n = 0;
    int32_t st = aowlspt_nim_store_get(ctx, (void*)key.ptr, key.len,
                                       (void*)&p, (void*)&n);
    if (out) { out->ptr = (uint8_t*)p; out->len = n; }
    return st;
}
static AowlStatus AOWLSPT_CALL aowl_host_store_set(void* ctx, AowlSlice key,
                                                   AowlSlice value) {
    return aowlspt_nim_store_set(ctx, (void*)key.ptr, key.len,
                                 (void*)value.ptr, value.len);
}
static AowlStatus AOWLSPT_CALL aowl_host_store_list(void* ctx, AowlSlice prefix,
                                                    AowlBuffer* out) {
    void* p = NULL; int32_t n = 0;
    int32_t st = aowlspt_nim_store_list(ctx, (void*)prefix.ptr, prefix.len,
                                        (void*)&p, (void*)&n);
    if (out) { out->ptr = (uint8_t*)p; out->len = n; }
    return st;
}

/* Invoking a callback a mod handed us, from nimony, which cannot hold it as a
 * proc.
 *
 * There are two of these because there are two callback shapes, and calling one
 * through the other is not a type error anywhere -- the compiler sees `void*`
 * on both sides. It is a crash: `AowlPatchFn` takes four parameters and
 * `AowlCallbackFn` takes three, so the handler reads its `args` out of the
 * register holding `out` and then writes through it. */
static int32_t aowl_invoke_callback(void* cb, void* user, void* payload, int32_t len) {
    AowlSlice s;
    s.ptr = (const uint8_t*)payload;
    s.len = len;
    return (int32_t)((AowlCallbackFn)cb)(user, s, NULL);
}

/* A route handler. Its own trampoline for the same reason a patch handler has
 * one: `AowlRouteFn` takes five parameters where `AowlCallbackFn` takes three,
 * and calling one through the other is a crash rather than a type error. */
static int32_t aowl_invoke_route(void* cb, void* user,
                                 void* url, int32_t urlLen,
                                 void* body, int32_t bodyLen,
                                 void* session, int32_t sessionLen,
                                 void* outPtrRaw, void* outLenRaw) {
    AowlSlice u; AowlSlice b; AowlSlice s; AowlBuffer out;
    u.ptr = (const uint8_t*)url;     u.len = urlLen;
    b.ptr = (const uint8_t*)body;    b.len = bodyLen;
    s.ptr = (const uint8_t*)session; s.len = sessionLen;
    out.ptr = NULL; out.len = 0;
    int32_t st = (int32_t)((AowlRouteFn)cb)(user, u, b, s, &out);
    *(void**)outPtrRaw = out.ptr;
    *(int32_t*)outLenRaw = out.len;
    return st;
}

/* Releasing a buffer a mod allocated with the host allocator. */
static void aowl_host_release(void* p) { free(p); }

/* The patch invoker that carries arguments and hands back a replacement.
 *
 * `aowl_invoke_patch` below is the older, narrower form: no arguments, and the
 * replacement result is released rather than used. This one is what a patch
 * that wants to read what the method was called with -- or to suppress it --
 * goes through. The out buffer belongs to the caller and must be released with
 * `aowl_host_release`. */
static int32_t aowl_invoke_patch_args(void* cb, void* user,
                                      void* target, int32_t tlen,
                                      void* args, int32_t alen,
                                      void* outPtrRaw, void* outLenRaw) {
    void** outPtr = (void**)outPtrRaw;
    int32_t* outLen = (int32_t*)outLenRaw;
    AowlSlice t;
    AowlSlice a;
    AowlBuffer out;
    t.ptr = (const uint8_t*)target;
    t.len = tlen;
    a.ptr = (const uint8_t*)args;
    a.len = alen;
    out.ptr = NULL;
    out.len = 0;
    int32_t st = (int32_t)((AowlPatchFn)cb)(user, t, a, &out);
    if (outPtr) *outPtr = (void*)out.ptr;
    if (outLen) *outLen = out.len;
    return st;
}

static int32_t aowl_invoke_patch(void* cb, void* user, void* target, int32_t tlen) {
    AowlSlice t;
    AowlSlice a;
    AowlBuffer out;
    t.ptr = (const uint8_t*)target;
    t.len = tlen;
    a.ptr = NULL;
    a.len = 0;
    out.ptr = NULL;
    out.len = 0;
    int32_t st = (int32_t)((AowlPatchFn)cb)(user, t, a, &out);
    /* A prefix patch may hand back a replacement result. This host cannot use
     * one -- it does not suppress the original -- so the buffer is released
     * rather than leaked. */
    if (out.ptr) free(out.ptr);
    return st;
}

/* ==================================================================== *
 * Building the host API
 *
 * One allocation holding the vtable and the info block it points at, so the
 * lifetime is a single free.
 * ==================================================================== */

typedef struct AowlHostBlock {
    AowlHostApi  api;
    AowlHostInfo info;
    char         strings[2048];
    int32_t      used;
} AowlHostBlock;

static AowlSlice aowl_block_str(AowlHostBlock* b, const char* s) {
    AowlSlice out;
    out.ptr = NULL;
    out.len = 0;
    if (!s) return out;
    int32_t n = (int32_t)strlen(s);
    if (b->used + n + 1 > (int32_t)sizeof(b->strings)) return out;
    memcpy(b->strings + b->used, s, (size_t)n + 1);
    out.ptr = (const uint8_t*)(b->strings + b->used);
    out.len = n;
    b->used += n + 1;
    return out;
}

static void* aowl_hostapi_new(void* ctx,
                              int32_t side,
                              const char* hostName,
                              const char* hostVersion,
                              const char* sptVersion,
                              const char* gameVersion,
                              const char* modDir,
                              const char* dataDir) {
    AowlHostBlock* b = (AowlHostBlock*)calloc(1, sizeof(AowlHostBlock));
    if (!b) return NULL;

    b->info.size         = (int32_t)sizeof(AowlHostInfo);
    b->info.abi_version  = AOWLSPT_ABI_VERSION;
    b->info.abi_revision = AOWLSPT_ABI_REVISION;
    b->info.side         = side;
    b->info.encodings    = (1u << AOWLSPT_ENC_JSON) | (1u << AOWLSPT_ENC_RAW);
    b->info.host_name    = aowl_block_str(b, hostName);
    b->info.host_version = aowl_block_str(b, hostVersion);
    b->info.spt_version  = aowl_block_str(b, sptVersion);
    b->info.game_version = aowl_block_str(b, gameVersion);
    b->info.mod_dir      = aowl_block_str(b, modDir);
    b->info.data_dir     = aowl_block_str(b, dataDir);

    b->api.size           = (int32_t)sizeof(AowlHostApi);
    b->api.ctx            = ctx;
    b->api.info           = &b->info;
    b->api.alloc          = aowl_host_alloc;
    b->api.free           = aowl_host_free;
    b->api.log            = aowl_host_log;
    b->api.last_error     = aowl_host_last_error;
    b->api.config_get     = aowl_host_config_get;
    b->api.config_set     = aowl_host_config_set;
    b->api.db_get         = aowl_host_db_get;
    b->api.db_patch       = aowl_host_db_patch;
    b->api.route_register = aowl_host_route_register;
    b->api.event_subscribe= aowl_host_event_subscribe;
    b->api.event_emit     = aowl_host_event_emit;
    b->api.call           = aowl_host_call;
    b->api.resolve        = aowl_host_resolve;
    b->api.handle_release = aowl_host_handle_release;
    b->api.patch          = aowl_host_patch;
    b->api.schedule       = aowl_host_schedule;
    b->api.invoke_main    = aowl_host_invoke_main;
    b->api.now_ms         = aowl_host_now_ms;
    b->api.store_get      = aowl_host_store_get;
    b->api.store_set      = aowl_host_store_set;
    b->api.store_list     = aowl_host_store_list;

    /* `handle_pointer` and `handle_pin` are deliberately left NULL here, and
     * `size` deliberately says so.
     *
     * They only mean anything to a host that has live managed objects, which is
     * the IL2CPP client host and not the server or the backend -- and the
     * functions behind them cannot even be *named* in this header without every
     * binary that includes it having to define them. So they are armed by
     * `aowlspt_live.h`, which only that host includes, and until they are the
     * struct honestly reports the revision-2 size.
     *
     * That is the whole meaning of `size` in rule 4: not "which revision of the
     * header was this compiled against", but "how much of this struct did I
     * fill". A host that reported the full size with two null pointers in it
     * would be telling a mod to call them. */
    b->api.size           = AOWLSPT_HOSTAPI_SIZE_REV2;

    return b;
}

static void aowl_hostapi_free(void* p) { free(p); }

/* The mod is handed `&block->api`, which is the block's first member. Spelled
 * out rather than relying on that coincidence. */
static void* aowl_hostapi_ptr(void* p) { return &((AowlHostBlock*)p)->api; }

static uint32_t aowl_abi_version_expected(void) { return AOWLSPT_ABI_VERSION; }
static int32_t  aowl_hostapi_sizeof(void)       { return (int32_t)sizeof(AowlHostApi); }
static int32_t  aowl_modapi_sizeof(void)        { return (int32_t)sizeof(AowlModApi); }
static int32_t  aowl_modinfo_sizeof(void)       { return (int32_t)sizeof(AowlModInfo); }

/* Writing an owned buffer back to a mod: allocate with the host allocator and
 * copy, since the nimony string it came from will not outlive the call. */
static int32_t aowl_out_copy(void* outPtrRaw, void* outLenRaw, void* src, int32_t len) {
    void** outPtr = (void**)outPtrRaw;
    int32_t* outLen = (int32_t*)outLenRaw;
    if (!outPtr || !outLen) return AOWLSPT_ERR_BAD_ARG;
    *outPtr = NULL;
    *outLen = 0;
    if (len <= 0 || !src) return AOWLSPT_OK;
    void* p = calloc(1, (size_t)len);
    if (!p) return AOWLSPT_ERR_GENERIC;
    memcpy(p, src, (size_t)len);
    *outPtr = p;
    *outLen = len;
    return AOWLSPT_OK;
}

/* ==================================================================== *
 * Argument arrays for il2cpp_runtime_invoke
 *
 * IL2CPP takes `void** params` with the same convention Mono uses: for a value
 * type the element points at the raw value, for a reference type the element
 * *is* the object pointer. Getting that backwards does not fail -- it reads an
 * object header as an integer -- so the two cases are separate calls here
 * rather than one that guesses.
 * ==================================================================== */

typedef struct AowlArgs {
    void*   slots[8];
    int64_t values[8];   /* storage for value-type arguments */
    int32_t count;
} AowlArgs;

static void* aowl_args_new(int32_t n) {
    if (n < 0 || n > 8) return NULL;
    AowlArgs* a = (AowlArgs*)calloc(1, sizeof(AowlArgs));
    if (a) a->count = n;
    return a;
}
static void aowl_args_free(void* p) { free(p); }
static void* aowl_args_ptr(void* p) {
    AowlArgs* a = (AowlArgs*)p;
    return (a && a->count > 0) ? (void*)a->slots : NULL;
}

/* Reference types: the slot is the pointer itself. */
static void aowl_args_set_ref(void* p, int32_t i, void* v) {
    AowlArgs* a = (AowlArgs*)p;
    if (!a || i < 0 || i >= a->count) return;
    a->slots[i] = v;
}
/* Value types: the slot points at storage owned by this block, which is why
 * the block has to outlive the invoke. */
static void aowl_args_set_i32(void* p, int32_t i, int32_t v) {
    AowlArgs* a = (AowlArgs*)p;
    if (!a || i < 0 || i >= a->count) return;
    *(int32_t*)&a->values[i] = v;
    a->slots[i] = &a->values[i];
}
static void aowl_args_set_i64(void* p, int32_t i, int64_t v) {
    AowlArgs* a = (AowlArgs*)p;
    if (!a || i < 0 || i >= a->count) return;
    a->values[i] = v;
    a->slots[i] = &a->values[i];
}
static void aowl_args_set_f32(void* p, int32_t i, double v) {
    AowlArgs* a = (AowlArgs*)p;
    if (!a || i < 0 || i >= a->count) return;
    *(float*)&a->values[i] = (float)v;
    a->slots[i] = &a->values[i];
}
static void aowl_args_set_f64(void* p, int32_t i, double v) {
    AowlArgs* a = (AowlArgs*)p;
    if (!a || i < 0 || i >= a->count) return;
    *(double*)&a->values[i] = v;
    a->slots[i] = &a->values[i];
}

/* Reading a boxed return value out of the pointer il2cpp_object_unbox gives. */
/* Whether a pointer lands in an executable page.
 *
 * This is the guard on every value read out of a runtime struct by assumed
 * offset. If the assumption is wrong on a given build, the value will not be
 * code — and that is cheap to check here and catastrophic to skip, since the
 * next thing done with it is either calling it or patching it. */
static int32_t aowl_is_code_pointer(void* p) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    return (mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                           PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;
}

/* Whether `size` bytes starting at `p` are safe to read -- committed, not a
 * guard page, and carrying a readable protection. `aowl_read_ptr` dereferences
 * a pointer the runtime handed back, and on a real client `findMethod` can
 * return a non-NULL value that is not a readable `MethodInfo` (the first
 * per-frame candidate `EFT.MainApplication::Update` is unverified on post-1.0);
 * a raw `memcpy` from it faults and takes the game down. This is the same
 * VirtualQuery guard `aowl_is_code_pointer` uses, for reads rather than code. */
static int32_t aowl_is_readable(void* p, int32_t size) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || size <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY))) return 0;
    /* the whole range has to lie inside this one committed region */
    {
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)p + (uintptr_t)size;
        if (need < (uintptr_t)p) return 0;   /* overflow */
        return need <= end ? 1 : 0;
    }
}

/* Reading a pointer field out of a runtime struct by byte offset. Used for
 * `MethodInfo.methodPointer`, which IL2CPP exposes no accessor for. */
static void* aowl_read_ptr(void* p, int32_t off) {
    if (!p) return NULL;
    void* v = NULL;
    memcpy(&v, (const char*)p + off, sizeof(void*));
    return v;
}

static int32_t aowl_read_i32(void* p) { return p ? *(int32_t*)p : 0; }
static int64_t aowl_read_i64(void* p) { return p ? *(int64_t*)p : 0; }
/* The saved argument registers, in the order the thunk writes them. `ret` is
 * where the dispatcher leaves a return value when it suppresses the original. */
typedef struct AowlRegs {
    uint64_t rcx, rdx, r8, r9;   /* 0x00 0x08 0x10 0x18 */
    double   x0, x1, x2, x3;     /* 0x20 0x28 0x30 0x38 */
    uint64_t ret;                /* 0x40 -- a replacement return value        */
    double   retf;               /* 0x48 -- XMM0 as the original left it, on
                                    the postfix path only                     */
} AowlRegs;

/* Returns 0 to run the original, 1 to suppress it. */
extern int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs);
/* Returns 0 to keep the original's return value, 1 to use `ret`. */
extern int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs);



/* Reading the saved frame from the host, which cannot dereference a struct it
 * has no declaration for. Index 0-3 is argument *position*, and a position is
 * either an integer register or an XMM register -- on this ABI the position
 * picks the register file, rather than each file having its own counter. */
static uint64_t aowl_regs_int(void* p, int32_t i) {
    AowlRegs* r = (AowlRegs*)p;
    if (!r) return 0;
    switch (i) {
        case 0: return r->rcx;
        case 1: return r->rdx;
        case 2: return r->r8;
        case 3: return r->r9;
        default: return 0;
    }
}
static double aowl_regs_flt(void* p, int32_t i) {
    AowlRegs* r = (AowlRegs*)p;
    if (!r) return 0.0;
    switch (i) {
        case 0: return r->x0;
        case 1: return r->x1;
        case 2: return r->x2;
        case 3: return r->x3;
        default: return 0.0;
    }
}
/* A `float` argument, read as a float.
 *
 * The thunk saves each XMM register with `movsd` -- the low 64 bits -- because
 * it does not know, and cannot know, what type the argument is: that lives in
 * the method's declared signature, which only the host has. A `System.Single`
 * occupies the low **32** of those bits and the rest is whatever the register
 * happened to hold, so reading the slot as a `double` produces a number with no
 * relationship to the argument. Passing 12.5f reported 0.000000.
 *
 * So there are two readers, and the caller picks by declared type: this one for
 * `System.Single`, `aowl_regs_flt` for `System.Double`. */
static double aowl_regs_f32(void* p, int32_t i) {
    AowlRegs* r = (AowlRegs*)p;
    float f = 0.0f;
    if (!r || i < 0 || i > 3) return 0.0;
    memcpy(&f, (&r->x0) + i, sizeof(f));
    return (double)f;
}

static void aowl_regs_set_ret_int(void* p, uint64_t v) {
    if (p) ((AowlRegs*)p)->ret = v;
}
static void aowl_regs_set_ret_f32(void* p, double v) {
    if (!p) return;
    float f = (float)v;
    uint64_t bits = 0;
    memcpy(&bits, &f, sizeof(f));
    ((AowlRegs*)p)->ret = bits;
}
static void aowl_regs_set_ret_f64(void* p, double v) {
    if (!p) return;
    uint64_t bits = 0;
    memcpy(&bits, &v, sizeof(v));
    ((AowlRegs*)p)->ret = bits;
}
static int32_t aowl_regs_sizeof(void) { return (int32_t)sizeof(AowlRegs); }

/* What the original returned, on the postfix path.
 *
 * Two readers for the same reason there are two readers for a float *argument*:
 * an integer or reference return is in RAX and a floating-point one is in XMM0,
 * the thunk saves both because it cannot know which, and only the method's
 * declared return type -- which the host has and the assembly does not -- says
 * which of the two is the value. Reading the wrong one produces a number rather
 * than an error, which is precisely the failure this pair exists to avoid. */
static uint64_t aowl_regs_ret_int(void* p) {
    return p ? ((AowlRegs*)p)->ret : 0;
}
static double aowl_regs_ret_f64(void* p) {
    return p ? ((AowlRegs*)p)->retf : 0.0;
}
/* A `System.Single` return occupies the low 32 bits of XMM0 and the rest is
 * whatever the register held; read as a double it is a number unrelated to the
 * result. Same trap as `aowl_regs_f32`, same fix. */
static double aowl_regs_ret_f32(void* p) {
    float f = 0.0f;
    if (!p) return 0.0;
    memcpy(&f, &((AowlRegs*)p)->retf, sizeof(f));
    return (double)f;
}

/* A 16-byte scratch cell.
 *
 * A field is read out of an object into raw memory rather than into a boxed
 * object -- `il2cpp_field_get_value` writes the value itself, not a reference
 * to one -- so something has to own the bytes for the length of the call.
 * Sixteen because that covers every primitive and a pointer with room to spare;
 * a value type larger than that is not something this path can read anyway, and
 * refusing it is better than writing past the end. */
static void* aowl_cell_new(void)  { return calloc(1, 16); }
static void  aowl_cell_free(void* p) { free(p); }
static void  aowl_cell_set_i32(void* p, int32_t v) { if (p) *(int32_t*)p = v; }
static void  aowl_cell_set_i64(void* p, int64_t v) { if (p) *(int64_t*)p = v; }
static void  aowl_cell_set_f32(void* p, double v)  { if (p) *(float*)p = (float)v; }
static void  aowl_cell_set_f64(void* p, double v)  { if (p) *(double*)p = v; }
static void  aowl_cell_set_ptr(void* p, void* v)   { if (p) *(void**)p = v; }
static void* aowl_cell_get_ptr(void* p)            { return p ? *(void**)p : NULL; }

static double  aowl_read_f32(void* p) { return p ? (double)*(float*)p : 0.0; }
static double  aowl_read_f64(void* p) { return p ? *(double*)p : 0.0; }

/* ------------------------------------------------------------------ *
 * Small Win32 services the host needs and nimony's stdlib does not have
 * ------------------------------------------------------------------ */

/* Where this DLL is on disk. The host reads its mods and writes its log
 * relative to itself, so that an install can be moved without reconfiguring
 * anything. Resolved from the address of a function in this module rather than
 * from a stored HINSTANCE, since a constructor is not handed one. */
/* An anchor whose address is inside whichever binary included this header.
 * `aowl_sys_module_path` needs *some* address in its own module; taking one
 * from a function that lives here means the answer is right whether the
 * includer is an exe or a DLL. */
static void aowl_sys_anchor(void) { }

static int32_t aowl_sys_module_path(char* buf, int32_t cap) {
    HMODULE self = NULL;
    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCSTR)(void*)&aowl_sys_anchor, &self)) {
        return 0;
    }
    return (int32_t)GetModuleFileNameA(self, buf, (DWORD)cap);
}

static uint64_t aowl_sys_now_ms(void) {
    return (uint64_t)GetTickCount64();
}

static void aowl_sys_sleep(int32_t ms) {
    Sleep((DWORD)ms);
}

static uint32_t aowl_sys_thread_id(void) {
    return (uint32_t)GetCurrentThreadId();
}

/* Loading a mod. Kept here beside the rest of the Win32 surface rather than
 * imported separately in nimony, so there is one place that knows how a mod
 * becomes a module. */
static void* aowl_sys_load_library(const char* path) {
    return (void*)LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
}
static void aowl_sys_free_library(void* h) {
    if (h) FreeLibrary((HMODULE)h);
}
static void* aowl_sys_get_proc(void* h, const char* name) {
    if (!h) return NULL;
    return (void*)GetProcAddress((HMODULE)h, name);
}
static uint32_t aowl_sys_last_error(void) {
    return (uint32_t)GetLastError();
}


#endif /* AOWLSPT_SHIM_H */
