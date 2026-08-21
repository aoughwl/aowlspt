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
import modcontrol
import modstore
import jsonpath
import jsondb
import wire
import websocket
import perfphase

# The shim first: it defines the ABI types the route trampoline needs, and
# the `aowl_sys_*` helpers. `aowlspt_hostboot.h` is deliberately not included
# -- its constructor calls a symbol only the client host defines.
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
# And the revision-5 arming, which is its own header for the reason
# `aowlspt_live.h` is: it names an `aowlspt_nim_*` function only this binary
# defines, so a host that has no websocket must not be made to link it.
{.emit: """#include "aowlspt_notify.h" """.}

proc cNetServe(port, workers: int32): int32 {.importc: "aowl_net_serve", nodecl.}
proc cNetStop() {.importc: "aowl_net_stop", nodecl.}
proc cNetRunning(): int32 {.importc: "aowl_net_running", nodecl.}
proc cNetSend(sock: uint64; buf: HostPtr; len: int32): int32 {.
  importc: "aowl_net_send", nodecl.}
proc cNetLastError(): int32 {.importc: "aowl_net_last_error", nodecl.}
# `aowl_net_recv` is gone from here: this file no longer reads a socket. The
# poller in `aowlspt_net.h` does that, and hands down a complete request. It is
# still in the header for `wire.nim`, whose client sockets are blocking.
# `aowl_net_set_timeout` was named here too and is gone from the header as
# well: it had no caller anywhere in this repo, and `wire.nim` sets
# `SO_RCVTIMEO` itself, inline in its own `{.emit.}` block.
proc cSessionLock(id: HostPtr; len: int32): int32 {.
  importc: "aowl_session_lock", nodecl.}
proc cSessionUnlock(slot: int32) {.
  importc: "aowl_session_unlock", nodecl.}
proc cArmNotify(hostBlock: HostPtr) {.
  importc: "aowl_hostapi_arm_notify", nodecl.}
# The websocket half of `aowlspt_net.h`. These live here and nowhere else:
# nimony emits one translation unit per module and everything in `abi/` is
# `static`, so a second module importing the same header gets its own empty
# copy of the connection table -- which is exactly what happened while
# `websocket.nim` called `aowl_ws_adopt` itself, and the symptom was a correct
# `101` followed instantly by a close.
proc cWsAdopt(sock: uint64): int64 {.importc: "aowl_ws_adopt", nodecl.}
proc cWsSend(ticket: int64; buf: HostPtr; len: int32): int32 {.
  importc: "aowl_ws_send", nodecl.}
proc cLock() {.importc: "aowl_lock", nodecl.}
proc cUnlock() {.importc: "aowl_unlock", nodecl.}

# ------------------------------------------------- the registration tables
#
# `gRoutes` and `gSubs` are the same shape of shared state as the database, and
# had the same hole: read on every request, from sixteen workers, and *rebuilt*
# from the serve loop when a mod is taken out while the server is serving --
# which is not a hypothetical, it is what `aowl test` does with `livectl` every
# run, and what the mod manager panel does from the game.
#
# `dropModRegistrations` assigned a freshly built sequence over each of them.
# That drops the last reference to the old buffer, and a worker walking it in
# `matchRoute` is then walking freed memory -- the same use-after-free the
# document had, one table over. `hostRouteRegister` appending from a mod's
# thread is the same race with a smaller window: a growing `seq` reallocates.
#
# One reader-writer lock over both, because both are rebuilt by the same pass
# and holding two would be an ordering to get wrong. Shared for the walk,
# exclusive for a registration or a teardown. A walk is a few dozen string
# compares and never runs a mod's code with the lock held -- see `matchRoute`
# and `deliverEvent`, both of which copy out what they need and let go before
# calling anything, which is what keeps a handler that registers a route from
# deadlocking against the walk that dispatched to it.
{.emit: """
static SRWLOCK aowl_reg_lock;
static void aowl_reg_read_begin(void)  { AcquireSRWLockShared(&aowl_reg_lock); }
static void aowl_reg_read_end(void)    { ReleaseSRWLockShared(&aowl_reg_lock); }
static void aowl_reg_write_begin(void) { AcquireSRWLockExclusive(&aowl_reg_lock); }
static void aowl_reg_write_end(void)   { ReleaseSRWLockExclusive(&aowl_reg_lock); }

/* `gRequests` is a counter and nothing more, and it was `inc`remented from
 * every worker at once -- which on a non-atomic read-modify-write loses counts
 * and, worse, is the kind of thing a reader of the status route quotes as if
 * it meant something. */
static LONG64 aowl_req_count = 0;
static int64_t aowl_req_bump(void) {
    return (int64_t)InterlockedIncrement64(&aowl_req_count);
}
static int64_t aowl_req_read(void) {
    return (int64_t)InterlockedCompareExchange64(&aowl_req_count, 0, 0);
}
""".}

proc cRegRead() {.importc: "aowl_reg_read_begin", nodecl.}
proc cRegReadEnd() {.importc: "aowl_reg_read_end", nodecl.}
proc cRegWrite() {.importc: "aowl_reg_write_begin", nodecl.}
proc cRegWriteEnd() {.importc: "aowl_reg_write_end", nodecl.}
proc cReqBump(): int64 {.importc: "aowl_req_bump", nodecl.}
proc cReqRead(): int64 {.importc: "aowl_req_read", nodecl.}

const
  HostName = "aowlspt-backend"
  HostVersion = "0.1.0"
  RouteStatic = 0'i32
  RouteDynamic = 1'i32
  HeadCapBytes = 65536
    ## How many header bytes a request may take before it is refused `431`.
    ## Must match `AOWL_HEAD_CAP` in `aowlspt_net.h`, which is the side that
    ## stops reading; this is only the number the refusal quotes.

  # The three receive deadlines -- 5 s idle on a kept-alive connection, 3 s to
  # a complete header, 5 s from there to a complete body -- and the 512-request
  # keep-alive cap used to be constants here, because the loop that enforced
  # them was here. They are `AOWL_IDLE_MS`, `AOWL_HEAD_MS`, `AOWL_BODY_MS` and
  # `AOWL_KEEPALIVE_MAX` in `aowlspt_net.h` now, with the same values and the
  # same reasoning, because the poller is what holds the clock. Nothing in this
  # file waits for a socket any more, so there was no honest way to keep them
  # here as well; two copies of a deadline is one copy that goes stale.

  WsaAddrInUse = 10048
    ## `WSAEADDRINUSE`. What a bind against a port somebody else is listening
    ## on answers, now that the listening socket asks for the port exclusively.
  WsaAccess = 10013
    ## `WSAEACCES`. The same collision seen from the other side: it is what
    ## Windows answers when the port is held by a socket that asked for it
    ## exclusively, and both have to be recognised or half the collisions are
    ## reported as an unexplained number.

  MaxBodyBytes = 16 * 1024 * 1024
    ## The largest request body this server will hold, framed or inflated.
    ##
    ## It is a bound on the *declared* length as well as on the inflated one,
    ## and that half is not a nicety: the body buffer used to be allocated at
    ## whatever `Content-Length` said, so a 90-byte request saying
    ## `Content-Length: 9000000000000000000` allocated nine exabytes, got an
    ## empty seq back, and took the whole process down on the bounds check that
    ## followed. One client, one request, no game server. A declared length
    ## over this is refused with 413 before anything is allocated.
    ##
    ## The other half is the amplification. Sixty-four kilobytes of zlib expand
    ## to sixty-four megabytes of one repeated byte, and a ceiling set where a
    ## bomb like that still fits is a ceiling that buys nothing: the pool is
    ## sixteen workers, so it is sixteen of whatever this number is, in flight,
    ## for the price of half a megabyte on the wire. Sixteen megabytes is far above
    ## the largest request the game makes -- `match/local/end` posts the whole
    ## profile document and that is single-digit megabytes for a full stash --
    ## and low enough that the bomb is refused rather than served.

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
    modIndex: int
      ## Whose timer this is. Only used when that mod is taken out: a timer
      ## holds a function pointer into the mod's library, so one left behind
      ## comes due after `FreeLibrary` and calls into unmapped memory.

