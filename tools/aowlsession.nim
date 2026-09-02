## Asking the backend things, and choosing a profile to play.
##
## ## Why this speaks HTTP by hand
##
## `backend/wire.nim` is a complete client for this server and would be the
## obvious thing to reuse. It cannot be: `aowl build` builds this launcher with
## `buildTool`, which passes the ABI include path and two source trees and does
## **not** pass `-lws2_32` or `-lz`, and does not put `backend/` on the search
## path. That rule is shared by every tool built the same way and lives in a
## file this one does not own. So the sockets are resolved out of `ws2_32.dll`
## at run time -- eight `GetProcAddress` calls once per launch -- and nothing is
## asked of the build.
##
## ## Why there is no zlib here
##
## The server deflates every response, and a launcher that had to inflate one
## would need zlib linked in for the same reason. It does not have to. The
## backend honours `Accept-Encoding: identity` (`aowlbackend.parseHead`, and
## `sendResponse` is called with `not req.identity`), and its request side
## passes an un-framed body straight through (`inflateBody` returns the bytes
## as they are when `aowl_zlib_looks_framed` says no). So the launcher's
## conversation is plain JSON in both directions, by agreement rather than by
## accident, and the one comment worth leaving is that this is *the* reason the
## header is there.
##
## ## The profile contract
##
## The launcher needs three things from the server and none of them is part of
## the game's own protocol -- the client asks for profiles with a session it
## already has, and the launcher has to choose *which* session before the client
## starts. So they live in aowlspt's own namespace, `/aowlspt/tarkov/launcher/*`
## -- deliberately *not* `/launcher/*`, which would be a guess at SPT's own URLs
## rather than this server's:
##
##   GET|POST /aowlspt/tarkov/launcher/profiles
##     -> {"ok":true,"profiles":[ <row>, ... ]}
##
##   POST /aowlspt/tarkov/launcher/profile/create
##        {"nickname":"...","side":"Usec"|"Bear"}   (only nickname required)
##     -> {"ok":true,"token":"<24 hex>","profile":<row>}
##
##   POST /aowlspt/tarkov/launcher/profile/select
##        {"id":"<24 hex>"}                          ("token" accepted as alias)
##     -> {"ok":true,"token":"<24 hex>","profile":<row>}
##
## `select` rebinds the launcher's session to the profile, and is called before
## launch *even for a profile that was just listed*: the launch token is
## whatever it hands back, not the id the launcher happened to have. That token
## equals the profile id, and it is what goes in the client's `-token=`.
##
## A `<row>` is {"id","token","readable","nickname","side","level",
## "experience","voice","edition","registered"}. Every field is optional here
## except `id`; `registered` is read as the profile's timestamp.
##
## The store aliases (`_id`, `Info.Nickname`, `Info.Side`, `Info.Level`,
## `Info.Edition`) are still read, so the same parser also copes with a whole
## profile *document* if it is ever handed one -- but the row never carries
## them. The one thing that is **not** guessed at is the id: a profile with no
## readable id is skipped and said to be skipped, because inventing one would
## start a game against a session the server has never heard of and the symptom
## is a menu that never loads.
##
## ## The envelope, and where failure lives
##
## Every one of these answers `{"ok":true, ...}` or `{"ok":false,"error":"..."}`,
## and a *failure is still HTTP 200* -- the status line says nothing, the `ok`
## field says everything. So this checks `ok`, never the status code, and
## surfaces the server's `error` sentence verbatim: it is written to be shown to
## a person ("that nickname is taken"), which is worth more than any code.
##
## Everything degrades by *saying so*. A 404 on the profiles route is reported
## as "this backend has no profile-list route", and the store on disk is read
## instead -- which is the same source of truth the route would read, one layer
## down. What never happens is a profile appearing that does not exist.

import std/strutils
import aowlsptinstall/winfs
import "../host/common/jsonpath"

