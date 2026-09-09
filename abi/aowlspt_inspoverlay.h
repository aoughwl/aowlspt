/* aowlspt_inspoverlay.h -- the native backing for the F2 LIVE INSPECTOR OVERLAY.
 *
 * WHAT THIS IS. A tiny, self-contained ring buffer of the live inspector's most
 * recent activity (the commands it ran and the answer lines it produced), plus a
 * published snapshot of its bound anchors. The inspector WRITES to it from
 * Unity's main thread as it runs a batch; the D3D11 overlay READS from it in
 * `Present` (a different thread) to draw the F2 panel. Nothing here detours,
 * resolves a name, calls into managed code, or allocates on any path -- every
 * buffer is a file-scope fixed array, every loop is bounded by a compile-time
 * constant, and the only OS calls are a CRITICAL_SECTION.
 *
 * WHY A LOCK. There is exactly one writer (Unity thread, `aowl_io_push` /
 * `aowl_io_anchor_*`) and one reader (the render thread, `aowl_io_get` /
 * `aowl_io_anchor_get`). A CRITICAL_SECTION held for the length of a <=63-byte
 * memcpy is the simplest thing that is unambiguously correct: the reader can
 * never observe a half-overwritten line, and at human command rates the writer
 * is never meaningfully blocked. This lock is DEDICATED -- it is never the
 * inspector's own `aowl_insp_lock` -- so there is no lock-ordering relationship
 * with anything else in the host and therefore no way to invert one.
 *
 * WHY 63 CHARS. `AOWL_REGION_TEXT_LEN` is 64, so a single overlay text command
 * carries at most 63 characters. Storing wider than the renderer can draw would
 * be a read-out that loses its right-hand column WITHOUT SAYING SO -- the exact
 * failure the inspector exists to avoid -- so a line is truncated to 63 here, at
 * the point of capture, and marked with a trailing '>' when it was cut. The full
 * untruncated answer is always in aowlspt-inspect-out.txt; this panel is a live
 * glance, not the transcript.
 */
#ifndef AOWLSPT_INSPOVERLAY_H
#define AOWLSPT_INSPOVERLAY_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

#define AOWL_IO_RING_N    128   /* recent activity lines kept (ring capacity)   */
#define AOWL_IO_LINE       64   /* bytes per stored line, incl NUL (== region)  */
#define AOWL_IO_ANCHOR_N   24   /* published anchor slots                       */

/* ---- kinds, so the panel can colour a command differently from an answer ---- */
#define AOWL_IO_KIND_CMD    0   /* a command the inspector is about to run      */
#define AOWL_IO_KIND_RESULT 1   /* one answer line the inspector produced       */
#define AOWL_IO_KIND_EVENT  2   /* a host-side event (fault, toggle, arm)       */

/* ---- the dedicated lock, lazily and race-safely initialised ---------------- */
static CRITICAL_SECTION aowl_io_cs;
static volatile LONG    aowl_io_cs_state = 0;   /* 0 uninit, 1 initing, 2 ready */

static void aowl_io_ensure(void) {
    if (InterlockedCompareExchange(&aowl_io_cs_state, 1, 0) == 0) {
        InitializeCriticalSection(&aowl_io_cs);
        InterlockedExchange(&aowl_io_cs_state, 2);
        return;
    }
    /* Another thread is initialising (state 1) or already did (state 2). Spin
     * only for the brief 1->2 window; this can only ever run once. */
    while (InterlockedCompareExchange(&aowl_io_cs_state, 2, 2) != 2) { /* wait */ }
}
static void aowl_io_lock(void)   { aowl_io_ensure(); EnterCriticalSection(&aowl_io_cs); }
static void aowl_io_unlock(void) { LeaveCriticalSection(&aowl_io_cs); }

/* ---- the activity ring ----------------------------------------------------- */
static char    aowl_io_ring[AOWL_IO_RING_N][AOWL_IO_LINE];
static uint8_t aowl_io_kindv[AOWL_IO_RING_N];
static int32_t aowl_io_head  = 0;    /* next slot to write                      */
static int32_t aowl_io_count = 0;    /* valid entries currently kept (<= N)     */
static int64_t aowl_io_seq   = 0;    /* total pushes ever -- lets the reader see */
                                     /* whether anything is new since last frame */