var gRoutes: seq[Route] = @[]
var gSubs: seq[Sub] = @[]
var gTimers: seq[Timer] = @[]
var gRoot = ""
var gPort = 6969
# `gRequests` lives in an interlocked counter in the emit block above; this is
# the read side of it. It was a plain `var` incremented from every worker.
proc gRequests(): int = int(cReqRead())

# --------------------------------------------------------------- bytes
#
# `toBytes` / `fromBytes` live in `wire.nim` now and go through `copyMem`.
# They used to be per-byte loops here as well, which is invisible on a 200-byte
# request and is the largest single cost on a 4 MB one: a route body has to
# cross from the mod's buffer into a string and then into a byte buffer, and
# doing either of those a byte at a time costs more than deflating it.

proc inflateBody(raw {.byref.}: seq[byte]; rawLen: int; into: var string): bool =
  ## Inflates when the body looks framed, passes it through when it does not.
  ##
  ## `byref` on the buffer is not a micro-optimisation: a by-value `seq`
  ## parameter copies the whole request body on entry, and this is called with
  ## the raw receive buffer.
  into = ""
  if rawLen <= 0:
    return true
  let src = cast[WirePtr](addr raw[0])
  if cZlibFramed(src, int32(rawLen)) == 0'i32:
    into = fromBytes(raw, rawLen)
    return true
  # Sized to the body, then grown on failure -- rather than 64x with a 64 KB
  # floor, which is what this used to do unconditionally.
  #
  # The floor was the expensive half. Every request the client makes carries a
  # body of a few hundred bytes, so every one of them allocated and zeroed
  # 64 KB to inflate 200 bytes into, and the allocation cost more than the
  # inflate did. 16x covers JSON of this shape in a single pass; the retry is
  # what keeps the cases it does not cover slower rather than refused, and the
  # ceiling is still there so a malformed length cannot become an allocation
  # attack.
  #
  # The buffer is allocated once and re-allocated across the loop rather than
  # inside it, and the length handed to `inflate` is **the buffer's own**
  # rather than the `cap` it was asked for. That is not style. A `var dst`
  # declared inside the loop is destroyed at the end of every iteration, and
  # the replacement did not behave as its `cap` claimed: every body that
  # inflated to more than 65,536 bytes was refused with a 400, deterministically
  # and only on a retry -- so a request whose first guess was big enough went
  # through and the same bytes compressed better did not. `/client/match/local/end`
  # posts the whole profile document, which is past 64 KB for any real profile,
  # so this was a client that could not come back from a raid rather than
  # anything a fuzzer had to find. Reading the length off the buffer makes the
  # two impossible to disagree.
  var cap = rawLen * 16
  if cap < 4096: cap = 4096
  if cap > MaxBodyBytes: cap = MaxBodyBytes
  var dst = newSeq[byte](cap)
  var tries = 0
  while tries < 4:
    let room = dst.len
    let n = cZlibInflate(src, int32(rawLen),
                         cast[WirePtr](addr dst[0]), int32(room))
    if n >= 0'i32:
      into = fromBytes(dst, int(n))
      return true
    if room >= MaxBodyBytes:
      return false
    var grown = room * 8
    if grown > MaxBodyBytes: grown = MaxBodyBytes
    dst = newSeq[byte](grown)
    inc tries
  result = false

proc deflateBody(text {.byref.}: string; into: var seq[byte];
                 outLen: var int): bool =
  ## Deflates straight out of the string.
  ##
  ## It used to copy `text` into a `seq[byte]` first, one byte at a time, which
  ## on the static tables was more wall time than the compression itself.
  outLen = 0
  into = @[]
  if text.len == 0:
    return true
  let cap = cZlibBound(int32(text.len))
  into = newSeq[byte](int(cap))
  let n = cZlibDeflate(cast[WirePtr](readRawData(text)), int32(text.len),
                       cast[WirePtr](addr into[0]), cap)
  if n < 0'i32:
    return false
  outLen = int(n)
  result = true

# --------------------------------------------------- the compressed-body cache
#
# The static tables are the same bytes on every request and deflating 4 MB of
# JSON costs ~45 ms. Nothing about them changes between requests, so the second
# and every later request for one should not pay that again.
#
# **The cache key is the response text itself**, not the URL and not a database
# revision counter. That is the whole design. A key derived from anything else
# has to be invalidated when the answer changes, and the answer here can change
# for reasons this module cannot see -- `dbPatch` from a timer, a mod rebuilding
# a table, a route that varies its answer by session. Keying on the bytes makes
# a stale hit impossible by construction: an entry can only be returned for a
# body byte-identical to the one it was built from. The price is a `memcmp` of
# the body per request, which at 4 MB is under a millisecond against the 45 the
# deflate costs.

const
  ZCacheMinBody = 8192   ## below this, the compare costs more than the deflate
  ZCacheMax = 12         ## entries; the emulator has seven bodies this large

type
  ZEntry = object
    text: string
    packed: seq[byte]
    packedLen: int
    stamp: int64

var gZCache: seq[ZEntry] = @[]
var gZStamp = 0'i64
var gZHits = 0
var gZMisses = 0
var gZSkipped = 0

proc zFind(body {.byref.}: string): int =
  ## Caller holds the lock. Length first: it rejects every non-candidate
  ## without touching the bytes.
  ##
  ## `byref`, here and on `cachedDeflate` and `sendResponse` below, for the
  ## same reason `inflateBody` has it: a by-value string parameter copies the
  ## whole body on entry, and the whole body is four megabytes for
  ## `/client/items`. The response used to cross three of those signatures on
  ## its way to the socket, which is three copies of the answer per request
  ## that nothing reads.
  result = -1
  for i in 0 ..< gZCache.len:
    if gZCache[i].text.len == body.len and gZCache[i].text == body:
      return i

proc cachedDeflate(body {.byref.}: string; into: var seq[byte];
                   outLen: var int): bool =
  if body.len < ZCacheMinBody:
    inc gZSkipped
    return deflateBody(body, into, outLen)

  cLock()
  var hit = zFind(body)
  if hit >= 0:
    inc gZStamp
    gZCache[hit].stamp = gZStamp
    inc gZHits
    outLen = gZCache[hit].packedLen
    into = newSeq[byte](if outLen > 0: outLen else: 1)
    if outLen > 0:
      copyMem(addr into[0], addr gZCache[hit].packed[0], outLen)
    cUnlock()
    return true
  inc gZMisses
  cUnlock()

  # Deflated outside the lock. Holding it here would serialise every worker
  # behind the first one to ask for a table, which is exactly the moment the
  # client asks for all of them at once.
  if not deflateBody(body, into, outLen):
    return false

  cLock()
  # Re-checked, because two workers can miss the same body at the same time and
  # the second one must not add a duplicate entry that then evicts a live one.
  if zFind(body) < 0:
    var slot = -1
    if gZCache.len >= ZCacheMax:
      slot = 0
      for i in 1 ..< gZCache.len:
        if gZCache[i].stamp < gZCache[slot].stamp:
          slot = i
    inc gZStamp
    var p = newSeq[byte](if outLen > 0: outLen else: 1)
    if outLen > 0:
      copyMem(addr p[0], addr into[0], outLen)
    let e = ZEntry(text: body, packed: p, packedLen: outLen, stamp: gZStamp)
    if slot >= 0: gZCache[slot] = e
    else: gZCache.add e
  cUnlock()
  result = true

# --------------------------------------------------------------- http

