## One HTTP GET, on a thread of its own, so that neither a frame nor a request
## ever waits on the network.
##
## The manager is a backend mod: its route handlers run on the server's request
## threads and its timers run on the host's tick. A synchronous fetch in either
## place is a stall the length of somebody's DNS timeout — on the tick that is a
## dropped frame in the game, and on a request it is the mod panel hanging while
## it asks the internet a question. So nothing here blocks:
##
##     start(url, ...)   ->  a job, or a refusal, immediately
##     poll(job)         ->  running / done, immediately
##     take(job)         ->  the body, once and only once
##
## **The worker is C and touches nothing of nimony's.** `aowl_http_thread` runs
## on a thread the nimony runtime has never seen, so it allocates nothing, calls
## no nimony code, and writes only into a buffer the *starting* thread allocated
## for it with `malloc`. Everything nimony-shaped — the string, the JSON, the
## registry — happens back on the manager's own thread after `poll` says the
## flag flipped. A worker that touched a nimony string would be a data race
## against the allocator with a game running on the other side of it.
##
## **WinHTTP is loaded by name, not linked.** `aowl build-mod` passes no
## `--passL`, and adding one to the shared mod build to give the manager a
## network library would put winsock in the link line of every mod in the tree.
## `LoadLibraryA("winhttp.dll")` needs only kernel32, which is already there,
## and it fails *softly*: a machine without WinHTTP gets "winhttp.dll could not
## be loaded" and its existing registry, rather than a mod that will not load.
##
## **A job outliving the mod is handled here, not hoped about.** The manager can
## be unloaded while a fetch is in flight — that is the whole point of live mod
## control — and the worker would then write into a freed buffer. `release`
## marks an unfinished job abandoned and hands ownership to the worker, which
## frees it when it is done. The cost is one buffer living a few seconds longer
## than the mod did; the alternative is a use-after-free in a game process.
##
## `registryFetchTimeoutMs` bounds the **whole** fetch, not each operation:
## WinHTTP's own timeouts are per-call, and a server dribbling one byte at a
## time trips none of them. The worker checks a deadline in its read loop for
## that case, because "it timed out" has to mean something a person can predict.
##
## `file://` and plain paths never reach any of this: they are read with
## `readFile` on the calling thread, because a local read is bounded by the disk
## and there is nothing to be gained by making it asynchronous.

import std/syncio

