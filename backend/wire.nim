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
/* One clock for both request paths. QPC rather than GetTickCount64: a small
 * request answers in a couple of hundred microseconds and a millisecond clock
 * cannot see that at all. */
static int64_t aowl_wire_now_us(void) {
  LARGE_INTEGER v, f;
  QueryPerformanceCounter(&v);
  QueryPerformanceFrequency(&f);
  return (int64_t)((v.QuadPart / f.QuadPart) * 1000000LL +
                   ((v.QuadPart % f.QuadPart) * 1000000LL) / f.QuadPart);
}

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
proc nowUs*(): int64 {.importc: "aowl_wire_now_us", nodecl.}
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
    ttfbUs*: int64
      ## Microseconds from "request sent" to "first byte of the answer
      ## arrived". This is the server's time; everything after it is transfer
      ## and decompression on this side. Splitting the two matters because the
      ## largest bodies here are dominated by the client's own `inflate`, and a
      ## round-trip number alone makes that look like server cost.

proc toBytes*(s: string): seq[byte] =
  ## `copyMem`, not a byte loop.
  ##
  ## These carry whole request and response bodies, and the static tables are
  ## megabytes: a per-byte loop over one of those is real wall time. Taking the
  ## byte loops out of this file and the backend's copy of them moved
  ## `/client/items` from 71.0 ms to 57.7 ms round-trip on a 4.2 MB body, before
  ## any of the caching that came after it.
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

# --------------------------------------------------------------------------- #
# The BSG envelope                                                             #
#                                                                              #
# A post-1.0 client does not put `zlib(json)` on the wire the way a pre-1.0    #
# one did. It wraps it:                                                        #
#                                                                              #
#     wire = shuffle_L( [int32 LE size][payload of `size` bytes][junk] )       #
#                                                                              #
# `shuffle_L` is a Fisher-Yates permutation whose swap indices come from a     #
# linear congruential sequence, stepped by the buffer's own length. **The      #
# length is the only key**, so this is obfuscation rather than encryption and  #
# either side can undo it. It is the same permutation this repository already  #
# applied to `/client/metadata` response bodies -- the discovery is not the    #
# permutation but that it is on *every* route, in both directions.             #
#                                                                              #
# The trailing junk is the tail of the client's send buffer, left unwritten.   #
# It is not covered by `size` and carries nothing. It is also why the same     #
# logical request appears on the wire at ten different lengths: the junk       #
# length varies, and the length picks the permutation. That is the whole       #
# explanation for a capture in which `/client/weather` and `/client/keepalive` #
# post byte-identical bodies -- both are the empty request, and they collided  #
# on a length.                                                                 #
#                                                                              #
# Why this matters to the server rather than being a curiosity: a body that    #
# arrives shuffled is not zlib-framed, so it flows through `inflateBody`'s     #
# pass-through branch and reaches the route handler as noise. Every route that #
# ignores its request body still works, which is why a client can boot all the #
# way to the main menu against a server that has never once read what it was   #
# sent -- and why the first thing to break is the first thing that matters:    #
# creating a profile, moving an item, ending a raid.                           #
# --------------------------------------------------------------------------- #

const
  BsgMod = 0x8ED7A18D'i64
  BsgMul = 1624453'i64
  BsgAdd = 1023920427'i64
  BsgSeed = 0x65F6D'i64
  BsgStartMod = 0xAAB

proc bsgSwapIndex(i, start: int): int =
  ## The client builds a table of these and indexes it; the table is a pure
  ## function of the position, so this computes the entry instead.
  ##
  ## Not a micro-optimisation. The table is `len + len mod 0xAAB` entries of
  ## 64-bit arithmetic, which for the 76 KB body that `/client/match/local/end`
  ## posts is a 600 KB allocation per request, to be read once and thrown away.
  ## The closed form allocates nothing. `bsgEnvelopeSelftest` asserts the two
  ## agree.
  ##
  ## The product cannot overflow: the multiplicand is bounded by the body
  ## length plus 0x65F6D, so for any body this server will accept it stays
  ## below 2^43.
  let t = (BsgMul * (BsgSeed + int64(i + start)) + BsgAdd) mod BsgMod
  result = int(t mod int64(i))

