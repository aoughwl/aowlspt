/* aowlspt_net.h — sockets and zlib for the backend server.
 *
 * nimony's `nativesocket` is a 26-line stub and `winlean` has no socket
 * surface at all, so the syscalls live here, like every other place this repo
 * has to reach something nimony cannot. Everything above the byte framing —
 * parsing, routing, the database, the mod API, and every byte that goes back
 * on the wire — is nimony.
 *
 * The zlib part is not optional decoration. Tarkov's client sends and expects
 * **zlib-framed bodies**: a request body arrives deflated and a response must
 * be deflated too. A server that answers in plain JSON gets a client that
 * silently fails to parse it, and `curl` against such a server appears to work
 * while the game does not — which is exactly the trap `tools/aowlprobe.nim`
 * exists to document, and why it frames its own bodies rather than shelling out
 * to `curl`. (This named `tools/SptProbe`, which has never existed in this
 * repo; the C# tool in `tools/SptReflect` is a metadata dumper and speaks no
 * protocol at all.)
 *
 * ------------------------------------------------------------------------
 * Why this is a poller and a request pool rather than a pool of accept
 * threads
 * ------------------------------------------------------------------------
 *
 * It used to be a fixed pool of threads that each called `accept` on the
 * shared listening socket and then stayed with the accepted connection until
 * the client let go of it. That is the simplest thing that works, and it has
 * one property that cannot be fixed by tuning it: **the pool size is the
 * connection limit**. Keep-alive means a connection lives for a session, so a
 * client that opens sixteen sockets and says nothing on any of them owns the
 * server. `fuzzwire` demonstrated it with twelve: every other client waited
 * ten seconds. Bounded receive deadlines cut that to five and raising the pool
 * from eight to sixteen doubled the number of sockets it took, but both are
 * the same trade — a bigger number for a bounded attacker, and the attacker
 * picks the number.
 *
 * What removes it rather than raising it is decoupling *having a connection*
 * from *having a thread*:
 *
 *   * One **poller** thread owns the listening socket and every connection
 *     that is not currently being served. It waits in `WSAPoll`, accepts, and
 *     reads whatever has arrived into that connection's buffer. It never runs
 *     a route and never blocks on one socket.
 *   * A connection becomes interesting only when a **complete request** is
 *     buffered — headers and the whole declared body. Then it is pushed onto a
 *     ready queue and one of the **request workers** picks it up, calls into
 *     nimony to answer it, and gives the connection back to the poller.
 *
 * So a connection that stalls, dribbles, or opens and says nothing never
 * reaches a worker at all. It costs one socket, one `AowlConn` (about a
 * hundred bytes; it was 80 before the websocket fields went in, and that is a
 * hand count off the struct rather than a `sizeof` anybody has printed) and
 * whatever it has actually managed to send — nothing is allocated
 * for a body it merely *claims* it will send. The limit is
 * `AOWL_NET_MAX_CONNS` sockets and `AOWL_NET_MAX_BUFFERED` bytes of buffered
 * request, not a thread count.
 *
 * ------------------------------------------------------------------------
 * WSAPoll, not IOCP — and what that costs
 * ------------------------------------------------------------------------
 *
 * IOCP is the other way to write this and is the better one for a server with
 * thousands of concurrent sockets spread over many cores. This is not that
 * server. It listens on loopback, for one game, and the realistic connection
 * count is single digits with a hostile one in the low hundreds.
 *
 * What IOCP would cost here:
 *
 *   * Every read becomes a posted `WSARecv` with an `OVERLAPPED` and a
 *     completion picked up somewhere else, which means the "have I got a whole
 *     request yet" state machine stops being a loop you can read top to bottom
 *     and becomes a set of callbacks with a lifetime problem attached to each
 *     buffer. The bug class that follows — a completion arriving for a
 *     connection that has just been closed — is exactly the kind this file
 *     must not have, because a crash here is the whole game server.
 *   * Cancellation and shutdown get harder: `CancelIoEx` plus draining the
 *     port, rather than "close the listening socket and set a flag".
 *
 * What WSAPoll costs, honestly:
 *
 *   * The poll set is rebuilt and scanned linearly every wakeup, so the poller
 *     is O(connections) per tick. At `AOWL_NET_MAX_CONNS` = 1024 that is a
 *     1024-entry array scan on a thread that is otherwise asleep; it is
 *     nothing next to inflating a request.
 *   * There is one poller, so reads are serialised. Reads are a `memcpy` out
 *     of the kernel; the work that is not — inflate, route, deflate — is on
 *     the worker pool, which is where the parallelism was already.
 *   * `WSAPoll` has a documented wart: it never reports `POLLOUT` for a socket
 *     with a connection in progress. Nothing here polls for writability on a
 *     connecting socket — the only `POLLWRNORM` wait is in
 *     `aowl_net_send_within`, reached from `aowl_net_send` and from
 *     `aowl_ws_send`, and in both cases on an already-established connection
 *     — so it does not bite.
 *
 * ------------------------------------------------------------------------
 * Why the byte framing is in C when everything else is nimony
 * ------------------------------------------------------------------------
 *
 * The poller has to answer one question to do its job: *how many bytes are one
 * request*. That is the read path, which is what this file is for, and doing
 * it here keeps the buffer and the loop that fills it in one place.
 *
 * It is deliberately the **only** HTTP knowledge in this file, and it is
 * advisory. `aowlspt_nim_handle` re-parses the same bytes and is the authority
 * on what the answer is; every case where the two could disagree — a second,
 * disagreeing `Content-Length`, a header block that never terminates, a
 * declared body over the limit — is a case nimony answers and **closes the
 * connection on**. So a framing disagreement can never desynchronise a
 * kept-alive stream: there is no next request to get wrong. No status line,
 * header or body is written from C.
 *
 * ------------------------------------------------------------------------
 * The websocket, and why the split falls where it does
 * ------------------------------------------------------------------------
 *
 * The game opens `/client/notifier/getwebsocket/<session>` and expects a
 * websocket it can be *pushed* to: new mail, an insurance return, a flea offer
 * sold. That used to be impossible here for a structural reason rather than a
 * protocol one — a held connection took one of a fixed pool of accept threads,
 * so four players idling in the menu owned the server — and the poller removed
 * exactly that. A connection nobody is answering now costs a socket and its
 * buffer. So a held websocket is a thing this shape can afford, and
 * `mods/tarkov` no longer has to fake it with a poll *for a client that
 * upgrades*. The poll route is still registered and still the fallback: a
 * client that has not upgraded, has not finished logging in, or has just lost
 * its connection gets `ErrNotFound` from `notifyPush` and is drained through
 * `/client/notifier/getwebsocket` instead. See `mods/tarkov/emu/notify.nim`,
 * which tries the socket first and falls back on purpose.
 *
 * **The trap is the completeness rule above.** A connection reaches a worker
 * when a *complete request* is buffered, and a websocket is precisely the
 * connection on which that never happens again: after the handshake the bytes
 * on the wire are frames, not requests, and `aowl_conn_complete` would sit at
 * false forever while the header scan ran to `AOWL_HEAD_CAP` and the body
 * deadline expired underneath it. Getting that wrong does not fail loudly — it
 * rebuilds the starvation this file was rewritten to remove, one socket at a
 * time. So a websocket connection is taken *out* of the request state machine
 * at the moment it is adopted (`c->ws`), is never pushed onto the ready queue
 * again, never consults `aowl_conn_complete`, and gets a deadline that treats
 * silence as health rather than as a stall.
 *
 * What is in C, and what is not:
 *
 *   * **Frame boundaries are here**, for the same reason request boundaries
 *     are: the poller has to answer "how many bytes are one frame" to know
 *     whether it has one, and the buffer and the loop that fills it are here.
 *     With it come the read-path refusals, because each of them is a decision
 *     about whether to *keep reading* — a payload length over
 *     `AOWL_WS_MAX_FRAME` is refused off the length field, before a byte is
 *     reserved for it, and an unmasked client frame is refused outright: RFC
 *     6455 requires a client to mask, and a server that tolerates its absence
 *     is a server that has stopped checking.
 *   * **The handshake is not here.** It is `Sec-WebSocket-Key` + the
 *     well-known GUID + SHA-1 + base64, and nimony ships both `std/sha1` and
 *     `std/base64`; writing them again in C would be a second implementation
 *     of two solved things in the language this repo uses least.
 *   * **No frame is composed here either**, which is the same rule the rest of
 *     this file already keeps: every byte the server puts on a socket is
 *     written by nimony. The poller detects a ping, a close or a violation and
 *     calls `aowlspt_nim_ws_control`; nimony builds the pong, the close or the
 *     refusal and hands it back to `aowl_ws_send`, which owns only the lock and
 *     the socket.
 *
 * `aowl_ws_send` exists because a push comes from a worker (a mod answering a
 * request) or a timer, while the reads come from the poller, and two threads
 * writing frames onto one socket interleave into a stream neither side can
 * parse. One critical section covers every websocket write and the close of a
 * websocket connection, so a socket is never closed out from under a send in
 * flight.
 *
 * **The poller does not wait on it, on any path.** Not on the close, where it
 * has always used `TryEnterCriticalSection` and deferred to its next wakeup,
 * and not on the write, where it used to. That is a rule about which thread is
 * asking rather than about which call it makes, so it is enforced where the
 * thread is known — `aowl_ws_send` compares the calling thread against the
 * poller's — and not at the call sites, which are several frames inside nimony
 * composing a pong. A worker still waits, up to `AOWL_WS_SEND_MS` per stall, because a
 * worker is a thread whose job is to wait for one client.
 *
 * What that rule is worth is visible in what it forbids. This lock is one lock
 * for every websocket, and a worker holds it across a `send` to a peer that
 * may not be reading — so a blocking poller was one non-reading notifier
 * client away from stopping the *server*: no accepts, no reads on any
 * connection, no deadlines, until that push gave up. And it does not give up
 * at `AOWL_WS_SEND_MS`: that deadline restarts on every byte the peer accepts,
 * so a client dribbling one byte at a time holds it open indefinitely. A held
 * connection stalling the whole server is precisely the failure the poller was
 * written to remove, rebuilt one lock lower down.
 *
 * A frame the poller cannot write immediately is queued on the connection
 * (`AOWL_WS_PEND_CAP`) and goes out at the next wakeup, `AOWL_WS_RETRY_MS`
 * later; a close it cannot make is retried on the same clock. Nothing is
 * dropped for being unlucky with a lock.
 */

#ifndef AOWLSPT_NET_H
#define AOWLSPT_NET_H

/* `WSAPoll` is Vista and later. ucrt64's headers already target higher than
 * this; the guard is here so a translation unit that pins an older target
 * still compiles rather than failing on an undeclared function. */
#if !defined(_WIN32_WINNT) || (_WIN32_WINNT < 0x0600)
#  undef _WIN32_WINNT
#  define _WIN32_WINNT 0x0600
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

/* The host lock used to be defined here, which meant anything wanting a
 * critical section also linked winsock and zlib -- see `aowlspt_lock.h` for
 * why that was wrong for the injected client host. It is included rather than
 * merely referenced so that every file that already included this header keeps
 * getting `aowl_lock`/`aowl_unlock` unchanged. */
#include "aowlspt_lock.h"

/* The TLS transport shim. When the server is started in `--tls` mode every
 * accepted connection carries an `SSL` handle and the `recv`/`send` calls below
 * become `SSL_read`/`SSL_write`; in the default plain-HTTP mode nothing here
 * touches OpenSSL. See `aowlspt_tls.h` for how want-read/want-write fold into
 * this file's existing `WSAEWOULDBLOCK` handling. */
#include "aowlspt_tls.h"

/* ------------------------------------------------------------------ *
 * What nimony provides
 * ------------------------------------------------------------------ *
 *
 * `aowlspt_nim_handle` is handed one complete request out of a connection's
 * buffer and returns 1 if the connection may be kept alive, 0 if it must be
 * closed. `headEnd` is the offset of the header terminator and `sep` its
 * length (4 for CRLFCRLF, 2 for LFLF); `headEnd < 0` means no terminator was
 * found within `AOWL_HEAD_CAP`, which nimony answers `431`.
 *
 * `aowlspt_nim_timeout` writes the `408` for a request that stopped arriving.
 * It is a call rather than a `send` from here so that every byte this server
 * puts on the wire is still written by nimony. `phase` is 0 for the headers
 * and 1 for the body.
 */
extern int32_t aowlspt_nim_handle(uint64_t sock, void* buf, int32_t len,
                                  int32_t headEnd, int32_t sep);
extern void aowlspt_nim_timeout(uint64_t sock, int32_t phase,
                                int32_t have, int32_t declared);

/* The websocket half. See the head of this file for why the handshake and
 * every composed byte are on the nimony side of these four calls and only the
 * frame boundaries are on this one.
 *
 * `aowlspt_nim_handle` grew a third return value for it: **2 means "I answered
 * this request with a 101 and this connection is now a websocket"**. 1 and 0
 * still mean keep-alive and close, so nothing that does not upgrade changes.
 *
 * `aowlspt_nim_ws_message` is handed one whole message — reassembled across
 * continuation frames here — and returns 1 to keep the connection or 0 to
 * close it. The game's notifier never sends one; it exists because a protocol
 * half-implemented is a protocol that fails on the first client that uses the
 * other half.
 *
 * `aowlspt_nim_ws_control` is a ping to echo (kind 0), the peer's close
 * (kind 1), or a violation this file refuses (kind 2, `code` being the close
 * status: 1002 protocol error, 1009 too large). Every one of them puts bytes
 * on the wire and none of those bytes is composed here.
 *
 * `aowlspt_nim_ws_idle` fires when a websocket has said nothing for
 * `AOWL_WS_IDLE_MS`. `pinged` says whether the last idle already sent a ping
 * that went unanswered — which is how a client that vanished without closing
 * is told apart from one that is simply idle, since a half-open TCP connection
 * looks exactly like a quiet one until something is written to it. Returns 1
 * to keep, 0 to close.
 *
 * `aowlspt_nim_ws_gone` is the connection being dropped, so nimony can forget
 * the session that was on it. It is called after the socket is closed and
 * outside the websocket write lock, so the lock order is only ever
 * nimony-then-C and never the reverse. */
extern int32_t aowlspt_nim_ws_message(int64_t ticket, int32_t opcode,
                                      void* p, int32_t len);
extern void aowlspt_nim_ws_control(int64_t ticket, int32_t kind, int32_t code,
                                   void* p, int32_t len);
extern int32_t aowlspt_nim_ws_idle(int64_t ticket, int32_t pinged);
extern void aowlspt_nim_ws_gone(int64_t ticket);

static int32_t aowl_net_startup(void) {
    WSADATA wsa;
    return WSAStartup(MAKEWORD(2, 2), &wsa) == 0 ? 1 : 0;
}

static int32_t aowl_net_last_error(void) {
    return (int32_t)WSAGetLastError();
}

/* 1 once the server has been started in `--tls` mode. Read on every read and
 * every send so that the plain-HTTP path pays a single predictable branch and
 * is otherwise byte-for-byte what it was; the test suites run against that path
 * and must stay unchanged. */
static int g_tlsMode = 0;

/* The `SSL` handle for a socket, or NULL. `aowl_net_send_within` and
 * `aowl_ws_write_nowait` are handed only a socket (the response path comes down
 * from nimony with no connection in hand), so they look the handle up here. It
 * is a scan of the connection table, but only ever taken in `--tls` mode, on a
 * loopback server whose realistic connection count is single digits; the
 * websocket send path already scans the same table for the same reason. Defined
 * after the table below; forward-declared here because the send helpers precede
 * it. */
static void* aowl_ssl_for_sock(SOCKET s);

/* Binds to loopback only.
 *
 * That is a deliberate default rather than a placeholder: this backend serves
 * a single-player game on the machine it runs on, and a game server that
 * listens on every interface by accident is how a LAN party becomes an
 * incident. Nothing here takes an address argument, so there is no flag to get
 * wrong. */