{.emit: """
#include <windows.h>
#include <winhttp.h>
#include <stdlib.h>
#include <string.h>

/* WinHTTP by name. The typedefs are spelled out rather than taken from an
   import library so that nothing has to be added to the mod link line. */
typedef HINTERNET (WINAPI *aowl_wh_open_t)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
typedef HINTERNET (WINAPI *aowl_wh_connect_t)(HINTERNET, LPCWSTR, INTERNET_PORT, DWORD);
typedef HINTERNET (WINAPI *aowl_wh_openreq_t)(HINTERNET, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR*, DWORD);
typedef BOOL (WINAPI *aowl_wh_send_t)(HINTERNET, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, DWORD_PTR);
typedef BOOL (WINAPI *aowl_wh_recv_t)(HINTERNET, LPVOID);
typedef BOOL (WINAPI *aowl_wh_query_t)(HINTERNET, DWORD, LPCWSTR, LPVOID, LPDWORD, LPDWORD);
typedef BOOL (WINAPI *aowl_wh_read_t)(HINTERNET, LPVOID, DWORD, LPDWORD);
typedef BOOL (WINAPI *aowl_wh_avail_t)(HINTERNET, LPDWORD);
typedef BOOL (WINAPI *aowl_wh_close_t)(HINTERNET);
typedef BOOL (WINAPI *aowl_wh_timeouts_t)(HINTERNET, int, int, int, int);

static HMODULE            aowl_wh_lib = NULL;
static aowl_wh_open_t     aowl_wh_open = NULL;
static aowl_wh_connect_t  aowl_wh_connect = NULL;
static aowl_wh_openreq_t  aowl_wh_openreq = NULL;
static aowl_wh_send_t     aowl_wh_send = NULL;
static aowl_wh_recv_t     aowl_wh_recv = NULL;
static aowl_wh_query_t    aowl_wh_query = NULL;
static aowl_wh_read_t     aowl_wh_read = NULL;
static aowl_wh_avail_t    aowl_wh_avail = NULL;
static aowl_wh_close_t    aowl_wh_close = NULL;
static aowl_wh_timeouts_t aowl_wh_timeouts = NULL;

static int aowl_http_bind(void) {
  if (aowl_wh_lib != NULL) return 1;
  aowl_wh_lib = LoadLibraryA("winhttp.dll");
  if (aowl_wh_lib == NULL) return 0;
  aowl_wh_open     = (aowl_wh_open_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpOpen");
  aowl_wh_connect  = (aowl_wh_connect_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpConnect");
  aowl_wh_openreq  = (aowl_wh_openreq_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpOpenRequest");
  aowl_wh_send     = (aowl_wh_send_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpSendRequest");
  aowl_wh_recv     = (aowl_wh_recv_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpReceiveResponse");
  aowl_wh_query    = (aowl_wh_query_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpQueryHeaders");
  aowl_wh_read     = (aowl_wh_read_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpReadData");
  aowl_wh_avail    = (aowl_wh_avail_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpQueryDataAvailable");
  aowl_wh_close    = (aowl_wh_close_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpCloseHandle");
  aowl_wh_timeouts = (aowl_wh_timeouts_t)(void*)GetProcAddress(aowl_wh_lib, "WinHttpSetTimeouts");
  if (!aowl_wh_open || !aowl_wh_connect || !aowl_wh_openreq || !aowl_wh_send ||
      !aowl_wh_recv || !aowl_wh_query || !aowl_wh_read || !aowl_wh_avail ||
      !aowl_wh_close) {
    aowl_wh_lib = NULL;
    return 0;
  }
  return 1;
}

typedef struct AowlHttpJob {
  volatile LONG done;       /* 0 while the worker is running, 1 when it is not */
  volatile LONG abandoned;  /* the starter has gone; the worker owns the memory */
  int status;               /* HTTP status, or 0 when the transport failed */
  int truncated;            /* the body did not fit in `cap` */
  int len;
  int cap;
  int timeoutMs;
  int secure;
  int port;
  char error[256];
  char *body;
  wchar_t whost[512];
  wchar_t wpath[4096];
} AowlHttpJob;

static void aowl_http_fail(AowlHttpJob *j, const char *what, DWORD code) {
  char buf[256];
  /* Code 0 means "this is our own refusal, not Windows'". Printing
     "(windows error 0)" after a message we wrote ourselves invites somebody to
     go looking up an error number that does not exist. */
  if (code == 0) wsprintfA(buf, "%.220s", what);
  else wsprintfA(buf, "%.180s (windows error %lu)", what, (unsigned long)code);
  strncpy(j->error, buf, sizeof(j->error) - 1);
  j->error[sizeof(j->error) - 1] = 0;
}

static void aowl_http_release(AowlHttpJob *j) {
  if (j == NULL) return;
  if (j->body != NULL) free(j->body);
  free(j);
}

static DWORD WINAPI aowl_http_thread(LPVOID p) {
  AowlHttpJob *j = (AowlHttpJob*)p;
  HINTERNET ses = NULL, con = NULL, req = NULL;
  DWORD flags = 0;
  /* A whole-fetch deadline, not only WinHTTP's per-operation timeouts. A
     server that hands over one byte every 50ms never trips a receive timeout
     and would otherwise hold a worker for as long as it liked. `timeoutMs`
     bounds the entire fetch, which is the only version of that number anyone
     can reason about. */
  ULONGLONG t0 = GetTickCount64();

  ses = aowl_wh_open(L"aowlspt-manager/1", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                     WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (ses == NULL) { aowl_http_fail(j, "WinHttpOpen failed", GetLastError()); goto finish; }
  if (aowl_wh_timeouts != NULL)
    aowl_wh_timeouts(ses, j->timeoutMs, j->timeoutMs, j->timeoutMs, j->timeoutMs);

  con = aowl_wh_connect(ses, j->whost, (INTERNET_PORT)j->port, 0);
  if (con == NULL) { aowl_http_fail(j, "could not connect", GetLastError()); goto finish; }

  flags = WINHTTP_FLAG_REFRESH;
  if (j->secure) flags |= WINHTTP_FLAG_SECURE;
  req = aowl_wh_openreq(con, L"GET", j->wpath, NULL, WINHTTP_NO_REFERER,
                        WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
  if (req == NULL) { aowl_http_fail(j, "could not open the request", GetLastError()); goto finish; }

  if (!aowl_wh_send(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                    WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
    aowl_http_fail(j, "the request could not be sent", GetLastError());
    goto finish;
  }
  if (!aowl_wh_recv(req, NULL)) {
    aowl_http_fail(j, "no response", GetLastError());
    goto finish;
  }

  {
    DWORD code = 0, size = sizeof(code);
    if (aowl_wh_query(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                      WINHTTP_HEADER_NAME_BY_INDEX, &code, &size,
                      WINHTTP_NO_HEADER_INDEX)) {
      j->status = (int)code;
    }
  }

  /* Query-then-read, one buffered chunk at a time. `WinHttpReadData` with a
     large buffer blocks until that buffer is *full* or the response ends, so
     reading straight into the remaining capacity hands control to the far end:
     a server dribbling a byte at a time keeps the worker inside one call for as
     long as it likes and the deadline below never gets a turn. Asking what is
     available first bounds every call to what has already arrived. */
  for (;;) {
    DWORD got = 0;
    DWORD avail = 0;
    DWORD want = 0;
    int room = j->cap - j->len;
    if (room <= 0) { j->truncated = 1; break; }
    if (GetTickCount64() - t0 > (ULONGLONG)j->timeoutMs) {
      aowl_http_fail(j, "the fetch took longer than the configured timeout", 0);
      j->status = 0;
      break;
    }
    if (!aowl_wh_avail(req, &avail)) {
      aowl_http_fail(j, "the body could not be read", GetLastError());
      j->status = 0;
      break;
    }
    if (avail == 0) break;
    want = avail;
    if (want > (DWORD)room) want = (DWORD)room;
    if (!aowl_wh_read(req, j->body + j->len, want, &got)) {
      aowl_http_fail(j, "the body could not be read", GetLastError());
      j->status = 0;
      break;
    }
    if (got == 0) break;
    j->len += (int)got;
  }

finish:
  if (req != NULL) aowl_wh_close(req);
  if (con != NULL) aowl_wh_close(con);
  if (ses != NULL) aowl_wh_close(ses);
  if (InterlockedExchange(&j->abandoned, 2) == 1) {
    /* The manager let go while this was in flight. Nobody will read the
       result, and this thread is the last owner of the memory. */
    aowl_http_release(j);
    return 0;
  }
  InterlockedExchange(&j->done, 1);
  return 0;
}

/* Everything below runs on the manager's thread only. */

void* aowl_http_start(const char *host, const char *path, int port, int secure,
                      int timeoutMs, int maxBytes) {
  AowlHttpJob *j;
  HANDLE th;
  if (!aowl_http_bind()) return NULL;
  if (maxBytes < 1024) maxBytes = 1024;
  j = (AowlHttpJob*)calloc(1, sizeof(AowlHttpJob));
  if (j == NULL) return NULL;
  j->body = (char*)malloc((size_t)maxBytes);
  if (j->body == NULL) { free(j); return NULL; }
  j->cap = maxBytes;
  j->timeoutMs = timeoutMs > 0 ? timeoutMs : 10000;
  j->secure = secure;
  j->port = port;
  MultiByteToWideChar(CP_UTF8, 0, host, -1, j->whost, 512);
  MultiByteToWideChar(CP_UTF8, 0, path, -1, j->wpath, 4096);
  th = CreateThread(NULL, 0, aowl_http_thread, j, 0, NULL);
  if (th == NULL) { aowl_http_release(j); return NULL; }
  CloseHandle(th);
  return (void*)j;
}

int aowl_http_done(void *p) {
  AowlHttpJob *j = (AowlHttpJob*)p;
  if (j == NULL) return 1;
  return InterlockedCompareExchange(&j->done, 0, 0) != 0 ? 1 : 0;
}

int aowl_http_status(void *p)    { return p == NULL ? 0 : ((AowlHttpJob*)p)->status; }
int aowl_http_len(void *p)       { return p == NULL ? 0 : ((AowlHttpJob*)p)->len; }
int aowl_http_truncated(void *p) { return p == NULL ? 0 : ((AowlHttpJob*)p)->truncated; }
const char* aowl_http_error(void *p) { return p == NULL ? "" : ((AowlHttpJob*)p)->error; }
int aowl_http_error_len(void *p) { return p == NULL ? 0 : (int)strlen(((AowlHttpJob*)p)->error); }
const char* aowl_http_body(void *p)  { return p == NULL ? "" : ((AowlHttpJob*)p)->body; }

void aowl_http_free(void *p) {
  AowlHttpJob *j = (AowlHttpJob*)p;
  if (j == NULL) return;
  if (InterlockedCompareExchange(&j->done, 0, 0) != 0) {
    aowl_http_release(j);
    return;
  }
  /* Still running: hand the memory to the worker. `abandoned` becoming 1
     before the worker's exchange means the worker frees; the worker getting
     there first returns 1 here and it frees below. */
  if (InterlockedExchange(&j->abandoned, 1) == 2) aowl_http_release(j);
}
""".}

