/* aowlspt_profile.h -- the per-mod / per-rider PROFILER's shared surface.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
 * ---------------------------------------------------------------------------
 *
 * The feature request was "ModProfiler, but for aowlspt": see which mod is
 * costing frame time. ModProfiler is a BepInEx/Mono tool -- it enumerates
 * loaded plugins by reflection and wraps their MonoBehaviour.Update with a
 * Harmony patch. NONE of that exists on this build: there is no Mono, no
 * BepInEx, and IL2CPP reflection FAULTS here (fact: il2cpp_object_get_class,
 * il2cpp_class_get_name, il2cpp_value_box and field iteration all fault).
 *
 * So this is not a port. It is the same IDEA reached by the only route this
 * architecture leaves open: **aowlspt already funnels every mod's and every
 * host feature's per-frame work through a small number of dispatch points that
 * we own the source of.** Instrumenting those is a pure-native, zero-reflection,
 * zero-by-name-lookup operation. Nothing in this file resolves an IL2CPP name,
 * calls a game method, or patches a byte of game code. It cannot: it is a
 * counter, a QueryPerformanceCounter pair, and a shared page.
 *
 * That matters for fact #145 -- on this build EVERY by-NAME IL2CPP route is
 * fatal the moment it is USED. This header has no such route to be fatal.
 *
 * The three dispatch points instrumented, and who owns them:
 *
 *   host/common/modhost.nim  `tickMods`      -> one slot per MOD (kind=MOD)
 *   host/Aowlspt.Host.Il2Cpp/aowlhost.nim
 *                            `patchFired` /
 *                            `patchReturned` -> one slot per HOST RIDER (RIDER)
 *   this header               frame boundary -> the frame-time histogram
 *
 * Backend ROUTE timing is deliberately NOT here. Another agent owns backend
 * route timing this session and two owners of one measurement is how a number
 * ends up meaning neither thing. `AOWL_PROF_KIND_ROUTE` is reserved so that
 * work can land without a version bump; nothing writes it today, and the mod
 * reports route cost as UNMEASURED rather than as zero.
 *
 * ---------------------------------------------------------------------------
 * THE MEASUREMENT, AND ITS HONEST ERROR BARS
 * ---------------------------------------------------------------------------
 *
 * Clock: QueryPerformanceCounter. On every machine this project runs on that is
 * the invariant TSC via the HPET-free fast path -- sub-100ns resolution, no
 * syscall. `QueryPerformanceFrequency` is read ONCE at init, not per sample.
 *
 * Overhead: a begin/end pair is two QPC calls plus two adds. That is NOT free
 * and it is NOT subtracted. Subtracting an overhead estimate from a number you
 * then read back is a self-comparison -- exactly the "verification that cannot
 * fail" shape this project has lost days to. Instead `aowl_prof_calibrate()`
 * times 4096 EMPTY scopes once at startup and publishes the per-scope cost in
 * `overheadNs`, so a reader can judge whether a 0.004 ms slot is real. A slot
 * whose reported cost is within 3x of `overheadNs` is reported by the mod as
 * "at the noise floor", never as a measurement.
 *
 * Attribution: a scope measures WALL time between two points on one thread,
 * so it includes any preemption the OS did in the middle. Over a rolling window
 * of frames that is what you want (a mod that gets descheduled IS costing you
 * frame time), but a single-frame max is not evidence of a mod being slow.
 * Both are published; the mod labels them differently.
 *
 * Nesting: scopes are NOT nested by this design. Each dispatch point wraps one
 * leaf call. If a mod's on_update itself calls another mod, the inner cost is
 * attributed to the outer mod, and that is stated rather than corrected.
 *
 * ---------------------------------------------------------------------------
 * WHY THERE IS NO ALLOCATION ANYWHERE ON THIS PATH
 * ---------------------------------------------------------------------------
 *
 * A profiler that allocates per frame changes the thing it measures. So:
 *
 *   * the region is ONE fixed-size POD struct in a named file mapping, mapped
 *     once per process and leaked on purpose;
 *   * slot names are fixed `char[32]` written ONCE at registration, by
 *     `aowl_prof_slot`, which is called from a `once` guard and never per frame;
 *   * the frame-time history is a fixed ring of 512 `uint32` microsecond
 *     samples, overwritten in place;
 *   * percentiles are computed into a 512-entry stack array by an insertion-free
 *     counting pass, and ONLY when a reader asks -- never per frame;
 *   * the render path formats into caller-provided fixed buffers; this header
 *     never calls malloc, never touches the managed heap, and never calls
 *     il2cpp_string_new.
 *
 * When `enabled` is 0, `aowl_prof_begin` is one relaxed volatile LONG load and
 * a return. That is the shipped default.
 *
 * ---------------------------------------------------------------------------
 * SAFETY
 * ---------------------------------------------------------------------------
 *
 * There is no pointer walk here to guard: the only pointer is the region, which
 * this file created, and every entry point returns immediately on NULL or on a
 * bad magic. There is no game memory read, so no VirtualQuery is needed and
 * adding one would be theatre. There is NO seh guard here EITHER -- and that is
 * deliberate: the callers (`patchFired`, `tickMods`) already run inside exactly
 * one `aowl_p_p_seh` and that guard is NOT re-entrant, so a nested guard here
 * would DISARM the outer one. This file is written so that it cannot fault:
 * every index is bounds-checked against a compile-time constant before use.
 *
 * Self-disable: `faults` counts refusals (slot table full, bad index, clock
 * went backwards). At `AOWL_PROF_FAULT_LIMIT` the profiler clears `enabled`
 * itself and sets `disabledReason`, and nothing turns it back on but a restart
 * or an explicit write from the mod.
 */