static uint64_t aowl_net_bind(int32_t port) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return 0;

    /* `SO_EXCLUSIVEADDRUSE`, and emphatically not `SO_REUSEADDR`.
     *
     * This was `SO_REUSEADDR`, with a comment saying it was there so a restart
     * inside the TIME_WAIT window could rebind -- which is the Berkeley
     * reading of the option and is not what Windows does with it. On Windows
     * `SO_REUSEADDR` means *this socket may take a port another process is
     * already listening on*. The bind succeeds, the second server reports
     * itself up, and the connections keep going to the first one.
     *
     * That is not a theoretical reading. Two backends started on port 6998,
     * and the second wrote `ok listening on 127.0.0.1:6998` into its log and
     * then failed its own self test with `no route` for every route it had
     * just registered -- because its requests were being answered by the other
     * process. Every tool in `tools/` that waits for the string `listening` in
     * the log to decide the server is up believed it, and `aowlspt-verify`
     * then spent twenty seconds not connecting and told a player their install
     * was broken. One socket option, and a diagnostic that accuses the
     * innocent.
     *
     * `SO_EXCLUSIVEADDRUSE` is the option that means what the old comment
     * thought `SO_REUSEADDR` meant: nobody may take this port from us, and we
     * may not take it from anybody. A collision now fails the bind with
     * `WSAEADDRINUSE`, which is a condition the caller already handles and can
     * name.
     *
     * The TIME_WAIT worry the old comment had does not apply to what this
     * socket is. TIME_WAIT is a property of a connection's four-tuple, not of
     * a listening port, and the accepted sockets that enter it are closed by
     * `aowl_conn_drop` rather than left to the process exiting. Restarting the
     * server on the same port immediately is what every gate in this repo does
     * dozens of times a run, and it is checked rather than assumed. */
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char*)&yes,
               sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    /* The error is read *before* the socket is closed and put back after.
     *
     * `closesocket` succeeds, and a winsock call that succeeds sets the last
     * error to zero -- so the caller asking `WSAGetLastError` after this
     * function has cleaned up got `0`, and reported "could not listen on port
     * 6998 (error 0)". A refusal that cannot say why is only half a diagnostic,
     * and this one is the half that names a port collision. */
    if (bind(s, (struct sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
        int err = WSAGetLastError();
        closesocket(s);
        WSASetLastError(err);
        return 0;
    }
    return (uint64_t)s;
}

/* `listen` is split off from the bind for one reason: *when* each of them is
 * allowed to happen.
 *
 * The bind is the collision test -- with `SO_EXCLUSIVEADDRUSE` above, a port
 * somebody else holds fails here with `WSAEADDRINUSE` -- and the backend wants
 * that answer before it registers a route or loads a mod, so that a failure to
 * start reads as a failure to start rather than as 150 lines of successful mod
 * output with an error under them.
 *
 * The `listen` must **not** move that early. A listening socket completes a
 * client's `connect` from the kernel backlog whether or not anything ever
 * calls `accept`, and `aowllaunch` (and `soak`, and `aowlspt-verify`) treat a
 * successful connect as "the backend is up". Listening before the mods are
 * loaded would make every one of those tools believe a server that cannot yet
 * answer them. So the port is *reserved* early and *served* at the same moment
 * it always was. */
static int32_t aowl_net_listen_on(uint64_t sock, int32_t backlog) {
    if (listen((SOCKET)sock, backlog) == SOCKET_ERROR) {
        int err = WSAGetLastError();
        WSASetLastError(err);
        return 0;
    }
    return 1;
}

static uint64_t aowl_net_listen(int32_t port, int32_t backlog) {
    uint64_t s = aowl_net_bind(port);
    if (!s) return 0;
    if (!aowl_net_listen_on(s, backlog)) {
        int err = WSAGetLastError();
        closesocket((SOCKET)s);
        WSASetLastError(err);
        return 0;
    }
    return s;
}

static uint64_t aowl_net_accept(uint64_t server) {
    SOCKET c = accept((SOCKET)server, NULL, NULL);
    return c == INVALID_SOCKET ? 0 : (uint64_t)c;
}

static int32_t aowl_net_recv(uint64_t sock, void* buf, int32_t len) {
    return (int32_t)recv((SOCKET)sock, (char*)buf, len, 0);
}

/* How long `aowl_net_send` will wait for a peer that has stopped reading.
 *
 * Server sockets are non-blocking now, so a `send` that fills the kernel
 * buffer returns `WSAEWOULDBLOCK` rather than parking the thread. Waiting for
 * writability with a deadline is what makes "a client that asks for the item
 * table and then stops reading it" cost one worker for thirty seconds
 * instead of forever. It is generous on purpose: this is loopback, and the
 * only way a healthy client reaches it is by being suspended in a debugger. */
#define AOWL_SEND_DEADLINE_MS 30000

static int32_t aowl_net_send_within(uint64_t sock, const void* buf, int32_t len,
                                    int32_t withinMs) {
    /* `send` may take fewer bytes than offered; looping here means callers do
     * not each have to remember that. */
    const char* p = (const char*)buf;
    int32_t sent = 0;
    ULONGLONG deadline = 0;
    void* ssl = aowl_ssl_for_sock((SOCKET)sock);
    while (sent < len) {
        /* `aowl_tls_write_once` returns the same shape as `send` -- >0 taken,
         * a would-block mapped to `WSAEWOULDBLOCK`, a fatal to a non-block
         * error -- so the wait-for-writable loop below is reused unchanged. */
        int n = ssl ? aowl_tls_write_once(ssl, p + sent, len - sent)
                    : send((SOCKET)sock, p + sent, len - sent, 0);
        if (n > 0) {
            sent += n;
            deadline = 0;
            continue;
        }
        if (n == 0) return -1;
        if (WSAGetLastError() != WSAEWOULDBLOCK) return -1;
        /* The socket is non-blocking and full. Wait for room, not forever.
         * `wire.nim`'s client sockets are blocking and never land here. */
        if (deadline == 0) deadline = GetTickCount64() + (ULONGLONG)withinMs;
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) return -1;
        int wait = (int)(deadline - now);
        if (wait > 500) wait = 500;
        WSAPOLLFD pfd;
        pfd.fd = (SOCKET)sock;
        pfd.events = POLLWRNORM;
        pfd.revents = 0;
        int r = WSAPoll(&pfd, 1, wait);
        if (r < 0) return -1;
        if (r > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) return -1;
    }
    return sent;
}

/* The response path, unchanged: `AOWL_SEND_DEADLINE_MS` is generous because
 * the only way a healthy client on loopback reaches it is by being suspended
 * in a debugger. The websocket path wants a much shorter one and passes its
 * own -- see `AOWL_WS_SEND_MS`. */
static int32_t aowl_net_send(uint64_t sock, const void* buf, int32_t len) {
    return aowl_net_send_within(sock, buf, len, AOWL_SEND_DEADLINE_MS);
}

static void aowl_net_close(uint64_t sock) {
    if (sock) closesocket((SOCKET)sock);
}

static void aowl_net_shutdown_recv(uint64_t sock) {
    if (sock) shutdown((SOCKET)sock, SD_RECEIVE);
}

/* `aowl_net_set_timeout` was here, and is gone. It set `SO_RCVTIMEO` for
 * `wire.nim` and the probe tools; `wire.nim` sets that option itself, inline
 * in its own `{.emit.}` block, the probe tools import only the zlib entry
 * points, and the server's own sockets are non-blocking and get their
 * deadlines from the poller. It had no caller in this repo and no reason to
 * gain one -- a client that wants a receive timeout is one `setsockopt` away
 * from it and does not need a wrapper in the server's header to find it.
 * `aowl_net_recv` above is *not* in the same position: `wire.nim` uses it. */

/* ------------------------------------------------------------------ *
 * Per-session serialisation
 * ------------------------------------------------------------------ *
 *
 * Profile handling is a read-modify-write of a whole document, and until this
 * existed two concurrent requests carrying the same session id could both read
 * it, both write it, and one of them silently lose. Six concurrent purchases
 * were answered `err:0` and three rifles arrived. The emulator narrowed the
 * window with a per-profile counter and said in `mods/tarkov/emu/profile.nim`
 * that narrowing is not closing and that the fix belongs in the host. This is
 * the host.
 *
 * The rules this has to obey, and how it obeys them:
 *
 *   * **The whole read-modify-write.** The lock is taken around the route
 *     callback in `aowlbackend.nim`, not around the store call, because the
 *     read and the write are at either end of the handler.
 *   * **Unrelated sessions must not contend.** One lock per session, matched
 *     exactly on the 24-character id, in a table that is only ever added to.
 *     A single-player server has a handful of sessions for the life of the
 *     process, so the table never turns over and an entry costs 80 bytes -- a
 *     lock, two counters and the 64-byte id -- for 10 KB of table. Only when
 *     128 *distinct* sessions have been seen does it degrade
 *     to sharing a slot by hash — still correct, and a case this server does
 *     not have.
 *   * **No session, no contention.** `len == 0` returns -1 without touching
 *     anything, so the status routes and the mod-manager routes never queue.
 *   * **Per session, not per connection.** The lock is taken and released
 *     inside one request. Keep-alive holds nothing: a connection waiting for
 *     its next request holds no lock, which is the whole point of not being
 *     back in a thread-per-connection server.
 *
 * A handler that never returns holds its session's lock for as long as it
 * runs, and there is no way around that: releasing a lock under a handler that
 * is still writing is the lost update this exists to prevent. What is bounded
 * is the blast radius. Other sessions and every session-less route carry on,
 * and a request that cannot get the lock within `AOWL_SESSION_WAIT_MS` gives
 * up and is answered `503` rather than pinning a worker for the life of the
 * process. Ten seconds is far past any handler on loopback; reaching it means
 * a mod is wedged, and a wedged mod should say so rather than take the pool
 * down with it.
 */

#define AOWL_SESSION_SLOTS 128
#define AOWL_SESSION_ID_MAX 64
#define AOWL_SESSION_WAIT_MS 10000
#define AOWL_SESSION_SPINS 256

typedef struct {
    SRWLOCK gate;
    int used;
    int32_t idLen;
    char id[AOWL_SESSION_ID_MAX];
} AowlSessionSlot;

/* Zero-initialised: `SRWLOCK_INIT` is all zero bits, so there is no init call
 * to forget and no order to get wrong. */
static AowlSessionSlot g_sessionSlots[AOWL_SESSION_SLOTS];
static SRWLOCK g_sessionTableLock;

static uint32_t aowl_session_hash(const char* p, int32_t len) {
    uint32_t h = 2166136261u;
    for (int32_t i = 0; i < len; i++) {
        h ^= (uint8_t)p[i];
        h *= 16777619u;
    }
    return h;
}

/* Finds or creates the slot for this id. Returns its index, or an index
 * chosen by hash alone if the table has filled.
 *
 * The lookup takes the table lock *shared*, because after the first request of
 * a session the answer is always "already there" and readers do not need to
 * exclude each other. Only an insert takes it exclusive. */
static int32_t aowl_session_slot(const char* id, int32_t len) {
    uint32_t h = aowl_session_hash(id, len);
    int32_t start = (int32_t)(h % AOWL_SESSION_SLOTS);
    int32_t found = -1;
    AcquireSRWLockShared(&g_sessionTableLock);
    for (int32_t i = 0; i < AOWL_SESSION_SLOTS; i++) {
        int32_t k = (start + i) % AOWL_SESSION_SLOTS;
        AowlSessionSlot* s = &g_sessionSlots[k];
        if (!s->used) break;
        if (s->idLen == len && memcmp(s->id, id, (size_t)len) == 0) {
            found = k;
            break;
        }
    }
    ReleaseSRWLockShared(&g_sessionTableLock);
    if (found >= 0) return found;

    AcquireSRWLockExclusive(&g_sessionTableLock);
    for (int32_t i = 0; i < AOWL_SESSION_SLOTS; i++) {
        int32_t k = (start + i) % AOWL_SESSION_SLOTS;
        AowlSessionSlot* s = &g_sessionSlots[k];
        if (!s->used) {
            s->used = 1;
            s->idLen = len;
            memcpy(s->id, id, (size_t)len);
            found = k;
            break;
        }
        if (s->idLen == len && memcmp(s->id, id, (size_t)len) == 0) {
            found = k;
            break;
        }
    }
    ReleaseSRWLockExclusive(&g_sessionTableLock);
    return found >= 0 ? found : start;
}

/* Returns the slot held, -1 for "no session, nothing taken", or -2 for
 * "gave up waiting". Only a return of >= 0 must be released.
 *
 * `TryAcquireSRWLockExclusive` first, and in the single-player case that is
 * the whole function: one interlocked compare-and-swap on the way in and one
 * on the way out. The first version of this held a `SRWLOCK` plus a
 * `CONDITION_VARIABLE` per slot and woke the variable on every release, and
 * even completely uncontended it cost around seventy microseconds a request --
 * fifteen percent of the whole server, for a wait that never happens. A lock
 * that is taken on every request and contended on almost none has to be free
 * when it is uncontended, and only then correct when it is not.
 *
 * When it is contended, the wait is a yield loop rather than a sleep. The
 * thing being waited for is another request on the same profile, which is
 * under a millisecond; `Sleep(1)` on Windows is fifteen, and would turn a
 * 0.5 ms wait into a 15 ms one. So: spin yielding for `AOWL_SESSION_SPINS`
 * turns, and only then fall back to sleeping, up to `AOWL_SESSION_WAIT_MS`. */
static int32_t aowl_session_lock(const void* idp, int32_t len) {
    if (idp == NULL || len <= 0) return -1;
    if (len > AOWL_SESSION_ID_MAX) len = AOWL_SESSION_ID_MAX;
    int32_t k = aowl_session_slot((const char*)idp, len);
    AowlSessionSlot* s = &g_sessionSlots[k];
    if (TryAcquireSRWLockExclusive(&s->gate)) return k;
    for (int32_t i = 0; i < AOWL_SESSION_SPINS; i++) {
        SwitchToThread();
        if (TryAcquireSRWLockExclusive(&s->gate)) return k;
    }
    ULONGLONG deadline = GetTickCount64() + AOWL_SESSION_WAIT_MS;
    for (;;) {
        Sleep(1);
        if (TryAcquireSRWLockExclusive(&s->gate)) return k;
        if (GetTickCount64() >= deadline) return -2;
    }
}

static void aowl_session_unlock(int32_t slot) {
    if (slot < 0 || slot >= AOWL_SESSION_SLOTS) return;
    ReleaseSRWLockExclusive(&g_sessionSlots[slot].gate);
}

/* ------------------------------------------------------------------ *
 * The poller and the request pool
 * ------------------------------------------------------------------ */

#define AOWL_NET_WORKERS 16
    /* Request workers. This is the concurrency limit on *answering*, which is
     * what a thread is actually needed for. It is no longer the connection
     * limit, so it no longer decides how many stalled sockets it takes to
     * starve the server -- nothing does. */

#define AOWL_NET_MAX_CONNS 1024
    /* Connections held open at once. This is the number the old pool size used
     * to be, three orders of magnitude larger, and it is a bound on memory
     * rather than on threads: an idle connection is a socket and an `AowlConn`,
     * and it does not own a thread, a stack or a receive buffer until it sends
     * something. Past this the poller accepts and immediately closes, so the
     * listen backlog does not fill and the refusal is instant. */

#define AOWL_HEAD_CAP 65536
    /* Header bytes accepted before the request is refused `431`. Same number
     * the nimony loop used for its whole receive buffer. */

#define AOWL_BODY_CAP (16 * 1024 * 1024)
    /* Must match `MaxBodyBytes` in `aowlbackend.nim`. A declared length over
     * this is never waited for and never allocated: the request is handed
     * straight to nimony, which answers `413` and closes. */

#define AOWL_NET_MAX_BUFFERED (64 * 1024 * 1024)
    /* Request bytes buffered across every connection at once. Without it the
     * per-connection limit multiplies by the connection limit and the answer
     * is sixteen gigabytes. This is the number that makes "bounded by memory"
     * a bound rather than a phrase: a connection that would push the total
     * over it is closed. Sixteen megabytes is already far above the largest
     * request the game makes, so four of the largest imaginable in flight at
     * once is headroom nothing legitimate reaches. */

#define AOWL_CONN_CHUNK 8192
    /* First allocation for a connection that has sent something, doubling
     * from there. Allocated on the first byte received, not on accept, so a
     * socket that opens and says nothing owns no buffer at all. */

