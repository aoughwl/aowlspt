/* racemod -- a mod that exists to be unloaded while it is answering.
 *
 *   gcc -O1 -shared -I../abi -o bin/racemod.dll racemod.c
 *
 * `backend/modrace.nim` is the test; this is the thing it takes away from its
 * own workers. Nothing here is interesting on its own, and everything here is
 * shaped to make the failure it is hunting *visible* rather than merely fatal:
 *
 *  * **The handler stays inside the image for a while.** It spins over a table
 *    in the library's own data section and calls a function in the library's
 *    own text, so a thread that is in the handler when `FreeLibrary` lands is
 *    reading and executing pages that have just been unmapped. A handler that
 *    returned a constant would be gone from the image before the unload could
 *    reach it, and the window this exists to open would be closed by accident.
 *
 *  * **The answer names the incarnation.** `AOWL_RACEMOD_GEN` is read at
 *    `init` and quoted in every response. `LoadLibrary` of a path that was
 *    just freed maps the image at the same base address, so a call that
 *    arrives late does not necessarily fault -- it can land in the *next*
 *    incarnation's live code and answer perfectly, with the wrong generation.
 *    That is the failure a survival test cannot see, and it is the reason the
 *    generation is in the text of the reply rather than only in the log.
 */

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "aowlspt_abi.h"

static const AowlHostApi* g_host = NULL;
static char g_gen[32] = "0";
static int32_t g_genLen = 1;

/* Read on every call, in the image's own data section: an unmapped page here
 * faults exactly as an unmapped instruction does, and this half of it is the
 * one a compiler cannot inline away. */
#define RACEMOD_TABLE 4096
static volatile uint32_t g_table[RACEMOD_TABLE];

/* How long one handler stays inside the library, in units of one pass over the
 * table. A route handler in the real server costs about 423 us; this is set
 * from the host through the environment so the test can widen or narrow the
 * window without a rebuild. */
static uint32_t g_passes = 24;

/* A handler that does not come back for a while, which is the case the drain
 * has a deadline for. It is an absolute moment rather than a duration per call
 * on purpose: every caller that arrives before it waits until it and no
 * longer, so the mod is wedged for exactly one window and answers normally
 * afterwards -- which is what lets the test check both halves, the unload that
 * is refused and the unload that then succeeds. */
static ULONGLONG g_wedge_until = 0;

static AowlSlice slice_of(const char* s) {
    AowlSlice v;
    v.ptr = (const uint8_t*)s;
    v.len = (int32_t)strlen(s);
    return v;
}

/* Deliberately not `static inline`: the handler must make a real call through
 * the image's text on every pass. */
__attribute__((noinline))
static uint32_t racemod_mix(uint32_t x) {
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return x;
}

static AowlStatus AOWLSPT_CALL race_route(void* user, AowlSlice url,
                                          AowlSlice body, AowlSlice session,
                                          AowlBuffer* out) {
    (void)body; (void)session;
    if (g_wedge_until) {
        ULONGLONG now = GetTickCount64();
        if (now < g_wedge_until) Sleep((DWORD)(g_wedge_until - now));
    }
    uint32_t acc = 1u;
    for (uint32_t p = 0; p < g_passes; p++) {
        for (int i = 0; i < RACEMOD_TABLE; i++) {
            acc = racemod_mix(acc ^ g_table[i]);
        }
    }

    /* The answer, and the whole of what the test checks: the generation this
     * incarnation was loaded as, the url it was asked for, and a checksum the
     * caller can verify was computed by code that was still there. */
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "{\"mod\":\"racemod\",\"gen\":%s,\"url\":\"%.*s\","
                     "\"acc\":%u}",
                     g_gen, (int)url.len, (const char*)url.ptr,
                     (unsigned)(acc | 1u));
    if (n < 0) return AOWLSPT_ERR_GENERIC;
    if (!g_host) return AOWLSPT_ERR_GENERIC;
    void* p = g_host->alloc(g_host->ctx, n);
    if (!p) return AOWLSPT_ERR_GENERIC;
    memcpy(p, buf, (size_t)n);
    out->ptr = (uint8_t*)p;
    out->len = n;
    (void)user;
    return AOWLSPT_OK;
}

static AowlStatus AOWLSPT_CALL race_on_load(void* self) {
    (void)self;
    if (!g_host) return AOWLSPT_ERR_GENERIC;
    return g_host->route_register(g_host->ctx, slice_of("/race/hit"),
                                  AOWLSPT_ROUTE_STATIC, race_route, NULL);
}

static AowlStatus AOWLSPT_CALL race_on_unload(void* self) {
    (void)self;
    return AOWLSPT_OK;
}

AOWLSPT_EXPORT uint32_t AOWLSPT_CALL aowlspt_abi_version(void) {
    return AOWLSPT_ABI_VERSION;
}

AOWLSPT_EXPORT AowlStatus AOWLSPT_CALL aowlspt_describe(AowlModInfo* out) {
    if (!out) return AOWLSPT_ERR_BAD_ARG;
    out->abi_version = AOWLSPT_ABI_VERSION;
    out->abi_revision = AOWLSPT_ABI_REVISION;
    out->guid = slice_of("aowl.racemod");
    out->name = slice_of("racemod");
    out->author = slice_of("aowlspt");
    out->version = slice_of("1.0.0");
    out->spt_range = slice_of("*");
    out->sides = (1u << AOWLSPT_SIDE_SERVER) |
                 (1u << AOWLSPT_SIDE_CLIENT) |
                 (1u << AOWLSPT_SIDE_SIM);
    out->flags = AOWLSPT_MOD_THREAD_SAFE;
    return AOWLSPT_OK;
}

AOWLSPT_EXPORT AowlStatus AOWLSPT_CALL aowlspt_init(const AowlHostApi* host,
                                                    AowlModApi* out) {
    if (!host || !out) return AOWLSPT_ERR_BAD_ARG;
    g_host = host;

    char env[32];
    DWORD n = GetEnvironmentVariableA("AOWL_RACEMOD_GEN", env, sizeof(env));
    if (n > 0 && n < sizeof(env)) {
        memcpy(g_gen, env, n + 1);
        g_genLen = (int32_t)n;
    }
    char pass[32];
    n = GetEnvironmentVariableA("AOWL_RACEMOD_PASSES", pass, sizeof(pass));
    if (n > 0 && n < sizeof(pass)) {
        uint32_t v = (uint32_t)strtoul(pass, NULL, 10);
        if (v > 0) g_passes = v;
    }

    char wedge[32];
    n = GetEnvironmentVariableA("AOWL_RACEMOD_WEDGE_MS", wedge, sizeof(wedge));
    if (n > 0 && n < sizeof(wedge)) {
        unsigned long ms = strtoul(wedge, NULL, 10);
        if (ms > 0) g_wedge_until = GetTickCount64() + (ULONGLONG)ms;
    }

    for (int i = 0; i < RACEMOD_TABLE; i++) {
        g_table[i] = (uint32_t)(i * 2654435761u);
    }

    out->self = NULL;
    out->on_load = race_on_load;
    out->on_update = NULL;
    out->on_unload = race_on_unload;
    out->state_save = NULL;
    out->state_load = NULL;
    return AOWLSPT_OK;
}
