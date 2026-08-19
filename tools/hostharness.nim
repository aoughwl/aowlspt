## hostharness -- run the IL2CPP client host without launching Tarkov.
##
##     hostharness HOST-DIR [--seconds N]     load the host into this process
##     hostharness HOST-DIR --inject EXE      start EXE suspended and inject it
##     hostharness --sleep N                  be an injection target for N seconds
##
## `HOST-DIR` holds `aowlspt-host-il2cpp.dll` and a `mods/` directory.
##
## The first form loads the host the way any process would -- a plain
## `LoadLibrary`, which fires the constructor that starts the host thread. The
## second exercises the code the real launcher uses (`abi/aowlspt_inject.h`):
## `CreateProcess` suspended, `VirtualAllocEx` + `WriteProcessMemory`,
## `CreateRemoteThread` at `LoadLibraryA`, resume. Point it at this same
## executable with `--sleep` and the whole path is tested without a game.
##
## Between them these prove everything except the runtime itself:
##
##   the constructor fires and the host thread starts
##   the host finds its own directory and opens its log
##   it discovers mods, checks their ABI version, and calls describe/init
##   `AowlHostApi` survives the boundary: the mod logs through it
##   `on_load` and `on_update` run
##
## What they cannot prove is `resolve` and `call`, because there is no IL2CPP
## runtime in either process -- and that is the point of running them. The host
## is supposed to notice, say so, and keep going rather than take the process
## down. A run that ends in "the runtime did not come up" is the expected
## result here, not a failure.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]

{.emit: """
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static void* g_host = NULL;   /* the host DLL, kept for GetProcAddress */
static void* aowl_harness_load(const char* p) {
  g_host = (void*)LoadLibraryExA(p, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
  return g_host;
}
static uint32_t aowl_harness_error(void) { return (uint32_t)GetLastError(); }
static void aowl_harness_sleep(int32_t ms) { Sleep((DWORD)ms); }

/* The clock, for the one row of the frame bench that has to be timed from
   *outside* the host: what a `call` costs the caller, ABI crossing and reply
   string included. The host cannot time that one, because half of it is the
   caller's own copy of the reply out of the buffer the host allocated. */
static int64_t aowl_harness_qpc(void) {
  LARGE_INTEGER v; QueryPerformanceCounter(&v); return (int64_t)v.QuadPart;
}
static int64_t aowl_harness_qpf(void) {
  LARGE_INTEGER v; QueryPerformanceFrequency(&v); return (int64_t)v.QuadPart;
}

/* A stand-in IL2CPP runtime, for exercising the host paths the real one
   cannot reach outside the game. Loaded before the host and started after it,
   so the host's "wait for the runtime" poll is exercised rather than skipped. */
static void* g_mockRt = NULL;
static int32_t aowl_rt_load(const char* p) {
  g_mockRt = (void*)LoadLibraryExA(p, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
  return g_mockRt != NULL;
}
static int32_t aowl_rt_init(void) {
  if (!g_mockRt) return 0;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "il2cpp_init");
  if (!f) return 0;
  return ((void*(*)(const char*))f)("mock") != NULL;
}
static int32_t aowl_rt_tick_count(void) {
  if (!g_mockRt) return -1;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_tick_count");
  if (!f) return -1;
  return ((int32_t(*)(void))f)();
}
/* The thread the mock's per-frame method runs on, and how many frames it has
   run. This is the harness's half of the main-thread proof: the host says
   which thread ran a callback that was queued from another one, and only the
   mock knows which thread its frame loop is. Equal is the assertion. */
static uint32_t aowl_rt_frame_thread(void) {
  if (!g_mockRt) return 0;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_frame_thread_id");
  if (!f) return 0;
  return ((uint32_t(*)(void))f)();
}
static int32_t aowl_rt_frame_count(void) {
  if (!g_mockRt) return -1;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_frame_count");
  if (!f) return -1;
  return ((int32_t(*)(void))f)();
}
/* How many times the runtime's write barrier was actually called. The mod can
   only report that its binding resolved the entry; whether the store went
   through the collector or around it is knowable here and nowhere else. A
   stand-in without the export leaves the mod silently on the plain store. */
/* How many times the two stack-argument stand-ins actually ran. A payload
   assertion is only about something if the method behind it ran, and a prefix
   that reads the arguments must leave the original running -- so this is the
   half of the argument checks that the payload itself cannot state. -1 means
   the runtime is not the stand-in and has no such export, which is the same
   answer every other counter here gives. */
static int32_t aowl_rt_step_calls(void) {
  if (!g_mockRt) return -1;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_step_calls");
  if (!f) return -1;
  return ((int32_t(*)(void))f)();
}
static int32_t aowl_rt_quint_calls(void) {
  if (!g_mockRt) return -1;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_quint_calls");
  if (!f) return -1;
  return ((int32_t(*)(void))f)();
}
static int32_t aowl_rt_wbarrier_calls(void) {
  if (!g_mockRt) return -1;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_wbarrier_calls");
  if (!f) return -1;
  return ((int32_t(*)(void))f)();
}
/* How many times the runtime was asked for a class's static data block, and
   what its own static field holds now. The first says the static binding
   actually went to the static block; the second says the write landed there
   rather than into an object at the same offset. Neither is answerable from
   the mod's side, which is the whole reason they are here: a static field and
   an instance field can share an offset, so "the value read back" is exactly
   as true of a binding that read the wrong storage. */
static int32_t aowl_rt_static_data_calls(void) {
  if (!g_mockRt) return -1;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_static_field_data_calls");
  if (!f) return -1;
  return ((int32_t(*)(void))f)();
}
static int32_t aowl_rt_spawn_count(void) {
  if (!g_mockRt) return -1;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_player_spawn_count");
  if (!f) return -1;
  return ((int32_t(*)(void))f)();
}
/* How many times anything asked an object for its type. `alive()` is a
   GetType call, so this is the runtime's side of "alive() answered honestly"
   -- without it, a mod that never made the call and a runtime that never
   implemented it produce the same log line. */
static int32_t aowl_rt_gettype_calls(void) {
  if (!g_mockRt) return -1;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_gettype_calls");
  if (!f) return -1;
  return ((int32_t(*)(void))f)();
}
""".}
{.emit: """#include "aowlspt_inject.h" """.}