type
  Request = object
    verb: string
    url: string
    session: string
    body: string
    ok: bool
    keepAlive: bool
    ## The caller asked for an unencoded body.
    ##
    ## Every response here is zlib-deflated, because that is what the game
    ## client expects and it does not say so in a header -- so the server cannot
    ## infer it and answers that way by default. Anything else talking to this
    ## server (the overlay, a browser, `curl`) gets a body starting `78 9C` and
    ## no `Content-Encoding` to explain it, which looks like a corrupt answer
    ## rather than a compressed one. Sending `Accept-Encoding: identity` opts
    ## out. The game never sends that header, so its path is byte-identical.
    identity: bool

proc jsonQuoted(s: string): string =
  ## `s` as a JSON string literal, escapes and all.
  ##
  ## The 404 body carries the url that was asked for, and it used to carry it
  ## verbatim: a request for `/client/x"y` answered
  ## `{"err":"no route","url":"/client/x"y"}`, which no parser will read, and a
  ## url with a NUL or a stray 0x80 in it put bytes in a JSON string that are
  ## not text at all. Anything a request chose the bytes of has to go through
  ## here on its way into a response.
  result = "\""
  for ch in s:
    let c = ord(ch)
    if ch == '"': result.add "\\\""
    elif ch == '\\': result.add "\\\\"
    elif ch == '\n': result.add "\\n"
    elif ch == '\r': result.add "\\r"
    elif ch == '\t': result.add "\\t"
    elif c < 32 or c > 126:
      # Control bytes and everything outside plain ASCII as `\u00XX`. A url is
      # not promised to be UTF-8 -- the client picks the bytes -- and a lone
      # 0x80 copied into a response is a body the client cannot decode.
      const Hex = "0123456789abcdef"
      result.add "\\u00"
      result.add Hex[(c shr 4) and 15]
      result.add Hex[c and 15]
    else:
      result.add ch
  result.add "\""

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
  var sawLength = false
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
  # HTTP/1.1 keeps the connection open unless the client says otherwise; 1.0
  # closes unless it says otherwise. Getting that default backwards is how a
  # server ends up holding a socket the client has already forgotten about.
  r.keepAlive = find(first, "HTTP/1.1") >= 0

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
      var digitsOnly = true
      for ch in value:
        if ch >= '0' and ch <= '9':
          # Clamped as it is read rather than after. `v * 10 + d` over a
          # nineteen-digit header wraps to a negative number, and a negative
          # length is a different bug in every place that then uses it.
          if v <= MaxBodyBytes:
            v = v * 10 + (ord(ch) - ord('0'))
          any = true
        else:
          digitsOnly = false
      # A value that is not `1*DIGIT` is refused rather than read as far as it
      # parses. It used to stop at the first non-digit and keep what it had, so
      # `-1`, `+5`, `0x10` and an empty value were all a length of *zero* -- and
      # a zero length means the bytes the client sent as the body are the
      # beginning of the next request on this connection. `aowl_scan_length`
      # read them the same way, so the framer and this agreed, and two parties
      # agreeing that a request ends before its body is what a request
      # smuggling primitive is. `backend/framelen.nim` sends each of them with
      # a request behind it and requires exactly one answer.
      if not any or not digitsOnly:
        return false
      # A second, disagreeing `Content-Length` is refused rather than having
      # one of them win: which one wins decides where this request ends and
      # the next one on the same connection begins, and a server that guesses
      # is a server two parties can be made to disagree about.
      if sawLength and v != contentLength:
        return false
      sawLength = true
      contentLength = v
    elif name == "accept-encoding":
      # Only `identity` is honoured, and only when it is asked for alone or
      # first: this is not a content negotiation, it is one client saying it
      # cannot inflate.
      let want = toLowerAscii(value)
      if find(want, "identity") >= 0 and find(want, "deflate") < 0:
        r.identity = true
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
    elif name == "connection":
      let v = toLowerAscii(value)
      if find(v, "close") >= 0:
        r.keepAlive = false
      elif find(v, "keep-alive") >= 0:
        r.keepAlive = true

  r.ok = true
  result = true

proc sendResponse(sock: uint64; status: string; body {.byref.}: string;
                  compress: bool; keepAlive = false;
                  contentType = "application/json") =
  var payload: seq[byte] = @[]
  var payloadLen = 0
  var compressed = false
  let tDeflate = perfNow()
  if compress and body.len > 0:
    if cachedDeflate(body, payload, payloadLen):
      compressed = true
    else:
      payloadLen = body.len
  else:
    payloadLen = body.len
  perfAdd(PhaseDeflate, tDeflate)

  var head = "HTTP/1.1 " & status & "\r\n"
  head.add "Content-Type: " & contentType & "\r\n"
  head.add "Content-Length: " & $payloadLen & "\r\n"
  head.add(if keepAlive: "Connection: keep-alive\r\n"
           else: "Connection: close\r\n")
  head.add "\r\n"

  let tSend = perfNow()
  # One `send` for a small answer, two for a large one.
  #
  # A header and a body sent separately are two system calls and two segments,
  # and the second one is at the mercy of Nagle: this socket has no
  # `TCP_NODELAY` on it, so a second small write can sit waiting for the first
  # to be acknowledged. On loopback that rarely bites and it is not a risk
  # worth carrying for the sake of avoiding a copy of a kilobyte -- which is
  # what almost every response here is, the large static tables being the
  # handful that are not.
  #
  # Above the threshold the copy would be the larger cost of the two and the
  # body goes out on its own, straight from wherever it already is: out of the
  # compressed buffer, or out of the response string via `readRawData`. That
  # path never allocated a copy just to have a pointer to hand `send`, and it
  # still does not.
  if payloadLen > 0 and payloadLen <= 65536:
    var whole = head
    if compressed:
      whole.add fromBytes(payload, payloadLen)
    else:
      whole.add body
    discard cNetSend(sock, cast[HostPtr](toCString(whole)), int32(whole.len))
  else:
    discard cNetSend(sock, cast[HostPtr](toCString(head)), int32(head.len))
    if payloadLen > 0:
      if compressed:
        discard cNetSend(sock, cast[HostPtr](addr payload[0]),
                         int32(payloadLen))
      else:
        discard cNetSend(sock, cast[HostPtr](readRawData(body)),
                         int32(payloadLen))
  perfAdd(PhaseSend, tSend)

# --------------------------------------------------------------- routing

proc matchRoute(url: string; into: var Route): bool =
  ## Exact matches win over prefixes, and the longest prefix wins among those.
  ## Registration order deciding it instead would make two mods' behaviour
  ## depend on their filenames.
  ##
  ## It answers with **the route** rather than with its index, and that is the
  ## concurrency fix rather than a tidy-up. An index is only meaningful while
  ## the table it indexes has not moved, and the table is rebuilt whenever a mod
  ## is unloaded -- so the old shape had a window between matching a route here
  ## and invoking it below (a window that contains the session lock, which is
  ## allowed to wait ten seconds) in which every index shifted by one. The
  ## request would then have been answered by whichever route slid into its
  ## place, or by reading past the end of a shorter table. A copy taken under
  ## the lock cannot go stale in a way that matters: the worst case is that a
  ## request already in flight is answered by the route that was there when it
  ## arrived, which is the only sensible reading of "unloaded while serving".
  result = false
  var bestLen = -1
  cRegRead()
  for i in 0 ..< gRoutes.len:
    if gRoutes[i].kind == RouteStatic:
      if gRoutes[i].url == url:
        into = gRoutes[i]
        cRegReadEnd()
        return true
    else:
      if url.len >= gRoutes[i].url.len and
         url.substr(0, gRoutes[i].url.len - 1) == gRoutes[i].url:
        if gRoutes[i].url.len > bestLen:
          bestLen = gRoutes[i].url.len
          into = gRoutes[i]
          result = true
  cRegReadEnd()

# The route callback goes through `aowl_invoke_route` in the shim, which is
# where it has to live: the trampoline needs the ABI's struct types, and those
# only exist in the translation unit that includes the header.
proc cInvokeRoute(cb, user, url: HostPtr; urlLen: int32;
                  body: HostPtr; bodyLen: int32;
                  session: HostPtr; sessionLen: int32;
                  outPtr, outLen: HostPtr): int32 {.
  importc: "aowl_invoke_route", nodecl.}