{.emit: """
#include <windows.h>
#include <stdint.h>
#include <string.h>

/* Winsock 1.1 through <windows.h>, resolved at run time. `aowlspt_net.h` is
 * deliberately not included: it includes winsock2.h, and winsock2 after
 * windows.h is the redefinition mess every Windows codebase meets once. A TCP
 * connect and a blocking send/recv is all of what is wanted. */
typedef SOCKET (WINAPI *aowl_s_socket)(int, int, int);
typedef int (WINAPI *aowl_s_connect)(SOCKET, const struct sockaddr*, int);
typedef int (WINAPI *aowl_s_send)(SOCKET, const char*, int, int);
typedef int (WINAPI *aowl_s_recv)(SOCKET, char*, int, int);
typedef int (WINAPI *aowl_s_closesocket)(SOCKET);
typedef int (WINAPI *aowl_s_setsockopt)(SOCKET, int, int, const char*, int);
typedef int (WINAPI *aowl_s_wsastartup)(WORD, LPWSADATA);
typedef u_short (WINAPI *aowl_s_htons)(u_short);
typedef u_long (WINAPI *aowl_s_htonl)(u_long);

static HMODULE aowl_sws = NULL;
static aowl_s_socket      aowl_sp_socket;
static aowl_s_connect     aowl_sp_connect;
static aowl_s_send        aowl_sp_send;
static aowl_s_recv        aowl_sp_recv;
static aowl_s_closesocket aowl_sp_closesocket;
static aowl_s_setsockopt  aowl_sp_setsockopt;
static aowl_s_htons       aowl_sp_htons;
static aowl_s_htonl       aowl_sp_htonl;

static int aowl_sws_ready(void) {
  aowl_s_wsastartup startup;
  WSADATA wsa;
  if (aowl_sws != NULL) return 1;
  aowl_sws = LoadLibraryA("ws2_32.dll");
  if (aowl_sws == NULL) return 0;
  startup             = (aowl_s_wsastartup)(void*)GetProcAddress(aowl_sws, "WSAStartup");
  aowl_sp_socket      = (aowl_s_socket)(void*)GetProcAddress(aowl_sws, "socket");
  aowl_sp_connect     = (aowl_s_connect)(void*)GetProcAddress(aowl_sws, "connect");
  aowl_sp_send        = (aowl_s_send)(void*)GetProcAddress(aowl_sws, "send");
  aowl_sp_recv        = (aowl_s_recv)(void*)GetProcAddress(aowl_sws, "recv");
  aowl_sp_closesocket = (aowl_s_closesocket)(void*)GetProcAddress(aowl_sws, "closesocket");
  aowl_sp_setsockopt  = (aowl_s_setsockopt)(void*)GetProcAddress(aowl_sws, "setsockopt");
  aowl_sp_htons       = (aowl_s_htons)(void*)GetProcAddress(aowl_sws, "htons");
  aowl_sp_htonl       = (aowl_s_htonl)(void*)GetProcAddress(aowl_sws, "htonl");
  if (startup == NULL || aowl_sp_socket == NULL || aowl_sp_connect == NULL ||
      aowl_sp_send == NULL || aowl_sp_recv == NULL ||
      aowl_sp_closesocket == NULL || aowl_sp_setsockopt == NULL ||
      aowl_sp_htons == NULL || aowl_sp_htonl == NULL) {
    aowl_sws = NULL;
    return 0;
  }
  if (startup(MAKEWORD(2, 2), &wsa) != 0) { aowl_sws = NULL; return 0; }
  return 1;
}

/* >0  bytes of response in `out`
 *  0  nothing is listening on the port
 * -1  winsock could not be loaded, so this cannot be asked at all
 * -2  the response is larger than the buffer -- reported rather than
 *     truncated, because a truncated JSON document parses as a *different*
 *     document rather than as an error
 * -3  connected, then the send or the receive failed */
static int32_t aowl_http_call(int32_t port, const char* req, int32_t reqLen,
                              char* out, int32_t outCap) {
  SOCKET s;
  struct sockaddr_in a;
  int have = 0;
  DWORD t;
  if (!aowl_sws_ready()) return -1;
  s = aowl_sp_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) return 0;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_port = aowl_sp_htons((unsigned short)port);
  a.sin_addr.s_addr = aowl_sp_htonl(INADDR_LOOPBACK);
  if (aowl_sp_connect(s, (struct sockaddr*)&a, (int)sizeof(a)) == SOCKET_ERROR) {
    aowl_sp_closesocket(s);
    return 0;
  }
  /* Bounded. A backend mid-flush holds the store lock, and a probe that blocks
   * for ever on it hangs the launcher rather than the request. */
  t = 15000;
  aowl_sp_setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&t, sizeof(t));
  t = 5000;
  aowl_sp_setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&t, sizeof(t));
  if (aowl_sp_send(s, req, reqLen, 0) == SOCKET_ERROR) {
    aowl_sp_closesocket(s);
    return -3;
  }
  for (;;) {
    int n;
    if (have >= outCap) { aowl_sp_closesocket(s); return -2; }
    n = aowl_sp_recv(s, out + have, outCap - have, 0);
    if (n == 0) break;
    if (n == SOCKET_ERROR) {
      aowl_sp_closesocket(s);
      return have > 0 ? have : -3;
    }
    have += n;
  }
  aowl_sp_closesocket(s);
  return (int32_t)have;
}

/* Connect, and close. Nothing is sent and nothing is read.
 *
 * This exists because the launcher cannot speak TLS and therefore could not
 * ask a TLS backend anything -- it fell back to reading the backend's own log
 * for `listening on`, which on a back-to-back restart is the PREVIOUS run's
 * file. A TCP connect is the one readiness signal that is true for a TLS
 * listener, cannot be stale, and costs nothing:
 *
 *   -1  winsock could not be loaded, so the question cannot be asked
 *    0  the connect was refused -- nobody is listening on that port
 *    1  something accepted a connection there
 *
 * `aowl_http_call` cannot stand in for this against a TLS port: it sends a
 * plain HTTP request, the TLS server waits for a ClientHello that never comes,
 * and the probe pays the 15 s receive timeout. Sending nothing is the point.
 *
 * A bind WITHOUT a listen -- which is exactly what the backend's `reservePort`
 * holds for the first several seconds of its startup -- refuses connect with
 * RST. So a 1 from here means `listen(2)` has been called, which is the event
 * the client needs and the event the log line only claims.
 */
static int32_t aowl_tcp_connects(int32_t port) {
  SOCKET s;
  struct sockaddr_in a;
  if (!aowl_sws_ready()) return -1;
  s = aowl_sp_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) return -1;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_port = aowl_sp_htons((unsigned short)port);
  a.sin_addr.s_addr = aowl_sp_htonl(INADDR_LOOPBACK);
  if (aowl_sp_connect(s, (struct sockaddr*)&a, (int)sizeof(a)) == SOCKET_ERROR) {
    aowl_sp_closesocket(s);
    return 0;
  }
  aowl_sp_closesocket(s);
  return 1;
}
""".}

