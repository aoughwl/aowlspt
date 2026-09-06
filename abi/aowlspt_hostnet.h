/* aowlspt_hostnet.h — the host's GENERIC outbound HTTP client.
 *
 * WHAT THIS IS, AND WHY IT EXISTS AT ALL. MEASURED 2026-09-06: the IL2CPP
 * client host had no HTTP client of any kind. A grep of
 * `host/Aowlspt.Host.Il2Cpp/*.nim` for WinHttp / InternetOpen / WinINet / curl
 * found nothing but the image-CDN ws2_32 redirect hook in `aowlhost.nim`, and
 * `docs/CAPABILITIES.md` said the same. A client-side mod therefore could not
 * reach `aowlspt-backend` at all: it could serve a settings page and it could
 * read the command line, but it could not ask the server a question. This file
 * is the missing half, and it is deliberately FEATURE-AGNOSTIC — it knows
 * nothing about any particular mod, route or payload. It moves bytes.
 *
 * WHY WINHTTP AND NOT SOCKETS. `abi/aowlspt_net.h` is the project's socket
 * layer and it would have worked, but it opens with `#include <winsock2.h>`
 * and `#include <zlib.h>` and needs `-lws2_32 -lz` at link time. The IL2CPP
 * host is built with NEITHER (see `buildIl2CppHost` in `tools/aowl.nim`:
 * no `--passL` at all), and a module injected into someone else's process
 * should carry exactly the imports its job requires. WinHTTP resolved by
 * `LoadLibraryA` + `GetProcAddress` adds ZERO link-time dependencies and zero
 * import-table entries, and a machine without `winhttp.dll` becomes a
 * printable refusal instead of a silent DLL-load failure during the game's
 * own startup. The same reasoning is written out at length in
 * `abi/aowlspt_overlay.h`, whose backend client this borrows its shape from.
 *
 * THREADING, which is the whole safety story here.
 *
 *   * NOTHING in this file runs on the Unity main thread, and nothing runs
 *     inside a detour. `aowl_hn_submit` is called from whatever thread invoked
 *     the verb, does no I/O at all, and returns after starting a worker.
 *   * Each request gets its own `CreateThread`. Blocking WinHTTP calls happen
 *     ONLY there. The inflight cap (default 4) bounds how many can exist.
 *   * Every access to the slot table — submit, worker publish, take, poll,
 *     release, reap — is under ONE process-wide `CRITICAL_SECTION` owned by
 *     this file. The worker does its I/O OUTSIDE the lock into a private
 *     buffer and takes the lock only to hand the finished buffer over.
 *   * Results are COPIED OUT to a caller-owned buffer under the lock, so a
 *     reader never holds a pointer this file can free.
 *
 * NO GAME MEMORY IS TOUCHED. Not one il2cpp export is called, no name is
 * resolved, no pointer from the game is dereferenced and no byte of
 * `GameAssembly.dll` is read or written. That is why there is no
 * `aowl_p_p_seh` here: the guard exists for reads that can fault on a moving
 * managed heap, and this file only ever touches its own statics and Win32.
 * Adding a guard would be cargo cult, and worse — the guard is not re-entrant,
 * so a guard here nested inside a caller's guard would DISARM the caller's.
 *
 * CAPS, all of them refusals rather than truncations:
 *   * host allowlist        — `aowl_hn_allow_add`, empty allowlist = refuse all
 *   * inflight              — `maxInflight`, submit is refused when full
 *   * request body          — `maxBody`, submit is refused
 *   * response body         — `maxBody`, the request COMPLETES with an error
 *                             and an empty body, never a valid-looking prefix
 *   * timeout               — clamped to [250 ms, AOWL_HN_TIMEOUT_MAX]
 *   * slot retention        — a finished slot is kept AOWL_HN_TTL_MS so a
 *                             polling mod can still read it, then reaped
 *
 * PLAINTEXT http:// ONLY, on purpose. The allowlist this ships with is
 * loopback, the backend is loopback, and TLS to 127.0.0.1 buys nothing while
 * costing a certificate-validation surface inside a game process. An
 * `https://` URL is REFUSED BY NAME rather than silently downgraded.
 */

#ifndef AOWLSPT_HOSTNET_H
#define AOWLSPT_HOSTNET_H

#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

