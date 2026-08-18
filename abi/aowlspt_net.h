/* aowlspt_net.h — sockets and zlib for the backend server.
 *
 * nimony's `nativesocket` is a 26-line stub and `winlean` has no socket
 * surface at all, so the syscalls live here, like every other place this repo
 * has to reach something nimony cannot. Everything above `recv` — parsing,
 * routing, the database, the mod API — is nimony.
 *
 * The zlib part is not optional decoration. Tarkov's client sends and expects
 * **zlib-framed bodies**: a request body arrives deflated and a response must
 * be deflated too. A server that answers in plain JSON gets a client that
 * silently fails to parse it, and `curl` against such a server appears to work
 * while the game does not — which is exactly the trap `tools/SptProbe` exists
 * to document on the SPT side.
 *
 * Concurrency is a fixed pool of accept threads rather than one thread per
 * connection. Windows allows several threads to `accept` the same listening
 * socket, the pool size is the concurrency limit, and there is no per-request
 * thread creation on the hot path.
 *
 * The pool size is now the *connection* limit rather than the request limit:
 * the server speaks keep-alive, so a worker stays with a connection until the
 * client closes it or it goes idle. That is why the ceiling here is sixteen
 * rather than eight -- a game that opens a handful of connections and holds
 * them must not be able to exhaust the pool by itself.
 */

#ifndef AOWLSPT_NET_H
#define AOWLSPT_NET_H

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

/* Implemented in nimony: handed one accepted connection, returns when it has
 * finished with it. */
extern void aowlspt_nim_serve(uint64_t sock);

/* One lock, for the host's own mutable lists.
 *
 * Requests are served on a pool of threads, so anything a route handler can
 * reach that the serve loop also touches -- the timer queue is the one -- needs
 * a lock rather than an argument about how unlikely the interleaving is.
 * Initialised on first use under a one-time flag, because there is no point in
 * the host in the process where it could be initialised earlier. */
static CRITICAL_SECTION aowl_host_cs;
static LONG aowl_host_cs_state = 0; /* 0 unset, 1 initialising, 2 ready */

static void aowl_lock(void) {
    LONG was = InterlockedCompareExchange(&aowl_host_cs_state, 1, 0);
    if (was == 0) {
        InitializeCriticalSection(&aowl_host_cs);
        InterlockedExchange(&aowl_host_cs_state, 2);
    } else {
        while (InterlockedCompareExchange(&aowl_host_cs_state, 2, 2) != 2) {
            Sleep(0);
        }
    }
    EnterCriticalSection(&aowl_host_cs);
}

static void aowl_unlock(void) {
    if (InterlockedCompareExchange(&aowl_host_cs_state, 2, 2) == 2) {
        LeaveCriticalSection(&aowl_host_cs);
    }
}

static int32_t aowl_net_startup(void) {
    WSADATA wsa;
    return WSAStartup(MAKEWORD(2, 2), &wsa) == 0 ? 1 : 0;
}

static int32_t aowl_net_last_error(void) {
    return (int32_t)WSAGetLastError();
}

/* Binds to loopback only.
 *
 * That is a deliberate default rather than a placeholder: this backend serves
 * a single-player game on the machine it runs on, and a game server that
 * listens on every interface by accident is how a LAN party becomes an
 * incident. Nothing here takes an address argument, so there is no flag to get
 * wrong. */
static uint64_t aowl_net_listen(int32_t port, int32_t backlog) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return 0;

    /* Without SO_REUSEADDR a restart inside the TIME_WAIT window fails to
     * bind, which during development is most restarts. */
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char*)&yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(s, (struct sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
        closesocket(s);
        return 0;
    }
    if (listen(s, backlog) == SOCKET_ERROR) {
        closesocket(s);
        return 0;
    }
    return (uint64_t)s;
}

