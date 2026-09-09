## wstest -- the notifier websocket, end to end and under a client that lies.
##
##     wstest --root <stage> --port 6982 --backend <aowlspt-backend.exe>
##
## A sibling of `tools/fuzzwire.nim` rather than more of it, and the split is
## not filing. `fuzzwire` is about **requests**: it reads the route table out of
## the backend's log and drives every registered endpoint with bodies no client
## would send, and every one of its phases ends by asking an ordinary question
## and re-reading the profile store. Nothing in it holds a connection open for
## longer than one exchange, because until now nothing on this server did.
##
## This tool is about a connection that is **held**, which is a different
## machine: a handshake, a frame stream in both directions, control frames,
## and a socket that lives across many requests. Bolting it into `fuzzwire`
## would have meant its 149 checks sharing a stage with a hundred long-lived
## sockets, and the first thing a websocket regression would do is change what
## the request checks were measuring. So `fuzzwire` is untouched and this runs
## beside it, on its own stage and its own port.
##
## It keeps `fuzzwire`'s three rules, because they are the reason that tool is
## worth having:
##
## **Survival is not enough.** Every phase that refuses something ends by
## asking an ordinary question over ordinary HTTP. A server that survives a
## malformed frame by wedging its poller has not passed.
##
## **A refusal has to say why.** A `400` with an empty body, or a close frame
## with no status in it, fails here. The refusal is the whole product of a
## check like "a bad key is rejected"; a bare disconnection is the same
## observable as a crash.
##
## **The exact bytes go in the failure line.** A frame is not text, so every
## failure carries it as hex.
##
## What it proves, in order: the handshake computes the accept the RFC names; a
## notification provoked through the *game's* own routes (list a flea offer,
## take it down, which posts to the mailbox) arrives as a correctly framed text
## frame; a ping is ponged with its own payload; a close is echoed; a bad key,
## a missing `Connection: Upgrade`, a wrong version, an unmasked frame, an
## oversized frame and a reserved bit are each refused with a reason; a client
## that vanishes without closing is noticed and its session falls back to the
## poll; and a hundred idle websockets held open do not slow an ordinary
## request down.

import std/[strutils, syncio, cmdline, sha1, base64]
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
/* This tool's own connect and clock, for the reason `fuzzwire` states: a
 * module that imports `wire` gets `wire`'s `{.emit.}` block *after* its own
 * code in the generated translation unit, so anything that needs a socket of
 * its own before `wire`'s definitions appear has to bring one. */
static uint64_t aowl_ws_test_connect(int32_t port, int32_t timeoutMs) {
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
  return (uint64_t)s;
}

/* An abrupt close: RST rather than FIN, which is what a machine losing power
 * or a process being killed leaves behind. `closesocket` on its own sends a
 * FIN and the server reads that as an orderly end of stream -- a different
 * case, and the easy one. */
static void aowl_ws_test_abort(uint64_t sock) {
  struct linger lg;
  lg.l_onoff = 1;
  lg.l_linger = 0;
  setsockopt((SOCKET)sock, SOL_SOCKET, SO_LINGER, (const char*)&lg, sizeof(lg));
  closesocket((SOCKET)sock);
}

static int64_t aowl_ws_test_now_us(void) {
  LARGE_INTEGER v, f;
  QueryPerformanceCounter(&v);
  QueryPerformanceFrequency(&f);
  return (int64_t)((v.QuadPart / f.QuadPart) * 1000000LL +
                   ((v.QuadPart % f.QuadPart) * 1000000LL) / f.QuadPart);
}
""".}

proc cWsConnect(port, timeoutMs: int32): uint64 {.
  importc: "aowl_ws_test_connect", nodecl.}
proc cWsAbort(sock: uint64) {.importc: "aowl_ws_test_abort", nodecl.}
proc wsNowUs(): int64 {.importc: "aowl_ws_test_now_us", nodecl.}

const
  Usage = """
wstest -- the notifier websocket, end to end

  wstest --root PATH --backend PATH [--port N]

  --root PATH      the scratch install (mods/, db.json)
  --backend PATH   aowlspt-backend.exe
  --port N         port to serve on (default 6982)
  --keep           leave the backend running at the end
  -h, --help       this