#define AOWL_KEEPALIVE_MAX 512
    /* Requests on one connection before it is closed anyway. It lived in
     * `aowlbackend.nim` when the connection loop did; it is applied here now,
     * after the response has gone out, so the bytes on the wire are unchanged
     * -- and request 512 is answered `Connection: close`, because that is
     * what then happens to the socket. See `aowl_final_req`. */

#define AOWL_IDLE_MS 5000
#define AOWL_HEAD_MS 3000
#define AOWL_BODY_MS 5000
    /* The same three deadlines the nimony loop had, for the same reasons: idle
     * between requests on a kept-alive connection is a healthy state and is
     * allowed to sit, idle in the middle of a request is a stall, and a body
     * gets longer than a header because it can be megabytes. They are enforced
     * by the poller's timeout now instead of by a 500 ms receive slice and a
     * clock check, which is the same behaviour for a tenth of the syscalls:
     * a stalled connection used to wake its thread twice a second and now
     * wakes nobody. */

#define AOWL_HOT_GRACE_MS 10
    /* After a worker answers a request it does not immediately hand the
     * connection back. It waits this long for the next one, and while it is
     * waiting the connection is *hot*: the socket is put back into blocking
     * mode with `SO_RCVTIMEO` set to this, and the worker sits in a plain
     * `recv` -- which is exactly, syscall for syscall, what the old
     * thread-per-connection loop did.
     *
     * That last part is not a detail, it is the measurement. The first version
     * of this left the socket non-blocking and waited in `WSAPoll`, which is a
     * `recv` that returns `WSAEWOULDBLOCK`, a `WSAPoll`, and a second `recv`
     * where there used to be one call. It cost a flat 65 microseconds a
     * request -- visible on every endpoint, from the 1.4 MiB item table down
     * to the empty-bodied keepalive -- and took 1450 requests a second to
     * 1290. Waiting the way the old code waited gets it back.
     *
     * A client in the middle of a session has its next request on the wire
     * within microseconds of reading the answer, so this window almost always
     * ends with work rather than with a wait, and the hot path is one thread
     * from `accept` to the last response. When it does end with a wait, or
     * with half a request, the connection goes back to the poller and costs
     * nothing until it says something.
     *
     * And it cannot be turned into a lever, for two reasons. A connection only
     * earns a window by having just sent a *complete* request, so ten
     * milliseconds of a worker per complete request served is not asymmetric;
     * and a worker only takes the window when the ready queue is empty and
     * another worker is free, so a busy server never spends one. That guard is
     * in `aowl_net_worker` and is what lets this number be ten rather than
     * two: two was not enough of a window for a client that pauses to inflate
     * a 1.4 MiB answer, and the connection went cold between every round. */

#define AOWL_HOT_READS 16
    /* How many `recv` calls a worker will make while a connection is hot
     * before handing it back. See `aowl_conn_read_hot`: enough that a request
     * split across segments is finished on the thread that is already holding
     * it, few enough that a client which dribbles cannot stay there. */

#define AOWL_WS_MAX_FRAME (256 * 1024)
    /* The largest single frame payload accepted from a client, refused off the
     * length field before anything is reserved for it. That is the whole
     * point: a 14-byte frame header can *claim* a 2^63 payload, and a server
     * that allocates what a length claims is the `Content-Length:
     * 9000000000000000000` bug wearing a different hat. Nothing the game sends
     * on this socket is larger than a ping, so this is already three orders of
     * magnitude of headroom. */

#define AOWL_WS_MAX_MESSAGE (1024 * 1024)
    /* And the largest *message*, which is the same bound one level up:
     * fragmentation lets a client send an unbounded message as a stream of
     * legal frames, so a per-frame limit alone bounds nothing. Refused 1009
     * when the accumulated payload would cross it. */

#define AOWL_WS_IDLE_MS 30000
    /* Silence on a websocket is health, not a stall -- that is the entire
     * difference between this deadline and `AOWL_BODY_MS`, and treating them
     * alike would close the notifier on every player who reads a paragraph of
     * quest text. What this timer is for is the other case: a client that
     * vanished without closing. A half-open TCP connection is indistinguishable
     * from an idle one until something is written to it, so the first
     * expiry sends a ping and the second, with the ping still unanswered,
     * closes. A dead notifier therefore costs at most two of these. */

#define AOWL_WS_SEND_MS 250
    /* Vestigial. It was how long a **worker's** websocket write waited for a
     * peer that had stopped reading, back when a worker wrote the socket itself.
     * No worker writes a websocket any more: a push is appended to the
     * connection's `wsOut` under `g_wsCs` and the poller alone puts it on the
     * wire, because OpenSSL forbids a concurrent read and write on one `SSL` and
     * corrupted its heap when a push met the poller's read (see `aowl_ws_send`).
     * So nothing waits per-stall on a websocket write now, and this constant has
     * no live use; it is kept only so the reasoning above stays on the record. */

#define AOWL_WS_RETRY_MS 5
    /* How long a queued frame, or a close the write lock was busy for, waits
     * for the poller to come back round. It is a cap on the poll timeout for
     * those connections only, so it costs a wakeup on a connection that is
     * mid-close and nothing at all on the rest. Five milliseconds is far below
     * anything a player perceives and far above the cost of the wakeup. */

#define AOWL_WS_OUT_CAP (256 * 1024)
    /* Bytes of pushed notification frames one connection may have queued for the
     * poller to send on its behalf -- the buffer a worker appends to rather than
     * writing the `SSL` itself. Sized for the largest notification the game
     * makes (a `new_message` with rewards is a few hundred bytes; this is three
     * orders of magnitude of headroom) and counted against `AOWL_NET_MAX_BUFFERED`
     * like every other byte held on a client's behalf. A push that would cross
     * it is refused, not truncated: the mod that asked has its own poll queue to
     * fall back to, and half a frame on the wire is worse than a frame delivered
     * a poll later. Distinct from `wsPend` below, which is control frames the
     * poller composed for itself; this is data another thread handed it. */

#define AOWL_WS_PEND_CAP 256
    /* Bytes of already-composed frame the poller may leave queued on one
     * connection when the write lock is busy. Sized for control frames, which
     * is what the read path composes: a pong or a close is at most 2 + 125
     * bytes, so this holds two of them. It is a fixed field rather than an
     * allocation because it is server-composed bytes with a hard ceiling, not
     * something a client can grow; 1024 connections cost 256 KB of BSS and no
     * malloc on the read path. A poller-thread send that does not fit is
     * refused rather than queued -- see `aowl_ws_send`. */

typedef struct {
    SOCKET s;
    char* buf;
    int32_t cap;
    int32_t len;        /* bytes buffered */
    int32_t scanned;    /* bytes already searched for the header terminator */
    int32_t headEnd;    /* offset of the terminator, or -1 */
    int32_t sep;        /* 4 for CRLFCRLF, 2 for LFLF */
    int32_t need;       /* total bytes of this request, or -1 if not yet known */
    int32_t declared;   /* Content-Length as read, for the 408 body */
    int32_t served;     /* requests answered on this connection */
    ULONGLONG deadline;
    int inUse;

    /* -- TLS ------------------------------------------------------------- *
     *
     * `ssl` is the per-connection OpenSSL handle, NULL for a plain connection
     * and for every connection when the server is not in `--tls` mode. `tlsUp`
     * is set once the handshake completes; until then the poller drives
     * `SSL_do_handshake` instead of reading requests. `tlsWantWrite` records a
     * mid-handshake `SSL_ERROR_WANT_WRITE`, so the poller adds `POLLWRNORM` to
     * this one connection's poll events until the handshake settles -- the one
     * TLS signal the plain `recv`/`send` re-poll machinery has no analogue for. */
    void* ssl;
    int tlsUp;
    int tlsWantWrite;

    /* -- websocket ------------------------------------------------------- *
     *
     * `wsReq` is set by the framing when the header block carries
     * `Upgrade: websocket`; it only tells the worker what kind of request it
     * is about to hand to nimony. `ws` is set once nimony has answered 101,
     * and it is the flag that takes this connection out of the request state
     * machine for good -- see the head of this file. */
    int wsReq;
    int ws;
    int wsPinged;       /* an idle ping is outstanding */
    int64_t wsTicket;   /* never reused; see `aowl_ws_adopt` */
    int32_t wsMsgOp;    /* opcode of the message being reassembled, 0 = none */
    char* wsMsg;        /* accumulated continuation payload */
    int32_t wsMsgLen;
    int32_t wsMsgCap;

    /* Frames the poller composed (through nimony) and could not put on the
     * wire at the moment it had them, because the write lock was held by a
     * worker or because the peer's window was full. Written and read only by
     * the poller thread, which is what makes them safe without a lock of their
     * own. `wsClosing` is the connection the poller has decided to close and
     * has not managed to yet: it owes the peer whatever is in `wsPend` and
     * then a `closesocket`, and it is retried every wakeup rather than left
     * for the idle timer. */
    char wsPend[AOWL_WS_PEND_CAP];
    int32_t wsPendLen;
    int wsClosing;

    /* Notification frames a *non-poller* thread (a request worker, a timer, the
     * serve loop) wants pushed down this websocket. They are appended here --
     * under `g_wsCs`, so they do not race the poller draining the same buffer --
     * and put on the wire by the poller in its pending pass, because the poller
     * is the ONE thread that may ever call `SSL_read`/`SSL_write` on a
     * connection's `SSL` handle. OpenSSL forbids a concurrent read and write on
     * one handle and corrupts its heap when it gets one; routing every push
     * through the poller makes that overlap structurally impossible rather than
     * merely locked against. Grown on demand and bounded by `AOWL_WS_OUT_CAP`;
     * a push that would exceed it is refused, which the mod reads as "no socket"
     * and falls back to its poll queue for. See `aowl_ws_send`. */
    char* wsOut;
    int32_t wsOutLen;
    int32_t wsOutCap;
} AowlConn;

static uint64_t g_listenSock = 0;

/* A second listening socket, always **plain HTTP**, whatever `g_tlsMode` says.
 *
 * This exists for one reason, and it is a client bug rather than a design
 * preference. Post-1.0 EFT fetches `/client/*` over its managed HTTP stack,
 * which it configures to accept any certificate -- so the self-signed cert on
 * the TLS listener is fine there. But every *asset* fetch (trader and quest
 * icons, and everything else the client pulls with a `UnityWebRequest`) goes
 * through Unity's own transport, and those call sites never assign a
 * `certificateHandler`. Unity therefore validates the certificate, the
 * handshake is rejected, and the request is never sent; the error branch
 * returns null without logging, so the UI spins forever with nothing in any
 * log but a `handshake FATAL` line on our side.
 *
 * There is no server-side fix for a client that will not accept our cert. The
 * fix is to not offer one: serve the asset routes over plain HTTP on a second
 * port and point the client's asset base url at `http://`. TLS never happens,
 * so TLS validation never fails.
 *
 * It is a second *socket*, not a second poller or a second server. Everything
 * downstream of `accept` already branches on the per-connection `c->ssl`
 * handle rather than on `g_tlsMode` -- the reads, the sends, the websocket
 * pump -- so a connection accepted here with `ssl == NULL` takes the plain
 * path throughout with no other change. In particular this adds no second
 * thread touching an `SSL`: these connections have none, and the poller
 * remains the only thread that drives a handshake. */
static uint64_t g_listenSock2 = 0;
static volatile LONG g_netRunning = 0;

static AowlConn g_conns[AOWL_NET_MAX_CONNS];
static int32_t g_freeList[AOWL_NET_MAX_CONNS];
static int32_t g_freeCount = 0;
static volatile LONG64 g_bufBytes = 0;

/* Forward-declared up by the send helpers; see the note there. */
static void* aowl_ssl_for_sock(SOCKET s) {
    if (!g_tlsMode) return NULL;
    for (int32_t i = 0; i < AOWL_NET_MAX_CONNS; i++)
        if (g_conns[i].inUse && g_conns[i].s == s) return g_conns[i].ssl;
    return NULL;
}

/* Ready: complete requests waiting for a worker. Handback: connections a
 * worker has finished with, waiting for the poller to watch them again. Both
 * are plain arrays under one lock -- neither is ever longer than the
 * connection count. */
static int32_t g_ready[AOWL_NET_MAX_CONNS];
static int32_t g_readyCount = 0;
static int32_t g_handback[AOWL_NET_MAX_CONNS];
static int32_t g_handbackCount = 0;
static CRITICAL_SECTION g_netCs;
static HANDLE g_readySem = NULL;

/* Workers currently lingering on a hot connection rather than available for
 * the ready queue. See the guard in `aowl_net_worker`. */
static volatile LONG g_graceWorkers = 0;

/* The poller's own list. Only the poller thread touches it. */
static int32_t g_watch[AOWL_NET_MAX_CONNS];
static int32_t g_watchCount = 0;

static HANDLE g_workers[AOWL_NET_WORKERS];
static int32_t g_workerCount = 0;
static HANDLE g_pollThread = NULL;

/* A datagram pair on loopback, used only to wake the poller out of `WSAPoll`
 * when a worker hands a connection back. Without it the poller would not see
 * the handback until its next timeout, and a keep-alive request would pay that
 * as latency. */
static SOCKET g_wakeRead = INVALID_SOCKET;
static SOCKET g_wakeWrite = INVALID_SOCKET;

static void aowl_net_set_nonblocking(SOCKET s) {
    u_long mode = 1;
    ioctlsocket(s, FIONBIO, &mode);
}

static int aowl_wake_open(void) {
    struct sockaddr_in a;
    int alen = (int)sizeof(a);
    g_wakeRead = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (g_wakeRead == INVALID_SOCKET) return 0;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = 0;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(g_wakeRead, (struct sockaddr*)&a, sizeof(a)) == SOCKET_ERROR)
        return 0;
    if (getsockname(g_wakeRead, (struct sockaddr*)&a, &alen) == SOCKET_ERROR)
        return 0;
    g_wakeWrite = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (g_wakeWrite == INVALID_SOCKET) return 0;
    if (connect(g_wakeWrite, (struct sockaddr*)&a, sizeof(a)) == SOCKET_ERROR)
        return 0;
    aowl_net_set_nonblocking(g_wakeRead);
    aowl_net_set_nonblocking(g_wakeWrite);
    return 1;
}

static void aowl_wake_poller(void) {
    char b = 1;
    if (g_wakeWrite != INVALID_SOCKET) send(g_wakeWrite, &b, 1, 0);
}

static void aowl_wake_drain(void) {
    char b[64];
    while (recv(g_wakeRead, b, (int)sizeof(b), 0) > 0) { }
}

/* -- connection slots ---------------------------------------------------- */

/* The reassembly buffer for a fragmented websocket message. Counted against
 * `AOWL_NET_MAX_BUFFERED` like every other byte this server holds on a
 * client's behalf, and freed with the connection buffer so there is one place
 * a connection gives its memory back. */
static void aowl_ws_free_msg(AowlConn* c) {
    if (c->wsMsg) {
        InterlockedExchangeAdd64(&g_bufBytes, -(LONG64)c->wsMsgCap);
        free(c->wsMsg);
        c->wsMsg = NULL;
        c->wsMsgCap = 0;
    }
    c->wsMsgLen = 0;
    c->wsMsgOp = 0;
}

/* The outbound push queue, freed with the connection like every other buffer
 * it holds and counted the same way. Poller thread or a drop under `g_wsCs`
 * only. */
static void aowl_ws_free_out(AowlConn* c) {
    if (c->wsOut) {
        InterlockedExchangeAdd64(&g_bufBytes, -(LONG64)c->wsOutCap);
        free(c->wsOut);
        c->wsOut = NULL;
        c->wsOutCap = 0;
    }
    c->wsOutLen = 0;
}

static void aowl_conn_free_buf(AowlConn* c) {
    aowl_ws_free_msg(c);
    aowl_ws_free_out(c);
    if (c->buf) {
        InterlockedExchangeAdd64(&g_bufBytes, -(LONG64)c->cap);
        free(c->buf);
        c->buf = NULL;
        c->cap = 0;
    }
}

