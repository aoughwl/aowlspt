/* Can one websocket client stop the whole server?
 *
 *   gcc -O1 -I../abi -o ws_stall.exe ws_stall.c -lws2_32 -lz && ./ws_stall.exe
 *
 * `wstest` drives the notifier over the real wire and proves it works.
 * Everything in this file is about the arrangement `wstest` cannot build: a
 * worker inside `aowl_ws_send`, holding the one websocket write lock, while
 * the poller wants it for a pong.
 *
 * ## The shape of the failure
 *
 * `g_wsCs` is one critical section for *every* websocket. A worker takes it to
 * push a notification and holds it across the `send`, so a client that has
 * stopped reading holds it for as long as that send takes -- up to
 * `AOWL_WS_SEND_MS`, and again for the next push, and the next. The poller
 * takes the same lock: every pong, close and refusal it answers is composed by
 * nimony and handed back to `aowl_ws_send`. It used to take it by waiting.
 *
 * A poller that is waiting is not in `WSAPoll`. It is not accepting, not
 * reading any connection, and not enforcing any deadline. So the cost of one
 * notifier client that stops reading is not "that client's notifications are
 * late", it is **the whole HTTP server stops** -- which is the held-connection
 * starvation the poller was written to remove, rebuilt one lock further down.
 *
 * ## Asserting on answers rather than on survival
 *
 * The server survives this either way, so "it did not crash" is worth nothing.
 * What is measured instead is what a player would notice:
 *
 *   * **the slowest ordinary request** -- on a fresh connection, made every
 *     100 ms while the pushes are stuck. Each is a request the game makes
 *     constantly: an accept, a read, a route, an answer, and not a websocket
 *     anywhere in it. Against the header as it was they run to a quarter of a
 *     second and *every* request in the window pays it, because the poller is
 *     asleep on a lock and nothing is being accepted or read at all.
 *   * **late, but not lost** -- the second websocket's pong and the third's
 *     close must still arrive. Not waiting is only an improvement if the frame
 *     that could not be written is queued rather than dropped: a pong that
 *     vanishes is a client that thinks the server is gone, and a close that
 *     vanishes is a protocol the peer cannot see the end of. They are allowed
 *     to be late -- the lock really is busy and the bytes really cannot go out
 *     yet -- and they are not allowed to be missing.
 *
 * ## Two things this had to be built around
 *
 * **The stalled peer must not read at all.** A peer that reads even a byte at
 * a time is worse for the server and useless for the test: progress inside
 * `aowl_net_send_within` resets its deadline, so the hold stops being bounded
 * by `AOWL_WS_SEND_MS` at all -- but Windows also grows a receive buffer that
 * is being read from, and 64 MB then disappears into the kernel without the
 * send ever blocking. So the client here reads nothing, which puts a floor
 * under the hold (one `AOWL_WS_SEND_MS` per push, back to back) rather than
 * demonstrating its absence of a ceiling. The ceiling is absent all the same:
 * see the note on `AOWL_WS_SEND_MS` in the header.
 *
 * **The frames have to be big.** Loopback swallows about two megabytes before
 * a send blocks at all, so a notification-sized frame never stalls anything.
 * Four megabytes a push, which is smaller than the largest request this server
 * already accepts.
 *
 * ## What it caught
 *
 * Against the header as it was: every ordinary request made during the window
 * took about a quarter of a second, against single-digit milliseconds when
 * nothing is pushing. Against the header as it is: single-digit milliseconds
 * throughout, with the pong and the close still arriving once the pushes let
 * the lock go.
 *
 * It compiles against both, which is the point of it -- the one check that
 * names the new machinery is behind `#if defined(AOWL_WS_PEND_CAP)`, so the
 * same source runs against the code that fails it.
 */

#include <stdio.h>
#include "aowlspt_net.h"

