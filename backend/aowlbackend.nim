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

import std/[strutils, syncio, cmdline]
import aowlsptinstall/winfs
import aowlsptinstall/log as console
import modhost
import modstore
import jsonpath
import jsondb
import wire

# The shim first: it defines the ABI types the route trampoline needs, and
# the `aowl_sys_*` helpers. `aowlspt_hostboot.h` is deliberately not included
# -- its constructor calls a symbol only the client host defines.
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}

proc cNetServe(port, workers: int32): int32 {.importc: "aowl_net_serve", nodecl.}
proc cNetStop() {.importc: "aowl_net_stop", nodecl.}
proc cNetRunning(): int32 {.importc: "aowl_net_running", nodecl.}
proc cNetRecv(sock: uint64; buf: HostPtr; len: int32): int32 {.
  importc: "aowl_net_recv", nodecl.}
proc cNetSend(sock: uint64; buf: HostPtr; len: int32): int32 {.
  importc: "aowl_net_send", nodecl.}
proc cNetLastError(): int32 {.importc: "aowl_net_last_error", nodecl.}
proc cLock() {.importc: "aowl_lock", nodecl.}
proc cUnlock() {.importc: "aowl_unlock", nodecl.}

const
  HostName = "aowlspt-backend"
  HostVersion = "0.1.0"
  RouteStatic = 0'i32
  RouteDynamic = 1'i32

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

var gRoutes: seq[Route] = @[]
var gSubs: seq[Sub] = @[]
var gTimers: seq[Timer] = @[]
var gRoot = ""
var gPort = 6969
var gRequests = 0

# --------------------------------------------------------------- bytes

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc fromBytes(b: seq[byte]; len: int): string =
  result = ""
  for i in 0 ..< len:
    result.add char(b[i])

proc inflateBody(raw: seq[byte]; rawLen: int; into: var string): bool =
  ## Inflates when the body looks framed, passes it through when it does not.
  into = ""
  if rawLen <= 0:
    return true
  var src = raw
  if cZlibFramed(cast[WirePtr](addr src[0]), int32(rawLen)) == 0'i32:
    into = fromBytes(raw, rawLen)
    return true
  # 64x is generous for JSON and bounded; a body that will not fit is refused
  # rather than retried with an ever-larger buffer, which is how a malformed
  # length turns into an allocation attack.
  var cap = rawLen * 64
  if cap < 65536: cap = 65536
  if cap > 64 * 1024 * 1024: cap = 64 * 1024 * 1024
  var dst = newSeq[byte](cap)
  let n = cZlibInflate(cast[WirePtr](addr src[0]), int32(rawLen),
                       cast[WirePtr](addr dst[0]), int32(cap))
  if n < 0'i32:
    return false
  into = fromBytes(dst, int(n))
  result = true

proc deflateBody(text: string; into: var seq[byte]; outLen: var int): bool =
  outLen = 0
  into = @[]
  if text.len == 0:
    return true
  var src = toBytes(text)
  let cap = cZlibBound(int32(text.len))
  into = newSeq[byte](int(cap))
  let n = cZlibDeflate(cast[WirePtr](addr src[0]), int32(text.len),
                       cast[WirePtr](addr into[0]), cap)
  if n < 0'i32:
    return false
  outLen = int(n)
  result = true

# --------------------------------------------------------------- http

type
  Request = object
    verb: string
    url: string
    session: string
    body: string
    ok: bool

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
      for ch in value:
        if ch >= '0' and ch <= '9':
          v = v * 10 + (ord(ch) - ord('0'))
          any = true
        else:
          break
      if any: contentLength = v
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

  r.ok = true
  result = true