static int32_t aowl_conn_take(SOCKET s) {
    int32_t idx = -1;
    EnterCriticalSection(&g_netCs);
    if (g_freeCount > 0) idx = g_freeList[--g_freeCount];
    LeaveCriticalSection(&g_netCs);
    if (idx < 0) return -1;
    AowlConn* c = &g_conns[idx];
    c->s = s;
    c->buf = NULL;
    c->cap = 0;
    c->len = 0;
    c->scanned = 0;
    c->headEnd = -1;
    c->sep = 4;
    c->need = -1;
    c->declared = 0;
    c->served = 0;
    c->deadline = GetTickCount64() + AOWL_HEAD_MS;
    c->ssl = NULL;
    c->tlsUp = 0;
    c->tlsWantWrite = 0;
    c->wsReq = 0;
    c->ws = 0;
    c->wsPinged = 0;
    c->wsTicket = 0;
    c->wsMsg = NULL;
    c->wsMsgLen = 0;
    c->wsMsgCap = 0;
    c->wsMsgOp = 0;
    c->wsPendLen = 0;
    c->wsClosing = 0;
    c->wsOut = NULL;
    c->wsOutLen = 0;
    c->wsOutCap = 0;
    c->inUse = 1;
    return idx;
}

static void aowl_conn_drop(int32_t idx) {
    AowlConn* c = &g_conns[idx];
    /* Before the socket is closed: `aowl_tls_conn_free` writes a best-effort
     * close_notify, which needs the socket still open. It never blocks. */
    if (c->ssl) {
        aowl_tls_conn_free(c->ssl);
        c->ssl = NULL;
    }
    if (c->s != INVALID_SOCKET) {
        closesocket(c->s);
        c->s = INVALID_SOCKET;
    }
    aowl_conn_free_buf(c);
    c->inUse = 0;
    EnterCriticalSection(&g_netCs);
    g_freeList[g_freeCount++] = idx;
    LeaveCriticalSection(&g_netCs);
}

/* Grows the buffer to hold `want` bytes. Returns 0 if that would break the
 * global bound, in which case the caller closes the connection -- the only
 * honest answer, since the request cannot be received and nothing has been
 * parsed yet to answer it with. */
static int aowl_conn_reserve(AowlConn* c, int32_t want) {
    if (c->cap >= want) return 1;
    int32_t next = c->cap > 0 ? c->cap : AOWL_CONN_CHUNK;
    while (next < want) {
        if (next > (int32_t)0x20000000) { next = want; break; }
        next *= 2;
    }
    LONG64 delta = (LONG64)next - (LONG64)c->cap;
    if (InterlockedExchangeAdd64(&g_bufBytes, delta) + delta >
        (LONG64)AOWL_NET_MAX_BUFFERED) {
        InterlockedExchangeAdd64(&g_bufBytes, -delta);
        return 0;
    }
    char* p = (char*)realloc(c->buf, (size_t)next);
    if (!p) {
        InterlockedExchangeAdd64(&g_bufBytes, -delta);
        return 0;
    }
    c->buf = p;
    c->cap = next;
    return 1;
}

/* -- framing ------------------------------------------------------------- *
 *
 * See the head of this file for why this lives in C and why a disagreement
 * with nimony cannot desynchronise anything. The scan is byte-for-byte the one
 * `serveConnection` used to do, including resuming three bytes behind the last
 * look so a terminator split across two segments is still found. */