## ---------------------------------------------------------------------------
## Churn: the same host, driven hard, watched over time
## ---------------------------------------------------------------------------
##
## Everything above proves the host can *do* a thing once. This proves it can
## stop doing it. The two are not the same claim and only the second one finds
## the failure that matters in a raid: a table that grows by one per cycle is a
## game that dies twenty minutes in, and a slot pool that never refills is a
## mod whose seventeenth patch silently does not install.
##
## The whole engine is C, deliberately. The churn loops call into the host
## thousands of times a second and take callbacks back from a detour thunk
## running on the mock's frame thread; a nimony closure on that path would be
## measuring its own allocator rather than the host's.
##
## Why the host's own exported `aowlspt_nim_*` surface rather than a mod: a mod
## can only be driven through `on_update`, which is the host's own tick, so a
## churn test written as a mod would be rate-limited by the thing it is testing
## and could not unload itself. Those exports are exactly what `aowlspt_shim.h`
## calls to implement `AowlHostApi`, so driving them is driving what a mod
## drives, one function call earlier.
{.emit: """
#define PSAPI_VERSION 2
#include <psapi.h>
""".}
{.emit: """#include "aowlspt_abi.h" """.}
{.emit: """
/* ------------------------------------------------------------------ *
 * The host's own entry points, by name.
 * ------------------------------------------------------------------ */
typedef int32_t (*FnCall)(void*, void*, int32_t, void*, int32_t, void*, void*);
typedef int32_t (*FnResolve)(void*, void*, int32_t, void*);
typedef void    (*FnRelease)(void*, uint64_t);
typedef int32_t (*FnPin)(void*, uint64_t, void*);
typedef int32_t (*FnPointer)(void*, uint64_t, void*);
typedef int32_t (*FnPatch)(void*, void*, int32_t, int32_t, void*, void*);
typedef int32_t (*FnSub)(void*, void*, int32_t, void*, void*);
typedef int32_t (*FnEmit)(void*, void*, int32_t, void*, int32_t);
typedef int32_t (*FnInvokeMain)(void*, void*, void*);
typedef int32_t (*FnSchedule)(void*, int32_t, void*, void*);

static FnCall       h_call       = NULL;
static FnResolve    h_resolve    = NULL;
static FnRelease    h_release    = NULL;
static FnPin        h_pin        = NULL;
static FnPointer    h_pointer    = NULL;
static FnPatch      h_patch      = NULL;
static FnPatch      h_patchTyped = NULL;
static FnSub        h_sub        = NULL;
static FnEmit       h_emit       = NULL;
static FnInvokeMain h_invokeMain = NULL;
static FnSchedule   h_schedule   = NULL;

/* The context pointer the harness registers under.
 *
 * A host context *is* a mod index, and the harness is not a mod. A number no
 * mod table will ever reach means `dropModRegistrations` never matches it, so
 * the harness's own subscriptions survive the mod churn they are there to
 * watch -- which is the point: a subscription that vanished with the mod would
 * hide the very growth being measured. */
#define AOWL_CHURN_CTX ((void*)(uintptr_t)0x7FFF)

/* And a second one to emit from.
 *
 * `hostEventEmit` skips the emitter's own subscribers -- a mod should not hear
 * its own event -- and the harness subscribes and emits, so emitting under the
 * same context delivers to nobody and the fan-out measures zero. Two numbers,
 * both outside any mod table. */
#define AOWL_CHURN_EMIT_CTX ((void*)(uintptr_t)0x7FFE)

static int32_t aowl_churn_bind(void) {
    if (!g_host) return 0;
    h_call       = (FnCall)      GetProcAddress((HMODULE)g_host, "aowlspt_nim_call");
    h_resolve    = (FnResolve)   GetProcAddress((HMODULE)g_host, "aowlspt_nim_resolve");
    h_release    = (FnRelease)   GetProcAddress((HMODULE)g_host, "aowlspt_nim_handle_release");
    h_pin        = (FnPin)       GetProcAddress((HMODULE)g_host, "aowlspt_nim_handle_pin");
    h_pointer    = (FnPointer)   GetProcAddress((HMODULE)g_host, "aowlspt_nim_handle_pointer");
    h_patch      = (FnPatch)     GetProcAddress((HMODULE)g_host, "aowlspt_nim_patch");
    h_patchTyped = (FnPatch)     GetProcAddress((HMODULE)g_host, "aowlspt_nim_patch_typed");
    h_sub        = (FnSub)       GetProcAddress((HMODULE)g_host, "aowlspt_nim_event_subscribe");
    h_emit       = (FnEmit)      GetProcAddress((HMODULE)g_host, "aowlspt_nim_event_emit");
    h_invokeMain = (FnInvokeMain)GetProcAddress((HMODULE)g_host, "aowlspt_nim_invoke_main");
    h_schedule   = (FnSchedule)  GetProcAddress((HMODULE)g_host, "aowlspt_nim_schedule");
    return (h_call && h_resolve && h_release && h_pin && h_pointer &&
            h_patch && h_patchTyped && h_sub && h_emit && h_invokeMain &&
            h_schedule) ? 1 : 0;
}

/* ------------------------------------------------------------------ *
 * One host call, with the reply parked where nimony can read it.
 * ------------------------------------------------------------------ */
static char    g_reply[8192];
static int32_t g_replyLen = 0;

static int32_t aowl_churn_call(const char* target, const char* args) {
    void* out = NULL;
    int32_t len = 0;
    g_reply[0] = 0;
    g_replyLen = 0;
    if (!h_call) return -1;
    int32_t st = h_call(AOWL_CHURN_CTX, (void*)target, (int32_t)strlen(target),
                        (void*)args, (int32_t)strlen(args), &out, &len);
    if (out) {
        if (len > (int32_t)sizeof(g_reply) - 1) len = (int32_t)sizeof(g_reply) - 1;
        if (len > 0) memcpy(g_reply, out, (size_t)len);
        g_reply[len < 0 ? 0 : len] = 0;
        g_replyLen = len < 0 ? 0 : len;
        /* The host allocated this with its own allocator and the ABI says the
         * receiver frees it -- which is what a mod does through
         * `aowl_host_release`. Doing the same here means the churn run also
         * measures whether that round trip gives the memory back. */
        free(out);
    }
    return st;
}
static int32_t aowl_churn_reply_len(void) { return g_replyLen; }
static uint8_t aowl_churn_reply_at(int32_t i) {
    return (i >= 0 && i < g_replyLen) ? (uint8_t)g_reply[i] : (uint8_t)0;
}

/* The first run of digits after `key`, or -1. Enough for a reply this host
 * built itself; nothing here parses a document from anywhere else. */
static int64_t aowl_json_num(const char* doc, const char* key) {
    if (!doc || !key) return -1;
    const char* at = strstr(doc, key);
    if (!at) return -1;
    at += strlen(key);
    while (*at == ' ' || *at == ':' || *at == '"') at++;
    int neg = 0;
    if (*at == '-') { neg = 1; at++; }
    if (*at < '0' || *at > '9') return -1;
    int64_t v = 0;
    while (*at >= '0' && *at <= '9') { v = v * 10 + (*at - '0'); at++; }
    return neg ? -v : v;
}

/* ------------------------------------------------------------------ *
 * What the process itself is holding.
 * ------------------------------------------------------------------ */
static int64_t aowl_churn_rss_kb(void) {
    PROCESS_MEMORY_COUNTERS pmc;
    memset(&pmc, 0, sizeof(pmc));
    pmc.cb = sizeof(pmc);
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) return -1;
    return (int64_t)(pmc.WorkingSetSize / 1024);
}

/* Commit charge, which is the honest one.
 *
 * The working set is what Windows currently has resident and it moves for
 * reasons that have nothing to do with this process -- a trim under memory
 * pressure takes it down while everything is still allocated, and touching a
 * page that was already committed takes it up. Private bytes only move when
 * something is actually committed or released, so a leak shows here and noise
 * mostly does not. Both are reported: the working set is what a player watches
 * in Task Manager, and this is what settles the argument. */
static int64_t aowl_churn_private_kb(void) {
    PROCESS_MEMORY_COUNTERS_EX pmc;
    memset(&pmc, 0, sizeof(pmc));
    pmc.cb = sizeof(pmc);
    if (!GetProcessMemoryInfo(GetCurrentProcess(),
                              (PROCESS_MEMORY_COUNTERS*)&pmc, sizeof(pmc)))
        return -1;
    return (int64_t)(pmc.PrivateUsage / 1024);
}
static int32_t aowl_churn_proc_handles(void) {
    DWORD n = 0;
    if (!GetProcessHandleCount(GetCurrentProcess(), &n)) return -1;
    return (int32_t)n;
}

/* ------------------------------------------------------------------ *
 * The callbacks the host will hold pointers to.
 * ------------------------------------------------------------------ */
static volatile LONG g_jsonFires   = 0;
static volatile LONG g_typedFires  = 0;
static volatile LONG g_eventFires  = 0;
static volatile LONG g_mainFires   = 0;
static volatile LONG g_nestCalls   = 0;
static volatile LONG g_nestEnabled = 0;
static volatile LONG g_nestDepth   = 0;
static char g_hurtSpec[64];

/* The last JSON payload a hook was handed, kept verbatim.
 *
 * This is the only place in the tree where the *mod's* view of a firing can be
 * asserted on. Everything else reads the host's own reply to a `call`, or a
 * line a mod printed about a payload it had already decided about -- neither of
 * which can show that an argument the method declares is missing from the
 * string, because a payload that omits it looks exactly like one whose value
 * happened to be empty. That is the defect this exists to make visible: the
 * bytes are compared, not a summary of them. */
static char    g_payload[8192];
static int32_t g_payloadLen = 0;

static int32_t AOWLSPT_CALL aowl_churn_patch_cb(void* user, AowlSlice target,
                                                AowlSlice args, AowlBuffer* out) {
    (void)user; (void)target;
    if (args.ptr && args.len > 0) {
        int32_t n = args.len;
        if (n > (int32_t)sizeof(g_payload) - 1) n = (int32_t)sizeof(g_payload) - 1;
        memcpy(g_payload, args.ptr, (size_t)n);
        g_payload[n] = 0;
        g_payloadLen = n;
    }
    if (out) { out->ptr = NULL; out->len = 0; }
    InterlockedIncrement(&g_jsonFires);
    return 0;
}

static void aowl_churn_payload_clear(void) { g_payload[0] = 0; g_payloadLen = 0; }
static int32_t aowl_churn_payload_len(void) { return g_payloadLen; }
static uint8_t aowl_churn_payload_at(int32_t i) {
    return (i >= 0 && i < g_payloadLen) ? (uint8_t)g_payload[i] : (uint8_t)0;
}

/* A typed handler that, when asked, calls something the host has also patched.
 *
 * That is the only way to reach the frame pool's second slot: `typedFire`
 * indexes it by `gPatchDepth`, so a nested firing is what proves the pool is a
 * pool rather than one frame with a counter. `typedTooDeep` in `patch_stats`
 * is the number this is watched against -- non-zero there means a mod stopped
 * being called, which is the kind of silence a churn run exists to notice. */
static int32_t AOWLSPT_CALL aowl_churn_typed_cb(void* user, const void* frame) {
    (void)user; (void)frame;
    InterlockedIncrement(&g_typedFires);
    /* Mode 1 nests exactly one level: this handler calls a method the host has
     * also patched, so the inner firing takes the frame pool's second slot.
     * That is what proves the pool is a pool rather than one frame and a
     * counter -- an inner handler reading the outer firing's registers would
     * see a plausible set of arguments rather than an error.
     *
     * Mode 2 takes the brake off and lets it recur until the pool runs out,
     * which is the other half of the same claim: past the pool the host lets
     * the original run and counts it in `typedTooDeep`, and neither the frames
     * nor the handle table may be left holding anything afterwards.
     *
     * The same function is the handler for every typed patch here, so without
     * mode 1's guard the *inner* firing nests too and the pool is exhausted on
     * the first call. */
    if (g_nestEnabled && h_call && (g_nestEnabled == 2 || g_nestDepth == 0)) {
        void* out = NULL; int32_t len = 0;
        InterlockedIncrement(&g_nestDepth);
        InterlockedIncrement(&g_nestCalls);
        h_call(AOWL_CHURN_CTX, (void*)g_hurtSpec, (int32_t)strlen(g_hurtSpec),
               (void*)"[1.0,0]", 7, &out, &len);
        if (out) free(out);
        InterlockedDecrement(&g_nestDepth);
    }
    return 0;
}

static int32_t AOWLSPT_CALL aowl_churn_event_cb(void* user, AowlSlice payload,
                                                AowlBuffer* out) {
    (void)user; (void)payload;
    if (out) { out->ptr = NULL; out->len = 0; }
    InterlockedIncrement(&g_eventFires);
    return 0;
}

static int32_t AOWLSPT_CALL aowl_churn_main_cb(void* user, AowlSlice payload,
                                               AowlBuffer* out) {
    (void)user; (void)payload;
    if (out) { out->ptr = NULL; out->len = 0; }
    InterlockedIncrement(&g_mainFires);
    return 0;
}

/* The mod manager's `listed` reply, caught as an ordinary subscriber.
 *
 * The harness needs a mod's *index* -- a context pointer is one -- and the only
 * thing that publishes the whole table in order is this reply. Catching it here
 * rather than adding a host entry point keeps the churn run driving the same
 * protocol the manager drives. */
static char g_listed[8192];
static volatile LONG g_listedSeq = 0;
static int32_t AOWLSPT_CALL aowl_churn_listed_cb(void* user, AowlSlice payload,
                                                 AowlBuffer* out) {
    (void)user;
    if (out) { out->ptr = NULL; out->len = 0; }
    int32_t n = payload.len;
    if (n < 0) n = 0;
    if (n > (int32_t)sizeof(g_listed) - 1) n = (int32_t)sizeof(g_listed) - 1;
    if (n > 0 && payload.ptr) memcpy(g_listed, payload.ptr, (size_t)n);
    g_listed[n] = 0;
    InterlockedIncrement(&g_listedSeq);
    return 0;
}
static int32_t aowl_churn_listed_seq(void) { return (int32_t)g_listedSeq; }
/* How long the manager's `listed` reply was. A reply that grows with the
 * number of toggles rather than with the number of mods is a table growing
 * without bound inside a message, and it is invisible from any host counter. */
static int32_t aowl_churn_listed_len(void) { return (int32_t)strlen(g_listed); }

/* Where `guid` sits in the listed table, which is its context index -- the
 * loader keeps dead slots, so position and index are the same number.
 *
 * The *live* row, and that is the whole subtlety: a mod that has been unloaded
 * and loaded again appears once per cycle, every earlier row still carrying its
 * guid and `"live":false`. Taking the first match hands back the index of a
 * corpse, and a patch registered against a dead mod's context is a patch no
 * unload will ever remove -- which is exactly the leak this run is looking for,
 * arriving from the test rather than the host. */
static int32_t aowl_churn_listed_index(const char* guid) {
    const char* p = g_listed;
    int32_t idx = 0;
    char needle[160];
    snprintf(needle, sizeof(needle) - 1, "\"guid\":\"%s\"", guid);
    needle[sizeof(needle) - 1] = 0;
    while ((p = strstr(p, "\"guid\":\"")) != NULL) {
        if (strncmp(p, needle, strlen(needle)) == 0) {
            const char* end = strstr(p + 8, "\"guid\":\"");
            const char* live = strstr(p + 8, "\"live\":true");
            if (live && (!end || live < end)) return idx;
        }
        idx++;
        p += 8;
    }
    return -1;
}

static int32_t aowl_churn_subscribe(void) {
    if (!h_sub) return 0;
    int32_t a = h_sub(AOWL_CHURN_CTX, (void*)"aowl.churn.ping", 15,
                      (void*)aowl_churn_event_cb, NULL);
    int32_t b = h_sub(AOWL_CHURN_CTX, (void*)"aowlspt.host.mods.listed", 24,
                      (void*)aowl_churn_listed_cb, NULL);
    return (a == 0 && b == 0) ? 1 : 0;
}

/* ------------------------------------------------------------------ *
 * The original bytes of a detoured method.
 * ------------------------------------------------------------------ */
static uint8_t g_origBytes[32];
static void*   g_origAt = NULL;

static void* aowl_churn_method_pointer(const char* nsType, const char* method) {
    if (!g_mockRt) return NULL;
    void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_method_pointer");
    if (!f) return NULL;
    return ((void*(*)(const char*, const char*))f)(nsType, method);
}
static int32_t aowl_churn_snapshot(const char* nsType, const char* method) {
    g_origAt = aowl_churn_method_pointer(nsType, method);
    if (!g_origAt) return 0;
    memcpy(g_origBytes, g_origAt, sizeof(g_origBytes));
    /* A snapshot taken while the method is already detoured would compare a
     * jump against itself for the rest of the run. */
    if (g_origBytes[0] == 0xFF && g_origBytes[1] == 0x25) return 0;
    return 1;
}
static int32_t aowl_churn_bytes_restored(void) {
    if (!g_origAt) return -1;
    return memcmp(g_origAt, g_origBytes, sizeof(g_origBytes)) == 0 ? 1 : 0;
}

/* ------------------------------------------------------------------ *
 * The churn itself.
 * ------------------------------------------------------------------ */
static int32_t g_resolveBad  = 0;
static int32_t g_pinBad      = 0;
static int32_t g_patchBad    = 0;
static int32_t g_lastPatchRc = 0;

/* resolve + release, the pair a mod makes every time it looks a type up. */
static void aowl_churn_handles(int32_t n) {
    int32_t i;
    for (i = 0; i < n; i++) {
        uint64_t h = 0;
        if (h_resolve(AOWL_CHURN_CTX, (void*)"EFT.Player", 10, &h) != 0 || h == 0) {
            g_resolveBad++;
            continue;
        }
        h_release(AOWL_CHURN_CTX, h);
    }
}

/* A live object, its address, a pin over it, and all of it given back.
 *
 * Two object handles and one pinned handle per turn: the world, the player it
 * owns, and a pin over the player. The pinned one is what a mod is told to use
 * when it must keep an address across frames, so it is the one whose slot has
 * to come back -- a pin that leaks its slot also leaves the collector working
 * around an address for the rest of the session. */
static void aowl_churn_pins(int32_t n) {
    int32_t i;
    for (i = 0; i < n; i++) {
        char spec[64];
        if (aowl_churn_call("EFT.GameWorld::get_Instance", "[]") != 0) {
            g_pinBad++;
            continue;
        }
        int64_t w = aowl_json_num(g_reply, "\"handle\"");
        if (w <= 0) { g_pinBad++; continue; }
        snprintf(spec, sizeof(spec) - 1, "#%d::get_MainPlayer", (int)w);
        spec[sizeof(spec) - 1] = 0;
        if (aowl_churn_call(spec, "[]") != 0) {
            g_pinBad++;
            h_release(AOWL_CHURN_CTX, (uint64_t)w);
            continue;
        }
        int64_t h = aowl_json_num(g_reply, "\"handle\"");
        if (h <= 0) {
            g_pinBad++;
            h_release(AOWL_CHURN_CTX, (uint64_t)w);
            continue;
        }
        uint64_t pinned = 0;
        uint64_t addr = 0;
        if (h_pointer(AOWL_CHURN_CTX, (uint64_t)h, &addr) != 0 || addr == 0)
            g_pinBad++;
        if (h_pin(AOWL_CHURN_CTX, (uint64_t)h, &pinned) == 0 && pinned != 0)
            h_release(AOWL_CHURN_CTX, pinned);
        else
            g_pinBad++;
        h_release(AOWL_CHURN_CTX, (uint64_t)h);
        h_release(AOWL_CHURN_CTX, (uint64_t)w);
    }
}

/* The two instance handles the firing loops call through, taken once.
 *
 * Every compiled stand-in in the mock dereferences `this` without a null check
 * -- deliberately, because a conditional branch in the first fourteen bytes is
 * a relative branch the detour engine refuses -- so a firing loop has to call
 * on a real object. These two handles are held for the whole run and are the
 * only handles here that are meant to be: they are a fixed two, not two per
 * cycle, and the trend is what this run is reading. */
static char g_tiltSpec[64];
static char g_aimSpec[64];
static int32_t aowl_churn_targets(void) {
    if (aowl_churn_call("EFT.MovementContext::get_Instance", "[]") != 0) return 0;
    int64_t c = aowl_json_num(g_reply, "\"handle\"");
    if (c <= 0) return 0;
    if (aowl_churn_call("EFT.GameWorld::get_Instance", "[]") != 0) return 0;
    int64_t w = aowl_json_num(g_reply, "\"handle\"");
    if (w <= 0) return 0;
    char spec[64];
    snprintf(spec, sizeof(spec) - 1, "#%d::get_MainPlayer", (int)w);
    spec[sizeof(spec) - 1] = 0;
    if (aowl_churn_call(spec, "[]") != 0) return 0;
    int64_t p = aowl_json_num(g_reply, "\"handle\"");
    if (p <= 0) return 0;
    h_release(AOWL_CHURN_CTX, (uint64_t)w);
    snprintf(g_tiltSpec, sizeof(g_tiltSpec) - 1, "#%d::SetTilt", (int)c);
    snprintf(g_aimSpec,  sizeof(g_aimSpec)  - 1, "#%d::Aim",     (int)c);
    snprintf(g_hurtSpec, sizeof(g_hurtSpec) - 1, "#%d::Hurt",    (int)p);
    g_tiltSpec[sizeof(g_tiltSpec) - 1] = 0;
    g_aimSpec[sizeof(g_aimSpec) - 1] = 0;
    g_hurtSpec[sizeof(g_hurtSpec) - 1] = 0;
    return 1;
}

static void aowl_churn_fire_json(int32_t n) {
    int32_t i;
    for (i = 0; i < n; i++) aowl_churn_call(g_tiltSpec, "[0.25]");
}
static void aowl_churn_fire_typed(int32_t n) {
    int32_t i;
    for (i = 0; i < n; i++) aowl_churn_call(g_aimSpec, "[0.5]");
}
static void aowl_churn_emit_events(int32_t n) {
    int32_t i;
    for (i = 0; i < n; i++)
        h_emit(AOWL_CHURN_EMIT_CTX, (void*)"aowl.churn.ping", 15, (void*)"{}", 2);
}
static void aowl_churn_queue(int32_t n) {
    int32_t i;
    for (i = 0; i < n; i++)
        h_invokeMain(AOWL_CHURN_CTX, (void*)aowl_churn_main_cb, NULL);
}
static void aowl_churn_timers(int32_t n) {
    int32_t i;
    for (i = 0; i < n; i++)
        h_schedule(AOWL_CHURN_CTX, (int32_t)(i % 3), (void*)aowl_churn_main_cb, NULL);
}

/* One patch, installed under a mod's context so that unloading that mod is what
 * takes it out again -- which is the only way a patch is ever removed: the ABI
 * has no `unpatch`. */
static int32_t aowl_churn_install(const char* target, int32_t kind,
                                  int32_t typed, int32_t ctxIndex) {
    void* ctx = (void*)(uintptr_t)(uint32_t)ctxIndex;
    FnPatch fn = typed ? h_patchTyped : h_patch;
    void* cb = typed ? (void*)aowl_churn_typed_cb : (void*)aowl_churn_patch_cb;
    int32_t rc = fn(ctx, (void*)target, (int32_t)strlen(target), kind, cb, NULL);
    g_lastPatchRc = rc;
    if (rc != 0) g_patchBad++;
    return rc;
}

static void aowl_churn_emit_control(const char* verb, const char* payload) {
    char name[64];
    snprintf(name, sizeof(name) - 1, "aowlspt.host.mods.%s", verb);
    name[sizeof(name) - 1] = 0;
    h_emit(AOWL_CHURN_CTX, (void*)name, (int32_t)strlen(name),
           (void*)payload, (int32_t)strlen(payload));
}

static int32_t aowl_churn_counter(int32_t which) {
    switch (which) {
        case 0: return (int32_t)g_jsonFires;
        case 1: return (int32_t)g_typedFires;
        case 2: return (int32_t)g_eventFires;
        case 3: return (int32_t)g_mainFires;
        case 4: return g_resolveBad;
        case 5: return g_pinBad;
        case 6: return g_patchBad;
        case 7: return g_lastPatchRc;
        case 8: return (int32_t)g_nestCalls;
        default: return -1;
    }
}
/* 0 off, 1 one level deep, 2 unbounded. Flattening this to a boolean -- which
 * it was -- made mode 2 indistinguishable from mode 1, so the frame pool's
 * depth guard was reported as unexercised rather than as unreached. */
static void aowl_churn_set_nesting(int32_t on) { g_nestEnabled = (LONG)on; }

/* The mock's frame loop, stopped and started. The host's drain hook is on the
 * method that loop calls, so this is a drain that goes quiet -- which is what a
 * hook bound to a raid-only method does the moment the raid ends. */
static void aowl_churn_frame_pause(int32_t on) {
    if (!g_mockRt) return;
    void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_frame_pause");
    if (f) ((void(*)(int32_t))f)(on);
}
/* Committed private address space, bucketed by region size.
 *
 * Private bytes said the process was committing tens of megabytes per mod
 * load/unload cycle and no host table moved at all, which is a fact about
 * something that is not a table. This says *what shape* the commitment has:
 * one region of a few kilobytes per cycle is a bookkeeping structure, and a
 * long run of identically-sized multi-megabyte regions is an allocator arena
 * per loaded binary that nothing released when the binary went away.
 *
 * Reported rather than judged. It names the shape; it cannot name the owner. */
static int64_t g_regionBytes = 0;
static int32_t g_regionCount = 0;
static int64_t g_biggestRegion = 0;
static int32_t g_biggestCount = 0;
static void aowl_churn_scan_commit(void) {
    MEMORY_BASIC_INFORMATION mbi;
    unsigned char* p = NULL;
    int64_t total = 0;
    int32_t count = 0;
    /* The largest region size seen, and how many regions share it. A pool of
     * identical arenas shows up as a big number with a big count. */
    int64_t biggest = 0;
    int32_t biggestN = 0;
    while (VirtualQuery((void*)p, &mbi, sizeof(mbi)) == sizeof(mbi)) {
        if (mbi.State == MEM_COMMIT && mbi.Type == MEM_PRIVATE) {
            total += (int64_t)mbi.RegionSize;
            count++;
            if ((int64_t)mbi.RegionSize > biggest) {
                biggest = (int64_t)mbi.RegionSize;
                biggestN = 1;
            } else if ((int64_t)mbi.RegionSize == biggest) {
                biggestN++;
            }
        }
        unsigned char* next = (unsigned char*)mbi.BaseAddress + mbi.RegionSize;
        if (next <= p) break;
        p = next;
    }
    g_regionBytes = total;
    g_regionCount = count;
    g_biggestRegion = biggest;
    g_biggestCount = biggestN;
}
static int64_t aowl_churn_commit_bytes(void) { return g_regionBytes; }
static int32_t aowl_churn_commit_regions(void) { return g_regionCount; }
static int64_t aowl_churn_commit_biggest(void) { return g_biggestRegion; }
static int32_t aowl_churn_commit_biggest_n(void) { return g_biggestCount; }

/* The runtime's own count of the handles the host is holding. The one number
 * in this run that does not come from the host's bookkeeping, so the one that
 * can contradict it. */
static int32_t aowl_churn_gc_live(void) {
    if (!g_mockRt) return -1;
    void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_gchandle_live");
    if (!f) return -1;
    return ((int32_t(*)(void))f)();
}
static int32_t aowl_churn_have_frame_pause(void) {
    if (!g_mockRt) return 0;
    return GetProcAddress((HMODULE)g_mockRt, "mock_frame_pause") != NULL;
}
""".}