proc sendResponse(sock: uint64; status: string; body: string; compress: bool) =
  var payload: seq[byte] = @[]
  var payloadLen = 0
  if compress and body.len > 0:
    if not deflateBody(body, payload, payloadLen):
      payload = toBytes(body)
      payloadLen = body.len
  else:
    payload = toBytes(body)
    payloadLen = body.len

  var head = "HTTP/1.1 " & status & "\r\n"
  head.add "Content-Type: application/json\r\n"
  head.add "Content-Length: " & $payloadLen & "\r\n"
  head.add "Connection: close\r\n"
  head.add "\r\n"

  var headBytes = toBytes(head)
  discard cNetSend(sock, cast[HostPtr](addr headBytes[0]), int32(head.len))
  if payloadLen > 0:
    discard cNetSend(sock, cast[HostPtr](addr payload[0]), int32(payloadLen))

# --------------------------------------------------------------- routing

proc matchRoute(url: string): int =
  ## Exact matches win over prefixes, and the longest prefix wins among those.
  ## Registration order deciding it instead would make two mods' behaviour
  ## depend on their filenames.
  result = -1
  var bestLen = -1
  for i in 0 ..< gRoutes.len:
    if gRoutes[i].kind == RouteStatic:
      if gRoutes[i].url == url:
        return i
    else:
      if url.len >= gRoutes[i].url.len and
         url.substr(0, gRoutes[i].url.len - 1) == gRoutes[i].url:
        if gRoutes[i].url.len > bestLen:
          bestLen = gRoutes[i].url.len
          result = i

# The route callback goes through `aowl_invoke_route` in the shim, which is
# where it has to live: the trampoline needs the ABI's struct types, and those
# only exist in the translation unit that includes the header.
proc cInvokeRoute(cb, user, url: HostPtr; urlLen: int32;
                  body: HostPtr; bodyLen: int32;
                  session: HostPtr; sessionLen: int32;
                  outPtr, outLen: HostPtr): int32 {.
  importc: "aowl_invoke_route", nodecl.}
proc cFreeBuf(p: HostPtr) {.importc: "aowl_host_release", nodecl.}

proc runRoute(index: int; r: Request; into: var string): bool =
  into = ""
  var url = r.url
  var body = r.body
  var session = r.session
  var outPtr: HostPtr = cast[HostPtr](0)
  var outLen = 0'i32
  let st = cInvokeRoute(gRoutes[index].cb, gRoutes[index].user,
                        cast[HostPtr](toCString(url)), int32(url.len),
                        cast[HostPtr](toCString(body)), int32(body.len),
                        cast[HostPtr](toCString(session)), int32(session.len),
                        cast[HostPtr](addr outPtr), cast[HostPtr](addr outLen))
  if outPtr != nil and outLen > 0'i32:
    into = readBytes(outPtr, outLen)
  if outPtr != nil:
    cFreeBuf(outPtr)
  result = st == StatusOk

# --------------------------------------------------------------- serving

proc serveConnection(sock: uint64) {.exportc: "aowlspt_nim_serve", cdecl.} =
  ## One request per connection. Keep-alive would be a real optimisation and is
  ## not one worth having before the endpoints exist.
  var buf = newSeq[byte](65536)
  var have = 0
  var headEnd = -1

  # Read until the header terminator. The body may already be partly here.
  while headEnd < 0 and have < buf.len:
    let n = cNetRecv(sock, cast[HostPtr](addr buf[have]), int32(buf.len - have))
    if n <= 0'i32:
      return
    have = have + int(n)
    let text = fromBytes(buf, have)
    headEnd = find(text, "\r\n\r\n")
    if headEnd < 0 and find(text, "\n\n") >= 0:
      headEnd = find(text, "\n\n")

  if headEnd < 0:
    sendResponse(sock, "431 Request Header Fields Too Large", "", false)
    return

  let whole = fromBytes(buf, have)
  let head = whole.substr(0, headEnd - 1)
  var sep = 4
  if whole.substr(headEnd, headEnd + 1) == "\n\n":
    sep = 2

  var req = Request(verb: "", url: "", session: "", body: "", ok: false)
  var contentLength = 0
  if not parseHead(head, req, contentLength):
    sendResponse(sock, "400 Bad Request", "", false)
    return

  # Pull the rest of the body.
  var bodyStart = headEnd + sep
  var bodyBytes = newSeq[byte](if contentLength > 0: contentLength else: 1)
  var bodyHave = 0
  for i in bodyStart ..< have:
    if bodyHave < contentLength:
      bodyBytes[bodyHave] = buf[i]
      inc bodyHave
  while bodyHave < contentLength:
    let n = cNetRecv(sock, cast[HostPtr](addr bodyBytes[bodyHave]),
                     int32(contentLength - bodyHave))
    if n <= 0'i32:
      break
    bodyHave = bodyHave + int(n)

  if not inflateBody(bodyBytes, bodyHave, req.body):
    modhost.warn "could not inflate a " & $bodyHave & "-byte body for " & req.url
    sendResponse(sock, "400 Bad Request", "", false)
    return

  inc gRequests

  if req.session.len > 0 and not isHexId(req.session):
    # Rejected before any route sees it: a malformed id reaching a mod would
    # be reported as that mod's bug.
    modhost.warn "rejecting a malformed session id on " & req.url
    sendResponse(sock, "400 Bad Request", "{\"err\":\"bad session id\"}", true)
    return

  let idx = matchRoute(req.url)
  if idx < 0:
    sendResponse(sock, "404 Not Found",
                 "{\"err\":\"no route\",\"url\":\"" & req.url & "\"}", true)
    return

  var body = ""
  if runRoute(idx, req, body):
    sendResponse(sock, "200 OK", body, true)
  else:
    sendResponse(sock, "500 Internal Server Error",
                 "{\"err\":\"the route handler failed\"}", true)