static int32_t aowl_ci_match(const char* p, int32_t n, const char* lit) {
    int32_t i = 0;
    while (lit[i]) {
        if (i >= n) return 0;
        char a = p[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (a != lit[i]) return 0;
        i++;
    }
    return i;
}

/* First `Content-Length` in the header block, clamped the way `parseHead`
 * clamps it so that an absurd one saturates above the limit rather than
 * wrapping negative. A second, disagreeing one is not detected here and does
 * not need to be: nimony refuses the request and closes.
 *
 * Returns `AOWL_LEN_BAD` for a value that is not a length at all -- `-1`,
 * `+5`, `0x10`, `5abc`, `5, 5`, or no value. That is not pedantry about a
 * grammar. The old scan stopped at the first non-digit and returned what it
 * had, so every one of those was *zero*: this request has no body, and the
 * bytes the client sent as its body begin the next request. `parseHead` read
 * them the same way, so the two agreed -- and agreeing on the wrong answer is
 * exactly what a request smuggling primitive is. Measured with
 * `backend/framelen.nim`: `Content-Length: 5abc`, five bytes of body and one
 * more request behind it came back as *two* answers, the second of them for a
 * request line made out of the first one's body. A length that is not
 * `1*DIGIT` is refused, and the framer does not wait for a body it is about
 * to refuse. */
#define AOWL_LEN_BAD (-1)

static int32_t aowl_scan_length(const char* head, int32_t n) {
    int32_t i = 0;
    /* Skip the request line. */
    while (i < n && head[i] != '\n') i++;
    i++;
    while (i < n) {
        int32_t eol = i;
        while (eol < n && head[eol] != '\n') eol++;
        int32_t lineLen = eol - i;
        if (lineLen > 0 && head[i + lineLen - 1] == '\r') lineLen--;
        int32_t adv = aowl_ci_match(head + i, lineLen, "content-length");
        if (adv > 0) {
            int32_t j = i + adv;
            while (j < i + lineLen && (head[j] == ' ' || head[j] == '\t')) j++;
            if (j < i + lineLen && head[j] == ':') {
                j++;
                while (j < i + lineLen &&
                       (head[j] == ' ' || head[j] == '\t')) j++;
                int32_t v = 0;
                int any = 0;
                while (j < i + lineLen && head[j] >= '0' && head[j] <= '9') {
                    if (v <= AOWL_BODY_CAP) v = v * 10 + (head[j] - '0');
                    any = 1;
                    j++;
                }
                /* Optional whitespace after the value is allowed. Anything
                 * else on the line is not, and neither is no digits at all. */
                while (j < i + lineLen &&
                       (head[j] == ' ' || head[j] == '\t')) j++;
                if (!any || j != i + lineLen) return AOWL_LEN_BAD;
                return v;
            }
        }
        i = eol + 1;
    }
    return 0;
}

/* Whether the header block asks for a websocket.
 *
 * Advisory in exactly the way the rest of the framing is: all it decides here
 * is that the worker is about to hand nimony a request that may not come back
 * as an ordinary one. `handshake` in `backend/websocket.nim` re-reads the same
 * bytes and is the authority -- it checks the version, the key, the
 * `Connection` token and a non-empty session, and a request that fails any of
 * `400` and closed rather than upgraded. So a disagreement between the two
 * costs nothing: this side never acts on `wsReq` except to skip the keep-alive
 * bookkeeping for a connection nimony has already said is a websocket. */
static int aowl_scan_upgrade(const char* head, int32_t n) {
    int32_t i = 0;
    while (i < n && head[i] != '\n') i++;
    i++;
    while (i < n) {
        int32_t eol = i;
        while (eol < n && head[eol] != '\n') eol++;
        int32_t lineLen = eol - i;
        if (lineLen > 0 && head[i + lineLen - 1] == '\r') lineLen--;
        int32_t adv = aowl_ci_match(head + i, lineLen, "upgrade");
        if (adv > 0) {
            int32_t j = i + adv;
            while (j < i + lineLen && (head[j] == ' ' || head[j] == '\t')) j++;
            if (j < i + lineLen && head[j] == ':') {
                for (int32_t k = j; k < i + lineLen; k++) {
                    if (aowl_ci_match(head + k, i + lineLen - k, "websocket"))
                        return 1;
                }
            }
        }
        i = eol + 1;
    }
    return 0;
}

/* Works out how many bytes this request is, if that is knowable yet. */
static void aowl_frame(AowlConn* c) {
    if (c->need >= 0) return;
    if (c->headEnd < 0) {
        int32_t k = c->scanned > 3 ? c->scanned - 3 : 0;
        while (k + 1 < c->len) {
            if (c->buf[k] == 13 && k + 3 < c->len && c->buf[k + 1] == 10 &&
                c->buf[k + 2] == 13 && c->buf[k + 3] == 10) {
                c->headEnd = k;
                c->sep = 4;
                break;
            }
            if (c->buf[k] == 10 && c->buf[k + 1] == 10) {
                c->headEnd = k;
                c->sep = 2;
                break;
            }
            k++;
        }
        c->scanned = c->len;
    }
    if (c->headEnd < 0) {
        /* No terminator, and no room left to find one: hand it over so nimony
         * can answer 431 and close. */
        if (c->len >= AOWL_HEAD_CAP) c->need = c->len;
        return;
    }
    int32_t cl = aowl_scan_length(c->buf, c->headEnd);
    c->declared = cl > 0 ? cl : 0;
    c->wsReq = aowl_scan_upgrade(c->buf, c->headEnd);
    if (cl > AOWL_BODY_CAP || cl == AOWL_LEN_BAD) {
        /* Not waited for and not allocated. nimony answers 413 for the first
         * and 400 for the second, and closes on both, so the unread body on
         * the socket leaves with the connection rather than being read as the
         * request that follows it. */
        c->need = c->headEnd + c->sep;
    } else {
        c->need = c->headEnd + c->sep + cl;
    }
}

static int aowl_conn_complete(AowlConn* c) {
    return c->need >= 0 && c->len >= c->need;
}

/* How many more bytes we are willing to take before the framing tells us
 * something. While the headers are incomplete that is the header cap; once
 * they are complete it is exactly the rest of this request. */
static int32_t aowl_conn_want(AowlConn* c) {
    if (c->need >= 0) return c->need - c->len;
    return AOWL_HEAD_CAP - c->len;
}

/* Reads whatever is waiting. Returns 1 to keep the connection, 0 to close it
 * silently, and -1 to close it after nimony has written a 408 for a body that
 * stopped arriving.
 *
 * The three outcomes are exactly what the nimony loop did: a peer that closes
 * between requests or mid-headers gets nothing back, and a peer that closes
 * mid-body gets the 408 the old body loop sent. */
static int aowl_conn_read(AowlConn* c) {
    for (;;) {
        if (aowl_conn_complete(c)) return 1;
        int32_t want = aowl_conn_want(c);
        if (want <= 0) return 1;
        if (want > 65536) want = 65536;
        if (!aowl_conn_reserve(c, c->len + want)) return 0;
        int n = c->ssl ? aowl_tls_read_once(c->ssl, c->buf + c->len, want)
                       : recv(c->s, c->buf + c->len, want, 0);
        if (n > 0) {
            c->len += n;
            aowl_frame(c);
            if (aowl_conn_complete(c)) return 1;
            continue;
        }
        if (n == 0) {
            /* Orderly close. Mid-body is the one case that is answered. */
            if (c->headEnd >= 0 && c->need > c->len) return -1;
            return 0;
        }
        if (WSAGetLastError() == WSAEWOULDBLOCK) return 1;
        return 0;
    }
}

/* The deadline that applies to a connection in its current state. */
static ULONGLONG aowl_conn_deadline(AowlConn* c, ULONGLONG now) {
    /* First, because it is the case the other three would get wrong. A
     * websocket that has said nothing is not a stalled request, and giving it
     * `AOWL_HEAD_MS` would close the notifier three seconds into every menu. */
    if (c->ws) return now + AOWL_WS_IDLE_MS;
    if (c->len == 0) {
        /* Nothing in hand. On a connection that has already answered
         * something this is an idle keep-alive, which is what keep-alive is
         * for; on a fresh one it is a client that connected and said nothing. */
        return now + (c->served > 0 ? AOWL_IDLE_MS : AOWL_HEAD_MS);
    }
    if (c->headEnd < 0) return now + AOWL_HEAD_MS;
    return now + AOWL_BODY_MS;
}

/* -- the websocket ------------------------------------------------------- *
 *
 * Read the head of this file first: what is here is frame boundaries and the
 * refusals that are decisions about whether to keep reading, and what is not
 * here is the handshake and every composed byte.
 */

/* One critical section over every websocket write and over the close of a
 * websocket connection. Two threads writing frames onto one socket interleave
 * into a stream neither side can parse, and a socket closed under a send in
 * flight is a use-after-close; one lock covers both. Three things take it: a
 * push from a worker (rare), `aowl_ws_adopt` from a worker at the 101, and the
 * poller, in `aowl_ws_send` when it answers a ping or a close and in
 * `aowl_ws_drop` when it closes one. The two worker paths wait for it; neither
 * poller path does. See `aowl_ws_send` for how that is enforced and the head of
 * this file for what it costs when it is not.
 *
 * The lock order is **nimony's lock, then this one, never the reverse**. Every
 * call from here into nimony -- a ping to echo, a close, a violation, an idle
 * tick, a connection gone -- is made with this released, and nimony's answer
 * comes back through `aowl_ws_send`, which takes it. */
static CRITICAL_SECTION g_wsCs;

/* A ticket rather than the socket, and this is not decoration.
 *
 * A push arrives naming a session, and nimony's session table is what turns
 * that into a connection. If the thing it stored were the socket, then a
 * websocket that closed and a *new* one accepted onto the same recycled socket
 * handle before nimony was told the first had gone would receive another
 * player's notification -- a narrow window, and the kind that is impossible to
 * reproduce and unmistakable when it happens. A ticket is never reused, so a
 * send against a closed connection finds nothing and says so. */
static volatile LONG64 g_wsTicket = 0;

/* Called by nimony from inside `aowlspt_nim_handle`, after it has written the
 * 101 and before it returns 2. Returns the ticket, or 0 if this socket is not
 * a connection this server is holding -- in which case nimony answers the
 * request as an ordinary one rather than pretending to have upgraded it. */
static int64_t aowl_ws_adopt(uint64_t sock) {
    int64_t ticket = 0;
    EnterCriticalSection(&g_wsCs);
    for (int32_t i = 0; i < AOWL_NET_MAX_CONNS; i++) {
        AowlConn* c = &g_conns[i];
        if (!c->inUse || c->s != (SOCKET)sock || c->ws) continue;
        ticket = (int64_t)InterlockedIncrement64(&g_wsTicket);
        c->ws = 1;
        c->wsTicket = ticket;
        c->wsPinged = 0;
        /* The request state machine is done with this connection. Clearing
         * these is what makes that true rather than merely intended: `need`
         * and `headEnd` are what `aowl_conn_complete` reads, and a websocket
         * must never satisfy it again. */
        c->need = -1;
        c->headEnd = -1;
        c->scanned = 0;
        c->declared = 0;
        c->wsReq = 0;
        break;
    }
    LeaveCriticalSection(&g_wsCs);
    return ticket;
}

/* Which thread is in here, and which connection it is answering for.
 *
 * The poller may not wait -- not on the lock and not on a peer -- and the
 * calls it makes into nimony come back into `aowl_ws_send` several frames
 * deep, so the rule cannot be enforced at the call sites: a pong is composed
 * inside `aowlspt_nim_ws_control`, which the poller reached from
 * `aowl_ws_pump`, and nothing at that depth knows which thread it is on.
 * Asking *which thread is this* is the enforcement, and it covers a poller
 * path added later without that path having to remember anything.
 *
 * It is a thread id rather than a thread-local flag, and that is not a style
 * choice: `__declspec(thread)` is **ignored with a warning** by the ucrt64 gcc
 * this repo builds with, so a thread-local written by the poller would be a
 * plain global read by all sixteen workers -- the exact opposite of the rule
 * it was there to keep, arrived at silently. `GetCurrentThreadId` is a read
 * out of the TEB and cannot be got wrong by a compiler flag.
 *
 * `g_pollCur` is the connection the poller is currently pumping or timing out.
 * Only the poller writes it and only the poller reads it, so it needs no
 * synchronisation of its own; it is what gives a deferred frame somewhere to
 * wait, since the poller owns that connection's watch entry for the whole
 * call. */
static DWORD g_pollTid = 0;
static AowlConn* g_pollCur = NULL;

/* Frames the poller had to queue rather than write. Counted so a test can
 * tell "the deferral worked" from "the case never arose"; nothing reads it to
 * make a decision. */
static volatile LONG g_wsDeferred = 0;

/* Frames a non-poller thread appended to a connection's `wsOut` for the poller
 * to send -- every push now, since a worker no longer writes the socket. Same
 * purpose as `g_wsDeferred`: a test can tell "the push went through the queue"
 * from "no push ever reached it", and nothing branches on it. */
static volatile LONG g_wsQueued = 0;

/* One pass of `send` with no waiting at all: returns how many bytes went, 0
 * included, or -1 if the socket is gone. The count matters -- a frame written
 * halfway and then abandoned is a stream neither end can parse, so the
 * remainder is queued rather than dropped. */
static int32_t aowl_ws_write_nowait(SOCKET s, const char* p, int32_t len) {
    int32_t sent = 0;
    void* ssl = aowl_ssl_for_sock(s);
    while (sent < len) {
        int n = ssl ? aowl_tls_write_once(ssl, p + sent, len - sent)
                    : send(s, p + sent, len - sent, 0);
        if (n > 0) { sent += n; continue; }
        if (n == 0) return -1;
        if (WSAGetLastError() == WSAEWOULDBLOCK) return sent;
        return -1;
    }
    return sent;
}

/* Queues bytes for the next wakeup. Poller thread only. -1 means they do not
 * fit, which the caller reports as a failed send rather than pretending. */
static int32_t aowl_ws_defer(AowlConn* c, const char* p, int32_t len) {
    if (c == NULL || len <= 0) return -1;
    if (len > AOWL_WS_PEND_CAP - c->wsPendLen) return -1;
    memcpy(c->wsPend + c->wsPendLen, p, (size_t)len);
    c->wsPendLen += len;
    InterlockedIncrement(&g_wsDeferred);
    return len;
}

/* Tries to put whatever is queued on the wire. Returns 1 for "nothing left",
 * 0 for "still queued, try again", -1 for "the socket is gone". Poller thread
 * only, and never waits: the lock is tried, and the write is one pass. */
static int aowl_ws_flush_pending(AowlConn* c) {
    if (c->wsPendLen == 0) return 1;
    if (c->s == INVALID_SOCKET) { c->wsPendLen = 0; return -1; }
    if (!TryEnterCriticalSection(&g_wsCs)) return 0;
    int32_t n = aowl_ws_write_nowait(c->s, c->wsPend, c->wsPendLen);
    LeaveCriticalSection(&g_wsCs);
    if (n < 0) { c->wsPendLen = 0; return -1; }
    if (n > 0) {
        int32_t left = c->wsPendLen - n;
        if (left > 0) memmove(c->wsPend, c->wsPend + n, (size_t)left);
        c->wsPendLen = left;
    }
    return c->wsPendLen == 0 ? 1 : 0;
}

/* Append one pushed frame to a connection's outbound queue, growing it. Called
 * from a non-poller thread with `g_wsCs` held, so it cannot race the poller
 * draining the same buffer in `aowl_ws_flush_out`. Returns 1 on success, 0 if
 * the frame would cross `AOWL_WS_OUT_CAP` or the global buffer bound or a
 * `realloc` fails -- in every one of those the caller reports the push as not
 * delivered and the mod falls back to its poll queue, which is a frame arriving
 * a poll later rather than a frame torn in half or a bound quietly broken. */
static int aowl_ws_enqueue_out(AowlConn* c, const char* p, int32_t len) {
    if (len <= 0) return 0;
    int64_t want = (int64_t)c->wsOutLen + len;
    if (want > (int64_t)AOWL_WS_OUT_CAP) return 0;
    if ((int32_t)want > c->wsOutCap) {
        int32_t next = c->wsOutCap > 0 ? c->wsOutCap : 4096;
        while (next < (int32_t)want) next *= 2;
        LONG64 delta = (LONG64)next - (LONG64)c->wsOutCap;
        if (InterlockedExchangeAdd64(&g_bufBytes, delta) + delta >
            (LONG64)AOWL_NET_MAX_BUFFERED) {
            InterlockedExchangeAdd64(&g_bufBytes, -delta);
            return 0;
        }
        char* np = (char*)realloc(c->wsOut, (size_t)next);
        if (!np) { InterlockedExchangeAdd64(&g_bufBytes, -delta); return 0; }
        c->wsOut = np;
        c->wsOutCap = next;
    }
    memcpy(c->wsOut + c->wsOutLen, p, (size_t)len);
    c->wsOutLen = (int32_t)want;
    InterlockedIncrement(&g_wsQueued);
    return 1;
}

/* The poller putting a connection's queued pushes on the wire. Same shape and
 * same rules as `aowl_ws_flush_pending` -- poller thread only, one non-blocking
 * pass under a tried lock, the unsent tail kept in order for the next wakeup --
 * but over the growable push queue rather than the fixed control buffer. This
 * is where a worker's notification actually reaches `SSL_write`, on the one
 * thread allowed to touch the handle. */
static int aowl_ws_flush_out(AowlConn* c) {
    if (c->wsOutLen == 0) return 1;
    if (c->s == INVALID_SOCKET) { c->wsOutLen = 0; return -1; }
    if (!TryEnterCriticalSection(&g_wsCs)) return 0;
    int32_t n = aowl_ws_write_nowait(c->s, c->wsOut, c->wsOutLen);
    LeaveCriticalSection(&g_wsCs);
    if (n < 0) { c->wsOutLen = 0; return -1; }
    if (n > 0) {
        int32_t left = c->wsOutLen - n;
        if (left > 0) memmove(c->wsOut, c->wsOut + n, (size_t)left);
        c->wsOutLen = left;
    }
    return c->wsOutLen == 0 ? 1 : 0;
}

/* The one way a websocket frame reaches the wire. `buf` is bytes nimony has
 * already framed. Returns the count sent, or -1 for "there is no such live
 * connection, or it would not take them".
 *
 * There are two of it, and which one runs is decided by the thread rather than
 * by the caller -- and the split is the whole of why a websocket no longer
 * crashes the server:
 *
 *   * **The poller** is the only thread that ever touches a connection's `SSL`
 *     handle. It never waits: it tries the lock and writes in one pass, and
 *     anything it cannot put on the wire right now is queued on the connection
 *     (a control frame in `wsPend`) and goes out at the next wakeup.
 *   * **Any other thread** -- a request worker pushing a notification, a timer,
 *     the serve loop -- does *not* write the socket. It appends the frame to
 *     the connection's outbound queue (`wsOut`, under `g_wsCs`) and wakes the
 *     poller, which drains it in `aowl_ws_flush_out`. This is not an
 *     optimisation, it is a correctness rule: OpenSSL forbids a concurrent
 *     `SSL_read` and `SSL_write` on one handle and corrupts its own heap when
 *     it gets them, and the notifier is the one connection the poller keeps
 *     *reading* while another thread would push to it. A worker that called
 *     `SSL_write` here raced the poller's `SSL_read` -- a silent heap-corruption
 *     fast-fail (`STATUS_HEAP_CORRUPTION`, which does not even reach an
 *     unhandled-exception filter) exactly when a push met a client-side
 *     teardown, i.e. raid entry and logout. Routing the push through the poller
 *     removes the overlap outright rather than serialising it and hoping every
 *     path took the lock.
 *
 * Queuing preserves order within each queue: later frames wait behind earlier
 * ones rather than overtaking on a lock that has since come free. A push the
 * queue cannot take (over `AOWL_WS_OUT_CAP`, or the global bound) is refused,
 * which the caller reports as "no socket" and the mod answers from its own poll
 * queue -- a frame a poll later, never a frame torn in half. */
static int32_t aowl_ws_send(int64_t ticket, const void* buf, int32_t len) {
    if (ticket <= 0 || len <= 0) return -1;

    if (GetCurrentThreadId() == g_pollTid) {
        AowlConn* c = g_pollCur;
        int mine = (c != NULL && c->inUse && c->ws && c->wsTicket == ticket);
        if (mine && c->wsPendLen > 0)
            return aowl_ws_defer(c, (const char*)buf, len);
        if (!TryEnterCriticalSection(&g_wsCs))
            return mine ? aowl_ws_defer(c, (const char*)buf, len) : -1;
        int32_t n = -1;
        if (mine) {
            n = aowl_ws_write_nowait(c->s, (const char*)buf, len);
        } else {
            for (int32_t i = 0; i < AOWL_NET_MAX_CONNS; i++) {
                AowlConn* o = &g_conns[i];
                if (!o->inUse || !o->ws || o->wsTicket != ticket) continue;
                n = aowl_ws_write_nowait(o->s, (const char*)buf, len);
                break;
            }
        }
        LeaveCriticalSection(&g_wsCs);
        if (n < 0) return -1;
        if (n == len) return len;
        /* Partly written. The rest must follow it, in order, or the peer is
         * reading half a frame. */
        if (!mine) return -1;
        if (aowl_ws_defer(c, (const char*)buf + n, len - n) < 0) return -1;
        return len;
    }

    /* A non-poller thread: queue the frame for the poller and wake it. The
     * append is under `g_wsCs` so it does not race the poller draining `wsOut`;
     * the SSL write itself happens later, on the poller thread, in
     * `aowl_ws_flush_out`. No `SSL` call is made from here, which is the point. */
    int32_t sent = -1;
    EnterCriticalSection(&g_wsCs);
    for (int32_t i = 0; i < AOWL_NET_MAX_CONNS; i++) {
        AowlConn* c = &g_conns[i];
        if (!c->inUse || !c->ws || c->wsTicket != ticket) continue;
        sent = aowl_ws_enqueue_out(c, (const char*)buf, len) ? len : -1;
        break;
    }
    LeaveCriticalSection(&g_wsCs);
    if (sent > 0) aowl_wake_poller();
    return sent;
}

/* Reasons a frame is refused, which are the `code` argument of
 * `aowlspt_nim_ws_control(kind 2)` and the close status that goes out. */
#define AOWL_WS_CLOSE_PROTOCOL 1002
#define AOWL_WS_CLOSE_TOO_BIG  1009

/* Reads whatever has arrived and acts on every whole frame in it. Returns 1 to
 * keep the connection and 0 to close it; a close that owes the peer a close
 * frame has already asked nimony for one.
 *
 * The shape is deliberately the same as `aowl_conn_read`: read what is there,
 * work out whether a whole thing is in hand, act on it, keep the remainder.
 * The differences are all refusals, and each is a decision about whether to go
 * on reading, which is why they are here rather than in nimony:
 *
 *   * **An unmasked client frame is refused, always.** RFC 6455 requires a
 *     client to mask and requires a server to fail the connection when it does
 *     not. Tolerating it costs nothing on loopback and is exactly the shape of
 *     a check that gets removed for convenience and never put back; the
 *     masking rule exists to stop a websocket being used to make a browser
 *     emit attacker-chosen plaintext at a proxy, and a server that does not
 *     enforce it is not speaking this protocol.
 *   * **A length is refused, not allocated.** `AOWL_WS_MAX_FRAME` is checked
 *     against the length *field*, before the buffer is grown, so a 14-byte
 *     header claiming two exabytes costs 14 bytes. `AOWL_WS_MAX_MESSAGE`
 *     is the same check across a fragmented message, which a per-frame limit
 *     alone does not bound at all.
 *   * **A control frame must be short and unfragmented**, and an unknown
 *     opcode or a reserved bit is a protocol error rather than something to
 *     skip past. Skipping past it is how two ends end up disagreeing about
 *     where the next frame starts.
 */
static int aowl_ws_pump(AowlConn* c) {
    for (;;) {
        /* -- act on every complete frame already buffered ----------------- */
        int32_t at = 0;
        for (;;) {
            int32_t avail = c->len - at;
            if (avail < 2) break;
            const unsigned char* f = (const unsigned char*)(c->buf + at);
            int fin = (f[0] & 0x80) != 0;
            int rsv = (f[0] & 0x70) != 0;
            int32_t op = (int32_t)(f[0] & 0x0F);
            int masked = (f[1] & 0x80) != 0;
            int64_t payload = (int64_t)(f[1] & 0x7F);
            int32_t hdr = 2;

            if (rsv) {
                aowlspt_nim_ws_control(c->wsTicket, 2,
                                       AOWL_WS_CLOSE_PROTOCOL, NULL, 0);
                return 0;
            }
            if (!masked) {
                /* The refusal named above. Not negotiable and not a warning. */
                aowlspt_nim_ws_control(c->wsTicket, 2,
                                       AOWL_WS_CLOSE_PROTOCOL, NULL, 0);
                return 0;
            }
            if (payload == 126) {
                if (avail < 4) break;
                payload = ((int64_t)f[2] << 8) | (int64_t)f[3];
                hdr = 4;
            } else if (payload == 127) {
                if (avail < 10) break;
                payload = 0;
                for (int k = 0; k < 8; k++)
                    payload = (payload << 8) | (int64_t)f[2 + k];
                hdr = 10;
                /* The top bit must be clear per the RFC, and anything with the
                 * high word set is over the cap anyway -- but it is checked
                 * before the cast so the comparison below is on a number
                 * rather than on whatever a truncation made of one. */
                if (payload < 0) {
                    aowlspt_nim_ws_control(c->wsTicket, 2,
                                           AOWL_WS_CLOSE_PROTOCOL, NULL, 0);
                    return 0;
                }
            }
            if (payload > (int64_t)AOWL_WS_MAX_FRAME) {
                aowlspt_nim_ws_control(c->wsTicket, 2,
                                       AOWL_WS_CLOSE_TOO_BIG, NULL, 0);
                return 0;
            }

            int isControl = (op & 0x08) != 0;
            if (isControl && (payload > 125 || !fin)) {
                /* A control frame carries at most 125 bytes and is never
                 * fragmented. Both are the RFC's, and both exist so that a
                 * close or a ping cannot be used to make a peer buffer. */
                aowlspt_nim_ws_control(c->wsTicket, 2,
                                       AOWL_WS_CLOSE_PROTOCOL, NULL, 0);
                return 0;
            }

            int32_t total = hdr + 4 + (int32_t)payload;
            if (c->len - at < total) {
                /* Not all here yet. The reserve below asks for exactly this
                 * frame, which is why a claimed length can never grow the
                 * buffer past the cap it was checked against. */
                if (!aowl_conn_reserve(c, at + total)) return 0;
                break;
            }

            unsigned char* mask = (unsigned char*)(c->buf + at + hdr);
            unsigned char* data = mask + 4;
            for (int32_t k = 0; k < (int32_t)payload; k++)
                data[k] = (unsigned char)(data[k] ^ mask[k & 3]);

            at += total;

            if (op == 0x8) {
                /* The peer's close. Nimony echoes one and we drop; there is
                 * nothing after a close worth reading. */
                int32_t code = 1000;
                if (payload >= 2) code = ((int32_t)data[0] << 8) | data[1];
                aowlspt_nim_ws_control(c->wsTicket, 1, code, NULL, 0);
                return 0;
            }
            if (op == 0x9) {
                aowlspt_nim_ws_control(c->wsTicket, 0, 0, data,
                                       (int32_t)payload);
                continue;
            }
            if (op == 0xA) {
                /* A pong. Nothing to answer; its whole value is that it
                 * arrived, which the idle timer reads off `wsPinged`. */
                c->wsPinged = 0;
                continue;
            }
            if (isControl) {
                aowlspt_nim_ws_control(c->wsTicket, 2,
                                       AOWL_WS_CLOSE_PROTOCOL, NULL, 0);
                return 0;
            }

            /* A data frame: 1 text, 2 binary, 0 continuation. */
            if (op == 0x0) {
                if (c->wsMsgOp == 0) {
                    /* A continuation of nothing. */
                    aowlspt_nim_ws_control(c->wsTicket, 2,
                                           AOWL_WS_CLOSE_PROTOCOL, NULL, 0);
                    return 0;
                }
            } else if (op == 0x1 || op == 0x2) {
                if (c->wsMsgOp != 0) {
                    /* A new message on top of an unfinished one. */
                    aowlspt_nim_ws_control(c->wsTicket, 2,
                                           AOWL_WS_CLOSE_PROTOCOL, NULL, 0);
                    return 0;
                }
                c->wsMsgOp = op;
            } else {
                aowlspt_nim_ws_control(c->wsTicket, 2,
                                       AOWL_WS_CLOSE_PROTOCOL, NULL, 0);
                return 0;
            }

            if (fin && c->wsMsgLen == 0) {
                /* The ordinary case: one frame is the whole message, and it is
                 * handed over out of the connection buffer without a copy. */
                int32_t keep = aowlspt_nim_ws_message(c->wsTicket, c->wsMsgOp,
                                                      data, (int32_t)payload);
                c->wsMsgOp = 0;
                if (!keep) return 0;
                continue;
            }

            if ((int64_t)c->wsMsgLen + payload > (int64_t)AOWL_WS_MAX_MESSAGE) {
                aowl_ws_free_msg(c);
                aowlspt_nim_ws_control(c->wsTicket, 2,
                                       AOWL_WS_CLOSE_TOO_BIG, NULL, 0);
                return 0;
            }
            int32_t want = c->wsMsgLen + (int32_t)payload;
            if (want > c->wsMsgCap) {
                int32_t next = c->wsMsgCap > 0 ? c->wsMsgCap : 4096;
                while (next < want) next *= 2;
                LONG64 delta = (LONG64)next - (LONG64)c->wsMsgCap;
                if (InterlockedExchangeAdd64(&g_bufBytes, delta) + delta >
                    (LONG64)AOWL_NET_MAX_BUFFERED) {
                    InterlockedExchangeAdd64(&g_bufBytes, -delta);
                    aowl_ws_free_msg(c);
                    return 0;
                }
                char* p = (char*)realloc(c->wsMsg, (size_t)next);
                if (!p) {
                    InterlockedExchangeAdd64(&g_bufBytes, -delta);
                    aowl_ws_free_msg(c);
                    return 0;
                }
                c->wsMsg = p;
                c->wsMsgCap = next;
            }
            memcpy(c->wsMsg + c->wsMsgLen, data, (size_t)payload);
            c->wsMsgLen = want;
            if (fin) {
                int32_t op2 = c->wsMsgOp;
                int32_t n = c->wsMsgLen;
                int32_t keep = aowlspt_nim_ws_message(c->wsTicket, op2,
                                                      c->wsMsg, n);
                aowl_ws_free_msg(c);
                if (!keep) return 0;
            }
        }

        if (at > 0) {
            int32_t left = c->len - at;
            if (left > 0) memmove(c->buf, c->buf + at, (size_t)left);
            c->len = left;
        }

        /* -- and then read more, if there is any -------------------------- *
         *
         * `AOWL_CONN_CHUNK` rather than the 64 KiB a request read asks for,
         * and that is about what an idle websocket costs. A notifier receives
         * pings and a close and nothing else, so a 64 KiB read grows every
         * held connection's buffer to 64 KiB the first time it says anything
         * -- 1024 of them would land exactly on `AOWL_NET_MAX_BUFFERED` and
         * leave nothing for anything else.
         * A frame larger than this is still read whole; it just takes another
         * turn of this loop, which costs one `recv` and no correctness. */
        int32_t want = AOWL_CONN_CHUNK;
        if (!aowl_conn_reserve(c, c->len + want)) return 0;
        int n;
        if (c->ssl) {
            /* One `SSL` object, and OpenSSL forbids a read and a write on it at
             * the same time: `SSL_read` and `SSL_write` share the record layer's
             * state, and a worker pushing a notification (a broadcast at raid
             * entry is the case that bites) is inside `SSL_write` under `g_wsCs`
             * on this very handle. The notifier is the *only* connection where
             * that overlap is possible -- it stays on the poller's watch list
             * and keeps being read here while a worker may push to it, whereas
             * every request connection is owned by one thread at a time. On a
             * plain socket a concurrent `recv`/`send` is fine and this does not
             * apply; there is no lock on that path.
             *
             * So the read joins the write under `g_wsCs`. The poller must never
             * wait on that lock (see `aowl_ws_send`), so a `TryEnter` that loses
             * to a worker's in-flight push is treated exactly like a would-block:
             * the frames stay on the socket, this wakeup returns "keep", and the
             * still-asserted `POLLRDNORM` brings the poller straight back once
             * the push has let the lock go. Without this the two `SSL` calls
             * raced and corrupted the record state -- a silent native crash the
             * moment a push and a client-side teardown coincided, which is raid
             * entry. */
            if (!TryEnterCriticalSection(&g_wsCs)) return 1;
            n = aowl_tls_read_once(c->ssl, c->buf + c->len, want);
            LeaveCriticalSection(&g_wsCs);
        } else {
            n = recv(c->s, c->buf + c->len, want, 0);
        }
        if (n > 0) { c->len += n; continue; }
        if (n == 0) return 0;                       /* peer closed the socket */
        if (WSAGetLastError() == WSAEWOULDBLOCK) return 1;
        return 0;
    }
}

/* -- queues -------------------------------------------------------------- */

static void aowl_push_ready(int32_t idx) {
    EnterCriticalSection(&g_netCs);
    g_ready[g_readyCount++] = idx;
    LeaveCriticalSection(&g_netCs);
    ReleaseSemaphore(g_readySem, 1, NULL);
}

static int32_t aowl_pop_ready(void) {
    int32_t idx = -1;
    EnterCriticalSection(&g_netCs);
    if (g_readyCount > 0) {
        idx = g_ready[0];
        for (int32_t i = 1; i < g_readyCount; i++) g_ready[i - 1] = g_ready[i];
        g_readyCount--;
    }
    LeaveCriticalSection(&g_netCs);
    return idx;
}

static void aowl_push_handback(int32_t idx) {
    EnterCriticalSection(&g_netCs);
    g_handback[g_handbackCount++] = idx;
    LeaveCriticalSection(&g_netCs);
    aowl_wake_poller();
}

/* The hot read: blocking `recv` with `SO_RCVTIMEO` set to the grace window.
 * Returns 1 for "another complete request is in the buffer", 2 for "nothing
 * more, or not enough yet -- give it back to the poller", 0 to close silently
 * and -1 to close after a 408 for a body that stopped arriving.
 *
 * It keeps reading while bytes keep coming, up to `AOWL_HOT_READS` of them.
 * The first version returned to the poller on *any* short read, which sounds
 * conservative and was the single largest cost in this rewrite: a request with
 * a body arrives as a header segment and a body segment, so nearly every
 * request handed the connection back and picked it up again, and two thread
 * wakeups landed on the critical path of almost every answer. It read as a
 * flat 70 microseconds a request on every endpoint. Reading a request that is
 * already arriving is not waiting for a client, it is finishing a receive.
 *
 * The iteration cap is what keeps that from becoming a place to stand. A
 * client that dribbles gets at most `AOWL_HOT_READS` reads before the
 * connection goes back to the poller, which holds it for nothing; the worst a
 * dribbler can buy is `AOWL_HOT_READS * AOWL_HOT_GRACE_MS` of one worker, and
 * only by first having sent a complete request. */
static int aowl_conn_read_hot(AowlConn* c) {
    for (int32_t i = 0; i < AOWL_HOT_READS; i++) {
        int32_t want = aowl_conn_want(c);
        if (want <= 0) return 1;
        if (want > 65536) want = 65536;
        if (!aowl_conn_reserve(c, c->len + want)) return 0;
        int n = c->ssl ? aowl_tls_read_once(c->ssl, c->buf + c->len, want)
                       : recv(c->s, c->buf + c->len, want, 0);
        if (n > 0) {
            c->len += n;
            aowl_frame(c);
            if (aowl_conn_complete(c)) return 1;
            continue;
        }
        if (n == 0) {
            if (c->headEnd >= 0 && c->need > c->len) return -1;
            return 0;
        }
        if (WSAGetLastError() == WSAETIMEDOUT) return 2;
        return 0;
    }
    return 2;
}

/* -- the workers --------------------------------------------------------- */

/* Whether the request this worker is about to answer is the last one this
 * connection is allowed. Thread-local because a worker answers one request at
 * a time and sixteen of them do it at once; read by `aowl_conn_final` from
 * inside the nimony callback, on the same thread, before anything is sent.
 *
 * This exists because the cap below used to be applied *after* the response
 * had gone out, so request 512 was answered `Connection: keep-alive` and the
 * socket then closed under it. The client, told to keep going, sent request
 * 513 into a dead socket and got nothing back -- one silently lost request per
 * 512 on every kept-alive connection, which `benchbackend --keepalive` runs
 * long enough to reach. (A sentence here quoted a diagnostic string that
 * `benchbackend` does not print; what the run shows is a request with no
 * answer, however that happens to be worded.) The
 * server's behaviour is unchanged; what changes is that it now says so. */
/* `__thread`, not `__declspec(thread)`, and this had to change: the ucrt64
 * gcc this repo builds with **ignores** `__declspec(thread)` and says so as a
 * warning nobody was reading, which made this flag a plain global shared by
 * all sixteen workers. One worker answering request 512 of its connection then
 * set it for every worker, and whichever connections happened to be answered
 * in that window were told `Connection: close` on a request that was not their
 * last -- the same lost request this comment describes, arrived at from the
 * other side. The MSVC spelling is kept for a compiler that wants it. */
#if defined(__GNUC__)
#  define AOWL_TLS __thread
#else
#  define AOWL_TLS __declspec(thread)
#endif
static AOWL_TLS int aowl_final_req = 0;

static int aowl_conn_final(void) { return aowl_final_req; }

/* One request out of the buffer, answered, and the bytes behind it kept.
 * The shift-down is what the nimony loop did with its own buffer: anything
 * past this request belongs to the next one, and a pipelined request left on
 * the floor is a client waiting for an answer that was thrown away. */
static int aowl_serve_one(AowlConn* c) {
    int32_t total = c->need;
    if (total < 0 || total > c->len) total = c->len;
    aowl_final_req = (c->served + 1 >= AOWL_KEEPALIVE_MAX) ? 1 : 0;
    if (g_aowl_trace_init || getenv("AOWL_NET_TRACE")) {
        char line[128]; int m = 0;
        for (; m < 127 && m < c->len && c->buf[m] != '\r' && c->buf[m] != '\n'; m++)
            line[m] = c->buf[m];
        line[m] = 0;
        aowl_trace("serve sock=%llu served=%d tls=%d bytes=%d req=[%s]",
                   (unsigned long long)c->s, c->served, c->ssl ? 1 : 0, total, line);
    }
    int32_t keep = aowlspt_nim_handle((uint64_t)c->s, c->buf, total,
                                      c->headEnd, c->sep);
    aowl_final_req = 0;
    int32_t left = c->len - total;
    if (left > 0) memmove(c->buf, c->buf + total, (size_t)left);
    c->len = left;
    c->scanned = 0;
    c->headEnd = -1;
    c->sep = 4;
    c->need = -1;
    c->declared = 0;
    c->served++;
    if (keep == 0) return 0;
    if (keep == 2) {
        /* Upgraded. Not subject to `AOWL_KEEPALIVE_MAX`, which counts
         * *requests* on a connection and would otherwise close the notifier
         * after the one request it will ever make. Whatever is left in the
         * buffer is not the next request, it is this websocket's first
         * frames. */
        return 2;
    }
    if (c->served >= AOWL_KEEPALIVE_MAX) return 0;
    return 1;
}

/* Closing a websocket, which is the one close that has to be coordinated: a
 * push may be inside `send` on this very socket.
 *
 * The body runs with the lock held. Whatever the poller still owes the peer --
 * a close frame it composed while the lock was busy -- goes out here, in one
 * non-blocking pass, immediately before the socket is closed: it is the last
 * moment there is a socket to write it to. A peer whose window is full does
 * not get it, and that is the right answer rather than a wait, since it is a
 * peer that has stopped reading and is about to be closed on.
 *
 * `aowl_ws_drop` returns 0 for "the write lock was busy, try again next round"
 * -- the poller never waits, and a connection that closes one wakeup later
 * closes just as dead. `aowl_ws_drop_blocking` is the same thing for a worker,
 * which may wait and must: a worker that gave up here would close the socket
 * outside the lock, under a push that is inside `send` on it. */
static void aowl_conn_drop(int32_t idx);
static void aowl_ws_drop_locked(int32_t idx) {
    AowlConn* c = &g_conns[idx];
    int64_t ticket = c->wsTicket;
    /* Whatever the poller still owes the peer goes out here, in one pass, while
     * the socket is still open and the lock still held: the control frames it
     * composed (`wsPend`) and then any pushes a worker queued (`wsOut`). A peer
     * whose window is full misses them, which is the right answer for a
     * connection about to close rather than a wait. */
    if (c->s != INVALID_SOCKET) {
        if (c->wsPendLen > 0)
            (void)aowl_ws_write_nowait(c->s, c->wsPend, c->wsPendLen);
        if (c->wsOutLen > 0)
            (void)aowl_ws_write_nowait(c->s, c->wsOut, c->wsOutLen);
    }
    c->wsPendLen = 0;
    c->wsOutLen = 0;
    c->wsClosing = 0;
    c->ws = 0;
    c->wsTicket = 0;
    if (c->s != INVALID_SOCKET) {
        closesocket(c->s);
        c->s = INVALID_SOCKET;
    }
    LeaveCriticalSection(&g_wsCs);
    /* Outside the lock, so the order stays nimony-then-C. */
    aowlspt_nim_ws_gone(ticket);
    aowl_conn_drop(idx);
}

static int aowl_ws_drop(int32_t idx) {
    if (!TryEnterCriticalSection(&g_wsCs)) return 0;
    aowl_ws_drop_locked(idx);
    return 1;
}

static void aowl_ws_drop_blocking(int32_t idx) {
    EnterCriticalSection(&g_wsCs);
    aowl_ws_drop_locked(idx);
}

static DWORD WINAPI aowl_net_worker(LPVOID param) {
    (void)param;
    for (;;) {
        WaitForSingleObject(g_readySem, INFINITE);
        if (InterlockedCompareExchange(&g_netRunning, 1, 1) != 1) break;
        int32_t idx = aowl_pop_ready();
        if (idx < 0) continue;
        AowlConn* c = &g_conns[idx];
        /* Hot: blocking, with the grace window as the receive timeout and
         * `AOWL_SEND_DEADLINE_MS` as the send one. The response goes out with
         * exactly the calls the old server made. */
        u_long blocking = 0;
        ioctlsocket(c->s, FIONBIO, &blocking);
        for (;;) {
            int rc0 = aowl_serve_one(c);
            if (rc0 == 0) { aowl_conn_drop(idx); break; }
            if (rc0 == 2) {
                /* A websocket now. It leaves the request state machine here
                 * and never comes back to it: no pipelining check, no grace
                 * window, no ready queue. What it gets instead is a place in
                 * the poller's watch list for as long as the client keeps it.
                 *
                 * The pump before the handback is not optional. A client is
                 * entitled to put its first frames in the same segment as the
                 * handshake, and those bytes are already in this buffer -- the
                 * poller would never see the socket become readable for them
                 * and the notifier would sit silent until the idle ping. */
                u_long nb = 1;
                ioctlsocket(c->s, FIONBIO, &nb);
                if (c->len > 0 && !aowl_ws_pump(c)) {
                    /* Blocking, because this is a worker and because the
                     * alternative was worse: this used to fall back to
                     * `aowl_conn_drop` when the try failed, which closes the
                     * socket *outside* the lock -- and by this point nimony
                     * has already registered the ticket, so a push could be
                     * inside `send` on the handle being closed. A worker is
                     * allowed to wait; that is the whole difference between it
                     * and the poller. */
                    aowl_ws_drop_blocking(idx);
                    break;
                }
                c->deadline = aowl_conn_deadline(c, GetTickCount64());
                aowl_push_handback(idx);
                break;
            }

            /* A pipelined request already in the buffer costs nothing extra. */
            aowl_frame(c);
            if (aowl_conn_complete(c)) continue;

            /* Whether this worker may linger at all.
             *
             * Lingering is what keeps a busy connection on one thread, and it
             * is only free when the worker had nothing else to do. Two things
             * decide it, and both have to hold: nothing is waiting in the
             * ready queue, and at least one other worker is not lingering
             * either. Without the second, sixteen hot connections could put
             * every worker into a grace window at once and a seventeenth
             * request would wait the window out with a full pool and no work
             * running -- the thread-per-connection failure this change exists
             * to remove, rebuilt out of smaller parts.
             *
             * With the guard the window can be generous, because it is only
             * ever taken by a worker that had nothing else to do. That matters
             * for the case this server actually has: one game, a handful of
             * connections, and a client whose next request is always a few
             * hundred microseconds away. Two milliseconds was not enough of a
             * window for it -- a client that pauses to inflate a 1.4 MiB
             * answer comes back after longer than that -- and the connection
             * went cold between every round, paying two thread wakeups on the
             * next request.
             *
             * `g_readyCount` is read without the lock on purpose. It is a hint
             * about whether the server is busy; being one request out of date
             * costs one grace window. */
            int r = 2;
            int lingering = 0;
            if (g_readyCount == 0) {
                if (InterlockedIncrement(&g_graceWorkers) <=
                    (LONG)(g_workerCount - 1)) {
                    lingering = 1;
                } else {
                    InterlockedDecrement(&g_graceWorkers);
                }
            }
            if (lingering) {
                r = aowl_conn_read_hot(c);
                InterlockedDecrement(&g_graceWorkers);
            }
            if (r == 1) continue;
            if (r <= 0) {
                if (r < 0)
                    aowlspt_nim_timeout((uint64_t)c->s, 1,
                                        c->len - (c->headEnd + c->sep),
                                        c->declared);
                aowl_conn_drop(idx);
                break;
            }

            /* Cold, or half a request. Back to the poller, which costs this
             * connection nothing until it has something to say. */
            u_long nonblocking = 1;
            ioctlsocket(c->s, FIONBIO, &nonblocking);
            c->deadline = aowl_conn_deadline(c, GetTickCount64());
            if (c->ssl)
                aowl_trace("handback sock=%llu idx=%d served=%d len=%d pending=%d",
                           (unsigned long long)c->s, idx, c->served, c->len,
                           aowl_tls_pending(c->ssl));
            aowl_push_handback(idx);
            break;
        }
        if (InterlockedCompareExchange(&g_netRunning, 1, 1) != 1) break;
    }
    return 0;
}

/* -- the poller ---------------------------------------------------------- */

static void aowl_watch_remove(int32_t at) {
    for (int32_t i = at + 1; i < g_watchCount; i++) g_watch[i - 1] = g_watch[i];
    g_watchCount--;
}

/* Drain one listening socket's backlog into the watch list.
 *
 * Lifted out of the poller unchanged so the second, always-plain listener can
 * reuse it; `useTls` is the only thing the two callers disagree about, and it
 * is passed rather than read from `g_tlsMode` because the plain listener must
 * stay plain in a process whose main listener is doing TLS. Only ever called
 * on the poller thread. */
static void aowl_net_accept_from(SOCKET listener, int useTls, ULONGLONG now) {
    for (;;) {
        SOCKET s = accept(listener, NULL, NULL);
        if (s == INVALID_SOCKET) break;
        aowl_net_set_nonblocking(s);
        /* Both only bite in blocking mode, which is the mode a worker puts
         * the socket into while the connection is hot: the receive timeout is
         * the grace window, and the send timeout is what stops a client that
         * asks for the item table and then stops reading it from owning a
         * worker for good. */
        DWORD rcvTo = AOWL_HOT_GRACE_MS;
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&rcvTo,
                   sizeof(rcvTo));
        DWORD sndTo = AOWL_SEND_DEADLINE_MS;
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&sndTo,
                   sizeof(sndTo));
        int32_t idx = aowl_conn_take(s);
        if (idx < 0) {
            /* Past the connection limit. Refused now rather than left in the
             * backlog to time out later. */
            closesocket(s);
            continue;
        }
        if (useTls) {
            /* A TLS connection: attach a server-role `SSL` now, on the
             * non-blocking socket, and let the poller drive the handshake
             * below before it reads a request. A handle that cannot be made
             * is dropped rather than watched. */
            void* ssl = aowl_tls_accept_new(s);
            if (!ssl) { aowl_conn_drop(idx); continue; }
            g_conns[idx].ssl = ssl;
            g_conns[idx].tlsUp = 0;
            g_conns[idx].tlsWantWrite = 0;
            aowl_trace("accept sock=%llu idx=%d (tls)",
                       (unsigned long long)s, idx);
        }
        g_conns[idx].deadline = aowl_conn_deadline(&g_conns[idx], now);
        g_watch[g_watchCount++] = idx;
    }
}