#ifndef AOWLSPT_PROFILE_H
#define AOWLSPT_PROFILE_H

#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

#define AOWL_PROF_REGION_NAME  "Local\\aowlspt_profile_shared_v1"
#define AOWL_PROF_MAGIC        0x414F574C50524F31ull   /* "AOWLPRO1" */
#define AOWL_PROF_VERSION      1

#define AOWL_PROF_MAX_SLOTS    64
#define AOWL_PROF_NAME_LEN     32
#define AOWL_PROF_RING         512     /* frame-time samples in the window     */
#define AOWL_PROF_FAULT_LIMIT  32
#define AOWL_PROF_REASON_LEN   160

/* Slot kinds. ROUTE is reserved and unwritten -- see the note above. */
enum {
    AOWL_PROF_KIND_FREE  = 0,
    AOWL_PROF_KIND_MOD   = 1,   /* a mod's on_update, from tickMods           */
    AOWL_PROF_KIND_RIDER = 2,   /* a host rider on the shared Update detour   */
    AOWL_PROF_KIND_ROUTE = 3,   /* RESERVED: backend route. Nothing writes it. */
    AOWL_PROF_KIND_OTHER = 4
};

static const char* aowl_prof_kind_name(int32_t k) {
    switch (k) {
        case AOWL_PROF_KIND_MOD:   return "mod";
        case AOWL_PROF_KIND_RIDER: return "host";
        case AOWL_PROF_KIND_ROUTE: return "route";
        case AOWL_PROF_KIND_OTHER: return "other";
        default:                   return "free";
    }
}

typedef struct AowlProfSlot {
    volatile LONG   kind;                       /* AOWL_PROF_KIND_*           */
    char            name[AOWL_PROF_NAME_LEN];   /* NUL-terminated, write-once */

    /* Accumulated over the CURRENT window. `aowl_prof_roll` moves these into
     * the `last*` members and zeroes them, so a reader never sees a half-built
     * window and never has to subtract two samples itself. */
    volatile LONG64 calls;
    volatile LONG64 ns;
    volatile LONG64 maxNs;

    /* The last COMPLETE window. This is what the panel draws. */
    volatile LONG64 lastCalls;
    volatile LONG64 lastNs;
    volatile LONG64 lastMaxNs;

    /* Lifetime, never rolled -- so "this mod has cost 4.1 seconds since boot"
     * is answerable, which a rolling window alone cannot do. */
    volatile LONG64 totalCalls;
    volatile LONG64 totalNs;

    /* Scratch for an in-flight scope. One writer per slot by construction: a
     * mod tick and a rider both run on one thread inside one dispatch point.
     * `depth` catches a re-entrant begin (which would corrupt `t0`) and makes
     * it a refusal instead. */
    volatile LONG64 t0;
    volatile LONG   depth;
} AowlProfSlot;

