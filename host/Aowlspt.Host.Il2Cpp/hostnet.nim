# ---------------------------------------------------------------------------
# hostnet.nim -- TWO GENERIC HOST VERBS: `http` and `play_wav`.
#
# WHAT THIS IS. Two services the host did not have and that no mod can build
# for itself without emitting its own C:
#
#   call("aowlspt.host::http", <json>)       async outbound HTTP (WinHTTP)
#   call("aowlspt.host::http_poll", <json>)  ask about one request by id
#   call("aowlspt.host::play_wav", <json>)   fire-and-forget .wav playback
#
# MEASURED 2026-09-06, and it is the reason this file exists: the client host
# had NO HTTP client at all. A grep of host/Aowlspt.Host.Il2Cpp for WinHttp /
# InternetOpen / WinINet / curl found nothing but the image-CDN ws2_32 redirect
# hook in `aowlhost.nim`. A client-side mod could serve a settings page and read
# the command line, but it could not ask `aowlspt-backend` a single question.
#
# GENERIC ON PURPOSE. Neither verb knows what it is carrying. There is no route
# name here, no schema, no feature, no mod. The host owns transport and safety;
# mods own features (`docs/MODDING.md`, and the standing rule "mods own
# features; host stays generic"). If a future edit to this file mentions a
# particular mod or a particular URL path, that edit is in the wrong file.
#
# ---------------------------------------------------------------------------
# WHERE THE COMPLETION IS EMITTED, AND WHY IT IS NOT THE WORKER THREAD
# ---------------------------------------------------------------------------
#
# The request runs on a worker thread created by `aowl_hn_submit`. The
# COMPLETION EVENT (`host.http.done`) is NOT emitted there. It is queued in the
# C slot table and emitted from the host's own 16 ms tick loop in `hostMain`,
# through `hostEmit`, on the host thread.
#
# That is not caution, it is a measured constraint. `aowlspt_nim_event_emit`
# (aowlhost.nim) says so itself: delivery is *"synchronous, and on whatever
# thread emitted"*. `deliverEvent` walks `gSubs` and CALLS each subscriber's
# callback inline. So emitting from a worker would run arbitrary mod code:
#
#   * on a thread that did not exist when the mod was loaded and that the mod
#     has never seen -- while its own ops thread may be inside the same
#     handler, on the same mod state, with no lock between them;
#   * on a thread with none of the host's per-thread state set up;
#   * and, worst, on a thread mimalloc did not see the mod initialise on. That
#     exact shape is already in the record: CLAUDE.md section 1 documents a
#     `__fastfail` (0xc0000409) that wrote NO Unity crash report at all, caused
#     by "mimalloc's thread-ownership assertion in a mod ticked on a different
#     thread than it was initialised on". A dead client with no crash folder is
#     the most expensive failure this project produces.
#
# So the worker's only interaction with the rest of the host is: fill a slot,
# set `done` last, under the slot table's own critical section. The tick loop
# calls `hnTakeCompletion()` (below) every 16 ms, which is `aowl_hn_take_done`
# -- one interlocked compare when nothing has ever been submitted -- and hands
# what it gets to `hostEmit`, at most `HnDrainPerTick` of them per tick.
#
# `http_poll` exists for a mod that would rather not subscribe at all. It reads
# the same slot under the same lock and COPIES the body out, so a poller never
# holds a pointer this side can free.
#
# ---------------------------------------------------------------------------
# THE EIGHT LIVE-PATH RULES, and which apply
# ---------------------------------------------------------------------------
#
# Rules 1 and 2 (prologue byte-verify, VirtualQuery every hop) do not apply and
# saying so is part of the argument: NOTHING here touches game memory. No
# il2cpp export is called, no name is resolved, no RVA is called, no detour is
# installed, no pointer that came from the game is dereferenced. Both verbs are
# answered ABOVE the `gReady` gate for the same reason `cmdline` and
# `raid_phase` are -- the answer is meaningful with no runtime at all.
#
# Rule 3 (exactly one `aowl_p_p_seh`): there is none, and that is deliberate.
# The guard exists for faulting reads of a moving managed heap; adding one to a
# path that only touches its own statics and Win32 would be cargo cult, and
# actively harmful -- the guard is NOT re-entrant, so a guard taken here inside
# a caller's guard would DISARM the caller's.
#
# Rule 4 (capped iteration): every loop in this file and in
# `abi/aowlspt_hostnet.h` is bounded by a compile-time constant -- 8 slots, 16
# allowlist entries, a bounded JSON scan, a bounded drain per tick.
#
# Rule 5 (flag-gated, default OFF): `hostHttp` and `hostPlayWav`, both default
# false. With the flag off the verb still ANSWERS -- `{"accepted":false,
# "why":"flag hostHttp is off"}` -- because a refusal is an answer and silence
# is the worst outcome we produce.
#
# Rule 6 (self-disable after N faults): there is no fault path to count. What
# there is instead is a cap on every resource -- inflight, body size, timeout,
# slot retention -- each of which REFUSES rather than degrades.
#
# Rule 7 (no per-frame managed allocation): the tick drain allocates only when
# a request has actually completed, which is at human rates. On an idle tick it
# is one `InterlockedCompareExchange` and a return.
#
# Rule 8 (never blind-write): nothing here writes to the game at all.
# ---------------------------------------------------------------------------