static DWORD WINAPI aowl_net_poller(LPVOID param) {
    (void)param;
    static WSAPOLLFD fds[AOWL_NET_MAX_CONNS + 3];
    /* Set once, read many frames deep: every `aowl_ws_send` reached from this
     * thread -- through nimony composing a pong, a close or a refusal -- takes
     * the path that does not wait. See `aowl_ws_send`. */
    g_pollTid = GetCurrentThreadId();
    g_pollCur = NULL;
    while (InterlockedCompareExchange(&g_netRunning, 1, 1) == 1) {
        ULONGLONG now = GetTickCount64();

        /* Build the set: the wake socket, the listener, then everything being
         * watched. The timeout is the nearest deadline, so a set full of
         * stalled connections wakes this thread once per deadline rather than
         * twice a second per connection. */
        int32_t n = 0;
        fds[n].fd = g_wakeRead;
        fds[n].events = POLLRDNORM;
        fds[n].revents = 0;
        n++;
        int32_t listenAt = -1;
        if (g_listenSock) {
            listenAt = n;
            fds[n].fd = (SOCKET)g_listenSock;
            fds[n].events = POLLRDNORM;
            fds[n].revents = 0;
            n++;
        }
        int32_t listen2At = -1;
        if (g_listenSock2) {
            listen2At = n;
            fds[n].fd = (SOCKET)g_listenSock2;
            fds[n].events = POLLRDNORM;
            fds[n].revents = 0;
            n++;
        }
        int32_t first = n;
        int timeout = 1000;
        for (int32_t i = 0; i < g_watchCount; i++) {
            AowlConn* c = &g_conns[g_watch[i]];
            fds[n].fd = c->s;
            fds[n].events = POLLRDNORM;
            /* A TLS handshake mid-flight that asked for the socket to be
             * writable is the one thing the request loop never waits on -- so
             * it is added here for that one connection until the handshake
             * settles. On loopback this is all but never taken. */
            if (c->ssl && !c->tlsUp && c->tlsWantWrite)
                fds[n].events = (SHORT)(POLLRDNORM | POLLWRNORM);
            fds[n].revents = 0;
            n++;
            int left = c->deadline > now ? (int)(c->deadline - now) : 0;
            /* A connection with a frame queued, or one that owes a close, is
             * not waiting for the peer to say something -- it is waiting for
             * this thread to come back round. Its deadline is irrelevant to
             * that, so it caps the poll instead. */
            if (c->wsPendLen > 0 || c->wsOutLen > 0 || c->wsClosing)
                left = AOWL_WS_RETRY_MS;
            if (left < timeout) timeout = left;
        }

        int r = WSAPoll(fds, (ULONG)n, timeout);
        if (InterlockedCompareExchange(&g_netRunning, 1, 1) != 1) break;
        now = GetTickCount64();

        if (r > 0) {
            if (fds[0].revents) aowl_wake_drain();

            if (listenAt >= 0 && (fds[listenAt].revents & POLLRDNORM))
                aowl_net_accept_from((SOCKET)g_listenSock, g_tlsMode, now);
            /* The second listener is plain HTTP even when the first is doing
             * TLS -- that is the whole point of it; see `g_listenSock2`. */
            if (listen2At >= 0 && (fds[listen2At].revents & POLLRDNORM))
                aowl_net_accept_from((SOCKET)g_listenSock2, 0, now);

            /* Readable connections, walked back to front so removing one does
             * not move an entry we have not looked at yet. */
            for (int32_t i = g_watchCount - 1; i >= 0; i--) {
                int32_t at = first + i;
                if (at >= n) continue;
                short rev = fds[at].revents;
                if (!rev) continue;
                int32_t idx = g_watch[i];
                AowlConn* c = &g_conns[idx];
                if (c->ws) {
                    /* A websocket never reaches `aowl_conn_complete` and never
                     * goes on the ready queue: its frames are read here and
                     * acted on here, and the only thing that leaves this
                     * thread is a call into nimony to compose a pong, a close
                     * or a pushed answer. See the head of this file. */
                    if (c->wsClosing) continue;   /* the retry pass owns it */
                    g_pollCur = c;
                    int wrc = aowl_ws_pump(c);
                    g_pollCur = NULL;
                    if (wrc <= 0 ||
                        (rev & (POLLERR | POLLHUP | POLLNVAL))) {
                        c->wsClosing = 1;
                        if (aowl_ws_drop(idx)) aowl_watch_remove(i);
                        continue;
                    }
                    /* Anything at all from the peer is proof it is there. */
                    c->wsPinged = 0;
                    c->deadline = aowl_conn_deadline(c, now);
                    continue;
                }
                if (c->ssl && !c->tlsUp) {
                    /* Not reading a request yet: this connection is still in
                     * the TLS handshake. Drive it a step and re-poll. A
                     * want-write is recorded so the poll set adds `POLLWRNORM`
                     * for it above; a want-read is the ordinary case. */
                    int hs = aowl_tls_do_handshake(c->ssl);
                    if (hs < 0) {
                        aowl_trace("handshake FATAL sock=%llu idx=%d",
                                   (unsigned long long)c->s, idx);
                        aowl_watch_remove(i);
                        aowl_conn_drop(idx);
                        continue;
                    }
                    if (hs != 1) {
                        c->tlsWantWrite = (hs == 2);
                        c->deadline = aowl_conn_deadline(c, now);
                        continue;
                    }
                    aowl_trace("handshake DONE sock=%llu idx=%d",
                               (unsigned long long)c->s, idx);
                    /* Handshake done. Fall straight through to a read rather
                     * than waiting for the next wakeup: the client is entitled
                     * to have put its first request bytes in the same TLS
                     * record flight as its Finished, and those are already
                     * decrypted inside OpenSSL where a socket poll cannot see
                     * them -- `aowl_conn_read` drains them via `SSL_read`. */
                    c->tlsUp = 1;
                    c->tlsWantWrite = 0;
                }
                int rc = aowl_conn_read(c);
                if (c->ssl)
                    aowl_trace("pollread sock=%llu idx=%d rc=%d len=%d complete=%d pending=%d",
                               (unsigned long long)c->s, idx, rc, c->len,
                               aowl_conn_complete(c) ? 1 : 0, aowl_tls_pending(c->ssl));
                if (rc <= 0) {
                    if (rc < 0)
                        /* Body bytes had, not bytes buffered. `rc < 0` is only
                         * reachable with `headEnd >= 0`, and the header block
                         * is not part of what the client owes -- the other two
                         * calls to this subtract it and this one did not, so
                         * the same stall reported a different `had` depending
                         * on whether the client closed or fell silent. */
                        aowlspt_nim_timeout((uint64_t)c->s, 1,
                                            c->len - (c->headEnd + c->sep),
                                            c->declared);
                    aowl_watch_remove(i);
                    aowl_conn_drop(idx);
                    continue;
                }
                if (aowl_conn_complete(c)) {
                    aowl_watch_remove(i);
                    aowl_push_ready(idx);
                    continue;
                }
                if (rev & (POLLERR | POLLHUP | POLLNVAL)) {
                    aowl_watch_remove(i);
                    aowl_conn_drop(idx);
                    continue;
                }
                /* Progress resets the clock for the phase it is in. */
                c->deadline = aowl_conn_deadline(c, now);
            }
        }

        /* Deadlines. */
        for (int32_t i = g_watchCount - 1; i >= 0; i--) {
            int32_t idx = g_watch[i];
            AowlConn* c = &g_conns[idx];
            if (now < c->deadline) continue;
            if (c->ws) {
                /* Silence on a websocket is not a stall, so this is not a 408.
                 * It is the only way to tell an idle client from one that
                 * vanished without closing: write something and see. The first
                 * expiry pings, the second closes if the ping went unanswered.
                 * `aowlspt_nim_ws_idle` composes the ping, like every other
                 * byte. */
                if (c->wsClosing) continue;   /* the retry pass owns it */
                g_pollCur = c;
                int32_t keepWs = aowlspt_nim_ws_idle(c->wsTicket, c->wsPinged);
                g_pollCur = NULL;
                if (keepWs != 0) {
                    c->wsPinged = 1;
                    c->deadline = aowl_conn_deadline(c, now);
                    continue;
                }
                c->wsClosing = 1;
                if (aowl_ws_drop(idx)) aowl_watch_remove(i);
                continue;
            }
            if (c->len > 0) {
                /* A request that began and stopped. Which 408 depends on how
                 * far it got, and both are written by nimony. */
                if (c->headEnd < 0)
                    aowlspt_nim_timeout((uint64_t)c->s, 0, c->len, 0);
                else
                    aowlspt_nim_timeout((uint64_t)c->s, 1,
                                        c->len - (c->headEnd + c->sep),
                                        c->declared);
            }
            /* Nothing in hand: an idle keep-alive that expired, or a socket
             * that connected and never spoke. Closed without a word, which is
             * what the old loop did. */
            aowl_watch_remove(i);
            aowl_conn_drop(idx);
        }

        /* What the write lock was busy for last time, and the pushes another
         * thread handed this one.
         *
         * Three things end up here: a control frame the poller composed and
         * could not write (a pong, or a close it owes the peer); a notification
         * a worker queued in `wsOut` for the poller to send on its behalf; and
         * a websocket the poller has decided to close and could not. All are
         * retried every wakeup, and the poll timeout above is capped while any
         * is outstanding, so "next wakeup" is milliseconds rather than the idle
         * timer. The `wsOut` drain is the *only* place a pushed frame reaches
         * `SSL_write`, and it is on this thread -- which is the whole reason a
         * push from a worker no longer races the read here. */
        for (int32_t i = g_watchCount - 1; i >= 0; i--) {
            int32_t idx = g_watch[i];
            AowlConn* c = &g_conns[idx];
            if (!c->ws) continue;
            if (c->wsClosing) {
                if (aowl_ws_drop(idx)) aowl_watch_remove(i);
                continue;
            }
            if (c->wsPendLen > 0 && aowl_ws_flush_pending(c) < 0) {
                c->wsClosing = 1;
                if (aowl_ws_drop(idx)) aowl_watch_remove(i);
                continue;
            }
            if (c->wsOutLen > 0 && aowl_ws_flush_out(c) < 0) {
                c->wsClosing = 1;
                if (aowl_ws_drop(idx)) aowl_watch_remove(i);
            }
        }

        /* Connections the workers have finished with. */
        EnterCriticalSection(&g_netCs);
        int32_t hb = g_handbackCount;
        g_handbackCount = 0;
        LeaveCriticalSection(&g_netCs);
        for (int32_t i = 0; i < hb; i++) g_watch[g_watchCount++] = g_handback[i];
    }

    /* Shutting down: everything still watched is closed here, because nothing
     * else owns it. */
    for (int32_t i = 0; i < g_watchCount; i++) aowl_conn_drop(g_watch[i]);
    g_watchCount = 0;
    return 0;
}