proc cHttpCall(port: int32; req: cstring; reqLen: int32; outBuf: pointer;
               outCap: int32): int32 {.importc: "aowl_http_call", nodecl.}
proc cTcpConnects(port: int32): int32 {.importc: "aowl_tcp_connects", nodecl.}

proc connects*(port: int): int =
  ## 1 something is accepting TCP connections on 127.0.0.1:`port`, 0 nothing is,
  ## -1 the question cannot be asked. See `aowl_tcp_connects` above.
  ##
  ## This is the ONLY readiness check in this codebase that works against the
  ## TLS port, and it is deliberately weaker than `answers`: it establishes that
  ## a listener exists, not that it routes. The launcher wants both, in that
  ## order -- a log line that says the backend listened, and a socket that
  ## proves it is still true now.
  result = int(cTcpConnects(int32(port)))

const
  ProbeSession* = "000000000000000000000001"
    ## A well-formed but meaningless session. The backend refuses a malformed
    ## id before any route sees it, so a probe has to carry one that parses; it
    ## does not have to name a real profile, because what is being established
    ## is that the server answers at all.
  ResponseCap = 4 * 1024 * 1024
    ## Generous for a profile list and far under what a whole profile document
    ## would be. `-2` says so rather than truncating.

type
  Reply* = object
    ok*: bool          ## a complete HTTP response came back
    status*: int       ## the HTTP status code, 0 when there was no reply
    body*: string      ## the response body, un-deflated because of `identity`
    error*: string     ## why not, in a sentence, when `ok` is false

proc statusCodeOf(line: string): int =
  ## `HTTP/1.1 200 OK` -> 200. 0 for anything that is not a status line.
  result = 0
  let sp = find(line, " ")
  if sp < 0: return
  var v = 0
  var any = false
  var i = sp + 1
  while i < line.len and line[i] >= '0' and line[i] <= '9':
    v = v * 10 + (ord(line[i]) - ord('0'))
    any = true
    inc i
  if any: result = v

proc call*(port: int; verb, path, body, session: string): Reply =
  ## One request, one answer, connection closed. There is no keep-alive here on
  ## purpose: the launcher makes a handful of calls in a session and a pooled
  ## connection would be one more thing to get wrong at shutdown.
  result = Reply(ok: false, status: 0, body: "", error: "")
  var req = verb & " " & path & " HTTP/1.1\r\n"
  req.add "Host: 127.0.0.1:" & $port & "\r\n"
  req.add "Cookie: PHPSESSID=" & session & "\r\n"
  # The reason the launcher needs no zlib. See the module comment.
  req.add "Accept-Encoding: identity\r\n"
  req.add "Content-Type: application/json\r\n"
  req.add "Content-Length: " & $body.len & "\r\n"
  req.add "Connection: close\r\n\r\n"
  req.add body

  var buf = newSeq[byte](ResponseCap)
  var r = req
  let n = cHttpCall(int32(port), toCString(r), int32(r.len),
                    cast[pointer](addr buf[0]), int32(ResponseCap))
  if n == -1'i32:
    result.error = "winsock could not be loaded, so the backend cannot be asked anything"
    return
  if n == 0'i32:
    result.error = "nothing is listening on 127.0.0.1:" & $port
    return
  if n == -2'i32:
    result.error = "the answer to " & path & " is larger than " &
                   $(ResponseCap div 1048576) & " MB"
    return
  if n == -3'i32:
    result.error = "connected to 127.0.0.1:" & $port & " and then lost the connection"
    return

  var raw = ""
  let dest = beginStore(raw, int(n))
  copyMem(dest, addr buf[0], int(n))
  endStore(raw)

  var headEnd = find(raw, "\r\n\r\n")
  var sep = 4
  if headEnd < 0:
    headEnd = find(raw, "\n\n")
    sep = 2
  if headEnd < 0:
    result.error = "no header terminator in the answer to " & path
    return
  let head = raw.substr(0, headEnd - 1)
  let lines = splitLines(head)
  if lines.len == 0:
    result.error = "an empty header in the answer to " & path
    return
  result.status = statusCodeOf(lines[0])
  if result.status == 0:
    result.error = "the answer to " & path & " does not begin with a status line"
    return
  result.body = raw.substr(headEnd + sep)
  result.ok = true

proc answers*(port: int): int =
  ## 1 the backend is up and routing, 0 nothing is there yet, -1 the question
  ## cannot be asked at all (no winsock).
  ##
  ## `/aowlspt/tarkov/selfcheck` rather than a generic status route. The backend
  ## only begins listening after every mod has finished loading, so *any* HTTP
  ## answer already means the load is done -- but this route belongs to the
  ## tarkov mod, so an answer here is specifically the mod that serves the
  ## profile routes reporting itself up. That is the readiness the launcher
  ## needs, because the next thing it does is ask that mod for profiles. A
  ## backend without the mod still answers (with a 404), which still means
  ## "listening", and the profile call then degrades to the store on its own.
  let r = call(port, "GET", "/aowlspt/tarkov/selfcheck", "", ProbeSession)
  if r.ok: return 1
  if find(r.error, "winsock") >= 0: return -1
  result = 0

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