{.emit: """#include "aowlspt_hostnet.h" """.}
{.emit: """#include "aowlspt_playwav.h" """.}

proc cHnConfigure(enabled, maxInflight, maxBody: int32) {.
  importc: "aowl_hn_configure", nodecl.}
proc cHnAllowReset() {.importc: "aowl_hn_allow_reset", nodecl.}
proc cHnAllowAdd(host: cstring): int32 {.importc: "aowl_hn_allow_add", nodecl.}
proc cHnAllowCount(): int32 {.importc: "aowl_hn_allow_count", nodecl.}
proc cHnSubmit(id, meth, url, body: cstring; bodyLen, timeoutMs: int32;
               why: cstring; whyCap: int32): int32 {.
  importc: "aowl_hn_submit", nodecl.}
proc cHnTakeDone(idOut: cstring; idCap: int32): int32 {.
  importc: "aowl_hn_take_done", nodecl.}
proc cHnResult(id: cstring; bodyOut: cstring; bodyCap: int32;
               status, ms: ptr int32; errOut: cstring; errCap: int32;
               bodyLen: ptr int32): int32 {.importc: "aowl_hn_result", nodecl.}
proc cHnStats(inflight, allowN, maxBody, maxInflight, enabled: ptr int32) {.
  importc: "aowl_hn_stats", nodecl.}
proc cHnApiOk(): int32 {.importc: "aowl_hn_api_ok", nodecl.}

proc cPwPlay(path: cstring; why: cstring; whyCap: int32): int32 {.
  importc: "aowl_pw_play_path", nodecl.}
proc cPwExpand(s: cstring; outp: cstring; cap: int32): int32 {.
  importc: "aowl_pw_expand", nodecl.}
proc cPwPlayed(): int64 {.importc: "aowl_pw_played", nodecl.}
proc cPwRefused(): int64 {.importc: "aowl_pw_refused", nodecl.}

const
  HnIdCap = 63              ## must stay under AOWL_HN_ID_CAP in the header
  HnWhyCap = 512
  HnBodyCap = 1048576       ## 1 MiB: the ceiling this side will COPY OUT
  HnValueCap = 1048576      ## longest JSON string value this side will read
  HnDrainPerTick = 4        ## completions emitted per 16 ms tick, capped
  HnRootsMax = 8

var gHnOn = false             ## flag `hostHttp`
var gHnAllow: seq[string] = @[]
var gHnMaxInflight = 4
var gHnMaxBody = HnBodyCap
var gHnEmitted = 0
var gHnSubmitted = 0
var gHnRefused = 0