/* Take the port before doing anything else, and hold it.
 *
 * This is the whole of the fix for a startup that discovered the collision
 * last. `aowl_net_serve` used to be the first thing that touched a socket, and
 * it runs after the routes are registered and after every mod's `on_load` --
 * so a port that was already taken produced a log that reads as a hundred and
 * fifty lines of a healthy server followed by one line of failure at the
 * bottom, which is exactly the shape of a log that gets blamed on the last mod
 * that spoke. `aowlspt-verify` had it right from the start: say the port is
 * free before claiming anything else is.
 *
 * The socket is kept in `g_listenSock` and `aowl_net_serve` adopts it, so the
 * port is held continuously from here to the serve loop. Nothing between the
 * two can lose it to another process. */
static int32_t aowl_net_reserve(int32_t port) {
    if (!aowl_net_startup()) return 0;
    if (g_listenSock) return 1;
    g_listenSock = aowl_net_bind(port);
    return g_listenSock ? 1 : 0;
}

/* Open the second, always-plain listener on `port`. See `g_listenSock2` for
 * why it exists.
 *
 * Bind *and* listen here, unlike the main socket, which splits the two so a
 * port collision is refused before the mods load. This one is opened at the
 * same moment the main serve starts, so there is nothing to gain by splitting
 * it -- and a failure here is not fatal to the server: the TLS listener still
 * answers `/client/*`, and the caller reports the loss of the asset route
 * rather than refusing to start. Returns 0 on any failure, having left
 * `g_listenSock2` at 0 so the poller simply never watches it.
 *
 * Safe to call before or after `aowl_net_serve*`: the poller re-reads
 * `g_listenSock2` at the top of every wakeup. Calling it before is what the
 * backend does, so the port is answering from the first accept. */