/* ------------------------------------------------------------------ *
 * The nimony side, which this file plays
 * ------------------------------------------------------------------ *
 *
 * The real one is `aowlbackend.nim` over `websocket.nim`: it composes every
 * byte and hands it to `aowl_ws_send`. These do the same thing with the same
 * calls in the same order -- a 101 written before `aowl_ws_adopt`, a pong
 * composed inside `aowlspt_nim_ws_control` and sent from there -- because the
 * whole question is what happens on the thread that call arrives on.
 */

static int64_t g_ticketA = 0;      /* the client that never reads */
static int64_t g_ticketB = 0;      /* the client that pings */
static int64_t g_ticketC = 0;      /* the client that closes */

static int contains(const char* hay, int32_t n, const char* needle) {
    int32_t m = (int32_t)strlen(needle);
    for (int32_t i = 0; i + m <= n; i++)
        if (memcmp(hay + i, needle, (size_t)m) == 0) return 1;
    return 0;
}

int32_t aowlspt_nim_handle(uint64_t sock, void* buf, int32_t len,
                           int32_t headEnd, int32_t sep) {
    (void)headEnd; (void)sep;
    const char* p = (const char*)buf;
    if (contains(p, len, "Upgrade: websocket")) {
        const char* r = "HTTP/1.1 101 Switching Protocols\r\n"
                        "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
        aowl_net_send(sock, r, (int32_t)strlen(r));
        int64_t t = aowl_ws_adopt(sock);
        if (t == 0) return 0;
        if (contains(p, len, "/ws/a")) g_ticketA = t;
        else if (contains(p, len, "/ws/b")) g_ticketB = t;
        else g_ticketC = t;
        return 2;
    }
    const char* r = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    aowl_net_send(sock, r, (int32_t)strlen(r));
    return 1;
}

void aowlspt_nim_timeout(uint64_t sock, int32_t phase, int32_t have,
                         int32_t declared) {
    (void)sock; (void)phase; (void)have; (void)declared;
}

int32_t aowlspt_nim_ws_message(int64_t ticket, int32_t opcode, void* p,
                               int32_t len) {
    (void)ticket; (void)opcode; (void)p; (void)len;
    return 1;
}

void aowlspt_nim_ws_control(int64_t ticket, int32_t kind, int32_t code,
                            void* p, int32_t len) {
    char frame[160];
    int32_t n = 0;
    if (kind == 0) {
        /* A pong echoes the ping's payload, which is what makes a dropped or
         * mangled one visible: the client checks the bytes come back. */
        if (len > 125) len = 125;
        frame[0] = (char)0x8A;
        frame[1] = (char)len;
        if (len > 0) memcpy(frame + 2, p, (size_t)len);
        n = 2 + len;
    } else {
        int32_t status = (kind == 1) ? 1000 : code;
        frame[0] = (char)0x88;
        frame[1] = (char)2;
        frame[2] = (char)((status >> 8) & 0xFF);
        frame[3] = (char)(status & 0xFF);
        n = 4;
    }
    aowl_ws_send(ticket, frame, n);
}

int32_t aowlspt_nim_ws_idle(int64_t ticket, int32_t pinged) {
    if (pinged) return 0;
    char frame[2];
    frame[0] = (char)0x89;
    frame[1] = (char)0;
    aowl_ws_send(ticket, frame, 2);
    return 1;
}

void aowlspt_nim_ws_gone(int64_t ticket) { (void)ticket; }

/* ------------------------------------------------------------------ *
 * Clients
 * ------------------------------------------------------------------ */

static int g_port = 7127;
static int g_checks = 0;
static int g_fails = 0;

static void ok(const char* what, int cond) {
    g_checks++;
    if (!cond) g_fails++;
    printf("%s  %s\n", cond ? "ok   " : "FAIL ", what);
    fflush(stdout);
}

static SOCKET dial(void) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return s;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)g_port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) == SOCKET_ERROR) {
        closesocket(s);
        return INVALID_SOCKET;
    }
    DWORD to = 4000;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&to, sizeof(to));
    return s;
}