type
  Profile* = object
    id*: string
    token*: string
      ## What to launch with (`-token`). The row carries it and it equals the
      ## id; kept separate so the launcher passes the value the server handed
      ## back rather than one it assumed.
    nickname*: string
    side*: string
    level*: int
    edition*: string
    lastPlayed*: int

  ProfileSource* = enum
    psRoute    ## the backend answered /aowlspt/tarkov/launcher/profiles
    psStore    ## read off disk, because it did not
    psNone     ## neither worked

  ProfileList* = object
    source*: ProfileSource
    items*: seq[Profile]
    note*: string   ## why the source is what it is, when it is not the route
    error*: string  ## set only when nothing could be read at all

proc okField(body: string): bool =
  ## The `ok` in `{"ok":true,...}`. Absent counts as false: a body with no `ok`
  ## is not this server's envelope at all, and reading a reshaped or truncated
  ## answer as a success is exactly the failure-wearing-success this guards.
  var v = ""
  if not pathGet(body, "ok", v): return false
  result = v == "true"

proc okEnvelope(body: string; err: var string): bool =
  ## True for `{"ok":true, ...}`. False for `{"ok":false,"error":"<sentence>"}`,
  ## with `err` set to that sentence.
  ##
  ## Failure is HTTP 200 on these routes, always -- so the status line is silent
  ## and the `ok` field is the whole answer. The `error` string is the server's
  ## own words, meant for a person, and is surfaced as-is.
  err = ""
  if okField(body): return true
  var msg = ""
  if pathGet(body, "error", msg) and msg.len > 0:
    err = msg
  else:
    err = "the server answered {\"ok\":false} without saying why"
  result = false

proc rowUnder(body, key: string): string =
  ## The `<row>` object nested under `key` (`"profile"`), as its own text, or
  ## "" when there is none there.
  var vs = 0
  var ve = 0
  if locatePath(body, key, vs, ve):
    return body.substr(vs, ve - 1)
  result = ""

proc isHexId(s: string): bool =
  ## The client's own rule for a session id, and the backend's: 24 lowercase
  ## hex characters. Checked here so that a route answering something else is
  ## refused at the launcher rather than at the game's login screen.
  if s.len != 24: return false
  for ch in s:
    let okDigit = ch >= '0' and ch <= '9'
    let okLower = ch >= 'a' and ch <= 'f'
    let okUpper = ch >= 'A' and ch <= 'F'
    if not (okDigit or okLower or okUpper): return false
  result = true

proc firstOf(text: string; paths: seq[string]; into: var string): bool =
  result = false
  for p in paths:
    if pathGet(text, p, into):
      if into.len > 0: return true
  into = ""

proc numberOf(text: string; paths: seq[string]): int =
  var s = ""
  if not firstOf(text, paths, s): return 0
  result = 0
  var any = false
  for ch in s:
    if ch >= '0' and ch <= '9':
      result = result * 10 + (ord(ch) - ord('0'))
      any = true
    elif any:
      break
  if not any: result = 0

proc parseProfile*(text: string; into: var Profile): bool =
  ## One `<row>`. False when it carries no usable id -- see the module comment
  ## for why that one field is not guessed at. The store aliases are read too,
  ## so this also parses a whole profile document if handed one.
  into = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                 edition: "", lastPlayed: 0)
  var id = ""
  discard firstOf(text, @["id", "_id", "uid", "aid", "profileId"], id)
  if not isHexId(id): return false
  into.id = id
  var tok = ""
  discard firstOf(text, @["token"], tok)
  into.token = (if isHexId(tok): tok else: id)
  discard firstOf(text, @["nickname", "Info.Nickname", "name"], into.nickname)
  discard firstOf(text, @["side", "Info.Side"], into.side)
  discard firstOf(text, @["edition", "Info.Edition"], into.edition)
  into.level = numberOf(text, @["level", "Info.Level"])
  into.lastPlayed = numberOf(text, @["registered", "lastPlayed",
                                     "Info.LastTimePlayedAsSavage"])
  result = true

proc storeProfileDir*(root: string): string =
  ## `<root>\aowlspt\store\aowl.tarkov`, which is where `modstore` puts the
  ## emulator's keys: `storeInit` roots the store at `<host dir>\store` and
  ## `storeKeys` files each mod's under its guid.
  joinPath(root, "aowlspt\\store\\aowl.tarkov")

