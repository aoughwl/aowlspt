## fuzzwire -- drive the backend with input a client would never send.
##
##     fuzzwire --root <stage> --port 6977 --backend <aowlspt-backend.exe>
##
## `emutest` proves the server is right when it is asked politely. This proves
## the other half: that no sequence of bytes a client can put on the socket
## takes the server down, wedges it, or leaves the store in a state the next
## request cannot read.
##
## Three rules shape every check here.
##
## **Survival is not enough.** After every hostile phase the tool asks an
## ordinary question -- the game config, then the profile list -- and requires
## both to answer. A server that survives a malformed request by corrupting the
## profile it was holding has not passed.
##
## **A refusal has to say why.** `400` with an empty body is indistinguishable
## from a server that fell over, and it sends whoever reads it to a debugger to
## find out which. So a refusal with no reason in it is a *failure* here, not a
## pass, and several of the reasons this tool now reads back were added to the
## backend because this check demanded them.
##
## **The routes are read, not listed.** The route table is taken from the
## backend's own log -- every `route <url>` line it writes as a mod registers
## one -- so a route added to any mod tomorrow is fuzzed by this tool tomorrow,
## with no edit here. A hardcoded list is a list that goes stale on the first
## endpoint somebody adds, and the endpoint nobody fuzzed is the one that
## crashes.
##
## **A death belongs to the request that caused it.** The liveness probe runs
## after every case, not after every phase, so the name on a crash is the bytes
## that were on the wire and not whatever the phase happened to send last. That
## distinction is not academic: this tool once reported the server dead on
## `Content-Length: 9000000000000000000` for a phase that had already sent five
## other hostile bodies behind it, and a session went into proving that value
## was handled correctly at every site -- which it was. Where the requests
## cannot be separated at all, four of them in flight at once, the report says
## which four and says outright that it cannot tell which; a vague finding
## costs an hour, and a confident wrong one costs a day. The probe itself
## distinguishes *refused*, *closed the connection*, *stopped answering* and
## *process gone*, because those are four different bugs, and it is checked
## against a serving port and a dead one before it is used to judge anything.
##
## What it does **not** do is judge a mod's answers beyond the invariants named
## in each check. `mods/tarkov` is content; the findings this tool makes about
## it are reported by failing with the request that produced them, which is the
## only form of bug report that cannot go stale.

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
/* This tool's own socket and clock, rather than `wire.nim`'s.
 *
 * `wire` defines both in an `{.emit.}` of its own, and a module that imports
 * it gets those definitions *after* its own code in the generated translation
 * unit -- fine for anything that only calls `request`, which is what every
 * other tool here does, and an implicit declaration for the first tool that
 * wants the socket itself. This one does: half its checks are bytes that are
 * not a request, so it cannot go through `request` to send them. */
static uint64_t aowl_fuzz_connect(int32_t port) {
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
  /* Longer than the server's own 15-second in-flight deadline, so a stalled
   * request comes back as the server giving up rather than as this tool
   * giving up on it -- the difference between "the server hung" and "the test
   * was impatient" is the whole finding. */
  DWORD t = 25000;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&t, sizeof(t));
  return (uint64_t)s;
}

/* The liveness probe, in C because the answers it has to tell apart are
 * different results of one `recv` and nothing above the socket can see them.
 *
 * "The server is down" is four different findings, and they are found in four
 * different places: nothing is listening at all; something accepted and then
 * dropped the connection; something accepted and never spoke; something spoke
 * and what it said is not an HTTP response. A probe that answers only
 * yes-or-no reports all four as "dead", and the first thing anyone reading
 * that has to do is work out which one it was.
 *
 * Return: 0 nothing is listening, 1 accepted then closed, 2 accepted and
 * silent past the deadline, 3 answered with bytes that are not HTTP, and
 * 1000 + the status code for an HTTP answer. */
static int32_t aowl_fuzz_probe(int32_t port, int32_t timeoutMs) {
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
  DWORD t = (DWORD)timeoutMs;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&t, sizeof(t));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&t, sizeof(t));
  static const char *req =
    "GET /client/game/config HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    "Content-Length: 0\r\nConnection: close\r\n\r\n";
  int len = (int)strlen(req);
  if (send(s, req, len, 0) != len) { closesocket(s); return 1; }
  char buf[256];
  int n = recv(s, buf, (int)sizeof(buf), 0);
  if (n == 0) { closesocket(s); return 1; }
  if (n < 0) {
    int e = WSAGetLastError();
    closesocket(s);
    /* A reset is the connection being torn down under us -- the same finding
     * as a clean close, from this side. Only the deadline expiring means the
     * server is there and not talking. */
    return (e == WSAETIMEDOUT) ? 2 : 1;
  }
  closesocket(s);
  if (n < 12 || memcmp(buf, "HTTP/1.", 7) != 0) return 3;
  if (buf[9] < '0' || buf[9] > '9' || buf[10] < '0' || buf[10] > '9' ||
      buf[11] < '0' || buf[11] > '9') return 3;
  return 1000 + (buf[9] - '0') * 100 + (buf[10] - '0') * 10 + (buf[11] - '0');
}

/* What a process that is gone exited with. -1 when it cannot be asked.
 *
 * A fault code and an ordinary one are different findings: `0xc0000005` is the
 * server crashing on the request that was in flight, and `0` or `1` is a
 * process that was told to stop -- which, on a machine running more than one
 * of these tools at once, is the likelier answer and the one that stops
 * somebody debugging an innocent request. */
/* Stop the process and *keep* the handle open, so its exit code can still be
 * read afterwards. `aowl_spawn_kill` closes the handle on the way out, which
 * for the self test below would throw away the one fact it is checking. */
static void aowl_fuzz_terminate(uint64_t handle) {
  if (handle) TerminateProcess((HANDLE)(uintptr_t)handle, 0);
}

static int64_t aowl_fuzz_exit_code(uint64_t handle) {
  DWORD code = 0;
  if (!handle) return -1;
  if (!GetExitCodeProcess((HANDLE)(uintptr_t)handle, &code)) return -1;
  return (int64_t)(uint32_t)code;
}

static int64_t aowl_fuzz_now_us(void) {
  LARGE_INTEGER v, f;
  QueryPerformanceCounter(&v);
  QueryPerformanceFrequency(&f);
  return (int64_t)((v.QuadPart / f.QuadPart) * 1000000LL +
                   ((v.QuadPart % f.QuadPart) * 1000000LL) / f.QuadPart);
}
""".}

proc cFuzzConnect(port: int32): uint64 {.importc: "aowl_fuzz_connect", nodecl.}
proc cFuzzProbe(port, timeoutMs: int32): int32 {.
  importc: "aowl_fuzz_probe", nodecl.}
proc cFuzzExitCode(handle: uint64): int64 {.
  importc: "aowl_fuzz_exit_code", nodecl.}
proc cFuzzTerminate(handle: uint64) {.importc: "aowl_fuzz_terminate", nodecl.}
proc fuzzNowUs(): int64 {.importc: "aowl_fuzz_now_us", nodecl.}

const
  Usage = """
fuzzwire -- drive the backend with hostile input

  fuzzwire --root PATH --backend PATH [--port N]

  --root PATH      the scratch install (mods/, db.json)
  --backend PATH   aowlspt-backend.exe
  --port N         port to serve on (default 6977)
  --keep           leave the backend running at the end
  --kill-after TXT kill the backend after the first case whose name contains
                   TXT, and require the death to be reported against that case
                   -- the self test for the attribution below
  -h, --help       this
