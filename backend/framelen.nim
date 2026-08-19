## framelen -- the declared body length, at every boundary arithmetic has.
##
##     framelen --root <stage> --backend <aowlspt-backend.exe> [--port 7203]
##
## `fuzzwire` sends two absurd `Content-Length` headers among a hundred other
## hostile things, checks that each is refused, and asks at the end of the phase
## whether the process is still there. That shape found the original bug -- the
## body buffer allocated at whatever the header claimed -- and it is the wrong
## shape for the question that came after it: *which* declared length, and
## which of the several places a declared length reaches arithmetic. A phase
## that sends twenty requests and then notices the process is gone names the
## twentieth, and the report that started this file said
## `Content-Length: 9000000000000000000` for a phase that had already sent a
## short body, a long body, a zlib bomb and a zero-length body behind it.
##
## So this tool is the other shape. One case, one connection, one assertion
## about the **answer**, and a liveness probe with that case's own name on it
## before the next one starts. A crash is attributed to the bytes that caused
## it rather than to the bytes that happened to be last.
##
## What it asserts, in three groups:
##
## **The value.** Nineteen and twenty digit lengths around `int64` and `uint64`
## max, `2^31`, `2^32`, the body cap and one past it, three hundred leading
## zeros in front of an absurd number, and the same numbers written with a sign
## or a trailing letter. A length over the cap is `413` *before* anything is
## reserved for it; a length under it is honoured exactly.
##
## **The disagreement.** Two `Content-Length` headers, in both orders, agreeing
## and disagreeing; a length that does not match the body that follows, in both
## directions. Whichever way the two are read, where this request ends and the
## next one begins must not be a thing two parties can be made to disagree
## about -- so anything but an exact agreement is refused and the connection
## closed.
##
## **The frame.** Every one of those cases again with a well-formed request
## pipelined behind it in the same write. The assertion is on how many answers
## come back and what the *second* one says: a server that answers the hostile
## request and then reads the body it declined as the next request has not
## refused it at all, it has been handed a request smuggling primitive. The
## count comes from parsing each response's own `Content-Length` out of the
## stream, which is the only way to tell one answer from two.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]
import wire

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnAlive(h: uint64): int32 {.importc: "aowl_spawn_alive", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

{.emit: """
/* This tool's own socket, for the same reason `fuzzwire` has one: half of what
 * it sends is not a request, so it cannot go through `wire.request`.
 *
 * The receive timeout is longer than the server's own body deadline
 * (`AOWL_BODY_MS`) plus its keep-alive idle window, so a case that declares a
 * body and never sends it comes back as *the server gave up*, with its 408,
 * rather than as this tool giving up on the server. Those two are the whole
 * finding apart. */
static uint64_t aowl_fl_connect(int32_t port) {
  SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) return 0;
  struct sockaddr_in a;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_port = htons((unsigned short)port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(s, (struct sockaddr*)&a, sizeof(a)) == SOCKET_ERROR) {
    closesocket(s);
    return 0;
  }
  DWORD t = 20000;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&t, sizeof(t));
  return (uint64_t)s;
}

/* And its own clock, for the reason `wire.nim`'s cannot be used here: `wire`
 * defines `aowl_wire_now_us` in an `{.emit.}` of its own, and a module that
 * imports it gets that definition *after* its own code in the generated
 * translation unit. Calling it from here is an implicit declaration and a
 * compile error. */
static int64_t aowl_fl_now_us(void) {
  LARGE_INTEGER v, f;
  QueryPerformanceCounter(&v);
  QueryPerformanceFrequency(&f);
  return (int64_t)((v.QuadPart / f.QuadPart) * 1000000LL +
                   ((v.QuadPart % f.QuadPart) * 1000000LL) / f.QuadPart);
}

/* Half-closing the sending side, which is what turns the last phase of this
 * tool from a five-second wait into a hammer.
 *
 * A body that stops arriving is answered `408`, and the *poller* thread writes
 * it -- `aowlspt_nim_timeout`, called from `aowl_net_poller` rather than from a
 * worker, which makes it the one response on this server composed off the
 * request path. Waiting for `AOWL_BODY_MS` to reach it buys one exercise of
 * that path every five seconds. Shutting down the write side reaches the same
 * call immediately, through `aowl_conn_read` seeing an orderly close with the
 * body still owed, and leaves the receive side open so the answer can still be
 * read and checked. Thousands a second instead of one every five. */
static void aowl_fl_half_close(uint64_t s) {
  shutdown((SOCKET)s, SD_SEND);
}

/* And the close that goes with it, which is not a detail either.
 *
 * The half-close above means *this* side sends the first FIN, so every one of
 * these connections would sit in TIME_WAIT on this machine for two minutes.
 * The dynamic port range here is fourteen thousand wide, so a storm that opens
 * two thousand connections a second runs out of local ports in about seven --
 * and every failure after that is `connect` failing in this tool, reported as
 * the server having stopped answering. That is a test that fails by exhausting
 * itself and blames the thing it is testing, which is worse than no test.
 *
 * `SO_LINGER` with a zero timeout makes `closesocket` send a reset and drop
 * the control block, so the local port is reusable immediately. It is the
 * right thing here for the additional reason that the answer has already been
 * read and checked by the time this is called: there is nothing left in flight
 * to lose. */
static void aowl_fl_reset_close(uint64_t s) {
  struct linger lg;
  lg.l_onoff = 1;
  lg.l_linger = 0;
  setsockopt((SOCKET)s, SOL_SOCKET, SO_LINGER, (const char*)&lg, sizeof(lg));
  closesocket((SOCKET)s);
}

/* The storm's counters and threads. Interlocked for the same reason
 * `dbrace.nim` gives: a mismatch counted with `++` from twelve threads is a
 * mismatch count that can read zero. */
static LONG64 aowl_fl_stalls  = 0;
static LONG64 aowl_fl_calls   = 0;
static LONG64 aowl_fl_wrong   = 0;
static LONG64 aowl_fl_lost    = 0;
static LONG64 aowl_fl_refused = 0;
static LONG   aowl_fl_stop    = 0;

static void    aowl_fl_bump_stall(void) { InterlockedIncrement64(&aowl_fl_stalls); }
static void    aowl_fl_bump_call(void)  { InterlockedIncrement64(&aowl_fl_calls); }
static void    aowl_fl_bump_wrong(void) { InterlockedIncrement64(&aowl_fl_wrong); }
static void    aowl_fl_bump_lost(void)  { InterlockedIncrement64(&aowl_fl_lost); }
static void    aowl_fl_bump_refused(void) { InterlockedIncrement64(&aowl_fl_refused); }
static int64_t aowl_fl_get_stalls(void) { return (int64_t)InterlockedCompareExchange64(&aowl_fl_stalls, 0, 0); }
static int64_t aowl_fl_get_calls(void)  { return (int64_t)InterlockedCompareExchange64(&aowl_fl_calls, 0, 0); }
static int64_t aowl_fl_get_wrong(void)  { return (int64_t)InterlockedCompareExchange64(&aowl_fl_wrong, 0, 0); }
static int64_t aowl_fl_get_lost(void)   { return (int64_t)InterlockedCompareExchange64(&aowl_fl_lost, 0, 0); }
static int64_t aowl_fl_get_refused(void){ return (int64_t)InterlockedCompareExchange64(&aowl_fl_refused, 0, 0); }
static int32_t aowl_fl_running(void)    { return InterlockedCompareExchange(&aowl_fl_stop, 0, 0) ? 0 : 1; }
static void    aowl_fl_halt(void)       { InterlockedExchange(&aowl_fl_stop, 1); }

/* nimony emits the definitions of these below this block. */
int32_t aowl_fl_staller(int32_t which);
int32_t aowl_fl_caller(int32_t which);

static DWORD WINAPI aowl_fl_staller_thunk(LPVOID p) {
  return (DWORD)aowl_fl_staller((int32_t)(intptr_t)p);
}
static DWORD WINAPI aowl_fl_caller_thunk(LPVOID p) {
  return (DWORD)aowl_fl_caller((int32_t)(intptr_t)p);
}

#define AOWL_FL_MAX 64
static HANDLE aowl_fl_threads[AOWL_FL_MAX];
static int32_t aowl_fl_n = 0;

static void aowl_fl_start(int32_t stallers, int32_t callers) {
  aowl_fl_n = 0;
  int32_t most = stallers > callers ? stallers : callers;
  for (int32_t i = 0; i < most; i++) {
    if (i < stallers && aowl_fl_n < AOWL_FL_MAX)
      aowl_fl_threads[aowl_fl_n++] =
        CreateThread(NULL, 0, aowl_fl_staller_thunk, (LPVOID)(intptr_t)i, 0, NULL);
    if (i < callers && aowl_fl_n < AOWL_FL_MAX)
      aowl_fl_threads[aowl_fl_n++] =
        CreateThread(NULL, 0, aowl_fl_caller_thunk, (LPVOID)(intptr_t)i, 0, NULL);
  }
}

static void aowl_fl_join(void) {
  for (int32_t i = 0; i < aowl_fl_n; i++) {
    if (aowl_fl_threads[i]) {
      WaitForSingleObject(aowl_fl_threads[i], 20000);
      CloseHandle(aowl_fl_threads[i]);
      aowl_fl_threads[i] = NULL;
    }
  }
  aowl_fl_n = 0;
}
""".}

proc cFlConnect(port: int32): uint64 {.importc: "aowl_fl_connect", nodecl.}
proc flNowUs(): int64 {.importc: "aowl_fl_now_us", nodecl.}
proc cFlHalfClose(s: uint64) {.importc: "aowl_fl_half_close", nodecl.}
proc cFlResetClose(s: uint64) {.importc: "aowl_fl_reset_close", nodecl.}
proc cFlBumpStall() {.importc: "aowl_fl_bump_stall", nodecl.}
proc cFlBumpCall() {.importc: "aowl_fl_bump_call", nodecl.}
proc cFlBumpWrong() {.importc: "aowl_fl_bump_wrong", nodecl.}
proc cFlBumpLost() {.importc: "aowl_fl_bump_lost", nodecl.}
proc cFlStalls(): int64 {.importc: "aowl_fl_get_stalls", nodecl.}
proc cFlCalls(): int64 {.importc: "aowl_fl_get_calls", nodecl.}
proc cFlWrong(): int64 {.importc: "aowl_fl_get_wrong", nodecl.}
proc cFlLost(): int64 {.importc: "aowl_fl_get_lost", nodecl.}
proc cFlBumpRefused() {.importc: "aowl_fl_bump_refused", nodecl.}
proc cFlRefused(): int64 {.importc: "aowl_fl_get_refused", nodecl.}
proc cFlRunning(): int32 {.importc: "aowl_fl_running", nodecl.}
proc cFlHalt() {.importc: "aowl_fl_halt", nodecl.}
proc cFlStart(stallers, callers: int32) {.importc: "aowl_fl_start", nodecl.}
proc cFlJoin() {.importc: "aowl_fl_join", nodecl.}

const
  Usage = """
framelen -- the declared body length at every boundary

  framelen --root PATH --backend PATH [--port N]

  --root PATH      the scratch install (mods/, db.json)
  --backend PATH   aowlspt-backend.exe
  --port N         port to serve on (default 7203)
  --seconds N      how long the concurrent phase runs (default 8)
  --stallers N     threads on the timeout path in it (default 8)
  --callers N      threads asking ordinary questions in it (default 4)
  --storm          only the concurrent phase
  --attach         drive a server somebody else started, on --port
  --keep           leave the backend running at the end
  -h, --help       this
"""
  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"

  Cap = 16 * 1024 * 1024
    ## `MaxBodyBytes` in `aowlbackend.nim` and `AOWL_BODY_CAP` in
    ## `aowlspt_net.h`. Written here as a third copy on purpose: the two are
    ## required to be the same number and this fails if either moves alone.

var gFailures = 0
var gChecks = 0
var gPort = 7203
var gBackend = ""
var gRoot = ""
var gProc = 0'u64
var gSeconds = 8
var gAttach = false
var gStormOnly = false
var gStallers = 8
var gCallers = 4

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

# --------------------------------------------------------------- the wire

type
  Answer = object
    status: string
      ## The status line, or "" for a response that was not there.
    body: string
      ## The response body, uncompressed. Every refusal this tool provokes is
      ## sent uncompressed, so this is the bytes as they arrived.

  Exchange = object
    answers: seq[Answer]
      ## One entry per *framed* response on the connection, in order. The
      ## count is the assertion for half the checks here.
    trailing: int
      ## Bytes after the last complete response. Anything but zero is a
      ## half-written answer, which is its own finding.
    elapsedMs: int
    connected: bool

proc sendAll(sock: uint64; bytes: string): bool =
  if sock == 0'u64 or bytes.len == 0:
    return false
  var b = toBytes(bytes)
  result = cSend(sock, cast[WirePtr](addr b[0]), int32(bytes.len)) >= 0'i32

proc headLengthOf(head: string): int =
  ## The `Content-Length` of one *response*. The server writes one on every
  ## answer it sends, which is what makes a stream of them separable.
  result = -1
  let lines = splitLines(head)
  for i in 0 ..< lines.len:
    let l = lines[i]
    let colon = find(l, ":")
    if colon < 0:
      continue
    if toLowerAscii(strip(l.substr(0, colon - 1))) != "content-length":
      continue
    let v = strip(l.substr(colon + 1))
    var n = 0
    var any = false
    for ch in v:
      if ch >= '0' and ch <= '9':
        n = n * 10 + (ord(ch) - ord('0'))
        any = true
      else:
        break
    if any:
      return n
  result = -1

proc exchange(sock: uint64; bytes: string): Exchange =
  ## Writes exactly these bytes and reads the connection to its end, taking the
  ## stream apart into the responses it contains.
  ##
  ## Reading *to the end* rather than to the first blank line is the point.
  ## The question several of these cases ask is whether a request that was
  ## refused took the bytes behind it with it, and a reader that stops at the
  ## first response cannot tell a refusal that closed from a refusal that went
  ## on to answer the body it declined.
  result = Exchange(answers: @[], trailing: 0, elapsedMs: 0, connected: false)
  if sock == 0'u64:
    return
  result.connected = true
  let startedAt = flNowUs()
  discard sendAll(sock, bytes)
  var buf = newSeq[byte](262144)
  var have = 0
  while true:
    if have == buf.len:
      var bigger = newSeq[byte](buf.len * 2)
      copyMem(addr bigger[0], addr buf[0], have)
      buf = bigger
    let m = cRecv(sock, cast[WirePtr](addr buf[have]), int32(buf.len - have))
    if m <= 0'i32:
      break
    have = have + int(m)
  result.elapsedMs = int((flNowUs() - startedAt) div 1000'i64)

  var at = 0
  while at < have:
    # The terminator of this response's head, found from `at`.
    var headEnd = -1
    var sep = 4
    var k = at
    while k + 1 < have:
      if buf[k] == byte(13) and k + 3 < have and buf[k + 1] == byte(10) and
         buf[k + 2] == byte(13) and buf[k + 3] == byte(10):
        headEnd = k
        sep = 4
        break
      if buf[k] == byte(10) and buf[k + 1] == byte(10):
        headEnd = k
        sep = 2
        break
      inc k
    if headEnd < 0:
      result.trailing = have - at
      return
    let head = bytesAt(buf, at, headEnd - at)
    let n = headLengthOf(head)
    if n < 0:
      # No length on the answer. Nothing after it can be framed, so the rest of
      # the stream is trailing by definition.
      result.answers.add Answer(status: splitLines(head)[0], body: "")
      result.trailing = have - (headEnd + sep)
      return
    let bodyAt = headEnd + sep
    if bodyAt + n > have:
      result.answers.add Answer(status: splitLines(head)[0], body: "")
      result.trailing = have - bodyAt
      return
    var text = ""
    if n > 0:
      let rawAt = cast[WirePtr](cast[uint](addr buf[0]) + uint(bodyAt))
      if cZlibFramed(rawAt, int32(n)) == 0'i32:
        text = bytesAt(buf, bodyAt, n)
      else:
        var cap = n * 8
        if cap < 65536: cap = 65536
        var tries = 0
        while tries < 6:
          var dst = newSeq[byte](cap)
          let room = dst.len
          let m2 = cZlibInflate(rawAt, int32(n), cast[WirePtr](addr dst[0]),
                                int32(room))
          if m2 >= 0'i32:
            text = fromBytes(dst, int(m2))
            break
          cap = room * 4
          inc tries
    result.answers.add Answer(status: splitLines(head)[0], body: text)
    at = bodyAt + n

proc once(bytes: string): Exchange =
  ## One exchange on a connection of its own.
  let sock = cFlConnect(int32(gPort))
  result = exchange(sock, bytes)
  if sock != 0'u64:
    cClose(sock)

proc statusOf(x: Exchange; i: int): string =
  if i < x.answers.len:
    return x.answers[i].status
  result = ""

proc bodyOf(x: Exchange; i: int): string =
  if i < x.answers.len:
    return x.answers[i].body
  result = ""

proc said(x: Exchange; i: int; code: string): bool =
  result = find(statusOf(x, i), code) >= 0

proc specific(x: Exchange; i: int): bool =
  ## A refusal that says what it refused. Same bar `fuzzwire` sets, and the
  ## same reason: `400` with an empty body is indistinguishable from a server
  ## that fell over, which is the question this whole tool is about.
  let b = bodyOf(x, i)
  result = b.len >= 24 and find(b, "\"err\"") >= 0

proc summarise(x: Exchange): string =
  result = $x.answers.len & " answer(s)"
  for i in 0 ..< x.answers.len:
    result.add " [" & x.answers[i].status & "]"
  if x.trailing > 0:
    result.add " + " & $x.trailing & " unframed byte(s)"
  if x.answers.len == 0:
    result.add " in " & $x.elapsedMs & " ms"

# --------------------------------------------------------------- the server

proc waitForBackend(tries: int): bool =
  var i = 0
  while i < tries:
    let r = request(gPort, "/client/game/config", "", Session)
    if r.ok and r.contains("\"err\":0"):
      return true
    cSleepMs(200'i32)
    inc i
  result = false

proc startBackend(): uint64 =
  if gAttach:
    return 0'u64
  var e = gBackend
  var w = gRoot
  var c = "\"" & gBackend & "\" --root \"" & gRoot & "\" --port " & $gPort
  result = cSpawn(toCString(e), toCString(w), toCString(c))

proc alive(): bool =
  ## The process handle, which is the honest answer, unless this run is
  ## attached to a server somebody else started -- in which case the only
  ## question that can be asked is whether the port still accepts, which is a
  ## weaker claim and is why `--attach` is a debugging aid rather than the way
  ## the gate runs.
  if gAttach:
    # Retried, because one refused `connect` is not proof of death: the
    # listener's backlog can be full for a moment under the storm this tool is
    # running, and a single probe that lands in that moment reports a server
    # that is answering as one that has gone.
    var tries = 0
    while tries < 10:
      let s = cFlConnect(int32(gPort))
      if s != 0'u64:
        cFlResetClose(s)
        return true
      cSleepMs(100'i32)
      inc tries
    return false
  result = gProc == 0'u64 or cSpawnAlive(gProc) != 0'i32

proc survived(what: string) =
  ## The probe that runs after **every** case rather than after every phase.
  ##
  ## This is the whole reason this tool exists next to `fuzzwire`: a liveness
  ## check at the end of a phase names the last request in the phase, not the
  ## one that did it. Here the name on the failure is the header that was on
  ## the wire when the process went.
  if alive():
    return
  check(what & ": the server is still up", false, "the process exited")
  gProc = startBackend()
  discard waitForBackend(60)

# --------------------------------------------------------------- the cases

proc head(length: string; body: string; keepAlive: bool): string =
  ## A well-formed request head with `Content-Length:` written out verbatim --
  ## `length` is the exact text of the value, which is the point of most of
  ## what follows, and it is written even when it is empty. An empty value is
  ## not the header being *absent*, and the two have to be told apart: one of
  ## them is a request with no body, the other is a request that declares a
  ## length and does not say what it is.
  result = "POST /client/game/keepalive HTTP/1.1\r\n"
  result.add "Host: 127.0.0.1:" & $gPort & "\r\n"
  result.add "Cookie: PHPSESSID=" & Session & "\r\n"
  result.add "Content-Length: " & length & "\r\n"
  result.add(if keepAlive: "Connection: keep-alive\r\n"
             else: "Connection: close\r\n")
  result.add "\r\n"
  result.add body

proc headNoLength(body: string): string =
  ## The same request with no `Content-Length` header at all.
  result = "POST /client/game/keepalive HTTP/1.1\r\n"
  result.add "Host: 127.0.0.1:" & $gPort & "\r\n"
  result.add "Cookie: PHPSESSID=" & Session & "\r\n"
  result.add "Connection: close\r\n\r\n"
  result.add body

proc follower(): string =
  ## A request that is beyond reproach, used only as the thing that must not be
  ## mis-framed. `Connection: close` so the exchange ends on its own.
  result = "GET /client/game/config HTTP/1.1\r\n"
  result.add "Host: 127.0.0.1:" & $gPort & "\r\n"
  result.add "Cookie: PHPSESSID=" & Session & "\r\n"
  result.add "Content-Length: 0\r\n"
  result.add "Connection: close\r\n\r\n"

# ------------------------------------------------------------- the storm
#
# The `408` for a body that stopped arriving is the only answer this server
# composes off the request path: `aowlspt_nim_timeout` is called from the
# poller thread, while sixteen workers are inside `aowlspt_nim_handle` on other
# connections. Everything above sends one request at a time and cannot say
# anything about that, and one request at a time is the shape the report this
# file was written for came from -- a crash seen once in four runs of a tool
# whose every check is sequential.
#
# So the last phase is the other shape. Twelve threads that reach the timeout
# path as fast as the loopback allows, four that ask ordinary questions at the
# same time, and the assertion is on the answers all sixteen got: the stalled
# ones must each be told what they had and what they declared, and the ordinary
# ones must each be answered correctly, for as long as it runs.

proc stallOnce(): int =
  ## One half-closed request that owes a body. The answer has to be a single
  ## `408` naming both numbers -- and naming them *correctly*, which is what
  ## makes this a check on an answer rather than on survival.
  ##
  ## Returns 1 for a right answer, 0 for a wrong one and -1 for a connection
  ## that was never made. The third is kept apart from the second on purpose:
  ## `connect` failing under a storm this tool is itself generating is a fact
  ## about the storm, and counting it as a wrong answer is how a load generator
  ## comes to report its own limits as the server's bugs.
  let sock = cFlConnect(int32(gPort))
  if sock == 0'u64:
    return -1
  var bytes = "POST /client/game/keepalive HTTP/1.1\r\n"
  bytes.add "Host: 127.0.0.1:" & $gPort & "\r\n"
  bytes.add "Cookie: PHPSESSID=" & Session & "\r\n"
  bytes.add "Content-Length: 64\r\nConnection: close\r\n\r\nhello"
  var b = toBytes(bytes)
  discard cSend(sock, cast[WirePtr](addr b[0]), int32(bytes.len))
  cFlHalfClose(sock)
  let x = exchange(sock, "")
  cFlResetClose(sock)
  let right = x.answers.len == 1 and find(x.answers[0].status, "408") >= 0 and
              find(x.answers[0].body, "\"had\":5") >= 0 and
              find(x.answers[0].body, "\"declared\":64") >= 0
  result = (if right: 1 else: 0)

proc callOnce(): int =
  ## One ordinary question, asked while the stallers are running. Same
  ## tri-state, for the same reason.
  let sock = cFlConnect(int32(gPort))
  if sock == 0'u64:
    return -1
  let x = exchange(sock, follower())
  cFlResetClose(sock)
  let right = x.answers.len == 1 and find(x.answers[0].status, "200") >= 0 and
              find(x.answers[0].body, "\"err\":0") >= 0
  result = (if right: 1 else: 0)

proc stallerThread(which: int32): int32 {.
    exportc: "aowl_fl_staller", cdecl.} =
  discard which
  while cFlRunning() != 0'i32:
    let r = stallOnce()
    if r > 0: cFlBumpStall()
    elif r == 0: cFlBumpWrong()
    else: cFlBumpRefused()
    # Paced rather than flat out. Every one of these connections is opened and
    # thrown away, and a thread that does that in a tight loop opens them
    # faster than any client ever will -- which stops being a test of the
    # server and starts being a test of how many sockets this machine can
    # cycle. Ten milliseconds a thread is still two orders of magnitude more
    # stalled requests a second than a game makes.
    cSleepMs(10'i32)
  result = 0'i32

proc callerThread(which: int32): int32 {.
    exportc: "aowl_fl_caller", cdecl.} =
  discard which
  while cFlRunning() != 0'i32:
    let r = callOnce()
    if r > 0: cFlBumpCall()
    elif r == 0: cFlBumpLost()
    else: cFlBumpRefused()
    cSleepMs(20'i32)
  result = 0'i32

proc tooLarge(name, length: string) =
  ## A declared length over the cap. Three claims, and they are three different
  ## claims: it is refused with `413`, the refusal says which limit, and the
  ## server does not wait for the body it just declined -- which is the one an
  ## arithmetic overflow would break, because `headEnd + sep + cl` with a
  ## wrapped `cl` is a `need` *smaller* than the header block and a connection
  ## that is complete before it has been read.
  let bytes = head(length, "x", false)
  let x = once(bytes)
  check(name & " is refused with 413",
        x.answers.len == 1 and said(x, 0, "413"), summarise(x))
  check(name & ": the refusal names the limit",
        specific(x, 0) and find(bodyOf(x, 0), $Cap) >= 0, bodyOf(x, 0))
  survived(name)

proc malformed(name, length: string) =
  ## A `Content-Length` whose value is not a number. It cannot be honoured and
  ## it must not be *ignored*: a header the server reads as zero and a header
  ## the client meant as a length disagree about where the body ends, and the
  ## bytes they disagree about are the next request.
  let bytes = head(length, "hello", false) & follower()
  let x = once(bytes)
  check(name & " is refused with 400",
        x.answers.len == 1 and said(x, 0, "400"), summarise(x))
  check(name & ": the refusal says why", specific(x, 0), bodyOf(x, 0))
  check(name & ": the body it declined is not read as a request",
        x.answers.len == 1, summarise(x))
  survived(name)

proc honoured(name, length, body: string) =
  ## A declared length under the cap, with a body that agrees with it. It has
  ## to be served, and this is the half that a clamp written the wrong way
  ## breaks quietly: a `Content-Length` of twenty-eight characters that happens
  ## to spell five is five.
  let bytes = head(length, body, false)
  let x = once(bytes)
  check(name & " is served",
        x.answers.len == 1 and said(x, 0, "200"), summarise(x))
  survived(name)

# --------------------------------------------------------------- main

proc storm() =
  heading "The same paths, all at once"
  # Eight threads on the timeout path and four asking ordinary questions,
  # for `--seconds`. The liveness probe runs every quarter second so that a
  # process that goes is noticed while the run is still going rather than at
  # the end of it, and the two failure counts are separate because they are
  # separate findings: a stalled request answered with the wrong numbers is a
  # bug in the answer, and an ordinary request that did not come back while
  # the stallers ran is a bug in the server's ability to do two things.
  cFlStart(int32(gStallers), int32(gCallers))
  var died = false
  var waited = 0
  while waited < gSeconds * 1000:
    cSleepMs(250'i32)
    waited = waited + 250
    if not alive():
      died = true
      break
  cFlHalt()
  cFlJoin()
  let stalls = cFlStalls()
  let calls = cFlCalls()
  let wrong = cFlWrong()
  let lost = cFlLost()
  let refused = cFlRefused()
  check("the server survives the timeout path under load", not died,
        "the process exited after " & $waited & " ms, " & $stalls &
        " stalled requests and " & $calls & " ordinary ones")
  check("every stalled request was told what it had and what it declared",
        wrong == 0'i64,
        $wrong & " of " & $(stalls + wrong) & " were not")
  check("every ordinary request beside them was answered",
        lost == 0'i64, $lost & " of " & $(calls + lost) & " were not")
  check("and there were enough of both to mean something",
        (gStallers == 0 or stalls > 200'i64) and
        (gCallers == 0 or calls > 100'i64),
        $stalls & " stalled, " & $calls & " ordinary, " & $refused &
        " connections refused")
  note $stalls & " stalled requests, " & $calls & " ordinary ones, " &
       $refused & " connections this machine would not open"
  if died:
    gProc = startBackend()
    discard waitForBackend(60)


proc run(): int =
  if gStormOnly:
    storm()
    return 0
  heading "A length that cannot fit"
  block:
    # Nineteen digits, one short of `int64` max. This is the number in the
    # report that started this file.
    tooLarge("9000000000000000000", "9000000000000000000")
    tooLarge("int64 max", "9223372036854775807")
    tooLarge("int64 max + 1", "9223372036854775808")
    tooLarge("uint64 max", "18446744073709551615")
    tooLarge("uint64 max + 1", "18446744073709551616")
    tooLarge("2^63", "9223372036854775808")
    tooLarge("2^32", "4294967296")
    tooLarge("uint32 max", "4294967295")
    tooLarge("2^31", "2147483648")
    tooLarge("int32 max", "2147483647")
    tooLarge("int32 max + 1", "2147483648")
    # The step either side of the cap. One below is a length the server accepts
    # and waits for; one above is refused. Both are read by the same clamp, and
    # a clamp that saturates one digit early refuses a body the game sends.
    tooLarge("one byte over the cap", $(Cap + 1))
    tooLarge("a hundred digits", repeat("9", 100))
    # Leading zeros in front of a number too large to hold. The clamp runs on
    # the accumulator, so three hundred zeros are three hundred chances for it
    # to have been written as a check on the digit count instead.
    tooLarge("300 leading zeros then an absurd number",
             repeat("0", 300) & "9000000000000000000")
    tooLarge("leading zeros then one over the cap",
             repeat("0", 40) & $(Cap + 1))

  heading "A length that is not a number"
  block:
    malformed("a negative length", "-1")
    malformed("a large negative length", "-9000000000000000000")
    malformed("a signed length", "+5")
    malformed("a hexadecimal length", "0x10")
    malformed("digits with a letter behind them", "5abc")
    malformed("a list of lengths", "5, 5")
    malformed("an empty length", "")
    malformed("a length that is only spaces", "   ")
    malformed("a length with a space in the middle", "5 5")
    malformed("a length written as a float", "5.0")
    survived("the malformed lengths")

  heading "A length that is a number"
  block:
    honoured("a plain length", "5", "hello")
    honoured("a length with leading zeros", "0000000000000000000000000005",
             "hello")
    honoured("a length with three hundred leading zeros",
             repeat("0", 300) & "5", "hello")
    honoured("a zero length", "0", "")
    honoured("a zero length written with leading zeros", "000", "")
    honoured("a length with trailing whitespace", "5   ", "hello")
    honoured("a length with leading whitespace", "   5", "hello")
    # The header absent entirely is a request with no body, not a request whose
    # length is unknown.
    let x = once(headNoLength(""))
    check("no Content-Length at all is served",
          x.answers.len == 1 and said(x, 0, "200"), summarise(x))
    survived("no Content-Length at all")

  heading "Two lengths"
  block:
    # Both orders. `aowl_scan_length` takes the first it finds and `parseHead`
    # compares every one it finds, so which of the two is the larger decides
    # which side of the boundary is the one that waits -- and the two orders
    # are therefore two different code paths, not one case written twice.
    let lowFirst = "POST /client/game/keepalive HTTP/1.1\r\n" &
                   "Content-Length: 0\r\nContent-Length: 5\r\n" &
                   "Connection: close\r\n\r\nhello" & follower()
    var x = once(lowFirst)
    check("a duplicate length, smaller first, is refused",
          x.answers.len == 1 and said(x, 0, "400"), summarise(x))
    check("and the bytes behind it are not read as a request",
          x.answers.len == 1, summarise(x))
    survived("a duplicate length, smaller first")

    let highFirst = "POST /client/game/keepalive HTTP/1.1\r\n" &
                    "Content-Length: 5\r\nContent-Length: 0\r\n" &
                    "Connection: close\r\n\r\nhello" & follower()
    x = once(highFirst)
    check("a duplicate length, larger first, is refused",
          x.answers.len == 1 and said(x, 0, "400"), summarise(x))
    check("and that refusal says why too", specific(x, 0), bodyOf(x, 0))
    survived("a duplicate length, larger first")

    # One of the two over the cap, in both orders. The interesting half is the
    # one where the framer's answer and the parser's answer are on opposite
    # sides of the limit.
    let absurdFirst = "POST /client/game/keepalive HTTP/1.1\r\n" &
                      "Content-Length: 9000000000000000000\r\n" &
                      "Content-Length: 5\r\nConnection: close\r\n\r\nhello"
    x = once(absurdFirst)
    check("a duplicate where the first is absurd is refused",
          x.answers.len == 1 and
          (said(x, 0, "413") or said(x, 0, "400")), summarise(x))
    survived("a duplicate where the first is absurd")

    let absurdSecond = "POST /client/game/keepalive HTTP/1.1\r\n" &
                       "Content-Length: 5\r\n" &
                       "Content-Length: 9000000000000000000\r\n" &
                       "Connection: close\r\n\r\nhello"
    x = once(absurdSecond)
    check("a duplicate where the second is absurd is refused",
          x.answers.len == 1 and
          (said(x, 0, "413") or said(x, 0, "400")), summarise(x))
    survived("a duplicate where the second is absurd")

    # Two that agree, including two that agree only after the leading zeros are
    # dropped. Agreement is agreement about the *value*.
    let agree = "POST /client/game/keepalive HTTP/1.1\r\n" &
                "Cookie: PHPSESSID=" & Session & "\r\n" &
                "Content-Length: 5\r\nContent-Length: 05\r\n" &
                "Connection: close\r\n\r\nhello"
    x = once(agree)
    check("a duplicate that agrees with itself is served",
          x.answers.len == 1 and said(x, 0, "200"), summarise(x))
    survived("a duplicate that agrees with itself")

  heading "A length that disagrees with the body"
  block:
    # More declared than sent, and nothing follows. The server cannot know the
    # rest is not coming, so the only right answer is to give up on the clock
    # and say so -- and to still be answering afterwards.
    let short = head("64", "hello", false)
    var x = once(short)
    check("a body shorter than its length ends in an answer",
          x.answers.len == 1, summarise(x))
    check("and that answer is a 408 that says what it had",
          said(x, 0, "408") and find(bodyOf(x, 0), "\"declared\":64") >= 0,
          statusOf(x, 0) & " " & bodyOf(x, 0))
    survived("a body shorter than its length")

    # Declared at the cap and never sent. The same deadline, on the value the
    # framer is most likely to have reserved for in advance.
    let atCap = head($Cap, "hello", false)
    x = once(atCap)
    check("a body declared at the cap and not sent ends in an answer",
          x.answers.len == 1 and said(x, 0, "408"), summarise(x))
    survived("a body declared at the cap and not sent")

    # Fewer declared than sent. The extra bytes are the next request, and this
    # is the case where reading them as part of this one is how two parties are
    # made to disagree about where a request ends.
    let long = "POST /client/game/keepalive HTTP/1.1\r\n" &
               "Cookie: PHPSESSID=" & Session & "\r\n" &
               "Content-Length: 5\r\nConnection: keep-alive\r\n\r\n" &
               "hello" & follower()
    x = once(long)
    check("a body longer than its length is framed at the length",
          x.answers.len == 2, summarise(x))
    check("and the request behind it is answered on its own merits",
          said(x, 1, "200") and find(bodyOf(x, 1), "\"err\":0") >= 0,
          statusOf(x, 1) & " " & bodyOf(x, 1))
    survived("a body longer than its length")

  heading "The frame after a refusal"
  block:
    # The assertion this whole file is built around. An absurd length is
    # refused without the body being waited for, which means the bytes the
    # client sent as that body are still on the socket. If the server then
    # reads them as the next request it has not refused anything -- it has been
    # handed a way to make one connection carry a request the server never
    # counted. So: exactly one answer, and the connection closed.
    let smuggle = "POST /client/game/keepalive HTTP/1.1\r\n" &
                  "Content-Length: 9000000000000000000\r\n" &
                  "Connection: keep-alive\r\n\r\n" & follower()
    var x = once(smuggle)
    check("an absurd length is answered exactly once",
          x.answers.len == 1 and said(x, 0, "413"), summarise(x))
    check("and nothing behind it is left half-written",
          x.trailing == 0, $x.trailing & " unframed bytes")
    survived("an absurd length with a request behind it")

    # And the same with the follower disguised as the declined body: the bytes
    # are a complete, valid request, and they must still not be answered.
    let smuggle2 = "POST /client/game/keepalive HTTP/1.1\r\n" &
                   "Content-Length: " & $(Cap + 1) & "\r\n" &
                   "Connection: keep-alive\r\n\r\n" &
                   follower() & follower()
    x = once(smuggle2)
    check("one byte over the cap is answered exactly once",
          x.answers.len == 1 and said(x, 0, "413"), summarise(x))
    survived("one byte over the cap with two requests behind it")

    # The kept-alive stream that is *not* hostile, as the control: three
    # ordinary requests pipelined in one write, each with its own body, must
    # come back as three answers in order. Without this the checks above pass
    # on a server that closes every connection after one request, which would
    # make them prove nothing.
    var pipeline = ""
    var i = 0
    while i < 3:
      pipeline.add "POST /client/game/keepalive HTTP/1.1\r\n"
      pipeline.add "Cookie: PHPSESSID=" & Session & "\r\n"
      pipeline.add "Content-Length: 5\r\n"
      pipeline.add "Connection: keep-alive\r\n\r\nhello"
      inc i
    pipeline.add follower()
    x = once(pipeline)
    check("three pipelined requests and a follower are four answers",
          x.answers.len == 4, summarise(x))
    check("and every one of them is a 200",
          x.answers.len == 4 and said(x, 0, "200") and said(x, 1, "200") and
          said(x, 2, "200") and said(x, 3, "200"), summarise(x))
    survived("three pipelined requests")

    # Every hostile value again, this time on a connection that asked to be
    # kept alive, with a well-formed request behind it. One answer each: the
    # refusal, and then the connection.
    var lengths: seq[string] = @[]
    lengths.add "9000000000000000000"
    lengths.add "9223372036854775807"
    lengths.add "18446744073709551615"
    lengths.add "4294967296"
    lengths.add "2147483648"
    lengths.add $(Cap + 1)
    lengths.add "-1"
    lengths.add "+5"
    lengths.add "0x10"
    lengths.add "5abc"
    var j = 0
    while j < lengths.len:
      let v = lengths[j]
      let bytes = head(v, "", true) & follower()
      let y = once(bytes)
      check("kept alive, \"" & v & "\" is refused and the frame ends there",
            y.answers.len == 1 and
            (said(y, 0, "413") or said(y, 0, "400")), summarise(y))
      survived("kept alive, \"" & v & "\"")
      inc j

  storm()

  heading "And the server is unchanged"
  block:
    check("the process is still up", alive())
    # Retried, and the reason is this machine rather than the server. The storm
    # above opens several thousand connections, every one of which the server
    # closes -- so several thousand of this machine's fourteen thousand
    # ephemeral ports are in TIME_WAIT on the server's side of the tuple when
    # it ends, and `connect` from here can be refused for reasons that have
    # nothing to do with whether the server is answering. Failing these two on
    # the first refusal reported a healthy server as a dead one twice in four
    # runs, which is the failure this whole tool exists to stop making.
    var cfg = request(gPort, "/client/game/config", "", Session)
    var tries = 0
    while tries < 20 and not (cfg.ok and cfg.contains("\"err\":0")):
      cSleepMs(250'i32)
      cfg = request(gPort, "/client/game/config", "", Session)
      inc tries
    check("an ordinary request still answers",
          cfg.ok and cfg.contains("\"err\":0"),
          if cfg.error.len > 0: cfg.error else: cfg.body)
    var list = request(gPort, "/client/game/profile/list", "", Session)
    tries = 0
    while tries < 20 and not (list.ok and list.contains("\"err\":0")):
      cSleepMs(250'i32)
      list = request(gPort, "/client/game/profile/list", "", Session)
      inc tries
    check("the profile store still reads back",
          list.ok and list.contains("\"err\":0"), list.body)

  result = 0

proc main(): int =
  var keep = false
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= n: gRoot = paramStr(i)
    elif a == "--backend":
      inc i
      if i <= n: gBackend = paramStr(i)
    elif a == "--port":
      inc i
      if i <= n:
        var v = 0
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
        if v > 0: gPort = v
    elif a == "--seconds":
      inc i
      if i <= n:
        var v = 0
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
        if v > 0: gSeconds = v
    elif a == "--storm":
      gStormOnly = true
    elif a == "--stallers" or a == "--callers":
      let which = a
      inc i
      if i <= n:
        var v = 0
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
        if which == "--stallers": gStallers = v else: gCallers = v
    elif a == "--attach":
      gAttach = true
    elif a == "--keep":
      keep = true
    elif a == "-h" or a == "--help":
      echo Usage
      return 0
    else:
      err "unknown argument: " & a
      echo Usage
      return 2
    inc i

  if gAttach:
    if cNetStartup() == 0'i32:
      fatal "could not start winsock"
      return 2
    if not waitForBackend(20):
      fatal "nothing answering on port " & $gPort
      return 2
    discard run()
    line ""
    if gFailures == 0:
      ok $gChecks & " checks, no failures"
      return 0
    err $gFailures & " of " & $gChecks & " checks failed"
    return 1

  if gRoot.len == 0 or gBackend.len == 0:
    echo Usage
    return 2
  if not fileExists(gBackend):
    fatal "no backend at " & gBackend
    return 2
  discard ensureDir(gRoot)

  if cNetStartup() == 0'i32:
    fatal "could not start winsock"
    return 2

  gProc = startBackend()
  if gProc == 0'u64:
    fatal "could not start the backend"
    return 2
  if not waitForBackend(80):
    fatal "the backend never came up on port " & $gPort
    cSpawnKill(gProc)
    return 2

  discard run()

  if not keep:
    cSpawnKill(gProc)

  line ""
  if gFailures == 0:
    ok $gChecks & " checks, no failures"
    return 0
  err $gFailures & " of " & $gChecks & " checks failed"
  result = 1

quit(main())