proc churnBind(): int32 {.importc: "aowl_churn_bind", nodecl.}
proc churnCall(target, args: cstring): int32 {.importc: "aowl_churn_call", nodecl.}
proc churnReplyLen(): int32 {.importc: "aowl_churn_reply_len", nodecl.}
proc churnReplyAt(i: int32): uint8 {.importc: "aowl_churn_reply_at", nodecl.}
proc churnRssKb(): int64 {.importc: "aowl_churn_rss_kb", nodecl.}
proc churnPrivateKb(): int64 {.importc: "aowl_churn_private_kb", nodecl.}
proc churnProcHandles(): int32 {.importc: "aowl_churn_proc_handles", nodecl.}
proc churnSubscribe(): int32 {.importc: "aowl_churn_subscribe", nodecl.}
proc churnHandles(n: int32) {.importc: "aowl_churn_handles", nodecl.}
proc churnPins(n: int32) {.importc: "aowl_churn_pins", nodecl.}
proc churnFireJson(n: int32) {.importc: "aowl_churn_fire_json", nodecl.}
proc churnFireTyped(n: int32) {.importc: "aowl_churn_fire_typed", nodecl.}
proc churnTargets(): int32 {.importc: "aowl_churn_targets", nodecl.}
proc churnEmitEvents(n: int32) {.importc: "aowl_churn_emit_events", nodecl.}
proc churnQueue(n: int32) {.importc: "aowl_churn_queue", nodecl.}
proc churnTimers(n: int32) {.importc: "aowl_churn_timers", nodecl.}
proc churnInstall(target: cstring; kind, typed, ctxIndex: int32): int32 {.
  importc: "aowl_churn_install", nodecl.}
proc churnEmitControl(verb, payload: cstring) {.
  importc: "aowl_churn_emit_control", nodecl.}
proc churnCounter(which: int32): int32 {.importc: "aowl_churn_counter", nodecl.}
proc churnSetNesting(on: int32) {.importc: "aowl_churn_set_nesting", nodecl.}
proc churnListedSeq(): int32 {.importc: "aowl_churn_listed_seq", nodecl.}
proc churnListedLen(): int32 {.importc: "aowl_churn_listed_len", nodecl.}
proc churnListedIndex(guid: cstring): int32 {.
  importc: "aowl_churn_listed_index", nodecl.}
proc churnSnapshot(nsType, meth: cstring): int32 {.
  importc: "aowl_churn_snapshot", nodecl.}
proc churnBytesRestored(): int32 {.importc: "aowl_churn_bytes_restored", nodecl.}
proc churnFramePause(on: int32) {.importc: "aowl_churn_frame_pause", nodecl.}
proc churnGcLive(): int32 {.importc: "aowl_churn_gc_live", nodecl.}
proc churnScanCommit() {.importc: "aowl_churn_scan_commit", nodecl.}
proc churnCommitBytes(): int64 {.importc: "aowl_churn_commit_bytes", nodecl.}
proc churnCommitRegions(): int32 {.importc: "aowl_churn_commit_regions", nodecl.}
proc churnCommitBiggest(): int64 {.importc: "aowl_churn_commit_biggest", nodecl.}
proc churnCommitBiggestN(): int32 {.
  importc: "aowl_churn_commit_biggest_n", nodecl.}
proc churnHaveFramePause(): int32 {.
  importc: "aowl_churn_have_frame_pause", nodecl.}


proc harnessLoad(path: cstring): nil pointer {.
  importc: "aowl_harness_load", nodecl.}
proc harnessError(): uint32 {.importc: "aowl_harness_error", nodecl.}
proc harnessSleep(ms: int32) {.importc: "aowl_harness_sleep", nodecl.}
proc harnessQpc(): int64 {.importc: "aowl_harness_qpc", nodecl.}
proc harnessQpf(): int64 {.importc: "aowl_harness_qpf", nodecl.}
proc rtLoad(path: cstring): int32 {.importc: "aowl_rt_load", nodecl.}
proc rtInit(): int32 {.importc: "aowl_rt_init", nodecl.}
proc rtTickCount(): int32 {.importc: "aowl_rt_tick_count", nodecl.}
proc rtFrameThread(): uint32 {.importc: "aowl_rt_frame_thread", nodecl.}
proc rtFrameCount(): int32 {.importc: "aowl_rt_frame_count", nodecl.}
proc mockStepCalls(): int32 {.importc: "aowl_rt_step_calls", nodecl.}
proc mockQuintCalls(): int32 {.importc: "aowl_rt_quint_calls", nodecl.}
proc payloadClear() {.importc: "aowl_churn_payload_clear", nodecl.}
proc payloadLen(): int32 {.importc: "aowl_churn_payload_len", nodecl.}
proc payloadAt(i: int32): uint8 {.importc: "aowl_churn_payload_at", nodecl.}
proc mockWbarrierCalls(): int32 {.importc: "aowl_rt_wbarrier_calls", nodecl.}
proc mockStaticDataCalls(): int32 {.importc: "aowl_rt_static_data_calls", nodecl.}
proc mockSpawnCount(): int32 {.importc: "aowl_rt_spawn_count", nodecl.}
proc mockGetTypeCalls(): int32 {.importc: "aowl_rt_gettype_calls", nodecl.}

type LaunchPtr = nil pointer

proc cLaunchNew(): LaunchPtr {.importc: "aowl_launch_new", nodecl.}
proc cLaunchFree(p: LaunchPtr) {.importc: "aowl_launch_free", nodecl.}
proc cLaunchStart(p: LaunchPtr; exe, workDir, cmdLine: cstring): int32 {.
  importc: "aowl_launch_start", nodecl.}
proc cLaunchInject(p: LaunchPtr; dll: cstring): int32 {.
  importc: "aowl_launch_inject", nodecl.}
proc cLaunchResume(p: LaunchPtr): int32 {.importc: "aowl_launch_resume", nodecl.}
proc cLaunchKill(p: LaunchPtr) {.importc: "aowl_launch_kill", nodecl.}
proc cLaunchClose(p: LaunchPtr) {.importc: "aowl_launch_close", nodecl.}
proc cLaunchPid(p: LaunchPtr): uint32 {.importc: "aowl_launch_pid", nodecl.}
proc cLaunchError(p: LaunchPtr): uint32 {.importc: "aowl_launch_error", nodecl.}
proc cLaunchWait(p: LaunchPtr; ms: int32): int32 {.
  importc: "aowl_launch_wait", nodecl.}

const Usage = """
hostharness -- run the IL2CPP client host outside the game

  hostharness HOST-DIR [--seconds N]     load the host into this process
  hostharness HOST-DIR --inject EXE      start EXE suspended and inject it
  hostharness HOST-DIR --runtime DLL     bring a mock IL2CPP runtime up too
  hostharness HOST-DIR --runtime DLL --churn N   load, unload, patch and
                                         release N times over and watch every
                                         host table for a trend
  hostharness --sleep N                  be an injection target for N seconds

HOST-DIR holds aowlspt-host-il2cpp.dll and mods/.

--runtime loads a stand-in GameAssembly.dll before the host and starts it a
second later, so the host's wait-for-runtime poll runs for real and resolve
and call have something to resolve against.

--churn N needs --runtime. It drives the host's own entry points directly --
resolve and release, patch install and removal through a mod that comes and
goes, handles taken and given back, events, timers, and the main-thread queue
including the drain going quiet -- and samples every table the host keeps as it
goes. It fails on a *trend*, not a threshold: a table that grows with the cycle
count is a leak whatever its absolute size. The mods directory must not hold a
mod that patches the same methods the run does; a stage with clientprobe alone
is what it expects.

--frame-bench N needs --runtime too. It arms a benchmark of the host's own
per-frame path and lets the drain thread run it, inside the frame, so what is
timed is the drain on the thread that pays for it rather than a copy of it in
this binary. It prints a table and asserts four things about it, including that
an armed per-frame chain costs the host no allocations at all.
"""

var gArgVerdicts: seq[string] = @[]
  ## What a hook was told about its arguments, decided before `checkLog` runs
  ## and printed under its `Result` heading.
  ##
  ## A seq rather than four assertions in place, because the payloads have to be
  ## collected while the host is still loaded and the runtime is still up, and
  ## the verdicts have to be printed where every other verdict in this run is
  ## printed. A check that prints somewhere else is a check a reader counts
  ## separately and eventually stops counting.
  ##
  ## Each entry begins with `ok ` or `err `, and an `err` fails the run.