# --------------------------------------------------------------- host api

var gLastError = ""

proc hostLog(ctx: HostPtr; level: int32; msg: HostPtr; len: int32) {.
    exportc: "aowlspt_nim_log", cdecl.} =
  let text = readBytes(msg, len)
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

proc hostLastError(ctx: HostPtr; outPtr, outLen: HostPtr) {.
    exportc: "aowlspt_nim_last_error", cdecl.} =
  if gLastError.len == 0:
    discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
    return
  discard cOutCopy(outPtr, outLen, cast[HostPtr](toCString(gLastError)),
                   int32(gLastError.len))

proc hostConfigGet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                   outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_config_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let k = readBytes(key, keyLen)
  let idx = int(cast[uint](ctx))
  let dir = modDirOf(idx)
  if dir.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  var text = ""
  if not readTextFile(joinPath(dir, "config.json"), text):
    gLastError = "no config.json for " & modGuidOf(idx)
    return ErrNotFound
  # An empty key is the whole document, which `aowlspt.nim` documents and this
  # did not do -- so a mod reading its config in one round trip got an error
  # instead. Dotted keys work too, through the same lookup the client host uses.
  var value = ""
  if k.len == 0:
    value = text
  elif not pathGet(text, k, value):
    gLastError = "no such key: " & k
    return ErrNotFound
  var v = value
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc hostConfigSet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                   val: HostPtr; valLen: int32): int32 {.
    exportc: "aowlspt_nim_config_set", cdecl.} =
  gLastError = "the backend does not write mod config"
  result = ErrUnsupported