proc profilesFromStore*(root: string; into: var seq[Profile]): string =
  ## The same profiles the route would answer with, read one layer down.
  ##
  ## This is a *fallback*, not a shortcut: it cannot see a profile the running
  ## backend has in memory and has not committed, and it knows nothing about
  ## whatever a future launcher route might add. It exists so that a backend
  ## without the route is still playable and the player is told exactly why the
  ## list came from here.
  ##
  ## Returns "" when it worked, or a sentence when it did not.
  into = @[]
  let dir = storeProfileDir(root)
  if not isDirectory(dir):
    return "there is no profile store at " & dir & " yet"
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(dir, files, dirs)
  for f in files:
    # `collectEntries` recurses and there is a `.hist` directory under here
    # holding previous generations of every key. Skipped by shape, exactly as
    # `modstore.storeKeys` does it -- a path with a separator is one of those,
    # and reporting `profile.<id>.2` as a profile would offer the player a
    # character that is one save behind.
    if find(f, "\\") >= 0: continue
    let name = baseName(f)
    if not startsWith(name, "profile."): continue
    let id = name.substr(len("profile."))
    if not isHexId(id): continue
    var text = ""
    if not readShared(joinPath(dir, name), text):
      continue
    # `readShared` hands back the bytes; `readTextFile` is the one that strips
    # a byte-order mark. A profile written by anything that puts one on -- an
    # editor, `Set-Content -Encoding utf8`, a hand-repaired save -- otherwise
    # parses as nothing at all, and the symptom is a profile in the list with
    # no nickname, no side and no level rather than an error. That exact shape
    # of failure is why `jsonpath.jsonFault` exists; here it is enough to drop
    # the three bytes.
    if text.len >= 3 and ord(text[0]) == 0xEF and ord(text[1]) == 0xBB and
       ord(text[2]) == 0xBF:
      text = text.substr(3)
    var p = Profile(id: id, token: id, nickname: "", side: "", level: 0,
                    edition: "", lastPlayed: 0)
    discard firstOf(text, @["Info.Nickname", "nickname"], p.nickname)
    discard firstOf(text, @["Info.Side", "side"], p.side)
    discard firstOf(text, @["Info.Edition", "edition"], p.edition)
    p.level = numberOf(text, @["Info.Level", "level"])
    into.add p
  result = ""

proc controlPortPath*(root: string): string =
  ## Where the backend publishes the plain-HTTP control port. `root` is the
  ## install root, and the backend's own `--root` is `<root>\aowlspt`, which is
  ## also where it writes its log.
  joinPath(root, "aowlspt\\aowlspt-control.json")

proc controlPort*(root: string; why: var string): int =
  ## The plain-HTTP port carrying `/aowlspt/*`, or 0.
  ##
  ## This exists because the launcher's HTTP client is plain-only and the client
  ## needs HTTPS: over TLS every launcher route was unreachable, permanently,
  ## and the profile list silently degraded to the on-disk store -- which cannot
  ## create a profile. The backend now publishes the port of its plain listener;
  ## this reads it.
  ##
  ## The file is READ but not TRUSTED. A backend that was killed leaves it
  ## behind, and a stale port that happens to be answering is exactly the
  ## confidently-wrong answer this whole file is written to avoid -- so the port
  ## is probed with `answers`, which asks the tarkov mod's own selfcheck route,
  ## and a port that does not answer is reported as no control port at all.
  ##
  ## `why` is always set to a sentence naming what was tried, success or not,
  ## so a caller never has to invent one.
  why = ""
  let p = controlPortPath(root)
  var text = ""
  if not readShared(p, text):
    why = "there is no " & p & ", so the backend published no plain-HTTP " &
          "control port (it writes one as soon as its plain listener is up)"
    return 0
  var v = ""
  if not pathGet(text, "port", v):
    why = p & " carries no \"port\", so it is not a control file this " &
          "launcher understands"
    return 0
  var n = 0
  var any = false
  for ch in v:
    if ch >= '0' and ch <= '9':
      n = n * 10 + (ord(ch) - ord('0'))
      any = true
  if not any or n <= 0 or n > 65535:
    why = p & " names port \"" & v & "\", which is not a port"
    return 0
  let a = answers(n)
  if a == 1:
    why = "the backend's plain-HTTP control port is 127.0.0.1:" & $n &
          " (from " & p & ")"
    return n
  if a < 0:
    why = "127.0.0.1:" & $n & " is named in " & p & " but no socket could be " &
          "opened at all to ask it anything"
  else:
    why = "127.0.0.1:" & $n & " is named in " & p & " but nothing answered " &
          "there, so that file is stale or the listener is gone"
  result = 0

proc listProfiles*(port: int; root: string): ProfileList =
  ## The route first, the store when there is no route, and a plain statement
  ## of which happened either way.
  result = ProfileList(source: psNone, items: @[], note: "", error: "")
  # `port <= 0` means the caller already established there is no control port,
  # and said why. Dialling it anyway would produce "nothing is listening on
  # 127.0.0.1:0", which names a port that was never a port and buries the real
  # reason under a socket error.
  var r = Reply(ok: false, status: 0, body: "",
                error: "there is no plain-HTTP control port to ask")
  if port > 0:
    r = call(port, "GET", "/aowlspt/tarkov/launcher/profiles", "", ProbeSession)
  if r.ok and r.status == 200:
    var err = ""
    if not okEnvelope(r.body, err):
      result.error = "the backend refused the profile list: " & err
      return
    var items: seq[string] = @[]
    if not pathItems(r.body, "profiles", items):
      result.error = "the profile list carried no \"profiles\" array"
      return
    var skipped = 0
    for it in items:
      var p = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                      edition: "", lastPlayed: 0)
      if parseProfile(it, p): result.items.add p
      else: inc skipped
    result.source = psRoute
    if skipped > 0:
      result.note = $skipped & " entr" & (if skipped == 1: "y" else: "ies") &
                    " in the profile list carried no usable 24-character id " &
                    "and were left out rather than guessed at"
    return
  # Everything below is a degradation, and every branch says what it is.
  var why = ""
  if not r.ok:
    why = r.error
  elif r.status == 404:
    why = "this backend has no profile-list route (404)"
  else:
    why = "the profile-list route answered " & $r.status
  var fromStore: seq[Profile] = @[]
  let storeErr = profilesFromStore(root, fromStore)
  if storeErr.len > 0:
    result.error = why & ", and " & storeErr
    return
  result.source = psStore
  result.items = fromStore
  result.note = why & ", so the list was read from " & storeProfileDir(root) &
                " instead. Creating a profile needs the route."

