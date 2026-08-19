## aowloverlay -- the nimony face of the in-game overlay.
##
## The overlay itself is C, in `abi/aowlspt_overlay.h`, and it has to be: it
## walks a COM vtable, installs a detour whose target is a function pointer, and
## implements two detours with the DXGI calling convention. nimony refuses to
## `cast` between `pointer` and `proc` in either direction, which is the same
## reason `abi/aowlspt_shim.h` exists -- see the note at the top of that header.
## So this module is thin on purpose: it is the layer that lets the client host
## turn the overlay on and tell it what is loaded, and nothing else.
##
## Using it from `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` is three lines:
##
## ```nim
## import aowloverlay
##
## # ... after the mods are loaded, on the host's boot thread (never DllMain):
## if overlayStart(VkInsert, backendPort):
##   for m in mods: overlaySetMod(m.guid, m.name, m.version, true)
##   info "overlay: " & overlayStatus()
## else:
##   warn "overlay: " & overlayStatus()
## ```
##
## `overlayStart` returning false is not a reason to fail the host. An overlay
## that could not hook is a missing feature; a host that refuses to load because
## of it is a broken install. Log the status and carry on.

{.emit: """#include "aowlspt_overlay.h" """.}

type
  OvPtr* = pointer

const
  VkInsert* = 0x2D'i32
  VkF9* = 0x78'i32
  VkHome* = 0x24'i32

# --------------------------------------------------------------- C surface
#
# `nodecl` plus the `emit` above, rather than `{.compile.}`: the overlay is
# header-only static code, so the compiler must see the definitions in the same
# translation unit. This is the same shape every other C shim in this repo uses
# and the only one that works -- `{.compile: "x.c".}` leaves an implicit
# declaration at the call site.

proc cOvStart(toggleVk, backendPort: int32): int32 {.
  importc: "aowl_ov_start", nodecl.}
proc cOvStop() {.importc: "aowl_ov_stop", nodecl.}
proc cOvRunning(): int32 {.importc: "aowl_ov_running", nodecl.}
proc cOvVisible(): int32 {.importc: "aowl_ov_visible", nodecl.}
proc cOvSetVisible(on: int32) {.importc: "aowl_ov_set_visible", nodecl.}
proc cOvFrames(): int32 {.importc: "aowl_ov_frames", nodecl.}
proc cOvFrameNs(): int32 {.importc: "aowl_ov_frame_ns", nodecl.}
proc cOvFrameNsMax(): int32 {.importc: "aowl_ov_frame_ns_max", nodecl.}
proc cOvStatus(buf: ptr char; cap: int32): int32 {.
  importc: "aowl_ov_status", nodecl.}
proc cOvSetMod(guid, name, version: cstring; enabled: int32) {.
  importc: "aowl_ov_set_mod", nodecl.}
proc cOvClearMods() {.importc: "aowl_ov_clear_mods", nodecl.}
proc cOvSyncStart(path: cstring; intervalMs: int32) {.
  importc: "aowl_ov_sync_start", nodecl.}
proc cOvSyncPending(): int32 {.importc: "aowl_ov_sync_pending", nodecl.}
proc cOvSyncTake(buf: ptr char; cap: int32): int32 {.
  importc: "aowl_ov_sync_take", nodecl.}

# --------------------------------------------------------------- public

proc overlayStart*(toggleVk: int32 = VkInsert; backendPort: int32 = 0): bool =
  ## Captures the DXGI vtable, detours `Present` and `ResizeBuffers`, and starts
  ## the backend poll thread when `backendPort` is non-zero.
  ##
  ## Must not be called from `DllMain`. It creates a window, a D3D11 device and
  ## a thread, and all three deadlock under the loader lock -- which presents as
  ## the game hanging on a black screen at startup rather than as an error.
  ## The host's boot thread (`aowlspt_hostboot.h`) is the right caller.
  ##
  ## Safe to call twice; the second call is a no-op that returns true.
  cOvStart(toggleVk, backendPort) != 0'i32

proc overlayStop*() =
  ## Only for a host that unloads itself. Removing a `Present` detour while the
  ## render thread might be inside it is inherently racy; the C side stops
  ## drawing and waits several frames first, which is as safe as this gets.
  cOvStop()

proc overlayRunning*(): bool = cOvRunning() != 0'i32
proc overlayVisible*(): bool = cOvVisible() != 0'i32
proc overlayShow*(on: bool) = cOvSetVisible(if on: 1'i32 else: 0'i32)