proc cFreeBuf(p: HostPtr) {.importc: "aowl_host_release", nodecl.}
proc cConnFinal(): int32 {.importc: "aowl_conn_final", nodecl.}

proc runRoute(route: Route; r: Request; into: var string): bool =
  ## The route is a copy taken under the registration lock, and nothing here
  ## holds that lock: this calls into a mod, a mod may register a route from a
  ## handler, and a walk that held the lock across the call would be waiting on
  ## itself.
  into = ""
  var url = r.url
  var body = r.body
  var session = r.session
  var outPtr: HostPtr = cast[HostPtr](0)
  var outLen = 0'i32
  let st = cInvokeRoute(route.cb, route.user,
                        cast[HostPtr](toCString(url)), int32(url.len),
                        cast[HostPtr](toCString(body)), int32(body.len),
                        cast[HostPtr](toCString(session)), int32(session.len),
                        cast[HostPtr](addr outPtr), cast[HostPtr](addr outLen))
  if outPtr != nil and outLen > 0'i32:
    # `readMem`, not `modhost.readBytes`: the latter goes through
    # `aowl_byte_at`, one call across a translation unit per byte, and a static
    # table is millions of them. Same bytes, one `copyMem`.
    into = readMem(cast[WirePtr](outPtr), outLen)
  if outPtr != nil:
    cFreeBuf(outPtr)
  result = st == StatusOk

# --------------------------------------------------------------- serving

proc sendTimeout(sock: uint64; phase: int32; have: int32;
                 declared: int32) {.exportc: "aowlspt_nim_timeout", cdecl.} =
  ## The `408` for a request that began and stopped.
  ##
  ## The poller decides *that* a request has stopped arriving -- it is the one
  ## holding the clock -- but it does not write the answer. Every byte this
  ## server puts on a socket is still composed here, which is what keeps
  ## `aowlspt_net.h` a file about sockets rather than a second, quieter HTTP
  ## implementation. The two bodies are the ones the receive loop used to send,
  ## unchanged.
  if phase == 0'i32:
    sendResponse(sock, "408 Request Timeout",
                 "{\"err\":\"the request headers stopped arriving\"," &
                 "\"after\":" & $int(have) & "}", false)
  else:
    sendResponse(sock, "408 Request Timeout",
                 "{\"err\":\"the request body stopped arriving\"," &
                 "\"had\":" & $int(have) & ",\"declared\":" &
                 $int(declared) & "}", false)

# --------------------------------------------------------------- websocket
#
# The four calls the poller makes and the one the ABI makes. All of them are
# three lines: the work is in `backend/websocket.nim`, and what is here is the
# `exportc` boundary, kept in this file because every other one is.

proc wsRawSend(sock: uint64; data: string): bool =
  discard cNetSend(sock, cast[HostPtr](readRawData(data)), int32(data.len))
  result = true

proc wsFrameSend(ticket: int64; data: string): bool =
  result = cWsSend(ticket, cast[HostPtr](readRawData(data)),
                   int32(data.len)) >= 0'i32

proc wsAdopt(sock: uint64): int64 = cWsAdopt(sock)

proc wsMessageIn(ticket: int64; opcode: int32; p: HostPtr;
                 len: int32): int32 {.
    exportc: "aowlspt_nim_ws_message", cdecl.} =
  let keep = websocket.wsOnMessage(ticket, int(opcode),
                                   readMem(cast[WirePtr](p), len))
  result = (if keep: 1'i32 else: 0'i32)

proc wsControlIn(ticket: int64; kind: int32; code: int32; p: HostPtr;
                 len: int32) {.
    exportc: "aowlspt_nim_ws_control", cdecl.} =
  websocket.wsOnControl(ticket, int(kind), int(code),
                        readMem(cast[WirePtr](p), len))