/* ALLOCATION GOES THROUGH THE PROCESS HEAP, NOT malloc/free, and that is a
 * deliberate choice rather than an old-fashioned one.
 *
 * A response buffer here is allocated on a WORKER thread and freed on the
 * HOST thread. The IL2CPP host is built with mimalloc (`mimallocFlags` in
 * `tools/aowl.nim` is on the host's own compile line), and mimalloc overrides
 * `malloc`/`free` process-wide with a thread-local-heap allocator that has
 * ownership assertions. CLAUDE.md section 1 records what that costs when it
 * bites: a `__fastfail` (0xc0000409) that writes NO Unity crash report at all,
 * caused by exactly this shape -- work ticking on a different thread than it
 * was initialised on. `HeapAlloc(GetProcessHeap(), ...)` is a Win32 call with
 * no allocator override in front of it and no thread affinity whatsoever, so
 * the whole question does not arise. */
#define AOWL_HN_ALLOC(n)      HeapAlloc(GetProcessHeap(), 0, (SIZE_T)(n))
#define AOWL_HN_REALLOC(p, n) HeapReAlloc(GetProcessHeap(), 0, (p), (SIZE_T)(n))
#define AOWL_HN_FREE(p)       HeapFree(GetProcessHeap(), 0, (p))

#define AOWL_HN_SLOTS          8      /* hard ceiling; maxInflight <= this   */
#define AOWL_HN_ALLOW_MAX      16     /* allowlist entries                   */
#define AOWL_HN_ID_CAP         64
#define AOWL_HN_HOST_CAP       128
#define AOWL_HN_PATH_CAP       2048
#define AOWL_HN_ERR_CAP        192
#define AOWL_HN_TIMEOUT_MAX    30000  /* the backend long-poll waits 25 s    */
#define AOWL_HN_TIMEOUT_MIN    250
#define AOWL_HN_TTL_MS         120000 /* how long a finished slot is kept    */
#define AOWL_HN_BODY_FLOOR     4096   /* smallest maxBody we will accept     */
#define AOWL_HN_BODY_CEIL      (8 * 1024 * 1024)

/* ---------------------------------------------------------------- WinHTTP */

typedef void* AOWL_HN_HINTERNET;
typedef AOWL_HN_HINTERNET (WINAPI *AowlHnOpen)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
typedef AOWL_HN_HINTERNET (WINAPI *AowlHnConnect)(AOWL_HN_HINTERNET, LPCWSTR, WORD, DWORD);
typedef AOWL_HN_HINTERNET (WINAPI *AowlHnOpenReq)(AOWL_HN_HINTERNET, LPCWSTR, LPCWSTR,
                                                  LPCWSTR, LPCWSTR, LPCWSTR*, DWORD);
typedef BOOL (WINAPI *AowlHnSend)(AOWL_HN_HINTERNET, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, DWORD_PTR);
typedef BOOL (WINAPI *AowlHnRecv)(AOWL_HN_HINTERNET, LPVOID);
typedef BOOL (WINAPI *AowlHnQueryAvail)(AOWL_HN_HINTERNET, LPDWORD);
typedef BOOL (WINAPI *AowlHnRead)(AOWL_HN_HINTERNET, LPVOID, DWORD, LPDWORD);
typedef BOOL (WINAPI *AowlHnClose)(AOWL_HN_HINTERNET);
typedef BOOL (WINAPI *AowlHnTimeouts)(AOWL_HN_HINTERNET, int, int, int, int);
typedef BOOL (WINAPI *AowlHnSetOption)(AOWL_HN_HINTERNET, DWORD, LPVOID, DWORD);
typedef BOOL (WINAPI *AowlHnQueryHdr)(AOWL_HN_HINTERNET, DWORD, LPCWSTR, LPVOID, LPDWORD, LPDWORD);

static struct {
    HMODULE          lib;
    AowlHnOpen       open;
    AowlHnConnect    connect;
    AowlHnOpenReq    openReq;
    AowlHnSend       send;
    AowlHnRecv       recv;
    AowlHnQueryAvail avail;
    AowlHnRead       read;
    AowlHnClose      close;
    AowlHnTimeouts   timeouts;
    AowlHnSetOption  setOption;
    AowlHnQueryHdr   queryHdr;
    int32_t          tried;
    int32_t          ok;
} g_hnApi;

/* ------------------------------------------------------------ slot table */

typedef struct {
    int32_t  used;                       /* slot allocated                  */
    volatile LONG done;                  /* worker has published a result   */
    int32_t  emitted;                    /* the ops tick has emitted it     */
    char     id[AOWL_HN_ID_CAP];
    wchar_t  wverb[8];
    wchar_t  whost[AOWL_HN_HOST_CAP];
    wchar_t  wpath[AOWL_HN_PATH_CAP];
    int32_t  port;
    char*    reqBody;
    int32_t  reqLen;
    int32_t  timeoutMs;
    int32_t  status;                     /* HTTP code, or 0                 */
    char*    respBody;                   /* NUL-terminated, owned here      */
    int32_t  respLen;
    char     err[AOWL_HN_ERR_CAP];
    uint64_t startMs;
    uint64_t endMs;
    HANDLE   thread;
} AowlHnSlot;

