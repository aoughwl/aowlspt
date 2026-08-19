## aowlprobe — talk to the backend the way the game does.
##
##     aowlprobe http://127.0.0.1:6969/aowlspt/status
##     aowlprobe http://127.0.0.1:6969/aowlspt/echo --body "{\"hi\":1}"
##     aowlprobe ... --expect "\"ok\":true"
##
## `curl` will not do, and the reason is not obvious. The client zlib-frames
## every request body and expects a zlib-framed response, so a plain request
## reaches the server as an unparseable body and a plain response reaches the
## client as unparseable JSON — with a 200 on both. A tool that speaks the
## protocol is the only way to tell a working route from a broken one.
##
## `--expect` makes it usable as a test: the process exits non-zero when the
## response does not contain the text, so a harness does not have to parse.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/log

{.emit: """#include "aowlspt_net.h" """.}

## `aowlspt_net.h` declares the two entry points its poller calls into nimony
## with as externs, so a client that includes it still has to define the
## symbols. Neither is ever called here -- this tool is a client, and nothing
## in it starts a server.
proc probeHandleStub(sock: uint64; buf: pointer; len: int32;
                     headEnd: int32; sep: int32): int32 {.
    exportc: "aowlspt_nim_handle", cdecl.} =
  result = 0'i32

proc probeTimeoutStub(sock: uint64; phase: int32; have: int32;
                      declared: int32) {.
    exportc: "aowlspt_nim_timeout", cdecl.} =
  discard

type NetPtr = nil pointer

proc cNetStartup(): int32 {.importc: "aowl_net_startup", nodecl.}
proc cNetLastError(): int32 {.importc: "aowl_net_last_error", nodecl.}
proc cZlibBound(n: int32): int32 {.importc: "aowl_zlib_bound", nodecl.}
proc cZlibDeflate(src: NetPtr; srcLen: int32; dst: NetPtr;
                  dstCap: int32): int32 {.importc: "aowl_zlib_deflate", nodecl.}
proc cZlibInflate(src: NetPtr; srcLen: int32; dst: NetPtr;
                  dstCap: int32): int32 {.importc: "aowl_zlib_inflate", nodecl.}
proc cZlibFramed(p: NetPtr; len: int32): int32 {.
  importc: "aowl_zlib_looks_framed", nodecl.}

