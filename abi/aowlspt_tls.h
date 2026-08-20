/* aowlspt_tls.h -- a TLS transport shim under the backend's HTTP loop.
 *
 * Post-1.0 Escape From Tarkov talks to its backend over HTTPS on port 443 and
 * *disables* certificate validation, so a self-signed cert is accepted. The
 * emulator's poller in `aowlspt_net.h` speaks plain HTTP over raw Winsock; this
 * header is the transport underneath it. When the server is started in TLS mode
 * every accepted connection gets an OpenSSL `SSL` handle, the handshake is
 * driven from the same `WSAPoll` loop, and `SSL_read`/`SSL_write` replace
 * `recv`/`send`. Nothing above the byte stream changes: the framing, the router,
 * the database and every composed byte are still the nimony above.
 *
 * ------------------------------------------------------------------------
 * Why the DLLs are loaded by name rather than linked
 * ------------------------------------------------------------------------
 *
 * OpenSSL 3 ships as `libssl-3-x64.dll` + `libcrypto-3-x64.dll` in the msys2
 * ucrt64 toolchain this repo builds with. Linking `-lssl` would need the import
 * library on the machine that *links*, and would make the two DLLs a hard load
 * dependency of `aowlspt-backend.exe` -- so a copy without them beside the exe
 * or on `PATH` would fail to start at all, before it could say why. Loading them
 * by name at runtime is the same idiom `aowlspt_overlay.h` uses for WinHTTP and
 * `aowlspt_net.h`/`aowllaunch` use for ws2_32/iphlpapi: a plain-HTTP test build
 * never touches OpenSSL, and a `--tls` run that cannot find the DLLs reports it.
 *
 * ------------------------------------------------------------------------
 * How want-read / want-write fold into the existing poll loop
 * ------------------------------------------------------------------------
 *
 * The poller and the workers already understand exactly one "not now" signal:
 * `recv`/`send` returning < 0 with `WSAGetLastError() == WSAEWOULDBLOCK`. So the
 * one-shot read/write helpers here translate OpenSSL's `SSL_ERROR_WANT_READ` and
 * `SSL_ERROR_WANT_WRITE` into precisely that -- they set `WSAEWOULDBLOCK` and
 * return -1 -- and translate a clean TLS close into a 0 return, the same shape a
 * peer's orderly `recv` == 0 already has. That is what lets the transport swap
 * be a handful of call-site substitutions in `aowlspt_net.h` rather than a
 * rewrite of its state machine: every existing `WSAEWOULDBLOCK` branch, every
 * deadline, every re-poll is reused unchanged. The one signal that has no
 * `recv`/`send` analogue is a handshake that wants the socket *writable* -- a
 * non-blocking `SSL_do_handshake` mid-flight -- and for that the poller adds
 * `POLLWRNORM` to that one connection's poll events until the handshake settles.
 *
 * A blocking hot-read (a worker with `SO_RCVTIMEO` set to the grace window) is
 * the one place `WSAEWOULDBLOCK` must *not* be synthesised: there OpenSSL's read
 * bottoms out in a blocking `recv` that times out with `WSAETIMEDOUT`, which the
 * worker reads as "hand the connection back", so a `SSL_ERROR_SYSCALL` leaves
 * `WSAGetLastError` exactly as the underlying transport set it.
 */

#ifndef AOWLSPT_TLS_H
#define AOWLSPT_TLS_H

#if !defined(_WIN32_WINNT) || (_WIN32_WINNT < 0x0600)
#  undef _WIN32_WINNT
#  define _WIN32_WINNT 0x0600
#endif

#include <winsock2.h>
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

/* A file tracer for diagnosing the TLS/keep-alive path against a real client.
 * Off unless the environment variable AOWL_NET_TRACE names a file; then every
 * accept/handshake/read/serve step is appended there with a millisecond stamp.
 * This is the only way to see, from the server side, whether the post-1.0
 * client's next request ever reaches the socket at all -- the nimony REQ log
 * only fires once a request has been fully framed and dispatched. */
