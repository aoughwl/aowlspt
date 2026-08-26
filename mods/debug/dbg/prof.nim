## The nimony face of `abi/aowlspt_profile.h` -- the profiler's shared region.
##
## Same shape as `mods/admin/adm/shared.nim`: the C is header-only, so the emit
## pulls the definitions into this translation unit and every entry is
## `importc ... nodecl`. This mod and the host each get their own copy of the
## header's `static` functions; what they actually share is the named file
## mapping, so both talking to it is two views of ONE region rather than two
## copies of a global.
##
## Nothing in this file resolves an IL2CPP name, calls a game method or writes
## game memory. It cannot -- the region is a page this process created, and the
## only arithmetic is on integers the host put there. That is deliberate: on
## this build every by-NAME IL2CPP route is fatal the moment it is USED
## (fact #145), so the profiler was designed to have no such route at all.

{.emit: """#include "aowlspt_profile.h" """.}

const
  profKindFree*  = 0'i32
  profKindMod*   = 1'i32
  profKindRider* = 2'i32
  profKindRoute* = 3'i32   ## RESERVED -- nothing writes it; see the header.
  profKindOther* = 4'i32

# Window statistic selectors for `profWinUs`.
const
  winMin*  = 0'i32
  winMean* = 1'i32
  winP50*  = 2'i32
  winP95*  = 3'i32
  winP99*  = 4'i32
  winMax*  = 5'i32

proc cReady(): int32 {.importc: "aowl_prof_ready", nodecl.}
proc cIsEnabled(): int32 {.importc: "aowl_prof_is_enabled", nodecl.}
proc cSetEnabled(on: int32) {.importc: "aowl_prof_set_enabled", nodecl.}
proc cSetWindow(n: int32) {.importc: "aowl_prof_set_window", nodecl.}
proc cCalibrate() {.importc: "aowl_prof_calibrate", nodecl.}
proc cFaults(): int32 {.importc: "aowl_prof_faults", nodecl.}
proc cSelfDisabled(): int32 {.importc: "aowl_prof_self_disabled", nodecl.}
proc cReasonChar(k: int32): int32 {.importc: "aowl_prof_reason_char", nodecl.}
proc cOverheadNs(): int64 {.importc: "aowl_prof_overhead_ns", nodecl.}
proc cFramesSeen(): int64 {.importc: "aowl_prof_frames", nodecl.}
proc cFrameSource(): int32 {.importc: "aowl_prof_frame_source", nodecl.}
proc cHeartbeat(): int32 {.importc: "aowl_prof_heartbeat", nodecl.}
proc cLiveSlots(): int32 {.importc: "aowl_prof_live_slots", nodecl.}
proc cSlotCount(): int32 {.importc: "aowl_prof_slot_count", nodecl.}
proc cSlotKind(i: int32): int32 {.importc: "aowl_prof_slot_kind", nodecl.}
proc cSlotNameChar(i, k: int32): int32 {.
  importc: "aowl_prof_slot_name_char", nodecl.}
proc cSlotNs(i: int32): int64 {.importc: "aowl_prof_slot_ns", nodecl.}
proc cSlotMaxNs(i: int32): int64 {.importc: "aowl_prof_slot_max_ns", nodecl.}
proc cSlotCalls(i: int32): int64 {.importc: "aowl_prof_slot_calls", nodecl.}
proc cSlotTotalNs(i: int32): int64 {.
  importc: "aowl_prof_slot_total_ns", nodecl.}
proc cSlotPermille(i: int32): int32 {.
  importc: "aowl_prof_slot_permille", nodecl.}
proc cWinUs(which: int32): int32 {.importc: "aowl_prof_win_us", nodecl.}
proc cKindChar(kind, k: int32): int32 {.
  importc: "aowl_prof_kind_char", nodecl.}

proc profReady*(): bool = cReady() != 0
proc profEnabled*(): bool = cIsEnabled() != 0
proc profSetEnabled*(on: bool) = cSetEnabled(if on: 1'i32 else: 0'i32)
proc profSetWindow*(n: int) = cSetWindow(int32(n))
proc profCalibrate*() = cCalibrate()
proc profFaults*(): int = int(cFaults())
proc profSelfDisabled*(): bool = cSelfDisabled() != 0
proc profReason*(): string =
  ## Byte at a time, and NOT via `$cstring`: that compiles under the host's Nim
  ## build and does not compile under the nimony toolchain the mods use
  ## (measured -- "expected: string but got: cstring not nil"). Bounded by the
  ## region's own constant, and a 0 byte ends the loop, so a corrupt region
  ## produces a short string rather than a walk off the end.
  result = ""
  var k = 0'i32
  while k < 160'i32:
    let c = cReasonChar(k)
    if c == 0: break
    result.add char(c)
    k = k + 1'i32
proc profOverheadNs*(): int64 = cOverheadNs()
proc profFramesSeen*(): int64 = cFramesSeen()
proc profHeartbeat*(): int = int(cHeartbeat())
  ## Boundary firings seen by the region. ZERO while the profiler is on is the
  ## single most diagnostic number here: it means nothing is calling a window
  ## boundary in this process, so no window can ever close.
proc profLiveSlots*(): int = int(cLiveSlots())
proc profFrameSourceLive*(): bool = cFrameSource() != 0
  ## Whether anything in this process is a real FRAME source -- i.e. whether
  ## the client host's shared Update rider chain has fired. False on the
  ## backend and the simulator, where the windows are rolled by the loader's
  ## tick instead. When it is false the frame-time percentiles are NOT a frame
  ## time and must not be printed as one.
proc profSlotCount*(): int = int(cSlotCount())
proc profSlotKind*(i: int): int32 = cSlotKind(int32(i))
proc profSlotName*(i: int): string =
  result = ""
  var k = 0'i32
  while k < 32'i32:
    let c = cSlotNameChar(int32(i), k)
    if c == 0: break
    result.add char(c)
    k = k + 1'i32
proc profSlotNs*(i: int): int64 = cSlotNs(int32(i))
proc profSlotMaxNs*(i: int): int64 = cSlotMaxNs(int32(i))
proc profSlotCalls*(i: int): int64 = cSlotCalls(int32(i))
proc profSlotTotalNs*(i: int): int64 = cSlotTotalNs(int32(i))
proc profSlotPermille*(i: int): int = int(cSlotPermille(int32(i)))
  ## Share of the completed window's WALL time, in tenths of a percent.
  ## **-1 means there is no complete window yet** and MUST be rendered as "--".
  ## Rendering it as 0.0% would turn "I could not look" into a measurement,
  ## which is the exact failure shape CLAUDE.md 9b is about.
proc profWinUs*(which: int32): int = int(cWinUs(which))
proc profKindName*(k: int32): string =
  result = ""
  var j = 0'i32
  while j < 16'i32:
    let c = cKindChar(k, j)
    if c == 0: break
    result.add char(c)
    j = j + 1'i32

proc profMs*(ns: int64): string =
  ## Nanoseconds as milliseconds to three places, integer arithmetic only.
  let us = ns div 1000
  result = $(us div 1000) & "." &
           (if us mod 1000 < 10: "00" elif us mod 1000 < 100: "0" else: "") &
           $(us mod 1000)

proc profAtNoiseFloor*(ns: int64): bool =
  ## A slot whose whole window cost is within 3x of ONE begin/end pair is not a
  ## measurement, it is the instrument. Reported as such, never as a number.
  let o = profOverheadNs()
  result = o > 0 and ns < o * 3