type CPtr = nil pointer

proc cHttpStart(host, path: cstring; port, secure, timeoutMs,
                maxBytes: int32): CPtr {.importc: "aowl_http_start", nodecl.}
proc cHttpDone(p: CPtr): int32 {.importc: "aowl_http_done", nodecl.}
proc cHttpStatus(p: CPtr): int32 {.importc: "aowl_http_status", nodecl.}
proc cHttpLen(p: CPtr): int32 {.importc: "aowl_http_len", nodecl.}
proc cHttpTruncated(p: CPtr): int32 {.importc: "aowl_http_truncated", nodecl.}
proc cHttpError(p: CPtr): CPtr {.importc: "aowl_http_error", nodecl.}
proc cHttpErrorLen(p: CPtr): int32 {.importc: "aowl_http_error_len", nodecl.}
proc cHttpBody(p: CPtr): CPtr {.importc: "aowl_http_body", nodecl.}
proc cHttpFree(p: CPtr) {.importc: "aowl_http_free", nodecl.}

type
  FetchState* = enum
    fsIdle       ## nothing has been asked for
    fsLocal      ## a file was read; the answer is already here
    fsRunning    ## a worker is out
    fsDone       ## the worker came back

  Fetch* = object
    state*: FetchState
    job*: CPtr   ## the worker, or nil. Public only so a global can be given a
                 ## literal initialiser: in an --app:lib build a global that
                 ## needs a *call* to initialise is left zeroed.
    url*: string
    ## Filled in once `state` is `fsDone` or `fsLocal`.
    ok*: bool
    status*: int         ## HTTP status, 0 for a local read or a transport fault
    error*: string
    truncated*: bool
    body*: string