/* One byte at a time, so the handshake response is read and *nothing past it*
 * is: the client that stops reading has to leave the pushed frames in the
 * kernel, where they can fill. */
static int read_headers(SOCKET s) {
    char last[4] = {0, 0, 0, 0};
    for (int i = 0; i < 4096; i++) {
        char ch;
        int n = recv(s, &ch, 1, 0);
        if (n != 1) return 0;
        last[0] = last[1]; last[1] = last[2]; last[2] = last[3]; last[3] = ch;
        if (last[0] == '\r' && last[1] == '\n' && last[2] == '\r' &&
            last[3] == '\n') return 1;
    }
    return 0;
}

static SOCKET ws_open(const char* path) {
    SOCKET s = dial();
    if (s == INVALID_SOCKET) return s;
    char req[256];
    int n = sprintf(req,
                    "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                    "Sec-WebSocket-Version: 13\r\n\r\n", path);
    send(s, req, n, 0);
    if (!read_headers(s)) { closesocket(s); return INVALID_SOCKET; }
    return s;
}

/* A client frame is masked, always -- the server refuses one that is not, and
 * a test that sent unmasked frames would be testing the refusal instead. */
static void ws_client_frame(SOCKET s, int op, const char* body, int len) {
    char f[160];
    unsigned char mask[4] = {0x37, 0xfa, 0x21, 0x3d};
    f[0] = (char)(0x80 | op);
    f[1] = (char)(0x80 | len);
    memcpy(f + 2, mask, 4);
    for (int i = 0; i < len; i++)
        f[6 + i] = (char)((unsigned char)body[i] ^ mask[i & 3]);
    send(s, f, 6 + len, 0);
}

/* Reads one frame with a deadline. Returns the opcode, or -1. */
static int ws_read_frame(SOCKET s, char* out, int* outLen, int withinMs) {
    ULONGLONG deadline = GetTickCount64() + (ULONGLONG)withinMs;
    unsigned char hdr[2];
    int got = 0;
    DWORD to = 100;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&to, sizeof(to));
    while (got < 2) {
        if (GetTickCount64() >= deadline) return -1;
        int n = recv(s, (char*)hdr + got, 2 - got, 0);
        if (n > 0) { got += n; continue; }
        if (n == 0) return -1;
        if (WSAGetLastError() != WSAETIMEDOUT) return -1;
    }
    int op = hdr[0] & 0x0F;
    int len = hdr[1] & 0x7F;
    if (len > 125) return -1;                 /* nothing here sends one */
    got = 0;
    while (got < len) {
        if (GetTickCount64() >= deadline) return -1;
        int n = recv(s, out + got, len - got, 0);
        if (n > 0) { got += n; continue; }
        if (n == 0) return -1;
        if (WSAGetLastError() != WSAETIMEDOUT) return -1;
    }
    *outLen = len;
    return op;
}

/* One ordinary request on a fresh connection, timed. This is the measurement:
 * what every route the game calls costs while a websocket push is stuck, and
 * it never touches a websocket. */
static int http_once(int* ms) {
    ULONGLONG t0 = GetTickCount64();
    SOCKET s = dial();
    if (s == INVALID_SOCKET) { *ms = -1; return 0; }
    const char* req = "GET /status HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                      "Connection: close\r\n\r\n";
    send(s, req, (int)strlen(req), 0);
    char buf[512];
    int total = 0;
    int answered = 0;
    for (;;) {
        int n = recv(s, buf + total, (int)sizeof(buf) - 1 - total, 0);
        if (n <= 0) break;
        total += n;
        buf[total] = 0;
        if (strstr(buf, "\r\n\r\nok")) { answered = 1; break; }
        if (total >= (int)sizeof(buf) - 1) break;
    }
    closesocket(s);
    *ms = (int)(GetTickCount64() - t0);
    return answered;
}

/* ------------------------------------------------------------------ *
 * The worker that is stuck
 * ------------------------------------------------------------------ */