static uint64_t aowl_net_accept(uint64_t server) {
    SOCKET c = accept((SOCKET)server, NULL, NULL);
    return c == INVALID_SOCKET ? 0 : (uint64_t)c;
}

static int32_t aowl_net_recv(uint64_t sock, void* buf, int32_t len) {
    return (int32_t)recv((SOCKET)sock, (char*)buf, len, 0);
}

static int32_t aowl_net_send(uint64_t sock, const void* buf, int32_t len) {
    /* `send` may take fewer bytes than offered; looping here means callers do
     * not each have to remember that. */
    const char* p = (const char*)buf;
    int32_t sent = 0;
    while (sent < len) {
        int n = send((SOCKET)sock, p + sent, len - sent, 0);
        if (n <= 0) return -1;
        sent += n;
    }
    return sent;
}

static void aowl_net_close(uint64_t sock) {
    if (sock) closesocket((SOCKET)sock);
}

static void aowl_net_shutdown_recv(uint64_t sock) {
    if (sock) shutdown((SOCKET)sock, SD_RECEIVE);
}

/* Read with a deadline, so a client that opens a connection and says nothing
 * cannot hold a worker thread forever. */
static int32_t aowl_net_set_timeout(uint64_t sock, int32_t ms) {
    DWORD t = (DWORD)ms;
    return setsockopt((SOCKET)sock, SOL_SOCKET, SO_RCVTIMEO,
                      (const char*)&t, sizeof(t)) == 0 ? 1 : 0;
}

/* ------------------------------------------------------------------ *
 * The accept pool
 * ------------------------------------------------------------------ */

#define AOWL_NET_WORKERS 16

static uint64_t g_listenSock = 0;
static volatile LONG g_netRunning = 0;
static HANDLE g_workers[AOWL_NET_WORKERS];
static int32_t g_workerCount = 0;

static DWORD WINAPI aowl_net_worker(LPVOID param) {
    (void)param;
    while (InterlockedCompareExchange(&g_netRunning, 1, 1) == 1) {
        uint64_t c = aowl_net_accept(g_listenSock);
        if (!c) {
            if (InterlockedCompareExchange(&g_netRunning, 1, 1) != 1) break;
            continue;
        }
        aowl_net_set_timeout(c, 15000);
        aowlspt_nim_serve(c);
        aowl_net_close(c);
    }
    return 0;
}

static int32_t aowl_net_serve(int32_t port, int32_t workers) {
    if (!aowl_net_startup()) return 0;
    g_listenSock = aowl_net_listen(port, 64);
    if (!g_listenSock) return 0;

    if (workers < 1) workers = 1;
    if (workers > AOWL_NET_WORKERS) workers = AOWL_NET_WORKERS;

    InterlockedExchange(&g_netRunning, 1);
    g_workerCount = 0;
    for (int32_t i = 0; i < workers; i++) {
        HANDLE t = CreateThread(NULL, 0, aowl_net_worker, NULL, 0, NULL);
        if (t) g_workers[g_workerCount++] = t;
    }
    return g_workerCount > 0 ? 1 : 0;
}

static void aowl_net_stop(void) {
    InterlockedExchange(&g_netRunning, 0);
    /* Closing the listening socket is what wakes the threads out of `accept`;
     * there is no portable way to cancel one otherwise. */
    if (g_listenSock) {
        closesocket((SOCKET)g_listenSock);
        g_listenSock = 0;
    }
    for (int32_t i = 0; i < g_workerCount; i++) {
        WaitForSingleObject(g_workers[i], 2000);
        CloseHandle(g_workers[i]);
    }
    g_workerCount = 0;
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
static int32_t aowl_zlib_deflate(const void* src, int32_t srcLen,
                                 void* dst, int32_t dstCap) {
    uLongf out = (uLongf)dstCap;
    int rc = compress2((Bytef*)dst, &out, (const Bytef*)src, (uLong)srcLen, 6);
    return rc == Z_OK ? (int32_t)out : -1;
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