typedef struct AowlProfShared {
    uint64_t      magic;
    uint32_t      version;
    uint32_t      pad0;

    /* MOD-OWNED. 0 is the shipped default and makes every hot entry point a
     * single load and a return. */
    volatile LONG enabled;
    /* Overlay-owned: whether the profiler panel is on screen. */
    volatile LONG panelOpen;

    volatile LONG faults;
    volatile LONG selfDisabled;
    char          disabledReason[AOWL_PROF_REASON_LEN];

    /* Clock. Written once by aowl_prof_map; 0 means QPF refused, in which case
     * every timing entry point becomes a no-op and says so. */
    volatile LONG64 qpf;
    volatile LONG64 overheadNs;     /* measured cost of ONE begin/end pair    */
    volatile LONG   calibrated;

    /* Frame-time ring, microseconds. `frames` is the total frame count, so
     * `frames % AOWL_PROF_RING` is the next write index. */
    volatile LONG64 frames;
    volatile LONG64 frameT0;
    uint32_t        ring[AOWL_PROF_RING];

    /* The last complete window's frame stats, in microseconds. */
    volatile LONG64 winFrames;
    volatile LONG64 winNs;          /* wall ns accumulating in THIS window    */
    volatile LONG64 lastWinNs;      /* wall ns of the last COMPLETE window    */
    uint32_t        wMin, wMax, wP50, wP95, wP99, wMean;

    /* How many frames make a window. 0 falls back to 120. */
    volatile LONG windowFrames;

    /* Whether anything has ever called `aowl_prof_frame` -- i.e. whether the
     * client host's shared Update rider chain is live in this process. The
     * backend and the simulator have no such chain, so their windows are
     * rolled by `aowl_prof_tick_boundary` instead and the frame-time
     * histogram is MEANINGLESS there. This flag is what lets a reader tell
     * "0.00 ms frame time" (a lie) from "there is no frame source" (the
     * truth), and it is why the two boundaries are separate functions rather
     * than one function with a comment. */
    volatile LONG frameSourceLive;

    AowlProfSlot  slots[AOWL_PROF_MAX_SLOTS];

    volatile LONG heartbeat;
} AowlProfShared;

/* ------------------------------------------------------------------ *
 * Mapping. Every side calls this; first creates, rest open. The handle is
 * leaked on purpose -- it lives for the process. NULL only if the OS refused,
 * which makes every entry point below a no-op rather than a crash.
 * ------------------------------------------------------------------ */
static AowlProfShared* aowl_prof_map(void) {
    HANDLE h = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
                                  (DWORD)sizeof(AowlProfShared),
                                  AOWL_PROF_REGION_NAME);
    AowlProfShared* s;
    if (!h) return NULL;
    s = (AowlProfShared*)MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0,
                                       sizeof(AowlProfShared));
    if (!s) return NULL;
    if (s->magic != AOWL_PROF_MAGIC) {
        /* First mapper initialises. A racing second mapper sees a zeroed page
         * and would also initialise -- harmless, both write the same constants,
         * and every counter it could clobber is zero at that moment anyway. */
        LARGE_INTEGER f;
        s->version = AOWL_PROF_VERSION;
        s->enabled = 0;                 /* rule 5: default OFF */
        s->panelOpen = 0;
        s->windowFrames = 120;
        s->qpf = QueryPerformanceFrequency(&f) ? (LONG64)f.QuadPart : 0;
        s->magic = AOWL_PROF_MAGIC;
    }
    return s;
}