static volatile LONG g_pushing = 0;
static volatile LONG g_pushCalls = 0;
static volatile LONG g_pushWorst = 0;
static char* g_big = NULL;
static int32_t g_bigLen = 0;

/* `hostNotifyPush` reaches `aowl_ws_send` on exactly this kind of thread: a
 * request worker, answering a route, pushing a notification at a session. The
 * only thing unusual about this one is that it keeps doing it. */
static DWORD WINAPI push_thread(LPVOID p) {
    (void)p;
    while (InterlockedCompareExchange(&g_pushing, 1, 1) == 1) {
        ULONGLONG t0 = GetTickCount64();
        (void)aowl_ws_send(g_ticketA, g_big, g_bigLen);
        int took = (int)(GetTickCount64() - t0);
        InterlockedIncrement(&g_pushCalls);
        if (took > (int)InterlockedCompareExchange(&g_pushWorst, 0, 0))
            InterlockedExchange(&g_pushWorst, (LONG)took);
    }
    return 0;
}

static void make_big(void) {
    /* A realistic notification, not the 4 MB monster this once was. That size
     * existed to fill the socket buffer and force the old worker-side send to
     * *block* under the write lock -- the stall this test was written around.
     * There is no worker-side send any more: a push is appended to the
     * connection's `wsOut` (bounded by `AOWL_WS_OUT_CAP`) and the poller drains
     * it, so a frame larger than that bound is refused rather than queued, and a
     * 4 MB push would simply never reach the queue this now checks. Eight
     * kilobytes is above any notification the game makes and well inside the
     * bound, so the pushes go through the queue and the drain is exercised. */
    int32_t payload = 8 * 1024;
    g_bigLen = 10 + payload;
    g_big = (char*)malloc((size_t)g_bigLen);
    memset(g_big, 'x', (size_t)g_bigLen);
    g_big[0] = (char)0x82;                    /* fin, binary */
    g_big[1] = (char)127;                     /* 64-bit length */
    for (int k = 0; k < 8; k++)
        g_big[2 + k] = (char)((((int64_t)payload) >> (56 - 8 * k)) & 0xFF);
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc)
            g_port = atoi(argv[++i]);

    printf("\nA stalled websocket push and the rest of the server\n");
    printf("--------------------------------------------------\n");

    if (!aowl_net_serve(g_port, 16)) {
        printf("FAIL   the server would not start on port %d\n", g_port);
        return 1;
    }
    Sleep(100);
    make_big();

    int ms = 0;
    ok("the server answers an ordinary request", http_once(&ms));

    SOCKET a = ws_open("/ws/a");
    ok("the client that will not read upgraded", a != INVALID_SOCKET);
    SOCKET b = ws_open("/ws/b");
    ok("a second websocket upgraded", b != INVALID_SOCKET);
    SOCKET c = ws_open("/ws/c");
    ok("a third websocket upgraded", c != INVALID_SOCKET);
    Sleep(50);
    ok("all three were adopted",
       g_ticketA != 0 && g_ticketB != 0 && g_ticketC != 0);
    if (!g_ticketA || !g_ticketB || !g_ticketC) { aowl_net_stop(); return 1; }

    /* A worker starts pushing at the client that will not read. Each call
     * fills what loopback will hold and then waits `AOWL_WS_SEND_MS` for room
     * that never comes -- with the lock held, the whole time. */
    InterlockedExchange(&g_pushing, 1);
    HANDLE pt = CreateThread(NULL, 0, push_thread, NULL, 0, NULL);
    Sleep(600);

    /* And, while it is stuck, the other two websockets say something: a ping,
     * which the poller has to answer with a pong, and a close, which it has to
     * answer with a close. Both are composed by nimony and both come back to
     * `aowl_ws_send` on the poller thread. This is the call that used to put
     * the poller to sleep on the lock. */
    ws_client_frame(b, 0x9, "hi", 2);
    ws_client_frame(c, 0x8, "\x03\xe8", 2);

    /* Every 100 ms, an ordinary request on a fresh connection. */
    int worst = 0, made = 0, answered = 0;
    ULONGLONG until = GetTickCount64() + 2000;
    while (GetTickCount64() < until) {
        int t = 0;
        if (http_once(&t)) answered++;
        made++;
        if (t > worst) worst = t;
        Sleep(100);
    }
    int calls = (int)InterlockedCompareExchange(&g_pushCalls, 0, 0);
    int pushWorst = (int)InterlockedCompareExchange(&g_pushWorst, 0, 0);
    printf("      %d pushes into a client that will not read, "
           "the slowest taking %d ms\n", calls, pushWorst);
    /* The invariant is now the opposite of what it once was. A worker no longer
     * writes the socket at all: `aowl_ws_send` off the poller thread appends the
     * frame to the connection's `wsOut` and returns, so a push at a client that
     * will not read is a bounded memcpy, never a blocking send. It must not
     * approach `AOWL_WS_SEND_MS` -- if it does, a worker is waiting on a peer
     * somewhere it should not be, which is the concurrent-SSL hazard this
     * removed. */
    ok("a push at a client that will not read never blocks the worker",
       calls > 0 && pushWorst < 150);
    printf("      %d ordinary requests during the stall, slowest %d ms\n",
           made, worst);
    ok("every ordinary request during the stall was answered",
       made > 0 && answered == made);
    ok("and none of them waited behind the websocket lock (< 150 ms)",
       worst < 150);

    /* Let the pushes stop, and drain the client so the last one can finish. */
    InterlockedExchange(&g_pushing, 0);
    DWORD to = 200;
    setsockopt(a, SOL_SOCKET, SO_RCVTIMEO, (const char*)&to, sizeof(to));
    static char sink[65536];
    ULONGLONG drainUntil = GetTickCount64() + 2000;
    while (GetTickCount64() < drainUntil) {
        int n = recv(a, sink, (int)sizeof(sink), 0);
        if (n <= 0) break;
    }
    WaitForSingleObject(pt, 5000);
    CloseHandle(pt);

    /* Late is allowed. Lost is not. */
    char body[160];
    int blen = 0;
    int op = ws_read_frame(b, body, &blen, 4000);
    ok("the pong arrived", op == 0xA);
    ok("and it echoed the ping's payload",
       op == 0xA && blen == 2 && body[0] == 'h' && body[1] == 'i');
    op = ws_read_frame(c, body, &blen, 4000);
    ok("the close frame was not dropped", op == 0x8);
    ok("and it carried a status", op == 0x8 && blen == 2);

