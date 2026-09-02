## aowlspt-backend — the game backend, in nimony.
##
##     aowlspt-backend --root D:\Aowlspt --port 6969
##
## An HTTP server that loads aowlspt mods and gives them routes, a database and
## events. It is the other half of the pipeline: the same mods, written the same
## way, with `aowlspt/server` on this side where the client has `aowlspt/game`.
##
## Why this exists rather than SPT's server: SPT 4.x targets a pre-1.0 client,
## and the whole point here is post-1.0. Rather than wait for someone else's
## server to move, this one is ours — which also means the backend and the
## client host share an ABI, a mod format and a build command.
##
## What it does **not** claim to be is a finished Tarkov emulator. Serving the
## game's several hundred endpoints with correct data is a body of work an order
## of magnitude larger than this, and it lives in mods rather than in here. This
## is the pipeline: sockets, the client's wire framing, routing, a database, the
## mod ABI, and the plugin API on top. What runs on it is content.
##
## Two protocol details are load-bearing and cost real time to rediscover:
##
##   * Request **and** response bodies are zlib-framed. A server that answers
##     plain JSON gets a client that fails to parse it, with no error either
##     side. Unframed requests are still accepted, because the tools people
##     debug with do not compress.
##   * The session id is a 24-character hex MongoId. Anything else is rejected
##     upstream of any route.

import std/[strutils, syncio, cmdline, json]
import aowlsptinstall/winfs
import aowlsptinstall/log as console
import modhost
import modcontrol
import modstore
import jsonpath
import jsondb
import wire
import websocket
import perfphase

# The shim first: it defines the ABI types the route trampoline needs, and
# the `aowl_sys_*` helpers. `aowlspt_hostboot.h` is deliberately not included
# -- its constructor calls a symbol only the client host defines.
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
# And the revision-5 arming, which is its own header for the reason
# `aowlspt_live.h` is: it names an `aowlspt_nim_*` function only this binary
# defines, so a host that has no websocket must not be made to link it.
{.emit: """#include "aowlspt_notify.h" """.}

# ------------------------------------------------------------- crash report
#
# The one thing a native access violation does not do on its own is say where.
# A Nim exception is caught and logged with a stack; a use-after-free or a null
# deref in the C net engine (`aowlspt_net.h`) is a first-chance SEH exception on
# a raw `CreateThread` worker or the poller, with no `__try` above it -- gcc has
# none -- so the process simply vanishes. That is exactly the shape of the raid
# entry crash: the log's last line is an ordinary request and then nothing.
#
# This installs two handlers that share one report body. A first-chance vectored
# handler catches the terminal codes -- including a heap-corruption fast-fail
# (`STATUS_HEAP_CORRUPTION` / `__fastfail`), which the runtime terminates on
# WITHOUT ever calling an unhandled-exception filter, so the filter alone caught
# nothing and the process just vanished. It logs and returns `CONTINUE_SEARCH`,
# never swallowing, so the repo's deliberate-and-recovered handlers
# (`aowl_seh_veh`, `mr_veh`, neither armed in the serving backend) still work and
# a real fault still dies. A `SetUnhandledExceptionFilter` remains as the
# last-resort catch for an ordinary unhandled fault that was not a fast-fail, and
# terminates without a WER dialog. Each writes the faulting instruction as
# module+offset (the map file turns that into a symbol), the touched address, the
# thread, and a return-address stack -- to stderr and the backend log.
# `RtlCaptureStackBackTrace` and `GetModuleHandleExA` are all it uses; a crash
# handler must not allocate, take a lock, or load `dbghelp`, and this does none.
{.emit: """
#include <stdio.h>

static char aowl_crash_logpath[1024];
static char aowl_crash_markerpath[1040];
static void aowl_crash_set_logpath(const char* p, int32_t n) {
    int i = 0;
    if (n > (int)sizeof(aowl_crash_logpath) - 1)
        n = (int)sizeof(aowl_crash_logpath) - 1;
    for (; i < n; i++) aowl_crash_logpath[i] = p[i];
    aowl_crash_logpath[i] = 0;
    /* The marker is a tiny sibling file next to the log. It is what survives a
     * heap-corruption fast-fail: the append-to-log path below goes through the
     * CRT and a corrupt heap can make fopen itself fail, but the marker is
     * written with raw Win32 (CreateFile/WriteFile/FlushFileBuffers), touches no
     * CRT heap, and is force-flushed to the medium before the process dies. Its
     * mere existence after the process is gone means "it crashed" rather than
     * "it was killed" -- the launcher watchdog and a human both read it that
     * way. Delete any stale one from a previous run here at startup so a fresh
     * boot never inherits an old crash's marker. */
    {
        int j = 0;
        for (; j < i && j < (int)sizeof(aowl_crash_markerpath) - 8; j++)
            aowl_crash_markerpath[j] = aowl_crash_logpath[j];
        const char* suffix = ".fatal";
        for (int k = 0; suffix[k]; k++) aowl_crash_markerpath[j++] = suffix[k];
        aowl_crash_markerpath[j] = 0;
        DeleteFileA(aowl_crash_markerpath);
    }
}

/* Raw-Win32 marker write. No CRT, no heap, no locks: safe on a corrupt heap,
 * which is exactly when it is needed. Force the bytes to the medium with
 * FlushFileBuffers before returning, because the very next thing to run is the
 * process terminator and a buffered write would be lost. */
static void aowl_crash_marker(const char* kind, DWORD code, void* rip) {
    if (!aowl_crash_markerpath[0]) return;
    HANDLE h = CreateFileA(aowl_crash_markerpath, GENERIC_WRITE, 0, NULL,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    char line[512];
    int len = snprintf(line, sizeof(line),
        "aowlspt-backend FATAL %s (0x%08lx) at %p thread %lu\n",
        kind, (unsigned long)code, rip, (unsigned long)GetCurrentThreadId());
    if (len > 0) {
        DWORD wrote = 0;
        WriteFile(h, line, (DWORD)len, &wrote, NULL);
    }
    FlushFileBuffers(h);
    CloseHandle(h);
}

/* Cleared on a clean shutdown so a marker never lingers past an orderly exit. */
static void aowl_crash_clear_marker(void) {
    if (aowl_crash_markerpath[0]) DeleteFileA(aowl_crash_markerpath);
}

/* stderr first -- it needs nothing and survives a log path that could not be
 * opened -- then the log, appended so the crash lands under the last request
 * the poller managed to write. No buffering games: flush each, since the next
 * thing to run is the default terminator. */
static void aowl_crash_write(const char* s) {
    fputs(s, stderr);
    fflush(stderr);
    if (aowl_crash_logpath[0]) {
        FILE* f = fopen(aowl_crash_logpath, "a");
        if (f) { fputs(s, f); fflush(f); fclose(f); }
    }
}

/* The basename of a module path, so the report reads `aowlspt-backend.exe+0x..`
 * rather than an absolute path per frame. */
static const char* aowl_crash_basename(const char* p, DWORD n) {
    const char* b = p;
    for (DWORD i = 0; i < n; i++)
        if (p[i] == '\\' || p[i] == '/') b = p + i + 1;
    return b;
}

/* Resolve an address to `module+offset`, writing the module basename into
 * `nameOut` (which must hold MAX_PATH). Offset is returned; the name is `?` and
 * the offset the raw address when the address is in no loaded module. */
static uintptr_t aowl_crash_resolve(void* addr, char* nameOut) {
    HMODULE m = NULL;
    nameOut[0] = '?'; nameOut[1] = 0;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)addr, &m) && m) {
        char path[MAX_PATH];
        DWORD n = GetModuleFileNameA(m, path, (DWORD)sizeof(path));
        if (n > 0) {
            const char* base = aowl_crash_basename(path, n);
            int i = 0;
            while (base[i] && i < MAX_PATH - 1) { nameOut[i] = base[i]; i++; }
            nameOut[i] = 0;
        }
        return (uintptr_t)addr - (uintptr_t)m;
    }
    return (uintptr_t)addr;
}

/* STATUS codes the SDK headers do not always define. */
#ifndef STATUS_HEAP_CORRUPTION
#  define STATUS_HEAP_CORRUPTION 0xC0000374L
#endif
#ifndef STATUS_STACK_BUFFER_OVERRUN
#  define STATUS_STACK_BUFFER_OVERRUN 0xC0000409L   /* __fastfail lands here */
#endif

/* The whole report: what faulted, where (module+offset), the touched address,
 * the thread, and a return-address backtrace. Shared by the first-chance VEH
 * and the last-resort filter. `origin` says which caught it. */
static void aowl_crash_report(EXCEPTION_POINTERS* ep, const char* origin) {
    EXCEPTION_RECORD* er = ep->ExceptionRecord;
    CONTEXT* c = ep->ContextRecord;
    void* rip = (void*)(uintptr_t)c->Rip;
    DWORD code = er->ExceptionCode;

    const char* kind =
        code == EXCEPTION_ACCESS_VIOLATION     ? "ACCESS_VIOLATION" :
        (DWORD)STATUS_HEAP_CORRUPTION == code  ? "HEAP_CORRUPTION" :
        (DWORD)STATUS_STACK_BUFFER_OVERRUN == code ? "STACK_BUFFER_OVERRUN/fastfail" :
        code == EXCEPTION_IN_PAGE_ERROR        ? "IN_PAGE_ERROR" :
        code == EXCEPTION_ILLEGAL_INSTRUCTION  ? "ILLEGAL_INSTRUCTION" :
        code == EXCEPTION_STACK_OVERFLOW       ? "STACK_OVERFLOW" : "exception";
    void* addr = er->NumberParameters >= 2
        ? (void*)(uintptr_t)er->ExceptionInformation[1] : NULL;
    long rw = er->NumberParameters >= 1 ? (long)er->ExceptionInformation[0] : -1;

    /* The survivable breadcrumb, written before anything that could touch a
     * corrupt heap. If everything below is lost to the fast-fail, this remains. */
    aowl_crash_marker(kind, code, rip);

    char modname[MAX_PATH];
    uintptr_t off = aowl_crash_resolve(rip, modname);

    char line[1024];
    snprintf(line, sizeof(line),
        "\n*** aowlspt-backend FATAL %s (0x%08lx, %s) ***\n"
        "    at   %p  %s+0x%llx\n"
        "    %s address %p  (thread %lu)\n",
        kind, (unsigned long)code, origin,
        rip, modname, (unsigned long long)off,
        rw == 0 ? "reading" : rw == 1 ? "writing" : rw == 8 ? "executing"
                                                            : "touching",
        addr, (unsigned long)GetCurrentThreadId());
    aowl_crash_write(line);

    /* Return addresses only -- no symbol lookup, no dbghelp. Each is
     * module+offset, which the .map the build emits turns into a function. */
    void* frames[24];
    USHORT got = RtlCaptureStackBackTrace(0, 24, frames, NULL);
    for (USHORT i = 0; i < got; i++) {
        char fn[MAX_PATH];
        uintptr_t fo = aowl_crash_resolve(frames[i], fn);
        char fl[600];
        snprintf(fl, sizeof(fl), "    [%2u] %p  %s+0x%llx\n",
                 (unsigned)i, frames[i], fn, (unsigned long long)fo);
        aowl_crash_write(fl);
    }
    aowl_crash_write("*** end crash report ***\n\n");
}

/* First-chance VEH. This is the half that catches the class the filter cannot:
 * a heap-corruption fast-fail (`STATUS_HEAP_CORRUPTION` / the `__fastfail` that
 * `STATUS_STACK_BUFFER_OVERRUN` rides in on) is terminated by the runtime
 * WITHOUT ever consulting `SetUnhandledExceptionFilter`, so the last logged line
 * is an ordinary request and the process is simply gone -- the exact signature
 * the retest saw. A vectored handler runs at first-chance, before that.
 *
 * Three rules keep it from doing harm on a shared exception path:
 *   * it acts only on the terminal codes and returns `CONTINUE_SEARCH` for
 *     everything else, so a benign C++ throw or debugger event passes through;
 *   * it NEVER converts or swallows -- always `CONTINUE_SEARCH` -- so the repo's
 *     deliberate-and-recovered handlers (`aowl_seh_veh`, `mr_veh`, neither of
 *     which is even armed in the serving backend) still get their fault and the
 *     process still dies for a real one;
 *   * a re-entrancy latch and a small cap stop a corruption that repeats on
 *     every thread from recursing through the logger or filling the log. */
static volatile LONG aowl_crash_inveh = 0;
static volatile LONG aowl_crash_count = 0;

static LONG CALLBACK aowl_crash_veh(EXCEPTION_POINTERS* ep) {
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION &&
        code != (DWORD)STATUS_HEAP_CORRUPTION &&
        code != (DWORD)STATUS_STACK_BUFFER_OVERRUN &&
        code != EXCEPTION_IN_PAGE_ERROR &&
        code != EXCEPTION_ILLEGAL_INSTRUCTION &&
        code != EXCEPTION_STACK_OVERFLOW)
        return EXCEPTION_CONTINUE_SEARCH;
    if (InterlockedCompareExchange(&aowl_crash_inveh, 1, 0) != 0)
        return EXCEPTION_CONTINUE_SEARCH;
    if (InterlockedIncrement(&aowl_crash_count) <= 3)
        aowl_crash_report(ep, "first-chance");
    InterlockedExchange(&aowl_crash_inveh, 0);
    return EXCEPTION_CONTINUE_SEARCH;
}

/* Last resort: a genuinely unhandled fault that was NOT a fast-fail. Reached
 * only if the VEH let it through (it always does) and nothing recovered it. It
 * terminates rather than falling through to WER, so a headless loopback server
 * dies cleanly instead of hanging on an error dialog the main session cannot
 * dismiss. */
static LONG WINAPI aowl_crash_filter(EXCEPTION_POINTERS* ep) {
    if (InterlockedCompareExchange(&aowl_crash_inveh, 1, 0) == 0) {
        if (InterlockedIncrement(&aowl_crash_count) <= 3)
            aowl_crash_report(ep, "unhandled");
        InterlockedExchange(&aowl_crash_inveh, 0);
    }
    aowl_crash_write("*** process terminating ***\n\n");
    return EXCEPTION_EXECUTE_HANDLER;
}

static void aowl_crash_install(void) {
    AddVectoredExceptionHandler(1, aowl_crash_veh);
    SetUnhandledExceptionFilter(aowl_crash_filter);
}
""".}

proc cCrashInstall() {.importc: "aowl_crash_install", nodecl.}
proc cCrashSetLog(p: HostPtr; n: int32) {.importc: "aowl_crash_set_logpath",
                                          nodecl.}
proc cCrashClearMarker() {.importc: "aowl_crash_clear_marker", nodecl.}

proc cNetServe(port, workers: int32): int32 {.importc: "aowl_net_serve", nodecl.}
# Bind the listening port and hold it, without listening on it yet. This is the
# first thing `main` does that can fail, and it is deliberately separate from
# `aowl_net_serve`: see `reservePort` below for why the two halves are that far
# apart, and `aowlspt_net.h` for why the `listen` may not move up here with the
# bind.
proc cNetReserve(port: int32): int32 {.importc: "aowl_net_reserve", nodecl.}
proc cNetPortHolder(port: int32; buf: ptr char; cap: int32): int32 {.
  importc: "aowl_net_port_holder", nodecl.}
# The TLS half of the serve loop. `aowl_net_serve_tls` builds the OpenSSL server
# context from the PEM cert+key, sets the poller into TLS mode, and starts it --
# everything above the byte stream (framing, routing, the database, the mod API)
# is the same as the plain path, because TLS is a transport shim under it. See
# `aowlspt_tls.h` for why the OpenSSL DLLs are loaded by name at runtime rather
# than linked, and `aowlspt_net.h` for how the handshake folds into the WSAPoll
# loop. `cNetTlsError` is the reason a `--tls` start failed, for the log.
proc cNetServeTls(port, workers: int32; cert, key: cstring): int32 {.
  importc: "aowl_net_serve_tls", nodecl.}
# The second listener, always plain HTTP, for the asset routes. See
# `g_listenSock2` in `aowlspt_net.h` for the whole of why it exists: Unity's
# `UnityWebRequest` asset fetches validate our self-signed certificate and are
# never sent, silently. Binds *and* listens; returns 0 on any failure, having
# started nothing, which the caller reports as a lost asset route rather than a
# failed server.
proc cNetListenPlain(port: int32): int32 {.
  importc: "aowl_net_listen_plain", nodecl.}
proc cNetTlsError(): cstring {.importc: "aowl_net_tls_error", nodecl.}
proc cNetTlsErrorLen(): int32 {.importc: "aowl_net_tls_error_len", nodecl.}
proc cNetTlsReady(): int32 {.importc: "aowl_net_tls_ready", nodecl.}
proc cNetTlsGenCert(openssl, cert, key: cstring): int32 {.
  importc: "aowl_net_tls_gencert", nodecl.}
proc cNetStop() {.importc: "aowl_net_stop", nodecl.}
proc cNetRunning(): int32 {.importc: "aowl_net_running", nodecl.}
proc cNetSend(sock: uint64; buf: HostPtr; len: int32): int32 {.
  importc: "aowl_net_send", nodecl.}
proc cNetLastError(): int32 {.importc: "aowl_net_last_error", nodecl.}
# `aowl_net_recv` is gone from here: this file no longer reads a socket. The
# poller in `aowlspt_net.h` does that, and hands down a complete request. It is
# still in the header for `wire.nim`, whose client sockets are blocking.
# `aowl_net_set_timeout` was named here too and is gone from the header as
# well: it had no caller anywhere in this repo, and `wire.nim` sets
# `SO_RCVTIMEO` itself, inline in its own `{.emit.}` block.
proc cSessionLock(id: HostPtr; len: int32): int32 {.
  importc: "aowl_session_lock", nodecl.}
proc cSessionUnlock(slot: int32) {.
  importc: "aowl_session_unlock", nodecl.}
proc cArmNotify(hostBlock: HostPtr) {.
  importc: "aowl_hostapi_arm_notify", nodecl.}
# The websocket half of `aowlspt_net.h`. These live here and nowhere else:
# nimony emits one translation unit per module and everything in `abi/` is
# `static`, so a second module importing the same header gets its own empty
# copy of the connection table -- which is exactly what happened while
# `websocket.nim` called `aowl_ws_adopt` itself, and the symptom was a correct
# `101` followed instantly by a close.
proc cWsAdopt(sock: uint64): int64 {.importc: "aowl_ws_adopt", nodecl.}
proc cWsSend(ticket: int64; buf: HostPtr; len: int32): int32 {.
  importc: "aowl_ws_send", nodecl.}
proc cLock() {.importc: "aowl_lock", nodecl.}
proc cUnlock() {.importc: "aowl_unlock", nodecl.}

# ------------------------------------------------- the registration tables
#
# `gRoutes` and `gSubs` are the same shape of shared state as the database, and
# had the same hole: read on every request, from sixteen workers, and *rebuilt*
# from the serve loop when a mod is taken out while the server is serving --
# which is not a hypothetical, it is what `aowl test` does with `livectl` every
# run, and what the mod manager panel does from the game.
#
# `dropModRegistrations` assigned a freshly built sequence over each of them.
# That drops the last reference to the old buffer, and a worker walking it in
# `matchRoute` is then walking freed memory -- the same use-after-free the
# document had, one table over. `hostRouteRegister` appending from a mod's
# thread is the same race with a smaller window: a growing `seq` reallocates.
#
# One reader-writer lock over both, because both are rebuilt by the same pass
# and holding two would be an ordering to get wrong. Shared for the walk,
# exclusive for a registration or a teardown. A walk is a few dozen string
# compares and never runs a mod's code with the lock held -- see `matchRoute`
# and `deliverEvent`, both of which copy out what they need and let go before
# calling anything, which is what keeps a handler that registers a route from
# deadlocking against the walk that dispatched to it.
{.emit: """
static SRWLOCK aowl_reg_lock;
static void aowl_reg_read_begin(void)  { AcquireSRWLockShared(&aowl_reg_lock); }
static void aowl_reg_read_end(void)    { ReleaseSRWLockShared(&aowl_reg_lock); }
static void aowl_reg_write_begin(void) { AcquireSRWLockExclusive(&aowl_reg_lock); }
static void aowl_reg_write_end(void)   { ReleaseSRWLockExclusive(&aowl_reg_lock); }

/* `gRequests` is a counter and nothing more, and it was `inc`remented from
 * every worker at once -- which on a non-atomic read-modify-write loses counts
 * and, worse, is the kind of thing a reader of the status route quotes as if
 * it meant something. */
static LONG64 aowl_req_count = 0;
static int64_t aowl_req_bump(void) {
    return (int64_t)InterlockedIncrement64(&aowl_req_count);
}
static int64_t aowl_req_read(void) {
    return (int64_t)InterlockedCompareExchange64(&aowl_req_count, 0, 0);
}
""".}

proc cRegRead() {.importc: "aowl_reg_read_begin", nodecl.}
proc cRegReadEnd() {.importc: "aowl_reg_read_end", nodecl.}
proc cRegWrite() {.importc: "aowl_reg_write_begin", nodecl.}
proc cRegWriteEnd() {.importc: "aowl_reg_write_end", nodecl.}
proc cReqBump(): int64 {.importc: "aowl_req_bump", nodecl.}
proc cReqRead(): int64 {.importc: "aowl_req_read", nodecl.}

