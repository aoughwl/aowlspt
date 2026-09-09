## The notifier websocket: the handshake, the frames, and the session table.
##
## The game opens `/client/notifier/getwebsocket/<session>` at login and
## expects to be *pushed* to for the rest of the session — new mail, an
## insurance return, a flea offer sold, a raid invitation. Everything a server
## decides on its own has nowhere to go without it: the profile can change all
## it likes and the player finds out on the next screen that happens to reload.
##
## It could not be held before, for a structural reason rather than a protocol
## one. The server was a fixed pool of accept threads, a connection took one
## from `accept` to `close`, and four players idling in the menu owned the
## whole server; `mods/tarkov` said so in `emu/notify.nim` and answered the
## same URL with an immediate poll instead. The poller removed exactly that.
## A connection nobody is answering now costs a socket and its buffer, the
## bound is 1024 sockets and 64 MiB rather than sixteen threads, and a held
## websocket became something this shape can afford.
##
## **Where the halves fall, and why.** `abi/aowlspt_net.h` owns the socket, the
## read loop, frame *boundaries* and the read-path refusals — the same job it
## already does for requests, for the same reason: the poller has to know how
## many bytes are one frame in order to know whether it has one. Everything
## else is here:
##
##   * The handshake, because it is `Sec-WebSocket-Key` + the well-known GUID +
##     SHA-1 + base64 and nimony ships `std/sha1` and `std/base64`. Writing
##     them again in C would be a second implementation of two solved things in
##     the language this repository uses least.
##   * Every byte that goes out, because that is the rule the rest of the
##     server already keeps — no status line, header or frame is composed in C.
##     The poller detects a ping, a close or a violation and calls back here;
##     this file builds the answer and hands it to `aowl_ws_send`, which owns
##     only the lock and the socket.
##   * The session table, because a session id is an HTTP and game concept and
##     the C side has never had one.
##
## **A ticket, not a socket.** What this file stores against a session is the
## ticket `aowl_ws_adopt` gave the connection, and tickets are never reused. If
## it stored the socket handle, then a websocket closing and a new one being
## accepted onto the same recycled handle — before the poller had told this
## file the first was gone — would deliver one player's mail to another. That
## window is small, unreproducible, and entirely avoidable.

import std/[strutils, sha1, base64]
import modhost

# Only the lock, and that is the whole of this module's C dependency.
#
# **nimony emits one translation unit per module**, and everything in `abi/` is
# `static`. So a header included by two modules gives each of them its *own*
# copy of every variable in it -- and this file learned that the expensive way:
# it called `aowl_ws_adopt` directly, which searched a second, permanently
# empty connection table, answered "no such connection" for every handshake,
# and the server closed each websocket immediately after writing it a perfectly
# correct `101`.
#
# So nothing here touches the poller's state. `aowlbackend.nim` is the module
# that emits `aowlspt_net.h` and runs the server, so it is the only one that
# may, and it installs the three calls this file needs through `wsBind` below.
# The lock is safe to have a private copy of for the opposite reason: it guards
# `gWs`, which is this module's alone, and a lock shared with the route table
# would be a lock two files have to agree about the ordering of.
{.emit: """#include "aowlspt_lock.h" """.}

proc cWsLock() {.importc: "aowl_lock", nodecl.}
proc cWsUnlock() {.importc: "aowl_unlock", nodecl.}

type
  RawSendFn* = nil proc (sock: uint64; data: string): bool
    ## Bytes onto a socket that is not yet a websocket -- the `101` and the
    ## `400`s.
  FrameSendFn* = nil proc (ticket: int64; data: string): bool
    ## One already-built frame, under the C side's websocket write lock.
  AdoptFn* = nil proc (sock: uint64): int64
    ## Take this connection out of the request state machine; answers its
    ## ticket, or 0 if the poller is not holding it any more.

var gRawSend: RawSendFn = nil
var gFrameSend: FrameSendFn = nil
var gAdopt: AdoptFn = nil

proc wsBind*(raw: RawSendFn; frame: FrameSendFn; adopt: AdoptFn) =
  ## Installed once by `aowlbackend.nim` before the server starts. Until it is,
  ## every path here refuses rather than upgrading -- a websocket answered by a
  ## module that cannot write to it would be a connection held for nothing.
  gRawSend = raw
  gFrameSend = frame
  gAdopt = adopt