static struct {
    CRITICAL_SECTION cs;
    LONG             csReady;            /* 0 none, 1 ready, 2 initialising */
    int32_t          enabled;
    int32_t          maxInflight;
    int32_t          maxBody;
    char             allow[AOWL_HN_ALLOW_MAX][AOWL_HN_HOST_CAP];
    int32_t          allowN;
    AowlHnSlot       slot[AOWL_HN_SLOTS];
    int64_t          submitted;
    int64_t          completed;
    int64_t          refused;
} g_hn;

static void aowl_hn_lock_init(void) {
    /* One-time init without a static initialiser, because this header is
     * included into a DLL whose constructor runs under the loader lock. The
     * interlocked dance is the same one `aowlspt_lock.h` documents. */
    if (InterlockedCompareExchange(&g_hn.csReady, 2, 0) == 0) {
        InitializeCriticalSection(&g_hn.cs);
        InterlockedExchange(&g_hn.csReady, 1);
        return;
    }
    while (InterlockedCompareExchange(&g_hn.csReady, 1, 1) != 1) Sleep(0);
}
static void aowl_hn_lock(void)   { aowl_hn_lock_init(); EnterCriticalSection(&g_hn.cs); }
static void aowl_hn_unlock(void) { LeaveCriticalSection(&g_hn.cs); }

static uint64_t aowl_hn_now(void) { return (uint64_t)GetTickCount64(); }

static void aowl_hn_copy(char* dst, int32_t cap, const char* src) {
    int32_t i = 0;
    if (cap <= 0) return;
    if (src) while (i < cap - 1 && src[i]) { dst[i] = src[i]; i++; }
    dst[i] = 0;
}

static int aowl_hn_ieq(const char* a, const char* b) {
    int i = 0;
    for (;;) {
        char ca = a[i], cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) return 0;
        if (!ca) return 1;
        i++;
    }
}

static void aowl_hn_widen(wchar_t* dst, int32_t cap, const char* src, int32_t n) {
    int32_t i = 0;
    if (cap <= 0) return;
    while (i < cap - 1 && i < n && src[i]) { dst[i] = (wchar_t)(unsigned char)src[i]; i++; }
    dst[i] = 0;
}

/* MEASURED 2026-09-06 by `tools/test_hosthttp.py` (case: two concurrent
 * requests). The obvious double-checked shape --
 *
 *     if (g_hnApi.tried) return g_hnApi.ok;
 *     g_hnApi.tried = 1;
 *     ...resolve every entry point...
 *
 * -- is WRONG with more than one worker, and wrong in the worst way: the
 * second thread reads `tried == 1` while the first is still inside
 * `LoadLibraryA`, sees `ok == 0`, and REPORTS "winhttp.dll is not loadable, or
 * is missing an entry point". The request fails with a diagnosis that names
 * the wrong thing entirely, and it fails only sometimes. Two concurrent
 * requests is the ordinary case for this verb, so this would have been a live
 * intermittent failure with a confidently wrong error message.
 *
 * The resolution therefore happens under the slot table's own critical
 * section. It runs at most once per process and holds the lock for one
 * `LoadLibraryA` plus eleven `GetProcAddress` calls; every caller either holds
 * no lock (`aowl_hn_worker`, before it does anything else) or is the verb
 * asking for status, so there is no order to get wrong. */