var gPwOn = false             ## flag `hostPlayWav`
var gPwRoots: seq[string] = @[]
var gPwCalls = 0

# ---------------------------------------------------------------------- json

proc hnEsc(s: string): string =
  ## JSON escaping for a value we are about to put INSIDE a payload a mod will
  ## parse. Unlike `caEsc` this also escapes DEL and keeps control bytes as
  ## `\uXXXX`-free but valid text: an HTTP body is arbitrary bytes, and a body
  ## that breaks the enclosing document reads to the mod as "the host answered
  ## nothing", which is the failure this whole file is trying not to have.
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c == '"': result = result & "\\\""
    elif c == '\\': result = result & "\\\\"
    elif c == '\n': result = result & "\\n"
    elif c == '\r': result = result & "\\r"
    elif c == '\t': result = result & "\\t"
    elif ord(c) < 0x20: result = result & " "
    else: result = result & c

proc hnJsonStr(src, key: string): string =
  ## The value of `"key": "..."`, WITH escapes decoded.
  ##
  ## `caJsonStr` in `cmdargs.nim` exists and is not reused here for two
  ## measured reasons: it caps values at 256 characters (`CaMaxValue`), which
  ## silently truncates a request body, and its escape handling drops the
  ## backslash and keeps the next character verbatim -- so `\n` becomes the
  ## letter `n`. Both are fine for a command-line token and wrong for a POST
  ## body. Truncation is exactly the class of bug section 9b is about, so this
  ## one refuses instead: a value longer than `HnValueCap` returns "" and the
  ## caller reports a refusal.
  result = ""
  let pat = "\"" & key & "\""
  var i = 0
  var at = -1
  while i + pat.len <= src.len:
    var m = true
    for k in 0 ..< pat.len:
      if src[i + k] != pat[k]: m = false
    if m:
      at = i
      break
    i = i + 1
  if at < 0: return ""
  var j = at + pat.len
  while j < src.len and (src[j] == ' ' or src[j] == ':' or src[j] == '\t'):
    j = j + 1
  if j >= src.len or src[j] != '"': return ""
  j = j + 1
  var acc = ""
  var n = 0
  while j < src.len and src[j] != '"' and n <= HnValueCap:
    if src[j] == '\\' and j + 1 < src.len:
      let e = src[j + 1]
      if e == 'n': acc = acc & "\n"
      elif e == 'r': acc = acc & "\r"
      elif e == 't': acc = acc & "\t"
      elif e == 'b' or e == 'f': acc = acc & " "
      elif e == 'u':
        # A \uXXXX escape is not decoded here; it is passed through verbatim so
        # the far end sees exactly what the mod wrote. Decoding half of UTF-16
        # into a byte string is how mojibake happens.
        acc = acc & "\\u"
        j = j + 2
        var k = 0
        while k < 4 and j < src.len:
          acc = acc & src[j]
          j = j + 1
          k = k + 1
          n = n + 1
        continue
      else: acc = acc & e
      j = j + 2
      n = n + 1
      continue
    acc = acc & src[j]
    j = j + 1
    n = n + 1
  if n > HnValueCap: return ""
  if j >= src.len or src[j] != '"': return ""
  result = acc

proc hnJsonInt(src, key: string; def: int): int =
  ## `"key": 1234`. Returns `def` when absent or not a run of digits.
  result = def
  let pat = "\"" & key & "\""
  var i = 0
  var at = -1
  while i + pat.len <= src.len:
    var m = true
    for k in 0 ..< pat.len:
      if src[i + k] != pat[k]: m = false
    if m:
      at = i
      break
    i = i + 1
  if at < 0: return def
  var j = at + pat.len
  while j < src.len and (src[j] == ' ' or src[j] == ':' or src[j] == '\t'):
    j = j + 1
  var v = 0
  var any = false
  var guard = 0
  while j < src.len and src[j] >= '0' and src[j] <= '9' and guard < 12:
    v = v * 10 + (ord(src[j]) - ord('0'))
    any = true
    j = j + 1
    guard = guard + 1
  if any: result = v