const
  WsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    ## RFC 6455's magic string. It is not a secret and is not doing any
    ## cryptography: concatenating it and hashing proves only that the peer
    ## read the key and knows this protocol, which is the whole job — it stops
    ## a cached or cross-protocol response being mistaken for a handshake.

  OpText* = 1
  OpBinary* = 2
  OpClose* = 8
  OpPing* = 9
  OpPong* = 10

  CloseNormal* = 1000
  CloseGoingAway* = 1001
  CloseProtocol* = 1002
  CloseTooBig* = 1009

# ---------------------------------------------------------------------------
# Reading the handshake
# ---------------------------------------------------------------------------

proc headerValue*(head: string; name: string): string =
  ## The value of one header out of a request block, or "". `name` must already
  ## be lower case; the comparison is case-insensitive on the header, which is
  ## what HTTP requires and what a client that capitalises differently needs.
  result = ""
  let lines = splitLines(head)
  for i in 1 ..< lines.len:
    let l = lines[i]
    let colon = find(l, ":")
    if colon < 0: continue
    if toLowerAscii(strip(l.substr(0, colon - 1))) == name:
      return strip(l.substr(colon + 1))

proc hasToken(value, token: string): bool =
  ## Whether a comma-separated header value carries a token, case-insensitively.
  ## `Connection: keep-alive, Upgrade` is a shape real clients send, so a whole
  ## string comparison here would refuse a correct handshake.
  result = find(toLowerAscii(value), token) >= 0

proc isUpgrade*(head: string): bool =
  ## Cheap and deliberately loose: `Upgrade: websocket` is present. Every other
  ## condition is checked by `handshake`, which answers `400` and names the one
  ## that failed rather than falling through to an ordinary route — a request
  ## that asked to upgrade and got a JSON body back is a client that hangs.
  result = hasToken(headerValue(head, "upgrade"), "websocket")

proc acceptFor*(key: string): string =
  ## `base64(sha1(key + GUID))`, which is the whole of the server's half.
  var st = newSha1State()
  update(st, key)
  update(st, WsGuid)
  let digest = finalize(st)
  var raw = newSeq[char](20)
  for i in 0 ..< 20:
    raw[i] = char(digest[i])
  result = encode(raw)

proc keyIsWellFormed*(key: string): bool =
  ## The RFC's key is sixteen random bytes, base64. Twenty-four characters with
  ## one pad, decoding to exactly sixteen bytes.
  ##
  ## Checked rather than assumed because the check is the only thing standing
  ## between "a client that speaks this protocol" and "anything that can be
  ## made to issue a GET". A server that hashes whatever it was sent and
  ## answers 101 has turned every request into a websocket.
  if key.len != 24: return false
  result = decode(key).len == 16

# ---------------------------------------------------------------------------
# Building frames
# ---------------------------------------------------------------------------

proc frameOf*(opcode: int; payload: string): string =
  ## One whole frame, FIN set, **unmasked** — a server must not mask, which is
  ## the mirror of the rule that a client must.
  result = ""
  result.add char(0x80 or (opcode and 0x0F))
  let n = payload.len
  if n <= 125:
    result.add char(n)
  elif n <= 65535:
    result.add char(126)
    result.add char((n shr 8) and 0xFF)
    result.add char(n and 0xFF)
  else:
    result.add char(127)
    var shift = 56
    while shift >= 0:
      result.add char((n shr shift) and 0xFF)
      shift = shift - 8
  result.add payload

proc closeFrame*(code: int; reason: string): string =
  ## A close carries a two-byte big-endian status and an optional reason, and
  ## the whole payload must fit in a control frame's 125 bytes. The reason is
  ## truncated rather than dropped: it is the only thing that tells whoever is
  ## reading a packet capture *why*, and a truncated sentence still says it.
  var body = ""
  body.add char((code shr 8) and 0xFF)
  body.add char(code and 0xFF)
  if reason.len > 0:
    body.add(if reason.len > 123: reason.substr(0, 122) else: reason)
  result = frameOf(OpClose, body)

# ---------------------------------------------------------------------------
# The session table
# ---------------------------------------------------------------------------
#
# Small, linear and under the process lock. A single-player server has one
# notifier open; the bound is `AOWL_NET_MAX_CONNS` and a scan of that is
# nothing next to a request. What matters is the two rules:
#
#   * **One socket per session.** A client that reconnects — a menu reload, a
#     raid ending — opens a new one, and leaving the old entry in place means
#     pushing to a socket nobody reads while the live one stays silent. The new
#     registration closes the old entry out.
#   * **Never hold this lock across a send.** `aowl_ws_send` takes the C side's
#     websocket lock, and the poller calls into this file while holding
#     nothing. Keeping the order one-way — this lock, then that one, never both
#     at once — is what makes the pair impossible to deadlock.