static int32_t aowl_hn_api(void) {
    if (InterlockedCompareExchange((volatile LONG*)&g_hnApi.tried, 1, 1) == 1)
        return g_hnApi.ok;
    aowl_hn_lock();
    if (g_hnApi.tried) { int32_t r = g_hnApi.ok; aowl_hn_unlock(); return r; }
    g_hnApi.lib = LoadLibraryA("winhttp.dll");
    if (!g_hnApi.lib) {
        InterlockedExchange((volatile LONG*)&g_hnApi.tried, 1);
        aowl_hn_unlock();
        return 0;
    }
    g_hnApi.open      = (AowlHnOpen)(void*)GetProcAddress(g_hnApi.lib, "WinHttpOpen");
    g_hnApi.connect   = (AowlHnConnect)(void*)GetProcAddress(g_hnApi.lib, "WinHttpConnect");
    g_hnApi.openReq   = (AowlHnOpenReq)(void*)GetProcAddress(g_hnApi.lib, "WinHttpOpenRequest");
    g_hnApi.send      = (AowlHnSend)(void*)GetProcAddress(g_hnApi.lib, "WinHttpSendRequest");
    g_hnApi.recv      = (AowlHnRecv)(void*)GetProcAddress(g_hnApi.lib, "WinHttpReceiveResponse");
    g_hnApi.avail     = (AowlHnQueryAvail)(void*)GetProcAddress(g_hnApi.lib, "WinHttpQueryDataAvailable");
    g_hnApi.read      = (AowlHnRead)(void*)GetProcAddress(g_hnApi.lib, "WinHttpReadData");
    g_hnApi.close     = (AowlHnClose)(void*)GetProcAddress(g_hnApi.lib, "WinHttpCloseHandle");
    g_hnApi.timeouts  = (AowlHnTimeouts)(void*)GetProcAddress(g_hnApi.lib, "WinHttpSetTimeouts");
    g_hnApi.setOption = (AowlHnSetOption)(void*)GetProcAddress(g_hnApi.lib, "WinHttpSetOption");
    g_hnApi.queryHdr  = (AowlHnQueryHdr)(void*)GetProcAddress(g_hnApi.lib, "WinHttpQueryHeaders");
    g_hnApi.ok = (g_hnApi.open && g_hnApi.connect && g_hnApi.openReq && g_hnApi.send &&
                  g_hnApi.recv && g_hnApi.avail && g_hnApi.read && g_hnApi.close) ? 1 : 0;
    /* `tried` is published LAST, with a release, so no thread can observe
     * "already tried" over a half-filled function table. That ordering is the
     * whole fix. */
    InterlockedExchange((volatile LONG*)&g_hnApi.tried, 1);
    {
        int32_t r = g_hnApi.ok;
        aowl_hn_unlock();
        return r;
    }
}

/* ------------------------------------------------------------- the worker */

static void aowl_hn_free_slot(AowlHnSlot* s) {
    if (s->reqBody)  { AOWL_HN_FREE(s->reqBody);  s->reqBody = NULL; }
    if (s->respBody) { AOWL_HN_FREE(s->respBody); s->respBody = NULL; }
    if (s->thread)   { CloseHandle(s->thread); s->thread = NULL; }
    memset(s, 0, sizeof(*s));
}