proc bsgUnshuffle*(b: var seq[byte]; len: int) =
  ## Wire order -> buffer order, in place. Ascending.
  if len <= 1:
    return
  let start = len mod BsgStartMod
  var i = 1
  while i < len:
    let j = bsgSwapIndex(i, start)
    let t = b[i]
    b[i] = b[j]
    b[j] = t
    inc i

proc bsgShuffle*(b: var seq[byte]; len: int) =
  ## Buffer order -> wire order, in place. The descending exact inverse.
  if len <= 1:
    return
  let start = len mod BsgStartMod
  var i = len - 1
  while i >= 1:
    let j = bsgSwapIndex(i, start)
    let t = b[i]
    b[i] = b[j]
    b[j] = t
    dec i

proc bsgUnwrap*(b: var seq[byte]; len: int; payloadLen: var int): bool =
  ## Unshuffles `b` in place and reports the payload, which begins at byte 4.
  ##
  ## Returns false -- leaving `b` unshuffled-but-modified -- when the result
  ## does not look like an envelope. The caller must therefore treat a false
  ## return as "this buffer is now scrambled, use your own copy", which is what
  ## `inflateBody` does. Sizing it any other way would mean copying every body
  ## twice on the common path to protect the rare one.
  ##
  ## The size check is what keeps a body that was never enveloped from being
  ## accepted as one: an unenveloped buffer unshuffles to noise, and noise has
  ## a one-in-a-few-hundred-million chance of leading with a size word that is
  ## both positive and inside the buffer.
  payloadLen = 0
  if len < 5:
    return false
  bsgUnshuffle(b, len)
  let size = int(b[0]) or (int(b[1]) shl 8) or (int(b[2]) shl 16) or
             (int(b[3]) shl 24)
  if size <= 0 or size > len - 4:
    return false
  payloadLen = size
  result = true

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
  result = Response(ok: false, status: "", body: "", error: "", ttfbUs: 0)

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
  let sentAt = nowUs()
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
    if have == 0:
      result.ttfbUs = nowUs() - sentAt
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

# --------------------------------------------------------------- keep-alive
#
# `request` above opens a connection, says `Connection: close` and reads to
# end-of-stream. That is the right shape for `aowlprobe` and for the self test:
# one question, one answer, nothing to clean up, and it works against a server
# that does not do keep-alive at all.
#
# A load generator is the other case. A session is thousands of small requests
# and a handshake per request is a real share of each answer, so `Conn` holds
# one socket open across them. Reading to end-of-stream is no longer available
# as a frame -- the stream does not end -- so this path reads exactly the
# `Content-Length` the response declares, and keeps whatever arrived past it
# for the next call.

type
  Conn* = object
    sock*: uint64
    buf*: seq[byte]
    have*: int
    port*: int

proc openConn*(port: int): Conn =
  result = Conn(sock: cConnect(int32(port)), buf: newSeq[byte](262144),
                have: 0, port: port)

proc closeConn*(c: var Conn) =
  if c.sock != 0'u64:
    cClose(c.sock)
    c.sock = 0'u64
  c.have = 0

proc findTerminator(b {.byref.}: seq[byte]; have: int;
                    headEnd, sep: var int): bool =
  headEnd = -1
  sep = 4
  var k = 0
  while k + 1 < have:
    if b[k] == byte(13) and k + 3 < have and b[k + 1] == byte(10) and
       b[k + 2] == byte(13) and b[k + 3] == byte(10):
      headEnd = k
      sep = 4
      return true
    if b[k] == byte(10) and b[k + 1] == byte(10):
      headEnd = k
      sep = 2
      return true
    inc k
  result = false

proc contentLengthOf(head: string): int =
  ## `-1` for "not stated", which on a keep-alive connection is unrecoverable:
  ## there is no end-of-stream to fall back on.
  result = -1
  let lines = splitLines(head)
  for i in 0 ..< lines.len:
    let l = lines[i]
    let colon = find(l, ":")
    if colon < 0: continue
    if toLowerAscii(strip(l.substr(0, colon - 1))) != "content-length":
      continue
    var v = 0
    var any = false
    for ch in strip(l.substr(colon + 1)):
      if ch >= '0' and ch <= '9':
        v = v * 10 + (ord(ch) - ord('0'))
        any = true
      else:
        break
    if any: return v
  result = -1