proc recordOk(s: string) = gArgVerdicts.add "ok " & s
proc recordErr(s: string) = gArgVerdicts.add "err " & s

proc parseCount(s: string; into: var int): bool =
  var v = 0
  var any = false
  for ch in s:
    if ch >= '0' and ch <= '9':
      v = v * 10 + (ord(ch) - ord('0'))
      any = true
    else:
      return false
  if any: into = v
  result = any

proc numberAfter(line: string; needle: string): int =
  ## The first run of digits after `needle`, or -1 if the needle is not there.
  ## Written out rather than reached for with a parser because the only thing
  ## being read is a thread id the host printed itself.
  result = -1
  let at = find(line, needle)
  if at < 0:
    return
  var i = at + needle.len
  var v = 0
  var any = false
  while i < line.len and line[i] >= '0' and line[i] <= '9':
    v = v * 10 + (ord(line[i]) - ord('0'))
    any = true
    inc i
  if any: result = v

proc checkLog(logPath: string; expectRuntime: bool = false;
              frameThread: int = 0; haveProbe: bool = true): int =
  ## `haveProbe` says whether the stage actually contains the mods whose log
  ## lines these checks read. **There are two of them, and the second is the
  ## one people forget.**
  ##
  ## Every assertion below is made against what the *mods* wrote, because the
  ## host does not narrate a successful resolve and should not -- that would be
  ## a log line per call. The cost is that a stage missing one of them fails
  ## "only 0 types resolved" no matter how well the host worked, which is a
  ## statement about the stage and reads as a statement about the host. It has
  ## now sent three people looking for a regression that was a missing
  ## directory.
  ##
  ##  * `clientprobe` carries "types resolved" and shares three more.
  ##  * `examples/highlevel` carries **fifteen** of the twenty-four: enums in
  ##    both directions and on the fast path, the integer result register, the
  ##    write barrier, all four static-field lines, `alive()`, `everyMain`,
  ##    `stopMainRepeats` and slot reuse. A stage with `clientprobe` alone dies
  ##    at "no enum argument was bound" after nine assertions.
  ##
  ## So the note below names whichever is missing rather than assuming it is
  ## the probe.
  heading "Host log"
  var text = ""
  if not readTextFile(logPath, text):
    err "the host wrote no log at " & logPath
    err "that means its thread never ran -- the boot path is broken"
    return 1
  for l in splitLines(text):
    if l.len > 0:
      line "  " & l

  var started = false
  var loadedAMod = false
  var noticedNoRuntime = false
  var boundRuntime = false
  var resolved = 0
  var calledOk = false
  var patchFired = false
  var argsOk = false
  var objectOk = false
  var fieldOk = false
  var enumArgOk = false
  var enumRetOk = false
  var enumFastOk = false
  var retIntOk = false
  var barrierOk = false
  var staticRefusalOk = false
  var staticReadOk = false
  var staticFloatOk = false
  var staticWriteOk = false
  var aliveOk = false
  var mainFires = -1
  var mainThread = -1
  var mainStopOk = false
  var slotsOk = false
  var drainBound = false
  var drainMethod = ""
  var selfTestThread = -1
  for l in splitLines(text):
    if find(l, "host running") >= 0:
      started = true
    if find(l, "loaded ") >= 0 and find(l, "aowl.") >= 0:
      loadedAMod = true
    if find(l, "did not come up") >= 0:
      noticedNoRuntime = true
    if find(l, "IL2CPP runtime bound") >= 0:
      boundRuntime = true
    if find(l, "resolved ") >= 0:
      inc resolved
    if find(l, "the game says Unity") >= 0 or find(l, "Unity 2022") >= 0:
      calledOk = true
    if find(l, "the hook fired on all") >= 0 or
       find(l, "the patch fired on all") >= 0:
      patchFired = true
    if find(l, "Add(17, 25) = 42") >= 0:
      argsOk = true
    # The instance half. "took this player from" is only printed when a method
    # ran against a live object *and* the change stuck to it -- a host that
    # invoked with a null `this`, or against a copy, cannot produce that line.
    if find(l, "the change is on the object") >= 0:
      objectOk = true
    # A field read that agrees with the property getter for the same storage.
    # Either alone can be plausibly wrong; agreeing is what makes the offset
    # right rather than lucky.
    if find(l, "field agrees with get_") >= 0:
      fieldOk = true
    # Enums, both directions. Most of what this game's methods take is one, and
    # both halves failed silently before: an enum argument was refused outright,
    # and an enum return came back as a handle to a boxed integer, so a mod
    # reading it got 0 with `ok` true.
    if find(l, "an enum argument arrived as a plain") >= 0:
      enumArgOk = true
    if find(l, "an enum return read back as") >= 0:
      enumRetOk = true
    # The fast path's own answer, which is a different mechanism from the boxed
    # one above: `bindMethod` infers register classes from the runtime's
    # metadata, and it refused an enum until the payload width could be
    # measured rather than guessed.
    if find(l, "an enum parameter binds on the fast path") >= 0:
      enumFastOk = true
    # A typed postfix reading an **integer** result. The float half has been
    # covered since the typed path landed; the integer half had no method to
    # stand on -- every instance method here that returned one was either
    # shorter than the jump or had a relative branch in its prologue -- so
    # `resultInt` was unexercised and a host confusing RAX with XMM0 would have
    # answered a plausible number.
    if find(l, "read an integer result out of RAX") >= 0:
      retIntOk = true
    # A reference field stored through `il2cpp_gc_wbarrier_set_field` rather
    # than around it. The mod's half of this can only report that its binding
    # found the entry; the runtime's counter below is the other half.
    if find(l, "written through the write barrier") >= 0:
      barrierOk = true
    # A static field, which the fast path refused outright until now. The four
    # lines are four different failures: the two bindings refusing each other,
    # the read agreeing with the boxed path, the float read at the right width,
    # and the write landing. The runtime's counters below are what stop any of
    # them being true of a binding that read an object instead -- the stand-in
    # puts a static Int32 and an instance Single at the same offset precisely
    # so that the wrong answer is a number rather than a crash.
    if find(l, "refused the other's binding") >= 0:
      staticRefusalOk = true
    if find(l, "and the boxed path agrees") >= 0:
      staticReadOk = true
    if find(l, "a static float read 2.5") >= 0:
      staticFloatOk = true
    if find(l, "a static field write landed") >= 0:
      staticWriteOk = true
    # `alive()` in both directions. It used to answer false about a live
    # object, because it is a GetType call and the stand-in had no GetType --
    # so the mock's shape arrived at the mod as a statement about the object.
    if find(l, "alive() said true for a live object") >= 0:
      aliveOk = true
    # The per-frame chain on the game's thread. Both numbers are read out of
    # the line, because "it fired" is not the claim: the claim is that it fired
    # once per frame on the thread the drain runs on, and a chain that spun
    # inside a single frame would print a firing count in the thousands.
    # Matched on the whole shape, not on "everyMain fired ": the *failure*
    # lines this mod prints begin with those same two words, and the last
    # match won -- so a broken stop was read as a firing count of -1 on thread
    # -1 and reported as a thread mismatch. A grep that can be satisfied by the
    # message announcing a different failure is a grep that will one day be
    # satisfied by nothing at all.
    if find(l, "everyMain fired ") >= 0 and find(l, " times on thread ") >= 0:
      mainFires = numberAfter(l, "everyMain fired ")
      mainThread = numberAfter(l, " times on thread ")
    # And that it can be stopped. A per-frame chain with no working stop is a
    # mod that cannot be unloaded: a callback still re-arming after its
    # library has gone is a jump into freed code, on the game's thread.
    if find(l, "stopMainRepeats stopped the chain") >= 0:
      mainStopOk = true
    # The scheduler hands a fired one-shot's slot back. A mod queueing work onto
    # the main thread every frame used to leak one slot per frame.
    if find(l, "the scheduler reused its slots") >= 0:
      slotsOk = true
    # The main-thread drain. Which method bound is reported rather than
    # assumed: the host tries several and the harness has no business knowing
    # which one this runtime happens to have.
    if find(l, "main-thread drain bound to ") >= 0:
      drainBound = true
      let at = find(l, "main-thread drain bound to ")
      drainMethod = l.substr(at + len("main-thread drain bound to "))
    if find(l, "invoke_main self-test ran on thread ") >= 0:
      selfTestThread = numberAfter(l, "invoke_main self-test ran on thread ")

  heading "Result"
  if not started:
    err "the host never reached 'host running'"
    return 1
  ok "the host booted and reached its tick loop"
  if loadedAMod:
    ok "a mod was loaded through the ABI"
  else:
    warn "no mod was loaded -- expected only if mods/ is empty"

  if not expectRuntime:
    if noticedNoRuntime:
      ok "the missing IL2CPP runtime was reported, not crashed on"
    return 0

  # With a runtime present, silence is not success: the point of the run is
  # that resolve and call actually did something.
  if not boundRuntime:
    err "the host never bound the runtime"
    return 1
  ok "the host bound the runtime and attached a thread"

  # The main-thread handoff. This is the one assertion that cannot be made from
  # the log alone: the host says which thread ran a callback that was queued
  # from a different one, and only the runtime knows which thread its frame
  # loop is. They have to be the same number.
  # Skipped when the runtime has no frame loop -- an older stand-in, or the
  # injected run, where there is nothing to compare against and a claim would
  # be worth nothing.
  if frameThread > 0:
    if not drainBound:
      err "the host bound no per-frame method, so invoke_main is still on " &
          "its own thread"
      return 1
    ok "the host detoured " & drainMethod & " to drain on the game's thread"
    if selfTestThread < 0:
      err "the callback queued from the host thread never ran"
      return 1
    if selfTestThread != frameThread:
      err "a callback queued from the host thread ran on thread " &
          $selfTestThread & ", but the per-frame method runs on " &
          $frameThread
      return 1
    ok "a callback queued from another thread ran on thread " & $frameThread &
       " -- the same thread the drain hook fires on"

  if not haveProbe:
    note "this stage has no clientprobe in it, so nothing here asked the " &
         "runtime to resolve, call or patch anything; the host's own boot " &
         "checks above are all this run can establish"
    return 0
  if resolved < 3:
    err "only " & $resolved & " types resolved; expected at least 3"
    return 1
  ok $resolved & " types resolved by name through the runtime"
  if not enumArgOk:
    err "no enum argument was bound; a mod cannot call most of this game"
    return 1
  ok "an enum argument was bound from a number"
  if not enumRetOk:
    err "no enum return came back as a number"
    return 1
  ok "an enum return came back as a number rather than a handle"
  if not enumFastOk:
    err "the fast path would not bind a method taking an enum"
    return 1
  ok "the fast path bound a method taking an enum"
  if not retIntOk:
    err "no typed postfix read an integer result"
    return 1
  ok "a typed postfix read an integer result out of the right register"
  # Both halves, and neither alone is worth much. The mod says its binding
  # resolved the barrier and used it; the runtime says it was actually called.
  # A stand-in that did not export the entry would leave the mod silently on
  # the plain store, and a check written only against the mod's line would go
  # on passing -- which is how this hazard survived being documented.
  if not barrierOk:
    err "no reference field was written through the write barrier"
    return 1
  let wb = mockWbarrierCalls()
  if wb <= 0:
    err "the mod reported a barriered store but the runtime counted none; " &
        "the binding is storing around the collector"
    return 1
  ok "a reference field was stored through the collector's write barrier (" &
     $wb & " call(s) counted by the runtime)"

  # ---- static fields ------------------------------------------------------
  #
  # Every one of these has a runtime-side witness, and they need one. A static
  # field's offset and an instance field's offset are numbers in the same
  # range: the stand-in has `Player::SpawnCount` (static Int32) and
  # `Player::Health` (instance Single) both at 16. So a binding that read an
  # object where it meant to read the static block does not fail -- it answers
  # a number, sets `ok`, and every check written against the mod's own line
  # goes on passing. `mock_static_field_data_calls` is how this run knows the
  # static block was asked for at all, and `mock_player_spawn_count` is how it
  # knows the write went there.
  if not staticRefusalOk:
    err "the fast path did not refuse a static field for bindField and an " &
        "instance field for bindStaticField; one of the two binds the wrong " &
        "storage and answers a plausible number"
    return 1
  ok "an instance binding and a static binding each refused the other's field"
  let sd = mockStaticDataCalls()
  if sd <= 0:
    err "the mod reported a static field read but the runtime was never " &
        "asked for a static data block; the binding is reading an object"
    return 1
  if not staticReadOk:
    err "no static field was read, or it disagreed with the boxed path"
    return 1
  ok "a static field was read through its own binding and agreed with the " &
     "boxed path (" & $sd & " static-block lookup(s) counted by the runtime)"
  if not staticFloatOk:
    err "no static float was read at the right width"
    return 1
  ok "a static float was read at its declared width"
  if not staticWriteOk:
    err "no static field write landed"
    return 1
  let sc = mockSpawnCount()
  if sc != 4242:
    err "the mod reported writing 4242 to a static field but the runtime's " &
        "own static block holds " & $int(sc) & "; the write went somewhere else"
    return 1
  ok "a static field write landed in the runtime's static block (it holds " &
     $int(sc) & ")"

  # ---- alive() ------------------------------------------------------------
  if not aliveOk:
    err "alive() did not answer true for a live object and false for a " &
        "released one; a liveness predicate that says 'dead' about a live " &
        "object is worse than one that refuses"
    return 1
  let gt = mockGetTypeCalls()
  if gt <= 0:
    err "the mod reported alive() answering, but the runtime never had an " &
        "object asked for its type; alive() is answering something else"
    return 1
  ok "alive() answered both ways and the runtime counted " & $int(gt) &
     " GetType call(s) behind it"

  # ---- everyMain ----------------------------------------------------------
  #
  # `every` repeats on the host's thread and `onMainThread` reaches the game's
  # and does not repeat; `everyMain` is both, built out of a one-shot that
  # re-arms itself. That it does not spin inside one frame is a property of the
  # host's drain -- the queue is snapshotted under the lock and walked outside
  # it -- so the check that matters is the *rate*: firings must not exceed the
  # frames the runtime says it ran. A chain re-armed into the live queue would
  # print a firing count in the thousands here rather than in the tens.
  if mainFires < 0:
    err "everyMain never reported; either it was refused or it never fired"
    return 1
  if mainFires == 0:
    err "everyMain was accepted and fired no times"
    return 1
  if frameThread > 0:
    if mainThread != frameThread:
      err "everyMain fired on thread " & $mainThread & ", but the runtime's " &
          "per-frame method runs on " & $frameThread & "; it is not reaching " &
          "the game's thread"
      return 1
    let frames = int(rtFrameCount())
    if frames > 0 and mainFires > frames:
      err "everyMain fired " & $mainFires & " times in " & $frames &
          " frames; a per-frame chain that fires more often than the frame " &
          "it re-arms in is spinning inside one drain"
      return 1
    ok "everyMain fired " & $mainFires & " times on thread " & $mainThread &
       ", the game's own, and never more than once per frame (" & $frames &
       " frames)"
  else:
    ok "everyMain fired " & $mainFires & " times"
  if not mainStopOk:
    err "stopMainRepeats did not stop the chain, or never reported; a " &
        "per-frame chain that cannot be stopped cannot be unloaded"
    return 1
  ok "stopMainRepeats stopped a running everyMain chain"
  if not slotsOk:
    err "the scheduler did not report reusing its slots"
    return 1
  ok "the scheduler reuses a fired callback's slot"
  if not calledOk:
    err "call never returned a value"
    return 1
  ok "a method was invoked and its string return marshalled back"
  if not argsOk:
    err "no call with arguments produced the expected value"
    return 1
  ok "arguments were bound by declared type and came back correct"
  if not patchFired:
    err "no patch fired"
    return 1
  ok "a compiled method was detoured and the patch fired"
  if not objectOk:
    err "no live object was reached; instance calls did not work"
    return 1
  ok "a live object was reached and an instance call changed it"
  if not fieldOk:
    err "no field was read; reflection over fields did not work"
    return 1
  ok "a field was read by declared type and agreed with its property"

  # ---- what a hook is told about its arguments ---------------------------
  #
  # Collected by `probeArgPayloads`, which reads the bytes a handler was
  # actually handed rather than a line some mod printed about them. Every
  # failure is reported rather than the first, because these four are four
  # different statements about the same payload and knowing which of them
  # broke is the whole value of having four.
  var argsBad = 0
  for v in gArgVerdicts:
    if startsWith(v, "ok "):
      ok substr(v, 3)
    else:
      err substr(v, 4)
      inc argsBad
  if argsBad > 0:
    return 1

  result = 0