static FILE* g_aowl_trace = NULL;
static int   g_aowl_trace_init = 0;
static void aowl_trace(const char* fmt, ...) {
    if (!g_aowl_trace_init) {
        g_aowl_trace_init = 1;
        const char* p = getenv("AOWL_NET_TRACE");
        if (p && *p) g_aowl_trace = fopen(p, "a");
    }
    if (!g_aowl_trace) return;
    unsigned long long t = (unsigned long long)GetTickCount64();
    fprintf(g_aowl_trace, "[%llu] ", t);
    va_list ap; va_start(ap, fmt);
    vfprintf(g_aowl_trace, fmt, ap);
    va_end(ap);
    fputc('\n', g_aowl_trace);
    fflush(g_aowl_trace);
}

/* The OpenSSL constants we use, spelled out so no OpenSSL header is needed. */
#define AOWL_SSL_FILETYPE_PEM       1
#define AOWL_SSL_VERIFY_NONE        0
#define AOWL_SSL_ERROR_NONE         0
#define AOWL_SSL_ERROR_WANT_READ    2
#define AOWL_SSL_ERROR_WANT_WRITE   3
#define AOWL_SSL_ERROR_SYSCALL      5
#define AOWL_SSL_ERROR_ZERO_RETURN  6

typedef void*         (*aowl_pfn_meth)(void);
typedef void*         (*aowl_pfn_ctx_new)(void*);
typedef void          (*aowl_pfn_ctx_free)(void*);
typedef int           (*aowl_pfn_use_cert)(void*, const char*);
typedef int           (*aowl_pfn_use_key)(void*, const char*, int);
typedef int           (*aowl_pfn_check_key)(void*);
typedef void          (*aowl_pfn_set_verify)(void*, int, void*);
typedef void*         (*aowl_pfn_ssl_new)(void*);
typedef void          (*aowl_pfn_ssl_free)(void*);
typedef int           (*aowl_pfn_set_fd)(void*, int);
typedef void          (*aowl_pfn_set_accept)(void*);
typedef int           (*aowl_pfn_do_handshake)(void*);
typedef int           (*aowl_pfn_read)(void*, void*, int);
typedef int           (*aowl_pfn_write)(void*, const void*, int);
typedef int           (*aowl_pfn_get_error)(void*, int);
typedef int           (*aowl_pfn_shutdown)(void*);
typedef int           (*aowl_pfn_pending)(void*);
typedef unsigned long (*aowl_pfn_err_get)(void);
typedef void          (*aowl_pfn_err_str)(unsigned long, char*, size_t);
typedef void          (*aowl_pfn_err_clear)(void);

static struct {
    int loaded;                 /* symbols resolved */
    HMODULE ssl;
    HMODULE crypto;
    void* ctx;                  /* the server SSL_CTX, once built */
    aowl_pfn_meth        TLS_server_method;
    aowl_pfn_ctx_new     SSL_CTX_new;
    aowl_pfn_ctx_free    SSL_CTX_free;
    aowl_pfn_use_cert    SSL_CTX_use_certificate_chain_file;
    aowl_pfn_use_key     SSL_CTX_use_PrivateKey_file;
    aowl_pfn_check_key   SSL_CTX_check_private_key;
    aowl_pfn_set_verify  SSL_CTX_set_verify;
    aowl_pfn_ssl_new     SSL_new;
    aowl_pfn_ssl_free    SSL_free;
    aowl_pfn_set_fd      SSL_set_fd;
    aowl_pfn_set_accept  SSL_set_accept_state;
    aowl_pfn_do_handshake SSL_do_handshake;
    aowl_pfn_read        SSL_read;
    aowl_pfn_write       SSL_write;
    aowl_pfn_get_error   SSL_get_error;
    aowl_pfn_shutdown    SSL_shutdown;
    aowl_pfn_pending     SSL_pending;
    aowl_pfn_err_get     ERR_get_error;
    aowl_pfn_err_str     ERR_error_string_n;
    aowl_pfn_err_clear   ERR_clear_error;
} g_tls;

static char g_tlsErr[256];

static void aowl_tls_set_err(const char* s) {
    size_t n = strlen(s);
    if (n >= sizeof(g_tlsErr)) n = sizeof(g_tlsErr) - 1;
    memcpy(g_tlsErr, s, n);
    g_tlsErr[n] = 0;
}