/* The one global this header keeps. Each translation unit that includes the
 * header gets its OWN copy of this pointer -- which is correct, because they
 * are separate DLLs; what they share is the mapping, not the variable. */
static AowlProfShared* g_prof = NULL;

static AowlProfShared* aowl_prof_get(void) {
    if (!g_prof) g_prof = aowl_prof_map();
    if (g_prof && g_prof->magic != AOWL_PROF_MAGIC) return NULL;
    return g_prof;
}

static void aowl_prof_fault(AowlProfShared* s, const char* why) {
    LONG n;
    if (!s) return;
    n = InterlockedIncrement(&s->faults);
    if (n == AOWL_PROF_FAULT_LIMIT && !s->selfDisabled) {
        s->selfDisabled = 1;
        s->enabled = 0;
        s->disabledReason[0] = 0;
        strncpy(s->disabledReason, why ? why : "unstated",
                AOWL_PROF_REASON_LEN - 1);
        s->disabledReason[AOWL_PROF_REASON_LEN - 1] = 0;
    }
}

static LONG64 aowl_prof_now(void) {
    LARGE_INTEGER c;
    if (!QueryPerformanceCounter(&c)) return 0;
    return (LONG64)c.QuadPart;
}

static LONG64 aowl_prof_ticks_to_ns(AowlProfShared* s, LONG64 ticks) {
    LONG64 f;
    if (!s) return 0;
    f = s->qpf;
    if (f <= 0) return 0;
    /* 1e9 * ticks overflows int64 at ~9.2 seconds of ticks on a 1e9 QPF, so
     * split: whole seconds first, remainder scaled. No floating point on the
     * hot path. */
    return (ticks / f) * 1000000000ll + ((ticks % f) * 1000000000ll) / f;
}

/* ------------------------------------------------------------------ *
 * Slot registration. Called from a `once` guard, NEVER per frame.
 * Returns the slot index, or -1 (refused, and counted as a fault) when the
 * table is full. -1 is a legal argument to begin/end, which ignore it, so a
 * refusal degrades to "this thing is not profiled" and never to a crash.
 * ------------------------------------------------------------------ */
static int32_t aowl_prof_slot(const char* name, int32_t kind) {
    AowlProfShared* s = aowl_prof_get();
    int32_t i;
    if (!s || !name || !*name) return -1;
    /* Idempotent: the same name always resolves to the same slot, so a caller
     * that lost its index (a mod reloaded, a rider re-armed) re-registers
     * without splitting its own history in two. */
    for (i = 0; i < AOWL_PROF_MAX_SLOTS; i++) {
        if (s->slots[i].kind != AOWL_PROF_KIND_FREE &&
            strncmp(s->slots[i].name, name, AOWL_PROF_NAME_LEN - 1) == 0)
            return i;
    }
    for (i = 0; i < AOWL_PROF_MAX_SLOTS; i++) {
        if (InterlockedCompareExchange(&s->slots[i].kind, kind,
                                       AOWL_PROF_KIND_FREE) ==
            AOWL_PROF_KIND_FREE) {
            memset(s->slots[i].name, 0, AOWL_PROF_NAME_LEN);
            strncpy(s->slots[i].name, name, AOWL_PROF_NAME_LEN - 1);
            return i;
        }
    }
    aowl_prof_fault(s, "slot table full: more than 64 profiled scopes");
    return -1;
}

/* ------------------------------------------------------------------ *
 * The hot path. When the profiler is off this is: one load, one compare, one
 * return. That is the shipped state.
 * ------------------------------------------------------------------ */
static void aowl_prof_begin(int32_t slot) {
    AowlProfShared* s = g_prof;
    if (!s || !s->enabled) return;
    if (slot < 0 || slot >= AOWL_PROF_MAX_SLOTS) return;
    if (InterlockedIncrement(&s->slots[slot].depth) != 1) {
        /* Re-entered. `t0` belongs to the outer scope; leave it alone and let
         * the matching end() discard this one. */
        return;
    }
    s->slots[slot].t0 = aowl_prof_now();
}