proc wsIdleIn(ticket: int64; pinged: int32): int32 {.
    exportc: "aowlspt_nim_ws_idle", cdecl.} =
  result = (if websocket.wsOnIdle(ticket, pinged != 0'i32): 1'i32 else: 0'i32)

proc wsGoneIn(ticket: int64) {.exportc: "aowlspt_nim_ws_gone", cdecl.} =
  websocket.wsOnGone(ticket)

proc hostNotifyPush(session: HostPtr; sessionLen: int32;
                    payload: HostPtr; payloadLen: int32): int32 {.
    exportc: "aowlspt_nim_notify_push", cdecl.} =
  ## `notify_push`, revision 5. `ErrNotFound` means there is no websocket for
  ## that session, which is an ordinary answer the mod falls back from -- and
  ## it must not be `Ok`, because `Ok` would tell the mod the player has been
  ## told.
  let s = readMem(cast[WirePtr](session), sessionLen)
  let p = readMem(cast[WirePtr](payload), payloadLen)
  if s.len == 0 or p.len == 0:
    return ErrBadArg
  result = (if websocket.wsPush(s, p): StatusOk else: ErrNotFound)

proc handleRequest(sock: uint64; buf: HostPtr; len: int32;
                   headEnd: int32; sep: int32): int32 {.
    exportc: "aowlspt_nim_handle", cdecl.} =
  ## Answers exactly one request, out of a buffer the poller has already
  ## filled. Returns 1 if the connection may be kept alive, 0 if it must close,
  ## and **2 if the request was a websocket handshake this answered `101`** --
  ## in which case the connection is no longer a request stream at all and the
  ## poller takes it out of the state machine that reads it as one.
  ##
  ## This used to be `serveConnection`, and it used to own the socket: it
  ## looped on `recv` until the client let go, which meant a worker thread was
  ## occupied for the life of a connection and the pool size was the connection
  ## limit. Three receive deadlines bounded the damage a stalled connection did
  ## and could not remove it, because the shape was the problem -- see the head
  ## of `aowlspt_net.h` for the shape that replaced it.
  ##
  ## What that leaves here is the part that was always the interesting part:
  ## one request's bytes in, one response's bytes out. There is no loop, no
  ## clock and no socket read. The framing -- where this request ends and the
  ## next begins -- is decided by the poller and re-checked below, and every
  ## way the two could disagree is answered and closed on, so a disagreement
  ## cannot desynchronise a kept-alive stream.
  if headEnd < 0'i32:
    # The poller gave up looking for a header terminator.
    sendResponse(sock, "431 Request Header Fields Too Large",
                 "{\"err\":\"the request headers do not fit in " &
                 $HeadCapBytes & " bytes\"}", false)
    return 0'i32

  let head = readMem(cast[WirePtr](buf), headEnd)

  var req = Request(verb: "", url: "", session: "", body: "", ok: false,
                    keepAlive: false)
  var contentLength = 0
  if not parseHead(head, req, contentLength):
    # Every refusal here says which one it is. A 400 with an empty body is
    # indistinguishable from a server that fell over, which is exactly the
    # question anyone reading it is trying to answer.
    sendResponse(sock, "400 Bad Request",
                 "{\"err\":\"the request line or its Content-Length is " &
                 "malformed\"}", false)
    return 0'i32

  # The connection's last allowed request answers `Connection: close`.
  #
  # `AOWL_KEEPALIVE_MAX` is applied by the poller after the answer has gone
  # out, so this request's response used to promise a connection that was
  # already going to be closed under it. Every `return` below turns
  # `req.keepAlive` into the poller's keep/close answer as well, so clearing it
  # here makes the header and the socket agree instead of contradicting each
  # other -- and the poller closes on either.
  if cConnFinal() != 0'i32:
    req.keepAlive = false

  # Every phase this thread accounts for from here on belongs to this URL.
  # Before the body work rather than after it, so `inflate` lands in the right
  # row; after `parseHead`, because there is no URL to name until it has run.
  perfBegin(req.url)

  # Refused rather than served, and the poller never waited for the body: the
  # allocation *is* the attack. See `MaxBodyBytes`.
  if contentLength > MaxBodyBytes:
    sendResponse(sock, "413 Payload Too Large",
                 "{\"err\":\"the body is larger than this server accepts\"," &
                 "\"limit\":" & $MaxBodyBytes & "}", false)
    return 0'i32

  let bodyStart = int(headEnd) + int(sep)
  var bodyHave = int(len) - bodyStart
  if bodyHave < 0: bodyHave = 0
  if bodyHave > contentLength: bodyHave = contentLength
  if bodyHave < contentLength:
    # The poller only hands over complete requests, so this is unreachable
    # unless its framing and `parseHead` read the same headers differently --
    # a second, disagreeing `Content-Length` is the way to arrange that. It is
    # refused and the connection closed, which is what makes the disagreement
    # harmless: there is no next request on this socket to get wrong.
    sendResponse(sock, "400 Bad Request",
                 "{\"err\":\"the request line or its Content-Length is " &
                 "malformed\"}", false)
    return 0'i32

  var bodyBytes = newSeq[byte](if bodyHave > 0: bodyHave else: 1)
  if bodyHave > 0:
    copyMem(addr bodyBytes[0],
            cast[pointer](cast[uint](buf) + uint(bodyStart)), bodyHave)

  let tInflate = perfNow()
  let inflated = inflateBody(bodyBytes, bodyHave, req.body)
  perfAdd(PhaseInflate, tInflate)
  if not inflated:
    modhost.warn "could not inflate a " & $bodyHave & "-byte body for " &
                 req.url
    sendResponse(sock, "400 Bad Request",
                 "{\"err\":\"the request body is not a zlib stream this " &
                 "server can inflate\",\"bytes\":" & $bodyHave & "}", false)
    return 0'i32

  discard cReqBump()

  if req.session.len == 0 and websocket.isUpgrade(head):
    # The client puts the session in the path of the notifier URL --
    # `/client/notifier/getwebsocket/<id>` -- and does not always send the
    # cookie with it. Taken from the last path segment only when there is no
    # cookie, and only for an upgrade, so no ordinary route can have a session
    # invented for it out of its own URL; and it goes through `isHexId` below
    # like every other session, so the path is not a way around that check.
    var tail = req.url
    let q = find(tail, "?")
    if q >= 0: tail = tail.substr(0, q - 1)
    var slash = -1
    var k = tail.len - 1
    while k >= 0:
      if tail[k] == '/':
        slash = k
        break
      dec k
    if slash >= 0: tail = tail.substr(slash + 1)
    if isHexId(tail): req.session = tail

  if req.session.len > 0 and not isHexId(req.session):
    # Rejected before any route sees it: a malformed id reaching a mod would
    # be reported as that mod's bug.
    modhost.warn "rejecting a malformed session id on " & req.url
    sendResponse(sock, "400 Bad Request", "{\"err\":\"bad session id\"}",
                 true, req.keepAlive)
    return (if req.keepAlive: 1'i32 else: 0'i32)

  if websocket.isUpgrade(head):
    # A websocket, and this is the fork in the whole request path.
    #
    # It is answered here rather than by a route on purpose: which URL carries
    # the notifier is the game's business and lives in `mods/tarkov`, but
    # *holding a connection* is the pipeline's, and a mod cannot be handed a
    # socket without handing it the poller's invariants with it. So the backend
    # upgrades any request that asks, keyed on the session it carries, and the
    # mod pushes by session and never learns there is a socket.
    #
    # Returning 2 is what takes this connection out of the request state
    # machine for good -- see the head of `aowlspt_net.h`, where getting that
    # wrong is the stalled-connection starvation the poller exists to remove,
    # rebuilt one socket at a time.
    var ticket = 0'i64
    if websocket.handshake(sock, head, req.session, ticket):
      return 2'i32
    return 0'i32

  let tMatch = perfNow()
  var route = Route(url: "", kind: RouteStatic, cb: cast[HostPtr](0),
                    user: cast[HostPtr](0), modIndex: -1)
  let matched = matchRoute(req.url, route)
  perfAdd(PhaseMatch, tMatch)
  if not matched:
    sendResponse(sock, "404 Not Found",
                 "{\"err\":\"no route\",\"url\":" &
                 jsonQuoted(req.url) & "}", not req.identity, req.keepAlive)
    return (if req.keepAlive: 1'i32 else: 0'i32)

  # One session at a time through a route handler.
  #
  # A handler for this client is a read-modify-write of a whole profile
  # document: it loads the profile, changes it, and saves it back. Two requests
  # carrying the same session id used to run that concurrently and one of them
  # lost -- six concurrent purchases were each answered `err:0` and three
  # rifles arrived, with the arithmetic self-consistent and three payments
  # silently discarded. The emulator narrowed the window from its side and said
  # so in `mods/tarkov/emu/profile.nim`; narrowing is not closing, and the
  # close belongs here, because this is the only place that knows a request is
  # about to begin and has somewhere to put a lock.
  #
  # It wraps the whole callback rather than the store call, because the read
  # and the write are at either end of the handler and anything narrower leaves
  # the same race in a smaller window. It is keyed on the session, so two
  # profiles do not wait on each other and a route with no session -- the
  # status routes, the mod manager -- takes no lock at all. And it is released
  # before the answer goes out and long before the connection waits for its
  # next request, so keep-alive holds nothing: the lock is per session, not per
  # connection.
  #
  # `aowl_session_lock` is where the rest of it is written down, including what
  # happens to a handler that never returns.
  var slot = -1'i32
  if req.session.len > 0:
    slot = cSessionLock(cast[HostPtr](toCString(req.session)),
                        int32(req.session.len))
  if slot == -2'i32:
    # Ten seconds waiting for another request on the same profile to finish.
    # That is a wedged handler, not contention, and saying so beats holding a
    # worker until the process ends.
    modhost.warn "gave up waiting for the session lock on " & req.url
    sendResponse(sock, "503 Service Unavailable",
                 "{\"err\":\"another request on this profile has not " &
                 "finished\"}", not req.identity, req.keepAlive)
    return (if req.keepAlive: 1'i32 else: 0'i32)

  # A reference on the mod, held across the call and given back after it.
  #
  # `matchRoute` copied this route out under the registration lock and let go,
  # which is what keeps a handler that registers a route from waiting on the
  # walk that dispatched to it -- and it is also what leaves this thread
  # carrying a function pointer into a library the control thread is allowed to
  # free. Everything the *host* holds is dropped by the teardown; this pointer
  # is not held by the host, it is held by this stack, and the only thing that
  # can protect it is a count the unload can see. `modhost.modEnter` takes it
  # and `modhost.modLeave` gives it back; the ordering that makes the pair
  # correct is written down where they are.
  #
  # 7.3 ns for the pair against a handler that costs about 423 us. It is under
  # the session lock rather than over it on purpose: taken first, a request
  # waiting ten seconds for another request on the same profile would hold a
  # mod open for those ten seconds and turn a live unload into a timeout.
  if not modhost.modEnter(route.modIndex):
    # The mod is draining. Not a 404: the route is still registered and will be
    # gone in a moment, and the honest answer to "ask again" is 503 rather than
    # "there was never anything here".
    if slot >= 0'i32:
      cSessionUnlock(slot)
    sendResponse(sock, "503 Service Unavailable",
                 "{\"err\":\"that mod is being unloaded\",\"url\":" &
                 jsonQuoted(req.url) & "}", not req.identity, req.keepAlive)
    return (if req.keepAlive: 1'i32 else: 0'i32)

  var body = ""
  let tRoute = perfNow()
  let served1 = runRoute(route, req, body)
  perfAdd(PhaseRoute, tRoute)
  modhost.modLeave(route.modIndex)
  if slot >= 0'i32:
    cSessionUnlock(slot)

  if served1:
    # A `/files/*` request is a binary asset (a trader avatar, a handbook icon,
    # a quest image). The client fetches these with an ordinary image request
    # and decodes the raw bytes -- it does NOT inflate them the way it does a
    # `/client/*` body, and it reads the picture from the bytes themselves, not
    # from a header. So this path must go out uncompressed and with an image
    # Content-Type; deflate it or label it `application/json` and the texture
    # never decodes, which is a spinning avatar the client retries forever.
    # Everything else keeps the default (deflate unless the caller sent
    # `identity`, `application/json`).
    var fpath = req.url
    let q = find(fpath, "?")
    if q >= 0: fpath = fpath.substr(0, q - 1)
    if fpath.len >= 7 and fpath.substr(0, 6) == "/files/":
      # The bytes the `/files/` handler returns are a PNG whatever extension the
      # url carried (the client sniffs the format from the magic bytes, not the
      # header or the path), so the honest Content-Type is `image/png`.
      sendResponse(sock, "200 OK", body, false, req.keepAlive, "image/png")
    else:
      sendResponse(sock, "200 OK", body, not req.identity, req.keepAlive)
  else:
    sendResponse(sock, "500 Internal Server Error",
                 "{\"err\":\"the route handler failed\"}",
                 not req.identity, req.keepAlive)
  result = (if req.keepAlive: 1'i32 else: 0'i32)

# --------------------------------------------------------------- host api

var gLastError {.threadvar.}: string
  ## The last error, **per thread**, which is both the fix for a race and the
  ## only reading of "last" that means anything here.
  ##
  ## It was one global string that every one of the sixteen workers assigned to.
  ## Assigning a string frees the buffer that was in it, so two workers failing
  ## a lookup at the same moment is a double free; and `aowlspt_nim_last_error`
  ## hands a mod a pointer into that buffer, which another worker is free to
  ## release while the mod is reading it. `db_get` on a path that is not there
  ## sets it, and a mod probing for an optional table does that on purpose --
  ## so this was not an exotic path.
  ##
  ## Per thread is also what the caller already assumed. A mod calls
  ## `lastError()` after a call that just failed, on the thread that made it;
  ## the answer it wanted was never "the last error anywhere in the server",
  ## and one global could hand it another request's failure with no way to tell.

proc hostLog(ctx: HostPtr; level: int32; msg: HostPtr; len: int32) {.
    exportc: "aowlspt_nim_log", cdecl.} =
  let text = readBytes(msg, len)
  let tLog = perfNow()
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
  perfAdd(PhaseLog, tLog)

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
  # `modhost.configRead` rather than a read and a lookup here, because this is
  # one of the three copies of this that disagreed. It answers the two failures
  # apart -- `ErrNotFound` for no file, `ErrConfigParse` for a file that is not
  # readable JSON -- and puts the file and the fault in `err`, where this used
  # to answer "no such key" for a document no key could ever come out of. A mod
  # that falls back to its defaults on any failure, which is most of them, then
  # ran a whole session on defaults with nothing anywhere saying so.
  var text = ""
  var err = ""
  let st = configRead(idx, text, err)
  if st != StatusOk:
    gLastError = err
    # A whole-document read gets the bytes even when they do not parse. It
    # asked for the file, the file is there, and a mod that reads its config in
    # one round trip and parses it itself -- which is the robust pattern, and
    # the one the mod manager uses -- would otherwise be told "no config" for a
    # config that exists and is broken. The status still says which it is.
    if st == ErrConfigParse and k.len == 0 and text.len > 0:
      var raw = text
      discard cOutCopy(outPtr, outLen, cast[HostPtr](toCString(raw)),
                       int32(raw.len))
    return st
  var value = ""
  if k.len == 0:
    value = text
  elif not pathGet(text, k, value):
    gLastError = "no such key: " & k
    return ErrNotFound
  # `value` is handed to `cOutCopy` directly. It used to be copied into a local
  # `v` first, which on `templates.items` is a 4.25 MB allocation and copy that
  # nothing reads: `cOutCopy` takes a pointer and a length and does its own
  # copy into the host buffer.
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(value)),
                    int32(value.len))

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
  let tDb = perfNow()
  # Copied **once**: out of the document and straight into the host buffer.
  #
  # This was `dbGetPath` into a nimony string and then `cOutCopy` out of that
  # string, which is two copies of the value -- the first into a string that
  # exists only to be the argument of the second. On `templates.items` against
  # a real database that is 12.5 MB allocated and copied for nothing, on every
  # request, and it is one of the seven copies `docs/PERF-SERVER.md` counts
  # between the database and the socket.
  #
  # `dbHoldPath` returns with the document read lock held and `dbRelease` gives
  # it back. The critical section is no longer than it was: `dbGetPath`'s
  # `substr` ran inside the same lock and for the same reason -- the lock is
  # what stops a concurrent `dbPatchPath` splicing the buffer being copied out
  # of. Nothing else is taken while it is held; the rest of the argument is at
  # `dbHoldPath`.
  # The reserved sigil, before anything else looks at the path.
  #
  # `docs/API-GAPS.md`'s gap 2: there is no `db_keys` entry, because adding one
  # is ABI revision 6 and the simulator cannot claim 6 without claiming 5 --
  # which means arming a `notify_push` it has no socket for, and which turns
  # `notifyReady()` from an honest `false` into a `true` in the one host mod
  # authors develop against. So the enumeration rides on the path string of the
  # entry that already exists, and a host that has never heard of the sigil
  # answers `ErrNotFound` for a root member that is not there, which is the
  # degradation a caller wanted anyway.
  var keysOf = ""
  if dbKeysRequest(p, keysOf):
    if keysOf.len == 0:
      # `"?keys "` alone. Refused here and **not found** on a host without
      # this, which is the difference a mod uses as a capability probe. Say
      # what it is rather than only that it is wrong.
      perfAdd(PhaseDbGet, tDb)
      gLastError = "`" & KeysSigil & "` needs a path to enumerate, e.g. `" &
                   KeysSigil & "locations`"
      return ErrBadArg
    var keys = ""
    var why = 0
    if not dbKeysPath(keysOf, keys, why):
      perfAdd(PhaseDbGet, tDb)
      if why == KeysNotAnObject:
        gLastError = keysOf & " is an array or a scalar, not an object"
        return ErrBadArg
      gLastError = "no such database path: " & keysOf
      return ErrNotFound
    result = cOutCopy(outPtr, outLen, cast[HostPtr](readRawData(keys)),
                      int32(keys.len))
    perfAdd(PhaseDbGet, tDb)
    return result

  var at = cast[pointer](0)
  var length = 0
  if not dbHoldPath(p, at, length):
    perfAdd(PhaseDbGet, tDb)
    gLastError = "no such database path: " & p
    return ErrNotFound
  result = cOutCopy(outPtr, outLen, cast[HostPtr](at), int32(length))
  dbRelease()
  perfAdd(PhaseDbGet, tDb)