/* Drains the OpenSSL error queue into `g_tlsErr`, most recent first. */
static void aowl_tls_pop_err(const char* prefix) {
    char detail[200] = {0};
    if (g_tls.ERR_get_error && g_tls.ERR_error_string_n) {
        unsigned long e = g_tls.ERR_get_error();
        if (e) g_tls.ERR_error_string_n(e, detail, sizeof(detail));
    }
    _snprintf(g_tlsErr, sizeof(g_tlsErr) - 1, "%s%s%s", prefix,
              detail[0] ? ": " : "", detail);
    g_tlsErr[sizeof(g_tlsErr) - 1] = 0;
}

/* The last thing that went wrong, for a caller to log. Never NULL. */
static const char* aowl_tls_error(void) { return g_tlsErr[0] ? g_tlsErr : "no error"; }

/* Loads the two DLLs and resolves every symbol. Idempotent; returns 1 once
 * everything is in hand, 0 with `aowl_tls_error()` set otherwise.
 *
 * `LoadLibraryA` by bare name searches the standard order (the exe's directory,
 * then `PATH`), which is where a shipped copy of the DLLs beside the backend, or
 * the ucrt64 `bin` a developer already has on `PATH`, is found. The one explicit
 * fallback is the ucrt64 install this repo builds with, so a from-source run on
 * a dev box works without arranging anything. */
static int aowl_tls_load(void) {
    if (g_tls.loaded) return 1;
    g_tls.crypto = LoadLibraryA("libcrypto-3-x64.dll");
    g_tls.ssl = LoadLibraryA("libssl-3-x64.dll");
    if (!g_tls.crypto)
        g_tls.crypto = LoadLibraryA("C:\\msys64\\ucrt64\\bin\\libcrypto-3-x64.dll");
    if (!g_tls.ssl)
        g_tls.ssl = LoadLibraryA("C:\\msys64\\ucrt64\\bin\\libssl-3-x64.dll");
    if (!g_tls.crypto || !g_tls.ssl) {
        aowl_tls_set_err("could not load libssl-3-x64.dll / libcrypto-3-x64.dll "
                         "(put them beside aowlspt-backend.exe or on PATH)");
        return 0;
    }

#define AOWL_TLS_SYM(field, type, lib, name) \
    g_tls.field = (type)(void*)GetProcAddress(g_tls.lib, name); \
    if (!g_tls.field) { aowl_tls_set_err("missing OpenSSL symbol " name); return 0; }

    AOWL_TLS_SYM(TLS_server_method, aowl_pfn_meth, ssl, "TLS_server_method")
    AOWL_TLS_SYM(SSL_CTX_new, aowl_pfn_ctx_new, ssl, "SSL_CTX_new")
    AOWL_TLS_SYM(SSL_CTX_free, aowl_pfn_ctx_free, ssl, "SSL_CTX_free")
    AOWL_TLS_SYM(SSL_CTX_use_certificate_chain_file, aowl_pfn_use_cert, ssl, "SSL_CTX_use_certificate_chain_file")
    AOWL_TLS_SYM(SSL_CTX_use_PrivateKey_file, aowl_pfn_use_key, ssl, "SSL_CTX_use_PrivateKey_file")
    AOWL_TLS_SYM(SSL_CTX_check_private_key, aowl_pfn_check_key, ssl, "SSL_CTX_check_private_key")
    AOWL_TLS_SYM(SSL_CTX_set_verify, aowl_pfn_set_verify, ssl, "SSL_CTX_set_verify")
    AOWL_TLS_SYM(SSL_new, aowl_pfn_ssl_new, ssl, "SSL_new")
    AOWL_TLS_SYM(SSL_free, aowl_pfn_ssl_free, ssl, "SSL_free")
    AOWL_TLS_SYM(SSL_set_fd, aowl_pfn_set_fd, ssl, "SSL_set_fd")
    AOWL_TLS_SYM(SSL_set_accept_state, aowl_pfn_set_accept, ssl, "SSL_set_accept_state")
    AOWL_TLS_SYM(SSL_do_handshake, aowl_pfn_do_handshake, ssl, "SSL_do_handshake")
    AOWL_TLS_SYM(SSL_read, aowl_pfn_read, ssl, "SSL_read")
    AOWL_TLS_SYM(SSL_write, aowl_pfn_write, ssl, "SSL_write")
    AOWL_TLS_SYM(SSL_get_error, aowl_pfn_get_error, ssl, "SSL_get_error")
    AOWL_TLS_SYM(SSL_shutdown, aowl_pfn_shutdown, ssl, "SSL_shutdown")
    AOWL_TLS_SYM(SSL_pending, aowl_pfn_pending, ssl, "SSL_pending")
    AOWL_TLS_SYM(ERR_get_error, aowl_pfn_err_get, crypto, "ERR_get_error")
    AOWL_TLS_SYM(ERR_error_string_n, aowl_pfn_err_str, crypto, "ERR_error_string_n")
    AOWL_TLS_SYM(ERR_clear_error, aowl_pfn_err_clear, crypto, "ERR_clear_error")
#undef AOWL_TLS_SYM

    g_tls.loaded = 1;
    return 1;
}