const
  HostName = "aowlspt-backend"
  HostVersion = "0.1.0"
  RouteStatic = 0'i32
  RouteDynamic = 1'i32
  HeadCapBytes = 65536
    ## How many header bytes a request may take before it is refused `431`.
    ## Must match `AOWL_HEAD_CAP` in `aowlspt_net.h`, which is the side that
    ## stops reading; this is only the number the refusal quotes.

  # The three receive deadlines -- 5 s idle on a kept-alive connection, 3 s to
  # a complete header, 5 s from there to a complete body -- and the 512-request
  # keep-alive cap used to be constants here, because the loop that enforced
  # them was here. They are `AOWL_IDLE_MS`, `AOWL_HEAD_MS`, `AOWL_BODY_MS` and
  # `AOWL_KEEPALIVE_MAX` in `aowlspt_net.h` now, with the same values and the
  # same reasoning, because the poller is what holds the clock. Nothing in this
  # file waits for a socket any more, so there was no honest way to keep them
  # here as well; two copies of a deadline is one copy that goes stale.

  WsaAddrInUse = 10048
    ## `WSAEADDRINUSE`. What a bind against a port somebody else is listening
    ## on answers, now that the listening socket asks for the port exclusively.
  WsaAccess = 10013
    ## `WSAEACCES`. The same collision seen from the other side: it is what
    ## Windows answers when the port is held by a socket that asked for it
    ## exclusively, and both have to be recognised or half the collisions are
    ## reported as an unexplained number.

  MaxBodyBytes = 16 * 1024 * 1024
    ## The largest request body this server will hold, framed or inflated.
    ##
    ## It is a bound on the *declared* length as well as on the inflated one,
    ## and that half is not a nicety: the body buffer used to be allocated at
    ## whatever `Content-Length` said, so a 90-byte request saying
    ## `Content-Length: 9000000000000000000` allocated nine exabytes, got an
    ## empty seq back, and took the whole process down on the bounds check that
    ## followed. One client, one request, no game server. A declared length
    ## over this is refused with 413 before anything is allocated.
    ##
    ## The other half is the amplification. Sixty-four kilobytes of zlib expand
    ## to sixty-four megabytes of one repeated byte, and a ceiling set where a
    ## bomb like that still fits is a ceiling that buys nothing: the pool is
    ## sixteen workers, so it is sixteen of whatever this number is, in flight,
    ## for the price of half a megabyte on the wire. Sixteen megabytes is far above
    ## the largest request the game makes -- `match/local/end` posts the whole
    ## profile document and that is single-digit megabytes for a full stash --
    ## and low enough that the bomb is refused rather than served.

# --------------------------------------------------------------- state

type
  Route = object
    url: string
    kind: int32
    cb: HostPtr
    user: HostPtr
    modIndex: int

  Sub = object
    name: string
    cb: HostPtr
    user: HostPtr
    modIndex: int

  Timer = object
    dueMs: int64
    cb: HostPtr
    user: HostPtr
    modIndex: int
      ## Whose timer this is. Only used when that mod is taken out: a timer
      ## holds a function pointer into the mod's library, so one left behind
      ## comes due after `FreeLibrary` and calls into unmapped memory.

var gRoutes: seq[Route] = @[]
var gSubs: seq[Sub] = @[]
var gTimers: seq[Timer] = @[]
var gRoot = ""
var gPort = 6969
# `gRequests` lives in an interlocked counter in the emit block above; this is
# the read side of it. It was a plain `var` incremented from every worker.
proc gRequests(): int = int(cReqRead())

# --------------------------------------------------------------- bytes
#
# `toBytes` / `fromBytes` live in `wire.nim` now and go through `copyMem`.
# They used to be per-byte loops here as well, which is invisible on a 200-byte
# request and is the largest single cost on a 4 MB one: a route body has to
# cross from the mod's buffer into a string and then into a byte buffer, and
# doing either of those a byte at a time costs more than deflating it.

proc inflateInto(src: WirePtr; len: int; into: var string): bool =
  ## One zlib stream into a string, growing the destination rather than
  ## guessing its size once.
  ##
  ## Sized to the body, then grown on failure -- rather than 64x with a 64 KB
  ## floor, which is what this used to do unconditionally.
  ##
  ## The floor was the expensive half. Every request the client makes carries a
  ## body of a few hundred bytes, so every one of them allocated and zeroed
  ## 64 KB to inflate 200 bytes into, and the allocation cost more than the
  ## inflate did. 16x covers JSON of this shape in a single pass; the retry is
  ## what keeps the cases it does not cover slower rather than refused, and the
  ## ceiling is still there so a malformed length cannot become an allocation
  ## attack.
  ##
  ## The buffer is allocated once and re-allocated across the loop rather than
  ## inside it, and the length handed to `inflate` is **the buffer's own**
  ## rather than the `cap` it was asked for. That is not style. A `var dst`
  ## declared inside the loop is destroyed at the end of every iteration, and
  ## the replacement did not behave as its `cap` claimed: every body that
  ## inflated to more than 65,536 bytes was refused with a 400, deterministically
  ## and only on a retry -- so a request whose first guess was big enough went
  ## through and the same bytes compressed better did not.
  ## `/client/match/local/end` posts the whole profile document, which is past
  ## 64 KB for any real profile, so this was a client that could not come back
  ## from a raid rather than anything a fuzzer had to find. Reading the length
  ## off the buffer makes the two impossible to disagree.
  into = ""
  if len <= 0:
    return false
  var cap = len * 16
  if cap < 4096: cap = 4096
  if cap > MaxBodyBytes: cap = MaxBodyBytes
  var dst = newSeq[byte](cap)
  var tries = 0
  while tries < 4:
    let room = dst.len
    let n = cZlibInflate(src, int32(len),
                         cast[WirePtr](addr dst[0]), int32(room))
    if n >= 0'i32:
      into = fromBytes(dst, int(n))
      return true
    if room >= MaxBodyBytes:
      return false
    var grown = room * 8
    if grown > MaxBodyBytes: grown = MaxBodyBytes
    dst = newSeq[byte](grown)
    inc tries
  result = false