static void aowl_prof_end(int32_t slot) {
    AowlProfShared* s = g_prof;
    LONG64 t1, d;
    LONG depth;
    if (!s || !s->enabled) return;
    if (slot < 0 || slot >= AOWL_PROF_MAX_SLOTS) return;
    depth = InterlockedDecrement(&s->slots[slot].depth);
    if (depth != 0) return;                 /* inner scope of a re-entry */
    t1 = aowl_prof_now();
    if (t1 == 0 || s->slots[slot].t0 == 0) return;
    d = t1 - s->slots[slot].t0;
    if (d < 0) { aowl_prof_fault(s, "QueryPerformanceCounter went backwards"); return; }
    d = aowl_prof_ticks_to_ns(s, d);
    s->slots[slot].calls++;
    s->slots[slot].ns += d;
    s->slots[slot].totalCalls++;
    s->slots[slot].totalNs += d;
    if (d > s->slots[slot].maxNs) s->slots[slot].maxNs = d;
}

/* ------------------------------------------------------------------ *
 * Percentiles over the ring. Called at most once per window (i.e. ~twice a
 * second at the default 120-frame window), NEVER per frame, and it sorts into
 * a stack buffer -- no allocation.
 * ------------------------------------------------------------------ */
static void aowl_prof_percentiles(AowlProfShared* s, int32_t n) {
    uint32_t tmp[AOWL_PROF_RING];
    int32_t i, j;
    uint64_t sum = 0;
    uint32_t k;
    if (!s || n <= 0) return;
    if (n > AOWL_PROF_RING) n = AOWL_PROF_RING;
    for (i = 0; i < n; i++) { tmp[i] = s->ring[i]; sum += tmp[i]; }
    /* Insertion sort. n <= 512 and this runs twice a second; a qsort call
     * would drag in a comparator and a function-pointer call for no gain. */
    for (i = 1; i < n; i++) {
        k = tmp[i];
        for (j = i - 1; j >= 0 && tmp[j] > k; j--) tmp[j + 1] = tmp[j];
        tmp[j + 1] = k;
    }
    s->wMin  = tmp[0];
    s->wMax  = tmp[n - 1];
    s->wP50  = tmp[(n * 50) / 100];
    s->wP95  = tmp[(n * 95) / 100 >= n ? n - 1 : (n * 95) / 100];
    s->wP99  = tmp[(n * 99) / 100 >= n ? n - 1 : (n * 99) / 100];
    s->wMean = (uint32_t)(sum / (uint64_t)n);
}

/* ------------------------------------------------------------------ *
 * The frame boundary. Called ONCE per frame from the host's shared Update
 * rider chain. It closes the frame-time sample and, every `windowFrames`,
 * rolls every slot's window into `last*` so a reader gets a coherent set of
 * numbers that were all accumulated over the SAME frames.
 * ------------------------------------------------------------------ */
static void aowl_prof_roll(AowlProfShared* s) {
    int32_t i, n;
    if (!s) return;
    n = (int32_t)(s->frames < AOWL_PROF_RING ? s->frames : AOWL_PROF_RING);
    if (n > 0) aowl_prof_percentiles(s, n);
    for (i = 0; i < AOWL_PROF_MAX_SLOTS; i++) {
        if (s->slots[i].kind == AOWL_PROF_KIND_FREE) continue;
        s->slots[i].lastCalls = s->slots[i].calls;
        s->slots[i].lastNs    = s->slots[i].ns;
        s->slots[i].lastMaxNs = s->slots[i].maxNs;
        s->slots[i].calls = 0;
        s->slots[i].ns    = 0;
        s->slots[i].maxNs = 0;
    }
    s->lastWinNs = s->winNs;
    s->winFrames = 0;
    s->winNs = 0;
}