/* Builds the long-lived server `SSL_CTX` from a PEM cert chain and key. Returns
 * 1 on success; 0 with `aowl_tls_error()` set if a file is missing, unreadable,
 * or the key does not match the certificate. Verification is off -- a server
 * that does not ask the client for a certificate, which is what an ordinary
 * HTTPS endpoint is. */
static int aowl_tls_server_init(const char* certPath, const char* keyPath) {
    if (!aowl_tls_load()) return 0;
    if (g_tls.ctx) return 1;    /* already built */
    void* meth = g_tls.TLS_server_method();
    void* ctx = g_tls.SSL_CTX_new(meth);
    if (!ctx) { aowl_tls_pop_err("SSL_CTX_new failed"); return 0; }
    g_tls.SSL_CTX_set_verify(ctx, AOWL_SSL_VERIFY_NONE, NULL);
    if (g_tls.SSL_CTX_use_certificate_chain_file(ctx, certPath) != 1) {
        aowl_tls_pop_err("could not load the TLS certificate");
        g_tls.SSL_CTX_free(ctx);
        return 0;
    }
    if (g_tls.SSL_CTX_use_PrivateKey_file(ctx, keyPath, AOWL_SSL_FILETYPE_PEM) != 1) {
        aowl_tls_pop_err("could not load the TLS private key");
        g_tls.SSL_CTX_free(ctx);
        return 0;
    }
    if (g_tls.SSL_CTX_check_private_key(ctx) != 1) {
        aowl_tls_pop_err("the TLS key does not match the certificate");
        g_tls.SSL_CTX_free(ctx);
        return 0;
    }
    g_tls.ctx = ctx;
    return 1;
}

/* A per-connection `SSL` in server (accept) role over an accepted socket.
 * Returns NULL if the context is not built or OpenSSL is out of memory. */
static void* aowl_tls_accept_new(SOCKET s) {
    if (!g_tls.ctx) return NULL;
    void* ssl = g_tls.SSL_new(g_tls.ctx);
    if (!ssl) return NULL;
    if (g_tls.SSL_set_fd(ssl, (int)s) != 1) { g_tls.SSL_free(ssl); return NULL; }
    g_tls.SSL_set_accept_state(ssl);
    return ssl;
}

/* Drive (or resume) the server handshake on a non-blocking socket.
 *   1  -> complete
 *   0  -> want read  (re-poll for readable)
 *   2  -> want write (re-poll for writable)
 *  -1  -> fatal */
static int aowl_tls_do_handshake(void* ssl) {
    g_tls.ERR_clear_error();
    int r = g_tls.SSL_do_handshake(ssl);
    if (r == 1) return 1;
    int e = g_tls.SSL_get_error(ssl, r);
    if (e == AOWL_SSL_ERROR_WANT_READ) return 0;
    if (e == AOWL_SSL_ERROR_WANT_WRITE) return 2;
    return -1;
}