proc inflateBody(raw {.byref.}: seq[byte]; rawLen: int; into: var string): bool =
  ## A request body, in whatever the client wrapped it in.
  ##
  ## `byref` on the buffer is not a micro-optimisation: a by-value `seq`
  ## parameter copies the whole request body on entry, and this is called with
  ## the raw receive buffer.
  ##
  ## Three shapes reach this, and they have to be tried in this order:
  ##
  ##   1. plain `zlib(json)` -- a pre-1.0 client, and every tool in this repo
  ##   2. the post-1.0 **envelope**: a length-keyed byte shuffle over
  ##      `[int32 size][zlib(json)]`, or over raw JSON on the `libraries`
  ##      routes. See `wire.bsgUnwrap`.
  ##   3. neither -- `/client/metadata` posts plain JSON -- passed through
  ##
  ## The envelope is what was missing, and its absence did not look like a bug.
  ## A shuffled body is not zlib-framed, so it took the pass-through branch and
  ## reached the route handler as noise, with a 200 and no warning. Every route
  ## that ignores its request body still worked, which is most of the menu; the
  ## client booted to the character screen against a server that had never read
  ## anything it was sent. What broke was creating a profile, moving an item,
  ## ending a raid.
  ##
  ## **`looksFramed` is a guess and is treated as one.** It reads two bytes, so
  ## roughly one shuffled body in five hundred opens with a valid zlib header
  ## by chance -- and one does, in the 149-body capture this is tested against
  ## (`/client/mail/dialog/list`, seq 458, whose shuffled form begins `78 da`).
  ## Deciding on the header alone sent that body down the plain path, where the
  ## inflate failed, and then out of the function as noise. So the header only
  ## picks the order to try things in; a failed inflate falls through to the
  ## envelope rather than out.
  into = ""
  if rawLen <= 0:
    return true
  let src = cast[WirePtr](addr raw[0])
  let looksFramed = cZlibFramed(src, int32(rawLen)) != 0'i32

  if looksFramed and inflateInto(src, rawLen, into):
    return true

  # The envelope, on a copy: unwrapping is destructive and the pass-through
  # below still needs the original bytes.
  var unwrapped = newSeq[byte](rawLen)
  copyMem(addr unwrapped[0], addr raw[0], rawLen)
  var payloadLen = 0
  if bsgUnwrap(unwrapped, rawLen, payloadLen):
    let payload = cast[WirePtr](cast[uint](addr unwrapped[0]) + 4'u)
    if inflateInto(payload, payloadLen, into):
      return true
    # An envelope over raw JSON rather than over a zlib stream. The `libraries`
    # routes post their payload that way.
    into = bytesAt(unwrapped, 4, payloadLen)
    return true

  if not looksFramed and inflateInto(src, rawLen, into):
    # Framed-looking bodies were already tried above; this catches the reverse
    # collision, where a plain zlib body's header happens not to validate.
    return true

  if looksFramed:
    # It announced itself as a zlib stream, it is not one, and it is not an
    # envelope either. Refused rather than passed through: passing it through
    # is how a body becomes noise the handler cannot tell from an empty
    # request, which is the whole failure this function was rewritten to stop.
    return false

  # Not framed and not enveloped -- `/client/metadata` posts plain JSON. The
  # body is what it is.
  into = fromBytes(raw, rawLen)
  result = true

proc deflateBody(text {.byref.}: string; into: var seq[byte];
                 outLen: var int): bool =
  ## Deflates straight out of the string.
  ##
  ## It used to copy `text` into a `seq[byte]` first, one byte at a time, which
  ## on the static tables was more wall time than the compression itself.
  outLen = 0
  into = @[]
  if text.len == 0:
    return true
  let cap = cZlibBound(int32(text.len))
  into = newSeq[byte](int(cap))
  let n = cZlibDeflate(cast[WirePtr](readRawData(text)), int32(text.len),
                       cast[WirePtr](addr into[0]), cap)
  if n < 0'i32:
    return false
  outLen = int(n)
  result = true

# --------------------------------------------------- the compressed-body cache
#
# The static tables are the same bytes on every request and deflating 4 MB of
# JSON costs ~45 ms. Nothing about them changes between requests, so the second
# and every later request for one should not pay that again.
#
# **The cache key is the response text itself**, not the URL and not a database
# revision counter. That is the whole design. A key derived from anything else
# has to be invalidated when the answer changes, and the answer here can change
# for reasons this module cannot see -- `dbPatch` from a timer, a mod rebuilding
# a table, a route that varies its answer by session. Keying on the bytes makes
# a stale hit impossible by construction: an entry can only be returned for a
# body byte-identical to the one it was built from. The price is a `memcmp` of
# the body per request, which at 4 MB is under a millisecond against the 45 the
# deflate costs.

const
  ZCacheMinBody = 8192   ## below this, the compare costs more than the deflate
  ZCacheMax = 32
    ## entries.
    ##
    ## It was 12, on the note that "the emulator has seven bodies this large".
    ## MEASURED with `tools/loadpathbench.py` over the real load path, that is
    ## no longer true, and the shortfall was visible: 15 distinct bodies over
    ## 8 KB go out before the client's SECOND `/client/items`, so the items
    ## entry -- the 15 MB one, the most expensive deflate in the process -- had
    ## already been evicted when that duplicate arrived. It cost 246 ms against
    ## the 75 ms a hit costs.

type
  ZEntry = object
    text: string
    packed: seq[byte]
    packedLen: int
    stamp: int64

var gZCache: seq[ZEntry] = @[]
var gZStamp = 0'i64
var gZHits = 0
var gZMisses = 0
var gZSkipped = 0

proc zFind(body {.byref.}: string): int =
  ## Caller holds the lock. Length first: it rejects every non-candidate
  ## without touching the bytes.
  ##
  ## `byref`, here and on `cachedDeflate` and `sendResponse` below, for the
  ## same reason `inflateBody` has it: a by-value string parameter copies the
  ## whole body on entry, and the whole body is four megabytes for
  ## `/client/items`. The response used to cross three of those signatures on
  ## its way to the socket, which is three copies of the answer per request
  ## that nothing reads.
  result = -1
  for i in 0 ..< gZCache.len:
    if gZCache[i].text.len == body.len and gZCache[i].text == body:
      return i

proc cachedDeflate(body {.byref.}: string; into: var seq[byte];
                   outLen: var int): bool =
  if body.len < ZCacheMinBody:
    inc gZSkipped
    return deflateBody(body, into, outLen)

  cLock()
  var hit = zFind(body)
  if hit >= 0:
    inc gZStamp
    gZCache[hit].stamp = gZStamp
    inc gZHits
    outLen = gZCache[hit].packedLen
    into = newSeq[byte](if outLen > 0: outLen else: 1)
    if outLen > 0:
      copyMem(addr into[0], addr gZCache[hit].packed[0], outLen)
    cUnlock()
    return true
  inc gZMisses
  cUnlock()

  # Deflated outside the lock. Holding it here would serialise every worker
  # behind the first one to ask for a table, which is exactly the moment the
  # client asks for all of them at once.
  if not deflateBody(body, into, outLen):
    return false

  cLock()
  # Re-checked, because two workers can miss the same body at the same time and
  # the second one must not add a duplicate entry that then evicts a live one.
  if zFind(body) < 0:
    var slot = -1
    if gZCache.len >= ZCacheMax:
      slot = 0
      for i in 1 ..< gZCache.len:
        if gZCache[i].stamp < gZCache[slot].stamp:
          slot = i
    inc gZStamp
    var p = newSeq[byte](if outLen > 0: outLen else: 1)
    if outLen > 0:
      copyMem(addr p[0], addr into[0], outLen)
    let e = ZEntry(text: body, packed: p, packedLen: outLen, stamp: gZStamp)
    if slot >= 0: gZCache[slot] = e
    else: gZCache.add e
  cUnlock()
  result = true

# --------------------------------------------------------------- http

type
  Request = object
    verb: string
    url: string
    session: string
    body: string
    ok: bool
    keepAlive: bool
    ## The caller asked for an unencoded body.
    ##
    ## Every response here is zlib-deflated, because that is what the game
    ## client expects and it does not say so in a header -- so the server cannot
    ## infer it and answers that way by default. Anything else talking to this
    ## server (the overlay, a browser, `curl`) gets a body starting `78 9C` and
    ## no `Content-Encoding` to explain it, which looks like a corrupt answer
    ## rather than a compressed one. Sending `Accept-Encoding: identity` opts
    ## out. The game never sends that header, so its path is byte-identical.
    identity: bool
    ## `If-None-Match`, verbatim. See `gEtagOn`.
    ifNoneMatch: string

proc jsonQuoted(s: string): string =
  ## `s` as a JSON string literal, escapes and all.
  ##
  ## The 404 body carries the url that was asked for, and it used to carry it
  ## verbatim: a request for `/client/x"y` answered
  ## `{"err":"no route","url":"/client/x"y"}`, which no parser will read, and a
  ## url with a NUL or a stray 0x80 in it put bytes in a JSON string that are
  ## not text at all. Anything a request chose the bytes of has to go through
  ## here on its way into a response.
  result = "\""
  for ch in s:
    let c = ord(ch)
    if ch == '"': result.add "\\\""
    elif ch == '\\': result.add "\\\\"
    elif ch == '\n': result.add "\\n"
    elif ch == '\r': result.add "\\r"
    elif ch == '\t': result.add "\\t"
    elif c < 32 or c > 126:
      # Control bytes and everything outside plain ASCII as `\u00XX`. A url is
      # not promised to be UTF-8 -- the client picks the bytes -- and a lone
      # 0x80 copied into a response is a body the client cannot decode.
      const Hex = "0123456789abcdef"
      result.add "\\u00"
      result.add Hex[(c shr 4) and 15]
      result.add Hex[c and 15]
    else:
      result.add ch
  result.add "\""

proc isHexId(s: string): bool =
  ## SPT parses the session id as a MongoId: 24 hex characters, nothing else.
  if s.len != 24:
    return false
  for ch in s:
    let isDigit = ch >= '0' and ch <= '9'
    let isLower = ch >= 'a' and ch <= 'f'
    let isUpper = ch >= 'A' and ch <= 'F'
    if not (isDigit or isLower or isUpper):
      return false
  result = true

proc parseHead(head: string; r: var Request; contentLength: var int): bool =
  ## The request line and the two headers that matter. Everything else is
  ## ignored on purpose -- this speaks to one client, and a general HTTP header
  ## model would be more code than the parts of it that get used.
  contentLength = 0
  var sawLength = false
  r.ok = false
  let lines = splitLines(head)
  if lines.len == 0:
    return false

  let first = lines[0]
  let sp1 = find(first, " ")
  if sp1 < 0:
    return false
  let sp2 = find(first.substr(sp1 + 1), " ")
  if sp2 < 0:
    return false
  r.verb = first.substr(0, sp1 - 1)
  r.url = first.substr(sp1 + 1, sp1 + sp2)
  # The `/aowlspt/ui/` fallback settings page (docs/UI-API.md) runs its
  # fetches from an ordinary browser, which the Fetch spec forbids from ever
  # setting `Accept-Encoding` -- so it cannot ask for `identity` the way the
  # overlay's own worker thread does (header). A `?ident=1` query param says
  # the same thing through a channel the browser does not block. It changes
  # nothing about what any route returns (fact #123's JSON shapes are
  # untouched) -- only whether this one response goes out deflated, which is
  # exactly what the header spelling already lets any caller ask for.
  if find(r.url, "ident=1") >= 0:
    r.identity = true
  # HTTP/1.1 keeps the connection open unless the client says otherwise; 1.0
  # closes unless it says otherwise. Getting that default backwards is how a
  # server ends up holding a socket the client has already forgotten about.
  r.keepAlive = find(first, "HTTP/1.1") >= 0

  for i in 1 ..< lines.len:
    let l = lines[i]
    let colon = find(l, ":")
    if colon < 0:
      continue
    let name = toLowerAscii(strip(l.substr(0, colon - 1)))
    let value = strip(l.substr(colon + 1))
    if name == "content-length":
      var v = 0
      var any = false
      var digitsOnly = true
      for ch in value:
        if ch >= '0' and ch <= '9':
          # Clamped as it is read rather than after. `v * 10 + d` over a
          # nineteen-digit header wraps to a negative number, and a negative
          # length is a different bug in every place that then uses it.
          if v <= MaxBodyBytes:
            v = v * 10 + (ord(ch) - ord('0'))
          any = true
        else:
          digitsOnly = false
      # A value that is not `1*DIGIT` is refused rather than read as far as it
      # parses. It used to stop at the first non-digit and keep what it had, so
      # `-1`, `+5`, `0x10` and an empty value were all a length of *zero* -- and
      # a zero length means the bytes the client sent as the body are the
      # beginning of the next request on this connection. `aowl_scan_length`
      # read them the same way, so the framer and this agreed, and two parties
      # agreeing that a request ends before its body is what a request
      # smuggling primitive is. `backend/framelen.nim` sends each of them with
      # a request behind it and requires exactly one answer.
      if not any or not digitsOnly:
        return false
      # A second, disagreeing `Content-Length` is refused rather than having
      # one of them win: which one wins decides where this request ends and
      # the next one on the same connection begins, and a server that guesses
      # is a server two parties can be made to disagree about.
      if sawLength and v != contentLength:
        return false
      sawLength = true
      contentLength = v
    elif name == "accept-encoding":
      # Only `identity` is honoured, and only when it is asked for alone or
      # first: this is not a content negotiation, it is one client saying it
      # cannot inflate.
      let want = toLowerAscii(value)
      if find(want, "identity") >= 0 and find(want, "deflate") < 0:
        r.identity = true
    elif name == "if-none-match":
      r.ifNoneMatch = value
    elif name == "cookie":
      # PHPSESSID is what the client carries its session in.
      let at = find(value, "PHPSESSID=")
      if at >= 0:
        var s = ""
        var i2 = at + len("PHPSESSID=")
        while i2 < value.len and value[i2] != ';' and value[i2] != ' ':
          s.add value[i2]
          inc i2
        r.session = s
    elif name == "sessionid":
      r.session = value
    elif name == "connection":
      let v = toLowerAscii(value)
      if find(v, "close") >= 0:
        r.keepAlive = false
      elif find(v, "keep-alive") >= 0:
        r.keepAlive = true

  r.ok = true
  result = true

proc sendResponse(sock: uint64; status: string; body {.byref.}: string;
                  compress: bool; keepAlive = false;
                  contentType = "application/json") =
  var payload: seq[byte] = @[]
  var payloadLen = 0
  var compressed = false
  let tDeflate = perfNow()
  if compress and body.len > 0:
    if cachedDeflate(body, payload, payloadLen):
      compressed = true
    else:
      payloadLen = body.len
  else:
    payloadLen = body.len
  perfAdd(PhaseDeflate, tDeflate)

  var head = "HTTP/1.1 " & status & "\r\n"
  head.add "Content-Type: " & contentType & "\r\n"
  head.add "Content-Length: " & $payloadLen & "\r\n"
  head.add(if keepAlive: "Connection: keep-alive\r\n"
           else: "Connection: close\r\n")
  head.add "\r\n"

  let tSend = perfNow()
  # One `send` for a small answer, two for a large one.
  #
  # A header and a body sent separately are two system calls and two segments,
  # and the second one is at the mercy of Nagle: this socket has no
  # `TCP_NODELAY` on it, so a second small write can sit waiting for the first
  # to be acknowledged. On loopback that rarely bites and it is not a risk
  # worth carrying for the sake of avoiding a copy of a kilobyte -- which is
  # what almost every response here is, the large static tables being the
  # handful that are not.
  #
  # Above the threshold the copy would be the larger cost of the two and the
  # body goes out on its own, straight from wherever it already is: out of the
  # compressed buffer, or out of the response string via `readRawData`. That
  # path never allocated a copy just to have a pointer to hand `send`, and it
  # still does not.
  if payloadLen > 0 and payloadLen <= 65536:
    var whole = head
    if compressed:
      whole.add fromBytes(payload, payloadLen)
    else:
      whole.add body
    discard cNetSend(sock, cast[HostPtr](toCString(whole)), int32(whole.len))
  else:
    discard cNetSend(sock, cast[HostPtr](toCString(head)), int32(head.len))
    if payloadLen > 0:
      if compressed:
        discard cNetSend(sock, cast[HostPtr](addr payload[0]),
                         int32(payloadLen))
      else:
        discard cNetSend(sock, cast[HostPtr](readRawData(body)),
                         int32(payloadLen))
  perfAdd(PhaseSend, tSend)

proc sendNotModified(sock: uint64; etag: string; keepAlive: bool) =
  ## `304 Not Modified`, no body. See `gEtagOn`.
  var head = "HTTP/1.1 304 Not Modified\r\n"
  head.add "ETag: " & etag & "\r\n"
  head.add(if keepAlive: "Connection: keep-alive\r\n"
           else: "Connection: close\r\n")
  head.add "\r\n"
  discard cNetSend(sock, cast[HostPtr](toCString(head)), int32(head.len))

proc sendPacked(sock: uint64; packed {.byref.}: seq[byte]; packedLen: int;
                keepAlive: bool; etag = "") =
  ## A response whose deflated bytes already exist -- the warm cache below.
  ##
  ## Split out of `sendResponse` rather than threaded through it as another
  ## flag, because the whole point of the warm path is that the uncompressed
  ## body is never materialised: a `sendResponse` overload taking the text
  ## would put the 15 MB string back on the request path that this exists to
  ## take it off.
  var head = "HTTP/1.1 200 OK\r\n"
  head.add "Content-Type: application/json\r\n"
  head.add "Content-Length: " & $packedLen & "\r\n"
  if etag.len > 0:
    head.add "ETag: " & etag & "\r\n"
  head.add(if keepAlive: "Connection: keep-alive\r\n"
           else: "Connection: close\r\n")
  head.add "\r\n"
  let tSend = perfNow()
  if packedLen > 0 and packedLen <= 65536:
    var whole = head
    whole.add fromBytes(packed, packedLen)
    discard cNetSend(sock, cast[HostPtr](toCString(whole)), int32(whole.len))
  else:
    discard cNetSend(sock, cast[HostPtr](toCString(head)), int32(head.len))
    if packedLen > 0:
      discard cNetSend(sock, cast[HostPtr](addr packed[0]), int32(packedLen))
  perfAdd(PhaseSend, tSend)

# --------------------------------------------------------------- routing

proc matchRoute(url: string; into: var Route): bool =
  ## Exact matches win over prefixes, and the longest prefix wins among those.
  ## Registration order deciding it instead would make two mods' behaviour
  ## depend on their filenames.
  ##
  ## It answers with **the route** rather than with its index, and that is the
  ## concurrency fix rather than a tidy-up. An index is only meaningful while
  ## the table it indexes has not moved, and the table is rebuilt whenever a mod
  ## is unloaded -- so the old shape had a window between matching a route here
  ## and invoking it below (a window that contains the session lock, which is
  ## allowed to wait ten seconds) in which every index shifted by one. The
  ## request would then have been answered by whichever route slid into its
  ## place, or by reading past the end of a shorter table. A copy taken under
  ## the lock cannot go stale in a way that matters: the worst case is that a
  ## request already in flight is answered by the route that was there when it
  ## arrived, which is the only sensible reading of "unloaded while serving".
  result = false
  var bestLen = -1
  # Match on the PATH only: the client appends query strings (`?completed=True`,
  # `&retry=1`, conditional-GET params) and an exact `==` against the full url
  # then 404s a route that is really registered -- which the client retries
  # forever, stalling the load. The handler still receives the full `req.url`.
  var path = url
  let q = find(url, "?")
  if q >= 0: path = url.substr(0, q - 1)
  cRegRead()
  for i in 0 ..< gRoutes.len:
    if gRoutes[i].kind == RouteStatic:
      if gRoutes[i].url == path:
        into = gRoutes[i]
        cRegReadEnd()
        return true
    else:
      if path.len >= gRoutes[i].url.len and
         path.substr(0, gRoutes[i].url.len - 1) == gRoutes[i].url:
        if gRoutes[i].url.len > bestLen:
          bestLen = gRoutes[i].url.len
          into = gRoutes[i]
          result = true
  cRegReadEnd()

# The route callback goes through `aowl_invoke_route` in the shim, which is
# where it has to live: the trampoline needs the ABI's struct types, and those
# only exist in the translation unit that includes the header.
proc cInvokeRoute(cb, user, url: HostPtr; urlLen: int32;
                  body: HostPtr; bodyLen: int32;
                  session: HostPtr; sessionLen: int32;
                  outPtr, outLen: HostPtr): int32 {.
  importc: "aowl_invoke_route", nodecl.}
proc cFreeBuf(p: HostPtr) {.importc: "aowl_host_release", nodecl.}
proc cConnFinal(): int32 {.importc: "aowl_conn_final", nodecl.}

proc runRoute(route: Route; r: Request; into: var string): bool =
  ## The route is a copy taken under the registration lock, and nothing here
  ## holds that lock: this calls into a mod, a mod may register a route from a
  ## handler, and a walk that held the lock across the call would be waiting on
  ## itself.
  into = ""
  var url = r.url
  var body = r.body
  var session = r.session
  var outPtr: HostPtr = cast[HostPtr](0)
  var outLen = 0'i32
  let st = cInvokeRoute(route.cb, route.user,
                        cast[HostPtr](toCString(url)), int32(url.len),
                        cast[HostPtr](toCString(body)), int32(body.len),
                        cast[HostPtr](toCString(session)), int32(session.len),
                        cast[HostPtr](addr outPtr), cast[HostPtr](addr outLen))
  if outPtr != nil and outLen > 0'i32:
    # `readMem`, not `modhost.readBytes`: the latter goes through
    # `aowl_byte_at`, one call across a translation unit per byte, and a static
    # table is millions of them. Same bytes, one `copyMem`.
    into = readMem(cast[WirePtr](outPtr), outLen)
  if outPtr != nil:
    cFreeBuf(outPtr)
  result = st == StatusOk

# ------------------------------------------------------------ the warm cache
#
# The compressed-body cache above removes the *second* deflate of a table. It
# cannot remove the first, and the first is what the player waits for: MEASURED
# with `tools/loadpathbench.py` against the real emulator and the real 41 MB
# database, `/client/items` costs 1295 ms on its first request and 75 ms on its
# second, `/client/locations` 1323 ms then 5 ms. Every one of those first-hit
# milliseconds is on the client's login path, once, and the client is doing
# nothing else while it waits.
#
# So the static tables are built and deflated BEFORE the client asks, on the
# serve loop's tick thread -- one route per 50 ms tick, never on an accept
# worker -- and the request that eventually arrives is a `send` of bytes that
# already exist.
#
# **What makes this safe is not the URL list; it is the self-check.** A
# URL-keyed cache can go stale, which is exactly why `cachedDeflate` above is
# keyed on the response text instead. Two things bound it here:
#
#   1. Every candidate is produced TWICE, with two different inputs (no
#      session, and a real session id), and the two must be byte-identical.
#      A route whose answer depends on the caller, on the clock, or on a
#      random draw FAILS that and is never warmed -- it is logged as a refusal
#      and served live for the life of the process. This check can fail and
#      has a named falsifying input; see `warmVerify`.
#   2. Entries EXPIRE. After `gWarmTtlMs` (default 120 s -- the login burst is
#      over in ten) the whole cache is dropped and the server behaves exactly
#      as it did before this existed. Nothing that changes an answer later in
#      a session -- a settings knob, a mod rebuilding a table -- can be served
#      a stale body, because by then there is nothing warm left to serve.
#
# The list is deliberately short and deliberately hand-written: it is the
# static load-path tables and nothing else. Adding a route here is a claim that
# its answer is a pure function of the database, and the self-check is what
# audits the claim rather than trusting it.

const WarmRoutes = [
  "/client/items",
  "/client/globals",
  "/client/customization",
  "/client/account/customization",
  "/client/handbook/templates",
  "/client/settings",
  "/client/languages",
  "/client/locale/en",
  "/client/menu/locale/en",
  "/client/locations",
  "/client/seasonal-perks/list",
  "/client/ending/list",
  "/client/prestige/list",
  "/client/trading/api/traderSettings",
  "/client/achievement/list",
  "/client/hideout/areas",
  "/client/hideout/settings",
  "/client/hideout/qte/list",
  "/client/hideout/production/recipes",
  "/client/quest/chains",
  "/client/tape/list",
  "/client/subtitle-track/list",
  "/client/getMetricsConfig",
  "/client/libraries",
  "/client/repeatalbeQuests/activityPeriods",
  # NEGATIVE CONTROL, and it is here on purpose.
  #
  # `/client/quest/list` restates every quest's status from the caller's
  # profile, so its answer is NOT a pure function of the database and it must
  # never be warmed. It is in this list so that every boot exercises the
  # refusal path: if this route is ever silently accepted, the self-check has
  # stopped being able to say no, and §9b of CLAUDE.md is about exactly that.
  # The log line it produces is the readback -- one `warm REFUSED` per boot,
  # naming the two byte counts that differed.
  "/client/quest/list"
]

const WarmControl = "/client/quest/list"
  ## The one entry above that MUST be refused. See `warmStep`.

type
  WarmEntry = object
    url: string
    packed: seq[byte]
    packedLen: int
    bodyLen: int

var gWarm: seq[WarmEntry] = @[]
var gWarmOn = true            ## `--no-warm` turns it off
var gWarmTtlMs = 120_000'i64  ## `--warm-ttl SECONDS`
var gWarmNext = 0
var gWarmStarted = false
var gWarmBornMs = 0'i64
var gWarmExpired = false
var gWarmHits = 0
var gWarmRefused = 0
var gWarmSession = ""         ## the second input the self-check uses

# ------------------------------------------------- readiness and the warm gate
#
# STARTUP RACE, measured 2026-09-01. The client draws the native dialog
# `Unable to check the client version` and dies when its first request --
# `/client/game/version/validate` -- does not get an answer quickly enough.
# Two separate things could produce that, and both are removed here rather than
# made less likely:
#
# 1. THE LISTENER WAS NOT UP YET. `cNetServe` used to be called *after*
#    `loadAll`, so between the bind (`reservePort`, ~0.05 s) and the listen
#    nobody answered `connect` at all: MEASURED 4.656 s to `listening` on a boot
#    where `aowl.waypoints` built 8,556 patrol points, against 3.55 s the build
#    before. The listen now happens BEFORE the mods load, and a request that
#    arrives while they are still loading WAITS in `waitForMods` below instead
#    of meeting a route table that does not have its routes in it yet. A
#    request held for two seconds and then answered correctly is a slow boot; a
#    404, or a connection nothing accepts, is a fatal dialog.
#
# 2. THE WARM BUILD WAS RUNNING. Warm is one route per serve-loop tick and it
#    runs on the serve loop's OWN thread, never on an accept worker -- so it
#    does not block a request by occupying its thread, and any claim that it
#    does is refuted by `main`'s loop and `cNetServe(gPort, 16)`. What it DOES
#    do is put a 15 MB-body handler and an 859 ms deflate in flight against the
#    one process-wide `aowl_lock` that the compressed-body cache, the warm
#    table, the timer list and `modstore`'s profile I/O all share. Measured
#    window on the failing boot: warm ran 5.1 s -> 9.0 s and the dialog appeared
#    at ~8 s. So warm is now GATED: it does not begin until either the client's
#    own first handshake has been answered, or `WarmGateGraceMs` has passed with
#    no client at all. Nothing else about the warm cache changes.
#
# Both flags are only ever written false -> true, and a reader that sees a stale
# `false` waits, or defers one more tick -- the harmless direction in both.

const
  ModsReadyWaitMs = 30_000'i64
    ## How long a request that arrived before the mods finished loading waits
    ## for them. Longer than any mod load measured here (worst 4.6 s), and
    ## bounded so a wedged `on_load` produces a well-formed 503 rather than a
    ## connection that is never answered at all.
  ModsReadyPollMs = 5'i32
  WarmGateGraceMs = 20_000'i64
    ## With no client, warm still has to happen: `aowl test`, `soak`, `fuzzwire`
    ## and any headless run never send a handshake. After this long since the
    ## listener came up the gate opens on its own, and says so.
  HandshakeUrl = "/client/game/version/validate"
    ## The client's FIRST request, and the one whose failure draws the dialog.
    ## Named here rather than in `mods/tarkov` because what this file does with
    ## it -- open the warm gate -- is the pipeline's business, not the game's.

var gModsReady = false
  ## False from process start until `loadAll` has returned. Read by every accept
  ## worker, written once by the main thread.
var gModsReadyMs = 0'i64
var gHeldRequests = 0
  ## How many requests had to wait for the mods. Reported once, because a boot
  ## where this is 0 and a boot where it is 40 are the same boot from the
  ## outside and only one of them was a race.
var gWarmGateOpen = false
var gWarmGateReason = ""
var gServeStartMs = 0'i64
  ## `elapsedMs()` when the listener came up. 0 until then, which is what
  ## `warmStep`'s grace is measured from.

proc warmGateOpen(reason: string) =
  ## Idempotent, and it records WHY, because "warm started late" and "warm never
  ## started at all" are indistinguishable in a log that only carries what warm
  ## managed to do.
  ##
  ## Under `cLock` because the two callers are on different threads -- an accept
  ## worker on the handshake, the serve loop on the grace -- and the loser of
  ## that race must not also write the string the winner is writing.
  if gWarmGateOpen:
    return
  cLock()
  let first = not gWarmGateOpen
  if first:
    gWarmGateReason = reason
    gWarmGateOpen = true
  cUnlock()
  if first:
    modhost.info "warm gate open (" & reason & ")"

proc waitForMods(): bool =
  ## True if the mods are loaded and this request may proceed; false if it
  ## waited `ModsReadyWaitMs` and they still are not.
  ##
  ## This is the whole of the listen-before-mods fix on the serving side. The
  ## alternative -- dispatch anyway -- would 404 a route whose mod has not
  ## registered it yet, and the client's answer to a 404 on the handshake is the
  ## fatal dialog. The alternative *below* -- 503 immediately -- is the same
  ## thing with a nicer status line. So the request waits, and only a genuinely
  ## wedged load turns into the 503 the caller sees.
  if gModsReady:
    return true
  inc gHeldRequests
  let t0 = elapsedMs()
  while not gModsReady:
    if elapsedMs() - t0 >= ModsReadyWaitMs:
      return false
    cSysSleep(ModsReadyPollMs)
  modhost.info "held a request " & $(elapsedMs() - t0) &
               " ms while the mods finished loading"
  result = true

# ------------------------------------------------------- conditional GET
#
# MEASURED, from the BSG capture manifest (`mods/tarkov/data/capture/raid1/
# manifest.json`), which is what the REAL server did with the repeat requests
# this client makes:
#
#   seq 045  GET /client/items    200  1,036,593 B
#   seq 069  GET /client/items    304  0 B
#   seq 224  GET /client/items    304  0 B
#   seq 426  GET /client/items    304  0 B
#   seq 084  GET /client/globals  200  179,073 B
#   seq 229  GET /client/globals  304  0 B
#   seq 424  GET /client/globals  304  0 B
#
# So "unchanged" is not a thing that has to be invented: it is ordinary HTTP
# conditional GET, the client's own stack already accepted a 304 for these two
# routes from BSG, and it carried on and drew the items.
#
# What the capture does NOT contain is the REQUEST headers -- `reqlen` is 0 and
# no request head was recorded -- so which validator the client sends is
# **unknown**, and `nettrace.log` records request lines without headers, so it
# cannot answer it either. Guessing would be exactly the confidently wrong
# diagnostic the house rules forbid.
#
# Therefore this is implemented as real conditional GET and NOTHING ELSE: a
# warm 200 carries an `ETag`, and a 304 goes out only for a request that
# actually carries a matching `If-None-Match`. If the client sends no
# validator, the flag is inert and the body goes out in full -- it cannot
# withhold a body the client did not say it already had.
#
# Default OFF. It is also self-answering: with it on, the first request for
# each warm route logs whether it carried a validator, so ONE launch settles
# the question this capture could not.
var gEtagOn = false
var gEtagAsked: seq[string] = @[]

proc etagFor(bodyLen, packedLen: int): string =
  ## Weak-ish but sufficient: the answer is a pure function of the database,
  ## and an entry only exists while the warm cache holds it, so a tag can only
  ## be handed out for bytes this process still has.
  "\"aowl-" & $bodyLen & "-" & $packedLen & "\""

proc etagNote(url: string; sent: string) =
  ## Once per url. The readback that decides whether a 304 can ever fire on
  ## this client -- and it states the negative case as loudly as the positive
  ## one, because "no validator" is the answer that means this flag is inert.
  for u in gEtagAsked:
    if u == url:
      return
  gEtagAsked.add url
  if sent.len == 0:
    modhost.info "conditional: " & url & " carried NO If-None-Match -- the " &
      "304 path cannot fire for it on this client"
  else:
    modhost.info "conditional: " & url & " carried If-None-Match " & sent

proc warmSecondSession(): string =
  ## The self-check needs a session that is not the empty one, and a REAL id
  ## beats a made-up one: a handler that looks a profile up will take its
  ## found-a-profile branch, which is the branch a session-varying route
  ## varies in. `launcher-last-profile.txt` is what the launcher writes; when
  ## there is none, a syntactically valid id is used and the check is weaker,
  ## which is stated in the log rather than glossed over.
  if gWarmSession.len > 0:
    return gWarmSession
  var text = ""
  if readTextFile(joinPath(gRoot, "launcher-last-profile.txt"), text):
    var id = ""
    for ch in text:
      if (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or
         (ch >= 'A' and ch <= 'F'):
        id.add ch
      elif id.len > 0:
        break
    if id.len >= 8:
      gWarmSession = id
  if gWarmSession.len == 0:
    gWarmSession = "0123456789abcdef01234567"
  result = gWarmSession

proc warmFind(path {.byref.}: string; into: var int): bool =
  ## Caller holds the lock.
  result = false
  for i in 0 ..< gWarm.len:
    if gWarm[i].url == path:
      into = i
      return true

proc warmRun(url: string; session: string; into: var string): bool =
  ## One synthetic request, straight at the route table. No socket, no session
  ## lock: nothing else is running yet when this is used at warm time, and the
  ## verify pass is the only other caller.
  var route = Route(url: "", kind: RouteStatic, cb: cast[HostPtr](0),
                    user: cast[HostPtr](0), modIndex: -1)
  if not matchRoute(url, route):
    return false
  if not modhost.modEnter(route.modIndex):
    return false
  let r = Request(verb: "POST", url: url, session: session, body: "",
                  ok: true, keepAlive: false, identity: false)
  result = runRoute(route, r, into)
  modhost.modLeave(route.modIndex)

proc warmStep() =
  ## One route per call, from the serve loop's tick. Deliberately not a burst:
  ## the tick thread also drains timers and live mod control, and warming
  ## twenty tables back to back would hold it for a second and a half.
  if not gWarmOn or gWarmExpired or gWarmNext >= WarmRoutes.len:
    return
  if not gModsReady:
    # The listener is up before the mods are (see `waitForMods`), so this loop
    # now runs during the load. Warming a half-registered route table would
    # measure whichever mods happened to be in already.
    return
  if not gWarmGateOpen:
    # THE GATE. See `warmGateOpen`. The client's handshake opens it; with no
    # client, the grace does.
    if gServeStartMs > 0'i64 and elapsedMs() - gServeStartMs >= WarmGateGraceMs:
      warmGateOpen("no client after " & $(WarmGateGraceMs div 1000) & " s")
    else:
      return
  if not gWarmStarted:
    gWarmStarted = true
    gWarmBornMs = elapsedMs()
  let url = WarmRoutes[gWarmNext]
  inc gWarmNext

  let t0 = elapsedMs()
  var a = ""
  if not warmRun(url, "", a):
    # Not registered by any loaded mod, or it refused. Neither is an error:
    # the list spans routes several different emulators may or may not serve.
    modhost.debug "warm: " & url & " is not served here"
    return
  if a.len < ZCacheMinBody:
    # Below the compressed-body cache's own floor there is nothing to win: the
    # deflate is microseconds. Warming it would only add a URL-keyed entry --
    # i.e. all of the staleness risk and none of the benefit.
    modhost.debug "warm: " & url & " is " & $a.len & " B, below the floor"
    return

  # The self-check. Two different inputs, one required answer.
  var b = ""
  let sess = warmSecondSession()
  if not warmRun(url, sess, b) or b != a:
    inc gWarmRefused
    modhost.warn "warm REFUSED " & url &
      " -- its answer is not a pure function of the database (" & $a.len &
      " B with no session, " & $b.len & " B with session " & sess &
      "). It will be served live."
    return

  if url == WarmControl:
    # It passed. That is not good news: this route restates every quest's
    # status from the caller's profile, so two different sessions cannot
    # legitimately produce the same bytes. The realistic cause is that the
    # second input was not a real session -- no `launcher-last-profile.txt`,
    # or a store with no profile in it -- in which case the check ran with two
    # inputs that were effectively the same one, and its verdict on every
    # OTHER route this boot is worth less than it looks.
    #
    # Refused anyway, and said at error level, because a self-check reporting
    # a pass it cannot have earned is the failure mode this control exists to
    # make visible.
    inc gWarmRefused
    modhost.fail "warm SELF-CHECK IS WEAK this boot: the control route " &
      url & " produced identical bytes for session '' and session " & sess &
      " (" & $a.len & " B). That means the second input is not a real " &
      "profile, so every other warm verdict this boot was taken with one " &
      "input, not two. Nothing was warmed from it."
    return

  var packed: seq[byte] = @[]
  var packedLen = 0
  if not deflateBody(a, packed, packedLen):
    inc gWarmRefused
    modhost.warn "warm REFUSED " & url & " -- it would not deflate"
    return

  cLock()
  var at = 0
  if not warmFind(url, at):
    gWarm.add WarmEntry(url: url, packed: packed, packedLen: packedLen,
                        bodyLen: a.len)
  cUnlock()
  # One line per warmed route, with the two byte counts and the wall time, so
  # the readback is in the log rather than in somebody's memory of a run.
  modhost.info "warm " & url & " " & $a.len & " B -> " & $packedLen &
               " B in " & $(elapsedMs() - t0) & " ms"

proc warmSweep() =
  ## Drop the whole cache once it is older than the TTL. This is the second
  ## half of what makes a URL-keyed cache defensible: it is not a cache with a
  ## clever invalidation rule, it is a cache that stops existing.
  if gWarmExpired or not gWarmStarted or gWarm.len == 0:
    return
  if elapsedMs() - gWarmBornMs < gWarmTtlMs:
    return
  cLock()
  let n = gWarm.len
  gWarm = @[]
  gWarmExpired = true
  cUnlock()
  modhost.info "warm cache expired after " & $(gWarmTtlMs div 1000) &
               " s: " & $n & " entr(ies) dropped, " & $gWarmHits &
               " request(s) had been served from it"

# --------------------------------------------------------------- serving

proc sendTimeout(sock: uint64; phase: int32; have: int32;
                 declared: int32) {.exportc: "aowlspt_nim_timeout", cdecl.} =
  ## The `408` for a request that began and stopped.
  ##
  ## The poller decides *that* a request has stopped arriving -- it is the one
  ## holding the clock -- but it does not write the answer. Every byte this
  ## server puts on a socket is still composed here, which is what keeps
  ## `aowlspt_net.h` a file about sockets rather than a second, quieter HTTP
  ## implementation. The two bodies are the ones the receive loop used to send,
  ## unchanged.
  if phase == 0'i32:
    sendResponse(sock, "408 Request Timeout",
                 "{\"err\":\"the request headers stopped arriving\"," &
                 "\"after\":" & $int(have) & "}", false)
  else:
    sendResponse(sock, "408 Request Timeout",
                 "{\"err\":\"the request body stopped arriving\"," &
                 "\"had\":" & $int(have) & ",\"declared\":" &
                 $int(declared) & "}", false)

# --------------------------------------------------------------- websocket
#
# The four calls the poller makes and the one the ABI makes. All of them are
# three lines: the work is in `backend/websocket.nim`, and what is here is the
# `exportc` boundary, kept in this file because every other one is.

proc wsRawSend(sock: uint64; data: string): bool =
  discard cNetSend(sock, cast[HostPtr](readRawData(data)), int32(data.len))
  result = true

proc wsFrameSend(ticket: int64; data: string): bool =
  result = cWsSend(ticket, cast[HostPtr](readRawData(data)),
                   int32(data.len)) >= 0'i32

proc wsAdopt(sock: uint64): int64 = cWsAdopt(sock)

proc wsMessageIn(ticket: int64; opcode: int32; p: HostPtr;
                 len: int32): int32 {.
    exportc: "aowlspt_nim_ws_message", cdecl.} =
  let keep = websocket.wsOnMessage(ticket, int(opcode),
                                   readMem(cast[WirePtr](p), len))
  result = (if keep: 1'i32 else: 0'i32)

proc wsControlIn(ticket: int64; kind: int32; code: int32; p: HostPtr;
                 len: int32) {.
    exportc: "aowlspt_nim_ws_control", cdecl.} =
  websocket.wsOnControl(ticket, int(kind), int(code),
                        readMem(cast[WirePtr](p), len))

proc wsIdleIn(ticket: int64; pinged: int32): int32 {.
    exportc: "aowlspt_nim_ws_idle", cdecl.} =
  result = (if websocket.wsOnIdle(ticket, pinged != 0'i32): 1'i32 else: 0'i32)

proc wsGoneIn(ticket: int64) {.exportc: "aowlspt_nim_ws_gone", cdecl.} =
  websocket.wsOnGone(ticket)

proc hostNotifyPush(session: HostPtr; sessionLen: int32;
                    payload: HostPtr; payloadLen: int32): int32 {.
    exportc: "aowlspt_nim_notify_push", cdecl.} =
  ## `notify_push`, revision 5. `ErrNotFound` means there is no websocket for
  ## that session, which is an ordinary answer the mod falls back from -- and
  ## it must not be `Ok`, because `Ok` would tell the mod the player has been
  ## told.
  let s = readMem(cast[WirePtr](session), sessionLen)
  let p = readMem(cast[WirePtr](payload), payloadLen)
  if s.len == 0 or p.len == 0:
    return ErrBadArg
  result = (if websocket.wsPush(s, p): StatusOk else: ErrNotFound)

proc handleRequest(sock: uint64; buf: HostPtr; len: int32;
                   headEnd: int32; sep: int32): int32 {.
    exportc: "aowlspt_nim_handle", cdecl.} =
  ## Answers exactly one request, out of a buffer the poller has already
  ## filled. Returns 1 if the connection may be kept alive, 0 if it must close,
  ## and **2 if the request was a websocket handshake this answered `101`** --
  ## in which case the connection is no longer a request stream at all and the
  ## poller takes it out of the state machine that reads it as one.
  ##
  ## This used to be `serveConnection`, and it used to own the socket: it
  ## looped on `recv` until the client let go, which meant a worker thread was
  ## occupied for the life of a connection and the pool size was the connection
  ## limit. Three receive deadlines bounded the damage a stalled connection did
  ## and could not remove it, because the shape was the problem -- see the head
  ## of `aowlspt_net.h` for the shape that replaced it.
  ##
  ## What that leaves here is the part that was always the interesting part:
  ## one request's bytes in, one response's bytes out. There is no loop, no
  ## clock and no socket read. The framing -- where this request ends and the
  ## next begins -- is decided by the poller and re-checked below, and every
  ## way the two could disagree is answered and closed on, so a disagreement
  ## cannot desynchronise a kept-alive stream.
  if headEnd < 0'i32:
    # The poller gave up looking for a header terminator.
    sendResponse(sock, "431 Request Header Fields Too Large",
                 "{\"err\":\"the request headers do not fit in " &
                 $HeadCapBytes & " bytes\"}", false)
    return 0'i32

  let head = readMem(cast[WirePtr](buf), headEnd)

  var req = Request(verb: "", url: "", session: "", body: "", ok: false,
                    keepAlive: false)
  var contentLength = 0
  if not parseHead(head, req, contentLength):
    # Every refusal here says which one it is. A 400 with an empty body is
    # indistinguishable from a server that fell over, which is exactly the
    # question anyone reading it is trying to answer.
    sendResponse(sock, "400 Bad Request",
                 "{\"err\":\"the request line or its Content-Length is " &
                 "malformed\"}", false)
    return 0'i32

  # The connection's last allowed request answers `Connection: close`.
  #
  # `AOWL_KEEPALIVE_MAX` is applied by the poller after the answer has gone
  # out, so this request's response used to promise a connection that was
  # already going to be closed under it. Every `return` below turns
  # `req.keepAlive` into the poller's keep/close answer as well, so clearing it
  # here makes the header and the socket agree instead of contradicting each
  # other -- and the poller closes on either.
  if cConnFinal() != 0'i32:
    req.keepAlive = false

  # Every phase this thread accounts for from here on belongs to this URL.
  # Before the body work rather than after it, so `inflate` lands in the right
  # row; after `parseHead`, because there is no URL to name until it has run.
  perfBegin(req.url)

  # THE READINESS GATE. The listener is up before the mods are loaded, so a
  # request can genuinely arrive at an empty route table -- and this is the only
  # place that difference is visible. See `waitForMods` for why it waits rather
  # than answering at once.
  if not gModsReady:
    if not waitForMods():
      # Well-formed, JSON, and it names the state rather than the symptom: a
      # reset or a 404 here is what the client turns into `Unable to check the
      # client version`, and neither of those says which of the twenty possible
      # causes it was.
      sendResponse(sock, "503 Service Unavailable",
                   "{\"err\":\"the server is still loading its mods\"," &
                   "\"retryAfterMs\":500,\"url\":" & jsonQuoted(req.url) &
                   "}", false, false)
      modhost.warn "still loading mods after " & $(ModsReadyWaitMs div 1000) &
                   " s; answered 503 for " & req.url
      return 0'i32

  # Refused rather than served, and the poller never waited for the body: the
  # allocation *is* the attack. See `MaxBodyBytes`.
  if contentLength > MaxBodyBytes:
    sendResponse(sock, "413 Payload Too Large",
                 "{\"err\":\"the body is larger than this server accepts\"," &
                 "\"limit\":" & $MaxBodyBytes & "}", false)
    return 0'i32

  let bodyStart = int(headEnd) + int(sep)
  var bodyHave = int(len) - bodyStart
  if bodyHave < 0: bodyHave = 0
  if bodyHave > contentLength: bodyHave = contentLength
  if bodyHave < contentLength:
    # The poller only hands over complete requests, so this is unreachable
    # unless its framing and `parseHead` read the same headers differently --
    # a second, disagreeing `Content-Length` is the way to arrange that. It is
    # refused and the connection closed, which is what makes the disagreement
    # harmless: there is no next request on this socket to get wrong.
    sendResponse(sock, "400 Bad Request",
                 "{\"err\":\"the request line or its Content-Length is " &
                 "malformed\"}", false)
    return 0'i32

  var bodyBytes = newSeq[byte](if bodyHave > 0: bodyHave else: 1)
  if bodyHave > 0:
    copyMem(addr bodyBytes[0],
            cast[pointer](cast[uint](buf) + uint(bodyStart)), bodyHave)

  let tInflate = perfNow()
  let inflated = inflateBody(bodyBytes, bodyHave, req.body)
  perfAdd(PhaseInflate, tInflate)
  if not inflated:
    modhost.warn "could not inflate a " & $bodyHave & "-byte body for " &
                 req.url
    sendResponse(sock, "400 Bad Request",
                 "{\"err\":\"the request body is not a zlib stream this " &
                 "server can inflate\",\"bytes\":" & $bodyHave & "}", false)
    return 0'i32

  discard cReqBump()

  if req.session.len == 0 and websocket.isUpgrade(head):
    # The client puts the session in the path of the notifier URL --
    # `/client/notifier/getwebsocket/<id>` -- and does not always send the
    # cookie with it. Taken from the last path segment only when there is no
    # cookie, and only for an upgrade, so no ordinary route can have a session
    # invented for it out of its own URL; and it goes through `isHexId` below
    # like every other session, so the path is not a way around that check.
    var tail = req.url
    let q = find(tail, "?")
    if q >= 0: tail = tail.substr(0, q - 1)
    var slash = -1
    var k = tail.len - 1
    while k >= 0:
      if tail[k] == '/':
        slash = k
        break
      dec k
    if slash >= 0: tail = tail.substr(slash + 1)
    if isHexId(tail): req.session = tail

  if req.session.len > 0 and not isHexId(req.session):
    # Rejected before any route sees it: a malformed id reaching a mod would
    # be reported as that mod's bug.
    modhost.warn "rejecting a malformed session id on " & req.url
    sendResponse(sock, "400 Bad Request", "{\"err\":\"bad session id\"}",
                 true, req.keepAlive)
    return (if req.keepAlive: 1'i32 else: 0'i32)

  if websocket.isUpgrade(head):
    modhost.info("WS UPGRADE " & req.url & " session=" & req.session)
    # A websocket, and this is the fork in the whole request path.
    #
    # It is answered here rather than by a route on purpose: which URL carries
    # the notifier is the game's business and lives in `mods/tarkov`, but
    # *holding a connection* is the pipeline's, and a mod cannot be handed a
    # socket without handing it the poller's invariants with it. So the backend
    # upgrades any request that asks, keyed on the session it carries, and the
    # mod pushes by session and never learns there is a socket.
    #
    # Returning 2 is what takes this connection out of the request state
    # machine for good -- see the head of `aowlspt_net.h`, where getting that
    # wrong is the stalled-connection starvation the poller exists to remove,
    # rebuilt one socket at a time.
    var ticket = 0'i64
    if websocket.handshake(sock, head, req.session, ticket):
      return 2'i32
    return 0'i32

  # The client's first request has reached a route. Everything expensive the
  # server does to itself is allowed to begin AFTER this, not during it.
  # `startsWith`, not `==`: the client appends query strings, and a gate that
  # only ever matched the bare path would have stayed shut for the whole run
  # with nothing saying so.
  if not gWarmGateOpen and startsWith(req.url, HandshakeUrl):
    warmGateOpen("the client handshaked")

  let tMatch = perfNow()
  var route = Route(url: "", kind: RouteStatic, cb: cast[HostPtr](0),
                    user: cast[HostPtr](0), modIndex: -1)
  let matched = matchRoute(req.url, route)
  perfAdd(PhaseMatch, tMatch)
  if not matched:
    # Said out loud, because the only other party who learns about it is the
    # client -- and the client's answer to a 404 is to carry on, retry, or draw
    # an empty screen. A route the game asks for and this server does not have
    # was therefore invisible from here: `docs/EMULATOR-COVERAGE.md` can say
    # which *SPT* operations are unserved, and it cannot say which URLs a real
    # build actually calls, because the reference dump carries no URLs at all.
    # One warn per unmatched url turns a playtest into that list.
    modhost.warn "no route for " & req.verb & " " & req.url
    sendResponse(sock, "404 Not Found",
                 "{\"err\":\"no route\",\"url\":" &
                 jsonQuoted(req.url) & "}", not req.identity, req.keepAlive)
    return (if req.keepAlive: 1'i32 else: 0'i32)

  # Warm? Then this request is a `send` and nothing else -- no handler, no
  # database read, no deflate.
  #
  # After `matchRoute` on purpose: a warm hit for a url no mod serves would be
  # a 200 for a route that does not exist. Before the session lock, because
  # nothing here touches a profile. `identity` requests fall through to the
  # live handler: they want the body uncompressed and the warm entry only
  # holds it deflated, and they are the overlay and the browser, never the
  # game.
  if gWarmOn and not req.identity and gWarm.len > 0:
    var wpath = req.url
    let wq = find(wpath, "?")
    if wq >= 0: wpath = wpath.substr(0, wq - 1)
    cLock()
    var wat = 0
    let whit = warmFind(wpath, wat)
    var wpacked: seq[byte] = @[]
    var wlen = 0
    var wbody = 0
    if whit:
      wlen = gWarm[wat].packedLen
      wbody = gWarm[wat].bodyLen
      wpacked = gWarm[wat].packed
      inc gWarmHits
    cUnlock()
    if whit:
      modhost.debug("REQ " & req.verb & " " & req.url & " (warm)")
      var tag = ""
      if gEtagOn:
        tag = etagFor(wbody, wlen)
        etagNote(wpath, req.ifNoneMatch)
        if req.ifNoneMatch == tag:
          sendNotModified(sock, tag, req.keepAlive)
          return (if req.keepAlive: 1'i32 else: 0'i32)
      sendPacked(sock, wpacked, wlen, req.keepAlive, tag)
      return (if req.keepAlive: 1'i32 else: 0'i32)

  # One session at a time through a route handler.
  #
  # A handler for this client is a read-modify-write of a whole profile
  # document: it loads the profile, changes it, and saves it back. Two requests
  # carrying the same session id used to run that concurrently and one of them
  # lost -- six concurrent purchases were each answered `err:0` and three
  # rifles arrived, with the arithmetic self-consistent and three payments
  # silently discarded. The emulator narrowed the window from its side and said
  # so in `mods/tarkov/emu/profile.nim`; narrowing is not closing, and the
  # close belongs here, because this is the only place that knows a request is
  # about to begin and has somewhere to put a lock.
  #
  # It wraps the whole callback rather than the store call, because the read
  # and the write are at either end of the handler and anything narrower leaves
  # the same race in a smaller window. It is keyed on the session, so two
  # profiles do not wait on each other and a route with no session -- the
  # status routes, the mod manager -- takes no lock at all. And it is released
  # before the answer goes out and long before the connection waits for its
  # next request, so keep-alive holds nothing: the lock is per session, not per
  # connection.
  #
  # `aowl_session_lock` is where the rest of it is written down, including what
  # happens to a handler that never returns.
  var slot = -1'i32
  if req.session.len > 0:
    slot = cSessionLock(cast[HostPtr](toCString(req.session)),
                        int32(req.session.len))
  if slot == -2'i32:
    # Ten seconds waiting for another request on the same profile to finish.
    # That is a wedged handler, not contention, and saying so beats holding a
    # worker until the process ends.
    modhost.warn "gave up waiting for the session lock on " & req.url
    sendResponse(sock, "503 Service Unavailable",
                 "{\"err\":\"another request on this profile has not " &
                 "finished\"}", not req.identity, req.keepAlive)
    return (if req.keepAlive: 1'i32 else: 0'i32)

  # A reference on the mod, held across the call and given back after it.
  #
  # `matchRoute` copied this route out under the registration lock and let go,
  # which is what keeps a handler that registers a route from waiting on the
  # walk that dispatched to it -- and it is also what leaves this thread
  # carrying a function pointer into a library the control thread is allowed to
  # free. Everything the *host* holds is dropped by the teardown; this pointer
  # is not held by the host, it is held by this stack, and the only thing that
  # can protect it is a count the unload can see. `modhost.modEnter` takes it
  # and `modhost.modLeave` gives it back; the ordering that makes the pair
  # correct is written down where they are.
  #
  # 7.3 ns for the pair against a handler that costs about 423 us. It is under
  # the session lock rather than over it on purpose: taken first, a request
  # waiting ten seconds for another request on the same profile would hold a
  # mod open for those ten seconds and turn a live unload into a timeout.
  if not modhost.modEnter(route.modIndex):
    # The mod is draining. Not a 404: the route is still registered and will be
    # gone in a moment, and the honest answer to "ask again" is 503 rather than
    # "there was never anything here".
    if slot >= 0'i32:
      cSessionUnlock(slot)
    sendResponse(sock, "503 Service Unavailable",
                 "{\"err\":\"that mod is being unloaded\",\"url\":" &
                 jsonQuoted(req.url) & "}", not req.identity, req.keepAlive)
    return (if req.keepAlive: 1'i32 else: 0'i32)

  var body = ""
  let tRoute = perfNow()
  # DIAGNOSTIC: every dispatched request, so a menu that stalls names what it
  # was last waiting on.
  #
  # This was `info`, i.e. unconditional, and it is the single largest source of
  # noise in this log: MEASURED on a 182 s session, 890 of 1577 lines (56.4%,
  # 4.9 lines/s) were this one statement, and 253 of those were the settings UI
  # polling `/settings/client/sync` -- six times in one second. A polling UI
  # logging every poll drowns everything that is not a poll.
  #
  # It is now `debug`: present in full when `--verbose` is passed, absent
  # otherwise. Nothing else moved to debug. A route that FAILS still logs at
  # its own level, so a quiet run still names a broken request -- what is gone
  # is the record of the ones that worked.
  modhost.debug("REQ " & req.verb & " " & req.url)
  let served1 = runRoute(route, req, body)
  perfAdd(PhaseRoute, tRoute)
  modhost.modLeave(route.modIndex)
  if slot >= 0'i32:
    cSessionUnlock(slot)

  if served1:
    # `/client/metadata` must go out uncompressed, whatever the request asked
    # for. It is read during `il2cpp_init` by a regex that scans the raw bytes
    # for `"value":"..."` -- it does not inflate, and the real BSG server sends
    # this one endpoint un-gzipped too (the captured response is 414 bytes of
    # plain shuffled JSON, and the client's request carries no Accept-Encoding).
    # Deflate it and the client cannot find the value, and `il2cpp_init` fails
    # at ~100 ms exactly as if there were no server at all. Every other route
    # keeps the default (deflate unless the caller sent `identity`).
    # A `/files/*` request is a binary asset (a trader avatar, a handbook or
    # quest icon, a document image). The client fetches these with an ordinary
    # image request and decodes the raw bytes -- it does NOT inflate them the way
    # it inflates a `/client/*` body, and it reads the picture from the bytes
    # themselves, not from a header. So this path must go out uncompressed and
    # with an image Content-Type; deflate it or label it `application/json` and
    # the texture never decodes. The post-1.0 client resolves these against its
    # asset-CDN base, whose url carries a `/regular` path prefix, so the request
    # arrives as `/regular/files/...`; both spellings are the same asset.
    var fpath = req.url
    let q = find(fpath, "?")
    if q >= 0: fpath = fpath.substr(0, q - 1)
    if (fpath.len >= 7 and fpath.substr(0, 6) == "/files/") or
       (fpath.len >= 15 and fpath.substr(0, 14) == "/regular/files/"):
      # The bytes the handler returns are a PNG whatever extension the url
      # carried (the client sniffs the format from the magic bytes, not the
      # header or the path), so the honest Content-Type is `image/png`.
      sendResponse(sock, "200 OK", body, false, req.keepAlive, "image/png")
    # `substr(a, b)` is INCLUSIVE of b, so a 17-character prefix is
    # `substr(0, 16)`, not `substr(0, 17)`. Getting this wrong makes the branch
    # unreachable and the page goes out as `application/json`, which a browser
    # offers as a download instead of rendering. The two branches above are the
    # correct pattern: "/files/" is 7 chars and uses substr(0, 6).
    elif fpath.len >= 17 and fpath.substr(0, 16) == "/aowlspt/ui/page/":
      # The fallback settings UI (docs/UI-API.md) is a page a human opens
      # directly in an ordinary browser -- not the overlay's worker thread,
      # which sets its own headers and can ask for `identity` -- so it cannot
      # rely on a client that knows to request uncompressed and inflate
      # nothing else does. Same reasoning as `/client/metadata` below: send it
      # uncompressed, and with a real `text/html` Content-Type so the browser
      # renders it instead of offering it as a JSON download.
      sendResponse(sock, "200 OK", body, false, req.keepAlive, "text/html; charset=utf-8")
    elif fpath.len >= 20 and fpath.substr(0, 19) == "/aowlspt/maps/asset/":
      # Map terrain art (mods/maps). Fetched by an ordinary browser, which can
      # neither ask for `identity` nor inflate, so it goes out uncompressed for
      # the same reason as the two branches below. The MIME type has to be
      # `image/svg+xml` specifically: a browser asked to render SVG labelled
      # `application/json` offers it as a download, and one labelled `text/xml`
      # will not render inside an <img>. This page inlines the markup through
      # DOMParser, which is stricter still.
      #
      # Count check, because the two branches below record getting this wrong:
      # `substr(a, b)` is INCLUSIVE of b, so the 20-character prefix
      # "/aowlspt/maps/asset/" is `substr(0, 19)`.
      sendResponse(sock, "200 OK", body, false, req.keepAlive,
                   "image/svg+xml; charset=utf-8")
    elif fpath.len >= 16 and fpath.substr(0, 15) == "/aowlspt/ui/lib/":
      # The settings UI client library (docs/UI-API.md). Same reasoning as the
      # page above -- a browser fetches it with a plain `<script src>` and can
      # neither ask for `identity` nor inflate -- plus the MIME type has to be
      # a script type: a browser will refuse to execute a `<script src>` served
      # as `application/json`. Serving the library over HTTP rather than
      # inlining it in the page is what lets a THIRD-PARTY page reuse the exact
      # same settings client the shipped page runs, instead of reimplementing
      # it and drifting.
      sendResponse(sock, "200 OK", body, false, req.keepAlive,
                   "text/javascript; charset=utf-8")
    else:
      # `/client/metadata` must go out uncompressed, whatever the request asked
      # for. It is read during `il2cpp_init` by a regex that scans the raw bytes
      # for `"value":"..."` -- it does not inflate, and the real BSG server sends
      # this one endpoint un-gzipped too. Every other route keeps the default
      # (deflate unless the caller sent `identity`).
      let raw = req.url == "/client/metadata" or req.url == "/client/libraries"
      sendResponse(sock, "200 OK", body,
                   (not raw) and (not req.identity), req.keepAlive)
  else:
    sendResponse(sock, "500 Internal Server Error",
                 "{\"err\":\"the route handler failed\"}",
                 not req.identity, req.keepAlive)
  result = (if req.keepAlive: 1'i32 else: 0'i32)

# --------------------------------------------------------------- host api

var gLastError {.threadvar.}: string
  ## The last error, **per thread**, which is both the fix for a race and the
  ## only reading of "last" that means anything here.
  ##
  ## It was one global string that every one of the sixteen workers assigned to.
  ## Assigning a string frees the buffer that was in it, so two workers failing
  ## a lookup at the same moment is a double free; and `aowlspt_nim_last_error`
  ## hands a mod a pointer into that buffer, which another worker is free to
  ## release while the mod is reading it. `db_get` on a path that is not there
  ## sets it, and a mod probing for an optional table does that on purpose --
  ## so this was not an exotic path.
  ##
  ## Per thread is also what the caller already assumed. A mod calls
  ## `lastError()` after a call that just failed, on the thread that made it;
  ## the answer it wanted was never "the last error anywhere in the server",
  ## and one global could hand it another request's failure with no way to tell.

proc hostLog(ctx: HostPtr; level: int32; msg: HostPtr; len: int32) {.
    exportc: "aowlspt_nim_log", cdecl.} =
  let text = readBytes(msg, len)
  let tLog = perfNow()
  # Every level is distinct. Folding trace and debug into info left a mod with
  # no way to say something quietly, so mods that wanted quiet diagnostics
  # simply did not emit them.
  case level
  of 0'i32: modhost.logLine("trace", text)
  of 1'i32: modhost.logLine("debug", text)
  of 3'i32: modhost.okLog text
  of 4'i32: modhost.warn text
  of 5'i32: modhost.fail text
  else: modhost.info text
  perfAdd(PhaseLog, tLog)

proc hostLastError(ctx: HostPtr; outPtr, outLen: HostPtr) {.
    exportc: "aowlspt_nim_last_error", cdecl.} =
  if gLastError.len == 0:
    discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
    return
  discard cOutCopy(outPtr, outLen, cast[HostPtr](toCString(gLastError)),
                   int32(gLastError.len))

# One config document per mod, held for a moment rather than re-read per key.
#
# `modhost.configRead` opens `config.json`, reads it, and runs `jsonFault` over
# the whole document -- every time a mod asks for ONE setting. That is correct
# and it is the only sane contract, but the emulator's generators read settings
# in unconditional blocks: `botGearConfig` + `modRarityConfig` are ~700 reads
# per bot batch and `lootConfig` is several hundred per raid. Against
# `mods/tarkov/config.json`, which is 41 KB, that is 700 file opens and 700
# whole-document validations on the loading screen.
#
# MEASURED with `tools/loadpathbench.py` and the mod's own log: the emulator
# prints `bot/generate request:` as the first statement inside `generate()`,
# and 469 ms elapsed between the backend dispatching the request and that line
# -- with `refreshBotGear()` the only thing in between.
#
# The cache is per mod index, and it is held for `ConfigCacheMs`. It is NOT a
# permanent memo: the settings page writes `config.json` and the whole point of
# reading it per batch is that an edit takes effect without a restart. A write
# through this process drops it immediately (`hostConfigSet` below); the TTL is
# what covers a write from outside this process, and half a second of it.
const ConfigCacheMs = 500'i64
const ConfigCacheMods = 64

type
  ConfigCacheEntry = object
    text: string
    status: int32
    err: string
    stampMs: int64
    live: bool
    ## The RESOLVED values, not just the document.
    ##
    ## Caching the document alone took a bot batch from 469 ms of setup to
    ## 170 ms and no further, because each of the ~700 reads still copied the
    ## 41 KB document out of the cache and then scanned it for one key. The
    ## keys are the same 700 every batch and the document has not changed, so
    ## the answer has not either. Parallel seqs rather than a table: nothing
    ## else in this file uses `std/tables`, the set is bounded by the mod's own
    ## schema, and a linear scan of a few hundred short strings is nothing
    ## against the scan it replaces.
    keys: seq[string]
    vals: seq[string]
    stats: seq[int32]

var gConfigCache: array[ConfigCacheMods, ConfigCacheEntry]

proc configDrop*(idx: int) =
  ## Invalidate one mod's cached document. Called from the write path.
  if idx < 0 or idx >= ConfigCacheMods:
    return
  cLock()
  gConfigCache[idx].live = false
  cUnlock()

proc configReadCached(idx: int; text: var string; err: var string): int32 =
  if idx < 0 or idx >= ConfigCacheMods:
    return configRead(idx, text, err)
  let now = elapsedMs()
  cLock()
  if gConfigCache[idx].live and now - gConfigCache[idx].stampMs < ConfigCacheMs:
    text = gConfigCache[idx].text
    err = gConfigCache[idx].err
    let st = gConfigCache[idx].status
    cUnlock()
    return st
  cUnlock()
  let st = configRead(idx, text, err)
  cLock()
  gConfigCache[idx] = ConfigCacheEntry(text: text, status: st, err: err,
                                       stampMs: now, live: true,
                                       keys: @[], vals: @[], stats: @[])
  cUnlock()
  result = st

proc configValueCached(idx: int; key: string; into: var string;
                       hit: var bool): int32 =
  ## One resolved key out of the live document cache, or `hit = false` when
  ## this key has not been looked up since the document was read.
  ##
  ## Only ever consulted while the entry it belongs to is live, so it cannot
  ## outlive the document it was resolved from -- the memo is a field OF the
  ## entry and is thrown away with it, by `configDrop` and by the TTL alike.
  hit = false
  result = ErrNotFound
  if idx < 0 or idx >= ConfigCacheMods or key.len == 0:
    return
  cLock()
  if gConfigCache[idx].live:
    for i in 0 ..< gConfigCache[idx].keys.len:
      if gConfigCache[idx].keys[i] == key:
        into = gConfigCache[idx].vals[i]
        result = gConfigCache[idx].stats[i]
        hit = true
        break
  cUnlock()

proc configValueRemember(idx: int; key, value: string; st: int32) =
  if idx < 0 or idx >= ConfigCacheMods or key.len == 0:
    return
  cLock()
  if gConfigCache[idx].live:
    var seen = false
    for i in 0 ..< gConfigCache[idx].keys.len:
      if gConfigCache[idx].keys[i] == key:
        seen = true
        break
    if not seen:
      gConfigCache[idx].keys.add key
      gConfigCache[idx].vals.add value
      gConfigCache[idx].stats.add st
  cUnlock()

proc hostConfigGet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                   outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_config_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let k = readBytes(key, keyLen)
  let idx = int(cast[uint](ctx))
  # `modhost.configRead` rather than a read and a lookup here, because this is
  # one of the three copies of this that disagreed. It answers the two failures
  # apart -- `ErrNotFound` for no file, `ErrConfigParse` for a file that is not
  # readable JSON -- and puts the file and the fault in `err`, where this used
  # to answer "no such key" for a document no key could ever come out of. A mod
  # that falls back to its defaults on any failure, which is most of them, then
  # ran a whole session on defaults with nothing anywhere saying so.
  # The resolved-value memo, checked before the document is even copied out of
  # the cache. This is the whole win for the generators: `botGearConfig` +
  # `modRarityConfig` are ~700 reads of the same ~700 keys per bot batch.
  if k.len > 0:
    var memo = ""
    var memoHit = false
    let memoSt = configValueCached(idx, k, memo, memoHit)
    if memoHit:
      if memoSt != StatusOk:
        gLastError = "no such key: " & k
        return memoSt
      return cOutCopy(outPtr, outLen, cast[HostPtr](toCString(memo)),
                      int32(memo.len))

  var text = ""
  var err = ""
  let st = configReadCached(idx, text, err)
  if st != StatusOk:
    gLastError = err
    # A whole-document read gets the bytes even when they do not parse. It
    # asked for the file, the file is there, and a mod that reads its config in
    # one round trip and parses it itself -- which is the robust pattern, and
    # the one the mod manager uses -- would otherwise be told "no config" for a
    # config that exists and is broken. The status still says which it is.
    if st == ErrConfigParse and k.len == 0 and text.len > 0:
      var raw = text
      discard cOutCopy(outPtr, outLen, cast[HostPtr](toCString(raw)),
                       int32(raw.len))
    return st
  var value = ""
  if k.len == 0:
    value = text
  elif not pathGet(text, k, value):
    # Remembered as ABSENT, not just skipped. A key the file does not hold is
    # the common case for a generator knob -- the settings page writes a key
    # only when somebody edits it -- so caching only the hits would leave the
    # majority of the 700 reads scanning the document every time.
    configValueRemember(idx, k, "", ErrNotFound)
    gLastError = "no such key: " & k
    return ErrNotFound
  if k.len > 0:
    configValueRemember(idx, k, value, StatusOk)
  # `value` is handed to `cOutCopy` directly. It used to be copied into a local
  # `v` first, which on `templates.items` is a 4.25 MB allocation and copy that
  # nothing reads: `cOutCopy` takes a pointer and a length and does its own
  # copy into the host buffer.
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(value)),
                    int32(value.len))

proc jsonEscapeKey(s: string): string =
  result = ""
  for c in s:
    case c
    of '"':  result.add "\\\""
    of '\\': result.add "\\\\"
    else:    result.add c

proc mergeConfigKey(text, key, valueJson: string): string =
  ## `text` with `key` set to `valueJson` (a JSON literal, verbatim). Replaces
  ## an existing top-level member's span in place; a key `config.json` has
  ## never held (a declared setting with no on-disk entry -- the write path
  ## this exists to fix) is inserted before the closing brace instead of
  ## being silently dropped.
  var vs = 0
  var ve = 0
  if locatePath(text, key, vs, ve):
    result = text.substr(0, vs - 1) & valueJson & text.substr(ve)
    return
  let trimmed = strip(text)
  let member = "\"" & jsonEscapeKey(key) & "\":" & valueJson
  if trimmed.len == 0 or trimmed == "{}":
    result = "{" & member & "}"
    return
  # `trimmed` is a readable object (checked by the caller before this runs),
  # so it starts with `{` and ends with `}`; splice the new member in just
  # before the closing brace.
  let inner = strip(trimmed.substr(1, trimmed.len - 2))
  if inner.len == 0:
    result = "{" & member & "}"
  else:
    result = "{" & inner & "," & member & "}"

proc hostConfigSet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                   val: HostPtr; valLen: int32): int32 {.
    exportc: "aowlspt_nim_config_set", cdecl.} =
  ## Merges one key into this mod's `config.json`, creating the file and/or
  ## the key if either is absent. Used to silently no-op for a key the file
  ## had never held -- `applySettingFromBody` would return `Ok`, the caller's
  ## POST would get 200 with the schema's *old* value echoed back, and
  ## nothing on disk would change. Every early-return here sets `gLastError`
  ## and answers a real status instead, so a failed persist cannot look like
  ## a successful one.
  let idx = int(cast[uint](ctx))
  let k = readBytes(key, keyLen)
  let v = readBytes(val, valLen)
  if k.len == 0:
    gLastError = "config set needs a key"
    return ErrBadArg
  if v.len == 0:
    gLastError = "config set needs a value"
    return ErrBadArg
  # NOTE: `jsonFault` validates a whole DOCUMENT -- it demands the top level
  # begin with `{` -- so it cannot be used to check `v` here: `v` is almost
  # always a scalar (`"PVE ZONE"`, `true`, `1.5`), and running it through
  # jsonFault rejected every one of those with ErrBadArg before this ever
  # reached a file write. That was the actual reason no POST persisted: not
  # a missing key, not a read/write failure, but this check refusing every
  # legal value. `v`'s syntax is verified for real below, as part of the
  # whole merged document -- a malformed `v` still cannot slip past that.
  let dir = modDirOf(idx)
  if dir.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  let cfgPath = joinPath(dir, "config.json")
  var text = ""
  var readErr = ""
  let rst = configRead(idx, text, readErr)
  if rst == ErrConfigParse:
    gLastError = readErr
    return ErrConfigParse
  if rst == ErrNotFound:
    text = "{}"
  let merged = mergeConfigKey(text, k, v)
  var mergedFault = ""
  if jsonFault(merged, mergedFault):
    gLastError = "internal: the merged " & cfgPath & " would not parse (" &
                 mergedFault & ")"
    return ErrGeneric
  let wr = writeTextFile(cfgPath, merged)
  if not wr.ok:
    gLastError = "could not write " & cfgPath
    return ErrGeneric
  # The document on disk is not the one `configReadCached` is holding any more.
  # Dropped here rather than left to the TTL, so a settings edit made through
  # this server is in force for the very next read, exactly as it was before
  # the cache existed.
  configDrop(idx)
  result = StatusOk

proc hostDbGet(ctx: HostPtr; path: HostPtr; pathLen: int32;
               outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_db_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let p = readBytes(path, pathLen)
  let tDb = perfNow()
  # Copied **once**: out of the document and straight into the host buffer.
  #
  # This was `dbGetPath` into a nimony string and then `cOutCopy` out of that
  # string, which is two copies of the value -- the first into a string that
  # exists only to be the argument of the second. On `templates.items` against
  # a real database that is 12.5 MB allocated and copied for nothing, on every
  # request, and it is one of the seven copies `docs/PERF-SERVER.md` counts
  # between the database and the socket.
  #
  # `dbHoldPath` returns with the document read lock held and `dbRelease` gives
  # it back. The critical section is no longer than it was: `dbGetPath`'s
  # `substr` ran inside the same lock and for the same reason -- the lock is
  # what stops a concurrent `dbPatchPath` splicing the buffer being copied out
  # of. Nothing else is taken while it is held; the rest of the argument is at
  # `dbHoldPath`.
  # The reserved sigil, before anything else looks at the path.
  #
  # `docs/API-GAPS.md`'s gap 2: there is no `db_keys` entry, because adding one
  # is ABI revision 6 and the simulator cannot claim 6 without claiming 5 --
  # which means arming a `notify_push` it has no socket for, and which turns
  # `notifyReady()` from an honest `false` into a `true` in the one host mod
  # authors develop against. So the enumeration rides on the path string of the
  # entry that already exists, and a host that has never heard of the sigil
  # answers `ErrNotFound` for a root member that is not there, which is the
  # degradation a caller wanted anyway.
  var keysOf = ""
  if dbKeysRequest(p, keysOf):
    if keysOf.len == 0:
      # `"?keys "` alone. Refused here and **not found** on a host without
      # this, which is the difference a mod uses as a capability probe. Say
      # what it is rather than only that it is wrong.
      perfAdd(PhaseDbGet, tDb)
      gLastError = "`" & KeysSigil & "` needs a path to enumerate, e.g. `" &
                   KeysSigil & "locations`"
      return ErrBadArg
    var keys = ""
    var why = 0
    if not dbKeysPath(keysOf, keys, why):
      perfAdd(PhaseDbGet, tDb)
      if why == KeysNotAnObject:
        gLastError = keysOf & " is an array or a scalar, not an object"
        return ErrBadArg
      gLastError = "no such database path: " & keysOf
      return ErrNotFound
    result = cOutCopy(outPtr, outLen, cast[HostPtr](readRawData(keys)),
                      int32(keys.len))
    perfAdd(PhaseDbGet, tDb)
    return result

  var at = cast[pointer](0)
  var length = 0
  if not dbHoldPath(p, at, length):
    perfAdd(PhaseDbGet, tDb)
    gLastError = "no such database path: " & p
    return ErrNotFound
  result = cOutCopy(outPtr, outLen, cast[HostPtr](at), int32(length))
  dbRelease()
  perfAdd(PhaseDbGet, tDb)

proc hostDbPatch(ctx: HostPtr; path: HostPtr; pathLen: int32;
                 patch: HostPtr; patchLen: int32): int32 {.
    exportc: "aowlspt_nim_db_patch", cdecl.} =
  let p = readBytes(path, pathLen)
  let j = readBytes(patch, patchLen)
  var err = ""
  let tDb = perfNow()
  let patched = dbPatchPath(p, j, err)
  perfAdd(PhaseDbPatch, tDb)
  if not patched:
    gLastError = err
    return ErrGeneric
  result = StatusOk

proc hostRouteRegister(ctx: HostPtr; url: HostPtr; urlLen: int32; kind: int32;
                       cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_route_register", cdecl.} =
  let u = readBytes(url, urlLen)
  if u.len == 0 or cb == nil:
    gLastError = "a route needs a url and a handler"
    return ErrBadArg
  # The duplicate check and the append are one operation under the lock. Two
  # mods registering the same url from two threads would otherwise both look,
  # both miss, and both add.
  cRegWrite()
  var clash = false
  for r in gRoutes:
    if r.url == u and r.kind == kind:
      clash = true
  if not clash:
    gRoutes.add Route(url: u, kind: kind, cb: cb, user: user,
                      modIndex: int(cast[uint](ctx)))
  cRegWriteEnd()
  if clash:
    gLastError = "the route " & u & " is already registered"
    return ErrGeneric
  modhost.okLog "route " & u & (if kind == RouteDynamic: " (prefix)" else: "")
  result = StatusOk

proc deliverEvent(n, body: string; fromIndex: int): int =
  ## One event to every subscriber but `fromIndex`. Factored out of the emit
  ## entry point because the **host** emits too now -- the mod-control replies
  ## come from here rather than from any mod, and pass `fromIndex = -1` so that
  ## nobody is skipped.
  ##
  ## The matching subscribers are copied out under the registration lock and
  ## called with nothing held. Calling them under it would be a deadlock the
  ## first time a subscriber subscribed to something, and would hold the table
  ## for as long as a mod's handler takes; walking it unlocked was the
  ## use-after-free `dropModRegistrations` opened. A copy is neither.
  result = 0
  var fanout: seq[Sub] = @[]
  cRegRead()
  for i in 0 ..< gSubs.len:
    if gSubs[i].name == n and gSubs[i].modIndex != fromIndex:
      fanout.add gSubs[i]
  cRegReadEnd()
  for i in 0 ..< fanout.len:
    # The same reference `runRoute` takes, for the same reason and against the
    # same window: this is a copied function pointer into a mod's library, and
    # an emit reaches here from a worker thread while the serve loop is free to
    # unload the subscriber. A subscriber that is going away is simply skipped
    # -- an event is a broadcast, and a mod that is being unloaded is exactly a
    # mod that no longer wants to hear about anything.
    #
    # `modGuardable` first, because `modEnter` answers the same `false` for
    # "out of range" as for "being unloaded", and only the second is a reason
    # to skip. A subscriber registered under an index that is not a mod's --
    # `tools/hostharness` uses `0x7FFF` on purpose, so its own registrations
    # outlive the churn it measures -- would otherwise be dropped as though it
    # were going away, and the reply it was waiting for would simply never
    # come. The client host hit exactly that and it took a gate failure to
    # find; nothing registers such an index here today, which is why this is
    # written down rather than left to be rediscovered.
    let guarded = modhost.modGuardable(fanout[i].modIndex)
    if guarded and not modhost.modEnter(fanout[i].modIndex):
      continue
    var b = body
    let st = cInvokeCallback(fanout[i].cb, fanout[i].user,
                             cast[HostPtr](toCString(b)), int32(body.len))
    if guarded:
      modhost.modLeave(fanout[i].modIndex)
    if st != StatusOk:
      # One bad subscriber must not stop the rest: an event is a broadcast, and
      # a mod dropping it is that mod's problem rather than the emitter's.
      modhost.warn "a subscriber to " & n & " returned " & $int(st)
    inc result

proc hostEmit(name, payload: string) =
  ## What `modcontrol` answers through. `-1` is not a mod index, which is the
  ## point: every subscriber hears it, including the manager that asked.
  discard deliverEvent(name, payload, -1)

proc hostEventEmit(ctx: HostPtr; name: HostPtr; nameLen: int32;
                   payload: HostPtr; payloadLen: int32): int32 {.
    exportc: "aowlspt_nim_event_emit", cdecl.} =
  ## Delivered synchronously, in subscription order, to everyone but the
  ## emitter -- a mod that both emits and subscribes to a name is the ordinary
  ## case (it owns the event), and calling it back into its own handler turns
  ## that into a loop it never asked for.
  let n = readBytes(name, nameLen)
  let body = readBytes(payload, payloadLen)
  let from1 = int(cast[uint](ctx))
  # A control request is recorded here and performed from the serve loop. Never
  # here: this stack runs through the mod that emitted, and an unload would
  # free the library it is about to return into.
  let control = modcontrol.submit(n, body)
  let delivered = deliverEvent(n, body, from1)
  if delivered == 0 and not control:
    modhost.info "event " & n & " (no subscribers)"
  result = StatusOk

proc hostEventSubscribe(ctx: HostPtr; name: HostPtr; nameLen: int32;
                        cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_event_subscribe", cdecl.} =
  let n = readBytes(name, nameLen)
  if n.len == 0 or cb == nil:
    gLastError = "a subscription needs a name and a handler"
    return ErrBadArg
  cRegWrite()
  gSubs.add Sub(name: n, cb: cb, user: user, modIndex: int(cast[uint](ctx)))
  cRegWriteEnd()
  modhost.okLog "subscribed to " & n
  result = StatusOk

proc hostCall(ctx: HostPtr; target: HostPtr; targetLen: int32;
              args: HostPtr; argsLen: int32;
              outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_call", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  gLastError = "the backend has no managed runtime to reflect into; " &
               "`call` is a client-side facility"
  result = ErrUnsupported

proc hostResolve(ctx: HostPtr; typeName: HostPtr; nameLen: int32;
                 outHandle: HostPtr): int32 {.
    exportc: "aowlspt_nim_resolve", cdecl.} =
  gLastError = "the backend has no type universe to resolve against"
  result = ErrUnsupported

proc hostHandleRelease(ctx: HostPtr; handle: uint64) {.
    exportc: "aowlspt_nim_handle_release", cdecl.} =
  discard

proc hostPatch(ctx: HostPtr; target: HostPtr; targetLen: int32; kind: int32;
               cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_patch", cdecl.} =
  gLastError = "there is no compiled game code in the backend to patch"
  result = ErrUnsupported

proc hostNowMs(ctx: HostPtr): int64 {.exportc: "aowlspt_nim_now_ms", cdecl.} =
  result = elapsedMs()

proc hostInvokeMain(ctx: HostPtr; cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_invoke_main", cdecl.} =
  ## The backend has no main thread a mod needs to be on -- routes already run
  ## on worker threads -- so this runs the callback where it stands rather than
  ## queueing it somewhere that never drains.
  if cb == nil:
    return ErrBadArg
  discard cInvokeCallback(cb, user, cast[HostPtr](0), 0'i32)
  result = StatusOk

proc hostSchedule(ctx: HostPtr; delayMs: int32; cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_schedule", cdecl.} =
  ## Queued, and run from the serve loop rather than from whatever thread asked.
  ## A timer that fired on the calling thread would run a mod's callback on an
  ## accept worker, holding a connection slot for the length of the delay.
  if cb == nil:
    gLastError = "a timer needs a callback"
    return ErrBadArg
  var d = int64(delayMs)
  if d < 0: d = 0
  cLock()
  gTimers.add Timer(dueMs: elapsedMs() + d, cb: cb, user: user,
                    modIndex: int(cast[uint](ctx)))
  cUnlock()
  result = StatusOk

proc runTimers() =
  ## Due timers, one pass, oldest first. Rebuilding the list rather than
  ## deleting in place: a callback may schedule another timer, and appending to
  ## a sequence being iterated by index is how that turns into a lost timer or
  ## a fired-twice one.
  if gTimers.len == 0:
    return
  let now = elapsedMs()
  var due: seq[Timer] = @[]
  var keep: seq[Timer] = @[]
  cLock()
  for t in gTimers:
    if t.dueMs <= now: due.add t
    else: keep.add t
  if due.len > 0:
    gTimers = keep
  cUnlock()
  if due.len == 0:
    return
  # The callbacks run outside the lock. Mod code may take as long as it likes,
  # and holding the queue while it does would stall every route handler that
  # wants to schedule something. A repeating timer -- the obvious thing to
  # write -- therefore re-queues onto a list nobody is iterating.
  for t in due:
    discard cInvokeCallback(t.cb, t.user, cast[HostPtr](0), 0'i32)

# --------------------------------------------------------------- store

proc hostStoreGet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                  outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_store_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let k = readBytes(key, keyLen)
  let guid = modGuidOf(int(cast[uint](ctx)))
  if guid.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  var value = ""
  var error = ""
  let tStore = perfNow()
  let got = storeReadInto(guid, k, value, error)
  perfAdd(PhaseStoreGet, tStore)
  if got != ReadOk:
    gLastError = error
    if got == ReadMissing:
      return ErrNotFound
    # Present and unreadable. Deliberately *not* `ErrNotFound`: a mod that
    # cannot tell the two apart answers "your profile is unreadable" by
    # creating a new character over the top of it, and that is the one failure
    # here nobody can undo. It is logged as well as returned, because the mod
    # that gets the status may be the one that decides to carry on regardless
    # and the player deserves to find out from somewhere.
    if got == ReadFailed:
      modhost.fail "store read failed: " & error
    return ErrGeneric
  var v = value
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc hostStoreSet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                  val: HostPtr; valLen: int32): int32 {.
    exportc: "aowlspt_nim_store_set", cdecl.} =
  let k = readBytes(key, keyLen)
  let v = readBytes(val, valLen)
  let guid = modGuidOf(int(cast[uint](ctx)))
  if guid.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  var error = ""
  let tStore = perfNow()
  let wrote = storeWrite(guid, k, v, error)
  perfAdd(PhaseStoreSet, tStore)
  if not wrote:
    gLastError = error
    return ErrGeneric
  # A successful write can still have something to say: the value is committed
  # but its history copy was not. The mod is not told -- nothing it does about
  # a save that worked would be right -- but the log is, because a store
  # running without the history the documentation promises should not be a
  # silent state.
  if error.len > 0:
    modhost.info "store: " & error
  result = StatusOk

proc hostStoreList(ctx: HostPtr; prefix: HostPtr; prefixLen: int32;
                   outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_store_list", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let p = readBytes(prefix, prefixLen)
  let guid = modGuidOf(int(cast[uint](ctx)))
  if guid.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  let tStore = perfNow()
  var v = storeKeys(guid, p)
  perfAdd(PhaseStoreList, tStore)
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc patchFired(slot: int32; regs: HostPtr): int32 {.
    exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## Nothing here can fire: the backend refuses `patch` outright, having no
  ## compiled game code to detour. It exists because the shim declares the
  ## symbol unconditionally and the link needs one. Zero means "run the
  ## original", which is the only safe answer for a slot that cannot exist.
  result = 0'i32

# --------------------------------------------------------------- self test

var gSelfFailures = 0
var gSelfInconclusive = 0

proc settingsRowsUsable(n: JsonNode; what, route, body: string): bool =
  ## Is this settings payload actually the ARRAY OF ROWS the caller is about to
  ## walk with `items()`?
  ##
  ## It has to be asked, because the failure it prevents is silent up to the
  ## moment it is fatal. A backend running WITHOUT `mods/tarkov` staged answers
  ## `/aowlspt/settings/aowl.tarkov` with the OBJECT `{"err":"no route"}`. That
  ## is a 200, so `r.ok` is true; it is valid strict JSON, so `hasError` is
  ## false. Both gates the selftest already had say yes. `items(root(tree))`
  ## then hits `assert kind(n) == JArray, "items: not a JArray"` inside
  ## std/json, which ABORTS THE PROCESS -- so every remaining check never runs,
  ## and the thing the operator is told about is an assertion in a JSON library
  ## rather than the mod that is not loaded.
  ##
  ## Reported as INCONCLUSIVE, not FAIL, when the route is simply absent: a
  ## selftest run against a backend with no mods staged has not proven the
  ## settings wire wrong, it has failed to look at it. `gSelfInconclusive` is
  ## counted separately from `gSelfFailures` for exactly that reason -- "I could
  ## not look" is not a pass and is not a failure.
  if kind(n) == JArray:
    return true
  if body.contains("\"waiting\":true"):
    # MEASURED 2026-09-01, with mods/settingshub staged and mods/tarkov not:
    # this route answered `{"waiting":true,...,"err":"waiting for aowl.tarkov
    # to publish (client-side, up to 5s)","rows":[]}` and this check called it
    # a FAIL -- "the settings wire is an array of rows" -- about a mod that is
    # simply not loaded. settingshub's fallback prefix answers for any guid
    # nobody registered, so "no route" is no longer the only way an absent mod
    # shows up here. A confidently wrong diagnosis is worse than none.
    console.warn what & ": INCONCLUSIVE -- route " & route &
      " answered the settingshub `waiting` shape, which means NO MOD OWNS " &
      "that guid in this process (mods/tarkov is not staged) and the page is " &
      "expected to arrive over the client sync instead. The settings wire " &
      "was never examined."
    inc gSelfInconclusive
    return false
  if body.contains("no route"):
    console.warn what & ": INCONCLUSIVE -- route " & route &
      " answered `no route`, so the mod that owns it (aowl.tarkov, i.e." &
      " mods/tarkov) is NOT LOADED on this backend. The settings wire was" &
      " never examined. Stage mods/tarkov and name it in" &
      " mods\\aowlspt-selection.json, then re-run."
    inc gSelfInconclusive
    return false
  console.err what & ": FAIL -- route " & route &
    " answered a non-array payload (" & body & "); the settings wire is an" &
    " array of {key,value} rows."
  inc gSelfFailures
  return false

# --------------------------------------------------------------------------
# The aggregated settings surface: `/aowlspt/settings/index/full`,
# `/aowlspt/keybinds`, `POST /aowlspt/settings/<guid>/set`
# --------------------------------------------------------------------------
#
# These checks assert properties of the FINISHED DOCUMENT, never of a write
# this test just made (CLAUDE.md 9b). Concretely, each one names the input that
# would falsify it:
#
#   * strict `parseJson` + `hasError`, never `contains` -- fact #122 was 22 rows
#     of unquoted `"value":standard` that a substring test passed for months.
#   * every mod the COMPACT index lists appears in the FULL one exactly once --
#     falsified by a missing mod and by a duplicated one, which is the shape
#     that put two "Bot AI" entries in the nav.
#   * every row's `type` is in the closed set of eight -- falsified by a new
#     kind reaching the wire before a renderer knows how to draw it.
#   * `settings` and `keybinds` are ARRAYS even when empty -- falsified by the
#     `null` a "leave it out when there is nothing" implementation produces,
#     which is the difference between a consumer drawing an empty page and a
#     consumer throwing.
#   * the round trip reads the value back out of the INDEX after the write, and
#     the reset check refuses to run unless the write demonstrably moved the
#     value first.

proc jStrField(n: JsonNode; want: string): string =
  ## `n[want]` when it is a JSON string, else "". No `var JsonNode` anywhere in
  ## this file: nimony refuses one ("cannot prove that f has been initialized")
  ## because JsonNode is a cursor with no zero value, so every member access
  ## here reads the value inline while iterating rather than holding a node.
  ## `pairs` also ASSERTS on a non-object -- an assert aborts the whole
  ## process -- so the kind is checked first, every time.
  result = ""
  if kind(n) != JObject:
    return
  for k, v in pairs(n):
    if k == want and kind(v) == JString:
      return getStr(v)

proc jBoolField(n: JsonNode; want: string; default: bool): bool =
  result = default
  if kind(n) != JObject:
    return
  for k, v in pairs(n):
    if k == want and kind(v) == JBool:
      return getBool(v)

proc jHasArray(n: JsonNode; want: string): bool =
  ## Does `n` have a member `want` that is an ARRAY? The distinction this is
  ## for is `[]` (a mod with nothing to declare) versus `null`/absent (a
  ## producer that leaves the field out), which a consumer cannot iterate.
  result = false
  if kind(n) != JObject:
    return
  for k, v in pairs(n):
    if k == want:
      return kind(v) == JArray

proc keybindValueFault(b: JsonNode): string =
  ## WHAT IS WRONG with one `/aowlspt/keybinds` entry's bound value, or "" when
  ## nothing is. Stated as a fault rather than a bool so the failure message
  ## names the input that produced it.
  ##
  ## The contract, which the native Controls -> MODS page reads:
  ##   * `value` and `default` are ALWAYS PRESENT. An omission is the one shape
  ##     a consumer cannot interpret -- `entry.value === undefined` reads
  ##     identically to "this backend predates the field".
  ##   * a key the store knows -> a JSON string: the KeyCode name, or `""` for
  ##     a key the mod declares UNBOUND. `""` is legitimate and MEASURED --
  ##     `aowl.admin.hotkeyEsp` declares `keybindSetting(..., "")` and its
  ##     config.json holds `""` -- so an empty value is only a fault when the
  ##     mod declared a real `default` and the store answered blank anyway,
  ##     which is the shape of a value that was lost rather than never set.
  ##   * a key the store does NOT know -> JSON `null`, WITH
  ##     `"error":"unknown setting key"` beside it.
  ## Every one of those is falsifiable, and `keybindCheckerProvesItself` below
  ## feeds this proc an input for each so the check cannot pass vacuously.
  result = ""
  if kind(b) != JObject:
    return "the entry is not a JSON object"
  var sawValue = false
  var sawDefault = false
  var valueIsNull = false
  var valueWrongKind = false
  var valueText = ""
  var defaultText = ""
  for bk, bv in pairs(b):
    if bk == "default":
      sawDefault = true
      if kind(bv) == JString:
        defaultText = getStr(bv)
    elif bk == "value":
      sawValue = true
      if kind(bv) == JString:
        valueText = getStr(bv)
      elif kind(bv) == JNull:
        valueIsNull = true
      else:
        valueWrongKind = true
  if not sawValue:
    return "carries NO `value` at all; an unknown key must be `null` with " &
           "`\"error\":\"unknown setting key\"`, never an omission"
  if not sawDefault:
    return "carries no `default`"
  if valueWrongKind:
    return "`value` is neither a JSON string nor null"
  if valueIsNull:
    if jStrField(b, "error") != "unknown setting key":
      return "`value` is null but no `\"error\":\"unknown setting key\"` " &
             "stands beside it, so a reader cannot tell WHY it is null"
    return ""
  if valueText.len == 0 and defaultText.len > 0:
    return "`value` is EMPTY while the mod declares a `default` of `" &
           defaultText & "`; the store lost the binding, and a blank reads " &
           "as `unbound` rather than as the fault it is"

proc keybindFaultOfLiteral(text: string): string =
  var t = parseJson(text)
  if hasError(t):
    return "the fixture itself did not parse"
  result = keybindValueFault(root(t))

proc keybindCheckerProvesItself(): string =
  ## THE NEGATIVE CONTROL, run every time. `keybindValueFault` is fed one
  ## literal per branch, including the two that MUST be rejected -- an entry
  ## with no `value`, and a null `value` with no `error`. If it accepts either,
  ## the live check below could not have failed and its PASS means nothing;
  ## that is reported as a failure of the TEST, not of the route.
  ##
  ## This exists because the live mod population may legitimately contain zero
  ## unknown keys, in which case the null branch is never exercised by real
  ## data and "every live entry passed" would be a check that cannot fail.
  result = ""
  if keybindFaultOfLiteral("{\"value\":\"F7\",\"default\":\"F6\"}").len != 0:
    return "it rejects a well-formed entry"
  if keybindFaultOfLiteral("{\"default\":\"F6\"}").len == 0:
    return "it ACCEPTS an entry that omits `value`"
  if keybindFaultOfLiteral("{\"value\":null,\"default\":null}").len == 0:
    return "it ACCEPTS a null `value` with no `error` beside it"
  if keybindFaultOfLiteral("{\"value\":\"\",\"default\":\"F6\"}").len == 0:
    return "it ACCEPTS an empty `value` under a declared `default`"
  if keybindFaultOfLiteral("{\"value\":\"\",\"default\":\"\"}").len != 0:
    return "it rejects a legitimately UNBOUND key (both empty)"
  if keybindFaultOfLiteral(
       "{\"value\":null,\"default\":null,\"error\":\"unknown setting key\"}").len != 0:
    return "it rejects the declared unknown-key shape"

proc isSettingTypeName(t: string): bool =
  ## THE CLOSED SET, spelled out. It mirrors `kindName` in
  ## `aowl/src/aowlspt/settings.nim`; a ninth kind added there and not here
  ## FAILS this check, which is the intended direction -- a renderer has to be
  ## taught the new kind before it may appear on the wire.
  t == "bool" or t == "int" or t == "float" or t == "enum" or
  t == "string" or t == "keybind" or t == "select" or t == "color"

proc fullIndexValueOf(port: int; guid, key: string; found: var bool): string =
  ## The current value of one row, as `/aowlspt/settings/index/full` reports
  ## it. `found` distinguishes "the row says empty string" from "there is no
  ## such row" -- two answers a bare `""` cannot carry apart.
  found = false
  result = ""
  let r = request(port, "/aowlspt/settings/index/full", "",
                  "000000000000000000000001")
  if not r.ok:
    return
  var t = parseJson(r.body)
  if hasError(t) or kind(root(t)) != JObject:
    return
  for topKey, topVal in pairs(root(t)):
    if topKey != "mods" or kind(topVal) != JArray:
      continue
    for m in items(topVal):
      if jStrField(m, "guid") != guid or kind(m) != JObject:
        continue
      for mk, mv in pairs(m):
        if mk != "settings" or kind(mv) != JArray:
          continue
        for row in items(mv):
          if jStrField(row, "key") != key or kind(row) != JObject:
            continue
          for rk, rv in pairs(row):
            if rk == "value" and kind(rv) == JString:
              found = true
              result = getStr(rv)
              return

proc expect(what, path, body, want: string) =
  ## A free proc with a module-level counter rather than a nested one closing
  ## over a local: nimony will not let a nested proc touch its enclosing
  ## scope's variables.
  let r = request(gPort, path, body, "000000000000000000000001")
  if not r.ok:
    console.err what & ": " & r.error
    inc gSelfFailures
    return
  if not r.contains(want):
    console.err what & ": expected " & want & " in " & r.body
    inc gSelfFailures
    return
  console.ok what

# --------------------------------------------------------------- main

const Usage = """
aowlspt-backend -- the game backend

  aowlspt-backend [--root PATH] [--port N]

  --root PATH   the install (default: the directory this exe is in)
  --port N      listen port, loopback only (default 6969, or 443 with --tls)
  --tls         serve HTTPS instead of plain HTTP -- what a real post-1.0 client
                needs. Terminates TLS on port 443 (override with --port) using a
                self-signed cert generated on first use; the client does not
                validate it. The default stays plain HTTP so the test suites are
                unaffected.
  --asset-port N
                with --tls, also listen on N in PLAIN HTTP for the asset routes
                (default 80; 0 turns it off). The client fetches `/files/*` with
                Unity's own transport, which validates our self-signed cert and
                drops the request without logging anything -- so those fetches
                are served over http instead, where no validation happens. The
                mod's `Static` backend url must name the same port.
  --control-port N
                the plain-HTTP port to fall back to when the asset port above
                cannot be opened (default 6970). There is exactly ONE plain
                listener and it carries every route this server has, `/aowlspt/*`
                included -- so whichever port it ends up on is also the CONTROL
                port that the launcher uses for mod management, settings and
                profile create/select. Its real value is written to
                <root>/aowlspt-control.json; nothing has to guess it.
  --cert PATH   TLS certificate PEM (default <root>/aowlspt-tls-cert.pem)
  --key PATH    TLS private key PEM (default <root>/aowlspt-tls-key.pem)
  --gen-cert    generate the self-signed cert+key and exit, without serving
  --db PATH     database JSON to load (default <root>/db.json)
  --verbose, -v log every dispatched request (`REQ <verb> <url>`) and other
                routine per-poll bookkeeping. DEFAULT OFF. Measured: with it on,
                56% of this log is request lines at ~4.9 lines/s, because the
                settings and mods panels poll continuously. Warnings, errors and
                every verdict line are UNAFFECTED by this flag in both
                directions -- a quiet log reaches the same conclusions.
  --once        serve until one request has been handled, then exit
  --perf        accumulate per-phase timings and print them at exit
  --selftest    serve, drive every route from inside this process, then exit
                with the result. One command, no orchestration.
  --no-warm     do NOT pre-build and pre-deflate the static load-path tables
                at startup. They are warmed by default, one route per serve-loop
                tick, off the accept path -- see `warmStep`. Each candidate is
                produced twice with different inputs and refused unless the two
                are byte-identical, and the whole cache is dropped after the
                TTL below.
  --warm-ttl N  seconds a warm entry lives (default 120). After it, the server
                answers exactly as it did before the cache existed.
  --etag        conditional GET on the warm routes: a 200 carries an `ETag`,
                and a request carrying a matching `If-None-Match` is answered
                `304` with no body -- which is what BSG's own server does for
                the repeat `/client/items` and `/client/globals` (capture seq
                069/224/426 and 229/424). Default OFF, and inert unless the
                client actually sends a validator; whether it does is logged
                on the first request for each route.
  --store-flush force every store write to the medium before it is committed.
                Costs about 6 ms a write and protects against a power cut, not
                against a crash -- see docs/BACKEND.md.
  --no-store-lock
                start even if another backend already holds this store. Two
                servers writing one profile lose saves; this is an escape
                hatch, not an option.
  -h, --help    this
"""

proc portHolder(port: int): string =
  ## Who is listening on `port`, in words, or `""` if that could not be found
  ## out. Never a guess: an empty answer here means the line is left off, not
  ## that it is filled in with the process most likely to be there.
  # Zeroed explicitly: nimony refuses to take the address of an uninitialised
  # array, and is right to -- the C side nul-terminates what it writes, but a
  # path it could not read leaves the rest of this untouched.
  var buf: array[512, char] = default(array[512, char])
  let pid = int(cNetPortHolder(int32(port), addr buf[0], 512'i32))
  if pid == 0:
    return ""
  var path = ""
  var i = 0
  while i < 512 and buf[i] != '\0':
    path.add buf[i]
    inc i
  if path.len > 0:
    result = path & " (pid " & $pid & ")"
  else:
    # `OpenProcess` is allowed to fail on a service or another user's process.
    # A pid alone still ends the search -- Task Manager takes it.
    result = "pid " & $pid

proc reservePort(): bool =
  ## Take the listening port, before anything else in this process is started.
  ##
  ## This used to happen at the *end* of startup, inside `aowl_net_serve`,
  ## after every route was registered and every mod's `on_load` had run. The
  ## work was wasted, which is the smaller half of the problem. The larger half
  ## is what it did to the log: a playtest run that could not have the port
  ## produced a hundred and fifty lines of a server coming up perfectly,
  ## followed at 312 ms by one line saying the port was taken -- a shape that
  ## reads as "the last mod broke it", and gets debugged that way.
  ##
  ## Only the bind moves up here. The `listen` stays where it was, because a
  ## listening socket answers `connect` from the kernel backlog with nobody
  ## accepting, and `aowllaunch`, `soak` and `aowlspt-verify` all read a
  ## successful connect as "the backend is up". See `aowlspt_net.h`.
  if cNetReserve(int32(gPort)) != 0'i32:
    modhost.okLog "port " & $gPort & " is free"
    console.line "  port  " & $gPort
    return true

  let e = int(cNetLastError())
  if e == WsaAddrInUse or e == WsaAccess:
    console.err "port " & $gPort & " is already in use"
    let who = portHolder(gPort)
    if who.len > 0:
      # A path beats every guess that could be made from the port number, so
      # when there is one it is the whole of the answer.
      console.line "  held by " & who
      modhost.fail "port " & $gPort & " is already in use, held by " & who
    else:
      # Named as SPT because that is overwhelmingly what it is and the reader
      # has no reason to know the two servers share a default. An SPT install
      # is *required* for the database import (docs/INSTALL.md step 5), so
      # anyone who leaves its server running meets this on their first launch.
      console.line "  another server -- SPT's own (it defaults to 6969 too)," &
                   " or an earlier"
      console.line "  aowlspt-backend -- already holds 127.0.0.1:" & $gPort & "."
      modhost.fail "port " & $gPort & " is already in use"
    console.line "  Close it, or start this one with --port N."
    return false

  console.err "could not bind port " & $gPort & " (error " & $e & ")"
  modhost.fail "could not bind " & $gPort & " (error " & $e & ")"
  result = false

proc main(): int =
  var root = ""
  var dbPath = ""
  var once = false
  var selftest = false
  var noLock = false
  var verbose = false
  # TLS. `tlsMode` serves HTTPS (what a real post-1.0 client needs, on port 443
  # by default); the default stays plain HTTP so `emutest`/`realtest` and every
  # other tool keep speaking the wire they always did. `portSet` lets `--tls`
  # pick 443 only when `--port` did not already choose one. `certPath`/`keyPath`
  # default to PEM files beside the backend; `genCertOnly` is the one-time setup
  # step that writes them and exits without serving.
  var tlsMode = false
  var portSet = false
  var genCertOnly = false
  var certPath = ""
  var keyPath = ""
  # The plain-HTTP asset listener. 80 is the default because it is the port a
  # bare `http://127.0.0.1` names, which is what the tarkov mod puts in
  # `backend.Static` -- keeping the url portless keeps it out of reach of the
  # client's host parsing. `--asset-port 0` turns it off; anything else moves
  # it, and the mod's `AssetUrl` has to be moved to match.
  var assetPort = 80
  var assetPortSet = false
  # The plain-HTTP CONTROL port.
  #
  # There is exactly one plain listener (`aowl_net_listen_plain`, socket
  # `g_listenSock2`), and it is not an asset-only server: everything downstream
  # of `accept` branches on the per-connection `ssl` handle rather than on the
  # listener, so a connection arriving there reaches the same router as one over
  # TLS. `/aowlspt/*` therefore already answers on it. What was missing was a
  # port the launcher could rely on and a way to find it -- the asset port is 80,
  # which is very often held on Windows, and when it is held the whole plain
  # surface disappeared with it.
  #
  # So: 80 is tried first (assets keep the portless url the tarkov mod's
  # `Static` needs), and if it is unavailable the plain listener is opened here
  # instead. Assets are lost in that case and the log says so, but mod
  # management, settings and profile creation are not.
  #
  # 6970 rather than a port chosen at run time: a fixed number is greppable, is
  # stable across restarts, and sits next to the 6969 everything in this repo
  # already knows. It is not *trusted* as a fixed number anywhere -- the value
  # that was actually bound is published in `aowlspt-control.json` and the
  # launcher reads that, so an override or a fallback needs no other change.
  var controlFallback = 6970
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= n: root = paramStr(i)
    elif a == "--port":
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any:
          gPort = v
          portSet = true
    elif a == "--asset-port":
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any:
          assetPort = v
          assetPortSet = true
    elif a == "--control-port":
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any:
          controlFallback = v
    elif a == "--tls":
      tlsMode = true
    elif a == "--cert":
      inc i
      if i <= n: certPath = paramStr(i)
    elif a == "--key":
      inc i
      if i <= n: keyPath = paramStr(i)
    elif a == "--gen-cert":
      genCertOnly = true
      tlsMode = true
    elif a == "--db":
      inc i
      if i <= n: dbPath = paramStr(i)
    elif a == "--once":
      once = true
    elif a == "--perf":
      # Off by default, and one branch per call site when it is off. A
      # per-phase breakdown is the only way to tell the mod's own time from
      # the server's, and rebuilding the instrument every time somebody asks
      # is how the answer goes back to being a guess.
      perfEnable()
    elif a == "--verbose" or a == "-v":
      # THE FIREHOSE, and it is opt-in. Default OFF, because the default log is
      # the one a player sends us and 56% of it was per-poll request lines.
      # This turns `modhost.debug` on and nothing else: no verdict, warning or
      # error is gated on it in either direction, so a quiet log and a verbose
      # log agree on every conclusion and differ only in bookkeeping.
      verbose = true
    elif a == "--no-warm":
      # The warm cache (see `warmStep`). ON by default: it is the difference
      # between a 1295 ms first `/client/items` and a 30 ms one, and it refuses
      # any route that fails its own two-input self-check. Off is the control
      # for a before/after measurement, and the escape hatch if it is ever
      # implicated in a wrong answer.
      gWarmOn = false
    elif a == "--warm-ttl":
      inc i
      if i <= n:
        var secs = 0
        var okNum = paramStr(i).len > 0
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9': secs = secs * 10 + (ord(ch) - ord('0'))
          else: okNum = false
        if okNum: gWarmTtlMs = int64(secs) * 1000'i64
    elif a == "--etag":
      # Conditional GET on the warm routes. Default OFF: see `gEtagOn` for
      # what is measured and what is not. It can only ever withhold a body the
      # request itself said it already had.
      gEtagOn = true
    elif a == "--selftest":
      selftest = true
    elif a == "--store-flush":
      # Force every store write to the medium before it is committed. Off by
      # default because it costs 3.9 ms of a 4.3 ms write and buys nothing
      # against a crash -- the rename is what makes a write all-or-nothing.
      # What it buys is the power-cut case: without it, a machine that loses
      # power can come back having lost the last write. It can never come back
      # with a half-written profile either way.
      storeFlushOnWrite(true)
    elif a == "--no-store-lock":
      # An escape hatch, and documented as one. If the claim below ever
      # refuses a store it should not have -- a filesystem that cannot do
      # delete-on-close, something exotic under a network path -- a player
      # should be able to start their server anyway rather than wait for a
      # fix. Running two backends on one store with it is still the data-loss
      # bug it was; nothing here makes that safe.
      noLock = true
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    elif a.startsWith("-"):
      err "unknown option: " & a
      return 1
    inc i

  startClock()
  if root.len == 0:
    root = parentOf(absolutePathOf(paramStr(0)))
  gRoot = absolutePathOf(root)

  let logPath = joinPath(gRoot, "aowlspt-backend.log")
  openLog(logPath, HostName & " " & HostVersion & "\n" &
                   "root " & gRoot & "\n\n")
  setLogVerbose(verbose)
  # ANNOUNCE THE QUIET, at info, so a reader of a quiet log is never left to
  # wonder whether the server handled no requests or merely did not say so.
  # An instrument that is off and does not say it is off is how "no REQ lines"
  # gets read as "the client never connected".
  if verbose:
    info "verbose logging is ON (--verbose): every dispatched request is " &
         "logged as `REQ <verb> <url>`. This is the firehose; expect several " &
         "lines per second while a settings or mods panel is open."
  else:
    info "verbose logging is OFF (the default): per-request `REQ` lines are " &
         "NOT written. Their absence is this setting, not an idle server. " &
         "Pass --verbose to get them. Warnings, errors and verdicts are " &
         "unaffected and appear either way."

  # Before anything that spawns a thread or answers a request: a native fault in
  # the C net engine has no Nim handler above it and would otherwise leave the
  # log ending on an ordinary request with no cause. This makes the next such
  # crash name its own faulting address. See the emit block above.
  cCrashSetLog(cast[HostPtr](readRawData(logPath)), int32(logPath.len))
  cCrashInstall()

  console.heading "aowlspt-backend"
  console.line "  root  " & gRoot
  console.line "  log   " & logPath

  # TLS setup, before anything that would be wasted work if it fails.
  #
  # The default port for the real client is 443: post-1.0 EFT talks to its
  # backend over HTTPS on a hardcoded 443 and disables certificate validation,
  # so any self-signed cert is accepted. Plain HTTP keeps its 6969 default. A
  # `--port` on the command line wins over both.
  if tlsMode and not portSet:
    gPort = 443
  if certPath.len == 0:
    certPath = joinPath(gRoot, "aowlspt-tls-cert.pem")
  if keyPath.len == 0:
    keyPath = joinPath(gRoot, "aowlspt-tls-key.pem")

  if tlsMode:
    # Generate the self-signed cert+key with `openssl.exe` when they are not
    # already there (or always, for `--gen-cert`). The client does not validate,
    # so the CN is irrelevant; `aowl_net_tls_gencert` uses localhost. openssl is
    # taken from PATH, with the ucrt64 install this repo builds against as a
    # fallback so a from-source run needs nothing arranged.
    let haveCert = fileExists(certPath) and fileExists(keyPath)
    if genCertOnly or not haveCert:
      var openssl = "openssl"
      const ucrtOpenssl = "C:\\msys64\\ucrt64\\bin\\openssl.exe"
      if fileExists(ucrtOpenssl):
        openssl = ucrtOpenssl
      console.line "  tls   generating a self-signed certificate"
      let rc = cNetTlsGenCert(toCString(openssl), toCString(certPath),
                              toCString(keyPath))
      if rc != 0'i32 or not (fileExists(certPath) and fileExists(keyPath)):
        console.err "could not generate a TLS certificate with openssl"
        console.line "  tried " & openssl & " (rc " & $int(rc) & ")."
        console.line "  Generate it by hand, e.g.:"
        console.line "    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \\"
        console.line "      -subj \"/CN=localhost\" -keyout \"" & keyPath &
                     "\" -out \"" & certPath & "\""
        modhost.fail "TLS certificate generation failed"
        return 1
      modhost.okLog "generated TLS certificate " & certPath
    console.line "  tls   cert " & certPath
    console.line "  tls   key  " & keyPath
    if genCertOnly:
      # A setup step, not a run: the cert is on disk, say so and stop.
      console.ok "TLS certificate ready"
      return 0
  # Before the database, before the store, before a single mod. The port is the
  # one thing this process needs that another process can be holding, and it is
  # the cheapest of all of them to check.
  if not reservePort():
    return 1

  if dbPath.len == 0:
    dbPath = joinPath(gRoot, "db.json")
  if fileExists(dbPath):
    var text = ""
    if readTextFile(dbPath, text):
      dbLoad(text)
      modhost.info "database loaded from " & dbPath & " (" & $text.len & " bytes)"
      line "  db    " & dbPath
  else:
    # `warn`, not `info`, and said in full. Without the database the backend
    # does not fail -- it comes up, loads every mod, creates profiles and
    # answers 200 on every route, with `/client/items`, `/client/globals` and
    # `/client/customization` all returning a structurally valid and EMPTY
    # `data`. Measured: 33-byte bodies, `{"err":0,"errmsg":null,"data":{}}`.
    # So every signal a tester can see says healthy, and the game has no items
    # in it. That is the silent-decline failure this project keeps paying for,
    # and one `info` line at the top of a log nobody reads is not an
    # announcement.
    modhost.warn "NO DATABASE at " & dbPath & " -- the backend will still " &
                 "start and answer every request, but /client/items, " &
                 "/client/globals and /client/customization will all be " &
                 "EMPTY and the game will have no items in it. Run " &
                 "aowl-importdb.exe against a Tarkov/SPT install to produce " &
                 "db.json, then restart the backend."
    console.line "  db    (NONE -- the game will have no items; run aowl-importdb)"

  storeInit(gRoot)
  console.line "  store " & storeRoot()

  # One backend per store, claimed before a single mod is loaded -- a mod's
  # `on_load` may write, and a second server that gets as far as writing has
  # already done the damage. Refused rather than warned about: the failure it
  # prevents is two processes taking turns to undo each other's saves, which
  # shows up as progress that comes and goes and is diagnosed by nobody.
  if not noLock:
    var holder = ""
    var lockError = ""
    if not storeLock("backend", holder, lockError):
      console.err lockError
      if holder.len > 0:
        console.line "  held by " & strip(holder)
      console.line "  another aowlspt-backend is using " & storeRoot() & "."
      console.line "  Close it and try again (--no-store-lock overrides, and"
      console.line "  two servers writing one store lose saves)."
      modhost.fail lockError
      return 1

  # Everything a mod left in this host, dropped before its library is freed.
  # Order around it is the loader's guarantee: after the mod's `on_unload`,
  # before `FreeLibrary`. Anything missed here is a route still served, an
  # event still delivered or a timer still due -- each of them a call through a
  # function pointer into memory that has been unmapped.
  proc dropModRegistrations(index: int) =
    # Under the registration lock, for the reason the timer sweep below is
    # under the host lock and with more at stake: this rebinds two sequences
    # that every worker walks on every request, and rebinding one drops the
    # last reference to the buffer a worker may be halfway through. It ran
    # unlocked, and `aowl test` unloads a mod while the server is serving.
    cRegWrite()
    var keptRoutes: seq[Route] = @[]
    for r in gRoutes:
      if r.modIndex != index: keptRoutes.add r
    gRoutes = keptRoutes

    var keptSubs: seq[Sub] = @[]
    for sb in gSubs:
      if sb.modIndex != index: keptSubs.add sb
    gSubs = keptSubs
    cRegWriteEnd()

    # Under the lock: `hostSchedule` runs on whatever thread a route handler is
    # on, and may be appending while this walks.
    cLock()
    var keptTimers: seq[Timer] = @[]
    for t in gTimers:
      if t.modIndex != index: keptTimers.add t
    gTimers = keptTimers
    cUnlock()

  setModTeardown(dropModRegistrations)

  # What `modcontrol` is allowed to know and do here. Deliberately narrow: it
  # gets no access to the mod table, only these answers about it.
  #
  # Installed **before** the mods are loaded, not after. The manager probes for
  # a host from its own `on_load`, so a controller that starts afterwards is a
  # controller that misses the only question it was ever asked -- and the
  # manager then spends the session reporting "no host answered the control
  # probe". Queueing before any mod exists is safe: nothing is performed until
  # the serve loop drains.
  proc opsCount(): int = modhost.modCount()
  proc opsGuid(i: int): string = modhost.modGuidOf(i)
  proc opsName(i: int): string = modhost.modNameOf(i)
  proc opsVersion(i: int): string = modhost.modVersionOf(i)
  proc opsPath(i: int): string = modhost.modPathOf(i)
  proc opsLive(i: int): bool = modhost.modIsLive(i)
  proc opsFlags(i: int): uint32 = modhost.modFlagsOf(i)
  proc opsIndex(guid: string): int = modhost.modIndexOf(guid)
  proc opsCanUnload(ignored: int): bool = modhost.hasTeardown()
  proc opsLoad(path: string): bool =
    modhost.loadOne(path, SideServer, HostName, HostVersion)
  proc opsUnload(guid: string): string =
    var err = ""
    if modhost.unloadByGuid(guid, err):
      return ""
    result = (if err.len > 0: err else: "the host refused to unload it")
  proc opsLog(msg: string) = modhost.info msg

  modcontrol.controlInit(HostName, HostVersion, SideServer, hostEmit,
                         HostOps(count: opsCount, guidOf: opsGuid,
                                 nameOf: opsName, versionOf: opsVersion,
                                 pathOf: opsPath, liveOf: opsLive,
                                 flagsOf: opsFlags, indexOf: opsIndex,
                                 canUnload: opsCanUnload, load: opsLoad,
                                 unload: opsUnload, log: opsLog))

  # The one entry `aowl_hostapi_new` cannot fill, through the mechanism the
  # IL2CPP host already uses for the two *it* fills. See `aowlspt_notify.h` for
  # why arming revision 5 also means filling revisions 3 and 4 with the refusal
  # they already owed.
  setHostBlockArm(cArmNotify)

  # And the three calls `websocket.nim` cannot make for itself. Before the
  # server starts, so no connection can arrive at a handshake that has nowhere
  # to write its answer.
  websocket.wsBind(wsRawSend, wsFrameSend, wsAdopt)

  # THE MOD LOAD USED TO BE HERE, above the listener, and that is the startup
  # race: nothing answered `connect` on 443 until every server mod had finished
  # its `on_load` -- 4.656 s on the boot that produced `Unable to check the
  # client version`, because `aowl.waypoints` builds 8,556 patrol points first.
  # It now happens after `cNetServe` below, and `waitForMods` holds any request
  # that arrives in between. Nothing about the ORDER OF SETUP changed: the
  # database, the store lock, `modcontrol.controlInit` and `websocket.wsBind`
  # are all still done before a single mod exists, which is what they required.
  # Sixteen *request* workers, which is a different thing from what this
  # number used to be.
  #
  # It used to be the connection limit: a worker took a connection at `accept`
  # and stayed with it until the client let go, so sixteen open sockets were
  # sixteen occupied threads whether or not any of them ever asked for
  # anything. That is what made a handful of stalled connections a denial of
  # service, and no value of this number fixes it -- eight was starved by
  # twelve, sixteen would be starved by twenty, and the attacker picks.
  #
  # A worker now takes a *complete request*, answers it, and gives the
  # connection back. Connections are held by the poller, which does not have a
  # thread each; the limit on them is `AOWL_NET_MAX_CONNS` (1024) and
  # `AOWL_NET_MAX_BUFFERED` (64 MiB), both in `aowlspt_net.h`. So this is the
  # concurrency limit on doing work, which is the only thing a thread was ever
  # needed for.
  # TLS or plain, chosen once here. The two calls are the same but for the
  # transport: `cNetServeTls` builds the OpenSSL server context from the cert
  # generated above and puts the poller into TLS mode; everything the HTTP loop
  # does above the byte stream is identical. A TLS context that fails to build
  # (a bad cert, or the OpenSSL DLLs not found) is not a port collision, so it
  # is reported with the reason the shim gives rather than a winsock number.
  let started =
    if tlsMode: cNetServeTls(int32(gPort), 16'i32,
                             toCString(certPath), toCString(keyPath))
    else: cNetServe(int32(gPort), 16'i32)
  if started == 0'i32:
    if tlsMode and cNetTlsReady() == 0'i32:
      # The listen never happened: the OpenSSL context could not be built. Its
      # own error names why (missing DLLs, an unreadable cert, a mismatched
      # key) far better than a winsock code, which here would be a stale zero.
      let msg = readBytes(cast[HostPtr](cNetTlsError()), cNetTlsErrorLen())
      console.err "could not start TLS: " & msg
      modhost.fail "could not start TLS: " & msg
      return 1
    # A port collision is the ordinary way this fails, and it deserves to be
    # said in those words rather than as a number. It is what happens when the
    # last backend has not quite exited, when SPT's own server is up, and on
    # any machine running two stages at once -- and the alternative to naming
    # it is a tool somewhere else reporting a connect timeout, which sends
    # whoever reads it looking in the wrong place.
    let e = int(cNetLastError())
    console.err "could not listen on port " & $gPort & " (error " & $e & ")"
    modhost.fail "could not listen on " & $gPort & " (error " & $e & ")"
    return 1
  # Written only now, and only from the socket's own result -- the bind is
  # `reservePort`'s, several hundred milliseconds earlier, and it deliberately
  # does not write this line. What is claimed here is *listening*, and that is
  # true from the statement above and not before it.
  #
  # It reads like a log line and it is an interface: `allmods`, `fuzzwire`,
  # `livectl`, `soak`, `wstest` and `aowlspt-verify` all decide the server is
  # up by finding `listening` in this file. It used to be able to appear after
  # a bind that had quietly attached to somebody else's port -- see
  # `SO_EXCLUSIVEADDRUSE` in `aowlspt_net.h` -- and every one of those tools
  # then waited on a server that was never going to answer them.
  # The scheme is named so a reader can tell a TLS run from a plain one, but the
  # word `listening` is kept verbatim: `allmods`, `fuzzwire`, `livectl`, `soak`,
  # `wstest` and `aowlspt-verify` all wait for exactly that string to decide the
  # server is up.
  let scheme = if tlsMode: "https" else: "http"
  gServeStartMs = elapsedMs()
  modhost.okLog "listening on " & scheme & "://127.0.0.1:" & $gPort
  console.line "  port  " & $gPort & (if tlsMode: " (TLS)" else: "")

  # The plain-HTTP asset listener, opened only in TLS mode -- a plain run is
  # already entirely plain and has nothing to gain from a second socket on the
  # same terms.
  #
  # Opened *after* the main listener is up, so a server that could not start at
  # all never leaves a bound port behind, and never fatal: losing this port
  # costs the asset fetches that are not already in the client's own cache, and
  # costs nothing else. `/client/*` is unaffected either way -- it goes over
  # TLS on `gPort` and the client accepts our certificate there.
  #
  # 80 is very often held on a Windows box (IIS, the WinNAT/Hyper-V reservation,
  # Skype's old habit), so the failure is a normal thing to meet rather than an
  # exotic one, and it says what to do about it.
  #
  # `controlPort` is whatever the plain listener actually ended up on -- 0 when
  # there is none. It is derived from the socket's own result, never assumed:
  # the whole point of publishing it is that no reader has to guess.
  var controlPort = 0
  if not tlsMode:
    # A plain run's main listener already is the plain listener. Nothing to open.
    controlPort = gPort
  elif assetPort > 0:
    if cNetListenPlain(int32(assetPort)) != 0'i32:
      controlPort = assetPort
      modhost.okLog "asset listener on http://127.0.0.1:" & $assetPort
      console.line "  asset " & $assetPort & " (plain HTTP)"
    else:
      let who = portHolder(assetPort)
      console.err "could not listen on asset port " & $assetPort &
                  (if who.len > 0: ", held by " & who else: "")
      console.line "    Assets (trader and quest icons, bundles) are fetched by"
      console.line "    Unity's own transport, which rejects this server's"
      console.line "    self-signed certificate silently -- so without this"
      console.line "    plain-HTTP port only assets already in the client's"
      console.line "    local cache will appear."
      console.line "    Pick a free port with --asset-port N, and set the tarkov"
      console.line "    mod's AssetUrl to http://127.0.0.1:N to match."
      modhost.warn "asset port " & $assetPort & " unavailable" &
                   (if who.len > 0: " (held by " & who & ")" else: "") &
                   "; uncached asset fetches will fail"
      # Assets are lost, but the control surface need not be. The same socket is
      # still free to open on another port.
      if controlFallback > 0 and cNetListenPlain(int32(controlFallback)) != 0'i32:
        controlPort = controlFallback
        modhost.okLog "control listener on http://127.0.0.1:" & $controlFallback
        console.line "  control " & $controlFallback & " (plain HTTP, no assets)"
  elif assetPortSet:
    console.line "  asset disabled (--asset-port 0)"
    modhost.warn "asset listener disabled; uncached asset fetches will fail"
    if controlFallback > 0 and cNetListenPlain(int32(controlFallback)) != 0'i32:
      controlPort = controlFallback
      modhost.okLog "control listener on http://127.0.0.1:" & $controlFallback
      console.line "  control " & $controlFallback & " (plain HTTP, no assets)"

  # Publish it, or make sure nothing stale claims one.
  #
  # Written last, from `controlPort`, so the file exists only when a plain
  # socket is genuinely listening -- and REMOVED when there is none, because a
  # leftover file from a previous run is exactly the "confidently wrong answer"
  # a reader cannot tell from a right one. Readers are still expected to probe
  # the port rather than trust the file: this process can die without unlinking.
  let ctlPath = joinPath(gRoot, "aowlspt-control.json")
  if controlPort > 0:
    let ctlBody = "{\"port\":" & $controlPort &
                  ",\"url\":\"http://127.0.0.1:" & $controlPort & "\"" &
                  ",\"pid\":" & $processId() &
                  ",\"assets\":" & (if controlPort == assetPort: "true" else: "false") &
                  ",\"tls\":" & (if tlsMode: "true" else: "false") & "}\n"
    if writeTextFile(ctlPath, ctlBody).ok:
      modhost.okLog "control port published in " & ctlPath
    else:
      modhost.warn "could not write " & ctlPath &
                   "; the launcher will have to be told the port by hand"
  else:
    discard removeFileAt(ctlPath)
    modhost.warn "no plain-HTTP control listener: mod management, settings " &
                 "and profile creation are unreachable from the launcher, " &
                 "which speaks plain HTTP only"

  # NOW the mods. The socket is listening, the control port is published, and
  # any request that arrives during this waits in `waitForMods` rather than
  # meeting a route table that is still being filled.
  let modsDir = joinPath(gRoot, "mods")
  let count = loadAll(modsDir, SideServer, HostName, HostVersion)
  gModsReadyMs = elapsedMs()
  gModsReady = true
  console.line "  mods  " & $count
  console.line "  routes " & $gRoutes.len
  # The readback for the whole fix, in one line, with the number that says
  # whether the race was live on THIS boot: `held 0` means the client had not
  # asked yet, `held 3` means it had and the old build would have failed.
  modhost.okLog "mods loaded (" & $count & " mods, " & $gRoutes.len &
                " routes) at " & $gModsReadyMs & " ms; listening since " &
                $gServeStartMs & " ms; held " & $gHeldRequests &
                " request(s) meanwhile"

  console.line ""
  console.line "  serving. Ctrl-C to stop."

  if selftest:
    # The server is up on a loopback port; drive it through the same wire code
    # `aowlprobe` uses, so this tests the framing rather than trusting it.
    console.heading "Self test"
    expect("status route", "/aowlspt/status", "", "\"ok\":true")
    expect("body survives the round trip", "/aowlspt/echo",
           "{\"hello\":\"world\"}", "hello")
    expect("prefix route reads the database",
           "/aowlspt/item/5447a9cd4bdc2dbd208b4567", "", "\"weight\"")
    expect("unknown routes 404", "/nope", "", "no route")
    expect("a mod can create a database path that was not there",
           "/aowlspt/created", "", "gameserver")

    # A body that is not compressed must still be accepted: the tools people
    # debug with do not compress, and rejecting them would make the server
    # untestable by hand.
    let plain = request(gPort, "/aowlspt/echo", "{\"plain\":1}",
                        "000000000000000000000001", false)
    if plain.ok and plain.contains("plain"):
      console.ok "an uncompressed body is accepted too"
    else:
      console.err "an uncompressed body was rejected"
      inc gSelfFailures

    # The mod settings wire format must be STRICT json, not just something the
    # client's own tolerant parser happens to accept -- fact #122 was 22 rows
    # of unquoted `"value":standard` that this same self test's `contains`-only
    # `expect` helper would never catch. Parse it for real and check the enum
    # row round-trips.
    let settingsResp = request(gPort, "/aowlspt/settings/aowl.tarkov", "",
                               "000000000000000000000001")
    if not settingsResp.ok:
      console.err "settings route: " & settingsResp.error
      inc gSelfFailures
    else:
      var tree = parseJson(settingsResp.body)
      if hasError(tree):
        console.err "settings route did not parse as strict JSON: " & errorMsg(tree)
        inc gSelfFailures
      elif not settingsRowsUsable(root(tree), "settings route",
                                  "/aowlspt/settings/aowl.tarkov",
                                  settingsResp.body):
        discard  # already reported, as FAIL or INCONCLUSIVE; keep going
      else:
        var sawEdition = false
        for row in items(root(tree)):
          var isEdition = false
          var valueOk = false
          for k, v in pairs(row):
            if k == "key" and v.getStr() == "edition":
              isEdition = true
            if k == "value" and v.kind == JString and v.getStr().len > 0:
              valueOk = true
          if isEdition:
            sawEdition = true
            if not valueOk:
              console.err "settings route: 'edition' value did not round-trip as a string"
              inc gSelfFailures
        if sawEdition:
          console.ok "settings route is strict JSON and 'edition' survives the round trip"
        else:
          console.err "settings route: no 'edition' row found to check"
          inc gSelfFailures

    # A POST to a DECLARED key must actually persist -- and a reset must put
    # the declared default back -- even when `config.json` never held that key
    # to begin with. `menuCornerLabel` is exactly that key on a stock install
    # (fact: `mods/tarkov/config.json` ships with no `menuCornerLabel` entry;
    # only the schema's `enumSetting` default supplies one), which is what
    # made the write path's old behaviour -- `configSet` hard-coded to
    # `ErrUnsupported`, silently discarded by every mod's route handler -- a
    # 200 that echoed the unchanged value back and changed nothing on disk.
    const cornerRoute = "/aowlspt/settings/aowl.tarkov"
    const cornerResetRoute = cornerRoute & "/reset"
    proc cornerLabelValue(): string =
      let r = request(gPort, cornerRoute, "", "000000000000000000000001")
      result = ""
      if not r.ok:
        return
      var tree = parseJson(r.body)
      if hasError(tree):
        return
      # Same abort, second site: `cornerLabelValue` is called four times by the
      # write/reset check below, and each one used to walk `{"err":"no route"}`
      # straight into std/json's `items: not a JArray` assert. An empty string
      # here reads as "no menuCornerLabel row", which the caller already knows
      # how to report.
      if kind(root(tree)) != JArray:
        return
      for row in items(root(tree)):
        var isCorner = false
        var v = ""
        for k, val in pairs(row):
          if k == "key" and val.getStr() == "menuCornerLabel":
            isCorner = true
          if k == "value" and val.kind == JString:
            v = val.getStr()
        if isCorner:
          return v

    let before = cornerLabelValue()
    # The escaping that matters: the wire body's "value" field IS the JSON
    # literal to persist (per `applySettingFromBody`'s docstring, the same
    # shape a keybind's `"KeypadMultiply"` uses) -- one level of quoting, not
    # two. `\"PVE ZONE\"` here is Nim source escaping down to the single JSON
    # string literal `"PVE ZONE"` on the wire; escaping it a second time would
    # send a value whose *content* is the four extra quote characters, not
    # the six-character label this checks for.
    let setResp = request(gPort, cornerRoute,
                          "{\"key\":\"menuCornerLabel\",\"value\":\"PVE ZONE\"}",
                          "000000000000000000000001")
    let after = cornerLabelValue()
    let writeWorked = setResp.ok and after == "PVE ZONE"
    if not setResp.ok:
      console.err "settings write: POST failed: " & setResp.error
      inc gSelfFailures
    elif not writeWorked:
      console.err "settings write: POST to a key not yet in config.json did " &
                  "not persist (before=\"" & before & "\" after=\"" & after &
                  "\", wanted \"PVE ZONE\")"
      inc gSelfFailures
    else:
      console.ok "settings write: a declared key with no prior config.json " &
                 "entry now persists"

    # The reset check's whole point is to prove a WRITE happened and reset
    # undid it. If the write above did not actually change the value, the
    # value was already sitting at "Profile Name" and a reset that does
    # NOTHING would still make this assertion read true -- exactly the
    # unfalsifiable shape rule 9b warns about, so that precondition is
    # checked explicitly and a failed precondition is reported as
    # INCONCLUSIVE, never as `ok`.
    if not writeWorked:
      console.err "settings reset: INCONCLUSIVE -- the write above did not " &
                  "establish a value other than the default, so this check " &
                  "cannot tell a working reset from a no-op one"
      inc gSelfFailures
    else:
      let resetResp = request(gPort, cornerResetRoute,
                              "{\"key\":\"menuCornerLabel\"}",
                              "000000000000000000000001")
      let afterReset = cornerLabelValue()
      if not resetResp.ok:
        console.err "settings reset: POST failed: " & resetResp.error
        inc gSelfFailures
      elif afterReset != "Profile Name":
        console.err "settings reset: did not restore the declared default " &
                    "(got \"" & afterReset & "\", wanted \"Profile Name\", " &
                    "was \"PVE ZONE\" before the reset)"
        inc gSelfFailures
      else:
        console.ok "settings reset: restores the schema's declared default " &
                   "(confirmed it was \"PVE ZONE\", not \"Profile Name\", " &
                   "immediately before the reset)"

    # ---- the aggregated settings surface (mods/settingshub) ----
    #
    # INCONCLUSIVE, not FAIL, when settingshub is not staged: the wire was not
    # examined, and "I could not look" is not a pass.
    var fullGuids: seq[string] = @[]
    var fullModCount = 0
    var fullRowCount = 0
    var rtGuid = ""
    var rtKey = ""
    var rtDefault = ""
    let fullResp = request(gPort, "/aowlspt/settings/index/full", "",
                           "000000000000000000000001")
    if not fullResp.ok:
      console.err "settings index/full: " & fullResp.error
      inc gSelfFailures
    elif fullResp.contains("no route"):
      console.warn "settings index/full: INCONCLUSIVE -- route " &
        "/aowlspt/settings/index/full answered `no route`, so " &
        "mods/settingshub is NOT LOADED on this backend and the aggregated " &
        "settings surface was never examined."
      inc gSelfInconclusive
    else:
      var ft = parseJson(fullResp.body)
      if hasError(ft):
        console.err "settings index/full did not parse as strict JSON: " &
                    errorMsg(ft)
        inc gSelfFailures
      elif not jHasArray(root(ft), "mods"):
        console.err "settings index/full: no `mods` ARRAY in the reply (" &
                    fullResp.body & ")"
        inc gSelfFailures
      else:
        var badType = ""
        var badRow = ""
        var notAnArray = ""
        var duplicated = ""
        for topKey, topVal in pairs(root(ft)):
          if topKey != "mods" or kind(topVal) != JArray:
            continue
          for m in items(topVal):
            inc fullModCount
            let guid = jStrField(m, "guid")
            if guid.len == 0:
              badRow = "a mod entry carried no guid"
            elif fullGuids.contains(guid):
              duplicated = guid
            else:
              fullGuids.add guid
            if not jHasArray(m, "settings"):
              # THE NEGATIVE CONTROL. A mod with nothing to declare must carry
              # `[]`; a `null` or an absent field is the failure.
              notAnArray = guid
              continue
            let isClient = jBoolField(m, "client", false)
            for mk, mv in pairs(m):
              if mk != "settings" or kind(mv) != JArray:
                continue
              for row in items(mv):
                inc fullRowCount
                let ty = jStrField(row, "type")
                if not isSettingTypeName(ty):
                  badType = guid & "." & jStrField(row, "key") & " type=\"" &
                            ty & "\""
                if jStrField(row, "key").len == 0:
                  badRow = guid & " has a row with no key"
                # A ROW SAFE TO ROUND-TRIP. Text-shaped (so an arbitrary
                # marker is a legal value), server-side (so the write is
                # applied here and not queued for a game process that is not
                # running), and sitting AT ITS DECLARED DEFAULT right now --
                # which is what makes the reset at the end of the trip restore
                # exactly what was there before. Without that precondition
                # this test would overwrite a value a player chose and put the
                # schema default in its place, on any install it is aimed at.
                if rtKey.len == 0 and ty == "string" and not isClient and
                   jStrField(row, "value") == jStrField(row, "default") and
                   jStrField(row, "default").len > 0:
                  rtGuid = guid
                  rtKey = jStrField(row, "key")
                  rtDefault = jStrField(row, "default")
        if notAnArray.len > 0:
          console.err "settings index/full: `" & notAnArray &
                      "` has no `settings` ARRAY (null or absent); a mod " &
                      "with no settings must carry [], which is what a " &
                      "consumer iterates without a null check"
          inc gSelfFailures
        elif duplicated.len > 0:
          console.err "settings index/full: guid `" & duplicated &
                      "` appears more than once; the guid is the identity " &
                      "and a duplicate draws the same mod twice in the nav"
          inc gSelfFailures
        elif badRow.len > 0:
          console.err "settings index/full: " & badRow
          inc gSelfFailures
        elif badType.len > 0:
          console.err "settings index/full: " & badType &
                      " is not one of the eight declared setting types " &
                      "(bool int float enum string keybind select color)"
          inc gSelfFailures
        elif fullModCount == 0:
          console.warn "settings index/full: INCONCLUSIVE -- the document " &
            "parsed and is well formed but lists ZERO mods, so no row was " &
            "examined. Stage a mod that calls declareSettings."
          inc gSelfInconclusive
        else:
          console.ok "settings index/full is strict JSON: " &
                     $fullModCount & " mod(s), " & $fullRowCount &
                     " row(s), every type in the closed set, every " &
                     "`settings` an array"

    # Every mod the COMPACT index lists must appear in the FULL one exactly
    # once. Checked in that direction because the compact index is what the
    # existing F12 nav is built from: a mod present there and missing here is a
    # page a native tab could never draw.
    if fullModCount > 0:
      let idxResp = request(gPort, "/aowlspt/settings/index", "",
                            "000000000000000000000001")
      var it = parseJson(idxResp.body)
      if not idxResp.ok or hasError(it):
        console.err "settings index: could not be parsed alongside index/full"
        inc gSelfFailures
      elif not jHasArray(root(it), "mods"):
        console.err "settings index: no `mods` array"
        inc gSelfFailures
      else:
        block:
          var missing = ""
          var compactCount = 0
          for topKey, topVal in pairs(root(it)):
            if topKey != "mods" or kind(topVal) != JArray:
              continue
            for m in items(topVal):
              inc compactCount
              let g = jStrField(m, "guid")
              if g.len > 0 and not fullGuids.contains(g):
                missing = g
          if missing.len > 0:
            console.err "settings index/full: `" & missing &
                        "` is in the compact index and MISSING from the full " &
                        "one"
            inc gSelfFailures
          elif compactCount != fullModCount:
            console.err "settings index/full lists " & $fullModCount &
                        " mod(s) but the compact index lists " &
                        $compactCount & "; the two routes disagree about how " &
                        "many mods exist"
            inc gSelfFailures
          else:
            console.ok "every mod in /aowlspt/settings/index appears in " &
                       "/aowlspt/settings/index/full exactly once (" &
                       $compactCount & ")"

    # ---- /aowlspt/keybinds ----
    if fullModCount > 0:
      let kbResp = request(gPort, "/aowlspt/keybinds", "",
                           "000000000000000000000001")
      if not kbResp.ok:
        console.err "keybinds route: " & kbResp.error
        inc gSelfFailures
      else:
        var kt = parseJson(kbResp.body)
        if hasError(kt):
          console.err "keybinds route did not parse as strict JSON: " &
                      errorMsg(kt)
          inc gSelfFailures
        elif not jHasArray(root(kt), "mods"):
          console.err "keybinds route: no `mods` array (" & kbResp.body & ")"
          inc gSelfFailures
        else:
          block:
            var kmods = 0
            var binds = 0
            var emptyLists = 0
            var noAction = ""
            var notAnArray = ""
            var valueFault = ""
            var faultAt = ""
            var unknownKeys = 0
            var clientBinds = 0
            let checkerFault = keybindCheckerProvesItself()
            for topKey, topVal in pairs(root(kt)):
              if topKey != "mods" or kind(topVal) != JArray:
                continue
              for m in items(topVal):
                inc kmods
                let guid = jStrField(m, "guid")
                let isClient = jBoolField(m, "client", false)
                if not jHasArray(m, "keybinds"):
                  notAnArray = guid
                  continue
                for mk, mv in pairs(m):
                  if mk != "keybinds" or kind(mv) != JArray:
                    continue
                  if len(mv) == 0:
                    inc emptyLists
                  for b in items(mv):
                    inc binds
                    if isClient:
                      inc clientBinds
                    if jStrField(b, "action").len == 0:
                      noAction = guid & "." & jStrField(b, "settingKey")
                    # THE BOUND VALUE. Asserted over every entry of every mod,
                    # client-side or not: the native Controls -> MODS page
                    # cannot draw a bind whose value it has no field for, and
                    # a client mod's rows travel a different transport but
                    # carry the same contract.
                    let f = keybindValueFault(b)
                    if f.len > 0 and valueFault.len == 0:
                      valueFault = f
                      faultAt = guid & "." & jStrField(b, "settingKey")
                    if jStrField(b, "error") == "unknown setting key":
                      inc unknownKeys
            if checkerFault.len > 0:
              console.err "keybinds route: THE VALUE CHECK ITSELF IS BROKEN -- " &
                          checkerFault & "; its verdict on the live payload " &
                          "below means nothing"
              inc gSelfFailures
            if valueFault.len > 0:
              console.err "keybinds route: " & faultAt & " " & valueFault
              inc gSelfFailures
            elif notAnArray.len > 0:
              console.err "keybinds route: `" & notAnArray &
                          "` has no `keybinds` ARRAY; a mod with no keys must " &
                          "carry [], not null and not a missing entry"
              inc gSelfFailures
            elif noAction.len > 0:
              console.err "keybinds route: " & noAction &
                          " has an EMPTY action; a keybind row with no action " &
                          "cannot be drawn"
              inc gSelfFailures
            elif kmods != fullModCount:
              console.err "keybinds route lists " & $kmods &
                          " mod(s) but index/full lists " & $fullModCount &
                          "; a mod with no keys must still appear, with []"
              inc gSelfFailures
            else:
              console.ok "keybinds route is strict JSON: " & $kmods &
                         " mod(s), " & $binds & " binding(s) (" & $clientBinds &
                         " on client mods), " & $emptyLists &
                         " mod(s) with an EMPTY list (not null); every one " &
                         "carries `value` and `default`, " & $unknownKeys &
                         " of them null with `unknown setting key`"

    # ---- the round trip: set -> index -> reset -> index ----
    #
    # Through `/set`, whose whole claim is that it answers with the value AS
    # STORED rather than an echo; the value is then re-read from
    # `/aowlspt/settings/index/full`, a DIFFERENT route reading the same store,
    # so a `/set` that merely echoed could not make both agree.
    #
    # The row is chosen, not hardcoded, and only a row already sitting at its
    # declared default qualifies -- see where `rtKey` is picked. That is what
    # makes the reset at the end restore exactly the value that was there
    # before this test ran, on any install this is pointed at.
    if fullModCount > 0 and rtKey.len == 0:
      console.warn "settings /set: INCONCLUSIVE -- no server-side string row " &
        "is currently sitting at its declared default, so there is no row " &
        "this test can write to and put back exactly as it found it. The " &
        "route was NOT examined."
      inc gSelfInconclusive
    elif rtKey.len > 0:
      let marker = "AOWL SELFTEST"
      var seen = false
      let sr = request(gPort, "/aowlspt/settings/" & rtGuid & "/set",
                       "{\"key\":\"" & rtKey & "\",\"value\":\"" & marker & "\"}",
                       "000000000000000000000001")
      var srt = parseJson(sr.body)
      var readback = ""
      if sr.ok and not hasError(srt):
        readback = jStrField(root(srt), "value")
      let afterSet = fullIndexValueOf(gPort, rtGuid, rtKey, seen)
      if not sr.ok:
        console.err "settings /set: POST failed: " & sr.error
        inc gSelfFailures
      elif hasError(srt):
        console.err "settings /set: the reply did not parse as strict JSON"
        inc gSelfFailures
      elif readback != marker:
        console.err "settings /set on " & rtGuid & "." & rtKey &
                    ": the reply's `value` read back \"" & readback &
                    "\", not the value that was written; /set's whole " &
                    "contract is that this field comes from the store"
        inc gSelfFailures
      elif not seen or afterSet != marker:
        console.err "settings /set on " & rtGuid & "." & rtKey &
                    ": the reply claimed the write took, but index/full " &
                    "still reads \"" & afterSet & "\" -- the readback and " &
                    "the index disagree"
        inc gSelfFailures
      else:
        console.ok "settings /set: the write to " & rtGuid & "." & rtKey &
                   " is visible in /aowlspt/settings/index/full (was \"" &
                   rtDefault & "\", now \"" & marker & "\")"
        let rr = request(gPort, "/aowlspt/settings/" & rtGuid & "/reset",
                         "{\"key\":\"" & rtKey & "\"}",
                         "000000000000000000000001")
        let afterReset = fullIndexValueOf(gPort, rtGuid, rtKey, seen)
        if not rr.ok:
          console.err "settings reset: POST failed: " & rr.error
          inc gSelfFailures
        elif afterReset != rtDefault:
          console.err "settings reset on " & rtGuid & "." & rtKey &
                      ": index/full reads \"" & afterReset &
                      "\", wanted the declared default \"" & rtDefault &
                      "\" (it was \"" & marker & "\" immediately before)"
          inc gSelfFailures
        else:
          console.ok "settings reset: index/full shows the declared default " &
                     "again (confirmed it read \"" & marker & "\" first)"

    # And a malformed session id must be refused before any route sees it.
    let badSession = request(gPort, "/aowlspt/status", "", "not-a-mongo-id")
    if badSession.ok and badSession.contains("bad session id"):
      console.ok "a malformed session id is refused"
    else:
      console.err "a malformed session id was not refused"
      inc gSelfFailures

    cNetStop()
    unloadMods()
    console.heading "Result"
    # Three outcomes, never two. An INCONCLUSIVE run examined less than it
    # meant to, so it does not get to say "served every route": that sentence
    # was the whole reason a mods-less selftest read as a clean bill of health
    # right up to the point it aborted.
    if gSelfInconclusive > 0:
      console.warn $gSelfInconclusive &
        " check(s) INCONCLUSIVE -- not examined, so not passed"
    if gSelfFailures > 0:
      console.err $gSelfFailures & " failed"
      return 1
    if gSelfInconclusive > 0:
      console.warn "no check FAILED, but " & $gSelfInconclusive &
        " could not be looked at; this is not a pass"
      return 0
    console.ok "the backend served every route over the wire"
    return 0

  # `--perf` writes its breakdown to a file rather than only to stdout,
  # because a load generator kills this process rather than asking it to stop
  # -- a report printed at exit is a report nobody ever sees.
  proc perfDump() =
    if not perfOn():
      return
    var text = "aowlspt-backend per-phase timings\n\n"
    let rows = perfReport(gRequests())
    for l in rows:
      text.add l
      text.add "\n"
    text.add perfCacheLine(gZHits, gZMisses, gZSkipped)
    text.add "\n"
    discard writeTextFile(joinPath(gRoot, "perf.txt"), text)

  var lastPerf = elapsedMs()
  var lastTick = elapsedMs()
  while cNetRunning() != 0'i32:
    cSysSleep(50'i32)
    let now = elapsedMs()
    tickMods(now - lastTick)
    runTimers()
    # Off the accept path, by construction: this is the serve loop's own
    # thread, and the accept workers are elsewhere. One route per tick.
    warmStep()
    warmSweep()
    # Live mod control, off the emitting stack. This is the only place a mod is
    # loaded or unloaded while the server is running.
    modcontrol.drain()
    lastTick = now
    if perfOn() and now - lastPerf >= 1000'i64:
      perfDump()
      lastPerf = now
    if once and gRequests() > 0:
      # One request then stop: how the test harness drives it.
      cSysSleep(200'i32)
      break

  cNetStop()
  unloadMods()
  # The store keeps a handle open per file it has touched. Nothing breaks if
  # they are left to the process teardown, but a server that has stopped should
  # not still be holding a player's profile open.
  storeClose()
  storeUnlock()
  # An orderly exit: leave a clear breadcrumb and drop the crash marker, so the
  # only thing that ever leaves a `.fatal` file behind is a genuine fault. A
  # reader (or the launcher watchdog) can then tell "it crashed" from "it was
  # stopped/killed" without guessing.
  cCrashClearMarker()
  modhost.okLog "backend exiting cleanly after " & $gRequests() & " requests"
  console.line ""
  console.line "  stopped after " & $gRequests() & " requests"
  perfDump()
  let finalRows = perfReport(gRequests())
  for l in finalRows:
    console.line l
  result = 0

quit(main())
