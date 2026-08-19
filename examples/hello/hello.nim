## The smallest mod that exercises every part of the ABI it can reach.
##
## Build:  aowl build-mod examples/hello
## Run:    aowl run examples/hello
##
## It works unchanged on the server, in the client, and in the simulator — the
## capabilities that exist on only one side are guarded by `side()`.

import std/strutils
import aowlspt

var tickCount = 0

proc onLoad(): Status =
  success "hello mod loaded on " & hostName() & " (side " & $ord(side()) & ")"

  let spt = sptVersion()
  if spt.len > 0:
    info "SPT " & spt

  # Routes are server-only; asking for one elsewhere answers ErrUnsupported
  # rather than failing the load.
  if side() == sideServer:
    let st = route("/aowlspt/hello", rkStatic,
      proc (url, body, session: string): string =
        info "hello route hit, session=" & session & " body=" & body
        # Echo the body back so a caller can see the request survived the round
        # trip: SPT compresses request and response, so "it returned 200" alone
        # does not prove the payload arrived intact.
        #
        # An empty body is spelled `null` rather than pasted in as nothing: a
        # GET arrives here with no body at all, and `"echo":` followed by the
        # closing brace is not JSON. The client parses what a route hands back,
        # so a malformed answer is an error at the caller with nothing here to
        # connect it to.
        """{"ok":true,"from":"nimony","echo":""" &
          (if body.len > 0: body else: "null") & "}")
    if st != Ok:
      warn "could not register route: " & lastError()

  # Events cross mods, so this is how two native mods talk without either one
  # knowing the other exists.
  discard on("aowlspt.ping",
    proc (payload: string): string =
      info "ping: " & payload
      """{"pong":true}""")

  discard emit("aowlspt.hello.ready", """{"version":"1.0.0"}""")
  Ok

proc onUpdate(elapsedMs: int64): Status =
  inc tickCount
  # Keep this cheap: it is on the main thread and a raid is running behind it.
  if tickCount mod 60 == 0:
    debug "tick " & $tickCount & " (+" & $elapsedMs & "ms)"
  Ok

proc onUnload(): Status =
  info "hello mod unloading after " & $tickCount & " ticks"
  Ok

# Hot reload: hand the tick count to the next incarnation so rebuilding
# mid-raid does not visibly reset the mod.
proc stateSave(): string =
  "{\"tickCount\":" & $tickCount & "}"

proc stateLoad(state: string): Status =
  const Key = "\"tickCount\":"
  let at = state.find(Key)
  if at >= 0:
    # Accumulated by hand rather than with parseInt: nimony marks parseInt
    # `.raises`, and a raising call has to sit inside a try/except. There is
    # nothing to recover from here — a malformed count just stays zero.
    var value = 0
    var i = at + Key.len
    var sawDigit = false
    while i < state.len and state[i] >= '0' and state[i] <= '9':
      value = value * 10 + (ord(state[i]) - ord('0'))
      sawDigit = true
      inc i
    if sawDigit:
      tickCount = value
      info "restored tickCount=" & $tickCount
  Ok

exportMod(
  guid = "aowl.hello",
  name = "Hello",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "~4.1.0",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload,
  stateSave = stateSave,
  stateLoad = stateLoad,
  flags = {mfHotReloadable})