proc jsonQuoted(s: string): string =
  result = "\""
  for ch in s:
    if ch == '"': result.add "\\\""
    elif ch == '\\': result.add "\\\\"
    elif ch < ' ': result.add " "
    else: result.add ch
  result.add "\""

proc tokenAndRow(body: string; into: var Profile): bool =
  ## The shared shape of `create` and `select`: `{"ok":true,"token":"<24 hex>",
  ## "profile":<row>}`. The row is the source of truth; the top-level `token`
  ## is the fallback for a server that answered a token without a row. False
  ## only when neither yields a usable id.
  into = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                 edition: "", lastPlayed: 0)
  let row = rowUnder(body, "profile")
  if row.len > 0 and parseProfile(row, into):
    # The top-level token wins over the row's when both are present: it is the
    # one the route names as the thing to launch with.
    var tok = ""
    if firstOf(body, @["token"], tok) and isHexId(tok):
      into.token = tok
    return true
  # No usable row -- stand the profile up from the top-level token alone.
  var tok = ""
  if firstOf(body, @["token"], tok) and isHexId(tok):
    into.id = tok
    into.token = tok
    return true
  result = false

proc createProfile*(port: int; nickname, side: string; into: var Profile): string =
  ## Returns "" on success. The message on failure is the server's own where
  ## there is one -- "that nickname is taken" is worth more than "create
  ## failed", and the emulator already writes it.
  into = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                 edition: "", lastPlayed: 0)
  if port <= 0:
    return "there is no plain-HTTP control port, so a profile cannot be " &
           "created from here. See the control-port line above for what was " &
           "tried."
  let body = "{\"nickname\":" & jsonQuoted(nickname) & ",\"side\":" &
             jsonQuoted(side) & "}"
  let r = call(port, "POST", "/aowlspt/tarkov/launcher/profile/create", body,
               ProbeSession)
  if not r.ok:
    return r.error
  if r.status == 404:
    return "this backend has no profile-create route (404), so a profile " &
           "cannot be created from here. Start the game with an existing " &
           "profile, or create one in the client."
  if r.status != 200:
    return "the profile-create route answered " & $r.status
  var err = ""
  if not okEnvelope(r.body, err):
    return err
  if not tokenAndRow(r.body, into):
    return "the server accepted the profile and answered no token for it, so " &
           "there is nothing to start the game with"
  if into.nickname.len == 0: into.nickname = nickname
  if into.side.len == 0: into.side = side
  result = ""

proc selectProfile*(port: int; id: string; into: var Profile): string =
  ## Rebinds the launcher's session to `id` and hands back the token to launch
  ## with. Called before launch even for a profile that was just listed, because
  ## it is the rebind that makes the session the client will arrive on point at
  ## this profile -- and the launch token is whatever this returns, not the id
  ## the launcher happened to hold. Returns "" on success, a sentence otherwise.
  into = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                 edition: "", lastPlayed: 0)
  if port <= 0:
    return "there is no plain-HTTP control port, so the session cannot be " &
           "bound to this profile from here"
  let body = "{\"id\":" & jsonQuoted(id) & "}"
  let r = call(port, "POST", "/aowlspt/tarkov/launcher/profile/select", body,
               ProbeSession)
  if not r.ok:
    return r.error
  if r.status == 404:
    return "this backend has no profile-select route (404)"
  if r.status != 200:
    return "the profile-select route answered " & $r.status
  var err = ""
  if not okEnvelope(r.body, err):
    return err
  if not tokenAndRow(r.body, into):
    return "the server selected the profile but answered no token to launch with"
  result = ""

# ---------------------------------------------------------------------------
# The "last played" marker
# ---------------------------------------------------------------------------
#
# The launcher auto-selects a profile rather than asking, and with more than one
# profile in the install "which one" has to be answered from something. Nothing
# on the wire answers it: the launcher's profile row carries `registered`, which
# is a creation date, and the emulator does not record a last-login stamp on the
# profile document. So the launcher records its own, next to `backend.json`, at
# the moment it binds a profile for a launch.
#
# It is a *hint*, not state: a missing, unreadable or stale marker only changes
# which profile the auto-select lands on, never whether the launch is bound at
# all. That is why nothing here fails loudly -- a marker that could break a
# launch would be worse than no marker.

proc lastProfilePath*(root: string): string =
  joinPath(root, "aowlspt\\launcher-last-profile.txt")