type WsConn = object
  session: string
  ticket: int64

var gWs: seq[WsConn] = @[]

proc wsRegister*(session: string; ticket: int64) =
  if ticket == 0 or session.len == 0: return
  cWsLock()
  var keep: seq[WsConn] = @[]
  for c in gWs:
    if c.session != session and c.ticket != ticket:
      keep.add c
  keep.add WsConn(session: session, ticket: ticket)
  gWs = keep
  cWsUnlock()

proc wsForget*(ticket: int64): string =
  ## Drops the entry and answers whose it was, for the log line.
  result = ""
  if ticket == 0: return
  cWsLock()
  var keep: seq[WsConn] = @[]
  for c in gWs:
    if c.ticket == ticket:
      result = c.session
    else:
      keep.add c
  gWs = keep
  cWsUnlock()

proc wsTicketFor*(session: string): int64 =
  result = 0'i64
  if session.len == 0: return
  cWsLock()
  for c in gWs:
    if c.session == session:
      result = c.ticket
      break
  cWsUnlock()

proc wsSessionFor*(ticket: int64): string =
  result = ""
  cWsLock()
  for c in gWs:
    if c.ticket == ticket:
      result = c.session
      break
  cWsUnlock()

proc wsOpenCount*(): int =
  cWsLock()
  result = gWs.len
  cWsUnlock()

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

proc wsSendFrame*(ticket: int64; frame: string): bool =
  ## The one way anything reaches the wire. Never called under the table lock.
  if ticket == 0 or frame.len == 0: return false
  if gFrameSend == nil: return false
  result = gFrameSend(ticket, frame)

proc wsPush*(session, payload: string): bool =
  ## Push one notification. False means there is no open socket for that
  ## session — which is the ordinary state of a client that has not upgraded,
  ## and the mod's cue to fall back to its queue rather than a failure.
  let ticket = wsTicketFor(session)
  if ticket == 0: return false
  let frame = frameOf(OpText, payload)
  result = wsSendFrame(ticket, frame)
  if not result:
    # The socket would not take it. The poller will notice and drop the
    # connection, but the entry goes now so the *next* push falls back to the
    # queue rather than being lost into the same dead socket.
    discard wsForget(ticket)

# ---------------------------------------------------------------------------
# The handshake, end to end
# ---------------------------------------------------------------------------

proc sendPlain(sock: uint64; text: string) =
  if gRawSend != nil:
    discard gRawSend(sock, text)

proc refuse(sock: uint64; why: string) =
  ## A refused upgrade is answered as an ordinary `400` with the reason in it,
  ## and the connection is closed. Both halves matter: a client that asked to
  ## upgrade and got a 200 with a JSON body would wait for frames that never
  ## come, and `400` with an empty body is indistinguishable from a server that
  ## fell over — the rule `fuzzwire` enforces everywhere else here.
  let body = "{\"err\":\"" & why & "\"}"
  var head = "HTTP/1.1 400 Bad Request\r\n"
  head.add "Content-Type: application/json\r\n"
  head.add "Content-Length: " & $body.len & "\r\n"
  head.add "Connection: close\r\n\r\n"
  sendPlain(sock, head & body)