proc idleFetch*(): Fetch =
  Fetch(state: fsIdle, job: nil, url: "", ok: false, status: 0, error: "",
        truncated: false, body: "")

# ---------------------------------------------------------------------------
# URLs
# ---------------------------------------------------------------------------

proc startsWith(s, prefix: string): bool =
  if prefix.len > s.len: return false
  for i in 0 ..< prefix.len:
    if s[i] != prefix[i]: return false
  result = true

proc localPathOf*(url: string): string =
  ## The local file a source names, or "" when it names a network location.
  ##
  ## `file:///C:/x/mods.json`, `file://C:/x/mods.json` and a bare `C:\x\mods.json`
  ## are all the same request, and all three are things a person types into a
  ## config file. A path is not a lesser kind of URL here — it is the form this
  ## whole feature was verified against, because a fetch you can run with no
  ## network is a fetch you can run in a test.
  if url.len == 0:
    return ""
  if startsWith(url, "http://") or startsWith(url, "https://"):
    return ""
  if startsWith(url, "file://"):
    var rest = url.substr(7, url.len - 1)
    # `file:///C:/x` — the third slash is the root marker, and on Windows what
    # follows it is already absolute.
    if rest.len > 0 and rest[0] == '/':
      rest = rest.substr(1, rest.len - 1)
    var outp = ""
    for ch in rest:
      if ch == '/': outp.add '\\'
      else: outp.add ch
    return outp
  result = url