static void aowl_prof_boundary(int32_t isFrameSource) {
    AowlProfShared* s = g_prof;
    LONG64 now, d, win;
    if (!s || !s->enabled) return;
    now = aowl_prof_now();
    if (now == 0) return;
    if (isFrameSource) s->frameSourceLive = 1;
    if (s->frameT0 != 0) {
        d = now - s->frameT0;
        if (d >= 0) {
            LONG64 ns = aowl_prof_ticks_to_ns(s, d);
            LONG64 us = ns / 1000;
            if (us > 0xFFFFFFFFll) us = 0xFFFFFFFFll;
            /* The RING is the frame-time histogram and only a real frame
             * source may write it. A backend tick is not a frame and putting
             * it here would produce a plausible p95 for a thing that has no
             * frames -- a number that cannot be wrong, which is the one kind
             * this project refuses to print. */
            if (isFrameSource) {
                s->ring[(int32_t)(s->frames % AOWL_PROF_RING)] = (uint32_t)us;
                s->frames++;
            }
            /* winNs is the DENOMINATOR for "share of", and that is meaningful
             * on both: on the client it is wall time per frame, on the backend
             * it is wall time per tick. Either way it is the wall time the
             * measured work had to fit inside. */
            s->winNs += ns;
        }
    }
    s->frameT0 = now;
    s->heartbeat++;

    win = s->windowFrames > 0 ? s->windowFrames : 120;
    s->winFrames++;
    if (s->winFrames < win) return;
    aowl_prof_roll(s);
}

/* The CLIENT HOST's boundary: called once per frame from the shared
 * `EFT.UI.PreloaderUI::Update` rider chain. Writes the frame-time histogram. */
static void aowl_prof_frame(void) { aowl_prof_boundary(1); }

/* The LOADER's boundary: called once per `tickMods` pass, on every host. On the
 * client this ALSO fires, and is deliberately harmless there -- it advances the
 * same window the frame boundary does, and since the client's tick loop and its
 * frame rider both run at roughly frame cadence the window simply completes a
 * little sooner. On the backend and the simulator it is the only boundary there
 * is, which is what makes the profiler testable without a game. */
static void aowl_prof_tick_boundary(void) { aowl_prof_boundary(0); }

/* The reader needs the denominator that matched the rolled window, so keep the
 * completed value rather than the running one. Stored separately to keep
 * `aowl_prof_frame` branch-free at the reset. */
static LONG64 aowl_prof_window_ns(AowlProfShared* s) {
    /* The denominator for "share of frame time" is the WALL TIME the completed
     * window actually took -- deliberately NOT the sum of the slots. Dividing
     * slots by the sum of slots always totals 100% and is therefore a statistic
     * that cannot be wrong, which is the exact shape this project loses days to.
     * Against wall time a total well under 100% is the honest answer: most of a
     * frame is the game, not us, and if our slots ever DID total near 100% that
     * would be a real and falsifiable finding.
     *
     * 0 until the first window completes. Callers must render that as "--". */
    if (!s) return 0;
    return (LONG64)s->lastWinNs;
}

/* ------------------------------------------------------------------ *
 * Calibration -- run ONCE, off the hot path, publishing what a begin/end pair
 * costs so no reader has to trust a number near the noise floor.
 * ------------------------------------------------------------------ */
static void aowl_prof_calibrate(void) {
    AowlProfShared* s = aowl_prof_get();
    LONG64 a, b;
    int i;
    LONG saveEnabled;
    int32_t slot;
    if (!s || s->calibrated) return;
    if (s->qpf <= 0) {
        s->calibrated = 1;
        s->overheadNs = 0;
        return;
    }
    slot = aowl_prof_slot("_calib", AOWL_PROF_KIND_OTHER);
    if (slot < 0) { s->calibrated = 1; return; }
    saveEnabled = s->enabled;
    s->enabled = 1;
    a = aowl_prof_now();
    for (i = 0; i < 4096; i++) { aowl_prof_begin(slot); aowl_prof_end(slot); }
    b = aowl_prof_now();
    s->enabled = saveEnabled;
    s->overheadNs = aowl_prof_ticks_to_ns(s, b - a) / 4096;
    /* Undo the calibration's own contribution so it is not reported as cost. */
    s->slots[slot].kind = AOWL_PROF_KIND_FREE;
    s->slots[slot].calls = 0; s->slots[slot].ns = 0; s->slots[slot].maxNs = 0;
    s->slots[slot].totalCalls = 0; s->slots[slot].totalNs = 0;
    s->calibrated = 1;
}