proc hostDbPatch(ctx: HostPtr; path: HostPtr; pathLen: int32;
                 patch: HostPtr; patchLen: int32): int32 {.
    exportc: "aowlspt_nim_db_patch", cdecl.} =
  let p = readBytes(path, pathLen)
  let j = readBytes(patch, patchLen)
  var err = ""
  let tDb = perfNow()
  let patched = dbPatchPath(p, j, err)
  perfAdd(PhaseDbPatch, tDb)
  if not patched:
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
  # The duplicate check and the append are one operation under the lock. Two
  # mods registering the same url from two threads would otherwise both look,
  # both miss, and both add.
  cRegWrite()
  var clash = false
  for r in gRoutes:
    if r.url == u and r.kind == kind:
      clash = true
  if not clash:
    gRoutes.add Route(url: u, kind: kind, cb: cb, user: user,
                      modIndex: int(cast[uint](ctx)))
  cRegWriteEnd()
  if clash:
    gLastError = "the route " & u & " is already registered"
    return ErrGeneric
  modhost.okLog "route " & u & (if kind == RouteDynamic: " (prefix)" else: "")
  result = StatusOk

proc deliverEvent(n, body: string; fromIndex: int): int =
  ## One event to every subscriber but `fromIndex`. Factored out of the emit
  ## entry point because the **host** emits too now -- the mod-control replies
  ## come from here rather than from any mod, and pass `fromIndex = -1` so that
  ## nobody is skipped.
  ##
  ## The matching subscribers are copied out under the registration lock and
  ## called with nothing held. Calling them under it would be a deadlock the
  ## first time a subscriber subscribed to something, and would hold the table
  ## for as long as a mod's handler takes; walking it unlocked was the
  ## use-after-free `dropModRegistrations` opened. A copy is neither.
  result = 0
  var fanout: seq[Sub] = @[]
  cRegRead()
  for i in 0 ..< gSubs.len:
    if gSubs[i].name == n and gSubs[i].modIndex != fromIndex:
      fanout.add gSubs[i]
  cRegReadEnd()
  for i in 0 ..< fanout.len:
    # The same reference `runRoute` takes, for the same reason and against the
    # same window: this is a copied function pointer into a mod's library, and
    # an emit reaches here from a worker thread while the serve loop is free to
    # unload the subscriber. A subscriber that is going away is simply skipped
    # -- an event is a broadcast, and a mod that is being unloaded is exactly a
    # mod that no longer wants to hear about anything.
    #
    # `modGuardable` first, because `modEnter` answers the same `false` for
    # "out of range" as for "being unloaded", and only the second is a reason
    # to skip. A subscriber registered under an index that is not a mod's --
    # `tools/hostharness` uses `0x7FFF` on purpose, so its own registrations
    # outlive the churn it measures -- would otherwise be dropped as though it
    # were going away, and the reply it was waiting for would simply never
    # come. The client host hit exactly that and it took a gate failure to
    # find; nothing registers such an index here today, which is why this is
    # written down rather than left to be rediscovered.
    let guarded = modhost.modGuardable(fanout[i].modIndex)
    if guarded and not modhost.modEnter(fanout[i].modIndex):
      continue
    var b = body
    let st = cInvokeCallback(fanout[i].cb, fanout[i].user,
                             cast[HostPtr](toCString(b)), int32(body.len))
    if guarded:
      modhost.modLeave(fanout[i].modIndex)
    if st != StatusOk:
      # One bad subscriber must not stop the rest: an event is a broadcast, and
      # a mod dropping it is that mod's problem rather than the emitter's.
      modhost.warn "a subscriber to " & n & " returned " & $int(st)
    inc result

