## Proves the nimony side of the overlay compiles, links and runs.
##
## The C is covered by `overlayhost.c`, which renders and screenshots. What
## this covers is the boundary: that `aowloverlay.nim` binds the header the way
## the rest of the repo binds C, that a nimony build needs no extra link
## library for it, and that a nimony `string` survives the trip to `const char*`.
##
## It starts the overlay in a process with no swap chain of its own. The hook
## installs (the vtable comes from a throwaway probe device, not from the host
## process's own rendering), no frame ever arrives, and the status line says so
## -- which is also exactly what a host would log if it were injected into
## something that does not render.

import std/syncio
import aowloverlay

proc patchFired(slot: int32; regs: pointer): int32 {.
  exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## `aowlspt_detour.h` emits its assembly thunk pool unconditionally and the
  ## thunks call this, so any binary that includes the detour engine has to
  ## define it. The client host already does. The overlay never routes through
  ## a thunk -- its detours are C functions with the right signature -- so this
  ## is unreachable here.
  0'i32

proc patchReturned(slot: int32; regs: pointer): int32 {.
  exportc: "aowlspt_nim_patch_returned", cdecl.} =
  ## The return-side half of the same dispatcher, and unreachable for the same
  ## reason. Both symbols have to exist in any binary that includes
  ## `aowlspt_detour.h`, because its thunk pool is emitted whether or not
  ## anything in the program routes through it.
  0'i32

proc main() =
  if overlayStart(VkInsert, 0'i32):
    echo "ok    overlay started from nimony"
  else:
    echo "error overlay start failed: " & overlayStatus()
    quit 1
  echo "      status: " & overlayStatus()

  overlaySetMod("aowl.clientprobe", "clientprobe", "0.1.0", true)
  overlaySetMod("aowl.sway", "SWAY", "1.4.2", false)
  echo "ok    mod rows pushed across the boundary"

  if overlayRunning():
    echo "ok    overlay reports running"
  else:
    echo "error overlay does not report running"
    quit 1

  overlayShow(true)
  if overlayVisible():
    echo "ok    visibility toggles from nimony"
  else:
    echo "error visibility did not toggle"
    quit 1
  overlayShow(false)

  if overlayFrames() == 0'i32:
    echo "ok    no frames seen, as expected in a process that never presents"

  # The cost accessors bind and answer. Zero is the correct answer here and the
  # reason is the point of the check: nothing has been drawn, so nothing has
  # been measured, and a non-zero figure would mean the counter is reporting
  # something other than time spent drawing.
  if overlayFrameNs() == 0'i32 and overlayFrameNsMax() == 0'i32:
    echo "ok    frame cost reads zero with no frame ever drawn"
  else:
    echo "error frame cost is non-zero in a process that never presented"
    quit 1

  overlayStop()
  echo "ok    overlay stopped"
  echo ""
  echo "all overlay nimony checks passed"

main()