proc splitHttp(url: string; host: var string; path: var string;
               port: var int; secure: var bool): bool =
  ## `scheme://host[:port]/path` into its parts. Returns false for anything
  ## that is not http or https, which the caller has already ruled out — it is
  ## checked again because a URL that reached the network layer unrecognised
  ## would otherwise be requested from the host "https".
  host = ""
  path = "/"
  secure = false
  var rest = ""
  if startsWith(url, "http://"):
    rest = url.substr(7, url.len - 1)
    port = 80
  elif startsWith(url, "https://"):
    rest = url.substr(8, url.len - 1)
    port = 443
    secure = true
  else:
    return false
  var slash = -1
  for i in 0 ..< rest.len:
    if rest[i] == '/':
      slash = i
      break
  var hostPart = rest
  if slash >= 0:
    hostPart = rest.substr(0, slash - 1)
    path = rest.substr(slash, rest.len - 1)
  var colon = -1
  for i in 0 ..< hostPart.len:
    if hostPart[i] == ':': colon = i
  if colon >= 0:
    var v = 0
    var any = false
    let digits = hostPart.substr(colon + 1, hostPart.len - 1)
    for ch in digits:
      if ch >= '0' and ch <= '9':
        v = v * 10 + (ord(ch) - ord('0'))
        any = true
      else:
        return false
    if any: port = v
    hostPart = hostPart.substr(0, colon - 1)
  if hostPart.len == 0:
    return false
  host = hostPart
  result = true

# ---------------------------------------------------------------------------
# Running one
# ---------------------------------------------------------------------------

proc readLocal(path: string; text: var string): bool =
  text = ""
  try:
    text = readFile(path)
  except:
    return false
  result = true

proc start*(url: string; timeoutMs, maxBytes: int): Fetch =
  ## Begin a fetch. Returns immediately in every case, including failure.
  result = idleFetch()
  result.url = url
  if url.len == 0:
    result.state = fsDone
    result.error = "no URL"
    return

  let local = localPathOf(url)
  if local.len > 0:
    var text = ""
    if not readLocal(local, text):
      result.state = fsLocal
      result.error = "could not read " & local
      return
    if text.len > maxBytes:
      result.state = fsLocal
      result.truncated = true
      result.error = local & " is " & $text.len & " bytes; the limit is " &
                     $maxBytes
      return
    result.state = fsLocal
    result.ok = true
    result.body = text
    return

  var host = ""
  var path = "/"
  var port = 80
  var secure = false
  if not splitHttp(url, host, path, port, secure):
    result.state = fsDone
    result.error = "\"" & url & "\" is not an http:// or https:// URL, and " &
                   "not a path this can read as a file"
    return

  var hostZ = host
  var pathZ = path
  let job = cHttpStart(toCString(hostZ), toCString(pathZ), int32(port), (if secure: 1'i32 else: 0'i32),
                       int32(timeoutMs), int32(maxBytes))
  if job == nil:
    result.state = fsDone
    result.error = "winhttp.dll could not be loaded, or a worker could not " &
                   "be started; nothing was fetched"
    return
  result.job = job
  result.state = fsRunning

proc borrowed(p: CPtr; n: int): string =
  ## A C buffer into a nimony string. `beginStore`/`endStore` rather than
  ## `addr result[0]`: a short nimony string keeps its bytes inline in the
  ## object, so there is no single data pointer to take the address of. The
  ## same reason `aowlspt.toString` is written this way.
  result = ""
  if p == nil or n <= 0: return
  let dest = beginStore(result, n)
  copyMem(dest, p, n)
  endStore(result)

proc poll*(f: var Fetch) =
  ## Take the result if the worker has finished. Never waits.
  if f.state != fsRunning:
    return
  if cHttpDone(f.job) == 0'i32:
    return
  f.state = fsDone
  f.status = int(cHttpStatus(f.job))
  f.truncated = cHttpTruncated(f.job) != 0'i32
  let n = int(cHttpLen(f.job))
  let errText = borrowed(cHttpError(f.job), int(cHttpErrorLen(f.job)))
  if errText.len > 0:
    f.error = errText
  elif f.status != 200:
    f.error = "the server answered " & $f.status
  elif f.truncated:
    # Refused rather than parsed. A JSON document cut short at a byte limit can
    # still parse — `{"mods":[...` closed by luck is not a thing, but a
    # truncation that lands between two entries produces a *smaller registry
    # that looks complete*, which is precisely the failure this whole path is
    # arranged against.
    f.error = "the body exceeded the configured limit and was cut short"
  else:
    f.ok = true
    if n > 0:
      f.body = borrowed(cHttpBody(f.job), n)
  cHttpFree(f.job)
  f.job = nil

proc release*(f: var Fetch) =
  ## Let go of a job, finished or not. Safe to call at any time, including from
  ## `onUnload` with a worker still out — see the module comment.
  if f.job != nil:
    cHttpFree(f.job)
    f.job = nil
  f.state = fsIdle