proc handshake*(sock: uint64; head, session: string; ticket: var int64): bool =
  ## Answers the upgrade. True means the connection is now a websocket and the
  ## caller must tell the poller so; false means a `400` has gone out and the
  ## connection must close.
  ##
  ## Four refusals, and each names a way the request is not this protocol:
  ##
  ## * no `Connection: Upgrade` — an `Upgrade` header on its own is a hint, not
  ##   a request, and honouring it would upgrade a connection whose client did
  ##   not ask.
  ## * a version that is not 13 — the only one anything has spoken for a
  ##   decade, and answering an unknown one is guessing at a framing.
  ## * a key that is not sixteen base64 bytes — see `keyIsWellFormed`.
  ## * no session — this server has exactly one thing to push and it is
  ##   per-player. A socket with no session to file it under is one nothing can
  ##   ever be sent down, and holding it would be holding it for nothing.
  ticket = 0'i64
  if gAdopt == nil or gRawSend == nil:
    return false
  if not hasToken(headerValue(head, "connection"), "upgrade"):
    refuse(sock, "a websocket upgrade needs Connection: Upgrade")
    return false
  let version = headerValue(head, "sec-websocket-version")
  if version != "13":
    refuse(sock, "this server speaks websocket version 13, not " &
                 (if version.len > 0: version else: "(none stated)"))
    return false
  let key = headerValue(head, "sec-websocket-key")
  if not keyIsWellFormed(key):
    refuse(sock, "Sec-WebSocket-Key must be sixteen bytes, base64")
    return false
  if session.len == 0:
    refuse(sock, "a notifier websocket needs a session")
    return false

  var resp = "HTTP/1.1 101 Switching Protocols\r\n"
  resp.add "Upgrade: websocket\r\n"
  resp.add "Connection: Upgrade\r\n"
  resp.add "Sec-WebSocket-Accept: " & acceptFor(key) & "\r\n"
  resp.add "\r\n"
  sendPlain(sock, resp)

  # Adopted only *after* the 101 is on the wire. The other order would let the
  # poller start reading frames on a connection whose handshake had not been
  # answered, and a push could go out ahead of the response that makes it
  # readable.
  if gAdopt == nil:
    return false
  ticket = gAdopt(sock)
  if ticket == 0'i64:
    # The connection is not one the poller is holding, which means it is
    # already being torn down. Nothing to register and nothing to keep.
    return false
  wsRegister(session, ticket)
  modhost.info "notifier websocket open for " & session &
               " (" & $wsOpenCount() & " open)"
  result = true

# ---------------------------------------------------------------------------
# What the poller calls back
# ---------------------------------------------------------------------------

proc wsOnControl*(ticket: int64; kind, code: int; payload: string) =
  ## kind 0: a ping to echo. kind 1: the peer's close. kind 2: a frame this
  ## server refuses, `code` being the status to say so with.
  ##
  ## Every one of these puts bytes on the wire, and none of those bytes is
  ## composed in C — which is the same rule `aowlspt_nim_timeout` exists to
  ## keep for the `408`.
  if kind == 0:
    # A pong carries the ping's payload back, byte for byte. Anything else is a
    # pong to a different ping as far as the peer is concerned.
    discard wsSendFrame(ticket, frameOf(OpPong, payload))
  elif kind == 1:
    discard wsSendFrame(ticket, closeFrame(CloseNormal, ""))
  else:
    let why =
      if code == CloseTooBig: "that frame is larger than this server accepts"
      else: "that is not a frame this server can read"
    discard wsSendFrame(ticket, closeFrame(code, why))
    modhost.warn "notifier websocket refused a frame (" & $code & "): " & why

proc wsOnMessage*(ticket: int64; opcode: int; payload: string): bool =
  ## A whole message from the client, reassembled across continuations by the
  ## poller. The game's notifier never sends one — the channel is one-way — so
  ## this exists because a protocol half-implemented is one that fails on the
  ## first client using the other half, and because ignoring a message quietly
  ## is different from not being able to receive one.
  ##
  ## Returns true to keep the connection, which is the answer for anything that
  ## framed correctly: there is nothing a client can say here that this server
  ## needs to act on, and closing on an unexpected message would make the
  ## notifier fragile to a client being chatty.
  modhost.info "notifier websocket ignored a " & $payload.len &
               "-byte message (opcode " & $opcode & ")"
  result = true

proc wsOnIdle*(ticket: int64; pinged: bool): bool =
  ## Nothing has arrived for `AOWL_WS_IDLE_MS`. First time: ping, and see. The
  ## second time with the ping still unanswered: the client is gone.
  ##
  ## This is the only way to tell an idle notifier from a client that vanished
  ## without closing. A half-open TCP connection is indistinguishable from a
  ## quiet one until something is written to it — a laptop that slept, a
  ## process killed, a cable — and a notifier that is never written to would sit
  ## in the poller's watch list for the life of the server.
  if pinged:
    let session = wsForget(ticket)
    modhost.info "notifier websocket for " & session &
                 " did not answer a ping; closing"
    return false
  result = wsSendFrame(ticket, frameOf(OpPing, ""))

proc wsOnGone*(ticket: int64) =
  ## The poller has closed the connection. Forgetting the entry here rather
  ## than waiting for the next failed push is what keeps `wsPush` able to say
  ## "no socket" — which is the answer that makes the mod fall back to its
  ## queue instead of dropping a notification into a closed socket.
  let session = wsForget(ticket)
  if session.len > 0:
    modhost.info "notifier websocket closed for " & session &
                 " (" & $wsOpenCount() & " open)"