static DWORD WINAPI aowl_hn_worker(LPVOID param) {
    AowlHnSlot* s = (AowlHnSlot*)param;
    AOWL_HN_HINTERNET ses = NULL, con = NULL, req = NULL;
    char* buf = NULL;
    int32_t cap = 0, total = 0, status = 0;
    char err[AOWL_HN_ERR_CAP];
    int32_t maxBody;

    err[0] = 0;
    aowl_hn_lock();
    maxBody = g_hn.maxBody;
    aowl_hn_unlock();

    if (!aowl_hn_api()) {
        aowl_hn_copy(err, sizeof(err),
                     "winhttp.dll is not loadable, or is missing an entry point, "
                     "so this host cannot make an HTTP request at all");
        goto publish;
    }

    /* A session per request rather than a cached one. The overlay caches its
     * session because it polls four routes a second forever; this verb is
     * called at human rates and a fresh session cannot inherit a poisoned
     * one. NO_PROXY (1) is not an optimisation here either — it is correct:
     * the allowlist is loopback, and DEFAULT_PROXY would run a WPAD lookup
     * (DNS, then DHCP) per call, measured at over a second when the network
     * is unhelpful. */
    ses = g_hnApi.open(L"aowlspt-host/1.0", 1 /*WINHTTP_ACCESS_TYPE_NO_PROXY*/,
                       NULL, NULL, 0);
    if (!ses) { aowl_hn_copy(err, sizeof(err), "WinHttpOpen failed"); goto publish; }
    if (g_hnApi.setOption) {
        DWORD one = 1;
        g_hnApi.setOption(ses, 3 /*WINHTTP_OPTION_CONNECT_RETRIES*/, &one, sizeof(one));
    }
    /* resolve / connect / send / receive. The RECEIVE budget is the caller's
     * whole timeout, because a long-poll route legitimately holds the
     * response open for 25 s; the first three are short because a loopback
     * connect that has not happened in 5 s is not going to. */
    if (g_hnApi.timeouts)
        g_hnApi.timeouts(ses, 3000, 5000, 5000, s->timeoutMs);

    con = g_hnApi.connect(ses, s->whost, (WORD)s->port, 0);
    if (!con) { aowl_hn_copy(err, sizeof(err), "WinHttpConnect failed (is the backend up?)"); goto publish; }
    req = g_hnApi.openReq(con, s->wverb, s->wpath, NULL, NULL, NULL, 0);
    if (!req) { aowl_hn_copy(err, sizeof(err), "WinHttpOpenRequest failed"); goto publish; }

    {
        /* `Accept-Encoding: identity` is load-bearing, not politeness.
         * `aowlspt-backend` zlib-deflates response bodies with no
         * `Content-Encoding` header (see `sendResponse` in
         * `backend/aowlbackend.nim`), and honours `identity` when it is asked
         * for without `deflate`. Without this header a mod would be handed
         * bytes starting `78 9C` and would report "the JSON did not parse",
         * which reads like a server bug and is not one. */
        const wchar_t* hdr =
            (s->reqLen > 0)
              ? L"Content-Type: application/json\r\nAccept-Encoding: identity\r\n"
              : L"Accept-Encoding: identity\r\n";
        DWORD hdrLen = (DWORD)wcslen(hdr);
        if (!g_hnApi.send(req, hdr, hdrLen, (LPVOID)s->reqBody,
                          (DWORD)s->reqLen, (DWORD)s->reqLen, 0)) {
            aowl_hn_copy(err, sizeof(err), "WinHttpSendRequest failed");
            goto publish;
        }
    }
    if (!g_hnApi.recv(req, NULL)) {
        aowl_hn_copy(err, sizeof(err),
                     "WinHttpReceiveResponse failed or timed out");
        goto publish;
    }
    if (g_hnApi.queryHdr) {
        DWORD code = 0, len = sizeof(code), idx = 0;
        /* 19 = WINHTTP_QUERY_STATUS_CODE, 0x20000000 = _FLAG_NUMBER */
        if (g_hnApi.queryHdr(req, 19 | 0x20000000, NULL, &code, &len, &idx))
            status = (int32_t)code;
    }

    cap = 16 * 1024;
    if (cap > maxBody + 1) cap = maxBody + 1;
    buf = (char*)AOWL_HN_ALLOC(cap);
    if (!buf) { aowl_hn_copy(err, sizeof(err), "out of memory reading the response"); goto publish; }
    for (;;) {
        DWORD avail = 0, got = 0, want;
        if (!g_hnApi.avail(req, &avail) || avail == 0) break;
        if (total + (int32_t)avail > maxBody) {
            /* REFUSED, NOT TRUNCATED. A prefix of valid JSON is the worst
             * possible answer: every reader rejects it as "not a schema" and
             * the size never appears anywhere. */
            AOWL_HN_FREE(buf); buf = NULL; total = 0;
            aowl_hn_copy(err, sizeof(err),
                         "the response body exceeds hostHttpMaxBody; it was "
                         "REFUSED rather than truncated, because a prefix of a "
                         "JSON document is worse than no document");
            goto publish;
        }
        if (total + (int32_t)avail + 1 > cap) {
            int32_t ncap = cap;
            char* nb;
            while (ncap < total + (int32_t)avail + 1) ncap *= 2;
            if (ncap > maxBody + 1) ncap = maxBody + 1;
            nb = (char*)AOWL_HN_REALLOC(buf, ncap);
            if (!nb) { AOWL_HN_FREE(buf); buf = NULL; total = 0;
                       aowl_hn_copy(err, sizeof(err), "out of memory growing the response buffer");
                       goto publish; }
            buf = nb; cap = ncap;
        }
        want = avail;
        if (want > (DWORD)(cap - 1 - total)) want = (DWORD)(cap - 1 - total);
        if (want == 0) break;
        if (!g_hnApi.read(req, buf + total, want, &got) || got == 0) break;
        total += (int32_t)got;
    }
    if (buf) buf[total] = 0;

publish:
    if (req) g_hnApi.close(req);
    if (con) g_hnApi.close(con);
    if (ses) g_hnApi.close(ses);

    aowl_hn_lock();
    s->status   = status;
    s->respBody = buf;
    s->respLen  = buf ? total : 0;
    aowl_hn_copy(s->err, sizeof(s->err), err);
    s->endMs = aowl_hn_now();
    g_hn.completed++;
    InterlockedExchange(&s->done, 1);
    aowl_hn_unlock();
    return 0;
}

/* ------------------------------------------------------------ housekeeping */

/* Caller holds the lock. */
static void aowl_hn_reap(void) {
    uint64_t now = aowl_hn_now();
    int32_t i;
    for (i = 0; i < AOWL_HN_SLOTS; i++) {
        AowlHnSlot* s = &g_hn.slot[i];
        if (s->used && s->done && (now - s->endMs) > (uint64_t)AOWL_HN_TTL_MS)
            aowl_hn_free_slot(s);
    }
}

/* Caller holds the lock. */
static int32_t aowl_hn_inflight(void) {
    int32_t i, n = 0;
    for (i = 0; i < AOWL_HN_SLOTS; i++)
        if (g_hn.slot[i].used && !g_hn.slot[i].done) n++;
    return n;
}