{.emit: """
static uint64_t aowl_probe_connect(int32_t port) {
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

proc cConnect(port: int32): uint64 {.importc: "aowl_probe_connect", nodecl.}
proc cSend(sock: uint64; buf: NetPtr; len: int32): int32 {.
  importc: "aowl_net_send", nodecl.}
proc cRecv(sock: uint64; buf: NetPtr; len: int32): int32 {.
  importc: "aowl_net_recv", nodecl.}
proc cClose(sock: uint64) {.importc: "aowl_net_close", nodecl.}

const Usage = """
aowlprobe -- call a backend route with the game's wire framing

  aowlprobe URL [options]

  --body TEXT     request body (zlib-framed on the way out)
  --session HEX   24-hex session id (default 000000000000000000000001)
  --expect TEXT   fail unless the response contains TEXT
  --raw           do not compress the request body
  -h, --help      this
"""

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](if s.len > 0: s.len else: 1)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc fromBytes(b: seq[byte]; len: int): string =
  result = ""
  for i in 0 ..< len:
    result.add char(b[i])

proc splitUrl(url: string; port: var int; path: var string): bool =
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
  result = true

proc main(): int =
  var url = ""
  var body = ""
  var session = "000000000000000000000001"
  var expect = ""
  var rawBody = false
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--body":
      inc i
      if i <= n: body = paramStr(i)
    elif a == "--session":
      inc i
      if i <= n: session = paramStr(i)
    elif a == "--expect":
      inc i
      if i <= n: expect = paramStr(i)
    elif a == "--raw":
      rawBody = true
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    elif url.len == 0:
      url = a
    inc i

  if url.len == 0:
    echo Usage
    return 1

  var port = 6969
  var path = "/"
  discard splitUrl(url, port, path)

  if cNetStartup() == 0'i32:
    err "winsock would not start"
    return 1

  let sock = cConnect(int32(port))
  if sock == 0'u64:
    err "could not connect to 127.0.0.1:" & $port &
        " (error " & $int(cNetLastError()) & ")"
    return 1

  # Frame the body the way the client does.
  var payload: seq[byte] = @[]
  var payloadLen = 0
  if body.len > 0:
    if rawBody:
      payload = toBytes(body)
      payloadLen = body.len
    else:
      var src = toBytes(body)
      let cap = cZlibBound(int32(body.len))
      payload = newSeq[byte](int(cap))
      let m = cZlibDeflate(cast[NetPtr](addr src[0]), int32(body.len),
                           cast[NetPtr](addr payload[0]), cap)
      if m < 0'i32:
        err "could not compress the body"
        cClose(sock)
        return 1
      payloadLen = int(m)

  var req = (if body.len > 0: "POST " else: "GET ") & path & " HTTP/1.1\r\n"
  req.add "Host: 127.0.0.1:" & $port & "\r\n"
  req.add "Cookie: PHPSESSID=" & session & "\r\n"
  req.add "Content-Length: " & $payloadLen & "\r\n"
  req.add "Connection: close\r\n\r\n"

  var head = toBytes(req)
  if cSend(sock, cast[NetPtr](addr head[0]), int32(req.len)) < 0'i32:
    err "could not send"
    cClose(sock)
    return 1
  if payloadLen > 0:
    discard cSend(sock, cast[NetPtr](addr payload[0]), int32(payloadLen))

  # The buffer grows rather than being a fixed 256 KiB. It was fixed, and
  # against a real database `/client/items` is 12 MiB of JSON -- more than
  # 256 KiB even deflated -- so the body arrived truncated and the only report
  # was "the response body would not inflate", from the one tool a person
  # reaches for when they are trying to find out what the server said.
  var buf = newSeq[byte](262144)
  var have = 0
  while true:
    if have == buf.len:
      var bigger = newSeq[byte](buf.len * 2)
      for k in 0 ..< have:
        bigger[k] = buf[k]
      buf = bigger
    let m = cRecv(sock, cast[NetPtr](addr buf[have]), int32(buf.len - have))
    if m <= 0'i32:
      break
    have = have + int(m)
  cClose(sock)

  if have == 0:
    err "the server closed without answering"
    return 1

  let whole = fromBytes(buf, have)
  var headEnd = find(whole, "\r\n\r\n")
  var sep = 4
  if headEnd < 0:
    headEnd = find(whole, "\n\n")
    sep = 2
  if headEnd < 0:
    err "no header terminator in the response"
    return 1

  let status = splitLines(whole.substr(0, headEnd - 1))[0]
  let bodyStart = headEnd + sep

  var respBody = ""
  if bodyStart < have:
    var raw = newSeq[byte](have - bodyStart)
    for k in bodyStart ..< have:
      raw[k - bodyStart] = buf[k]
    if raw.len > 0 and
       cZlibFramed(cast[NetPtr](addr raw[0]), int32(raw.len)) != 0'i32:
      var cap = raw.len * 64
      if cap < 65536: cap = 65536
      var dst = newSeq[byte](cap)
      let m = cZlibInflate(cast[NetPtr](addr raw[0]), int32(raw.len),
                           cast[NetPtr](addr dst[0]), int32(cap))
      if m < 0'i32:
        err "the response body would not inflate"
        return 1
      respBody = fromBytes(dst, int(m))
    else:
      respBody = fromBytes(raw, raw.len)

  heading status
  line "  " & respBody

  if expect.len > 0:
    if find(respBody, expect) < 0:
      err "the response does not contain: " & expect
      return 1
    ok "found: " & expect
  result = 0

quit(main())