#if defined(AOWL_WS_OUT_CAP)
    /* The push went onto the connection's outbound queue -- the buffer a
     * non-poller thread appends to and the poller alone drains onto the wire.
     * That queue existing and having carried the pushes is the mechanism that
     * keeps a worker off the `SSL` handle the poller is reading. */
    printf("      %ld pushes went onto the outbound queue for the poller\n",
           (long)InterlockedCompareExchange(&g_wsQueued, 0, 0));
    ok("the outbound queue is what carried them",
       InterlockedCompareExchange(&g_wsQueued, 0, 0) > 0);
#else
    printf("      (this build has no outbound queue)\n");
#endif

    /* The server is unchanged. */
    ok("the server still answers an ordinary request", http_once(&ms));
    SOCKET d = ws_open("/ws/d");
    ok("a websocket still upgrades", d != INVALID_SOCKET);
    if (d != INVALID_SOCKET) closesocket(d);
    if (a != INVALID_SOCKET) closesocket(a);
    if (b != INVALID_SOCKET) closesocket(b);
    if (c != INVALID_SOCKET) closesocket(c);

    aowl_net_stop();
    printf("\n%s  %d checks, %d failures\n",
           g_fails == 0 ? "ok   " : "FAIL ", g_checks, g_fails);
    return g_fails == 0 ? 0 : 1;
}