/* Caller holds the lock. Returns NULL when nothing can be freed. */
static AowlHnSlot* aowl_hn_alloc(void) {
    int32_t i, best = -1;
    uint64_t oldest = 0;
    for (i = 0; i < AOWL_HN_SLOTS; i++)
        if (!g_hn.slot[i].used) return &g_hn.slot[i];
    /* Full: recycle the oldest slot that is finished AND already emitted. A
     * finished-but-unemitted slot is never recycled — that would be a
     * completion the mod is still waiting for, dropped silently. */
    for (i = 0; i < AOWL_HN_SLOTS; i++) {
        AowlHnSlot* s = &g_hn.slot[i];
        if (s->used && s->done && s->emitted && (best < 0 || s->endMs < oldest)) {
            best = i; oldest = s->endMs;
        }
    }
    if (best < 0) return NULL;
    aowl_hn_free_slot(&g_hn.slot[best]);
    return &g_hn.slot[best];
}

/* ------------------------------------------------------------- public API */

/* Configuration. Called from the host's own boot, on the host thread, before
 * any mod exists — and again is harmless. `maxBody` is in BYTES. */
static void aowl_hn_configure(int32_t enabled, int32_t maxInflight, int32_t maxBody) {
    aowl_hn_lock();
    g_hn.enabled = enabled ? 1 : 0;
    if (maxInflight < 1) maxInflight = 1;
    if (maxInflight > AOWL_HN_SLOTS) maxInflight = AOWL_HN_SLOTS;
    g_hn.maxInflight = maxInflight;
    if (maxBody < AOWL_HN_BODY_FLOOR) maxBody = AOWL_HN_BODY_FLOOR;
    if (maxBody > AOWL_HN_BODY_CEIL) maxBody = AOWL_HN_BODY_CEIL;
    g_hn.maxBody = maxBody;
    aowl_hn_unlock();
}

static void aowl_hn_allow_reset(void) {
    aowl_hn_lock();
    g_hn.allowN = 0;
    aowl_hn_unlock();
}

static int32_t aowl_hn_allow_add(const char* host) {
    int32_t ok = 0;
    aowl_hn_lock();
    if (host && host[0] && g_hn.allowN < AOWL_HN_ALLOW_MAX) {
        aowl_hn_copy(g_hn.allow[g_hn.allowN], AOWL_HN_HOST_CAP, host);
        g_hn.allowN++;
        ok = 1;
    }
    aowl_hn_unlock();
    return ok;
}

static int32_t aowl_hn_allow_count(void) {
    int32_t n;
    aowl_hn_lock(); n = g_hn.allowN; aowl_hn_unlock();
    return n;
}

/* Submit. Returns 1 accepted, 0 refused (and `why` says why, always).
 *
 * Does NO I/O on the calling thread. The only blocking call it makes is
 * `CreateThread`. Safe from any thread, including a mod's ops thread. */