proc runInjection(hostDll, logPath, target: string; seconds: int): int =
  ## The real launcher's path, against a target we control.
  heading "Injecting"
  line "  target  " & target
  if not fileExists(target):
    err "no such executable"
    return 1

  let launch = cLaunchNew()
  if launch == nil:
    err "out of memory"
    return 1

  var e = target
  var w = parentOf(target)
  # argv[0] first, the way CreateProcess expects a command line.
  var cmd = "\"" & target & "\" --sleep " & $seconds
  if cLaunchStart(launch, toCString(e), toCString(w), toCString(cmd)) == 0'i32:
    err "could not start it (error " & $int(cLaunchError(launch)) & ")"
    cLaunchFree(launch)
    return 1
  ok "started suspended, pid " & $int(cLaunchPid(launch))

  var d = hostDll
  if cLaunchInject(launch, toCString(d)) == 0'i32:
    err "injection failed (error " & $int(cLaunchError(launch)) & ")"
    cLaunchKill(launch)
    cLaunchClose(launch)
    cLaunchFree(launch)
    return 1
  ok "host injected into the target"

  if cLaunchResume(launch) == 0'i32:
    err "could not resume (error " & $int(cLaunchError(launch)) & ")"
    cLaunchKill(launch)
    cLaunchClose(launch)
    cLaunchFree(launch)
    return 1
  ok "target resumed"

  discard cLaunchWait(launch, int32((seconds + 5) * 1000))
  cLaunchClose(launch)
  cLaunchFree(launch)
  result = checkLog(logPath)


# ---------------------------------------------------------------------------
# The churn run
# ---------------------------------------------------------------------------
#
# One round is a slice of everything a mod does to this host, plus a whole mod
# coming out and going back in. Every table the host keeps is sampled every few
# rounds, and what is reported is the *trend* through those samples rather than
# any single figure -- because a leak is a slope, and a threshold on an absolute
# size would either fire on a warm cache or miss a table growing by sixteen
# bytes a cycle for the length of a raid.
#
# The tables that must be flat, and what a slope in each one would mean:
#
#   patches / hookUsed  a detour slot that is not reclaimed. There are sixteen,
#                       so this one does not "leak slowly": it stops working.
#   handles             a GC handle table that never reuses a released slot,
#                       which on a mod pinning per frame is one slot a frame.
#   subs                a subscriber list a mod's unload did not clear, which
#                       is also a call into a freed DLL waiting to happen.
#   pending             the main-thread queue, which is allowed to move but
#                       must come back to nothing when the producer stops.
#   procHandles         an OS handle -- a file, an event, a library -- per cycle.
#   rssKb               everything else, including anything the C side of the
#                       ABI allocated and nobody freed.
#
# `mods` is the one that grows by design and is reported without a verdict: a
# context pointer *is* an index, so the loader keeps dead slots rather than
# compacting and repointing every live mod at its neighbour.

type
  Sample = object
    cycle: int64
    rss: int64
    priv: int64
    procHandles: int64
    patches: int64
    patchesLive: int64
    hookUsed: int64
    hookFree: int64
    handles: int64
    handlesLive: int64
    handlesFree: int64
    subs: int64
    pending: int64
    mods: int64
    modsLive: int64
    allocCount: int64
    allocLive: int64
    gcLive: int64

proc jsonPath(path: string): string =
  ## A Windows path inside a JSON string. Every backslash doubled and nothing
  ## else touched: the only characters in a mod path that JSON cares about are
  ## the separators.
  result = ""
  for ch in path:
    if ch == '\\':
      result.add "\\\\"
    else:
      result.add ch

proc replyText(): string =
  ## The last host reply, as a string. Byte at a time because it is a few
  ## hundred characters the host built itself, once every few hundred rounds.
  result = ""
  let n = int(churnReplyLen())
  for i in 0 ..< n:
    result.add char(churnReplyAt(int32(i)))

proc hostAsk(target: string): string =
  var t = target
  var a = "[]"
  if churnCall(toCString(t), toCString(a)) != 0'i32:
    return ""
  result = replyText()

proc numAfter(doc, key: string): int64 =
  ## The number after `"key":` in a reply this host wrote. -1 when absent.
  result = -1
  let needle = "\"" & key & "\":"
  let at = find(doc, needle)
  if at < 0:
    return
  var i = at + needle.len
  var neg = false
  if i < doc.len and doc[i] == '-':
    neg = true
    inc i
  var v = 0'i64
  var any = false
  while i < doc.len and doc[i] >= '0' and doc[i] <= '9':
    v = v * 10'i64 + int64(ord(doc[i]) - ord('0'))
    any = true
    inc i
  if not any:
    return -1
  result = (if neg: -v else: v)

proc hostAskArgs(target, args: string): string =
  var t = target
  var a = args
  if churnCall(toCString(t), toCString(a)) != 0'i32:
    return ""
  result = replyText()

# ---------------------------------------------------------------------------
# What a hook is told about its arguments
#
# Win64 passes four arguments in registers and the detour thunk saves those
# four. `this` is one of them on an instance method, so a four-argument
# instance method's last parameter arrived on the stack and is not in the
# frame at all. That constraint is real and is not what is being tested here.
#
# What is tested is what the payload *says* about it. It used to say nothing:
# the array stopped at three entries and a handler reading argument 3 got the
# same empty answer an argument with an empty value would give it. The two
# methods below are the pair that makes the difference reachable --
# `EFT.MovementContext::Step` and `EFT.Player::Quint` have the same four
# leading parameter types and differ only in `this` -- and these checks read
# the bytes the handler was handed, because a payload that omits an argument
# and one that reports it as empty are indistinguishable in any summary.
# ---------------------------------------------------------------------------

const
  StepTarget  = "EFT.MovementContext::Step"
  QuintTarget = "EFT.Player::Quint"
  MarkerF     = "{\"onStack\":true,\"type\":\"System.Single\"}"
  MarkerI     = "{\"onStack\":true,\"type\":\"System.Int32\"}"

proc payloadText(): string =
  ## The last payload a JSON hook was handed, verbatim.
  result = ""
  let n = int(payloadLen())
  for i in 0 ..< n:
    result.add char(payloadAt(int32(i)))

proc argsInterior(payload: string): string =
  ## The inside of the payload's `"args"` array, or "" if there is not one.
  ##
  ## Bracket-counted rather than taken to the last `]`, because an argument may
  ## itself be an object and a `System.String` argument may contain anything at
  ## all -- including a bracket. The one producer of these payloads is the host,
  ## and the strings inside them come from the game.
  result = ""
  let needle = "\"args\":["
  let at = find(payload, needle)
  if at < 0:
    return
  var i = at + needle.len
  var depth = 0
  var inStr = false
  var out1 = ""
  while i < payload.len:
    let ch = payload[i]
    if inStr:
      out1.add ch
      if ch == '\\' and i + 1 < payload.len:
        inc i
        out1.add payload[i]
      elif ch == '"':
        inStr = false
    elif ch == '"':
      inStr = true
      out1.add ch
    elif ch == '{' or ch == '[':
      inc depth
      out1.add ch
    elif ch == ']' and depth == 0:
      return out1
    elif ch == '}' or ch == ']':
      dec depth
      out1.add ch
    else:
      out1.add ch
    inc i
  # Unterminated. Nothing is claimed about a payload that does not close its
  # own array; the caller sees "" and says so.
  result = ""

proc splitTop(interior: string): seq[string] =
  ## An array's elements, split on the commas that are not inside a string or a
  ## nested object.
  result = @[]
  if interior.len == 0:
    return
  var depth = 0
  var inStr = false
  var cur = ""
  var i = 0
  while i < interior.len:
    let ch = interior[i]
    if inStr:
      cur.add ch
      if ch == '\\' and i + 1 < interior.len:
        inc i
        cur.add interior[i]
      elif ch == '"':
        inStr = false
    elif ch == '"':
      inStr = true
      cur.add ch
    elif ch == '{' or ch == '[':
      inc depth
      cur.add ch
    elif ch == '}' or ch == ']':
      dec depth
      cur.add ch
    elif ch == ',' and depth == 0:
      result.add cur
      cur = ""
    else:
      cur.add ch
    inc i
  result.add cur