proc hostEmit(name, payload: string) =
  ## What `modcontrol` answers through. `-1` is not a mod index, which is the
  ## point: every subscriber hears it, including the manager that asked.
  discard deliverEvent(name, payload, -1)

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
  # A control request is recorded here and performed from the serve loop. Never
  # here: this stack runs through the mod that emitted, and an unload would
  # free the library it is about to return into.
  let control = modcontrol.submit(n, body)
  let delivered = deliverEvent(n, body, from1)
  if delivered == 0 and not control:
    modhost.info "event " & n & " (no subscribers)"
  result = StatusOk

proc hostEventSubscribe(ctx: HostPtr; name: HostPtr; nameLen: int32;
                        cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_event_subscribe", cdecl.} =
  let n = readBytes(name, nameLen)
  if n.len == 0 or cb == nil:
    gLastError = "a subscription needs a name and a handler"
    return ErrBadArg
  cRegWrite()
  gSubs.add Sub(name: n, cb: cb, user: user, modIndex: int(cast[uint](ctx)))
  cRegWriteEnd()
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
  gTimers.add Timer(dueMs: elapsedMs() + d, cb: cb, user: user,
                    modIndex: int(cast[uint](ctx)))
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
  let tStore = perfNow()
  let got = storeReadInto(guid, k, value, error)
  perfAdd(PhaseStoreGet, tStore)
  if got != ReadOk:
    gLastError = error
    if got == ReadMissing:
      return ErrNotFound
    # Present and unreadable. Deliberately *not* `ErrNotFound`: a mod that
    # cannot tell the two apart answers "your profile is unreadable" by
    # creating a new character over the top of it, and that is the one failure
    # here nobody can undo. It is logged as well as returned, because the mod
    # that gets the status may be the one that decides to carry on regardless
    # and the player deserves to find out from somewhere.
    if got == ReadFailed:
      modhost.fail "store read failed: " & error
    return ErrGeneric
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
  let tStore = perfNow()
  let wrote = storeWrite(guid, k, v, error)
  perfAdd(PhaseStoreSet, tStore)
  if not wrote:
    gLastError = error
    return ErrGeneric
  # A successful write can still have something to say: the value is committed
  # but its history copy was not. The mod is not told -- nothing it does about
  # a save that worked would be right -- but the log is, because a store
  # running without the history the documentation promises should not be a
  # silent state.
  if error.len > 0:
    modhost.info "store: " & error
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
  let tStore = perfNow()
  var v = storeKeys(guid, p)
  perfAdd(PhaseStoreList, tStore)
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc patchFired(slot: int32; regs: HostPtr): int32 {.
    exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## Nothing here can fire: the backend refuses `patch` outright, having no
  ## compiled game code to detour. It exists because the shim declares the
  ## symbol unconditionally and the link needs one. Zero means "run the
  ## original", which is the only safe answer for a slot that cannot exist.
  result = 0'i32

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
  --db PATH     database JSON to load (default <root>/db.json)
  --once        serve until one request has been handled, then exit
  --perf        accumulate per-phase timings and print them at exit
  --selftest    serve, drive every route from inside this process, then exit
                with the result. One command, no orchestration.
  --store-flush force every store write to the medium before it is committed.
                Costs about 6 ms a write and protects against a power cut, not
                against a crash -- see docs/BACKEND.md.
  --no-store-lock
                start even if another backend already holds this store. Two
                servers writing one profile lose saves; this is an escape
                hatch, not an option.
  -h, --help    this
"""

proc main(): int =
  var root = ""
  var dbPath = ""
  var once = false
  var selftest = false
  var noLock = false
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
    elif a == "--perf":
      # Off by default, and one branch per call site when it is off. A
      # per-phase breakdown is the only way to tell the mod's own time from
      # the server's, and rebuilding the instrument every time somebody asks
      # is how the answer goes back to being a guess.
      perfEnable()
    elif a == "--selftest":
      selftest = true
    elif a == "--store-flush":
      # Force every store write to the medium before it is committed. Off by
      # default because it costs 3.9 ms of a 4.3 ms write and buys nothing
      # against a crash -- the rename is what makes a write all-or-nothing.
      # What it buys is the power-cut case: without it, a machine that loses
      # power can come back having lost the last write. It can never come back
      # with a half-written profile either way.
      storeFlushOnWrite(true)
    elif a == "--no-store-lock":
      # An escape hatch, and documented as one. If the claim below ever
      # refuses a store it should not have -- a filesystem that cannot do
      # delete-on-close, something exotic under a network path -- a player
      # should be able to start their server anyway rather than wait for a
      # fix. Running two backends on one store with it is still the data-loss
      # bug it was; nothing here makes that safe.
      noLock = true
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

  # One backend per store, claimed before a single mod is loaded -- a mod's
  # `on_load` may write, and a second server that gets as far as writing has
  # already done the damage. Refused rather than warned about: the failure it
  # prevents is two processes taking turns to undo each other's saves, which
  # shows up as progress that comes and goes and is diagnosed by nobody.
  if not noLock:
    var holder = ""
    var lockError = ""
    if not storeLock("backend", holder, lockError):
      console.err lockError
      if holder.len > 0:
        console.line "  held by " & strip(holder)
      console.line "  another aowlspt-backend is using " & storeRoot() & "."
      console.line "  Close it and try again (--no-store-lock overrides, and"
      console.line "  two servers writing one store lose saves)."
      modhost.fail lockError
      return 1

  # Everything a mod left in this host, dropped before its library is freed.
  # Order around it is the loader's guarantee: after the mod's `on_unload`,
  # before `FreeLibrary`. Anything missed here is a route still served, an
  # event still delivered or a timer still due -- each of them a call through a
  # function pointer into memory that has been unmapped.
  proc dropModRegistrations(index: int) =
    # Under the registration lock, for the reason the timer sweep below is
    # under the host lock and with more at stake: this rebinds two sequences
    # that every worker walks on every request, and rebinding one drops the
    # last reference to the buffer a worker may be halfway through. It ran
    # unlocked, and `aowl test` unloads a mod while the server is serving.
    cRegWrite()
    var keptRoutes: seq[Route] = @[]
    for r in gRoutes:
      if r.modIndex != index: keptRoutes.add r
    gRoutes = keptRoutes

    var keptSubs: seq[Sub] = @[]
    for sb in gSubs:
      if sb.modIndex != index: keptSubs.add sb
    gSubs = keptSubs
    cRegWriteEnd()

    # Under the lock: `hostSchedule` runs on whatever thread a route handler is
    # on, and may be appending while this walks.
    cLock()
    var keptTimers: seq[Timer] = @[]
    for t in gTimers:
      if t.modIndex != index: keptTimers.add t
    gTimers = keptTimers
    cUnlock()

  setModTeardown(dropModRegistrations)

  # What `modcontrol` is allowed to know and do here. Deliberately narrow: it
  # gets no access to the mod table, only these answers about it.
  #
  # Installed **before** the mods are loaded, not after. The manager probes for
  # a host from its own `on_load`, so a controller that starts afterwards is a
  # controller that misses the only question it was ever asked -- and the
  # manager then spends the session reporting "no host answered the control
  # probe". Queueing before any mod exists is safe: nothing is performed until
  # the serve loop drains.
  proc opsCount(): int = modhost.modCount()
  proc opsGuid(i: int): string = modhost.modGuidOf(i)
  proc opsName(i: int): string = modhost.modNameOf(i)
  proc opsVersion(i: int): string = modhost.modVersionOf(i)
  proc opsPath(i: int): string = modhost.modPathOf(i)
  proc opsLive(i: int): bool = modhost.modIsLive(i)
  proc opsFlags(i: int): uint32 = modhost.modFlagsOf(i)
  proc opsIndex(guid: string): int = modhost.modIndexOf(guid)
  proc opsCanUnload(ignored: int): bool = modhost.hasTeardown()
  proc opsLoad(path: string): bool =
    modhost.loadOne(path, SideServer, HostName, HostVersion)
  proc opsUnload(guid: string): string =
    var err = ""
    if modhost.unloadByGuid(guid, err):
      return ""
    result = (if err.len > 0: err else: "the host refused to unload it")
  proc opsLog(msg: string) = modhost.info msg

  modcontrol.controlInit(HostName, HostVersion, SideServer, hostEmit,
                         HostOps(count: opsCount, guidOf: opsGuid,
                                 nameOf: opsName, versionOf: opsVersion,
                                 pathOf: opsPath, liveOf: opsLive,
                                 flagsOf: opsFlags, indexOf: opsIndex,
                                 canUnload: opsCanUnload, load: opsLoad,
                                 unload: opsUnload, log: opsLog))

  # The one entry `aowl_hostapi_new` cannot fill, through the mechanism the
  # IL2CPP host already uses for the two *it* fills. See `aowlspt_notify.h` for
  # why arming revision 5 also means filling revisions 3 and 4 with the refusal
  # they already owed.
  setHostBlockArm(cArmNotify)

  # And the three calls `websocket.nim` cannot make for itself. Before the
  # server starts, so no connection can arrive at a handshake that has nowhere
  # to write its answer.
  websocket.wsBind(wsRawSend, wsFrameSend, wsAdopt)

  let modsDir = joinPath(gRoot, "mods")
  let count = loadAll(modsDir, SideServer, HostName, HostVersion)
  console.line "  mods  " & $count
  console.line "  routes " & $gRoutes.len

  # Sixteen *request* workers, which is a different thing from what this
  # number used to be.
  #
  # It used to be the connection limit: a worker took a connection at `accept`
  # and stayed with it until the client let go, so sixteen open sockets were
  # sixteen occupied threads whether or not any of them ever asked for
  # anything. That is what made a handful of stalled connections a denial of
  # service, and no value of this number fixes it -- eight was starved by
  # twelve, sixteen would be starved by twenty, and the attacker picks.
  #
  # A worker now takes a *complete request*, answers it, and gives the
  # connection back. Connections are held by the poller, which does not have a
  # thread each; the limit on them is `AOWL_NET_MAX_CONNS` (1024) and
  # `AOWL_NET_MAX_BUFFERED` (64 MiB), both in `aowlspt_net.h`. So this is the
  # concurrency limit on doing work, which is the only thing a thread was ever
  # needed for.
  if cNetServe(int32(gPort), 16'i32) == 0'i32:
    # A port collision is the ordinary way this fails, and it deserves to be
    # said in those words rather than as a number. It is what happens when the
    # last backend has not quite exited, when SPT's own server is up, and on
    # any machine running two stages at once -- and the alternative to naming
    # it is a tool somewhere else reporting a connect timeout, which sends
    # whoever reads it looking in the wrong place.
    let e = int(cNetLastError())
    if e == WsaAddrInUse or e == WsaAccess:
      console.err "port " & $gPort & " is already in use"
      console.line "  another server -- an earlier aowlspt-backend, or SPT's" &
                   " own -- already holds"
      console.line "  127.0.0.1:" & $gPort & ". Close it, or start this one" &
                   " with --port."
      modhost.fail "port " & $gPort & " is already in use"
    else:
      console.err "could not listen on port " & $gPort & " (error " & $e & ")"
      modhost.fail "could not listen on " & $gPort & " (error " & $e & ")"
    return 1
  # Written only now, and only from the bind's own result.
  #
  # It reads like a log line and it is an interface: `allmods`, `fuzzwire`,
  # `livectl`, `soak`, `wstest` and `aowlspt-verify` all decide the server is
  # up by finding `listening` in this file. It used to be able to appear after
  # a bind that had quietly attached to somebody else's port -- see
  # `SO_EXCLUSIVEADDRUSE` in `aowlspt_net.h` -- and every one of those tools
  # then waited on a server that was never going to answer them.
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

  # `--perf` writes its breakdown to a file rather than only to stdout,
  # because a load generator kills this process rather than asking it to stop
  # -- a report printed at exit is a report nobody ever sees.
  proc perfDump() =
    if not perfOn():
      return
    var text = "aowlspt-backend per-phase timings\n\n"
    let rows = perfReport(gRequests())
    for l in rows:
      text.add l
      text.add "\n"
    text.add perfCacheLine(gZHits, gZMisses, gZSkipped)
    text.add "\n"
    discard writeTextFile(joinPath(gRoot, "perf.txt"), text)

  var lastPerf = elapsedMs()
  var lastTick = elapsedMs()
  while cNetRunning() != 0'i32:
    cSysSleep(50'i32)
    let now = elapsedMs()
    tickMods(now - lastTick)
    runTimers()
    # Live mod control, off the emitting stack. This is the only place a mod is
    # loaded or unloaded while the server is running.
    modcontrol.drain()
    lastTick = now
    if perfOn() and now - lastPerf >= 1000'i64:
      perfDump()
      lastPerf = now
    if once and gRequests() > 0:
      # One request then stop: how the test harness drives it.
      cSysSleep(200'i32)
      break

  cNetStop()
  unloadMods()
  # The store keeps a handle open per file it has touched. Nothing breaks if
  # they are left to the process teardown, but a server that has stopped should
  # not still be holding a player's profile open.
  storeClose()
  storeUnlock()
  modhost.okLog "stopped after " & $gRequests() & " requests"
  console.line ""
  console.line "  stopped after " & $gRequests() & " requests"
  perfDump()
  let finalRows = perfReport(gRequests())
  for l in finalRows:
    console.line l
  result = 0

quit(main())
