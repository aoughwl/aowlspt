## aowlgraphics -- the nimony face of the native full-frame post-process.
##
## The renderer itself is C, in `abi/aowlspt_graphics.h`, for the same reason
## the overlay is: it walks a COM vtable, installs a detour whose target is a
## function pointer, and implements two detours with the DXGI calling
## convention -- none of which nimony expresses. This module is thin: it lets
## the client host turn the post-process on and push a grade into it, and
## nothing else.
##
## Wiring from `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` (on the boot thread,
## AFTER `overlayStart`, so the two Present hooks chain grade-then-UI):
##
## ```nim
## import aowlgraphics
## if graphicsStart():
##   info "graphics: " & graphicsStatus()
## else:
##   warn "graphics: " & graphicsStatus()
## ```
##
## Params come from the `mods/graphics` mod, which calls
## `call("aowlspt.host::gfx_apply", <json>)`; the host forwards the JSON to
## `graphicsApplyJson`. `graphicsStart` returning false is not a reason to fail
## the host -- a post-process that could not hook is a missing feature, not a
## broken install. Log the status and carry on.

{.emit: """#include "aowlspt_graphics.h" """.}

# --------------------------------------------------------------- C surface
#
# `nodecl` + the emit above, not `{.compile.}`: the header is header-only static
# code, so the compiler must see the definitions in this translation unit. Same
# shape as `aowloverlay.nim`.

proc cGfxStart(): int32 {.importc: "aowl_gfx_start", nodecl.}
proc cGfxStop() {.importc: "aowl_gfx_stop", nodecl.}
proc cGfxRunning(): int32 {.importc: "aowl_gfx_running", nodecl.}
proc cGfxFrames(): int32 {.importc: "aowl_gfx_frames", nodecl.}
proc cGfxStatus(buf: ptr char; cap: int32): int32 {.importc: "aowl_gfx_status", nodecl.}
proc cGfxSetParamsJson(json: cstring) {.importc: "aowl_gfx_set_params_json", nodecl.}
proc cGfxStartDriven(): int32 {.importc: "aowl_gfx_start_driven", nodecl.}
proc cGfxGradePtr(): pointer {.importc: "aowl_gfx_grade_ptr", nodecl.}
proc cGfxReleasePtr(): pointer {.importc: "aowl_gfx_release_ptr", nodecl.}
proc cGfxSetInRaid(on: int32) {.importc: "aowl_gfx_set_in_raid", nodecl.}

# --------------------------------------------------------------- public

proc graphicsStart*(): bool =
  ## Captures the DXGI vtable, detours `Present` and `ResizeBuffers`, and loads
  ## d3dcompiler. Must not be called from `DllMain`. Safe to call twice; the
  ## second call is a no-op returning true. False means the post-process cannot
  ## draw (the game still renders normally).
  cGfxStart() != 0'i32

proc graphicsStartDriven*(): bool =
  ## Start WITHOUT installing a Present hook. Used when the overlay already owns
  ## the DXGI Present detour (the engine refuses a second hook on the same
  ## function). The host then registers `graphicsGradePtr()` /
  ## `graphicsReleasePtr()` with the overlay so grading runs from the overlay's
  ## Present hook. Safe to call twice.
  cGfxStartDriven() != 0'i32

proc graphicsGradePtr*(): pointer =
  ## Opaque pointer to the C grade callback, to hand to `overlaySetPrePresent`.
  cGfxGradePtr()

proc graphicsReleasePtr*(): pointer =
  ## Opaque pointer to the C release-on-resize callback, for `overlaySetPreResize`.
  cGfxReleasePtr()

proc graphicsStop*() =
  ## Only for a host that unloads itself. Removing a `Present` detour while the
  ## render thread might be inside it is inherently racy; the C side stops
  ## drawing (latches broken) and waits several frames before removing.
  cGfxStop()

proc graphicsRunning*(): bool = cGfxRunning() != 0'i32

proc graphicsFrames*(): int32 =
  ## Frames the post-process has processed. Zero long after the game is
  ## rendering means the hook is on a swap chain the game does not use.
  cGfxFrames()

proc graphicsApplyJson*(json: string) =
  ## Push a grade. `json` is the compact `{"exposure":..,"contrast":..,...}` the
  ## `mods/graphics` mod builds from its config; unknown keys are ignored and
  ## missing keys keep their current value. Thread-safe (the C side copies under
  ## a lock), so it can be called from the host's `call` dispatcher directly.
  var j = json
  cGfxSetParamsJson(toCString(j))

proc graphicsSetInRaid*(inRaid: bool) =
  ## Push the raid-state gate signal from the host (sourced from the backend's
  ## poll — the tarkov mod knows raid start/end definitively). When the mod's
  ## `raidOnly` is set (the default), the post-process grades only while this is
  ## true and passes the frame through untouched in the menu. The C side ramps
  ## the transition over a few frames so it fades rather than pops. Thread-safe.
  cGfxSetInRaid(if inRaid: 1'i32 else: 0'i32)

proc graphicsStatus*(): string =
  ## One line, meant to be logged verbatim: what the post-process is doing or the
  ## first thing that went wrong.
  var buf: array[256, char] = default(array[256, char])
  let n = cGfxStatus(addr buf[0], 256'i32)
  result = ""
  var i = 0
  while i < int(n):
    result.add buf[i]
    inc i
