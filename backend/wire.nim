## Speaking the client's wire protocol, from the client side.
##
## Shared by `aowlprobe` and by the backend's own `--selftest`, so there is one
## implementation of the framing and both are exercised by the same code that
## the tool a human reaches for uses.
##
## The framing is the whole reason this exists. The game zlib-compresses every
## request body and expects a zlib-compressed response; a plain request reaches
## the server as an unparseable body and a plain response reaches the client as
## unparseable JSON, both with a 200. `curl` therefore cannot tell a working
## route from a broken one.

import std/strutils

{.emit: """#include "aowlspt_net.h" """.}

type WirePtr* = nil pointer

proc cNetStartup*(): int32 {.importc: "aowl_net_startup", nodecl.}
proc cNetLastError*(): int32 {.importc: "aowl_net_last_error", nodecl.}
proc cZlibBound*(n: int32): int32 {.importc: "aowl_zlib_bound", nodecl.}
proc cZlibDeflate*(src: WirePtr; srcLen: int32; dst: WirePtr;
                   dstCap: int32): int32 {.importc: "aowl_zlib_deflate", nodecl.}
proc cZlibInflate*(src: WirePtr; srcLen: int32; dst: WirePtr;
                   dstCap: int32): int32 {.importc: "aowl_zlib_inflate", nodecl.}
proc cZlibFramed*(p: WirePtr; len: int32): int32 {.
  importc: "aowl_zlib_looks_framed", nodecl.}

{.emit: """
static uint64_t aowl_wire_connect(int32_t port) {
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
  DWORD t = 10000;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&t, sizeof(t));
  return (uint64_t)s;
}
""".}

proc cConnect*(port: int32): uint64 {.importc: "aowl_wire_connect", nodecl.}
proc cSend*(sock: uint64; buf: WirePtr; len: int32): int32 {.
  importc: "aowl_net_send", nodecl.}
proc cRecv*(sock: uint64; buf: WirePtr; len: int32): int32 {.
  importc: "aowl_net_recv", nodecl.}
proc cClose*(sock: uint64) {.importc: "aowl_net_close", nodecl.}

type
  Response* = object
    ok*: bool
    status*: string
    body*: string
    error*: string

proc toBytes*(s: string): seq[byte] =
  result = newSeq[byte](if s.len > 0: s.len else: 1)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc fromBytes*(b: seq[byte]; len: int): string =
  result = ""
  for i in 0 ..< len:
    result.add char(b[i])

proc splitUrl*(url: string; port: var int; path: var string) =
  port = 6969
  path = "/"
  var rest = url
  let scheme = find(rest, "://")
  if scheme >= 0:
    rest = rest.substr(scheme + 3)
  let slash = find(rest, "/")
  var hostPart = rest
  if slash >= 0:
    hostPart = rest.substr(0, slash - 1)
    path = rest.substr(slash)
  let colon = find(hostPart, ":")
  if colon >= 0:
    var v = 0
    var any = false
    for ch in hostPart.substr(colon + 1):
      if ch >= '0' and ch <= '9':
        v = v * 10 + (ord(ch) - ord('0'))
        any = true
    if any: port = v

proc request*(port: int; path, body, session: string;
              compress = true): Response =
  result = Response(ok: false, status: "", body: "", error: "")

  let sock = cConnect(int32(port))
  if sock == 0'u64:
    result.error = "could not connect to 127.0.0.1:" & $port &
                   " (error " & $int(cNetLastError()) & ")"
    return

  var payload: seq[byte] = @[]
  var payloadLen = 0
  if body.len > 0:
    if compress:
      var src = toBytes(body)
      let cap = cZlibBound(int32(body.len))
      payload = newSeq[byte](int(cap))
      let m = cZlibDeflate(cast[WirePtr](addr src[0]), int32(body.len),
                           cast[WirePtr](addr payload[0]), cap)
      if m < 0'i32:
        result.error = "could not compress the body"
        cClose(sock)
        return
      payloadLen = int(m)
    else:
      payload = toBytes(body)
      payloadLen = body.len

  var req = (if body.len > 0: "POST " else: "GET ") & path & " HTTP/1.1\r\n"
  req.add "Host: 127.0.0.1:" & $port & "\r\n"
  req.add "Cookie: PHPSESSID=" & session & "\r\n"
  req.add "Content-Length: " & $payloadLen & "\r\n"
  req.add "Connection: close\r\n\r\n"

  var head = toBytes(req)
  if cSend(sock, cast[WirePtr](addr head[0]), int32(req.len)) < 0'i32:
    result.error = "could not send"
    cClose(sock)
    return
  if payloadLen > 0:
    discard cSend(sock, cast[WirePtr](addr payload[0]), int32(payloadLen))

  var buf = newSeq[byte](262144)
  var have = 0
  while have < buf.len:
    let m = cRecv(sock, cast[WirePtr](addr buf[have]), int32(buf.len - have))
    if m <= 0'i32:
      break
    have = have + int(m)
  cClose(sock)

  if have == 0:
    result.error = "the server closed without answering"
    return

  let whole = fromBytes(buf, have)
  var headEnd = find(whole, "\r\n\r\n")
  var sep = 4
  if headEnd < 0:
    headEnd = find(whole, "\n\n")
    sep = 2
  if headEnd < 0:
    result.error = "no header terminator in the response"
    return

  result.status = splitLines(whole.substr(0, headEnd - 1))[0]
  let bodyStart = headEnd + sep

  if bodyStart < have:
    var raw = newSeq[byte](have - bodyStart)
    for k in bodyStart ..< have:
      raw[k - bodyStart] = buf[k]
    if raw.len > 0 and
       cZlibFramed(cast[WirePtr](addr raw[0]), int32(raw.len)) != 0'i32:
      var cap = raw.len * 64
      if cap < 65536: cap = 65536
      var dst = newSeq[byte](cap)
      let m = cZlibInflate(cast[WirePtr](addr raw[0]), int32(raw.len),
                           cast[WirePtr](addr dst[0]), int32(cap))
      if m < 0'i32:
        result.error = "the response body would not inflate"
        return
      result.body = fromBytes(dst, int(m))
    else:
      result.body = fromBytes(raw, raw.len)

  result.ok = true

proc contains*(r: Response; text: string): bool =
  result = find(r.body, text) >= 0