static void aowl_io_copy63(char* dst, const char* s) {
    int i = 0;
    if (!s) s = "";
    for (; i < AOWL_IO_LINE - 1 && s[i]; ++i) dst[i] = s[i];
    if (i == AOWL_IO_LINE - 1 && s[i]) {
        /* there was more: mark the truncation rather than hide it */
        dst[AOWL_IO_LINE - 2] = '>';
    }
    dst[i] = 0;
}

static void aowl_io_push(int32_t kind, const char* s) {
    aowl_io_lock();
    aowl_io_copy63(aowl_io_ring[aowl_io_head], s);
    aowl_io_kindv[aowl_io_head] = (uint8_t)kind;
    aowl_io_head = (aowl_io_head + 1) % AOWL_IO_RING_N;
    if (aowl_io_count < AOWL_IO_RING_N) aowl_io_count++;
    aowl_io_seq++;
    aowl_io_unlock();
}

static int32_t aowl_io_count_get(void) { return aowl_io_count; }
static int64_t aowl_io_seq_get(void)   { return aowl_io_seq; }

/* Copy window entry `j` (0 = OLDEST of the kept window, count-1 = newest) into
 * `out`, which MUST be at least AOWL_IO_LINE bytes. Returns the entry's kind,
 * or -1 when `j` is out of range (in which case `out` is set empty). */
static int32_t aowl_io_get(int32_t j, char* out) {
    int32_t k = -1;
    aowl_io_lock();
    if (j >= 0 && j < aowl_io_count) {
        int32_t start = (aowl_io_head - aowl_io_count + AOWL_IO_RING_N) % AOWL_IO_RING_N;
        int32_t idx   = (start + j) % AOWL_IO_RING_N;
        memcpy(out, aowl_io_ring[idx], AOWL_IO_LINE);
        out[AOWL_IO_LINE - 1] = 0;
        k = (int32_t)aowl_io_kindv[idx];
    } else if (out) {
        out[0] = 0;
    }
    aowl_io_unlock();
    return k;
}

/* ---- the published anchor snapshot ----------------------------------------- *
 * Republished wholesale at the start of every batch (when the inspector rebinds
 * its anchors on Unity's thread). `begin` clears; `add` appends a preformatted
 * "name=0x..." line. The reader takes a consistent view under the same lock. */
static char    aowl_io_anchor[AOWL_IO_ANCHOR_N][AOWL_IO_LINE];
static int32_t aowl_io_anchor_n   = 0;
static int64_t aowl_io_anchor_seq = 0;

static void aowl_io_anchor_begin(void) {
    aowl_io_lock();
    aowl_io_anchor_n = 0;
    aowl_io_unlock();
}
static void aowl_io_anchor_add(const char* s) {
    aowl_io_lock();
    if (aowl_io_anchor_n < AOWL_IO_ANCHOR_N) {
        aowl_io_copy63(aowl_io_anchor[aowl_io_anchor_n], s);
        aowl_io_anchor_n++;
    }
    aowl_io_unlock();
}
static void aowl_io_anchor_commit(void) {
    aowl_io_lock();
    aowl_io_anchor_seq++;
    aowl_io_unlock();
}
static int32_t aowl_io_anchor_count(void) { return aowl_io_anchor_n; }
static int64_t aowl_io_anchor_seq_get(void) { return aowl_io_anchor_seq; }
static int32_t aowl_io_anchor_get(int32_t j, char* out) {
    aowl_io_lock();
    if (j >= 0 && j < aowl_io_anchor_n) {
        memcpy(out, aowl_io_anchor[j], AOWL_IO_LINE);
        out[AOWL_IO_LINE - 1] = 0;
    } else if (out) {
        out[0] = 0;
    }
    aowl_io_unlock();
    return 0;
}

#endif /* AOWLSPT_INSPOVERLAY_H */