static int32_t aowl_hn_submit(const char* id, const char* method, const char* url,
                              const char* body, int32_t bodyLen, int32_t timeoutMs,
                              char* why, int32_t whyCap) {
    AowlHnSlot* s = NULL;
    const char* p;
    const char* hostStart;
    int32_t hostLen = 0, port = 80, i;
    char hostA[AOWL_HN_HOST_CAP];
    int allowed = 0;

    if (why && whyCap > 0) why[0] = 0;
    if (!id || !id[0]) { aowl_hn_copy(why, whyCap, "the request carries no id"); return 0; }
    if (!url || !url[0]) { aowl_hn_copy(why, whyCap, "the request carries no url"); return 0; }
    if (!method || !method[0]) method = "GET";
    if (!(aowl_hn_ieq(method, "GET") || aowl_hn_ieq(method, "POST"))) {
        aowl_hn_copy(why, whyCap, "only GET and POST are supported by this verb");
        return 0;
    }

    aowl_hn_lock();
    if (!g_hn.enabled) {
        aowl_hn_unlock();
        aowl_hn_copy(why, whyCap, "flag hostHttp is off");
        return 0;
    }
    aowl_hn_unlock();

    /* URL: http://host[:port]/path — parsed by hand, because a URL cracker
     * would be another WinHTTP entry point to resolve for four lines of work. */
    if (url[0] == 'h' && url[1] == 't' && url[2] == 't' && url[3] == 'p' &&
        url[4] == 's') {
        aowl_hn_copy(why, whyCap,
                     "https:// is refused by this verb: the allowlist is "
                     "loopback and TLS inside the game process buys nothing "
                     "here. Use http://");
        return 0;
    }
    p = url;
    if (!(p[0]=='h'&&p[1]=='t'&&p[2]=='t'&&p[3]=='p'&&p[4]==':'&&p[5]=='/'&&p[6]=='/')) {
        aowl_hn_copy(why, whyCap, "the url must begin with http://");
        return 0;
    }
    p += 7;
    hostStart = p;
    while (*p && *p != '/' && *p != ':') p++;
    hostLen = (int32_t)(p - hostStart);
    if (hostLen <= 0 || hostLen >= AOWL_HN_HOST_CAP) {
        aowl_hn_copy(why, whyCap, "the url has no usable host");
        return 0;
    }
    for (i = 0; i < hostLen; i++) hostA[i] = hostStart[i];
    hostA[hostLen] = 0;
    if (*p == ':') {
        p++;
        port = 0;
        while (*p >= '0' && *p <= '9') { port = port * 10 + (*p - '0'); p++; }
        if (port <= 0 || port > 65535) {
            aowl_hn_copy(why, whyCap, "the url has an out-of-range port");
            return 0;
        }
    }
    if (*p != '/' && *p != 0) {
        aowl_hn_copy(why, whyCap, "the url is malformed after the host");
        return 0;
    }

    aowl_hn_lock();
    for (i = 0; i < g_hn.allowN; i++)
        if (aowl_hn_ieq(g_hn.allow[i], hostA)) { allowed = 1; break; }
    if (!allowed) {
        int32_t n = g_hn.allowN;
        g_hn.refused++;
        aowl_hn_unlock();
        if (n == 0)
            aowl_hn_copy(why, whyCap,
                         "the host allowlist is EMPTY, so every host is refused; "
                         "set hostHttpAllow in aowlspt-host.json");
        else
            aowl_hn_copy(why, whyCap,
                         "that host is not in hostHttpAllow, so it is refused");
        return 0;
    }
    if (bodyLen < 0) bodyLen = 0;
    if (bodyLen > g_hn.maxBody) {
        g_hn.refused++;
        aowl_hn_unlock();
        aowl_hn_copy(why, whyCap,
                     "the request body exceeds hostHttpMaxBody; it is REFUSED, "
                     "not truncated");
        return 0;
    }
    aowl_hn_reap();
    if (aowl_hn_inflight() >= g_hn.maxInflight) {
        g_hn.refused++;
        aowl_hn_unlock();
        aowl_hn_copy(why, whyCap,
                     "hostHttpMaxInflight requests are already in flight; "
                     "try again when one completes");
        return 0;
    }
    /* An id already in the table is refused rather than shadowed: two live
     * requests under one id makes `http_poll` answer about whichever one the
     * scan happened to reach first, which is a check that cannot fail. */
    for (i = 0; i < AOWL_HN_SLOTS; i++)
        if (g_hn.slot[i].used && aowl_hn_ieq(g_hn.slot[i].id, id)) {
            aowl_hn_unlock();
            aowl_hn_copy(why, whyCap,
                         "that id is already in the table (still in flight, or "
                         "its result has not aged out yet); pick a fresh one");
            return 0;
        }
    s = aowl_hn_alloc();
    if (!s) {
        g_hn.refused++;
        aowl_hn_unlock();
        aowl_hn_copy(why, whyCap,
                     "every request slot holds a completion nothing has "
                     "collected yet");
        return 0;
    }
    memset(s, 0, sizeof(*s));
    s->used = 1;
    aowl_hn_copy(s->id, sizeof(s->id), id);
    aowl_hn_widen(s->whost, AOWL_HN_HOST_CAP, hostA, hostLen);
    s->port = port;
    aowl_hn_widen(s->wverb, 8, aowl_hn_ieq(method, "POST") ? "POST" : "GET", 4);
    {
        const char* path = (*p == '/') ? p : "/";
        int32_t plen = (int32_t)strlen(path);
        if (plen >= AOWL_HN_PATH_CAP) {
            aowl_hn_free_slot(s);
            aowl_hn_unlock();
            aowl_hn_copy(why, whyCap, "the url path is longer than this verb accepts");
            return 0;
        }
        aowl_hn_widen(s->wpath, AOWL_HN_PATH_CAP, path, plen);
    }
    if (bodyLen > 0 && body) {
        s->reqBody = (char*)AOWL_HN_ALLOC(bodyLen + 1);
        if (!s->reqBody) {
            aowl_hn_free_slot(s);
            aowl_hn_unlock();
            aowl_hn_copy(why, whyCap, "out of memory copying the request body");
            return 0;
        }
        memcpy(s->reqBody, body, (size_t)bodyLen);
        s->reqBody[bodyLen] = 0;
        s->reqLen = bodyLen;
    }
    if (timeoutMs < AOWL_HN_TIMEOUT_MIN) timeoutMs = AOWL_HN_TIMEOUT_MIN;
    if (timeoutMs > AOWL_HN_TIMEOUT_MAX) timeoutMs = AOWL_HN_TIMEOUT_MAX;
    s->timeoutMs = timeoutMs;
    s->startMs = aowl_hn_now();
    g_hn.submitted++;
    s->thread = CreateThread(NULL, 0, aowl_hn_worker, s, 0, NULL);
    if (!s->thread) {
        aowl_hn_free_slot(s);
        aowl_hn_unlock();
        aowl_hn_copy(why, whyCap, "CreateThread failed; no request was made");
        return 0;
    }
    aowl_hn_unlock();
    return 1;
}