proc requestOn*(c: var Conn; path, body, session: string;
                compress = true): Response =
  ## One request on a connection that stays open. Reconnects once if the server
  ## closed the connection between requests -- which it will, at the keep-alive
  ## bound -- because a load generator that dies at request five hundred and
  ## thirteen is measuring the bound rather than the server.
  result = Response(ok: false, status: "", body: "", error: "", ttfbUs: 0)
  if c.sock == 0'u64:
    c = openConn(c.port)
    if c.sock == 0'u64:
      result.error = "could not connect to 127.0.0.1:" & $c.port
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
        return
      payloadLen = int(m)
    else:
      payload = toBytes(body)
      payloadLen = body.len

  var req = (if body.len > 0: "POST " else: "GET ") & path & " HTTP/1.1\r\n"
  req.add "Host: 127.0.0.1:" & $c.port & "\r\n"
  req.add "Cookie: PHPSESSID=" & session & "\r\n"
  req.add "Content-Length: " & $payloadLen & "\r\n"
  req.add "Connection: keep-alive\r\n\r\n"

  var headBytes = toBytes(req)
  if cSend(c.sock, cast[WirePtr](addr headBytes[0]), int32(req.len)) < 0'i32:
    closeConn(c)
    result.error = "could not send"
    return
  if payloadLen > 0:
    discard cSend(c.sock, cast[WirePtr](addr payload[0]), int32(payloadLen))

  let sentAt = nowUs()
  var headEnd = -1
  var sep = 4
  while not findTerminator(c.buf, c.have, headEnd, sep):
    if c.have >= c.buf.len:
      var bigger = newSeq[byte](c.buf.len * 2)
      copyMem(addr bigger[0], addr c.buf[0], c.have)
      c.buf = bigger
    let m = cRecv(c.sock, cast[WirePtr](addr c.buf[c.have]),
                  int32(c.buf.len - c.have))
    if m <= 0'i32:
      closeConn(c)
      result.error = "the server closed without answering"
      return
    if result.ttfbUs == 0'i64:
      result.ttfbUs = nowUs() - sentAt
    c.have = c.have + int(m)

  let headText = bytesAt(c.buf, 0, headEnd)
  result.status = splitLines(headText)[0]
  let bodyStart = headEnd + sep
  let length = contentLengthOf(headText)
  if length < 0:
    closeConn(c)
    result.error = "no Content-Length on a keep-alive response"
    return

  while c.have < bodyStart + length:
    if c.have >= c.buf.len:
      var bigger = newSeq[byte](c.buf.len * 2)
      copyMem(addr bigger[0], addr c.buf[0], c.have)
      c.buf = bigger
    let m = cRecv(c.sock, cast[WirePtr](addr c.buf[c.have]),
                  int32(c.buf.len - c.have))
    if m <= 0'i32:
      closeConn(c)
      result.error = "the response body was cut short"
      return
    c.have = c.have + int(m)

  if length > 0:
    let rawAt = cast[WirePtr](cast[uint](addr c.buf[0]) + uint(bodyStart))
    if cZlibFramed(rawAt, int32(length)) != 0'i32:
      var cap = length * 8
      if cap < 65536: cap = 65536
      var tries = 0
      var done = false
      while tries < 6 and not done:
        var dst = newSeq[byte](cap)
        let m = cZlibInflate(rawAt, int32(length),
                             cast[WirePtr](addr dst[0]), int32(cap))
        if m >= 0'i32:
          result.body = fromBytes(dst, int(m))
          done = true
        else:
          cap = cap * 4
          inc tries
      if not done:
        result.error = "the response body would not inflate"
        return
    else:
      result.body = bytesAt(c.buf, bodyStart, length)

  # Whatever came in past this response belongs to the next one.
  let consumed = bodyStart + length
  var leftover = c.have - consumed
  if leftover < 0: leftover = 0
  if leftover > 0:
    copyMem(addr c.buf[0],
            cast[pointer](cast[uint](addr c.buf[0]) + uint(consumed)), leftover)
  c.have = leftover
  result.ok = true