static int32_t aowl_net_listen_plain(int32_t port) {
    if (!aowl_net_startup()) return 0;
    if (g_listenSock2) return 1;
    uint64_t s = aowl_net_bind(port);
    if (!s) return 0;
    if (!aowl_net_listen_on(s, 128)) {
        closesocket((SOCKET)s);
        return 0;
    }
    aowl_net_set_nonblocking((SOCKET)s);
    g_listenSock2 = s;
    return 1;
}

/* Which process is listening on a loopback TCP port, if that can be found out.
 *
 * Worth the code because of what the answer nearly always is. SPT's server
 * defaults to 6969, an SPT install is mandatory for the database import, and
 * so *every* user who leaves SPT running meets this collision. "Port 6969 is
 * in use" sends them looking; "SPT.Server.exe is holding it" does not.
 *
 * `iphlpapi.dll` is loaded at run time rather than linked, for the reason
 * `aowllaunch.nim` loads winsock that way: the build rule that compiles this
 * translation unit lives in `tools/aowl.nim` and passes `-lws2_32 -lz` and
 * nothing else, and one `GetProcAddress` on a path that only runs when the
 * server is about to exit is cheaper than a link-flag change every caller
 * would have to make.
 *
 * Every step of this is allowed to fail and the failures are not equivalent,
 * which is why the pid and the path are reported separately. The table lookup
 * needs no privilege and nearly always works. `OpenProcess` on a service, or
 * on a process owned by another user, legitimately does not -- so a caller can
 * get a pid with no path, and must say only what it actually learned. Nothing
 * here guesses a name from a port number.
 *
 * Returns the owning pid, or 0 if it could not be determined. `out` receives
 * the full image path, or an empty string. */
static int32_t aowl_net_port_holder(int32_t port, char* out, int32_t outLen) {
    typedef DWORD (WINAPI *AowlGetExtTcpTable)(PVOID, PDWORD, BOOL, ULONG,
                                               ULONG, ULONG);
    typedef BOOL (WINAPI *AowlQueryImageName)(HANDLE, DWORD, LPSTR, PDWORD);
    /* Declared here rather than by including <iphlpapi.h>: the two fields this
     * reads have been stable since Windows XP SP2, and the header drags in a
     * dependency the build does not otherwise have. */
    typedef struct {
        DWORD dwState;
        DWORD dwLocalAddr;
        DWORD dwLocalPort;
        DWORD dwRemoteAddr;
        DWORD dwRemotePort;
        DWORD dwOwningPid;
    } AowlTcpRowOwnerPid;
    typedef struct {
        DWORD dwNumEntries;
        AowlTcpRowOwnerPid table[1];
    } AowlTcpTableOwnerPid;

    if (out && outLen > 0) out[0] = 0;

    HMODULE ip = LoadLibraryA("iphlpapi.dll");
    if (!ip) return 0;
    AowlGetExtTcpTable getTable =
        (AowlGetExtTcpTable)(void*)GetProcAddress(ip, "GetExtendedTcpTable");
    if (!getTable) { FreeLibrary(ip); return 0; }

    DWORD pid = 0;
    DWORD size = 0;
    /* 3 is `TCP_TABLE_OWNER_PID_LISTENER`. Listeners only: a client socket
     * with an ephemeral local port equal to ours is not what is holding it. */
    if (getTable(NULL, &size, FALSE, AF_INET, 3, 0) == ERROR_INSUFFICIENT_BUFFER
        && size > 0) {
        char* buf = (char*)malloc((size_t)size);
        if (buf) {
            if (getTable(buf, &size, FALSE, AF_INET, 3, 0) == NO_ERROR) {
                AowlTcpTableOwnerPid* t = (AowlTcpTableOwnerPid*)buf;
                unsigned short want = htons((unsigned short)port);
                for (DWORD i = 0; i < t->dwNumEntries; i++) {
                    if ((unsigned short)(t->table[i].dwLocalPort & 0xFFFF)
                        == want) {
                        pid = t->table[i].dwOwningPid;
                        break;
                    }
                }
            }
            free(buf);
        }
    }
    FreeLibrary(ip);
    if (!pid) return 0;

    /* `PROCESS_QUERY_LIMITED_INFORMATION`, which is the access right that
     * works across an integrity boundary for exactly this question. */
    HANDLE h = OpenProcess(0x1000, FALSE, pid);
    if (h) {
        HMODULE k32 = GetModuleHandleA("kernel32.dll");
        AowlQueryImageName q = k32
            ? (AowlQueryImageName)(void*)GetProcAddress(
                  k32, "QueryFullProcessImageNameA")
            : NULL;
        if (q && out && outLen > 1) {
            DWORD n = (DWORD)(outLen - 1);
            if (q(h, 0, out, &n)) out[n] = 0;
            else out[0] = 0;
        }
        CloseHandle(h);
    }
    return (int32_t)pid;
}

static int32_t aowl_net_serve_impl(int32_t port, int32_t workers) {
    if (!aowl_net_startup()) return 0;

    InitializeCriticalSection(&g_netCs);
    InitializeCriticalSection(&g_wsCs);
    g_freeCount = 0;
    for (int32_t i = AOWL_NET_MAX_CONNS - 1; i >= 0; i--) {
        g_conns[i].s = INVALID_SOCKET;
        g_conns[i].buf = NULL;
        g_conns[i].inUse = 0;
        g_conns[i].ssl = NULL;
        g_conns[i].tlsUp = 0;
        g_conns[i].tlsWantWrite = 0;
        g_conns[i].ws = 0;
        g_conns[i].wsTicket = 0;
        g_conns[i].wsMsg = NULL;
        g_conns[i].wsMsgCap = 0;
        g_conns[i].wsMsgLen = 0;
        g_conns[i].wsMsgOp = 0;
        g_conns[i].wsPendLen = 0;
        g_conns[i].wsClosing = 0;
        g_conns[i].wsOut = NULL;
        g_conns[i].wsOutLen = 0;
        g_conns[i].wsOutCap = 0;
        g_freeList[g_freeCount++] = i;
    }
    g_readyCount = 0;
    g_handbackCount = 0;
    g_watchCount = 0;
    g_bufBytes = 0;

    if (!aowl_wake_open()) return 0;
    g_readySem = CreateSemaphore(NULL, 0, AOWL_NET_MAX_CONNS, NULL);
    if (!g_readySem) return 0;

    /* Adopt the socket `aowl_net_reserve` bound, if there is one. The bind is
     * where a port collision is refused and that has already happened by now;
     * all that is left is to start listening on it. A caller that never
     * reserved (`tests/ws_stall.c`, and anything else that calls this
     * directly) still gets the bind here. */
    if (g_listenSock) {
        if (!aowl_net_listen_on(g_listenSock, 128)) {
            closesocket((SOCKET)g_listenSock);
            g_listenSock = 0;
            return 0;
        }
    } else {
        g_listenSock = aowl_net_listen(port, 128);
        if (!g_listenSock) return 0;
    }
    aowl_net_set_nonblocking((SOCKET)g_listenSock);

    if (workers < 1) workers = 1;
    if (workers > AOWL_NET_WORKERS) workers = AOWL_NET_WORKERS;

    InterlockedExchange(&g_netRunning, 1);
    g_workerCount = 0;
    for (int32_t i = 0; i < workers; i++) {
        HANDLE t = CreateThread(NULL, 0, aowl_net_worker, NULL, 0, NULL);
        if (t) g_workers[g_workerCount++] = t;
    }
    g_pollThread = CreateThread(NULL, 0, aowl_net_poller, NULL, 0, NULL);
    if (!g_pollThread || g_workerCount == 0) {
        InterlockedExchange(&g_netRunning, 0);
        return 0;
    }
    return 1;
}

/* Plain HTTP -- the default, and the one the test suites speak. `g_tlsMode` is
 * cleared so every accepted connection stays a raw socket and the read/send
 * helpers take the untouched `recv`/`send` path. */
static int32_t aowl_net_serve(int32_t port, int32_t workers) {
    g_tlsMode = 0;
    return aowl_net_serve_impl(port, workers);
}

/* HTTPS. The server `SSL_CTX` is built from the PEM cert+key first, so a bad or
 * missing certificate fails the start with a nameable reason (`aowl_tls_error`)
 * rather than after the listen. Once it is up every accepted connection carries
 * a TLS handshake and `SSL_read`/`SSL_write`, and the HTTP loop above runs
 * unchanged over the decrypted stream. Returns 0 without starting anything if
 * the context cannot be built. */
static int32_t aowl_net_serve_tls(int32_t port, int32_t workers,
                                  const char* certPath, const char* keyPath) {
    if (!aowl_tls_server_init(certPath, keyPath)) return 0;
    g_tlsMode = 1;
    if (!aowl_net_serve_impl(port, workers)) {
        g_tlsMode = 0;
        return 0;
    }
    return 1;
}

/* Whether the OpenSSL DLLs and a server context are in hand, and the last
 * reason they were not -- so the backend can turn a failed `--tls` start into a
 * diagnostic. `aowl_tls_error` is defined in `aowlspt_tls.h`. */
static int32_t aowl_net_tls_ready(void) { return g_tls.ctx != NULL ? 1 : 0; }
static const char* aowl_net_tls_error(void) { return aowl_tls_error(); }
static int32_t aowl_net_tls_error_len(void) { return (int32_t)strlen(aowl_tls_error()); }

/* Generate a self-signed cert+key with `openssl.exe` if they are not already
 * there. Exposed for the backend's startup step; see `aowlspt_tls.h`. */
static int32_t aowl_net_tls_gencert(const char* openssl, const char* certPath,
                                    const char* keyPath) {
    return (int32_t)aowl_tls_gencert(openssl, certPath, keyPath);
}

static void aowl_net_stop(void) {
    InterlockedExchange(&g_netRunning, 0);
    /* Closing the listening socket and poking the wake socket is what gets the
     * poller out of `WSAPoll`; releasing the semaphore once per worker is what
     * gets the workers out of their wait. */
    if (g_listenSock) {
        closesocket((SOCKET)g_listenSock);
        g_listenSock = 0;
    }
    if (g_listenSock2) {
        closesocket((SOCKET)g_listenSock2);
        g_listenSock2 = 0;
    }
    aowl_wake_poller();
    if (g_pollThread) {
        WaitForSingleObject(g_pollThread, 2000);
        CloseHandle(g_pollThread);
        g_pollThread = NULL;
    }
    if (g_readySem) ReleaseSemaphore(g_readySem, g_workerCount, NULL);
    for (int32_t i = 0; i < g_workerCount; i++) {
        WaitForSingleObject(g_workers[i], 2000);
        CloseHandle(g_workers[i]);
    }
    g_workerCount = 0;
    if (g_wakeWrite != INVALID_SOCKET) {
        closesocket(g_wakeWrite);
        g_wakeWrite = INVALID_SOCKET;
    }
    if (g_wakeRead != INVALID_SOCKET) {
        closesocket(g_wakeRead);
        g_wakeRead = INVALID_SOCKET;
    }
}

static int32_t aowl_net_running(void) {
    return InterlockedCompareExchange(&g_netRunning, 1, 1) == 1 ? 1 : 0;
}

/* ------------------------------------------------------------------ *
 * zlib
 * ------------------------------------------------------------------ */

static int32_t aowl_zlib_bound(int32_t srcLen) {
    return (int32_t)compressBound((uLong)srcLen) + 32;
}

/* Returns the number of bytes written, or -1. */
/* Deflate at level 6, reusing one z_stream per thread.
 *
 * This was `compress2`, which is `deflateInit2` + `deflate` + `deflateEnd` per
 * call — and `deflateInit2` at level 6 allocates the window, the hash chains
 * and the pending buffer every time, around a quarter of a megabyte of
 * malloc-and-free to compress a one-kilobyte response. Measured on the
 * backend's own load generator that was ~95 us per small response, against a
 * few microseconds for the deflate itself, and small responses are almost
 * every response: the large static tables are served out of a compressed-body
 * cache, so each distinct body reaches this once and comes from the cache after
 * that. (This used to say they never reach it at all. The cache is a
 * miss-through -- a miss, and anything under its 8 KiB floor, falls straight
 * through to the deflate.) What reaches it repeatedly is the item moves and the
 * keepalives.
 *
 * `deflateReset` restores the stream to exactly the state `deflateInit2` left
 * it in, so the bytes on the wire are identical to what `compress2` produced.
 * That is not a nicety here: the client is a game, this is its transport, and
 * a compression change is not something that can be tested by reading the
 * response back.
 *
 * Thread-local rather than locked, because the backend deflates on all sixteen
 * of its request workers at once and a lock here would serialise exactly the
 * path this is meant to make cheap. This used to say "eight accept workers",
 * which is the shape this file was written to remove: `AOWL_NET_WORKERS` is 16
 * and a worker takes a complete request off the poller rather than calling
 * `accept`. The state is never `deflateEnd`ed — it lives for the life of the
 * thread, which is the life of the process for a pool worker; a quarter of a
 * megabyte per worker, so about four megabytes across the pool, is the price of
 * not paying for it per request.
 */
static _Thread_local z_stream aowl_zdef;
static _Thread_local int aowl_zdef_ready = 0;

static int32_t aowl_zlib_deflate(const void* src, int32_t srcLen,
                                 void* dst, int32_t dstCap) {
    if (!aowl_zdef_ready) {
        aowl_zdef.zalloc = Z_NULL;
        aowl_zdef.zfree = Z_NULL;
        aowl_zdef.opaque = Z_NULL;
        if (deflateInit(&aowl_zdef, 6) != Z_OK) {
            /* Fall back to the stateless call rather than failing the request:
             * a server that cannot answer because it could not allocate a
             * compression context is a worse outcome than a slow answer. */
            uLongf out = (uLongf)dstCap;
            int rc = compress2((Bytef*)dst, &out, (const Bytef*)src,
                               (uLong)srcLen, 6);
            return rc == Z_OK ? (int32_t)out : -1;
        }
        aowl_zdef_ready = 1;
    } else if (deflateReset(&aowl_zdef) != Z_OK) {
        return -1;
    }
    aowl_zdef.next_in = (Bytef*)src;
    aowl_zdef.avail_in = (uInt)srcLen;
    aowl_zdef.next_out = (Bytef*)dst;
    aowl_zdef.avail_out = (uInt)dstCap;
    if (deflate(&aowl_zdef, Z_FINISH) != Z_STREAM_END) {
        /* The only way here is a destination smaller than `deflateBound`, and
         * every caller sizes from `aowl_zlib_bound`. Reset so the next call on
         * this thread does not inherit a half-finished stream. */
        deflateReset(&aowl_zdef);
        return -1;
    }
    return (int32_t)aowl_zdef.total_out;
}

static int32_t aowl_zlib_inflate(const void* src, int32_t srcLen,
                                 void* dst, int32_t dstCap) {
    uLongf out = (uLongf)dstCap;
    int rc = uncompress((Bytef*)dst, &out, (const Bytef*)src, (uLong)srcLen);
    return rc == Z_OK ? (int32_t)out : -1;
}

/* Whether a body looks zlib-framed.
 *
 * The client always compresses, but the tools people debug with do not, and a
 * server that inflates unconditionally answers a hand-written request with an
 * empty body and a confusing log line. The check is the two-byte zlib header:
 * CMF low nibble 8 (deflate), and (CMF<<8 | FLG) a multiple of 31. */
static int32_t aowl_zlib_looks_framed(const void* p, int32_t len) {
    const unsigned char* b = (const unsigned char*)p;
    if (len < 2) return 0;
    if ((b[0] & 0x0F) != 8) return 0;
    return (((unsigned)b[0] << 8) | b[1]) % 31 == 0 ? 1 : 0;
}

#endif /* AOWLSPT_NET_H */