proc readLastProfile*(root: string): string =
  ## The profile id this launcher last started the game on, or "" when there is
  ## none on record or what is on record is not an id.
  result = ""
  var text = ""
  if not readTextFile(lastProfilePath(root), text):
    return ""
  let id = strip(text)
  if isHexId(id): result = id

proc noteLastProfile*(root, id: string) =
  ## Records `id` as the profile to prefer next time. Best-effort on purpose:
  ## see above.
  if not isHexId(id): return
  discard ensureDir(joinPath(root, "aowlspt"))
  discard writeTextFile(lastProfilePath(root), id & "\n")

# ---------------------------------------------------------------------------
# `launchProfileId` -- telling the HOST which profile the launcher bound
# ---------------------------------------------------------------------------
#
# The host DLL cannot see the launcher's choice. It is passed to the CLIENT as
# `-token=<session>`, and a session token is not a profile id -- the host has no
# route from one to the other, because that mapping lives in the backend.
#
# The `uxSkipModeScreen` feature needs the PROFILE id specifically: it compares
# it against `CharacterSelectionProfileData.ProfileId` on each slot the game's
# selection screen shows, and Submits the slot that matches. So the launcher
# writes the id it bound into `aowlspt-host.json`, beside the DLL, where the
# host already reads its other settings from.
#
# Written on EVERY launch, including as an explicit empty string when no profile
# was bound. That is the important half: a STALE id left over from a previous
# boot would have the host select a profile the current session is not bound to,
# which is a worse failure than not skipping at all. Clearing is not optional.

proc hostConfigPath*(root: string): string =
  joinPath(root, "aowlspt\\aowlspt-host.json")

proc noteLaunchProfileId*(root, id: string): bool =
  ## Records `id` as `launchProfileId` in `aowlspt-host.json`. Pass "" to clear
  ## it. Returns false if the file could not be written, so the caller can say
  ## so -- unlike `noteLastProfile`, this one is NOT purely a hint: a launch that
  ## silently failed to record its profile will show the mode screen the user
  ## asked never to see, and that deserves a word rather than a shrug.
  ##
  ## A shallow key rewrite, deliberately matching the shallow key READ the host
  ## does (`readStrKey` in `aowlhost.nim`). Neither side drags in a JSON parser
  ## for a flat file of scalars, and a parser here would additionally reformat a
  ## file a human edits by hand.
  let path = hostConfigPath(root)
  let value = (if isHexId(id): id else: "")
  var text = ""
  if not readTextFile(path, text):
    # No config yet: create a minimal one rather than failing. The host treats
    # every absent key as its default, so a file with only this key is valid.
    discard ensureDir(joinPath(root, "aowlspt"))
    return writeTextFile(path,
      "{\n  \"launchProfileId\": \"" & value & "\"\n}\n").ok

  let needle = "\"launchProfileId\""
  let at = find(text, needle)
  if at < 0:
    # Insert after the opening brace, preserving everything else byte for byte.
    let brace = find(text, "{")
    if brace < 0:
      return writeTextFile(path,
        "{\n  \"launchProfileId\": \"" & value & "\"\n}\n").ok
    var outp = text[0 .. brace]
    outp.add "\n  \"launchProfileId\": \"" & value & "\","
    outp.add text[brace + 1 .. text.high]
    return writeTextFile(path, outp).ok

  # Replace the existing quoted value in place. Capped scans throughout: a file
  # with an unterminated quote must not become an unbounded walk.
  var i = at + needle.len
  var guard = 0
  while i < text.len and (text[i] == ' ' or text[i] == ':' or
                          text[i] == '\t') and guard < 64:
    inc i
    inc guard
  if i >= text.len or text[i] != '"':
    # The key is there but its value is not a quoted string. Leave the file
    # alone rather than guessing at what to rewrite, and say the write failed.
    return false
  let vStart = i + 1
  var j = vStart
  guard = 0
  while j < text.len and text[j] != '"' and guard < 512:
    inc j
    inc guard
  if j >= text.len or text[j] != '"':
    return false
  var outp = text[0 ..< vStart]
  outp.add value
  outp.add text[j .. text.high]
  return writeTextFile(path, outp).ok

proc autoProfile*(list: ProfileList; lastId: string; chosen: var Profile;
                  reason: var string): bool =
  ## Which profile to play when nobody is being asked.
  ##
  ## The order is "the one you played last, then the one you most recently
  ## made, then the furthest along" -- each step a fact on record rather than a
  ## preference, so the same install picks the same character every boot. An
  ## unreadable profile is never auto-selected: it is a character the player
  ## would be dropped into with no inventory, and it is exactly the case the
  ## picker exists to let them choose *against*.
  chosen = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                   edition: "", lastPlayed: 0)
  reason = ""
  var usable: seq[Profile] = @[]
  for p in list.items:
    if p.id.len > 0: usable.add p
  if usable.len == 0:
    reason = "there are no profiles in this install yet"
    return false
  if lastId.len > 0:
    for p in usable:
      if p.id == lastId:
        chosen = p
        reason = "the profile you played last"
        return true
  var best = usable[0]
  var many = usable.len > 1
  for i in 1 ..< usable.len:
    let p = usable[i]
    if p.lastPlayed > best.lastPlayed or
       (p.lastPlayed == best.lastPlayed and p.level > best.level):
      best = p
  chosen = best
  reason = if many: "the most recent of " & $usable.len & " profiles"
           else: "the only profile in this install"
  result = true