proc overlayFrames*(): int32 =
  ## Frames the `Present` hook has seen. Zero after the game has been rendering
  ## for a while means the hook is installed on a swap chain the game does not
  ## use -- worth logging, because everything else will look fine.
  cOvFrames()

proc overlayFrameNs*(): int32 =
  ## What one frame of the panel costs the game, in nanoseconds: an exponential
  ## moving average over roughly the last hundred drawn frames, measured with
  ## QPC around the build-and-draw inside the `Present` hook.
  ##
  ## **Not** zeroed when the panel closes -- only `overlayStart` clears it -- so
  ## after a close it goes on reporting the last thing that was measured. That
  ## is deliberate, and it is what makes this worth logging once after a raid:
  ## an overlay inside a game's present loop should be made to say what it
  ## costs rather than be asked, and the question is asked when the panel is
  ## already shut. The other side of it is that a reading taken just after the
  ## panel is *reopened* is still the previous opening's; the panel labels that
  ## `was` on its title bar, and a caller here can only wait the half second it
  ## takes the average to settle.
  ##
  ## This used to say the figure was zero while the panel was closed and that a
  ## hidden panel was one `if` in the hook; neither was quite the case. A hidden
  ## frame is cheap but not free -- the frame counter, the reentrancy guard and
  ## the swap-chain bind all run before the visible test.
  cOvFrameNs()

proc overlayFrameNsMax*(): int32 =
  ## The worst single frame since the overlay started. Never lowered: an average
  ## hides a stutter by construction, and the stutter is what a player notices.
  cOvFrameNsMax()

proc overlaySetMod*(guid, name, version: string; enabled: bool) =
  ## Tells the panel about one loaded mod. This is the read-only fallback: with
  ## no backend reachable the panel still lists what is actually running in this
  ## process, which is the one source of truth that cannot be stale.
  ##
  ## The parameters are `var` copies because `toCString` hands out a pointer
  ## into the string's storage and nimony strings keep short contents inline --
  ## a pointer into a by-value parameter that has already been destroyed is the
  ## subtle failure this avoids.
  var g = guid
  var n = name
  var v = version
  cOvSetMod(toCString(g), toCString(n), toCString(v),
            if enabled: 1'i32 else: 0'i32)

proc overlayClearMods*() = cOvClearMods()

proc overlaySyncStart*(path: string; intervalMs: int32) =
  ## Ask the overlay's worker thread to fetch `path` from the backend every
  ## `intervalMs`, and to keep the newest whole body for `overlaySyncTake`.
  ##
  ## This is how the client host reaches the backend without gaining an HTTP
  ## client, a worker thread or a socket library of its own -- all three already
  ## exist here, for the panel, and the alternative was a second copy of each
  ## inside a DLL that is injected into a process mid-startup.
  ##
  ## Call it after `overlayStart`, and call it even when `overlayStart` returned
  ## false: a failure there means the overlay cannot *draw*, and the worker
  ## thread is running regardless.
  var p = path
  cOvSyncStart(toCString(p), intervalMs)

proc overlaySyncTake*(): string =
  ## The newest body the feed fetched, once. Empty when nothing has arrived
  ## since the last call -- which is the normal answer on all but one poll in
  ## sixty, and is also the answer when the backend is down, unreachable or
  ## answering rubbish. A caller that acts only on a non-empty result therefore
  ## does nothing at all when the far end is unhappy, which is the behaviour
  ## live mod control needs and not merely the one it tolerates.
  result = ""
  let n = cOvSyncPending()
  if n <= 0:
    return
  # One byte more than the body, for the terminator the C side writes.
  var buf = newSeq[char](n + 1)
  let got = cOvSyncTake(addr buf[0], int32(n + 1))
  if got <= 0'i32:
    # 0 is "another caller got there first", -1 is "it grew between the two
    # calls". Both mean: nothing this time, try again on the next tick.
    return
  var i = 0
  while i < int(got):
    result.add buf[i]
    inc i

proc overlayStatus*(): string =
  ## One line, meant to be logged verbatim: either what the overlay is doing or
  ## the first thing that went wrong.
  # Zeroed explicitly: nimony will not let an uninitialised array's
  # address be taken, and it is right to insist -- the C side writes at
  # most `cap` bytes and nul-terminates, but a refusal there would leave
  # this reading whatever was on the stack.
  var buf: array[256, char] = default(array[256, char])
  let n = cOvStatus(addr buf[0], 256'i32)
  result = ""
  var i = 0
  while i < int(n):
    result.add buf[i]
    inc i