/* ------------------------------------------------------------------ *
 * Small typed accessors, so the Nim side never dereferences the struct and the
 * layout stays this file's private business.
 * ------------------------------------------------------------------ */
static int32_t aowl_prof_ready(void)      { return aowl_prof_get() ? 1 : 0; }
static int32_t aowl_prof_is_enabled(void) { AowlProfShared* s = aowl_prof_get(); return s && s->enabled ? 1 : 0; }
static void    aowl_prof_set_enabled(int32_t on) {
    AowlProfShared* s = aowl_prof_get();
    if (!s) return;
    if (on && s->selfDisabled) return;   /* only a restart re-arms after N faults */
    s->enabled = on ? 1 : 0;
}
static int32_t aowl_prof_panel_open(void) { AowlProfShared* s = aowl_prof_get(); return s && s->panelOpen ? 1 : 0; }
static void    aowl_prof_set_panel(int32_t on) { AowlProfShared* s = aowl_prof_get(); if (s) s->panelOpen = on ? 1 : 0; }
static void    aowl_prof_set_window(int32_t n) {
    AowlProfShared* s = aowl_prof_get();
    if (!s) return;
    if (n < 10) n = 10;
    if (n > AOWL_PROF_RING) n = AOWL_PROF_RING;
    s->windowFrames = n;
}
static int32_t aowl_prof_faults(void)       { AowlProfShared* s = aowl_prof_get(); return s ? (int32_t)s->faults : 0; }
static int32_t aowl_prof_self_disabled(void){ AowlProfShared* s = aowl_prof_get(); return s && s->selfDisabled ? 1 : 0; }
static const char* aowl_prof_reason(void)   { AowlProfShared* s = aowl_prof_get(); return s ? s->disabledReason : ""; }
static int64_t aowl_prof_overhead_ns(void)  { AowlProfShared* s = aowl_prof_get(); return s ? (int64_t)s->overheadNs : 0; }
static int64_t aowl_prof_frames(void)       { AowlProfShared* s = aowl_prof_get(); return s ? (int64_t)s->frames : 0; }
static int32_t aowl_prof_heartbeat(void)    { AowlProfShared* s = aowl_prof_get(); return s ? (int32_t)s->heartbeat : -1; }
static int32_t aowl_prof_live_slots(void) {
    AowlProfShared* s = aowl_prof_get();
    int32_t i, n = 0;
    if (!s) return -1;
    for (i = 0; i < AOWL_PROF_MAX_SLOTS; i++)
        if (s->slots[i].kind != AOWL_PROF_KIND_FREE) n++;
    return n;
}
static int32_t aowl_prof_frame_source(void) { AowlProfShared* s = aowl_prof_get(); return s && s->frameSourceLive ? 1 : 0; }
static int32_t aowl_prof_slot_count(void)   { return AOWL_PROF_MAX_SLOTS; }
static int32_t aowl_prof_slot_kind(int32_t i) {
    AowlProfShared* s = aowl_prof_get();
    if (!s || i < 0 || i >= AOWL_PROF_MAX_SLOTS) return AOWL_PROF_KIND_FREE;
    return (int32_t)s->slots[i].kind;
}
static const char* aowl_prof_slot_name(int32_t i) {
    AowlProfShared* s = aowl_prof_get();
    if (!s || i < 0 || i >= AOWL_PROF_MAX_SLOTS) return "";
    return s->slots[i].name;
}
static int64_t aowl_prof_slot_ns(int32_t i) {
    AowlProfShared* s = aowl_prof_get();
    if (!s || i < 0 || i >= AOWL_PROF_MAX_SLOTS) return 0;
    return (int64_t)s->slots[i].lastNs;
}
static int64_t aowl_prof_slot_max_ns(int32_t i) {
    AowlProfShared* s = aowl_prof_get();
    if (!s || i < 0 || i >= AOWL_PROF_MAX_SLOTS) return 0;
    return (int64_t)s->slots[i].lastMaxNs;
}
static int64_t aowl_prof_slot_calls(int32_t i) {
    AowlProfShared* s = aowl_prof_get();
    if (!s || i < 0 || i >= AOWL_PROF_MAX_SLOTS) return 0;
    return (int64_t)s->slots[i].lastCalls;
}
static int64_t aowl_prof_slot_total_ns(int32_t i) {
    AowlProfShared* s = aowl_prof_get();
    if (!s || i < 0 || i >= AOWL_PROF_MAX_SLOTS) return 0;
    return (int64_t)s->slots[i].totalNs;
}
static int32_t aowl_prof_win_us(int32_t which) {
    /* 0=min 1=mean 2=p50 3=p95 4=p99 5=max */
    AowlProfShared* s = aowl_prof_get();
    if (!s) return 0;
    switch (which) {
        case 0: return (int32_t)s->wMin;
        case 1: return (int32_t)s->wMean;
        case 2: return (int32_t)s->wP50;
        case 3: return (int32_t)s->wP95;
        case 4: return (int32_t)s->wP99;
        case 5: return (int32_t)s->wMax;
        default: return 0;
    }
}
static int64_t aowl_prof_window_denom_ns(void) {
    return aowl_prof_window_ns(aowl_prof_get());
}