proc hnLower(s: string): string =
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result = result & chr(ord(c) + 32)
    else: result = result & c

proc hnCBuf(n: int): seq[char] =
  result = newSeq[char](n)
  for i in 0 ..< n: result[i] = '\0'

proc hnFromBuf(buf: seq[char]): string =
  ## A NUL-terminated C buffer -> a Nim string, bounded by the buffer.
  result = ""
  var i = 0
  while i < buf.len and buf[i] != '\0':
    result = result & buf[i]
    i = i + 1

# --------------------------------------------------------------- the config

proc hnApplyConfig(httpOn: bool; allow: seq[string]; maxInflight, maxBody: int;
                   wavOn: bool; roots: seq[string]) =
  ## Called ONCE from the host's own boot, on the host thread, before any mod
  ## exists. Everything after that only reads.
  gHnOn = httpOn
  gPwOn = wavOn
  gHnAllow = @[]
  gHnMaxInflight = maxInflight
  if gHnMaxInflight < 1: gHnMaxInflight = 1
  if gHnMaxInflight > 8: gHnMaxInflight = 8
  gHnMaxBody = maxBody
  if gHnMaxBody < 4096: gHnMaxBody = 4096
  # CLAMPED to what this side is willing to copy out in one go. The C side
  # would accept 8 MiB; a single reply that big inside a game process is a
  # different decision from "the host can do HTTP", so it is not taken here.
  if gHnMaxBody > HnBodyCap: gHnMaxBody = HnBodyCap
  cHnConfigure(if httpOn: 1'i32 else: 0'i32, int32(gHnMaxInflight),
               int32(gHnMaxBody))
  cHnAllowReset()
  var i = 0
  while i < allow.len and i < 16:
    if allow[i].len > 0:
      # A `var` copy because nimony's `toCString` takes its argument by `var`
      # (it hands out an interior pointer, so it will not do that for a
      # temporary or a `let`). Copying is also the honest thing here: the C
      # side keeps its own copy of the host name anyway.
      var one = allow[i]
      if cHnAllowAdd(toCString(one)) != 0'i32:
        gHnAllow.add allow[i]
    i = i + 1

  gPwRoots = @[]
  var r = 0
  while r < roots.len and r < HnRootsMax:
    if roots[r].len > 0:
      var buf = hnCBuf(1024)
      var rootIn = roots[r]
      let n = cPwExpand(toCString(rootIn), cast[cstring](addr buf[0]), 1024'i32)
      if n > 0:
        gPwRoots.add hnFromBuf(buf)
      else:
        # An unexpandable root is NOT silently dropped: a root list that
        # quietly lost an entry is a play_wav that refuses a legitimate path
        # with no reason anybody can see.
        warn "hostPlayWav: the root " & roots[r] & " could not be expanded " &
             "(ExpandEnvironmentStrings refused it or the result is longer " &
             "than 1023 characters), so paths under it will be REFUSED"
    r = r + 1

proc hnBootLog() =
  ## One line each, at boot, whether on or off -- a feature that declines
  ## silently is the worst outcome we produce.
  if gHnOn:
    if cHnApiOk() == 0'i32:
      warn "hostHttp is ON but winhttp.dll did not resolve, so " &
           "`aowlspt.host::http` will refuse every request by name. Nothing " &
           "else changes."
    else:
      var allowTxt = ""
      for i in 0 ..< gHnAllow.len:
        if i > 0: allowTxt = allowTxt & ", "
        allowTxt = allowTxt & gHnAllow[i]
      if gHnAllow.len == 0:
        warn "hostHttp is ON but the allowlist is EMPTY, so every host is " &
             "refused. Set hostHttpAllow in aowlspt-host.json."
      else:
        okLog "hostHttp is ON: `aowlspt.host::http` will reach [" & allowTxt &
              "], at most " & $gHnMaxInflight & " in flight, bodies capped " &
              "at " & $gHnMaxBody & " bytes (REFUSED over, never truncated). " &
              "Requests run on their own worker thread; completions are " &
              "emitted as `host.http.done` from the host's own tick, never " &
              "from the worker."
  else:
    info "hostHttp is OFF: `aowlspt.host::http` answers " &
         "{\"accepted\":false,\"why\":\"flag hostHttp is off\"} rather than " &
         "nothing. Nothing is loaded and no thread is created."
  if gPwOn:
    var rootTxt = ""
    for i in 0 ..< gPwRoots.len:
      if i > 0: rootTxt = rootTxt & ", "
      rootTxt = rootTxt & gPwRoots[i]
    if gPwRoots.len == 0:
      warn "hostPlayWav is ON but hostPlayWavRoots expanded to nothing, so " &
           "every path is refused."
    else:
      okLog "hostPlayWav is ON: `aowlspt.host::play_wav` will play PCM .wav " &
            "files under [" & rootTxt & "]. NON-SPATIAL (winmm PlaySoundW) " &
            "and the `volume` argument is IGNORED -- see docs/VOICE_RVA.md " &
            "for the Unity AudioSource path that would give either."
  else:
    info "hostPlayWav is OFF: `aowlspt.host::play_wav` refuses by name."

# ------------------------------------------------------------- the verb: http

proc hnHttpVerb(argText: string): string =
  ## `call("aowlspt.host::http", {"id":..,"method":..,"url":..,"body":..,
  ##                              "timeoutMs":..})`
  ##
  ## Returns IMMEDIATELY. Never blocks the caller, whichever thread it is on.
  if not gHnOn:
    return "{\"accepted\":false,\"why\":\"flag hostHttp is off\"}"
  let id = hnJsonStr(argText, "id")
  if id.len == 0 or id.len > HnIdCap:
    return "{\"accepted\":false,\"why\":\"the args need an `id` of 1.." &
           $HnIdCap & " characters; it is the caller's token and every " &
           "answer is keyed by it\"}"
  var meth = hnJsonStr(argText, "method")
  if meth.len == 0: meth = "GET"
  let url = hnJsonStr(argText, "url")
  if url.len == 0:
    return "{\"accepted\":false,\"id\":\"" & hnEsc(id) &
           "\",\"why\":\"the args carry no `url` (or it was longer than this " &
           "verb accepts)\"}"
  let body = hnJsonStr(argText, "body")
  let timeoutMs = hnJsonInt(argText, "timeoutMs", 25000)
  var why = hnCBuf(HnWhyCap)
  # `var` copies for the same reason as in `hnApplyConfig`: `toCString` takes
  # its argument by `var`. The C side copies every one of these into its own
  # slot before `aowl_hn_submit` returns, so nothing here outlives the call.
  var idV = id
  var methV = meth
  var urlV = url
  var bodyV = body
  gHnSubmitted = gHnSubmitted + 1
  let okSub = cHnSubmit(toCString(idV), toCString(methV), toCString(urlV),
                        toCString(bodyV), int32(body.len), int32(timeoutMs),
                        cast[cstring](addr why[0]), int32(HnWhyCap))
  if okSub == 0'i32:
    gHnRefused = gHnRefused + 1
    var w = hnFromBuf(why)
    if w.len == 0: w = "refused, and the C side gave no reason -- report this"
    return "{\"accepted\":false,\"id\":\"" & hnEsc(id) & "\",\"why\":\"" &
           hnEsc(w) & "\"}"
  result = "{\"accepted\":true,\"id\":\"" & hnEsc(id) & "\"}"

proc hnResultJson(id: string; includeDone: bool): string =
  ## The shared body of `http_poll`'s answer and of the `host.http.done`
  ## payload. ONE builder, so the two can never disagree about a field -- the
  ## kind of drift that makes a mod's poll path and its event path behave
  ## differently for reasons nobody can find.
  var bodyBuf = hnCBuf(gHnMaxBody + 1)
  var status = 0'i32
  var ms = 0'i32
  var blen = 0'i32
  var errBuf = hnCBuf(256)
  var idV = id
  let rc = cHnResult(toCString(idV), cast[cstring](addr bodyBuf[0]),
                     int32(gHnMaxBody + 1), addr status, addr ms,
                     cast[cstring](addr errBuf[0]), 256'i32, addr blen)
  if rc < 0'i32:
    return "{\"id\":\"" & hnEsc(id) & "\",\"done\":false,\"known\":false," &
           "\"status\":0,\"body\":\"\",\"ms\":0,\"error\":\"no request with " &
           "that id: it was never submitted here, or its result aged out " &
           "(results are kept 120 s)\"}"
  if rc == 0'i32:
    return "{\"id\":\"" & hnEsc(id) & "\",\"done\":false,\"known\":true," &
           "\"status\":0,\"body\":\"\",\"ms\":0,\"error\":\"\"}"
  var doneField = ""
  if includeDone: doneField = "\"done\":true,\"known\":true,"
  result = "{\"id\":\"" & hnEsc(id) & "\"," & doneField &
           "\"status\":" & $int(status) &
           ",\"body\":\"" & hnEsc(hnFromBuf(bodyBuf)) & "\"" &
           ",\"bytes\":" & $int(blen) &
           ",\"ms\":" & $int(ms) &
           ",\"error\":\"" & hnEsc(hnFromBuf(errBuf)) & "\"}"

proc hnHttpPollVerb(argText: string): string =
  if not gHnOn:
    return "{\"done\":false,\"known\":false,\"error\":\"flag hostHttp is off\"}"
  let id = hnJsonStr(argText, "id")
  if id.len == 0:
    return "{\"done\":false,\"known\":false,\"error\":\"the args carry no " &
           "`id`\"}"
  result = hnResultJson(id, true)

proc hnTakeCompletion(): string =
  ## ONE finished request's `host.http.done` payload, or "" when there is
  ## none. Called from the host's OWN tick loop, on the host thread, which
  ## then hands it to `hostEmit`. See the banner: that split is the whole
  ## reason the worker thread does not emit anything itself.
  ##
  ## It is a `string` rather than a callback because `hostEmit` is defined
  ## further down `aowlhost.nim` than this file is included; a proc-typed
  ## parameter would work and would also put an indirect call on a path that
  ## runs every 16 ms for the whole session.
  ##
  ## On a build where the verb was never called this is one interlocked
  ## compare (`aowl_hn_take_done` returns before touching its lock when the
  ## critical section was never initialised) and a return -- so it costs
  ## nothing on the sessions that never make a request. The CALLER caps how
  ## many it takes per tick (`HnDrainPerTick`).
  result = ""
  if not gHnOn: return
  var idBuf = hnCBuf(HnIdCap + 1)
  if cHnTakeDone(cast[cstring](addr idBuf[0]), int32(HnIdCap + 1)) == 0'i32:
    return
  let id = hnFromBuf(idBuf)
  if id.len == 0: return
  gHnEmitted = gHnEmitted + 1
  result = hnResultJson(id, false)

proc hnStatusJson(): string =
  ## What `aowlspt.host::http` answers when given NO arguments at all: the
  ## state of the service, so a mod can find out whether asking is worth it
  ## instead of discovering the flag is off one refusal at a time.
  var inflight = 0'i32
  var allowN = 0'i32
  var maxBody = 0'i32
  var maxInflight = 0'i32
  var enabled = 0'i32
  cHnStats(addr inflight, addr allowN, addr maxBody, addr maxInflight,
           addr enabled)
  var allowTxt = ""
  for i in 0 ..< gHnAllow.len:
    if i > 0: allowTxt = allowTxt & ","
    allowTxt = allowTxt & "\"" & hnEsc(gHnAllow[i]) & "\""
  result = "{\"service\":\"http\",\"enabled\":" &
           (if enabled != 0'i32: "true" else: "false") &
           ",\"winhttp\":" & (if cHnApiOk() != 0'i32: "true" else: "false") &
           ",\"allow\":[" & allowTxt & "]" &
           ",\"inflight\":" & $int(inflight) &
           ",\"maxInflight\":" & $int(maxInflight) &
           ",\"maxBody\":" & $int(maxBody) &
           ",\"submitted\":" & $gHnSubmitted &
           ",\"refused\":" & $gHnRefused &
           ",\"emitted\":" & $gHnEmitted &
           ",\"event\":\"host.http.done\"}"

# --------------------------------------------------------- the verb: play_wav

proc hnUnderRoot(path: string): bool =
  ## Case-insensitive prefix match against the EXPANDED roots, with `/`
  ## normalised to `\`. A `..` anywhere is refused outright rather than
  ## resolved: resolving it correctly needs the real filesystem, and a prefix
  ## check that can be walked out of is a check that cannot fail.
  if gPwRoots.len == 0: return false
  var norm = ""
  for i in 0 ..< path.len:
    if path[i] == '/': norm = norm & "\\"
    else: norm = norm & path[i]
  let low = hnLower(norm)
  for i in 0 ..< low.len - 1:
    if low[i] == '.' and low[i + 1] == '.': return false
  for r in 0 ..< gPwRoots.len:
    var rn = ""
    for i in 0 ..< gPwRoots[r].len:
      if gPwRoots[r][i] == '/': rn = rn & "\\"
      else: rn = rn & gPwRoots[r][i]
    var pre = hnLower(rn)
    while pre.len > 0 and pre[pre.len - 1] == '\\':
      pre = substr(pre, 0, pre.len - 2)
    if pre.len == 0: continue
    if low.len > pre.len and substr(low, 0, pre.len - 1) == pre and
       low[pre.len] == '\\':
      return true
  result = false

proc hnPlayWavVerb(argText: string): string =
  ## `call("aowlspt.host::play_wav", {"path":"..","volume":0.0-1.0})`
  ##
  ## NON-SPATIAL, and `volume` is IGNORED -- both stated in the answer, not
  ## only in a header nobody reads at 3am. See `abi/aowlspt_playwav.h` for why
  ## `waveOutSetVolume` is not "trivially safe" (it moves the whole output
  ## DEVICE's level, i.e. the game's), and `docs/VOICE_RVA.md` for the Unity
  ## `AudioSource` step that would give real per-sound volume and position.
  gPwCalls = gPwCalls + 1
  if not gPwOn:
    return "{\"ok\":false,\"why\":\"flag hostPlayWav is off\"}"
  let path = hnJsonStr(argText, "path")
  if path.len == 0:
    return "{\"ok\":false,\"why\":\"the args carry no `path`\"}"
  if not hnUnderRoot(path):
    var rootTxt = ""
    for i in 0 ..< gPwRoots.len:
      if i > 0: rootTxt = rootTxt & ", "
      rootTxt = rootTxt & gPwRoots[i]
    if gPwRoots.len == 0:
      return "{\"ok\":false,\"why\":\"hostPlayWavRoots is empty (or nothing " &
             "in it expanded), so every path is refused\"}"
    return "{\"ok\":false,\"why\":\"that path is not under any of " &
           "hostPlayWavRoots [" & hnEsc(rootTxt) & "]; a `..` anywhere in " &
           "the path is refused outright rather than resolved\"}"
  var why = hnCBuf(HnWhyCap)
  var pathV = path
  let okPlay = cPwPlay(toCString(pathV), cast[cstring](addr why[0]),
                       int32(HnWhyCap))
  if okPlay == 0'i32:
    var w = hnFromBuf(why)
    if w.len == 0: w = "winmm refused it and gave no reason -- report this"
    return "{\"ok\":false,\"why\":\"" & hnEsc(w) & "\"}"
  result = "{\"ok\":true,\"spatial\":false,\"volumeIgnored\":true," &
           "\"note\":\"non-spatial winmm playback; `volume` is not applied " &
           "(see docs/VOICE_RVA.md for the Unity AudioSource step)\"," &
           "\"played\":" & $cPwPlayed() & "}"