proc probeArgPayloads() =
  ## Fires a hook on one instance method and one static method whose fourth and
  ## fifth arguments are past the register window, and reads what the handler
  ## was handed.
  if churnBind() == 0'i32:
    recordErr "the harness could not bind the host's patch and call entry " &
              "points, so nothing could be asked what a hook is told about " &
              "its arguments"
    return
  let ctxReply = hostAsk("EFT.MovementContext::get_Instance")
  let ctxHandle = numAfter(ctxReply, "handle")
  if ctxHandle <= 0'i64:
    recordErr "no EFT.MovementContext instance came back, so the instance " &
              "half of the argument checks could not be fired"
    return
  var stepTarget = StepTarget
  var quintTarget = QuintTarget
  if churnInstall(toCString(stepTarget), 0x10'i32, 0'i32, 0x7FFF'i32) != 0'i32:
    recordErr "could not install a JSON prefix with arguments on " &
              StepTarget & " (code " & $int(churnCounter(7'i32)) & ")"
    return
  if churnInstall(toCString(quintTarget), 0x10'i32, 0'i32, 0x7FFF'i32) != 0'i32:
    recordErr "could not install a JSON prefix with arguments on " &
              QuintTarget & " (code " & $int(churnCounter(7'i32)) & ")"
    return

  # ---- the instance method: four declared, three in registers -------------
  let stepBefore = mockStepCalls()
  payloadClear()
  var spec = "#" & $int(ctxHandle) & "::Step"
  discard hostAskArgs(spec, "[0.5,3,\"seven\",1.5]")
  let stepPayload = payloadText()
  let stepArgs = splitTop(argsInterior(stepPayload))
  if stepPayload.len == 0:
    recordErr "the hook on " & StepTarget & " was never handed a payload; " &
              "either the detour did not fire or it fired without arguments"
    return
  if mockStepCalls() <= stepBefore:
    recordErr "the original " & StepTarget & " never ran, so the payload " &
              "below describes a firing that did not happen"
    return

  if numAfter(stepPayload, "argc") != 4'i64 or stepArgs.len != 4:
    recordErr "a four-argument instance method's payload should carry " &
              "argc 4 and four entries; it carries argc " &
              $int(numAfter(stepPayload, "argc")) & " and " & $stepArgs.len &
              " entry(s). An argument that is simply absent reads exactly " &
              "like one whose value was empty: " & stepPayload
  elif stepArgs[3] != MarkerF:
    recordErr "the fourth declared argument of an instance method is on the " &
              "stack and must be named as such; the payload has " &
              stepArgs[3] & " there rather than " & MarkerF
  elif numAfter(stepPayload, "stackArgs") != 1'i64:
    recordErr "the payload names one stack argument in its array but its " &
              "stackArgs count says " & $int(numAfter(stepPayload, "stackArgs"))
  else:
    recordOk "a hook on a four-argument instance method is told about all " &
             "four: three values and the fourth named " & MarkerF &
             ", which no reported value can be mistaken for"

  # The three that *are* in registers, and specifically that the float went to
  # its own file at the same *position*: `Step`'s first parameter is XMM1
  # because `this` took position 0, and a host that counted integer and float
  # registers separately would read it out of XMM0 and report `this` as a
  # number.
  if stepArgs.len >= 3:
    if find(stepArgs[0], "0.5") < 0 or stepArgs[1] != "3" or
       stepArgs[2] != "\"seven\"":
      recordErr "the three register arguments of " & StepTarget &
                " came back as " & stepArgs[0] & ", " & stepArgs[1] & ", " &
                stepArgs[2] & " rather than 0.5, 3 and \"seven\"; a float at " &
                "position 1 is XMM1, an integer at 2 is R8 and a reference " &
                "at 3 is R9"
    else:
      recordOk "the three arguments an instance method does fit in registers " &
               "are read by position across both register files: 0.5 out of " &
               "XMM1, 3 out of R8 and \"seven\" out of R9"

  # ---- the static method: five declared, four in registers ----------------
  let quintBefore = mockQuintCalls()
  payloadClear()
  discard hostAskArgs("EFT.Player::Quint", "[0.5,3,\"seven\",1.5,9]")
  let quintPayload = payloadText()
  let quintArgs = splitTop(argsInterior(quintPayload))
  if quintPayload.len == 0 or mockQuintCalls() <= quintBefore:
    recordErr "the hook on " & QuintTarget & " was never handed a payload, " &
              "or the original never ran"
    return
  if numAfter(quintPayload, "argc") != 5'i64 or quintArgs.len != 5:
    recordErr "a five-argument static method's payload should carry argc 5 " &
              "and five entries; it carries argc " &
              $int(numAfter(quintPayload, "argc")) & " and " & $quintArgs.len &
              " entry(s): " & quintPayload
  elif quintArgs[4] != MarkerI:
    recordErr "the fifth declared argument of a static method is on the " &
              "stack and must be named as such; the payload has " &
              quintArgs[4] & " there rather than " & MarkerI
  elif numAfter(quintPayload, "stackArgs") != 1'i64:
    recordErr "the static payload names one stack argument but its " &
              "stackArgs count says " &
              $int(numAfter(quintPayload, "stackArgs"))
  else:
    recordOk "a hook on a five-argument static method is told about all " &
             "five: four values and the fifth named " & MarkerI

  # The difference between the two, which is the whole point of the pair: the
  # same declared type at the same index is a value on the static method and a
  # stack marker on the instance one, and `this` is the only reason.
  if quintArgs.len >= 4 and stepArgs.len >= 4:
    if find(quintArgs[3], "1.5") < 0:
      recordErr "the static method's fourth argument should be 1.5 out of " &
                "XMM3 -- static means parameter n is register position n -- " &
                "and it is " & quintArgs[3]
    elif stepArgs[3] == quintArgs[3]:
      recordErr "the instance and static methods reported their fourth " &
                "argument identically; one of them is wrong, because `this` " &
                "pushes the instance one onto the stack"
    else:
      recordOk "the same declared parameter is a value on the static method " &
               "(1.5, out of XMM3) and a named stack argument on the " &
               "instance one, and the payload says which it is rather than " &
               "leaving a handler to work it out from the arity"

proc rowNs(doc, op: string): int64 =
  ## The `ps` figure of the row whose `op` is `op`, or -1.
  ##
  ## Picoseconds rather than nanoseconds because two of the four rows are a
  ## handful of instructions, and a nanosecond figure rounds a change of thirty
  ## percent in the empty-queue drain to no change at all.
  result = -1
  let needle = "\"op\":\"" & op & "\""
  let at = find(doc, needle)
  if at < 0:
    return
  result = numAfter(doc.substr(at), "ps")

proc psText(ps: int64): string =
  ## Picoseconds as nanoseconds with two decimals. Written out because the two
  ## cheap rows are single-digit nanoseconds and an integer would report every
  ## one of them as "5".
  if ps < 0'i64:
    return "n/a"
  let whole = ps div 1000'i64
  let frac = ps mod 1000'i64
  var f = $(frac div 10'i64)
  if f.len < 2: f = "0" & f
  result = $whole & "." & f

proc benchTable(root: string; iters: int): int =
  ## The per-frame path, measured inside the host on the host's drain thread.
  ##
  ## The whole point of measuring it there rather than here: the drain runs on
  ## whichever thread won the detoured method, with the host's allocator and
  ## the host's lock. A loop in this binary would be timing a copy of the code
  ## rather than the code, and would say nothing about either.
  heading "Per-frame path"
  var problems = 0

  if churnBind() == 0'i32:
    err "the host does not export the entry points this drives"
    return 1

  let armed = hostAskArgs("aowlspt.host::frame_bench_arm", "[" & $iters & "]")
  if find(armed, "\"armed\":true") < 0:
    err "the host would not arm the frame bench: " & armed
    note "it refuses when no per-frame method bound, because then there is " &
         "no frame to measure and the drain is on the host's own thread"
    return 1
  ok "armed for " & $iters & " iterations; waiting for a frame to run it"

  var report = ""
  var waited = 0
  while waited < 30000:
    harnessSleep(250'i32)
    waited = waited + 250
    report = hostAsk("aowlspt.host::frame_bench")
    if find(report, "\"rows\"") >= 0:
      break
  if find(report, "\"rows\"") < 0:
    err "no report after " & $waited & "ms; the drain never fired"
    return 1

  let empty = rowNs(report, "mainDrain, queue empty")
  let held = rowNs(report, "mainDrain, one entry queued not due")
  let turn = rowNs(report, "enqueue + takeDue, no dispatch")
  let chain = rowNs(report, "enqueue + mainDrain, one chain frame")
  let dispatches = numAfter(report, "dispatches")
  let chainFrames = numAfter(report, "chainFrames")
  let allocDelta = numAfter(report, "allocDelta")

  line ""
  line "  operation                                        ns/op"
  line "  ---------------------------------------------  -------"
  line "  mainDrain, queue empty                         " & psText(empty)
  line "  mainDrain, one entry queued, not yet due        " & psText(held)
  line "  enqueue + takeDue, no dispatch                  " & psText(turn)
  line "  enqueue + mainDrain, one armed chain frame      " & psText(chain)
  line ""
  line "  what those are made of:"
  line "  cMqEnter alone, the gate                        " &
       psText(rowNs(report, "cMqEnter alone, the gate"))
  line "  cMqLock + cMqUnlock, uncontended                " &
       psText(rowNs(report, "cMqLock plus cMqUnlock, uncontended"))
  line "  cNowMs                                         " &
       psText(rowNs(report, "cNowMs"))
  line ""

  # And the one row that cannot be timed inside the host, because half of it is
  # the caller's: an ABI `call` in and a reply string out. `patch_stats` is a
  # host-internal target, so no game type is resolved and no method invoked --
  # what is left is exactly the crossing and the marshalling. A mod reaching
  # the *game* pays this on top of `perfbench`'s boxed-call figure.
  var probeArgs = "[]"
  var probeTarget = "aowlspt.host::patch_stats"
  discard churnCall(toCString(probeTarget), toCString(probeArgs))
  let callIters = 20000
  let q0 = harnessQpc()
  for k in 0 ..< callIters:
    discard churnCall(toCString(probeTarget), toCString(probeArgs))
  let q1 = harnessQpc()
  let freq = harnessQpf()
  var callPs = -1'i64
  if freq > 0'i64:
    callPs = ((q1 - q0) * 1000000000000'i64) div (freq * int64(callIters))
  # The same crossing with the reply taken out of it: a malformed target is
  # refused after the two argument copies and before anything is built, so the
  # gap between these two rows is what building and handing back a hundred
  # bytes of JSON costs.
  var badTarget = "not-a-target"
  discard churnCall(toCString(badTarget), toCString(probeArgs))
  let r0 = harnessQpc()
  for k in 0 ..< callIters:
    discard churnCall(toCString(badTarget), toCString(probeArgs))
  let r1 = harnessQpc()
  var refusedPs = -1'i64
  if freq > 0'i64:
    refusedPs = ((r1 - r0) * 1000000000000'i64) div (freq * int64(callIters))

  line "  host `call` round trip from another binary, reply string included:"
  line "  aowlspt.host::patch_stats                      " & psText(callPs)
  line "  a malformed target, refused before any reply    " & psText(refusedPs)
  line ""
  line "  " & $dispatches & " callbacks dispatched, " & $allocDelta &
       " host allocations over " & $chainFrames & " chain frames"
  line ""

  # --- the assertions ------------------------------------------------------
  #
  # Every one of these is written so that it fails if the thing it names stops
  # happening, and not merely if a number moves. A timing threshold on its own
  # would be noise wearing a check's clothes.

  # 1. The loop dispatched. Without this every row below is a benchmark of a
  #    drain that dropped its queue on the floor, which would time beautifully.
  if dispatches < chainFrames:
    err "the chain loop ran " & $chainFrames & " frames but the host's " &
        "callback counter moved by " & $dispatches &
        "; the drain is not dispatching what it dequeues"
    return 1
  ok $dispatches & " callbacks were dispatched through the ABI trampoline, " &
     "one per armed frame"

  # 2. The steady state allocates nothing. This is the property the drain was
  #    rewritten for, and it is the one assertion here that a person could not
  #    have written before the rewrite: the old drain built a fresh `due` seq
  #    and a fresh `keep` seq every frame and handed the second to `gPending`,
  #    so this number was two per frame -- 40000 over this loop, not zero.
  #    The counter is mimalloc's cumulative block count inside the *host*, so
  #    nothing on the free path can lower it back to a passing figure.
  if allocDelta < 0'i64:
    err "the host could not read its own allocation counter"
    return 1
  if allocDelta != 0'i64:
    err "the drain made " & $allocDelta & " host allocations over " &
        $chainFrames & " frames of an armed chain; the steady state is " &
        "supposed to reuse its buffers"
    return 1
  ok "an armed per-frame chain cost the host 0 allocations over " &
     $chainFrames & " frames"

  # 3. The gate is doing its job: a frame with nothing queued must be cheaper
  #    than a frame that has to walk the queue. If `cMqEnter` ever stopped
  #    short-circuiting, these two would converge -- and nothing else here
  #    would notice.
  if empty <= 0'i64 or held <= 0'i64:
    err "a row came back at or below zero; the clock is not resolving this"
    return 1
  if empty >= held:
    err "an empty-queue frame (" & psText(empty) & ") costs at least as much " &
        "as one with an entry to walk (" & psText(held) & "); the lock-free " &
        "empty check is not short-circuiting"
    return 1
  ok "an empty frame is cheaper than a frame that walks the queue (" &
     psText(empty) & " against " & psText(held) & ")"

  # There was a fourth check here and it is gone on purpose. It asserted that
  # a chain frame costs more than the same queue turnaround without a
  # dispatch -- true, and about 2.5 ns of truth, against two rows whose
  # run-to-run spread is fifteen. It failed on the first run where the noise
  # went the other way, which is a check reporting the weather. What it was
  # trying to establish -- that the callback is really on the measured path --
  # is what the dispatch counter above establishes exactly, and the counter
  # cannot be satisfied by a fast afternoon.
  line "  the dispatch itself is " & psText(chain - turn) &
       " of the chain frame, which is inside the run-to-run spread of both " &
       "rows; it is reported and not asserted"

  note "these are tests/mockil2cpp, not Tarkov: what they establish is the " &
       "host's own per-frame cost, on a stand-in's frame loop"
  result = problems

proc takeSample(cycle: int): Sample =
  let t = hostAsk("aowlspt.host::table_stats")
  result = Sample(cycle: int64(cycle),
                  rss: churnRssKb(),
                  priv: churnPrivateKb(),
                  procHandles: int64(churnProcHandles()),
                  patches: numAfter(t, "patches"),
                  patchesLive: numAfter(t, "patchesLive"),
                  hookUsed: numAfter(t, "hookUsed"),
                  hookFree: numAfter(t, "hookFree"),
                  handles: numAfter(t, "handles"),
                  handlesLive: numAfter(t, "handlesLive"),
                  handlesFree: numAfter(t, "handlesFree"),
                  subs: numAfter(t, "subs"),
                  pending: numAfter(t, "pending"),
                  mods: numAfter(t, "mods"),
                  modsLive: numAfter(t, "modsLive"),
                  allocCount: numAfter(t, "allocCount"),
                  allocLive: numAfter(t, "allocLive"),
                  gcLive: int64(churnGcLive()))

proc slopePerK(xs, ys: seq[int64]): int64 =
  ## Least squares, in units per thousand cycles.
  ##
  ## A fit rather than last-minus-first because the noisy series here -- RSS,
  ## the pending queue -- can end high or low by accident, and one sample is not
  ## a trend. Integer arithmetic scaled by a thousand: the answer wanted is
  ## "entries per thousand cycles", which is a whole number for every table that
  ## matters and would be an unreadable fraction otherwise.
  result = 0
  let n = int64(xs.len)
  if n < 2'i64:
    return
  var sx = 0'i64
  var sy = 0'i64
  var sxy = 0'i64
  var sxx = 0'i64
  for i in 0 ..< xs.len:
    sx = sx + xs[i]
    sy = sy + ys[i]
    sxy = sxy + xs[i] * ys[i]
    sxx = sxx + xs[i] * xs[i]
  let den = n * sxx - sx * sx
  if den == 0'i64:
    return
  result = ((n * sxy - sx * sy) * 1000'i64) div den

proc secondHalf(v: seq[int64]): seq[int64] =
  ## The settled part of a series.
  ##
  ## Several of these tables are high-water marks rather than counts -- the
  ## handle table is the size of the most handles ever held at once, not the
  ## number ever taken -- so they climb once and then stop. Fitting from the
  ## first sample reads that climb as a slope for the whole run; fitting the
  ## back half asks the question that matters, which is whether it is still
  ## climbing.
  result = @[]
  var at = v.len div 2
  if at >= v.len: at = 0
  for i in at ..< v.len:
    result.add v[i]

proc trend(label: string; xs, ys: seq[int64]; tolerance: int64;
           unit: string; problems: var int) =
  ## One series, fitted and judged. `tolerance` is in the same units the slope
  ## is reported in -- per thousand cycles -- so "0" means a table that must not
  ## grow at all and a larger number is the honest noise floor of a series that
  ## moves for reasons other than a leak.
  let s = slopePerK(secondHalf(xs), secondHalf(ys))
  var first = 0'i64
  var last = 0'i64
  if ys.len > 0:
    first = ys[0]
    last = ys[ys.len - 1]
  let text = label & ": " & $first & " -> " & $last & unit &
             ", slope " & $s & unit & "/1000 cycles"

  # A slope is an extrapolation, and a short run extrapolates a long way. At
  # `--churn 40` the process's private bytes moved **16 KB** across the settled
  # half and that was reported as 537 KB per thousand cycles -- a failure. The
  # same stage at 120 and at 400 cycles is flat. One page the allocator touched
  # inside a short window is not a leak, but multiplied by 25 it looks like one.
  #
  # So the net movement has to clear a floor of its own before a slope through
  # it is worth believing. The floor is a quarter of the series' tolerance: far
  # below anything that matters (the mimalloc arena leak this file was written
  # to catch was 32 MB *per load*), and far above the noise a few dozen cycles
  # produce. A run that cannot see far enough says so rather than failing, and
  # rather than the worse alternative of passing quietly and leaving the reader
  # believing a leak was looked for.
  var floorAbs = tolerance div 4
  if floorAbs < 1: floorAbs = 1
  if s > tolerance and last > first and (last - first) < floorAbs:
    note text & " -- moved only " & $(last - first) & unit & " in " &
         $(if xs.len > 0: xs[xs.len - 1] else: 0'i64) &
         " cycles, which is too little to call a trend; run --churn 120 or more"
    return
  # `last > first` as well as the slope: several of these are noisy enough that
  # a fit through the settled half can come out positive on a series that ended
  # below where it started -- the working set in particular, which moves with
  # whatever Windows feels like trimming. A leak is a slope *and* a net gain.
  if s > tolerance and last > first:
    err text & " -- grows with the cycle count"
    inc problems
  else:
    ok text

proc waitForLive(want: int; timeoutMs: int): bool =
  ## The mod-control queue is drained on the host's own tick, so a load or an
  ## unload is a request rather than a call. Polling the host's own count is the
  ## only honest way to know it happened; a fixed sleep would either be slower
  ## than the run can afford or a race.
  var waited = 0
  while waited < timeoutMs:
    let t = hostAsk("aowlspt.host::table_stats")
    if numAfter(t, "modsLive") == int64(want):
      return true
    harnessSleep(5'i32)
    waited = waited + 5
  result = false

proc waitForListed(was: int; timeoutMs: int): bool =
  var waited = 0
  while waited < timeoutMs:
    if int(churnListedSeq()) != was:
      return true
    harnessSleep(5'i32)
    waited = waited + 5
  result = false

proc modIndexOfGuid(guid: string; timeoutMs: int): int =
  ## Asks the host to list its mods and reads the position of `guid`, which is
  ## its context index -- dead slots are kept, so position and index agree.
  var verb = "list"
  var body = "{}"
  let was = int(churnListedSeq())
  churnEmitControl(toCString(verb), toCString(body))
  if not waitForListed(was, timeoutMs):
    return -1
  var g = guid
  result = int(churnListedIndex(toCString(g)))

proc reportTrends(what: string; xs: seq[int64]; samples: seq[Sample];
                  rssTol, privTol: int64; problems: var int) =
  ## The verdict for one pass. Split from the run because there are two passes
  ## and they answer different questions: one drives everything a *mod* does
  ## with nothing coming or going, the other takes a mod out and puts it back.
  ## A single series over both would have every trend read as the mod cycle's,
  ## which is the one thing here that is expensive by design.
  heading "Trends -- " & what
  var rss: seq[int64] = @[]
  var pv: seq[int64] = @[]
  var ph: seq[int64] = @[]
  var pt: seq[int64] = @[]
  var hu: seq[int64] = @[]
  var hl: seq[int64] = @[]
  var hv: seq[int64] = @[]
  var sb: seq[int64] = @[]
  var pd: seq[int64] = @[]
  var gc: seq[int64] = @[]
  var lv: seq[int64] = @[]
  for s in samples:
    gc.add s.gcLive
    lv.add s.allocLive
    pv.add s.priv
    rss.add s.rss
    ph.add s.procHandles
    pt.add s.patches
    hu.add s.hookUsed
    hl.add s.handles
    hv.add s.handlesLive
    sb.add s.subs
    pd.add s.pending
  # A table indexed by a slot in a sixteen-slot pool cannot grow at all, so the
  # tolerance is zero and not a judgement call.
  trend("host patch rows", xs, pt, 0'i64, "", problems)
  trend("engine detour slots in use", xs, hu, 0'i64, "", problems)
  trend("GC handle table", xs, hl, 0'i64, "", problems)
  trend("GC handles held", xs, hv, 0'i64, "", problems)
  # And the same question asked of the runtime rather than of the host. A host
  # that reused a handle slot without freeing the GC handle behind it looks flat
  # above and climbs here.
  if gc.len > 0 and gc[0] >= 0'i64:
    trend("GC handles the runtime is holding", xs, gc, 0'i64, "", problems)
  trend("event subscribers", xs, sb, 0'i64, "", problems)
  # The queue moves for a living. What it must not do is trend upwards over
  # thousands of rounds, and a whole entry per thousand is already generous.
  trend("main-thread queue", xs, pd, 20'i64, "", problems)
  trend("OS handles", xs, ph, 0'i64, "", problems)
  # RSS is the catch-all and the noisiest: the allocator holds pages back and
  # the working set moves with whatever Windows feels like trimming.
  # Two tolerances, because they are two measurements. The working set moves
  # with whatever Windows is doing to the machine and is here because it is what
  # a player watches; private bytes only move when something is committed or
  # released, and that is the one a verdict should rest on.
  trend("process RSS", xs, rss, rssTol, " KB", problems)
  trend("process private bytes", xs, pv, privTol, " KB", problems)
  # The host's own heap, live rather than cumulative -- reported and not judged,
  # and the reason is the ABI rather than the measurement.
  #
  # `aowl_out_copy` allocates a reply with the *host's* allocator and the
  # receiver frees it with its own: that is the documented contract, it is what
  # every mod does through `aowl_host_release`, and the memory really is
  # reclaimed -- private bytes above stay flat across tens of thousands of them.
  # But mimalloc keeps its statistics per binary, so the free is counted against
  # the freeing module and the host's live figure climbs by every buffer it has
  # ever handed out. A verdict on this number would be a verdict on the ABI's
  # ownership rule. It is here because its *shape* still says something: growth
  # far above the size of the replies handed out would be the host holding
  # something.
  if lv.len > 0 and lv[0] >= 0'i64:
    let ls = slopePerK(secondHalf(xs), secondHalf(lv))
    line "      host live heap: " & $lv[0] & " -> " & $lv[lv.len - 1] &
         " B, slope " & $ls & " B/1000 cycles (buffers freed across the ABI " &
         "are counted against the freeing binary, so this over-reads)"

proc runChurn(root: string; cycles: int; frameThread: int): int =
  heading "Churn"
  var problems = 0

  if churnBind() == 0'i32:
    err "the host does not export the entry points a churn run drives"
    return 1
  ok "bound the host's own AowlHostApi entry points"

  if churnSubscribe() == 0'i32:
    err "the host refused a subscription"
    return 1

  if churnTargets() == 0'i32:
    err "could not take a live MovementContext and Player to call through"
    note "every compiled stand-in in the mock dereferences `this` without a " &
         "null check, so a firing loop must call on a real object"
    return 1
  ok "took the two instance handles the firing loops call through"

  # The bytes of a method that is about to be detoured a few thousand times.
  # `--churn` is the only thing in this repo that removes a detour more than
  # once, so this is the only place the restore can be checked repeatedly.
  var mc = "EFT.MovementContext"
  var st = "SetTilt"
  let haveBytes = churnSnapshot(toCString(mc), toCString(st)) == 1'i32
  if not haveBytes:
    warn "could not snapshot EFT.MovementContext::SetTilt; the byte-restore " &
         "check is skipped"

  let probe = joinPath(joinPath(joinPath(root, "mods"), "clientprobe"),
                       "clientprobe.dll")
  if not fileExists(probe):
    err "no clientprobe under " & root & "; there is nothing to cycle"
    return 1

  let base = takeSample(0)
  if base.patches < 0'i64:
    err "the host does not answer aowlspt.host::table_stats"
    note "the staged DLL is older than this harness; rebuild the host"
    return 1
  line "  at rest: " & $base.patches & " patch rows (" & $base.patchesLive &
       " live), " & $base.hookUsed & " engine slots in use, " &
       $base.handles & " handles, " & $base.subs & " subscribers, " &
       $base.mods & " mod rows"

  var liveBase = int(base.modsLive)
  # A mod's context index is its row in the loader's table, and the loader only
  # ever appends -- so the row a load will take is the row count just before it.
  # Read out of `listed` originally, which was wrong twice over: the reply
  # carried a dead row per earlier toggle, so the first match was a corpse, and
  # now that it does not, position and index no longer agree at all.
  var idx = modIndexOfGuid("aowl.clientprobe", 2000)
  if idx < 0:
    err "the host did not list aowl.clientprobe"
    return 1
  let listedAtStart = int(churnListedLen())

  var tiltTarget = mc & "::SetTilt"
  var aimTarget = mc & "::Aim"
  var hurtTarget = "EFT.Player::Hurt"
  var unloadVerb = "unload"
  var loadVerb = "load"
  var unloadBody = "{\"guid\":\"aowl.clientprobe\"}"
  var loadBody = "{\"guid\":\"aowl.clientprobe\",\"path\":\"" &
                 jsonPath(probe) & "\"}"

  churnSetNesting(1'i32)

  # -------------------------------------------------------------------------
  # Pass one: everything a mod does, with nothing coming or going
  # -------------------------------------------------------------------------
  #
  # Handles taken and released, patches firing with arguments and without,
  # events, timers, and the main-thread queue -- the paths a mod is on every
  # frame of a raid. Nothing is loaded or unloaded here, so every table that
  # moves in this pass moves because one of those paths did not give something
  # back.
  heading "Driving the mod-facing paths"
  if churnInstall(toCString(tiltTarget), 0x10'i32, 0'i32, int32(idx)) != 0'i32 or
     churnInstall(toCString(aimTarget), 0'i32, 1'i32, int32(idx)) != 0'i32 or
     churnInstall(toCString(hurtTarget), 0'i32, 1'i32, int32(idx)) != 0'i32:
    err "could not install the three patches the firing loops need (code " &
        $int(churnCounter(7'i32)) & ")"
    return 1
  ok "a JSON patch with arguments, and two typed ones, installed"

  var xsA: seq[int64] = @[]
  var samplesA: seq[Sample] = @[]
  var everyA = cycles div 20
  if everyA < 1: everyA = 1
  var c = 1
  while c <= cycles:
    churnHandles(10'i32)
    churnPins(1'i32)
    churnFireJson(20'i32)
    churnFireTyped(20'i32)
    churnEmitEvents(5'i32)
    churnQueue(8'i32)
    churnTimers(2'i32)
    # A millisecond a round, so the producer runs at about the rate a mod
    # queueing once a frame does. Without it the loop outruns a 120 Hz drain by
    # two orders of magnitude and the queue depth measures the overload rather
    # than anything the host is holding on to.
    harnessSleep(1'i32)
    if c mod everyA == 0:
      let s = takeSample(c)
      samplesA.add s
      xsA.add s.cycle
    inc c
  # The queue has to be empty before the last reading: a pending callback is a
  # row in a table, and sampling with the producer still ahead of the drain
  # measures the backlog rather than a leak.
  harnessSleep(1500'i32)
  let finalA = takeSample(cycles + 1)
  samplesA.add finalA
  xsA.add finalA.cycle
  line "  " & $cycles & " rounds: " & $(cycles * 11) & " handles taken and " &
       "released, " & $(cycles * 20) & " JSON firings, " & $(cycles * 40) &
       " typed, " & $(cycles * 25) & " callbacks queued"
  # The working set is judged loosely on purpose: it moves by a megabyte or two
  # across a run of this length for reasons that are not this process's, and
  # private bytes beside it is the number that only moves when something is
  # actually committed. A leak large enough to matter shows in both.
  reportTrends("the mod-facing paths", xsA, samplesA, 4096'i64, 256'i64,
               problems)

  # -------------------------------------------------------------------------
  # Pass two: a mod coming out and going back in
  # -------------------------------------------------------------------------
  #
  # Four detours installed and removed per round -- the mod's own plus the
  # three registered against its context -- which is the only path a detour is
  # ever removed on: the ABI has no `unpatch`.
  heading "Taking a mod out and putting it back"
  churnScanCommit()
  let commitBefore = churnCommitBytes()
  let regionsBefore = int(churnCommitRegions())
  var cyclesB = cycles div 4
  if cyclesB < 8: cyclesB = 8
  var xsB: seq[int64] = @[]
  var samplesB: seq[Sample] = @[]
  var everyB = cyclesB div 20
  if everyB < 1: everyB = 1
  var badRestore = 0
  var badUnload = 0
  var badLoad = 0
  var installFail = 0
  var b = 1
  while b <= cyclesB:
    churnEmitControl(toCString(unloadVerb), toCString(unloadBody))
    if not waitForLive(liveBase - 1, 3000):
      inc badUnload

    # Every detour the mod's context owned is out now, and the method's first
    # bytes are the game's again -- or they are not, which is a game jumping
    # into a trampoline that has been freed.
    if haveBytes and churnBytesRestored() != 1'i32:
      inc badRestore

    # The row the load is about to take.
    let before = numAfter(hostAsk("aowlspt.host::table_stats"), "mods")
    churnEmitControl(toCString(loadVerb), toCString(loadBody))
    if not waitForLive(liveBase, 3000):
      inc badLoad
    # `modsLive` moves before the mod's `on_load` has run, and `on_load` is
    # where a mod installs its own patches. Sampling in that window reads a
    # table mid-flight and reports the gap as a trend.
    harnessSleep(40'i32)
    idx = int(before)

    if churnInstall(toCString(tiltTarget), 0x10'i32, 0'i32, int32(idx)) != 0'i32:
      inc installFail
    if churnInstall(toCString(aimTarget), 0'i32, 1'i32, int32(idx)) != 0'i32:
      inc installFail
    if churnInstall(toCString(hurtTarget), 0'i32, 1'i32, int32(idx)) != 0'i32:
      inc installFail

    churnFireJson(5'i32)
    churnFireTyped(5'i32)

    if b mod everyB == 0:
      let s = takeSample(b)
      samplesB.add s
      xsB.add s.cycle
    inc b

  harnessSleep(500'i32)
  let finalB = takeSample(cyclesB + 1)
  samplesB.add finalB
  xsB.add finalB.cycle
  line "  " & $cyclesB & " load/unload cycles, " & $(cyclesB * 4) &
       " detours installed and removed over a pool of " &
       $numAfter(hostAsk("aowlspt.host::table_stats"), "hookCapacity") &
       " slots"
  # A kept mod row costs a few hundred bytes of strings and it is kept on
  # purpose, so this pass has a floor no fix will take away. Four kilobytes a
  # cycle is well above that and two orders of magnitude below the 32 MB an
  # unreleased allocator arena used to cost.
  reportTrends("a mod coming and going", xsB, samplesB, 4096'i64, 4096'i64,
               problems)

  # What the private-byte trend above is made of. A host table would be
  # kilobytes; this is the shape of whatever is actually being committed.
  churnScanCommit()
  let commitAfter = churnCommitBytes()
  let regionsAfter = int(churnCommitRegions())
  let grewKb = (commitAfter - commitBefore) div 1024'i64
  if grewKb > int64(cyclesB):
    heading "Where the committed memory went"
    line "  committed private space grew " & $grewKb & " KB over " & $cyclesB &
         " load/unload cycles (" & $(grewKb div int64(cyclesB)) &
         " KB a cycle), and the count of committed regions moved by " &
         $(regionsAfter - regionsBefore)
    line "  the largest committed private region is " &
         $(churnCommitBiggest() div 1024'i64) & " KB, and there are " &
         $int(churnCommitBiggestN()) & " of that size"
    note "no host table moved across those cycles, and the host's own live " &
         "heap moved by less than a kilobyte a cycle. A run of identically " &
         "sized multi-megabyte regions, one per load, is an allocator arena " &
         "belonging to the mod binary: every nimony library links its own " &
         "mimalloc, and FreeLibrary unmaps the image without giving that back"

  # The manager's own reply. It is not a host table and no host counter sees
  # it, but it is built out of one -- and it grew by a row per toggle until
  # `listedRowFor` cut it back to one row per guid.
  discard modIndexOfGuid("aowl.clientprobe", 2000)
  let listedNow = int(churnListedLen())
  if listedNow > listedAtStart * 2 + 64:
    err "the manager's `listed` reply grew from " & $listedAtStart & " to " &
        $listedNow & " bytes over " & $cyclesB & " toggles"
    inc problems
  else:
    ok "the manager's `listed` reply stayed at " & $listedNow &
       " bytes across " & $cyclesB & " toggles"

  heading "Growing by design"
  var md: seq[int64] = @[]
  var ac: seq[int64] = @[]
  for s in samplesB:
    md.add s.mods
  for s in samplesA:
    ac.add s.allocCount
  let modSlope = slopePerK(xsB, md)
  line "  mod rows: " & $md[0] & " -> " & $md[md.len - 1] & ", slope " &
       $modSlope & "/1000 cycles"
  note "one row per load, and it is kept rather than compacted: a context " &
       "pointer is an index, so removing a dead row would repoint every live " &
       "mod at its neighbour"
  let allocSlope = slopePerK(xsA, ac)
  line "  host allocator blocks: " & $ac[0] & " -> " & $ac[ac.len - 1] &
       ", slope " & $allocSlope & "/1000 cycles"
  note "mimalloc's cumulative block count; nothing on the free path lowers " &
       "it, so this grows in any run that allocates at all and is here to " &
       "prove the counter moves rather than to be flat"
  if allocSlope <= 0'i64:
    err "the host's allocation counter did not move, so nothing above " &
        "measured the host's allocator"
    inc problems

  churnSetNesting(0'i32)

  # The pool of typed frames is indexed by patch depth, and everything above
  # nested exactly one level. This is the other end of it: let the handler recur
  # until the pool runs out, and check that the host does the documented thing
  # -- lets the original run, counts it, and comes back holding nothing.
  heading "The typed frame pool, overrun on purpose"
  let beforeDeep = hostAsk("aowlspt.host::patch_stats")
  let deepWas = numAfter(beforeDeep, "typedTooDeep")
  let handlesWas = numAfter(hostAsk("aowlspt.host::table_stats"), "handles")
  if deepWas > 0'i64:
    err "a typed firing outran the frame pool during ordinary churn, so a " &
        "mod was not called"
    inc problems
  else:
    ok "no typed firing outran the pool while nesting one level deep"
  churnSetNesting(2'i32)
  churnFireTyped(50'i32)
  churnSetNesting(0'i32)
  let afterDeep = hostAsk("aowlspt.host::patch_stats")
  let handlesNow = numAfter(hostAsk("aowlspt.host::table_stats"), "handles")
  if numAfter(afterDeep, "typedTooDeep") <= deepWas:
    warn "unbounded nesting never reached the bottom of the frame pool; " &
         "the depth guard was not exercised"
  else:
    ok "past the pool the host let the original run and counted it (" &
       $numAfter(afterDeep, "typedTooDeep") & " firings deeper than " &
       $numAfter(afterDeep, "frameDepth") & ")"
  if handlesNow != handlesWas:
    err "overrunning the frame pool left the handle table at " & $handlesNow &
        " where it was " & $handlesWas
    inc problems
  else:
    ok "the handle table came back to where it was"

  # The queue with nobody draining it. The drain hook is on a method the mock's
  # frame loop calls, so stopping that loop is exactly what happens when a hook
  # bound to a raid-only method outlives the raid.
  heading "The drain stalling and coming back"
  if churnHaveFramePause() == 0'i32:
    warn "this stand-in runtime has no mock_frame_pause; the stall is not " &
         "exercised"
  elif frameThread <= 0:
    warn "no frame loop, so there is nothing to stall"
  else:
    churnFramePause(1'i32)
    churnQueue(200'i32)
    harnessSleep(3000'i32)
    let stalled = hostAsk("aowlspt.host::table_stats")
    let mid = numAfter(stalled, "pending")
    let mainThread = hostAsk("aowlspt.host::main_thread")
    if find(mainThread, "\"stalled\":true") < 0:
      err "the host did not notice the drain had stopped firing"
      inc problems
    else:
      ok "the host noticed the drain had gone quiet and took the queue back"
    if mid > 0'i64:
      err "the queue still held " & $mid & " callbacks after the host " &
          "took it back"
      inc problems
    else:
      ok "the host thread drained the queue while the hook was quiet"
    churnFramePause(0'i32)
    churnQueue(200'i32)
    harnessSleep(1500'i32)
    let back = hostAsk("aowlspt.host::main_thread")
    if find(back, "\"stalled\":false") < 0:
      err "the drain never came back"
      inc problems
    else:
      ok "the drain came back and the host thread stood down"

  heading "What was driven"
  line "  " & $int(churnCounter(0'i32)) & " JSON patch firings, " &
       $int(churnCounter(1'i32)) & " typed, " &
       $int(churnCounter(8'i32)) & " of them nested inside a typed handler"
  line "  " & $int(churnCounter(2'i32)) & " events delivered, " &
       $int(churnCounter(3'i32)) & " main-thread callbacks run"
  let stats = hostAsk("aowlspt.host::patch_stats")
  line "  the host's own account: " & stats
  line "  its tables now: " & hostAsk("aowlspt.host::table_stats")

  heading "Result"
  if int(churnCounter(4'i32)) > 0:
    err $int(churnCounter(4'i32)) & " resolve calls failed"
    inc problems
  if int(churnCounter(5'i32)) > 0:
    err $int(churnCounter(5'i32)) & " handle/pin round trips failed"
    inc problems
  if installFail > 0:
    err $installFail & " patch installs were refused (last code " &
        $int(churnCounter(7'i32)) & ")"
    note "a detour slot the host does not give back is the usual reason: " &
         "there are only sixteen of them"
    inc problems
  else:
    ok $(cyclesB * 4) & " detours installed and removed, every one of them " &
       "into a reclaimed slot after the first few"
  if badRestore > 0:
    err $badRestore & " of " & $cyclesB & " removals left the method's " &
        "original bytes overwritten"
    inc problems
  elif haveBytes:
    ok "the method's original bytes were restored on all " & $cyclesB &
       " removals"
  if badUnload > 0 or badLoad > 0:
    err $badUnload & " unloads and " & $badLoad & " loads did not complete"
    inc problems
  else:
    ok $cyclesB & " load/unload cycles completed"

  if problems > 0:
    err $problems & " problem(s)"
    return 1
  ok "nothing grew with the cycle count"
  # The honest size of the claim. A flat trend over a hundred rounds is worth
  # much less than a flat trend over two thousand, and the difference is a
  # command-line argument rather than anything to reason about.
  if cycles < 2000:
    note "this run did " & $cycles & " rounds of the mod-facing paths and " &
         $cyclesB & " load/unload cycles, which is enough to show every " &
         "trend flat and not enough to be a claim about a session; " &
         "--churn 2000 is about a minute and a half"
  else:
    note "over " & $cycles & " rounds and " & $cyclesB &
         " load/unload cycles, which is more churn than a session of the " &
         "game will produce"
  result = 0


proc main(): int =
  var dir = ""
  var seconds = 8
  var injectTarget = ""
  var runtimeDll = ""
  var sleepFor = -1
  var churnCycles = 0
  var frameBenchIters = 0
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--seconds":
      inc i
      if i <= n: discard parseCount(paramStr(i), seconds)
    elif a == "--inject":
      inc i
      if i <= n: injectTarget = paramStr(i)
    elif a == "--runtime":
      inc i
      if i <= n: runtimeDll = paramStr(i)
    elif a == "--sleep":
      inc i
      if i <= n: discard parseCount(paramStr(i), sleepFor)
    elif a == "--churn":
      inc i
      if i <= n: discard parseCount(paramStr(i), churnCycles)
    elif a == "--frame-bench":
      inc i
      frameBenchIters = 20000
      if i <= n: discard parseCount(paramStr(i), frameBenchIters)
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    elif dir.len == 0:
      dir = a
    inc i

  # Target mode: do nothing but stay alive long enough to be injected into.
  if sleepFor >= 0:
    harnessSleep(int32(sleepFor * 1000))
    return 0

  if dir.len == 0:
    echo Usage
    return 1

  let root = absolutePathOf(dir)
  let hostDll = joinPath(root, "aowlspt-host-il2cpp.dll")
  let logPath = joinPath(root, "aowlspt-host.log")

  heading "Harness"
  line "  host   " & hostDll
  if not fileExists(hostDll):
    err "no host DLL there"
    return 1

  let modsDir = joinPath(root, "mods")
  if isDirectory(modsDir):
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(modsDir, files, dirs)
    var count = 0
    for f in files:
      if endsWith(toLowerAscii(f), ".dll"):
        inc count
        line "  mod    " & f
    if count == 0:
      warn "no mod libraries under " & modsDir
  else:
    warn "no mods directory at " & modsDir

  # A stale log would make a host that never started look like one that did.
  discard removeFileAt(logPath)

  if injectTarget.len > 0:
    return runInjection(hostDll, logPath, absolutePathOf(injectTarget), seconds)

  # The runtime goes in before the host, but stays un-started: the host must
  # find the module and then wait for a domain, which is the same window the
  # game has between process start and IL2CPP coming up.
  var haveRuntime = false
  if runtimeDll.len > 0:
    heading "Mock runtime"
    var r = absolutePathOf(runtimeDll)
    line "  " & r
    if not fileExists(r):
      err "no such runtime"
      return 1
    if rtLoad(toCString(r)) == 0'i32:
      err "could not load it (error " & $int(harnessError()) & ")"
      return 1
    ok "loaded, not yet started"
    haveRuntime = true

  heading "Loading"
  var p = hostDll
  let h = harnessLoad(toCString(p))
  if h == nil:
    err "LoadLibrary failed (error " & $int(harnessError()) & ")"
    return 1
  ok "host loaded; the constructor should have started its thread"

  if haveRuntime:
    harnessSleep(1500'i32)
    if rtInit() == 0'i32:
      err "the mock runtime would not start"
      return 1
    ok "mock runtime started; the host should pick it up on its next poll"

  if frameBenchIters > 0:
    if not haveRuntime:
      err "--frame-bench needs --runtime: without one nothing detours a " &
          "per-frame method, so the drain never reaches the game's thread " &
          "and there is no frame to measure"
      return 1
    # Long enough for the runtime poll, the drain bind and the mods to settle.
    harnessSleep(6000'i32)
    return benchTable(root, frameBenchIters)

  if churnCycles > 0:
    if not haveRuntime:
      err "--churn needs --runtime: there is nothing to resolve, call or " &
          "patch without one"
      return 1
    # Long enough for the runtime poll, the drain bind and the mods, and no
    # longer: everything after this point is driven rather than waited for.
    harnessSleep(4000'i32)
    return runChurn(root, churnCycles, int(rtFrameThread()))

  line "  running for " & $seconds & "s"
  harnessSleep(int32(seconds * 1000))

  var frameThread = 0
  if haveRuntime:
    frameThread = int(rtFrameThread())
    if frameThread > 0:
      heading "Frame loop"
      line "  the mock ran " & $int(rtFrameCount()) &
           " frames on thread " & $frameThread

  # What a hook is handed, read from inside a handler rather than from a log.
  # It goes here, while the host is loaded and the runtime is up, and its
  # verdicts are printed with everything else under `Result`.
  if haveRuntime:
    probeArgPayloads()

  # Both subjects, not one. `haveProbe` gates the resolve/call/patch block on
  # `clientprobe`; a stage carrying that but not `highlevel` used to reach the
  # assertions and fail them, which reads as a broken host rather than a stage
  # that was never asked the question.
  let haveProbe = isDirectory(joinPath(modsDir, "clientprobe"))
  let haveHigh = isDirectory(joinPath(modsDir, "highlevel"))
  if haveProbe and not haveHigh:
    note "this stage has clientprobe but no highlevel in it. Fifteen of the " &
         "assertions below are matched against lines highlevel prints -- " &
         "enums, the static fields, the write barrier, everyMain, slot reuse " &
         "-- so they are about to fail as a statement about the stage. Copy " &
         "examples\\highlevel\\bin\\highlevel.dll into mods\\highlevel."
  result = checkLog(logPath, haveRuntime, frameThread, haveProbe)

quit(main())