/* Share of frame time, in tenths of a percent, so the Nim side needs no float.
 * Returns -1 when the denominator is not yet established -- which the caller
 * MUST render as "--" and not as 0.0%. "I could not look" is not a measurement. */
static int32_t aowl_prof_slot_permille(int32_t i) {
    LONG64 denom = aowl_prof_window_denom_ns();
    LONG64 v = aowl_prof_slot_ns(i);
    if (denom <= 0) return -1;
    return (int32_t)((v * 1000ll) / denom);
}

/* ------------------------------------------------------------------ *
 * BYTE-AT-A-TIME string accessors.
 *
 * These exist because `$cstring` compiles under the host's Nim build and does
 * NOT compile under the nimony toolchain the mods are built with -- measured,
 * not assumed: `dbg/prof.nim(69,38) Error: Type mismatch ... expected: string
 * but got: cstring not nil`. Rather than have the mod and the host disagree
 * about how a name crosses the boundary, both sides use these: one call per
 * byte, bounded by a compile-time constant, off the hot path (a name is read
 * on a panel refresh or an HTTP request, never in a scope).
 *
 * Return 0 for "end of string" and for any out-of-range index, so a caller's
 * loop terminates on a bad index instead of running off the end.
 * ------------------------------------------------------------------ */
static int32_t aowl_prof_slot_name_char(int32_t i, int32_t k) {
    AowlProfShared* s = aowl_prof_get();
    if (!s || i < 0 || i >= AOWL_PROF_MAX_SLOTS) return 0;
    if (k < 0 || k >= AOWL_PROF_NAME_LEN) return 0;
    return (int32_t)(unsigned char)s->slots[i].name[k];
}

static int32_t aowl_prof_reason_char(int32_t k) {
    AowlProfShared* s = aowl_prof_get();
    if (!s || k < 0 || k >= AOWL_PROF_REASON_LEN) return 0;
    return (int32_t)(unsigned char)s->disabledReason[k];
}

static int32_t aowl_prof_kind_char(int32_t kind, int32_t k) {
    const char* n = aowl_prof_kind_name(kind);
    int32_t i;
    if (!n || k < 0) return 0;
    for (i = 0; i < k; i++) if (!n[i]) return 0;
    return (int32_t)(unsigned char)n[k];
}

#endif /* AOWLSPT_PROFILE_H */
