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
  ## `copyMem`, not a byte loop.
  ##
  ## These carry whole request and response bodies, and the static tables are
  ## megabytes: a per-byte loop over one of those costs more wall time than the
  ## deflate it feeds. Measured at 3000 item templates, converting the
  ## `/client/items` body one byte at a time was 24 ms of the 41 ms the whole
  ## response took.
  result = newSeq[byte](if s.len > 0: s.len else: 1)
  if s.len > 0:
    copyMem(addr result[0], readRawData(s), s.len)

proc fromBytes*(b {.byref.}: seq[byte]; len: int): string =
  ## `byref` is load-bearing as well as fast: a by-value `seq` parameter would
  ## copy the whole receive buffer on every call, and this is called with a
  ## multi-megabyte one.
  result = ""
  if len <= 0:
    return
  let dest = beginStore(result, len)
  copyMem(dest, addr b[0], len)
  endStore(result)

proc bytesAt*(b {.byref.}: seq[byte]; start, len: int): string =
  ## `fromBytes` of a window, without the intermediate `seq` copy the callers
  ## used to make to cut a body out of a receive buffer.
  result = ""
  if len <= 0:
    return
  let dest = beginStore(result, len)
  copyMem(dest, cast[pointer](cast[uint](addr b[0]) + uint(start)), len)
  endStore(result)

proc readMem*(p: WirePtr; len: int32): string =
  ## A host buffer as a string, in one `copyMem`.
  ##
  ## `modhost.readBytes` does the same job through `aowl_byte_at`, which is a
  ## call across a translation unit per byte. That is fine for a mod's guid and
  ## ruinous for a 12 MB route response, which is the other thing it was being
  ## used for.
  result = ""
  if cast[uint](p) == 0'u or len <= 0'i32:
    return
  let n = int(len)
  let dest = beginStore(result, n)
  copyMem(dest, p, n)
  endStore(result)

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

  # The buffer grows rather than capping.
  #
  # It used to be a fixed 256 KB, which silently truncated any response larger
  # than that -- and `/client/items` against a real database is tens of times
  # that. The symptom was not a short body but "the response body would not
  # inflate", because a truncated zlib stream is a corrupt one, so the bug read
  # as a server fault rather than a client one.
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
  cClose(sock)

  if have == 0:
    result.error = "the server closed without answering"
    return

  # The terminator is found in the byte buffer, not in a string copy of it.
  # Turning a 12 MB response into a string in order to locate a header four
  # bytes long was the single most expensive thing this client did.
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
    result.error = "no header terminator in the response"
    return

  let headText = bytesAt(buf, 0, headEnd)
  result.status = splitLines(headText)[0]
  let bodyStart = headEnd + sep

  if bodyStart < have:
    let rawLen = have - bodyStart
    let rawAt = cast[WirePtr](cast[uint](addr buf[0]) + uint(bodyStart))
    if cZlibFramed(rawAt, int32(rawLen)) != 0'i32:
      # The uncompressed length is not on the wire, so the buffer is guessed
      # and grown on failure rather than sized once at 64x -- which for a
      # multi-megabyte body was a several-hundred-megabyte allocation per
      # request.
      var cap = rawLen * 8
      if cap < 65536: cap = 65536
      var tries = 0
      while tries < 6:
        var dst = newSeq[byte](cap)
        let m = cZlibInflate(rawAt, int32(rawLen),
                             cast[WirePtr](addr dst[0]), int32(cap))
        if m >= 0'i32:
          result.body = fromBytes(dst, int(m))
          result.ok = true
          return
        cap = cap * 4
        inc tries
      result.error = "the response body would not inflate"
      return
    else:
      result.body = bytesAt(buf, bodyStart, rawLen)

  result.ok = true

proc contains*(r: Response; text: string): bool =
  result = find(r.body, text) >= 0