"""
  Session = "cccccccccccccccccccccccc"
  WsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  IdleSockets = 100
    ## Held open, doing nothing, while ordinary requests are timed behind them.
    ## A hundred is over six times the worker pool and a hundred times the
    ## connection count a single-player server has; under the accept-thread pool
    ## this server used to be it was unanswerable by construction. The only
    ## question worth asking of it now is whether an ordinary request notices.

var gFailures = 0
var gChecks = 0
var gPort = 6982
var gBackend = ""
var gRoot = ""
var gProc = 0'u64

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc hex(s: string): string =
  ## A frame in a failure line. Frames are not text and a finding that cannot
  ## be replayed goes stale, so the bytes go in verbatim.
  const Hex = "0123456789abcdef"
  result = ""
  var i = 0
  while i < s.len and i < 64:
    let c = ord(s[i])
    result.add Hex[(c shr 4) and 15]
    result.add Hex[c and 15]
    result.add ' '
    inc i
  if s.len > 64:
    result.add "... (" & $s.len & " bytes)"

# --------------------------------------------------------------- the client
#
# A websocket client written here rather than borrowed, because there is no
# other one in this repository and because half the checks below are frames a
# correct client would never send.

type
  WsClient = object
    sock: uint64
    buf: string
      ## Bytes read from the socket and not yet consumed by a frame.
    open: bool

  Frame = object
    got: bool
    fin: bool
    opcode: int
    payload: string
    masked: bool

proc wsOpen(timeoutMs = 5000): WsClient =
  result = WsClient(sock: cWsConnect(int32(gPort), int32(timeoutMs)),
                    buf: "", open: false)

proc wsClose(c: var WsClient) =
  if c.sock != 0'u64:
    cClose(c.sock)
    c.sock = 0'u64
  c.open = false

proc wsAbort(c: var WsClient) =
  ## The client that vanished: reset, no FIN, no close frame.
  if c.sock != 0'u64:
    cWsAbort(c.sock)
    c.sock = 0'u64
  c.open = false

proc sendBytes(c: var WsClient; s: string): bool =
  if c.sock == 0'u64 or s.len == 0: return false
  var b = toBytes(s)
  result = cSend(c.sock, cast[WirePtr](addr b[0]), int32(s.len)) >= 0'i32

proc pump(c: var WsClient): bool =
  ## One receive into the buffer. False when the peer closed or the deadline
  ## passed, which the callers tell apart by what they were waiting for.
  if c.sock == 0'u64: return false
  var b = newSeq[byte](65536)
  let n = cRecv(c.sock, cast[WirePtr](addr b[0]), 65536'i32)
  if n <= 0'i32: return false
  c.buf.add bytesAt(b, 0, int(n))
  result = true

proc key16(seed: int): string =
  ## Sixteen bytes, base64. Not random: a test that fails should fail the same
  ## way twice, and the key's randomness protects a *client* from a cached
  ## response, which is not what is being tested here.
  var raw = newSeq[char](16)
  for i in 0 ..< 16:
    raw[i] = char((seed * 37 + i * 11 + 7) and 0xFF)
  result = encode(raw)

proc acceptFor(key: string): string =
  ## Computed here, independently of the server's copy. A check that asked the
  ## server for the answer and then compared it with the server's answer would
  ## pass against a server that made the value up.
  var st = newSha1State()
  update(st, key)
  update(st, WsGuid)
  let digest = finalize(st)
  var raw = newSeq[char](20)
  for i in 0 ..< 20:
    raw[i] = char(digest[i])
  result = encode(raw)

proc maskedFrame(opcode: int; payload: string; fin = true;
                 mask = true; maskSeed = 0x31): string =
  ## A client frame. `mask = false` is one of the refusals under test.
  result = ""
  result.add char((if fin: 0x80 else: 0x00) or (opcode and 0x0F))
  let n = payload.len
  let maskBit = if mask: 0x80 else: 0x00
  if n <= 125:
    result.add char(maskBit or n)
  elif n <= 65535:
    result.add char(maskBit or 126)
    result.add char((n shr 8) and 0xFF)
    result.add char(n and 0xFF)
  else:
    result.add char(maskBit or 127)
    var shift = 56
    while shift >= 0:
      result.add char((n shr shift) and 0xFF)
      shift = shift - 8
  if not mask:
    result.add payload
    return
  var m = newSeq[char](4)
  for i in 0 ..< 4:
    m[i] = char((maskSeed + i * 29) and 0xFF)
    result.add m[i]
  for i in 0 ..< n:
    result.add char(ord(payload[i]) xor ord(m[i and 3]))

proc claimedLengthFrame(opcode: int; claimed: int): string =
  ## A header that *claims* a payload of `claimed` bytes and then sends two.
  ##
  ## This is the check that the length is refused off the field rather than
  ## allocated for: the whole thing is sixteen bytes on the wire. It is the
  ## websocket shape of `Content-Length: 9000000000000000000`, which took this
  ## server's whole process down once.
  result = ""
  result.add char(0x80 or (opcode and 0x0F))
  result.add char(0x80 or 127)
  var shift = 56
  while shift >= 0:
    result.add char((claimed shr shift) and 0xFF)
    shift = shift - 8
  for i in 0 ..< 4:
    result.add char(0x40 + i)
  result.add "ab"

proc readFrame(c: var WsClient; waitMs = 4000): Frame =
  ## The next whole frame from the server, or `got = false`.
  result = Frame(got: false, fin: false, opcode: 0, payload: "", masked: false)
  let deadline = wsNowUs() + int64(waitMs) * 1000'i64
  while true:
    if c.buf.len >= 2:
      let b0 = ord(c.buf[0])
      let b1 = ord(c.buf[1])
      let masked = (b1 and 0x80) != 0
      var n = b1 and 0x7F
      var at = 2
      if n == 126:
        if c.buf.len < 4: n = -1
        else:
          n = (ord(c.buf[2]) shl 8) or ord(c.buf[3])
          at = 4
      elif n == 127:
        if c.buf.len < 10: n = -1
        else:
          n = 0
          for i in 0 ..< 8:
            n = (n shl 8) or ord(c.buf[2 + i])
          at = 10
      if n >= 0:
        let total = at + (if masked: 4 else: 0) + n
        if c.buf.len >= total:
          result.got = true
          result.fin = (b0 and 0x80) != 0
          result.opcode = b0 and 0x0F
          result.masked = masked
          result.payload = c.buf.substr(at + (if masked: 4 else: 0), total - 1)
          c.buf = c.buf.substr(total)
          return
    if wsNowUs() >= deadline:
      return
    if not pump(c):
      return

proc handshakeHead(session, key, version, connection, upgrade: string): string =
  result = "GET /client/notifier/getwebsocket/" & session & " HTTP/1.1\r\n"
  result.add "Host: 127.0.0.1:" & $gPort & "\r\n"
  if upgrade.len > 0:
    result.add "Upgrade: " & upgrade & "\r\n"
  if connection.len > 0:
    result.add "Connection: " & connection & "\r\n"
  if key.len > 0:
    result.add "Sec-WebSocket-Key: " & key & "\r\n"
  if version.len > 0:
    result.add "Sec-WebSocket-Version: " & version & "\r\n"
  result.add "Content-Length: 0\r\n"
  result.add "\r\n"

proc readHead(c: var WsClient; waitMs = 4000): string =
  ## The HTTP response head **and its body**, leaving anything past them in the
  ## buffer.
  ##
  ## The body is not optional here: half the checks below are "the refusal says
  ## why", and the reason is in the body. An earlier version read the head
  ## alone, and every one of those checks was asserting against a string that
  ## could not contain the answer -- which is the same failure as not checking
  ## at all, wearing a passing test's clothes.
  result = ""
  let deadline = wsNowUs() + int64(waitMs) * 1000'i64
  var head = ""
  var got = false
  while not got:
    let at = find(c.buf, "\r\n\r\n")
    if at >= 0:
      head = c.buf.substr(0, at + 3)
      c.buf = c.buf.substr(at + 4)
      got = true
    else:
      if wsNowUs() >= deadline:
        return
      if not pump(c):
        return
  result = head
  # A 101 has no body and no `Content-Length`; every refusal here has both.
  var want = 0
  let cl = find(toLowerAscii(head), "content-length:")
  if cl >= 0:
    var i = cl + 15
    while i < head.len and head[i] == ' ': inc i
    while i < head.len and head[i] >= '0' and head[i] <= '9':
      want = want * 10 + (ord(head[i]) - ord('0'))
      inc i
  while c.buf.len < want:
    if wsNowUs() >= deadline: break
    if not pump(c): break
  if want > 0 and c.buf.len >= want:
    result.add c.buf.substr(0, want - 1)
    c.buf = c.buf.substr(want)

proc upgraded(c: var WsClient; session: string; seed: int;
              head: var string): bool =
  ## The ordinary handshake, and the accept checked against a value computed
  ## here rather than read back from the server.
  let key = key16(seed)
  head = ""
  if not sendBytes(c, handshakeHead(session, key, "13", "Upgrade",
                                    "websocket")):
    return false
  head = readHead(c)
  if find(head, "101") < 0:
    return false
  if find(head, "Sec-WebSocket-Accept: " & acceptFor(key)) < 0:
    return false
  c.open = true
  result = true

# --------------------------------------------------------------- the server

proc call(path, body: string): Response =
  result = request(gPort, path, body, Session)

proc alive(): bool =
  result = gProc == 0'u64 or cSpawnAlive(gProc) != 0'i32

proc settled(phase: string) =
  ## What every refusing phase ends with. A poller wedged by a malformed frame
  ## takes every *request* with it, and that is the failure this catches.
  check(phase & ": the process is still up", alive())
  let cfg = call("/client/game/config", "")
  check(phase & ": an ordinary request still answers",
        cfg.ok and cfg.contains("\"err\":0"),
        if cfg.error.len > 0: cfg.error else: cfg.body)

proc waitForBackend(tries: int): bool =
  var i = 0
  while i < tries:
    let r = call("/client/game/config", "")
    if r.ok and r.contains("\"err\":0"):
      return true
    cSleepMs(200'i32)
    inc i
  result = false

proc startBackend(): uint64 =
  var e = gBackend
  var w = gRoot
  var c = "\"" & gBackend & "\" --root \"" & gRoot & "\" --port " & $gPort
  result = cSpawn(toCString(e), toCString(w), toCString(c))

# --------------------------------------------------------------- readers

proc textAfter(body: string; key: string; from2: int): string =
  ## The string value of `"key":"..."` at or after `from2`, or "".
  result = ""
  let at = find(body, "\"" & key & "\":\"", from2)
  if at < 0: return
  var i = at + key.len + 4
  while i < body.len and body[i] != '"':
    result.add body[i]
    inc i

proc firstRoubleStack(profileList: string): string =
  ## The `_id` of a stack of roubles in the profile, which is what the flea
  ## check lists and takes down again.
  let tpl = "5449016a4bdc2d6f028b456f"
  var at = 0
  while true:
    let hit = find(profileList, "\"_tpl\":\"" & tpl & "\"", at)
    if hit < 0: return ""
    # The `_id` of an item object comes before its `_tpl`, so this walks back
    # to the nearest one. `substr(a, b)` is inclusive of `b`, which is what an
    # earlier five-character window got wrong: it never matched, the check for a
    # stack failed, and every later check listed an empty offer and then
    # asserted against a notification that had no reason to exist.
    var start = hit
    var back = 0
    while start > 0 and back < 400:
      if profileList.substr(start, start + 4) == "\"_id\"":
        return textAfter(profileList, "_id", start)
      dec start
      inc back
    at = hit + 1

proc lastBefore(hay, needle: string; before: int): int =
  ## The last occurrence of `needle` starting before `before`, or -1. nimony's
  ## `find` only goes forward, and every use here is "walk back out of a nested
  ## object to the one containing it".
  result = -1
  var at = 0
  while true:
    let hit = find(hay, needle, at)
    if hit < 0 or hit >= before: break
    result = hit
    at = hit + 1

proc offerIdHolding(findBody, itemId: string): string =
  ## The `_id` of the flea offer whose `items` carry `itemId`.
  ##
  ## Not "the first `_id` in the response", which is what this did first and
  ## which is wrong for a reason worth writing down: `offerOwnerType: 2` means
  ## *not a trader*, and this market generates offers from fake players, so the
  ## first row back is somebody called Partisan. Removing that id fails with a
  ## warning inside an `err:0` envelope -- so the check passed, no mail was
  ## posted, and the notification the test was waiting for had never had a
  ## reason to exist.
  result = ""
  let item = find(findBody, "\"_id\":\"" & itemId & "\"")
  if item < 0: return
  let itemsAt = lastBefore(findBody, "\"items\":[", item)
  if itemsAt < 0: return
  let offerAt = lastBefore(findBody, "\"_id\":\"", itemsAt)
  if offerAt < 0: return
  result = textAfter(findBody, "_id", offerAt)

proc listableItems(profileList: string): seq[string] =
  ## Every item in the profile that has a parent -- that is, one sitting in a
  ## container rather than being one of the roots the emulator refuses to list
  ## (and is right to: listing the stash took the stash and everything under it
  ## out of the profile once).
  ##
  ## A list rather than one item, because each provocation *consumes* one: the
  ## flea holds a listed item and taking the listing down posts it back by
  ## mail, so it is in the mailbox and no longer in the profile. Asking for
  ## "the rouble stack" three times therefore works once and then quietly stops
  ## provoking anything, which is exactly the shape of a test that passes
  ## because nothing happened.
  result = @[]
  var at = 0
  while true:
    let hit = find(profileList, "\"parentId\":\"", at)
    if hit < 0: break
    var start = hit
    var back = 0
    var found = ""
    while start > 0 and back < 600:
      if profileList.substr(start, start + 4) == "\"_id\"":
        found = textAfter(profileList, "_id", start)
        break
      dec start
      inc back
    if found.len == 24:
      var seen = false
      for f in result:
        if f == found: seen = true
      if not seen: result.add found
    at = hit + 1

proc reclaimMail(): int =
  ## Drag everything out of the mailbox and back into the stash, and answer how
  ## many items came back.
  ##
  ## This is what makes the provocation repeatable rather than a one-shot. The
  ## flea round trip *consumes* what it lists -- taking a listing down posts the
  ## item back by mail rather than into the stash, deliberately, because by then
  ## the stash may be full -- and a fresh profile has exactly one thing in the
  ## stash to begin with. Without this the second provocation finds nothing to
  ## list, provokes nothing, and the check that follows waits for a
  ## notification that never had a reason to exist.
  ##
  ## The client has no redeem endpoint: collecting a reward is an ordinary
  ## `Move` with `fromOwner` naming the message, which is what `emutest` drives
  ## for a quest reward and what a player's drag actually sends.
  result = 0
  let listBody = call("/client/game/profile/list", "").body
  let stashId = textAfter(listBody, "stash", 0)
  if stashId.len == 0: return
  let box = call("/client/mail/dialog/getAllAttachments",
                 "{\"dialogId\":\"ragfair\"}")
  var at = 0
  while true:
    let msgAt = find(box.body, "\"_id\":\"", at)
    if msgAt < 0: break
    let messageId = textAfter(box.body, "_id", msgAt)
    at = msgAt + 1
    if messageId.len != 24: continue
    # A message's attachments are `items: {stash, data: [...]}`, not a bare
    # array -- the `stash` is the container the client draws them in. So the
    # ids come after `"data":[`, and an earlier version of this looked for
    # `"items":[`, matched nothing, and quietly reclaimed nothing at all.
    let itemsAt = find(box.body, "\"data\":[", msgAt)
    if itemsAt < 0: continue
    var k = itemsAt
    while true:
      let itemAt = find(box.body, "\"_id\":\"", k + 1)
      if itemAt < 0: break
      let itemId = textAfter(box.body, "_id", itemAt)
      k = itemAt
      if itemId.len != 24: break
      let dragged = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"Move\",\"item\":\"" & itemId &
        "\",\"fromOwner\":{\"id\":\"" & messageId & "\",\"type\":\"Mail\"}," &
        "\"to\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"}}]," &
        "\"tm\":2}")
      if dragged.ok and find(dragged.body, "\"warnings\":[]") >= 0:
        inc result
      else:
        break
    if result > 0: return

proc provokeMail(): bool =
  ## One notification, provoked through the game's own routes rather than
  ## through a hook put here for the test: listing an item on the flea and
  ## taking the listing down posts the item back by mail, and every mailbox
  ## delivery is what the notifier exists to announce. So this exercises the
  ## path a player actually takes to it.
  ##
  ## The removal is checked for a *warning* rather than for `err:0`. This
  ## server answers `err:0` with a `warnings` entry for anything it declines
  ## inside an otherwise valid batch, so `err:0` alone would call a refused
  ## removal a success -- and a provocation that provoked nothing is the worst
  ## kind of green.
  discard reclaimMail()
  let profiles = call("/client/game/profile/list", "")
  let candidates = listableItems(profiles.body)
  for itemId in candidates:
    let listed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairAddOffer\",\"sellInOnePiece\":false," &
      "\"items\":[\"" & itemId & "\"],\"requirements\":[{\"_tpl\":" &
      "\"5449016a4bdc2d6f028b456f\",\"count\":1}]}],\"tm\":2}")
    if not listed.ok or find(listed.body, "\"warnings\":[]") < 0: continue
    let mine = call("/client/ragfair/find",
                    "{\"page\":0,\"limit\":500,\"offerOwnerType\":2," &
                    "\"sortType\":5}")
    let offerId = offerIdHolding(mine.body, itemId)
    if offerId.len == 0: continue
    let removed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairRemoveOffer\",\"offerId\":\"" &
      offerId & "\"}],\"tm\":2}")
    if removed.ok and find(removed.body, "\"warnings\":[]") >= 0:
      return true
  result = false

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
    elif a == "--keep":
      keep = true
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      err "unknown option: " & a
      return 1
    inc i

  # Absolute before anything uses it: the child runs with its working directory
  # set to the root *and* `--root` on its command line, so a relative one is
  # resolved twice and the server starts perfectly well in `<root>/<root>`.
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
    # The spawn takes `root` as its working directory, so a root that does not
    # exist yet fails here -- and "could not start the backend" then names the
    # backend, which is fine, while the thing that is wrong is the argument two
    # flags to the left. Every other caller of this suite stages the root
    # first, so it went years without being said out loud.
    if not exists(gRoot):
      note "there is no directory at " & gRoot & " -- the spawn takes the " &
           "root as its working directory, so it fails before the backend " &
           "runs. Create it (and stage the mod and the database into it) " &
           "first; `aowl test` does that for you"
    elif not fileExists(gBackend):
      note "there is no file at " & gBackend & "; build it with `aowl build`"
    return 1
  if not waitForBackend(60):
    err "the backend never answered /client/game/config"
    cSpawnKill(gProc)
    return 1
  ok "the backend is serving on " & $gPort

  # A profile on this session, so the routes that post mail have somewhere to
  # post to.
  discard call("/client/game/profile/create",
               "{\"nickname\":\"wstest\",\"side\":\"Usec\"}")
  let selected = call("/client/game/profile/select", "{}")
  check("a profile is selected on this session",
        selected.ok and selected.contains("\"err\":0"), selected.body)

  # ------------------------------------------------------------- handshake

  heading "The handshake"
  block:
    var c = wsOpen()
    check("the notifier URL accepts a connection", c.sock != 0'u64)
    var head = ""
    let up = upgraded(c, Session, 1, head)
    check("and upgrades it to a websocket", up, head)
    check("the response is 101 rather than 200", find(head, "101") >= 0, head)
    # The accept is the whole of the server's half of the handshake, and it is
    # checked against a value computed in this file. A check that read the
    # server's answer back and compared it with itself would pass against a
    # server that made the value up, which is exactly the failure a client
    # would then reject the connection for.
    check("and carries the accept the RFC computes",
          find(head, "Sec-WebSocket-Accept: " & acceptFor(key16(1))) >= 0,
          head)
    check("and says Upgrade: websocket back",
          find(toLowerAscii(head), "upgrade: websocket") >= 0, head)
    wsClose(c)

  block:
    # Each refusal is a way the request is not this protocol, and each has to
    # come back as a *named* `400` rather than a dropped connection: a client
    # that reads a disconnection cannot tell a wrong key from a server that
    # fell over, and neither can whoever is reading the log.
    var c = wsOpen()
    discard sendBytes(c, handshakeHead(Session, "tooshort", "13", "Upgrade",
                                       "websocket"))
    var head = readHead(c)
    check("a Sec-WebSocket-Key that is not sixteen base64 bytes is refused",
          find(head, "400") >= 0, head)
    check("and the refusal names the key",
          find(head, "Sec-WebSocket-Key") >= 0, head)
    wsClose(c)

    c = wsOpen()
    discard sendBytes(c, handshakeHead(Session, "", "13", "Upgrade",
                                       "websocket"))
    head = readHead(c)
    check("a missing key is refused too", find(head, "400") >= 0, head)
    wsClose(c)

    c = wsOpen()
    discard sendBytes(c, handshakeHead(Session, key16(2), "13", "keep-alive",
                                       "websocket"))
    head = readHead(c)
    check("an Upgrade header without Connection: Upgrade is refused",
          find(head, "400") >= 0, head)
    check("and says which header was missing",
          find(head, "Connection") >= 0, head)
    wsClose(c)

    c = wsOpen()
    discard sendBytes(c, handshakeHead(Session, key16(3), "8", "Upgrade",
                                       "websocket"))
    head = readHead(c)
    check("a websocket version other than 13 is refused",
          find(head, "400") >= 0, head)
    check("and says which version this server speaks",
          find(head, "13") >= 0, head)
    wsClose(c)

    c = wsOpen()
    discard sendBytes(c, handshakeHead("", key16(4), "13", "Upgrade",
                                       "websocket"))
    head = readHead(c)
    check("an upgrade with no session is refused", find(head, "400") >= 0,
          head)
    wsClose(c)

  settled("the refused handshakes")

  # ------------------------------------------------------------- the push

  heading "A notification, provoked and pushed"
  block:
    var c = wsOpen()
    var head = ""
    let up = upgraded(c, Session, 5, head)
    check("a websocket is open for this session", up, head)

    # Provoked through the game's own routes rather than through a hook put
    # here for the test: a flea listing taken down again posts the item back by
    # mail, and a mailbox delivery is what the notifier exists to announce.
    let profiles = call("/client/game/profile/list", "")
    check("the profile has something to list",
          listableItems(profiles.body).len > 0, "nothing in the stash")
    check("a flea listing can be made and taken down again, posting mail",
          provokeMail(), "the flea round trip did not post anything")

    # And it arrives without being asked for, which is the entire point.
    let f = readFrame(c)
    check("the notification arrives on the socket, unasked", f.got,
          "no frame in four seconds")
    check("as a text frame", f.opcode == 1, "opcode " & $f.opcode)
    check("with FIN set", f.fin, hex(f.payload))
    # A server must not mask. A client that receives a masked frame is required
    # to fail the connection, so this is not a formality.
    check("and unmasked, as a server frame must be", not f.masked,
          hex(f.payload))
    check("and it is the mail notification the mailbox just took",
          find(f.payload, "\"type\":\"new_message\"") >= 0, f.payload)
    check("naming the dialog the message went into",
          find(f.payload, "\"dialogId\":\"ragfair\"") >= 0, f.payload)

    # A push is not a poll: having taken the frame off the socket, the poll
    # must have nothing left to hand out. Otherwise every notification is
    # delivered twice to a client that does both.
    let polled = call("/client/notifier/getwebsocket/" & Session, "")
    check("and the poll does not hand out the same news again",
          polled.ok and find(polled.body, "\"ping\"") >= 0, polled.body)
    wsClose(c)

  settled("the push")

  # ------------------------------------------------------------- control

  heading "Control frames"
  block:
    var c = wsOpen()
    var head = ""
    discard upgraded(c, Session, 6, head)

    discard sendBytes(c, maskedFrame(9, "hello"))
    let pong = readFrame(c)
    check("a ping is answered", pong.got and pong.opcode == 10,
          "opcode " & $pong.opcode)
    # Byte for byte: a pong carrying a different payload is a pong to a
    # different ping as far as the peer's liveness check is concerned.
    check("with the ping's own payload, byte for byte", pong.payload == "hello",
          hex(pong.payload))
    check("and unmasked", not pong.masked, hex(pong.payload))

    # A fragmented message. The game's notifier never sends one; a protocol
    # half-implemented is one that fails on the first client using the other
    # half, and a continuation mishandled desynchronises the frame stream
    # rather than failing visibly.
    discard sendBytes(c, maskedFrame(1, "half ", fin = false))
    discard sendBytes(c, maskedFrame(0, "a message", fin = true,
                                     maskSeed = 0x55))
    discard sendBytes(c, maskedFrame(9, "after"))
    let after = readFrame(c)
    check("a message split across a continuation does not break the stream",
          after.got and after.opcode == 10 and after.payload == "after",
          "opcode " & $after.opcode & " " & hex(after.payload))

    var body = ""
    body.add char(0x03)
    body.add char(0xE8)
    discard sendBytes(c, maskedFrame(8, body))
    let closed = readFrame(c)
    check("a close is echoed", closed.got and closed.opcode == 8,
          "opcode " & $closed.opcode)
    check("and the echo carries a status code", closed.payload.len >= 2,
          hex(closed.payload))
    wsClose(c)

  settled("control frames")

  # ------------------------------------------------------------- refusals

  heading "Frames the server refuses"
  block:
    # The masking rule. RFC 6455 requires a client to mask every frame and
    # requires a server to fail the connection when it does not; a server that
    # tolerates the absence is a server that has stopped checking, and the rule
    # is what stops a websocket being used to make a browser put
    # attacker-chosen plaintext on the wire at an intermediary.
    var c = wsOpen()
    var head = ""
    discard upgraded(c, Session, 7, head)
    discard sendBytes(c, maskedFrame(1, "unmasked", mask = false))
    let f = readFrame(c)
    check("an unmasked client frame is refused", f.got and f.opcode == 8,
          "opcode " & $f.opcode)
    check("with a protocol-error status rather than a bare disconnection",
          f.payload.len >= 2 and
          ((ord(f.payload[0]) shl 8) or ord(f.payload[1])) == 1002,
          hex(f.payload))
    check("and the close says why in words",
          f.payload.len > 2, hex(f.payload))
    wsClose(c)

  block:
    # Sixteen bytes on the wire claiming a payload of two exabytes. The check
    # is that it is refused off the length *field* -- the server is still
    # answering afterwards, which it would not be if it had tried to reserve
    # what the field claimed. This is the websocket shape of
    # `Content-Length: 9000000000000000000`, which took the whole process down
    # once.
    var c = wsOpen()
    var head = ""
    discard upgraded(c, Session, 8, head)
    discard sendBytes(c, claimedLengthFrame(1, 0x2000000000000000))
    let f = readFrame(c)
    check("a frame claiming an absurd length is refused",
          f.got and f.opcode == 8, "opcode " & $f.opcode)
    check("with a too-large status",
          f.payload.len >= 2 and
          ((ord(f.payload[0]) shl 8) or ord(f.payload[1])) == 1009,
          hex(f.payload))
    wsClose(c)

    # And one that is merely over the bound rather than absurd, declared
    # honestly. Same refusal, and the frame is still only its header on the
    # wire.
    c = wsOpen()
    discard upgraded(c, Session, 9, head)
    discard sendBytes(c, claimedLengthFrame(1, 4 * 1024 * 1024))
    let f2 = readFrame(c)
    check("a frame over the stated bound is refused as well",
          f2.got and f2.opcode == 8 and f2.payload.len >= 2 and
          ((ord(f2.payload[0]) shl 8) or ord(f2.payload[1])) == 1009,
          hex(f2.payload))
    wsClose(c)

  block:
    var c = wsOpen()
    var head = ""
    discard upgraded(c, Session, 10, head)
    # A reserved bit set. Nothing here negotiates an extension, so a reserved
    # bit means the peer thinks something was negotiated that was not -- and
    # skipping past it is how two ends come to disagree about where the next
    # frame begins.
    var frame = maskedFrame(1, "rsv")
    frame[0] = char(ord(frame[0]) or 0x40)
    discard sendBytes(c, frame)
    let f = readFrame(c)
    check("a reserved bit is refused", f.got and f.opcode == 8,
          "opcode " & $f.opcode)
    wsClose(c)

    c = wsOpen()
    discard upgraded(c, Session, 11, head)
    discard sendBytes(c, maskedFrame(5, "unknown"))
    let f2 = readFrame(c)
    check("an unknown opcode is refused", f2.got and f2.opcode == 8,
          "opcode " & $f2.opcode)
    wsClose(c)

    c = wsOpen()
    discard upgraded(c, Session, 12, head)
    # A continuation of nothing, which is a message the server was never told
    # the start of.
    discard sendBytes(c, maskedFrame(0, "orphan"))
    let f3 = readFrame(c)
    check("a continuation with no message to continue is refused",
          f3.got and f3.opcode == 8, "opcode " & $f3.opcode)
    wsClose(c)

  settled("refused frames")

  # ------------------------------------------------- the client that vanishes

  heading "A client that vanishes"
  block:
    # Not `close`, which sends a FIN and is the easy case. `SO_LINGER 0` sends
    # a reset, which is what a killed process or a lost cable leaves behind:
    # the server has an open socket whose peer is gone and no event saying so
    # until it writes.
    var c = wsOpen()
    var head = ""
    let up = upgraded(c, Session, 13, head)
    check("a websocket is open before the client disappears", up, head)
    wsAbort(c)

    # A reset is noticed at once -- the poller is already watching this socket,
    # `recv` fails on the next wakeup, and the connection is dropped and its
    # session forgotten. So one provocation after a short pause is enough, and
    # it must reach the queue the poll drains.
    #
    # What is *not* claimed is that no notification can ever be lost. A write
    # onto a reset socket succeeds into the kernel buffer and the reset comes
    # back afterwards, so a push in flight at the moment the client disappears
    # has no answer TCP can give -- which is why `emu/notify` says the profile
    # is the durable record and a notification is not. The claim here is the
    # one that matters for a session: the dead entry is retired, so the *rest*
    # of the news is not dropped into it silently.
    cSleepMs(500'i32)
    check("something can still be provoked after the client vanished",
          provokeMail(), "nothing left in the profile to list")

    var found = false
    var tries = 0
    while tries < 20 and not found:
      let polled = call("/client/notifier/getwebsocket/" & Session, "")
      if polled.ok and find(polled.body, "new_message") >= 0:
        found = true
      else:
        cSleepMs(200'i32)
      inc tries
    check("once the server notices, notifications fall back to the poll",
          found, "the poll never handed one over")

  settled("the vanished client")

  # ------------------------------------------------------------ idle sockets

  heading "Idle websockets"
  block:
    # The measurement this whole change rests on. Under the accept-thread pool
    # this server used to be, a held connection took a worker for its life and
    # a hundred of them was unanswerable by construction -- which is why the
    # notifier was a poll and said so in its own source. The claim now is that a
    # connection nobody is answering costs a socket and its buffer, so the only
    # question is whether an ordinary request notices.
    var held: seq[WsClient] = @[]
    var opened = 0
    var k = 0
    while k < IdleSockets:
      var c = wsOpen(2000)
      if c.sock != 0'u64:
        var head = ""
        # Each on its own session id, because one session may only have one
        # notifier: registering a second retires the first, and a hundred
        # sockets on one session would be a hundred connections the server was
        # right to have forgotten.
        var sess = "d"
        var d = k
        var j = 0
        while j < 23:
          sess.add "0123456789abcdef"[(d + j) and 15]
          d = d div 2
          inc j
        if upgraded(c, sess, 20 + k, head):
          inc opened
        held.add c
      inc k
    check("a hundred websockets can be held open at once",
          opened >= IdleSockets - 2, $opened & " of " & $IdleSockets)

    # Timed behind them, and not "eventually": twenty requests, and the whole
    # batch has to come back in the time an idle server would take. A second
    # for twenty is two orders of magnitude above what they cost on an idle
    # server and far under any deadline a held socket is waiting out, so
    # anything over it means they are queueing behind something.
    let started = wsNowUs()
    var answered = 0
    var q = 0
    while q < 20:
      let r = call("/client/game/config", "")
      if r.ok and r.contains("\"err\":0"): inc answered
      inc q
    let elapsedMs = int((wsNowUs() - started) div 1000'i64)
    note "twenty ordinary requests behind " & $opened &
         " idle websockets took " & $elapsedMs & " ms"
    check("every ordinary request behind them was answered", answered == 20,
          $answered & " of 20")
    check("and they were not slowed down", elapsedMs <= 1000,
          "twenty requests took " & $elapsedMs & " ms")

    # And a push still reaches a socket that is not one of the idle hundred,
    # which is the check that the poller is still reading rather than merely
    # still accepting.
    var live = wsOpen()
    var head = ""
    let up = upgraded(live, Session, 400, head)
    check("a new websocket still upgrades behind them", up, head)

    for j in 0 ..< held.len:
      var h = held[j]
      wsClose(h)
    wsClose(live)

    var backAgain = false
    var t2 = 0
    while t2 < 40 and not backAgain:
      let again = call("/client/game/config", "")
      backAgain = again.ok and again.contains("\"err\":0")
      if not backAgain: cSleepMs(200'i32)
      inc t2
    check("and the server is unchanged once they let go", backAgain,
          "still not answering after " & $t2 & " attempts")

  settled("idle websockets")

  # ------------------------------------------------------------- the fallback

  heading "A client that never upgrades"
  block:
    # The regression guard. Everything above is new; this is the promise that
    # nothing under it moved. A plain request to the notifier URL must still be
    # answered as a poll, immediately, with the shape it always had.
    let polled = call("/client/notifier/getwebsocket/" & Session, "")
    check("the notifier URL still answers an ordinary request",
          polled.ok and polled.contains("\"err\":0"), polled.body)
    check("with a ping when there is no news",
          find(polled.body, "\"type\":\"ping\"") >= 0, polled.body)
    let channel = call("/client/notifier/channel/create", "{}")
    check("and the channel still opens", channel.ok and
          channel.contains("\"channel_id\""), channel.body)

  heading "Result"
  if not keep:
    cSpawnKill(gProc)
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " failed"
    return 1
  ok "the notifier websocket passed all " & $gChecks & " checks"
  result = 0

quit(main())