"""
  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"
  Other = "bbbbbbbbbbbbbbbbbbbbbbbb"

var gFailures = 0
var gChecks = 0
var gPort = 6977
var gBackend = ""
var gRoot = ""
var gProc = 0'u64
var gKillAfter = ""
var gKilled = ""
var gDeaths: seq[string] = @[]
var gProbeStatus = 0

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

var gSkippedPhases: seq[string] = @[]

proc phaseRuns(phase, uid, moneyId, stashId: string): bool =
  ## Whether a semantic phase has what it needs, asserted rather than assumed.
  ##
  ## Everything from "Ids that are lies" down needs one profile with money and a
  ## stash in it, and every one of those phases used to begin `if uid.len == 24`.
  ## When that was false the phases did not fail -- they were *not there*. The
  ## measured cost of that: renaming the `uid` field in the create response takes
  ## this tool from 149 checks to 129, reports one failure, and says nothing at
  ## all about the twenty checks that stopped happening. A green run is supposed
  ## to mean the checks passed, not that they were skipped, so a phase that
  ## cannot run is a failure with its own name on it.
  result = uid.len == 24 and moneyId.len == 24 and stashId.len == 24
  if not result:
    gSkippedPhases.add phase
    check(phase & ": the profile this phase attacks exists", false,
          "uid=\"" & uid & "\" money=\"" & moneyId & "\" stash=\"" & stashId &
          "\" -- every check in this phase was skipped, not passed")

# --------------------------------------------------------------- raw wire
#
# `wire.request` is the polite client: it frames the body, writes a well-formed
# head and reads the answer. Everything below it is what this tool needs -- the
# bytes on the socket, chosen here, including bytes that are not a request at
# all.

type
  Raw = object
    reached: bool
      ## The bytes got onto a socket at all. `false` is a connection that was
      ## never made, and it has to be told apart from an exchange that
      ## happened: every "it ended promptly" claim below is measured from a
      ## clock that also reads near zero when nothing was sent, so a check that
      ## does not require this passes hardest when the server is least there.
    answered: bool
      ## The server wrote something back. `false` means it closed, or never
      ## spoke inside the deadline -- which for a request that should have been
      ## refused is itself a finding.
    status: string
    body: string
    elapsedMs: int
    inflateFailed: bool

proc openRaw(): uint64 =
  result = cFuzzConnect(int32(gPort))

proc sendRaw(sock: uint64; bytes: string): bool =
  if sock == 0'u64 or bytes.len == 0:
    return false
  var b = toBytes(bytes)
  result = cSend(sock, cast[WirePtr](addr b[0]), int32(bytes.len)) >= 0'i32

proc readRaw(sock: uint64): Raw =
  ## Reads to end of stream and takes the response apart. The socket carries a
  ## receive deadline from `aowl_fuzz_connect`, so a server that never answers
  ## comes back as `answered = false` rather than hanging this tool with it.
  result = Raw(reached: true, answered: false, status: "", body: "",
               elapsedMs: 0, inflateFailed: false)
  let startedAt = fuzzNowUs()
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
  result.elapsedMs = int((fuzzNowUs() - startedAt) div 1000'i64)
  if have == 0:
    return

  var headEnd = -1
  var sep = 4
  var k = 0
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
    return

  result.answered = true
  result.status = splitLines(bytesAt(buf, 0, headEnd))[0]
  let bodyStart = headEnd + sep
  if bodyStart >= have:
    return
  let rawLen = have - bodyStart
  let rawAt = cast[WirePtr](cast[uint](addr buf[0]) + uint(bodyStart))
  if cZlibFramed(rawAt, int32(rawLen)) == 0'i32:
    result.body = bytesAt(buf, bodyStart, rawLen)
    return
  var cap = rawLen * 8
  if cap < 65536: cap = 65536
  var tries = 0
  while tries < 6:
    var dst = newSeq[byte](cap)
    let room = dst.len
    let m = cZlibInflate(rawAt, int32(rawLen), cast[WirePtr](addr dst[0]),
                         int32(room))
    if m >= 0'i32:
      result.body = fromBytes(dst, int(m))
      return
    cap = room * 4
    inc tries
  result.inflateFailed = true

proc hostile(bytes: string): Raw =
  ## One exchange of exactly these bytes, on a connection of its own.
  let sock = openRaw()
  if sock == 0'u64:
    result = Raw(reached: false, answered: false, status: "",
                 body: "could not connect", elapsedMs: 0, inflateFailed: false)
    return
  discard sendRaw(sock, bytes)
  result = readRaw(sock)
  cClose(sock)

proc deflated(body: string): string =
  ## `body` as the zlib stream the client would have sent.
  if body.len == 0:
    return ""
  var src = toBytes(body)
  let cap = cZlibBound(int32(body.len))
  var packed = newSeq[byte](int(cap))
  let m = cZlibDeflate(cast[WirePtr](addr src[0]), int32(body.len),
                       cast[WirePtr](addr packed[0]), cap)
  if m < 0'i32:
    return ""
  result = bytesAt(packed, 0, int(m))

proc framed(path, payload, session: string; length = -1): string =
  ## A well-formed request head with a body of the caller's choosing. `length`
  ## overrides the declared `Content-Length`, which is the point of several of
  ## the checks below.
  let declared = if length >= 0: length else: payload.len
  result = (if payload.len > 0: "POST " else: "GET ") & path & " HTTP/1.1\r\n"
  result.add "Host: 127.0.0.1:" & $gPort & "\r\n"
  if session.len > 0:
    result.add "Cookie: PHPSESSID=" & session & "\r\n"
  result.add "Content-Length: " & $declared & "\r\n"
  result.add "Connection: close\r\n\r\n"
  result.add payload

proc call(path, body: string): Response =
  result = request(gPort, path, body, Session)

proc callAs(path, body, session: string): Response =
  result = request(gPort, path, body, session)

proc move(actions: string): Response =
  result = call("/client/game/profile/items/moving",
                "{\"data\":[" & actions & "],\"tm\":2}")

# --------------------------------------------------------------- judgements

proc specific(r: Raw): bool =
  ## Whether a refusal says what it refused.
  ##
  ## The bar is deliberately crude -- a body, with an `err` in it, long enough
  ## to be a sentence rather than a shrug. It is not a spelling test; it is the
  ## difference between `400` with nothing in it and `400` with a reason, and
  ## the first one is what this tool exists to stop being shipped.
  result = r.body.len >= 24 and find(r.body, "\"err\"") >= 0

proc warned(r: Response; text: string): bool =
  ## A route refusal: the emulator answers `err:0` with a `warnings` entry for
  ## anything it declines inside an otherwise valid batch.
  result = r.ok and find(r.body, text) >= 0

proc printable(s: string): string =
  ## Bytes as something a failure line can carry. A finding is only actionable
  ## if the exact input is in it, and half the inputs here are not text.
  result = ""
  var i = 0
  while i < s.len and i < 220:
    let c = ord(s[i])
    if c == 13: result.add "\\r"
    elif c == 10: result.add "\\n"
    elif c < 32 or c > 126:
      const Hex = "0123456789abcdef"
      result.add "\\x"
      result.add Hex[(c shr 4) and 15]
      result.add Hex[c and 15]
    else: result.add s[i]
    inc i
  if s.len > 220:
    result.add " ... (" & $s.len & " bytes)"

proc alive(): bool =
  result = gProc == 0'u64 or cSpawnAlive(gProc) != 0'i32

# ------------------------------------------------------------------ liveness
#
# "The server is down" is not one finding, and the tool that reports it as one
# sends whoever reads it looking in the wrong place. Four things this probe
# tells apart, because they are four different bugs:
#
#   the process is gone         -- it crashed, and the crash is the finding
#   nothing is listening        -- it is running and not serving; it never bound,
#                                  or the listener is gone and the process is not
#   it accepted and closed      -- the connection got as far as the server and
#                                  the server dropped it without an answer
#   it accepted and said nothing -- it is wedged: a thread, a lock, or a read
#                                  that never returns
#
# and the fifth, which is the only one that is not a finding: it answered.

type
  Liveness = enum
    lvServing     ## an ordinary request came back `200`
    lvErroring    ## it spoke HTTP, with a status that is not `200`
    lvGarbled     ## it wrote bytes back that are not an HTTP response
    lvSilent      ## it accepted the connection and never spoke
    lvClosed      ## it accepted the connection and closed it unanswered
    lvRefused     ## nothing is listening on the port
    lvGone        ## the process has exited

proc probeAt(port: int; status: var int): Liveness =
  ## One ordinary request on a connection of its own, and what became of it.
  ##
  ## Deliberately not `wire.request`: that reports `ok = false` for every one
  ## of the states below, which is the collapse this exists to undo.
  status = 0
  let code = int(cFuzzProbe(int32(port), 4000'i32))
  if code >= 1000:
    status = code - 1000
    if status == 200:
      return lvServing
    return lvErroring
  case code
  of 3: result = lvGarbled
  of 2: result = lvSilent
  of 1: result = lvClosed
  else: result = lvRefused

proc hex32(v: int64): string =
  const Digits = "0123456789abcdef"
  result = "0x"
  var shift = 28
  while shift >= 0:
    result.add Digits[int((v shr shift) and 15'i64)]
    shift = shift - 4

proc whyGone(code: int64): string =
  ## An exit code as the thing worth knowing about it.
  ##
  ## The distinction is not decoration. A fault code means the request named
  ## above took the process down and the finding is real; `0` or `1` means
  ## something *stopped* it -- another tool's cleanup, a gate run tidying up
  ## backends by name, a person at a console -- and reading that as a crash on
  ## the named request is how an afternoon goes into a bug that was never
  ## there.
  if code < 0:
    return "the exit code could not be read"
  if code == 0'i64 or code == 1'i64:
    return "exit code " & $int(code) &
           ", an ordinary exit rather than a fault -- something stopped it," &
           " which is not the same as the request above killing it"
  if (code and 0xf0000000'i64) == 0xc0000000'i64:
    var what = "a fault"
    if code == 0xc0000005'i64: what = "an access violation"
    elif code == 0xc00000fd'i64: what = "a stack overflow"
    elif code == 0xc0000374'i64: what = "heap corruption"
    elif code == 0xc0000409'i64: what = "a failed stack cookie or bounds check"
    elif code == 0xc000001d'i64: what = "an illegal instruction"
    return "exit code " & hex32(code) & ", " & what & " -- it crashed"
  result = "exit code " & hex32(code)

proc describe(state: Liveness; status: int): string =
  case state
  of lvServing: result = "it answered 200"
  of lvErroring:
    result = "it is listening and answered " & $status &
             " to an ordinary request -- the process is up and the route is not"
  of lvGarbled:
    result = "it wrote bytes back that are not an HTTP response"
  of lvSilent:
    result = "it accepted the connection and never spoke -- the process is " &
             "up and wedged, not gone"
  of lvClosed:
    result = "it accepted the connection and closed it without answering"
  of lvRefused:
    result = "nothing is listening on that port -- for the server's own port," &
             " with the process still up, that is a server that stopped" &
             " serving without dying"
  of lvGone:
    result = "the process has exited: " & whyGone(cFuzzExitCode(gProc))

proc probe(): Liveness =
  ## The state of the server, retried where a retry can change the answer.
  ##
  ## One refused `connect` is not proof of death: the listener's backlog can be
  ## full for a moment under the storm this tool runs, and a single probe that
  ## lands in that moment reports a server that is answering as one that has
  ## gone -- which is a *misattributed* death, the thing this file is most
  ## careful about. A silent or garbled answer is not a backlog artefact, so it
  ## is confirmed once and believed.
  result = lvGone
  var status = 0
  var tries = 0
  while tries < 8:
    result = probeAt(gPort, status)
    gProbeStatus = status
    if result == lvServing:
      return
    if gProc != 0'u64 and cSpawnAlive(gProc) == 0'i32:
      gProbeStatus = 0
      return lvGone
    if result != lvRefused and result != lvClosed and tries >= 1:
      return
    inc tries
    cSleepMs(150'i32)

# --------------------------------------------------------------- readers

proc findFrom(haystack, needle: string; start: int): int =
  if start >= haystack.len:
    return -1
  let at = find(haystack.substr(start), needle)
  if at < 0:
    return -1
  result = start + at

proc textAt(body: string; start: int; key: string): string =
  let at = findFrom(body, "\"" & key & "\":\"", start)
  if at < 0:
    return ""
  var i = at + key.len + 4
  result = ""
  while i < body.len and body[i] != '"':
    result.add body[i]
    inc i

proc jsonText(body, key: string): string = textAt(body, 0, key)

proc idOfTemplate(body, tpl: string): string =
  ## The `_id` of the item carrying this `_tpl`, found by scanning back -- an
  ## item's id is the one *before* its template in the document.
  let at = find(body, "\"_tpl\":\"" & tpl & "\"")
  if at < 0:
    return ""
  var i = at
  while i > 0:
    if i + 7 < body.len and body.substr(i, i + 6) == "\"_id\":\"":
      var k = i + 7
      result = ""
      while k < body.len and body[k] != '"':
        result.add body[k]
        inc k
      return result
    dec i
  result = ""

proc profileOf(listBody, uid: string): string =
  ## One profile document out of a `profile/list` response. Needed because the
  ## scav's item list is the PMC's stash spliced in at read time, so every stash
  ## item appears twice in the whole response.
  let at = find(listBody, "{\"_id\":\"" & uid & "\"")
  if at < 0:
    return ""
  var depth = 0
  var i = at
  var inString = false
  while i < listBody.len:
    let c = listBody[i]
    if inString:
      if c == '\\': inc i
      elif c == '"': inString = false
    elif c == '"': inString = true
    elif c == '{': inc depth
    elif c == '}':
      dec depth
      if depth == 0: break
    inc i
  if depth != 0:
    return ""
  result = listBody.substr(at, i)

proc countOf(haystack, needle: string): int =
  result = 0
  var i = 0
  while i < haystack.len:
    let at = find(haystack.substr(i), needle)
    if at < 0:
      return
    inc result
    i = i + at + needle.len

proc readable(doc: string): bool =
  ## Whether a profile document came back at all.
  ##
  ## `profileOf` answers `""` for a list it could not find the profile in, and
  ## an empty document is the quietest possible failure: `cycleIn("")` is `""`,
  ## `find("", anything)` is `-1` and `countOf("", x)` is `0`, so the checks
  ## downstream of it either pass with nothing behind them or fail saying the
  ## stash was sold and the money is gone. Both are lies about the same
  ## missing read. Same bound the tree phase already used on the document it
  ## walks; this is that guard, applied to every document rather than one.
  result = doc.len > 200 and countOf(doc, "\"_id\":\"") > 3

proc about(doc, detail: string): string =
  ## The detail a check carries when the document it judges never arrived.
  if readable(doc):
    result = detail
  else:
    result = "the profile document did not come back (" & $doc.len &
             " bytes) -- this check could not be made, so it is failed rather" &
             " than passed, and it is not evidence about the request above it"

proc cycleIn(profileDoc: string): string =
  ## "" when the inventory is a tree; otherwise the id the walk came back to.
  ##
  ## An item that is its own ancestor is not a cosmetic problem: the client
  ## builds the stash by walking `parentId` from the root, so a cycle is either
  ## a hang or a stash that draws nothing, and no later request can undo it --
  ## the drag that would move the item out has to find the item first.
  ##
  ## Each item is read as the slice between its `"_id"` and the next one, which
  ## is the same bound `emutest` reads stacks with and for the same reason:
  ## read forward without one and an item with no `parentId` reports the *next*
  ## item's parent.
  var ids: seq[string] = @[]
  var parents: seq[string] = @[]
  var i = 0
  while true:
    let at = findFrom(profileDoc, "\"_id\":\"", i)
    if at < 0:
      break
    var stop = findFrom(profileDoc, "\"_id\":\"", at + 7)
    if stop < 0:
      stop = profileDoc.len
    let slice = profileDoc.substr(at, stop - 1)
    ids.add textAt(slice, 0, "_id")
    parents.add textAt(slice, 0, "parentId")
    i = at + 7

  for n in 0 ..< ids.len:
    var steps = 0
    var cur = parents[n]
    while cur.len > 0 and steps <= ids.len + 1:
      if cur == ids[n]:
        return ids[n]
      var next = ""
      for m in 0 ..< ids.len:
        if ids[m] == cur:
          next = parents[m]
          break
      cur = next
      inc steps
    if steps > ids.len:
      return ids[n]
  result = ""

proc routesFromLog(): seq[string] =
  ## Every route the backend registered, read out of its own log.
  ##
  ## This is the whole reason the tool does not carry a list. The backend logs
  ## `route <url>` as each mod registers one, so whatever is loaded is what gets
  ## fuzzed -- an endpoint added to `mods/tarkov` next week is covered by this
  ## run without anyone remembering to add it here.
  result = @[]
  var text = ""
  if not readTextFile(joinPath(gRoot, "aowlspt-backend.log"), text):
    return
  for line in splitLines(text):
    let at = find(line, "route /")
    if at < 0:
      continue
    var url = strip(line.substr(at + 6))
    let space = find(url, " ")
    if space >= 0:
      # `route /client/locale/ (prefix)` -- the prefix marker is not part of it.
      url = url.substr(0, space - 1)
    if url.len > 1:
      result.add url

# --------------------------------------------------------------- the backend

proc startupRefusal(): string =
  ## The backend's own words for a start it refused, or "".
  ##
  ## It will not start on a port or a store another process holds, and it says
  ## which. That is worth reading rather than guessing at, because the shape it
  ## makes from out here is indistinguishable from a healthy server otherwise:
  ## the process that already holds the port goes on answering, so the port is
  ## up, the config route replies, and every check that follows is a report
  ## about a server this run did not start. Only the sentences that mean a
  ## refused *start* count -- an ordinary error line logged by a serving
  ## backend is not one.
  ##
  ## `openLog` truncates per run, so an error at the top of the file belongs to
  ## the process that was spawned last, which is the one being waited on.
  result = ""
  var text = ""
  if not readTextFile(logPath(), text):
    return
  for line in splitLines(text):
    let at = find(line, "] error")
    if at < 0:
      continue
    let msg = strip(line.substr(at + 7))
    if find(msg, "already using this store") >= 0 or
       find(msg, "already in use") >= 0 or
       find(msg, "could not listen") >= 0:
      return msg

proc itIsListening(): bool =
  ## Whether the process just spawned got as far as binding the port.
  ##
  ## `listening on 127.0.0.1:<port>` is written from the bind's own result and
  ## nowhere else, and `startBackend` removed the file before the spawn -- so
  ## this line is proof that the server answering is the one this run started,
  ## which "the port answers" on its own is not.
  var text = ""
  if not readTextFile(logPath(), text):
    return false
  ## The scheme is part of that line and this used to not allow for one.
  ## `aowlbackend` writes `listening on <scheme>://127.0.0.1:<port>`, and it
  ## gained the scheme when it learned to serve TLS. The old pattern --
  ## `listening on 127.0.0.1:` -- stopped matching the moment that landed, so
  ## `itIsListening` was permanently false and every run of this tool ended in
  ## "it never answered", against a server that was answering perfectly well.
  ## Matched on `://127.0.0.1:<port>` now, which is what the two spellings have
  ## in common.
  result = find(text, "://127.0.0.1:" & $gPort) >= 0

proc waitUntilServing(tries: int): string =
  ## "" when the backend **this tool started** is the one now serving, and
  ## otherwise why not, in one sentence.
  ##
  ## Three different answers used to be one `false`: it refused to start, it
  ## started and died, and it never answered in time. The fourth is the one
  ## that has to be caught rather than reported -- the port answers and the
  ## child is gone, which means somebody else's server is about to be fuzzed
  ## and blamed.
  var i = 0
  while i < tries:
    let why = startupRefusal()
    if why.len > 0:
      return "it refused to start: " & why
    let r = call("/client/game/config", "")
    if r.ok and r.contains("\"err\":0") and itIsListening():
      if alive():
        return ""
      return "port " & $gPort & " is answering and the process this tool " &
             "started is not running -- something else is serving " & gRoot
    if not alive():
      if r.ok and r.contains("\"err\":0"):
        # It is gone and the port still answers: the server being talked to is
        # not this run's. Said in those words rather than as "it died", because
        # the fix is to close the other one and nothing about this one.
        return "the backend this tool started has exited and port " & $gPort &
               " is still answering -- something else is serving " & gRoot
      return "it exited before it answered, and its log says no reason"
    cSleepMs(200'i32)
    inc i
  result = "it never answered /client/game/config in " & $(tries * 200) & " ms"

proc logPath(): string = joinPath(gRoot, "aowlspt-backend.log")

proc startBackend(): uint64 =
  ## The log goes first, and that is not tidiness.
  ##
  ## Everything this tool knows about a start it did not watch comes out of
  ## that file -- whether the backend refused the port, whether it got as far
  ## as listening, which routes it registered. The backend truncates it itself
  ## on the way up, but not until it is running, and the window before that is
  ## exactly when a start that fails is being diagnosed: read it a moment too
  ## early and the answer is the *previous* server's, which on a held port is
  ## the server that is still answering. Removed here, so anything found in it
  ## afterwards was written by the process just spawned.
  discard removeFileAt(logPath())
  var e = gBackend
  var w = gRoot
  var c = "\"" & gBackend & "\" --root \"" & gRoot & "\" --port " & $gPort
  result = cSpawn(toCString(e), toCString(w), toCString(c))

proc recover(state: Liveness) =
  ## Brings the server back so the rest of the run still means something. A
  ## tool that stops at the first crash finds one bug per run.
  ##
  ## What it will not do is roll the two failures into one. A server that did
  ## not come back is not a second crash, and until the backend learned to
  ## refuse a held port out loud there was no way to tell those apart from out
  ## here -- every restart that landed on a port the dying process had not
  ## finished letting go of read as another death, on whatever request came
  ## next.
  if state != lvGone:
    # Wedged rather than dead: it has to go before another can bind the port.
    cSpawnKill(gProc)
    cSleepMs(300'i32)
  gProc = startBackend()
  if gProc == 0'u64:
    err "  and the replacement backend could not be spawned at all"
    inc gFailures
    return
  # It did not come up is a different fact from the death above it, and it is
  # reported as its own line rather than folded into the next request's name.
  let why = waitUntilServing(60)
  if why.len == 0:
    note "  the server was restarted; what follows is a fresh process"
    return
  err "  and the replacement backend is not serving: " & why
  note "  every check after this one is against a server that is not there;" &
       " they are not evidence about the requests they name"
  inc gFailures

proc probed(name, caveat: string): bool =
  ## The probe behind every attribution in this file.
  ##
  ## On a healthy run it adds no check and says nothing -- the count stays what
  ## it was -- and on an unhealthy one it is the only thing that names the
  ## request. `caveat` is empty when the name is the request that was on the
  ## wire, and is the honest disclaimer when it is a span of them.
  if gKillAfter.len > 0 and gKilled.len == 0 and find(name, gKillAfter) >= 0:
    gKilled = name
    note "--kill-after: killing the backend after \"" & name & "\""
    cFuzzTerminate(gProc)
    cSleepMs(200'i32)
  let state = probe()
  if state == lvServing:
    return true
  gDeaths.add name
  check(name & ": the server is still serving afterwards", false,
        describe(state, gProbeStatus) & caveat)
  recover(state)
  result = false

proc afterCase(what: string): bool =
  ## The probe that runs after **one** case, with that case's own name on it.
  ##
  ## This is the whole point. The old shape asked once per phase, so a phase
  ## that sent nine hostile bodies and then found the process gone named the
  ## ninth -- and the report that cost a day said the server died on
  ## `Content-Length: 9000000000000000000` for a phase that had already sent a
  ## truncated zlib stream, a garbage one, two length lies and a zero-length
  ## body behind it. The value in that report was handled correctly at every
  ## site; the death was somewhere else entirely. A probe costs one loopback
  ## request. A wrong name on a death costs an afternoon.
  result = probed(what, "")

proc afterSpan(phase, span: string): bool =
  ## The probe for a stretch this tool genuinely cannot cut any finer --
  ## requests in flight at once, or a phase whose cases cannot be separated.
  ##
  ## It names the stretch and says outright that it does not know which request
  ## did it. A vague report is a bad report; a confident wrong one is worse,
  ## because it is the one that gets believed and chased.
  result = probed(phase & " (" & span & ")",
                  " -- fuzzwire cannot say which of those requests did it")

proc settled(phase: string) =
  ## The check that every hostile phase ends with.
  ##
  ## Three claims, and they are different claims. The process is still there;
  ## an ordinary request still answers; and the profile store still reads back.
  ## A server can pass the first two and fail the third -- a half-written
  ## profile answers `err:0` on a route that does not touch it -- and the third
  ## is the one a player loses a character to.
  ##
  ## The first of the three is a phase-wide claim by construction, so it says
  ## so: by the time it runs, everything in the phase has been on the wire, and
  ## the per-case probes above are what carry the names.
  let state = probe()
  check(phase & ": the process is still up", state != lvGone,
        describe(state, gProbeStatus) &
        " -- somewhere in this phase; the cases in it are probed one by one")
  let cfg = call("/client/game/config", "")
  check(phase & ": an ordinary request still answers",
        cfg.ok and cfg.contains("\"err\":0"),
        if cfg.error.len > 0: cfg.error else: cfg.body)
  let list = call("/client/game/profile/list", "")
  check(phase & ": the profile store still reads back",
        list.ok and list.contains("\"err\":0"), list.body)

# --------------------------------------------------------------- main

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
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any: gPort = v
    elif a == "--kill-after":
      inc i
      if i <= n: gKillAfter = paramStr(i)
    elif a == "--keep":
      keep = true
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      err "unknown option: " & a
      return 1
    inc i

  # Absolute, before anything uses it.
  #
  # The child is started **with its working directory set to the root** and
  # `--root` on its command line. A relative root is then resolved twice: the
  # backend joins it to its own new cwd and lands in `<root>/<root>`. That was
  # live -- `installer/build/gate-fuzzstage/installer/build/gate-fuzzstage/`
  # exists on disk, with the log and the store in it, while the stage's own top
  # level has neither -- and it is silent, because the server starts perfectly
  # well in the wrong place.
  # Guarded, because `absolutePathOf("")` answers the current directory, and a
  # run with no `--root` would then quietly point at wherever it was started.
  if gRoot.len > 0:
    gRoot = absolutePathOf(gRoot)

  if gRoot.len == 0 or gBackend.len == 0:
    echo Usage
    return 1
  if not fileExists(gBackend):
    err "no backend at " & gBackend
    return 1

  discard cNetStartup()

  heading "Starting"
  gProc = startBackend()
  if gProc == 0'u64:
    err "could not start the backend"
    return 1
  let notServing = waitUntilServing(60)
  if notServing.len > 0:
    # "It did not come up" and "it came up and died" are different failures
    # with different fixes, and this used to report both as one sentence. The
    # third one is worse than either: a held port or a held store leaves the
    # *previous* server answering while this run's backend refuses to start, so
    # everything below would be a hostile-input report about a process this
    # tool did not launch -- findings against the wrong binary, which is
    # exactly how the report that prompted this rewrite came about.
    err "the backend did not come up: " & notServing
    err "  close whatever is on port " & $gPort & " and " & gRoot &
        ", or run with --port and a stage of your own"
    cSpawnKill(gProc)
    return 1
  ok "the backend is serving on " & $gPort

  # ------------------------------------------------------------- the instrument
  #
  # Every attribution below rests on this probe, so it is checked before it is
  # used to judge anything. An instrument that answers "dead" for a server that
  # is fine, or "fine" for one that is not listening, does not produce a weaker
  # report -- it produces a wrong one, against a named request that was
  # innocent, which is exactly the failure this file was rewritten to stop
  # making.

  heading "The liveness probe"
  block:
    var status = 0
    let up = probeAt(gPort, status)
    check("the liveness probe sees a serving server", up == lvServing,
          describe(up, status))
    # Port 1 has no listener on this machine and cannot get one without
    # privileges, so a refused connect there is not luck. This is the half that
    # matters for attribution: `lvRefused` and `lvGone` must not be the same
    # answer, or "it stopped serving" and "it crashed" are the same report.
    var offStatus = 0
    let off = probeAt(1, offStatus)
    check("and tells a port with nothing behind it from a serving one",
          off == lvRefused, describe(off, offStatus))

  # ------------------------------------------------------------- framing
  #
  # The body is zlib both ways, so the body is the first thing a client can lie
  # about. Every case here is a lie of a different shape, and the requirement is
  # the same one each time: a named refusal, quickly, with the server still
  # there afterwards.

  heading "Framing"
  block:
    # Every case here is probed the moment it has been sent, under its own
    # name, with nothing else on the wire in between -- the shape
    # `backend/framelen.nim` uses for the same reason. The phase-wide probe
    # this replaces is what put `Content-Length: 9000000000000000000` on a
    # death that was not its doing: it was merely the last thing the phase had
    # sent.
    let good = deflated("{\"nickname\":\"x\"}")

    var cut = good.substr(0, good.len div 2)
    var r = hostile(framed("/client/game/keepalive", cut, Session))
    check("a truncated zlib body is refused",
          r.answered and find(r.status, "400") >= 0, printable(cut))
    check("and the refusal says why", specific(r), r.status & " " & r.body)
    discard afterCase("a truncated zlib body")

    let garbage = "\x78\x9c" & repeat("\xff", 400)
    r = hostile(framed("/client/game/keepalive", garbage, Session))
    check("a zlib header with garbage behind it is refused",
          r.answered and find(r.status, "400") >= 0, printable(garbage))
    check("and that refusal says why too", specific(r), r.status & " " & r.body)
    discard afterCase("a zlib header with garbage behind it")

    # A body whose declared length is longer than what follows. The server
    # cannot know the rest is not coming, so this is a *deadline* check rather
    # than a parse check: it has to give up and answer rather than hold the
    # connection for good.
    r = hostile(framed("/client/game/keepalive", good, Session,
                       length = good.len + 4096))
    check("a body shorter than its Content-Length ends in an answer",
          r.answered, "no answer in " & $r.elapsedMs & " ms")
    discard afterCase("a body 4096 bytes shorter than its Content-Length")

    # And the same lie the other way: more bytes than declared. The extra is
    # the start of the next request on this connection, and reading it as part
    # of this one is how two parties come to disagree about where a request
    # ends.
    r = hostile(framed("/client/game/keepalive", good, Session, length = 2))
    check("a body longer than its Content-Length is still answered", r.answered,
          r.status)
    discard afterCase("a body longer than its Content-Length of 2")

    r = hostile(framed("/client/game/keepalive", "", Session))
    check("a zero-length body is an ordinary request",
          r.answered and find(r.status, "200") >= 0, r.status & " " & r.body)
    discard afterCase("a zero-length body")

    # Larger than any real request, declared but never sent. The allocation is
    # the attack: this used to be `newSeq[byte](contentLength)` with no ceiling
    # on it, and `Content-Length: 9000000000000000000` -- ninety bytes on the
    # wire -- took the process down on the bounds check that followed the failed
    # allocation.
    let absurd = "POST /client/game/keepalive HTTP/1.1\r\n" &
                 "Content-Length: 9000000000000000000\r\n" &
                 "Connection: close\r\n\r\nx"
    r = hostile(absurd)
    check("an absurd Content-Length is refused rather than allocated",
          r.answered and find(r.status, "413") >= 0, printable(absurd))
    check("and the refusal names the limit", specific(r), r.body)
    discard afterCase("Content-Length: 9000000000000000000")

    let big = "POST /client/game/keepalive HTTP/1.1\r\n" &
              "Content-Length: 2000000000\r\nConnection: close\r\n\r\nx"
    r = hostile(big)
    check("and so is one merely far larger than any request",
          r.answered and find(r.status, "413") >= 0, printable(big))
    discard afterCase("Content-Length: 2000000000")

  settled("framing")

  heading "A zip bomb"
  block:
    # Bounded on purpose: the claim is that the server refuses rather than
    # allocating, and a check that has to allocate a gigabyte to make it would
    # be the attack it is testing for. Sixty-four megabytes of one byte
    # compresses to about 64 KB, which is a body the server will happily read
    # and must not expand.
    var payload = ""
    var k = 0
    while k < 64 * 1024 * 1024:
      payload.add ' '
      inc k
    let bomb = deflated(payload)
    check("the bomb is small on the wire", bomb.len > 0 and bomb.len < 262144,
          $bomb.len & " bytes")
    let before = fuzzNowUs()
    let r = hostile(framed("/client/game/keepalive", bomb, Session))
    let tookMs = int((fuzzNowUs() - before) div 1000'i64)
    check("a body that decompresses to 64 MB is refused",
          r.answered and find(r.status, "200") < 0, r.status)
    check("and the refusal says why", specific(r), r.body)
    check("and it is refused rather than inflated first",
          r.reached and tookMs < 5000,
          if r.reached: $tookMs & " ms"
          else: "the connection was never made, so nothing was timed")
    discard afterCase("a body that inflates to 64 MB")

    # And the body just under the ceiling still goes through, because a bound
    # that also refuses the largest thing the game legitimately sends is a
    # server the client cannot come back from a raid to. Two megabytes is the
    # shape of a profile document at `match/local/end`.
    var ordinary = "{\"pad\":\""
    k = 0
    while k < 2 * 1024 * 1024:
      ordinary.add 'a'
      inc k
    ordinary.add "\"}"
    let fat = hostile(framed("/client/game/keepalive", deflated(ordinary),
                             Session))
    check("a two-megabyte body is still served",
          fat.answered and find(fat.status, "200") >= 0, fat.status)
    # Named for the body that was actually last on the wire. It used to say
    # "a 64 MB zip bomb" here, which is the request before this one -- a wrong
    # name on a death, one line long, of exactly the kind this rewrite is
    # about.
    discard afterCase("a two-megabyte body")

  settled("the zip bomb")

  # ------------------------------------------------------------- http
  #
  # The request line and the headers. None of this is a general HTTP parser
  # test: it is the set of things a hostile client can put where the server
  # reads a url, a length or a session out of.

  heading "HTTP"
  block:
    var probes: seq[string] = @[]
    probes.add "POST /client/game/keepalive HTTP/1.1\r\n\r\n"
    probes.add "POST /client/game/keepalive HTTP/1.1\r\nCookie:\r\n" &
               "Connection: close\r\n\r\n"
    probes.add "/client/game/keepalive HTTP/1.1\r\nConnection: close\r\n\r\n"
    probes.add "POST\r\nConnection: close\r\n\r\n"
    probes.add "\xff\xfe\x00\x01\r\n\r\n"
    probes.add "\r\n\r\n"
    probes.add "POST /client/game/keepalive HTTP/1.1\r\nX-Pad: " &
               repeat("A", 60000) & "\r\nConnection: close\r\n\r\n"
    probes.add "POST /client/game/keepalive HTTP/1.1\r\n: novalue\r\n" &
               "Connection: close\r\n\r\n"
    for p in probes:
      let r = hostile(p)
      check("answered rather than hung: " & printable(p.substr(0, 40)),
            r.answered, printable(p))
      if r.answered and find(r.status, "200") < 0:
        check("and said why: " & printable(p.substr(0, 40)), specific(r),
              r.status & " " & r.body)
      # Per probe, not per phase: eight of these go out, and a probe after the
      # eighth can only name the eighth.
      discard afterCase(printable(p.substr(0, 40)))

    # A header longer than the whole receive buffer. The connection cannot be
    # recovered -- there is no end of head to skip to -- so the server answers
    # 431 and closes, and the close usually arrives while this tool is still
    # writing, which on Windows resets the connection and takes the answer with
    # it. So the claim made here is the one that survives that race: the
    # exchange *ends*, promptly, and the server is still there. Whether the 431
    # gets through is noted rather than required.
    let flood = "POST /client/game/keepalive HTTP/1.1\r\nX-Pad: " &
                repeat("A", 200000) & "\r\n\r\n"
    let big = hostile(flood)
    # `reached` is load-bearing: the clock this reads starts after the connect,
    # so a connection that was never made also "ends promptly", and the version
    # of this check without it passed hardest against a server that was gone.
    check("headers that do not fit the buffer end the connection promptly",
          big.reached and big.elapsedMs < 20000,
          if big.reached: $big.elapsedMs & " ms"
          else: "the connection was never made, so nothing was timed")
    if big.answered:
      check("and the refusal says so",
            find(big.status, "431") >= 0 and specific(big),
            big.status & " " & big.body)
    else:
      note "the 431 was lost to the reset -- the connection ended in " &
           $big.elapsedMs & " ms"
    let afterFlood = probe()
    check("and the server is still there", afterFlood == lvServing,
          describe(afterFlood, gProbeStatus))
    if afterFlood != lvServing:
      gDeaths.add "a 200,000-byte header"
      recover(afterFlood)

    # Two lengths that disagree. Whichever one wins decides where this request
    # ends and the next begins, so a server that picks one is a server two
    # parties can be made to read the same bytes differently.
    let dup = "POST /client/game/keepalive HTTP/1.1\r\nContent-Length: 0\r\n" &
              "Content-Length: 5\r\nConnection: close\r\n\r\nhello"
    let dupR = hostile(dup)
    check("a disagreeing duplicate Content-Length is refused",
          dupR.answered and find(dupR.status, "400") >= 0, printable(dup))
    check("and that refusal says why", specific(dupR), dupR.body)
    discard afterCase("two Content-Length headers that disagree")

    let same = "POST /client/game/keepalive HTTP/1.1\r\nContent-Length: 0\r\n" &
               "Content-Length: 0\r\nConnection: close\r\n\r\n"
    let sameR = hostile(same)
    check("a duplicate that agrees with itself is not",
          sameR.answered and find(sameR.status, "200") >= 0, sameR.status)
    discard afterCase("two Content-Length headers that agree")

  settled("the request line")

  heading "URLs"
  block:
    # Whatever the url is, it comes back in the 404 body -- so whatever the url
    # is, the 404 body has to stay JSON. It did not: a url with a quote in it
    # produced `{"err":"no route","url":"/client/x"y"}`, which no parser reads,
    # and a url with a NUL or a stray 0x80 put bytes in a JSON string that are
    # not text at all.
    var urls: seq[string] = @[]
    urls.add "/client/" & repeat("a", 4000)
    urls.add "/client/x\"y"
    urls.add "/client/x\\y"
    urls.add "/client/\x00abc"
    urls.add "/client/\xff\xfe\x80"
    urls.add "/client/a\tb"
    urls.add "/"
    for u in urls:
      let r = hostile(framed(u, "", Session))
      check("a hostile url is answered: " & printable(u.substr(0, 30)),
            r.answered, printable(u))
      if r.answered and find(r.status, "404") >= 0:
        # The body has to be readable JSON. Checked by the two things that
        # actually broke: an unescaped quote closes the string early, and a
        # byte under 32 is not legal inside a JSON string at all.
        var clean = true
        var inEscape = false
        var quotes = 0
        for ch in r.body:
          if inEscape:
            inEscape = false
          elif ch == '\\':
            inEscape = true
          elif ch == '"':
            inc quotes
          elif ord(ch) < 32:
            clean = false
        check("and its 404 body is still JSON: " & printable(u.substr(0, 30)),
              clean and (quotes mod 2) == 0 and find(r.body, "no route") >= 0,
              printable(r.body))
      discard afterCase("the url " & printable(u.substr(0, 40)))

  settled("urls")

  heading "Session ids"
  block:
    var bad: seq[string] = @[]
    bad.add "aaa"
    bad.add repeat("a", 25)
    bad.add "zzzzzzzzzzzzzzzzzzzzzzzz"
    bad.add "aaaaaaaaaaaa aaaaaaaaaaa"
    bad.add "aaaaaaaaaaaaaaaaaaaa\"\";"
    for s in bad:
      let r = hostile(framed("/client/game/keepalive", "", s))
      check("a malformed session id is refused: " & printable(s),
            r.answered and find(r.status, "400") >= 0, r.status)
      check("and named as the reason", specific(r), r.body)
      discard afterCase("the session id " & printable(s))

    # Missing entirely is a different case and a legal one -- the client asks
    # for the config before it has a session -- so it must reach the route.
    let none = hostile(framed("/client/game/config", "", ""))
    check("no session id at all still reaches the route",
          none.answered and find(none.status, "200") >= 0, none.status)

    # And well-formed but unknown. This one is the interesting half: it is not
    # the server's job to refuse it, it is the mod's job to say there is no
    # profile behind it, and saying nothing is how a client sits on a blank
    # menu with a 200 in the log.
    let ghost = callAs("/client/game/profile/list", "",
                       "0123456789abcdef01234567")
    check("a well-formed session with no profile still answers",
          ghost.ok and ghost.contains("\"err\":0"), ghost.body)
    let ghostSelect = callAs("/client/game/profile/select",
                             "{\"uid\":\"ffffffffffffffffffffffff\"}",
                             "0123456789abcdef01234567")
    check("and selecting a profile that is not there says which",
          ghostSelect.contains("no such profile"), ghostSelect.body)

  settled("session ids")

  # ------------------------------------------------------------- json

  heading "JSON"
  block:
    var bodies: seq[string] = @[]
    bodies.add "{\"data\":[{\"Action\":\"Move\""
    bodies.add "}{"
    bodies.add "["
    bodies.add "\"just a string\""
    bodies.add "null"
    bodies.add "{\"data\":null}"
    bodies.add "{\"data\":{}}"
    bodies.add "{\"data\":[[1,2,3]]}"
    bodies.add "{\"data\":[{\"Action\":\"Move\",\"item\":{\"a\":1}}]}"
    bodies.add "{\"data\":[{\"Action\":\"Move\",\"item\":[1,2]}]}"
    bodies.add "{\"data\":[{\"Action\":\"Split\",\"count\":" &
               "99999999999999999999999999999999}]}"
    bodies.add "{\"data\":[{\"Action\":\"Split\",\"count\":-9223372036854775808}]}"
    bodies.add "{\"nickname\":\"a\\"
    bodies.add "{\"nickname\":\"\\u00\"}"
    bodies.add "{\"a\":1,\"a\":2,\"a\":3}"
    for b in bodies:
      let r = call("/client/game/profile/items/moving", b)
      check("malformed JSON is answered rather than fatal: " &
            printable(b.substr(0, 40)),
            r.ok and r.contains("\"err\""), r.error & r.body)
      discard afterCase("the body " & printable(b.substr(0, 40)))

    # Depth. The readers here are iterative by construction -- a depth counter
    # rather than a recursive descent -- and this is the check that keeps them
    # that way: a recursive parser meets a stack it cannot grow at some depth,
    # and the process goes down with no log line at all.
    var deep = "{\"data\":"
    var d = 0
    while d < 100000:
      deep.add '['
      inc d
    d = 0
    while d < 100000:
      deep.add ']'
      inc d
    deep.add '}'
    let deepR = call("/client/game/profile/items/moving", deep)
    check("100,000 levels of nesting is answered, not a stack overflow",
          deepR.ok, deepR.error)
    let afterDeep = probe()
    check("the server is still up after it", afterDeep == lvServing,
          describe(afterDeep, gProbeStatus))
    if afterDeep != lvServing:
      gDeaths.add "100,000 levels of nesting"
      recover(afterDeep)

    var deepObj = "{\"data\":"
    d = 0
    while d < 50000:
      deepObj.add "{\"a\":"
      inc d
    deepObj.add "1"
    d = 0
    while d < 50000:
      deepObj.add '}'
      inc d
    deepObj.add '}'
    let objR = call("/client/game/profile/items/moving", deepObj)
    check("and so is 50,000 levels of objects", objR.ok, objR.error)
    discard afterCase("50,000 levels of objects")

  settled("json")

  # ------------------------------------------------------------- routes

  heading "Every route"
  block:
    let routes = routesFromLog()
    check("the route table was read out of the backend's log",
          routes.len > 0,
          "no `route` lines in " & joinPath(gRoot, "aowlspt-backend.log"))
    if routes.len > 0:
      note $routes.len & " routes, read rather than listed"
    var broken = 0
    var quiet = 0
    for u in routes:
      # Three shapes per route, and the third is the one that finds things: an
      # empty body, an empty object, and a body of entirely the wrong type for
      # whatever this endpoint reads.
      var shapes: seq[string] = @[]
      shapes.add ""
      shapes.add "{}"
      shapes.add "[]"
      shapes.add "{\"data\":\"not an array\"}"
      shapes.add "{\"data\":[{\"Action\":12345}]}"
      shapes.add "0"
      for body in shapes:
        let r = call(u, body)
        if not r.ok:
          inc broken
          err "route " & u & " did not answer " &
              (if body.len == 0: "an empty body" else: body) & ": " & r.error
          inc gFailures
        elif find(r.body, "\"err\"") < 0 and r.body.len == 0:
          inc quiet
        # Per route *and per shape*. The old probe here ran once per route, so
        # six bodies went out and the name on a death was the route with no
        # word about which of the six was on the wire -- and the sixth is not
        # more likely to be the one than the first.
        discard afterCase("route " & u & " with " &
                          (if body.len == 0: "an empty body" else: body))
    # Guarded by the count as well as by `broken`: with no routes read, both of
    # these are claims about nothing, and both used to pass.
    check("every registered route answered every malformed shape",
          routes.len > 0 and broken == 0,
          if routes.len == 0: "no routes were read, so nothing was fuzzed"
          else: $broken & " did not")
    check("and none of them answered with nothing at all",
          routes.len > 0 and quiet == 0,
          if routes.len == 0: "no routes were read, so nothing was fuzzed"
          else: $quiet & " empty bodies")

  settled("every route")

  # ------------------------------------------------------------- semantics
  #
  # The attacks that matter. Everything above is a server that has to survive
  # nonsense; this is a server that has to survive a client that understands
  # the protocol perfectly and is lying inside it.

  heading "A profile to attack"
  var uid = ""
  var moneyId = ""
  var stashId = ""
  block:
    let created = call("/client/game/profile/create",
                       "{\"nickname\":\"Fuzz\",\"side\":\"Usec\",\"headId\":\"x\"}")
    uid = jsonText(created.body, "uid")
    check("a profile to attack", uid.len == 24, created.body)
    discard call("/client/game/profile/select", "{\"uid\":\"" & uid & "\"}")
    let listBody = call("/client/game/profile/list", "").body
    moneyId = idOfTemplate(listBody, "5449016a4bdc2d6f028b456f")
    stashId = jsonText(listBody, "stash")
    check("with money and a stash in it",
          moneyId.len == 24 and stashId.len == 24, moneyId & " " & stashId)

  heading "Ids that are lies"
  if phaseRuns("ids that are lies", uid, moneyId, stashId):
    let ghost = move("{\"Action\":\"Move\",\"item\":\"ffffffffffffffffffffffff\"," &
                     "\"to\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"}}")
    check("moving an item that does not exist says so",
          warned(ghost, "no such item"), ghost.body)
    discard afterCase("a move of an item that does not exist")

    # Another profile's item, named by a session that does not own it. The ids
    # are sequential, so guessing one is not the hard part -- refusing it is.
    discard callAs("/client/game/profile/create",
                   "{\"nickname\":\"Fuzz2\",\"side\":\"Bear\",\"headId\":\"x\"}",
                   Other)
    let others = callAs("/client/game/profile/list", "", Other).body
    let otherUid = jsonText(others, "uid")
    let stolen = callAs("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Move\",\"item\":\"" & moneyId &
      "\",\"to\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"}}],\"tm\":2}",
      Other)
    check("an item that belongs to another profile is refused",
          find(stolen.body, "no such item") >= 0, stolen.body)
    discard afterCase("a move of another profile's item")
    let stillMine = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and it is still in the profile that owns it",
          readable(stillMine) and find(stillMine, moneyId) >= 0,
          about(stillMine, "the item moved"))

  settled("ids")

  heading "Counts that are lies"
  if phaseRuns("counts that are lies", uid, moneyId, stashId):
    let neg = move("{\"Action\":\"Split\",\"splitItem\":\"" & moneyId &
      "\",\"newItem\":\"cccccccccccccccccccccccc\",\"count\":-5," &
      "\"container\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"," &
      "\"location\":{\"x\":6,\"y\":6,\"r\":\"Horizontal\"}}}")
    check("a negative split count is refused with a reason",
          warned(neg, "not a split") or warned(neg, "count"), neg.body)
    discard afterCase("a split of -5")

    let over = move("{\"Action\":\"Split\",\"splitItem\":\"" & moneyId &
      "\",\"newItem\":\"dddddddddddddddddddddddd\",\"count\":99999999," &
      "\"container\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"," &
      "\"location\":{\"x\":7,\"y\":6,\"r\":\"Horizontal\"}}}")
    check("a split larger than the stack is refused with a reason",
          warned(over, "stack"), over.body)
    discard afterCase("a split of 99999999 from a stack of 500000")

    let mine = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and neither of them created a stack",
          readable(mine) and
          find(mine, "cccccccccccccccccccccccc") < 0 and
          find(mine, "dddddddddddddddddddddddd") < 0,
          about(mine, "a refused split landed"))

  settled("counts")

  heading "The inventory tree"
  if phaseRuns("the inventory tree", uid, moneyId, stashId):
    let before = profileOf(call("/client/game/profile/list", "").body, uid)
    # The document first, then what is in it. `cycleIn` walks the items it can
    # find and answers "" for a document with none -- so every cycle check in
    # this phase passes against an empty string, which is exactly what
    # `profileOf` returns when it cannot find the profile at all. The three
    # checks below would then be reporting on a document that was never read.
    check("the profile document came back to be walked", readable(before),
          $before.len & " bytes, " & $countOf(before, "\"_id\":\"") & " ids")
    check("the inventory is a tree to begin with",
          readable(before) and cycleIn(before).len == 0,
          about(before, "cycle at " & cycleIn(before)))

    # An item moved into itself. There is no drag on any screen that produces
    # this and no reason to accept it: the client builds the stash by walking
    # `parentId` from the root, so an item that is its own parent is an item
    # nothing can reach and no later request can move back.
    let selfMove = move("{\"Action\":\"Move\",\"item\":\"" & moneyId &
      "\",\"to\":{\"id\":\"" & moneyId & "\",\"container\":\"hideout\"}}")
    discard afterCase("a move of an item into itself")
    let afterSelf = profileOf(call("/client/game/profile/list", "").body, uid)
    check("moving an item into itself does not make a cycle",
          readable(afterSelf) and cycleIn(afterSelf).len == 0,
          about(afterSelf, "cycle at " & cycleIn(afterSelf) &
                " -- request was " & selfMove.body))

    # And into its own child: the stash into something the stash holds. This is
    # the same rule one level out, and it is the one that costs a whole
    # inventory rather than one item.
    let intoChild = move("{\"Action\":\"Move\",\"item\":\"" & stashId &
      "\",\"to\":{\"id\":\"" & moneyId & "\",\"container\":\"hideout\"}}")
    discard afterCase("a move of the stash into its own child")
    let afterChild = profileOf(call("/client/game/profile/list", "").body, uid)
    check("moving a container into its own child does not make a cycle",
          readable(afterChild) and cycleIn(afterChild).len == 0,
          about(afterChild, "cycle at " & cycleIn(afterChild) &
                " -- request was " & intoChild.body))
    check("and the stash is still in the inventory",
          readable(afterChild) and
          find(afterChild, "\"_id\":\"" & stashId & "\"") >= 0,
          about(afterChild, "the stash container is gone from the item list"))

  settled("the inventory tree")

  heading "Selling what cannot be sold"
  if phaseRuns("selling what cannot be sold", uid, moneyId, stashId):
    # The stash itself, listed on the flea. It is an item in the item list like
    # any other, which is exactly why the check for "is this yours" is not
    # enough on its own -- the inventory root is yours, and listing it takes
    # every item in the profile with it.
    let sellStash = move("{\"Action\":\"RagFairAddOffer\"," &
      "\"sellInOnePiece\":false,\"items\":[\"" & stashId &
      "\"],\"requirements\":[{\"_tpl\":\"5449016a4bdc2d6f028b456f\"," &
      "\"count\":1}]}")
    discard afterCase("a flea listing of the stash container")
    let afterSale = profileOf(call("/client/game/profile/list", "").body, uid)
    check("the stash container cannot be listed on the flea",
          readable(afterSale) and
          find(afterSale, "\"_id\":\"" & stashId & "\"") >= 0,
          about(afterSale, "the stash left the profile -- request was " &
                sellStash.body))
    check("and the money is still there",
          readable(afterSale) and find(afterSale, moneyId) >= 0,
          about(afterSale, "the stash took the money with it"))

    let ghostOffer = move("{\"Action\":\"RagFairBuyOffer\",\"offers\":[{" &
      "\"id\":\"ffffffffffffffffffffffff\",\"count\":1,\"items\":[{\"id\":\"" &
      moneyId & "\",\"count\":1}]}]}")
    check("buying an offer that is not on the market says so",
          warned(ghostOffer, "no offer"), ghostOffer.body)
    discard afterCase("a buy of an offer that is not on the market")

    let emptyOffer = move("{\"Action\":\"RagFairBuyOffer\",\"offers\":[{" &
      "\"id\":\"\",\"count\":-3,\"items\":[]}]}")
    check("and so does an empty offer id with a negative count",
          emptyOffer.ok and find(emptyOffer.body, "warnings\":[{") >= 0,
          emptyOffer.body)
    discard afterCase("a buy of an empty offer id with a count of -3")

  settled("the flea")

  heading "Replays"
  if phaseRuns("replays", uid, moneyId, stashId):
    discard move("{\"Action\":\"HideoutUpgrade\",\"areaType\":3}")
    discard move("{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":3}")
    let again = move("{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":3}")
    check("a second complete on an area that is not being upgraded is refused",
          warned(again, "not being upgraded"), again.body)
    discard afterCase("a hideout upgrade completed twice")

    let noCraft = move("{\"Action\":\"HideoutTakeProduction\"," &
                       "\"recipeId\":\"there-is-no-such-recipe\"}")
    check("collecting a craft that was never started is refused",
          warned(noCraft, "nothing is being made") or
          warned(noCraft, "no such recipe"), noCraft.body)
    discard afterCase("a collect of a craft that was never started")

  settled("replays")

  heading "Two requests, one item"
  if phaseRuns("two requests, one item", uid, moneyId, stashId):
    # Four splits of the same stack, in flight at once on four connections.
    # Money is the thing to count: whatever the server does about the race, the
    # roubles in the profile afterwards must be the roubles it started with.
    # Losing an update is a bug; inventing one is an economy.
    let beforeBody = profileOf(call("/client/game/profile/list", "").body, uid)
    let beforeStacks = countOf(beforeBody, "5449016a4bdc2d6f028b456f")
    var socks: seq[uint64] = @[]
    var r = 0
    while r < 4:
      let s = openRaw()
      if s != 0'u64:
        let body = "{\"data\":[{\"Action\":\"Split\",\"splitItem\":\"" & moneyId &
          "\",\"newItem\":\"eeeeeeeeeeeeeeeeeeeeeee" & $r &
          "\",\"count\":100,\"container\":{\"id\":\"" & stashId &
          "\",\"container\":\"hideout\",\"location\":{\"x\":" & $r &
          ",\"y\":8,\"r\":\"Horizontal\"}}}],\"tm\":2}"
        discard sendRaw(s, framed("/client/game/profile/items/moving",
                                  deflated(body), Session))
        socks.add s
      inc r
    var answered = 0
    for s in socks:
      let resp = readRaw(s)
      if resp.answered and find(resp.status, "200") >= 0:
        inc answered
      cClose(s)
    if socks.len < 4:
      check("four connections were opened to race with", false,
            "only " & $socks.len & " connected, so what follows is a smaller" &
            " race than the one this phase claims to run")
    check("four racing requests all got an answer",
          socks.len == 4 and answered == socks.len,
          $answered & " of " & $socks.len)
    # Four requests were in flight together, so there is no order to point at
    # and this tool will not invent one: the failure says which four and says
    # it cannot tell them apart.
    let afterRace = probe()
    check("and the server is still up", afterRace == lvServing,
          describe(afterRace, gProbeStatus) &
          " -- after four splits of one stack in flight at once; fuzzwire" &
          " cannot say which of them did it")
    if afterRace != lvServing:
      gDeaths.add "the race (four splits in flight at once)"
      recover(afterRace)

    let afterBody = profileOf(call("/client/game/profile/list", "").body, uid)
    # Against what the tree looked like going in, not against "a tree": an
    # earlier phase may have left a cycle behind, and re-reporting it here
    # would name the race for damage the race did not do.
    check("the race did not add a cycle the profile did not already have",
          readable(afterBody) and readable(beforeBody) and
          cycleIn(afterBody) == cycleIn(beforeBody),
          about(afterBody, about(beforeBody,
                "cycle at " & cycleIn(afterBody) & ", was " &
                cycleIn(beforeBody))))
    check("and the profile still holds its money",
          readable(afterBody) and
          countOf(afterBody, "5449016a4bdc2d6f028b456f") >= beforeStacks,
          about(afterBody, "roubles went from " & $beforeStacks &
                " stacks to " &
                $countOf(afterBody, "5449016a4bdc2d6f028b456f")))

  settled("the race")

  heading "Slow clients"
  block:
    # A connection that declares a body and does not send it. Each one holds a
    # worker for the receive deadline, and the pool is the concurrency limit, so
    # this is the shape of a denial of service rather than a crash. The check is
    # that an ordinary request still gets through -- and how long it waited,
    # because that number is the exposure and it should be visible when it
    # changes.
    var held: seq[uint64] = @[]
    var i2 = 0
    while i2 < 12:
      let s = openRaw()
      if s != 0'u64:
        discard sendRaw(s, "POST /client/game/keepalive HTTP/1.1\r\n" &
                           "Content-Length: 5000\r\n" &
                           "Connection: keep-alive\r\n\r\nab")
        held.add s
      inc i2
    if held.len < 12:
      check("twelve connections were opened to stall the server with", false,
            "only " & $held.len & " connected -- the number below is not the" &
            " measurement this phase is named for")
    let started = fuzzNowUs()
    let r = call("/client/game/config", "")
    let waitedMs = int((fuzzNowUs() - started) div 1000'i64)
    for s in held:
      cClose(s)
    if not r.ok:
      # Recorded rather than failed, and the distinction is deliberate. This is
      # the number that named the problem: with a worker thread per connection
      # these twelve sockets shut every other client out for the whole
      # in-flight receive deadline, and a client that kept reconnecting kept
      # them locked out. It is kept at twelve so the figure stays comparable
      # with the ones already written down.
      note "twelve stalled connections shut every other client out for " &
           $waitedMs & " ms -- a slow-loris holds the whole pool"
    elif waitedMs > 1000:
      note "an ordinary request waited " & $waitedMs &
           " ms behind twelve stalled ones"
    else:
      ok "stalled connections do not delay an ordinary request"
      inc gChecks

    # What has to be true either way: once they let go, the server is not
    # merely alive but usable again, with no worker left holding a slot.
    var recovered = false
    var attempt = 0
    while attempt < 40 and not recovered:
      let again = call("/client/game/config", "")
      recovered = again.ok and again.contains("\"err\":0")
      if not recovered:
        cSleepMs(500'i32)
      inc attempt
    check("and the pool comes back once they let go", recovered,
          "still not answering after " & $attempt & " attempts")
    discard afterSpan("slow clients",
                      "twelve connections that declare a body and never send it")

  block:
    # Twelve was the number that broke the old server, so twelve is what the
    # check above keeps measuring. This is the one that says what the shape is
    # now: a connection that is not in the middle of being answered is not
    # holding a thread, so the number of them the server tolerates is a
    # function of sockets and memory rather than of the pool size.
    #
    # Two hundred and fifty-six is twenty times the pool. Under a thread per
    # connection it is unanswerable by construction; the only question worth
    # asking of it now is whether an ordinary request notices, and it must not.
    #
    # Three shapes, because they fail in different places: a socket that
    # connects and says nothing never reaches the framing at all, one that
    # dribbles half a request line is stuck in the header scan, and one that
    # declares a body and never sends it is the original finding.
    var many: seq[uint64] = @[]
    var k = 0
    while k < 256:
      let s = openRaw()
      if s != 0'u64:
        let shape = k mod 3
        if shape == 1:
          discard sendRaw(s, "GET /client/game/config HT")
        elif shape == 2:
          discard sendRaw(s, "POST /client/game/keepalive HTTP/1.1\r\n" &
                             "Content-Length: 5000\r\n" &
                             "Connection: keep-alive\r\n\r\nab")
        many.add s
      inc k

    if many.len < 256:
      check("256 connections were opened to hold against the server", false,
            "only " & $many.len & " connected -- the two checks below name a" &
            " number they did not measure")
    let manyStarted = fuzzNowUs()
    let deep = call("/client/game/config", "")
    let deepMs = int((fuzzNowUs() - manyStarted) div 1000'i64)
    note "an ordinary request behind " & $many.len &
         " stalled connections took " & $deepMs & " ms"
    check("an ordinary request is answered behind " & $many.len &
          " stalled connections",
          deep.ok and deep.contains("\"err\":0"),
          "no answer after " & $deepMs & " ms")
    # Not "eventually": the point of holding them without a thread is that they
    # are not in the way at all. A second is two orders of magnitude above what
    # this request costs on an idle server and still far under the deadlines a
    # stalled connection is waiting out, so anything over it means they are
    # queueing behind something.
    check("and they do not slow it down", deepMs <= 1000,
          "it waited " & $deepMs & " ms")

    for s in many:
      cClose(s)

    var backAgain = false
    var tries = 0
    while tries < 40 and not backAgain:
      let again2 = call("/client/game/config", "")
      backAgain = again2.ok and again2.contains("\"err\":0")
      if not backAgain:
        cSleepMs(500'i32)
      inc tries
    check("and the server is unchanged once they let go", backAgain,
          "still not answering after " & $tries & " attempts")
    discard afterSpan("slow clients",
                      "256 connections held open at once -- silent, half a" &
                      " request line, and a declared body never sent")

  settled("slow clients")

  heading "Result"
  if not keep:
    cSpawnKill(gProc)
  if gDeaths.len > 0:
    # Gathered here as well as said where it happened, because the line that
    # gets read is the last one and a death is the finding worth reading.
    err $gDeaths.len & " time(s) the server stopped serving, after:"
    for d in gDeaths:
      err "  " & d
  if gKillAfter.len > 0:
    # The self test for everything above: a death caused on purpose, at a case
    # named on the command line, and the requirement is that the report names
    # *that* case and no other. A tool that attributes deaths is only worth
    # reading if it has been made to attribute one that was known in advance.
    inc gChecks
    if gKilled.len == 0:
      err "--kill-after \"" & gKillAfter & "\" matched no case, so nothing" &
          " was killed and nothing was proved"
      inc gFailures
    elif gDeaths.len == 1 and gDeaths[0] == gKilled:
      ok "the death was reported against \"" & gKilled &
         "\", which is the case it was caused after"
    else:
      var which = ""
      for d in gDeaths:
        if which.len > 0: which.add "; "
        which.add d
      err "the backend was killed after \"" & gKilled &
          "\" and the run reported " & $gDeaths.len & " death(s): " & which
      inc gFailures
  if gSkippedPhases.len > 0:
    # Said in one place at the end as well as at the point it happened, because
    # the phases are hundreds of lines apart and the number that gets read is
    # the last one.
    var which = ""
    for p in gSkippedPhases:
      if which.len > 0: which.add ", "
      which.add p
    err $gSkippedPhases.len & " phase(s) did not run at all: " & which
    note "  nothing below `A profile to attack` was tested in those; the " &
         "checks in them are absent from the count, not passed"
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " failed"
    return 1
  ok "the server survived all " & $gChecks & " checks"
  result = 0

quit(main())