/* One `SSL_read`, shaped exactly like `recv`: >0 bytes, 0 for a closed stream,
 * -1 with `WSAEWOULDBLOCK` for "not now", -1 with the transport's own error
 * otherwise. See the header comment for why a syscall error keeps the underlying
 * `WSAGetLastError` (the blocking hot-read reads `WSAETIMEDOUT` off it). */
static int aowl_tls_read_once(void* ssl, void* buf, int len) {
    g_tls.ERR_clear_error();
    int n = g_tls.SSL_read(ssl, buf, len);
    if (n > 0) return n;
    int e = g_tls.SSL_get_error(ssl, n);
    if (e == AOWL_SSL_ERROR_WANT_READ || e == AOWL_SSL_ERROR_WANT_WRITE) {
        WSASetLastError(WSAEWOULDBLOCK);
        return -1;
    }
    if (e == AOWL_SSL_ERROR_ZERO_RETURN) return 0;
    if (e == AOWL_SSL_ERROR_SYSCALL) {
        if (n == 0) return 0;   /* unexpected EOF before close_notify */
        return -1;              /* leave WSAGetLastError as the transport set it */
    }
    WSASetLastError(WSAECONNRESET);
    return -1;
}

/* One `SSL_write`, shaped exactly like `send`: >0 accepted, -1 with
 * `WSAEWOULDBLOCK` when the record layer wants the socket, -1 with a fatal error
 * otherwise. TLS 1.3 write rarely wants read; both wants map to would-block so
 * the caller's re-poll handles either. */
static int aowl_tls_write_once(void* ssl, const void* buf, int len) {
    g_tls.ERR_clear_error();
    int n = g_tls.SSL_write(ssl, buf, len);
    if (n > 0) return n;
    int e = g_tls.SSL_get_error(ssl, n);
    if (e == AOWL_SSL_ERROR_WANT_READ || e == AOWL_SSL_ERROR_WANT_WRITE) {
        WSASetLastError(WSAEWOULDBLOCK);
        return -1;
    }
    WSASetLastError(WSAECONNRESET);
    return -1;
}

/* Decrypted-and-buffered bytes inside OpenSSL that a raw socket poll cannot see.
 * The read helpers drain these before returning would-block, so the poller never
 * strands them; this is exposed only for a diagnostic. */
static int aowl_tls_pending(void* ssl) {
    return ssl ? g_tls.SSL_pending(ssl) : 0;
}

/* close_notify (one shot, never blocks the caller) then free the handle. The
 * socket itself is closed by the connection owner, right after this. */
static void aowl_tls_conn_free(void* ssl) {
    if (!ssl || !g_tls.loaded) return;
    g_tls.SSL_shutdown(ssl);
    g_tls.SSL_free(ssl);
}

/* Run a command line to completion, hidden, and return its exit code (or -1 if
 * the process could not be started). Used only for the one-time self-signed
 * certificate generation via `openssl.exe`; nothing on the request path spawns
 * anything. */
static int aowl_tls_spawn(const char* cmdline) {
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    char* cmd = _strdup(cmdline);   /* CreateProcessA may write to the buffer */
    if (!cmd) return -1;
    BOOL ok = CreateProcessA(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                             NULL, NULL, &si, &pi);
    free(cmd);
    if (!ok) return -1;
    WaitForSingleObject(pi.hProcess, 60000);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)code;
}

/* Generate a self-signed cert+key with `openssl.exe`. `openssl` is the program
 * (a bare "openssl" to search PATH, or a full path); `cert`/`key` are the PEM
 * output paths. Any CN is fine -- the client does not validate -- so localhost
 * is used. Returns openssl's exit code, or -1 if it could not be run. */
static int aowl_tls_gencert(const char* openssl, const char* cert, const char* key) {
    char cmd[2048];
    _snprintf(cmd, sizeof(cmd) - 1,
              "\"%s\" req -x509 -newkey rsa:2048 -keyout \"%s\" -out \"%s\" "
              "-days 3650 -nodes -subj \"/CN=localhost\"",
              openssl, key, cert);
    cmd[sizeof(cmd) - 1] = 0;
    return aowl_tls_spawn(cmd);
}

#endif /* AOWLSPT_TLS_H */