# ---------------------------------------------------------------------------
# The client's command line
# ---------------------------------------------------------------------------

proc clientCommandLine*(backendUrl, token, extra: string): string =
  ## What SPT's own launcher passes, and therefore what the client parses.
  ## Taken from `SPT_Runtime\user\logs\Launcher.log`:
  ##
  ##   -force-gfx-jobs native -token=<24 hex>
  ##   -config={'BackendUrl':'https://127.0.0.1:6969','Version':'live',
  ##            'MatchingVersion':'live'}
  ##
  ## The **single quotes inside `-config` are not a typo and not a shell
  ## artefact**: that is the literal text the client is handed, and it parses it
  ## itself. Double quotes there would have to be escaped through
  ## `CreateProcess`'s own quoting rules, and the result is a config the client
  ## reads as empty -- which shows up as a game that starts, reaches the menu
  ## and talks to nothing.
  ##
  ## `backendUrl` is passed through from `aowlspt\backend.json` verbatim rather
  ## than rebuilt from the port. That file is what the *client host* reads too,
  ## and two readers of one setting that reconstruct it differently is how a
  ## launcher and a game come to disagree about which server they are using.
  result = "-force-gfx-jobs native"
  if token.len > 0:
    result.add " -token=" & token
  result.add " -config={'BackendUrl':'" & backendUrl &
             "','Version':'live','MatchingVersion':'live'}"
  if extra.len > 0:
    result.add " " & extra

proc backendUrlOf*(root: string): string =
  ## `backendUrl` out of `aowlspt\backend.json`, or "" when it does not say.
  result = ""
  var cfg = ""
  if readTextFile(joinPath(root, "aowlspt\\backend.json"), cfg):
    var url = ""
    if pathGet(cfg, "backendUrl", url):
      result = url

# ---------------------------------------------------------------------------
# Scheme and port out of the backend url
# ---------------------------------------------------------------------------
#
# The post-1.0 client always talks HTTPS on a hardcoded 443, so what the url
# says the launcher has to read the same way the client and the backend do:
# the scheme decides plain-vs-TLS, and an explicit `:<port>` after the host is
# the only thing that overrides the per-scheme default. The rule this replaced
# took "the last run of digits in the string", which for `https://127.0.0.1/`
# read the `1` out of the address and called it a port -- a launcher that then
# started a backend on port 1 and told nobody.

const
  DefaultHttpPort* = 6969
    ## Plain HTTP keeps the port it always had.
  TlsPort* = 443
    ## What a real post-1.0 client talks HTTPS on, and does not let the url
    ## change: its own regex stops the url at the first colon, so any `:<port>`
    ## an https url carries is ignored and the request goes to 443 regardless.

type
  BackendCfg* = object
    found*: bool          ## a backendUrl was present in backend.json
    url*: string          ## the url as written (may be "")
    https*: bool          ## the scheme is https, i.e. TLS
    explicitPort*: bool   ## the url named a `:<port>` after the host
    port*: int            ## resolved: the explicit port, else 443 (https) /
                          ## 6969 (http)

proc parseBackendUrl*(url: string): BackendCfg =
  ## Split a backendUrl into scheme and port. `https://127.0.0.1/` is TLS on
  ## 443; `http://127.0.0.1:6970` is plain on 6970; an explicit `:<port>` after
  ## the host wins over the per-scheme default. A url with no scheme is read as
  ## plain http on whatever it names, for the dev/test loopback case.
  result = BackendCfg(found: url.len > 0, url: url, https: false,
                      explicitPort: false, port: DefaultHttpPort)
  var rest = url
  if startsWith(rest, "https://"):
    result.https = true
    rest = rest.substr(len("https://"))
  elif startsWith(rest, "http://"):
    result.https = false
    rest = rest.substr(len("http://"))
  # The host is everything up to the first slash. The port, if any, is the run
  # of digits after a colon in *that* -- never a colon in the path, which is
  # why the slash is cut off first.
  let slash = find(rest, "/")
  var hostPart = rest
  if slash >= 0: hostPart = rest.substr(0, slash - 1)
  let colon = find(hostPart, ":")
  if colon >= 0:
    var v = 0
    var any = false
    var i = colon + 1
    while i < hostPart.len and hostPart[i] >= '0' and hostPart[i] <= '9':
      v = v * 10 + (ord(hostPart[i]) - ord('0'))
      any = true
      inc i
    if any and v > 0 and v < 65536:
      result.explicitPort = true
      result.port = v
      return
  result.port = (if result.https: TlsPort else: DefaultHttpPort)

proc readBackendConfig*(root: string): BackendCfg =
  ## `parseBackendUrl` over the url in `aowlspt\backend.json`. `found` is false
  ## when the file or the key is missing, and the caller decides the default.
  let url = backendUrlOf(root)
  if url.len == 0:
    return BackendCfg(found: false, url: "", https: false,
                      explicitPort: false, port: DefaultHttpPort)
  result = parseBackendUrl(url)