/* The DRAIN. Called from the host's own tick loop, on the host thread.
 * Copies the id of one finished-and-not-yet-emitted request into `idOut` and
 * marks it emitted. Returns 1 when it found one, 0 when it did not. */
static int32_t aowl_hn_take_done(char* idOut, int32_t idCap) {
    int32_t i, found = 0;
    if (idOut && idCap > 0) idOut[0] = 0;
    /* Cheap out before touching the lock. This runs every 16 ms for the whole
     * session on a build where nothing ever calls the verb; if the critical
     * section was never even initialised there is provably nothing to drain,
     * and initialising it here would be work done purely to find that out. */
    if (InterlockedCompareExchange(&g_hn.csReady, 1, 1) != 1) return 0;
    aowl_hn_lock();
    for (i = 0; i < AOWL_HN_SLOTS; i++) {
        AowlHnSlot* s = &g_hn.slot[i];
        if (s->used && s->done && !s->emitted) {
            s->emitted = 1;
            aowl_hn_copy(idOut, idCap, s->id);
            found = 1;
            break;
        }
    }
    if (!found) aowl_hn_reap();
    aowl_hn_unlock();
    return found;
}

/* Read a result by id. Returns:
 *    1  done   — status/ms/err/body filled in
 *    0  in flight
 *   -1  no such id (never submitted, or its result has aged out)
 * The body is COPIED into `bodyOut`, so the caller never holds a pointer this
 * file can free. `bodyLenOut` reports the FULL length even when `bodyCap` was
 * too small, so a caller can tell a short buffer from a short body. */
static int32_t aowl_hn_result(const char* id, char* bodyOut, int32_t bodyCap,
                              int32_t* statusOut, int32_t* msOut,
                              char* errOut, int32_t errCap, int32_t* bodyLenOut) {
    int32_t i, rc = -1;
    if (bodyOut && bodyCap > 0) bodyOut[0] = 0;
    if (errOut && errCap > 0) errOut[0] = 0;
    if (statusOut) *statusOut = 0;
    if (msOut) *msOut = 0;
    if (bodyLenOut) *bodyLenOut = 0;
    if (!id || !id[0]) return -1;
    aowl_hn_lock();
    for (i = 0; i < AOWL_HN_SLOTS; i++) {
        AowlHnSlot* s = &g_hn.slot[i];
        if (!s->used || !aowl_hn_ieq(s->id, id)) continue;
        if (!s->done) { rc = 0; break; }
        rc = 1;
        if (statusOut) *statusOut = s->status;
        if (msOut) *msOut = (int32_t)(s->endMs - s->startMs);
        if (bodyLenOut) *bodyLenOut = s->respLen;
        aowl_hn_copy(errOut, errCap, s->err);
        if (bodyOut && bodyCap > 0 && s->respBody) {
            int32_t n = s->respLen;
            if (n > bodyCap - 1) n = bodyCap - 1;
            memcpy(bodyOut, s->respBody, (size_t)n);
            bodyOut[n] = 0;
        }
        break;
    }
    aowl_hn_unlock();
    return rc;
}

static void aowl_hn_stats(int32_t* inflight, int32_t* allowN, int32_t* maxBody,
                          int32_t* maxInflight, int32_t* enabled) {
    aowl_hn_lock();
    if (inflight) *inflight = aowl_hn_inflight();
    if (allowN) *allowN = g_hn.allowN;
    if (maxBody) *maxBody = g_hn.maxBody;
    if (maxInflight) *maxInflight = g_hn.maxInflight;
    if (enabled) *enabled = g_hn.enabled;
    aowl_hn_unlock();
}

/* Is winhttp.dll usable at all? Resolves it if it has not been resolved yet,
 * so the boot log can say so once rather than a mod discovering it later. */
static int32_t aowl_hn_api_ok(void) { return aowl_hn_api(); }

#endif /* AOWLSPT_HOSTNET_H */