proc hostDbGet(ctx: HostPtr; path: HostPtr; pathLen: int32;
               outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_db_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let p = readBytes(path, pathLen)
  var value = ""
  if not dbGetPath(p, value):
    gLastError = "no such database path: " & p
    return ErrNotFound
  var v = value
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc hostDbPatch(ctx: HostPtr; path: HostPtr; pathLen: int32;
                 patch: HostPtr; patchLen: int32): int32 {.
    exportc: "aowlspt_nim_db_patch", cdecl.} =
  let p = readBytes(path, pathLen)
  let j = readBytes(patch, patchLen)
  var err = ""
  if not dbPatchPath(p, j, err):
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
  for r in gRoutes:
    if r.url == u and r.kind == kind:
      gLastError = "the route " & u & " is already registered"
      return ErrGeneric
  gRoutes.add Route(url: u, kind: kind, cb: cb, user: user,
                    modIndex: int(cast[uint](ctx)))
  modhost.okLog "route " & u & (if kind == RouteDynamic: " (prefix)" else: "")
  result = StatusOk

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
  var delivered = 0
  for i in 0 ..< gSubs.len:
    if gSubs[i].name != n or gSubs[i].modIndex == from1:
      continue
    var b = body
    let st = cInvokeCallback(gSubs[i].cb, gSubs[i].user,
                             cast[HostPtr](toCString(b)), int32(body.len))
    if st != StatusOk:
      # One bad subscriber must not stop the rest: an event is a broadcast, and
      # a mod dropping it is that mod's problem rather than the emitter's.
      modhost.warn "a subscriber to " & n & " returned " & $int(st)
    inc delivered
  if delivered == 0:
    modhost.info "event " & n & " (no subscribers)"
  result = StatusOk

proc hostEventSubscribe(ctx: HostPtr; name: HostPtr; nameLen: int32;
                        cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_event_subscribe", cdecl.} =
  let n = readBytes(name, nameLen)
  if n.len == 0 or cb == nil:
    gLastError = "a subscription needs a name and a handler"
    return ErrBadArg
  gSubs.add Sub(name: n, cb: cb, user: user, modIndex: int(cast[uint](ctx)))
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
  gTimers.add Timer(dueMs: elapsedMs() + d, cb: cb, user: user)
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
  if not storeRead(guid, k, value, error):
    gLastError = error
    return ErrNotFound
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
  if not storeWrite(guid, k, v, error):
    gLastError = error
    return ErrGeneric
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
  var v = storeKeys(guid, p)
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc patchFired(slot: int32) {.exportc: "aowlspt_nim_patch_fired", cdecl.} =
  discard

# --------------------------------------------------------------- self test

var gSelfFailures = 0

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
  --port N      listen port, loopback only (default 6969)
  --db PATH     database JSON to load (default <root>/aowlspt/db.json)
  --once        serve until one request has been handled, then exit
  --selftest    serve, drive every route from inside this process, then exit
                with the result. One command, no orchestration.
  -h, --help    this
"""

proc main(): int =
  var root = ""
  var dbPath = ""
  var once = false
  var selftest = false
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
        if any: gPort = v
    elif a == "--db":
      inc i
      if i <= n: dbPath = paramStr(i)
    elif a == "--once":
      once = true
    elif a == "--selftest":
      selftest = true
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

  console.heading "aowlspt-backend"
  console.line "  root  " & gRoot
  console.line "  log   " & logPath

  if dbPath.len == 0:
    dbPath = joinPath(gRoot, "db.json")
  if fileExists(dbPath):
    var text = ""
    if readTextFile(dbPath, text):
      dbLoad(text)
      modhost.info "database loaded from " & dbPath & " (" & $text.len & " bytes)"
      line "  db    " & dbPath
  else:
    modhost.info "no database at " & dbPath & "; db_get will find nothing"
    console.line "  db    (none)"

  storeInit(gRoot)
  console.line "  store " & storeRoot()

  let modsDir = joinPath(gRoot, "mods")
  let count = loadAll(modsDir, SideServer, HostName, HostVersion)
  console.line "  mods  " & $count
  console.line "  routes " & $gRoutes.len

  if cNetServe(int32(gPort), 4'i32) == 0'i32:
    console.err "could not listen on port " & $gPort &
        " (error " & $int(cNetLastError()) & ")"
    modhost.fail "could not listen on " & $gPort
    return 1
  modhost.okLog "listening on 127.0.0.1:" & $gPort
  console.line "  port  " & $gPort
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
    if gSelfFailures > 0:
      console.err $gSelfFailures & " failed"
      return 1
    console.ok "the backend served every route over the wire"
    return 0

  var lastTick = elapsedMs()
  while cNetRunning() != 0'i32:
    cSysSleep(50'i32)
    let now = elapsedMs()
    tickMods(now - lastTick)
    runTimers()
    lastTick = now
    if once and gRequests > 0:
      # One request then stop: how the test harness drives it.
      cSysSleep(200'i32)
      break

  cNetStop()
  unloadMods()
  modhost.okLog "stopped after " & $gRequests & " requests"
  console.line ""
  console.line "  stopped after " & $gRequests & " requests"
  result = 0

quit(main())
