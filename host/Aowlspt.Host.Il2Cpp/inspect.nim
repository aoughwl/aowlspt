# inspect.nim -- THE LIVE INSPECTOR / REPL.
#
# `include`d into `aowlhost.nim` (NOT a separate module), LAST, because it
# stands on everything above it: this file's guarded raw primitives
# (`cIsReadable`/`cReadPtrAt`/`cUxWritePtr`), its logging, `hexOf`,
# `attachDrain`, the VEH/SEH guard, `gRt`/`newString`; `settingsui.nim`'s
# `suiReadString` and tab registry; `invoke2.nim`'s verified managed targets;
# `debugui.nim`'s `duOk`, `bdSanePtr`, its clone anchors and its GameWorld
# cache; and `modetext.nim`'s slot, which this feature may have to ride on.
#
# WHY IT EXISTS
# -------------
# Server-side work on this project is fast: instant rebuild, no restart,
# hundreds of assertions in seconds. Client-side work crawls, and the cause is
# not difficulty -- it is the FEEDBACK LOOP. Today, one question about the live
# game costs an edit, a serialised multi-minute rebuild, a deploy, a launch and
# ninety seconds to the menu, and answers exactly ONE log line: the one somebody
# had to PREDICT they would want. If the answer is not in a line written in
# advance, nothing is learned and the whole cost is paid again.
#
# That is why a trivial change -- relabel a corner string -- took cycle after
# cycle, each one revealing a new invisible layer (a zero-size RectTransform, a
# world-space canvas, a nested `Canvas` copied by `Object::Instantiate`, a
# `Graphic` raycast target). None of those were reasoning failures. They were
# INVISIBLE, because reflection is dead on this IL2CPP build and the only thing
# we can do is assert an offline-guessed offset and watch whether it faults.
#
# So this is not a feature. It is the INSTRUMENT: a command channel into the
# running game that answers a question in SECONDS, with no rebuild and no
# restart, while the player stays at the menu.
#
# HOW IT IS WIRED -- nothing new that can fail
# --------------------------------------------
#   * The command channel is a FILE beside the host DLL, polled by the host's
#     own tick loop, which already runs. No new socket, no new thread, no new
#     port. A file is also the one channel that is scriptable from a shell
#     without a UI, which is the actual working situation: a human at the
#     keyboard with the game running, and an agent driving from outside.
#   * Execution is on UNITY'S MAIN THREAD, because managed access requires it.
#     It rides the EXISTING `EFT.UI.PreloaderUI::Update` detour -- the same one
#     the F3 overlay and the menu mode-text feature share -- by aliasing its
#     slot, exactly as those two alias each other. Two detours on one function
#     would have the second overwrite the first's trampoline; there is only ever
#     one, and `patchFired` calls every rider whose slot matches.
#
# THE SAFETY DISCIPLINE, unchanged from the rest of this host
# -----------------------------------------------------------
#   * EVERY hop goes through `aowl_is_readable`/`duOk` -- never a faulting
#     dereference to find out.
#   * A BREADCRUMB is written before every dereference, so a caught fault
#     reports THE LAST HOP ATTEMPTED and its pointer. "Fault caught" with no
#     location is precisely what has been costing cycles, and this is the one
#     thing here that exists purely to stop that happening again.
#   * ONE `aowl_p_p_seh` per COMMAND, never nested -- that guard is not
#     re-entrant, and a nested one would disarm the outer on return. Per command
#     rather than per batch so a bad address in line 3 does not hide lines 4-20.
#   * Every loop is capped and every output is capped.
#   * Writes are OFF unless the batch says `allow write` AND the host flag
#     `liveInspectorWrite` is set. Two switches, because a typo in a REPL that
#     can store into live managed objects is a crash at best.
#   * Default OFF (`liveInspector`), and self-disabling after
#     `InspMaxFaults` faults.
#
# WHAT IT CANNOT DO -- stated plainly, because a tool whose limits are unclear
# is a tool that produces confident nonsense
# ---------------------------------------------------------------------------
#   * It cannot NAME a type. Reflection is dead; `klass` reports the raw
#     `Il2CppClass*` from offset 0 of the object header and nothing more. Two
#     objects with the same klass pointer are the same type; which type it is
#     has to come from `tools/il2cpp_resolve.py` offline.
#   * It cannot enumerate fields. `fields` classifies each 8-byte slot by what
#     the BYTES look like (a readable pointer, a plausible small int, a
#     plausible float) -- a guess, labelled as one, and it is still the fastest
#     way to find out that the offset metadata gave you reads null on the live
#     object.
#   * It cannot list a Transform's children. `Transform::GetChild` is a generic
#     -- and more to the point the child count getter is not in the verified
#     target tables. The parent chain IS reachable, and walking UP from a
#     verified live object is how the settings-row container was finally
#     reached after `_rectTransform`@0x78 kept reading null. `children` reports
#     that limit rather than pretending.
#   * `call` supports the argument shapes in `aowlspt_inspect.h` and the
#     `sret` shape for small float structs. A method taking a struct BY VALUE
#     (`Camera::WorldToScreenPoint(Vector3)`) is refused, not attempted.
#   * A `call` executes real game code. A getter is safe; a setter is not
#     read-only, and `call` is therefore gated by the same `allow write`.

# ---- the native half ----
{.emit: """#include "aowlspt_inspect.h" """.}
## UI NAVIGATION TARGETS -- `ShowScreen` and `set_IsSelected`, so the inspector
## can DRIVE the menu and not only read it. Verified through the prologue
## SNAPSHOT and additionally shape-checked against being a do-nothing stub.
##
## Not added to `aowl_pro_prime_all`: that function is emitted long before this
## file is included, so it cannot name this table. The LAZY capture inside
## `aowl_pro_verify` is correct here for the documented reason -- a target's
## first verify necessarily precedes its first patch, and nothing detours
## either of these at all.
{.emit: """#include "aowlspt_navui.h" """.}
proc cNavTargetCount(): int32 {.importc: "aowl_nav_target_count", nodecl.}
proc cNavFn(i: int32): Il2CppPtr {.importc: "aowl_nav_target_at", nodecl.}
proc cNavName(i: int32): cstring {.importc: "aowl_nav_target_name", nodecl.}
proc cNavRva(i: int32): uint32 {.importc: "aowl_nav_target_rva", nodecl.}
proc cNavOffCurrentTab(): int32 {.importc: "aowl_nav_off_currenttab", nodecl.}
proc cNavOffInitTabs(): int32 {.importc: "aowl_nav_off_inittabs", nodecl.}
proc cNavOffFirstSel(): int32 {.importc: "aowl_nav_off_firstsel", nodecl.}
proc cNavOffCreated(): int32 {.importc: "aowl_nav_off_created", nodecl.}
proc cNavReason(): int32 {.importc: "aowl_nav_last_reason", nodecl.}
proc cNavActualValid(): int32 {.importc: "aowl_nav_actual_valid", nodecl.}
proc cNavActualAt(i: int32): int32 {.importc: "aowl_nav_actual_at", nodecl.}
proc cNavExpectedAt(t, i: int32): int32 {.importc: "aowl_nav_expected_at", nodecl.}

proc cInspLock() {.importc: "aowl_insp_lock", nodecl.}
proc cInspUnlock() {.importc: "aowl_insp_unlock", nodecl.}
proc cInspHave(): int32 {.importc: "aowl_insp_have", nodecl.}
proc cInspSetPending(v: int32) {.importc: "aowl_insp_set_pending", nodecl.}

proc cInspMark(what, p: Il2CppPtr) {.importc: "aowl_insp_mark", nodecl.}
proc cInspCrumb(): Il2CppPtr {.importc: "aowl_insp_crumb_get", nodecl.}
proc cInspCrumbPtr(): Il2CppPtr {.importc: "aowl_insp_crumb_ptr_get", nodecl.}

proc cInspReadBytes(p: Il2CppPtr; off, n: int32; outp: ptr uint8): int32 {.
  importc: "aowl_insp_read_bytes", nodecl.}
proc cInspReadableSpan(p: Il2CppPtr; off, n: int32): int32 {.
  importc: "aowl_insp_readable_span", nodecl.}
proc cInspWriteBytes(p: Il2CppPtr; off, n: int32; src: ptr uint8): int32 {.
  importc: "aowl_insp_write_bytes", nodecl.}

proc cInspCode(rva: uint64): Il2CppPtr {.importc: "aowl_insp_code", nodecl.}
proc cInspReason(): int32 {.importc: "aowl_insp_last_reason", nodecl.}
proc cInspPrologueOk(p, hex: Il2CppPtr): int32 {.
  importc: "aowl_insp_prologue_ok", nodecl.}
proc cInspIl2Start(): uint64 {.importc: "aowl_insp_il2cpp_start", nodecl.}
proc cInspIl2End(): uint64 {.importc: "aowl_insp_il2cpp_end", nodecl.}
proc cInspModuleBase(): Il2CppPtr {.importc: "aowl_insp_module_base", nodecl.}

proc cInspUV(fn, mi: Il2CppPtr): uint64 {.importc: "aowl_insp_u_v", nodecl.}
proc cInspUP(fn, a0, mi: Il2CppPtr): uint64 {.importc: "aowl_insp_u_p", nodecl.}
proc cInspUPP(fn, a0, a1, mi: Il2CppPtr): uint64 {.
  importc: "aowl_insp_u_pp", nodecl.}
proc cInspUPPP(fn, a0, a1, a2, mi: Il2CppPtr): uint64 {.
  importc: "aowl_insp_u_ppp", nodecl.}
proc cInspUPPPP(fn, a0, a1, a2, a3, mi: Il2CppPtr): uint64 {.
  importc: "aowl_insp_u_pppp", nodecl.}
proc cInspUPI(fn, a0: Il2CppPtr; a1: int32; mi: Il2CppPtr): uint64 {.
  importc: "aowl_insp_u_pi", nodecl.}
proc cInspUPL(fn, a0: Il2CppPtr; a1: int64; mi: Il2CppPtr): uint64 {.
  importc: "aowl_insp_u_pl", nodecl.}
proc cInspUPF(fn, a0: Il2CppPtr; a1: float32; mi: Il2CppPtr): uint64 {.
  importc: "aowl_insp_u_pf", nodecl.}
proc cInspUPFF(fn, a0: Il2CppPtr; a1, a2: float32; mi: Il2CppPtr): uint64 {.
  importc: "aowl_insp_u_pff", nodecl.}
proc cInspUI(fn: Il2CppPtr; a0: int32; mi: Il2CppPtr): uint64 {.
  importc: "aowl_insp_u_i", nodecl.}
proc cInspFV(fn, mi: Il2CppPtr): float32 {.importc: "aowl_insp_f_v", nodecl.}
proc cInspFP(fn, a0, mi: Il2CppPtr): float32 {.importc: "aowl_insp_f_p", nodecl.}
proc cInspFPP(fn, a0, a1, mi: Il2CppPtr): float32 {.
  importc: "aowl_insp_f_pp", nodecl.}
proc cInspFPI(fn, a0: Il2CppPtr; a1: int32; mi: Il2CppPtr): float32 {.
  importc: "aowl_insp_f_pi", nodecl.}
proc cInspBitsF32(b: uint32): float32 {.importc: "aowl_insp_bits_to_f32", nodecl.}
proc cInspBitsF64(b: uint64): float64 {.importc: "aowl_insp_bits_to_f64", nodecl.}
proc cInspF32Bits(v: float32): uint32 {.importc: "aowl_insp_f32_to_bits", nodecl.}
proc cInspF64Bits(v: float64): uint64 {.importc: "aowl_insp_f64_to_bits", nodecl.}

# ---------------------------------------------------------------------------
# State
#
# Two threads touch this: the host's TICK thread (loads a batch, publishes the
# answer) and UNITY'S main thread (runs it). The split is deliberate and the
# rule is one line long -- the tick thread owns `gInspCmds` while
# `aowl_insp_have()` is 0, Unity owns it while it is 1, and the handover in
# each direction is one interlocked store. `gInspOut` is written only by Unity
# and read by the tick thread after that store, so the same fence covers it.
#
# The lock exists only for the two moments of handover; nothing holds it while
# a command runs, because a command may call managed code and take as long as
# it likes.
# ---------------------------------------------------------------------------
const
  InspMaxFaults    = 8
    ## After this many caught faults the inspector switches itself off for the
    ## session. A REPL is pointed at wrong addresses by design, so the budget
    ## is generous -- but a channel that faults every frame is a channel that
    ## is confusing the log rather than answering anything.
  InspMaxCmds      = 128     ## commands accepted from one batch
  InspMaxOutLines  = 600     ## lines of answer kept
  InspMaxDumpBytes = 512     ## bytes one `dump`/`fields`/`scan` may touch
  InspMaxWalk      = 24      ## hops one `parent` walk may take
  InspMaxLineLen   = 400     ## characters kept per output line
  InspStuckMs      = 8000'u64
    ## How long a handed-over batch may sit undrained before the channel gives
    ## up on it and publishes a diagnosis. A batch normally runs on the very
    ## next frame; seconds means nothing is running it at all, and a silent
    ## wedge is the one failure this instrument must never have.

var gInspOn = false          ## the `liveInspector` flag
var gInspWriteOn = false     ## the `liveInspectorWrite` flag
var gInspOff = false         ## self-disabled after too many faults
## `gInspSlot` -- the PreloaderUI::Update slot, shared or claimed -- is declared
## in `aowlhost.nim` beside `gModeTextSlot`, because `attachDrain` and
## `patchFired` are both defined above this file's include point and both need
## to name it. Procs resolve across the whole module regardless of order;
## module-level `var`s do not.
var gInspFaults = 0
var gInspFires = 0
  ## How many times the Unity-thread rider has actually been DISPATCHED. This
  ## is the number that tells "the rider never ran" apart from "the rider ran
  ## and found nothing to do" -- two failures that look identical from the
  ## outside and which cost two live runs to distinguish. Incremented before
  ## every early-out in `inspectFired`, so it counts dispatches, not work.
var gInspTicks = 0
  ## How many times the rider ran with a batch actually pending, i.e. got past
  ## the `aowl_insp_have` gate. `gInspFires` high with `gInspTicks` zero means
  ## the rider is dispatched fine and the HANDOFF FLAG is what is broken.
var gInspDrainFires = 0
  ## Dispatches that arrived on the IN-RAID anchor (the main drain) rather than
  ## on `PreloaderUI::Update`. Non-zero means the instrument is alive in raid.
var gInspFiredLogged = false
  ## One-shot: the rider announces its own first call, with a timestamp. That
  ## line is what makes the ORDER of events legible in the log -- specifically
  ## whether the detour started ticking before or after a batch was handed over.
var gInspWaitBatch = -1
  ## The batch we have already explained is waiting for the detour to start
  ## ticking, so that explanation is given once per batch and not every poll.
var gInspInFlight = -1
  ## The batch currently being executed on the Unity thread, or -1. If this is
  ## still set when the rider is next entered, the previous run did NOT return
  ## normally -- it escaped between here and the completion handshake. That is
  ## the only way to notice an escape at all, since an escape by definition
  ## skips whatever line was meant to record it.
var gInspEscapes = 0
var gInspPhase = 0
  ## Which part of the batch is executing: 0 idle, 1 anchor refresh,
  ## 2 a command, 3 the completion handshake. Reported when a batch escapes,
  ## so the recovery names the phase that escaped instead of guessing.
var gInspResumeAt = 0
  ## Where a SUSPENDED batch resumes. A batch used to be all-or-nothing inside
  ## one tick, which made it useless for driving the UI: opening a screen takes
  ## frames, so "open settings then read the tab" could only ever read the tab
  ## as it was BEFORE the open.
var gInspSuspended = false
  ## True while a batch is parked on a `wait`/`until`. The completion handshake
  ## is skipped while this holds, and the rider resumes the batch next frame.
var gInspUntilLeft = 0
  ## Frames remaining on the current `wait`/`until`. Hard-capped: a condition
  ## that never becomes true reports a timeout and the batch CONTINUES, rather
  ## than parking the channel forever.
var gInspBodyMode = 0
  ## What the ONE guarded body should do this call: 0 run the current command,
  ## 1 refresh the anchors. The guard carries a single pointer, so the selector
  ## goes in a global -- the same pattern the command index already uses.
var gInspBatch = 0
var gInspBatchDone = -1      ## last batch Unity finished; the tick thread's cue

var gInspCmds: seq[string] = @[]
var gInspOut: seq[string] = @[]
var gInspOutBytes = 0
var gInspCurIdx = 0
var gInspAllowWrite = false  ## per batch, reset every batch

var gInspVarName: seq[string] = @[]
var gInspVarVal: seq[uint64] = @[]

var gInspPreloader: Il2CppPtr = nil
  ## The live `PreloaderUI` this, straight out of RCX on the detour that
  ## carries this feature. It is the ROOT ANCHOR: a session that starts from a
  ## verified live object instead of a raw address is a session whose first hop
  ## is not already a guess.

var gInspLastText = ""       ## last command-file content, so an unchanged file costs nothing
var gInspNextPollMs = 0'u64
var gInspHandedMs = 0'u64
  ## When the current batch was handed to Unity's thread, so a batch nobody
  ## drains times out with an explanation instead of wedging the channel.
var gInspCmdPath = ""
var gInspOutPath = ""
var gInspGreeted = false

# ---------------------------------------------------------------------------
# Small text helpers.
#
# Hand-rolled rather than reached for from `strutils`, for the ordinary reason
# in this host: they run inside a VEH-guarded body on the game's own thread,
# and the fewer allocating library calls on that path the better.
# ---------------------------------------------------------------------------
proc iMark(what: string; p: Il2CppPtr) =
  ## THE BREADCRUMB. Called before every dereference and every call, so a
  ## caught fault names the last hop attempted instead of only that something
  ## went wrong. The native side copies the text out immediately, so the local
  ## `var` only has to survive the call -- which is exactly the lifetime a
  ## nimony SSO string's `toCString` pointer has.
  var s = what
  cInspMark(cast[Il2CppPtr](toCString(s)), p)

proc iPrologueOk(p: Il2CppPtr; hex: string): bool =
  var s = hex
  result = cInspPrologueOk(p, cast[Il2CppPtr](toCString(s))) != 0'i32

const InspHexDigits = "0123456789abcdef"

proc iHexPad(v: uint64; width: int): string =
  result = ""
  var shift = (width - 1) * 4
  while shift >= 0:
    result.add InspHexDigits[int((v shr uint64(shift)) and 0xF'u64)]
    shift = shift - 4

proc iPtr(p: Il2CppPtr): string = "0x" & iHexPad(cast[uint64](p), 16)
proc iPtrU(v: uint64): string = "0x" & iHexPad(v, 16)

proc iIsSpace(c: char): bool = c == ' ' or c == '\t' or c == '\r'

proc iSplit(s: string): seq[string] =
  ## Whitespace split that keeps a double-quoted run together, so
  ## `write $x str "hello world"` is three tokens and not four.
  result = @[]
  var cur = ""
  var i = 0
  var inQuote = false
  while i < s.len:
    let c = s[i]
    if inQuote:
      if c == '"':
        inQuote = false
      else:
        cur.add c
    elif c == '"':
      inQuote = true
    elif iIsSpace(c):
      if cur.len > 0:
        result.add cur
        cur = ""
    else:
      cur.add c
    inc i
  if cur.len > 0:
    result.add cur

proc iLines(s: string): seq[string] =
  result = @[]
  var cur = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\n':
      result.add cur
      cur = ""
    elif c != '\r':
      cur.add c
    inc i
  if cur.len > 0:
    result.add cur

proc iLower(s: string): string =
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z':
      result.add char(int(c) + 32)
    else:
      result.add c

proc iHexVal(c: char): int =
  if c >= '0' and c <= '9': return int(c) - int('0')
  if c >= 'a' and c <= 'f': return int(c) - int('a') + 10
  if c >= 'A' and c <= 'F': return int(c) - int('A') + 10
  result = -1

proc iParseU(tok: string; v: var uint64): bool =
  ## `0x...` hex or plain decimal. Deliberately NOT `parseInt`: that routine is
  ## `.raises` in nimony and would drag a try/except onto the guarded path for
  ## a job that is fifteen lines.
  v = 0'u64
  if tok.len == 0:
    return false
  var i = 0
  var neg = false
  if tok[0] == '-':
    neg = true
    i = 1
  if i + 1 < tok.len and tok[i] == '0' and (tok[i + 1] == 'x' or tok[i + 1] == 'X'):
    i = i + 2
    if i >= tok.len:
      return false
    var acc = 0'u64
    while i < tok.len:
      let d = iHexVal(tok[i])
      if d < 0:
        return false
      acc = acc * 16'u64 + uint64(d)
      inc i
    v = (if neg: 0'u64 - acc else: acc)
    return true
  var acc = 0'u64
  while i < tok.len:
    let c = tok[i]
    if c < '0' or c > '9':
      return false
    acc = acc * 10'u64 + uint64(int(c) - int('0'))
    inc i
  v = (if neg: 0'u64 - acc else: acc)
  result = true

proc iParseF(tok: string; v: var float64): bool =
  ## Decimal float, hand-rolled for the same reason as `iParseU`.
  v = 0.0
  if tok.len == 0:
    return false
  var i = 0
  var neg = false
  if tok[0] == '-':
    neg = true
    i = 1
  elif tok[0] == '+':
    i = 1
  var whole = 0.0
  var seen = false
  while i < tok.len and tok[i] >= '0' and tok[i] <= '9':
    whole = whole * 10.0 + float64(int(tok[i]) - int('0'))
    seen = true
    inc i
  if i < tok.len and tok[i] == '.':
    inc i
    var scale = 0.1
    while i < tok.len and tok[i] >= '0' and tok[i] <= '9':
      whole = whole + float64(int(tok[i]) - int('0')) * scale
      scale = scale * 0.1
      seen = true
      inc i
  if not seen or i != tok.len:
    return false
  v = (if neg: -whole else: whole)
  result = true

proc iFmtF(v: float64): string =
  ## Four decimals, no exponent, no `formatFloat`. A REPL that printed
  ## `1.0000000000000002e-05` for a canvas scale would be answering a different
  ## question from the one asked.
  var x = v
  var s = ""
  if x < 0.0:
    s = "-"
    x = -x
  if x > 1.0e15:
    return s & "big"
  let whole = uint64(x)
  var frac = x - float64(whole)
  s = s & $int64(whole) & "."
  for i in 0 ..< 4:
    frac = frac * 10.0
    let d = int(frac)
    s.add InspHexDigits[if d < 0: 0 elif d > 9: 9 else: d]
    frac = frac - float64(d)
  result = s

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
proc iOut(s: string) =
  ## Every answer line. Capped twice -- per line and per batch -- because this
  ## runs on the game's main thread and an unbounded `dump` would be a stall
  ## the player feels.
  if gInspOut.len >= InspMaxOutLines:
    return
  if s.len > InspMaxLineLen:
    var cut = ""
    for i in 0 ..< InspMaxLineLen:
      cut.add s[i]
    gInspOut.add cut & " ...(truncated)"
    gInspOutBytes = gInspOutBytes + InspMaxLineLen + 16
    return
  gInspOut.add s
  gInspOutBytes = gInspOutBytes + s.len + 1

proc iErr(s: string) = iOut("  ! " & s)

# ---------------------------------------------------------------------------
# The variable / anchor namespace
#
# Anchors and user variables share one namespace on purpose: an anchor is
# simply a variable the host rebinds every batch from something it already
# knows, and a session that starts by typing a raw address it got from a log
# line is a session whose first hop is unverified. `anchors` lists them.
# ---------------------------------------------------------------------------
proc iSetVar(name: string; v: uint64) =
  for i in 0 ..< gInspVarName.len:
    if gInspVarName[i] == name:
      gInspVarVal[i] = v
      return
  gInspVarName.add name
  gInspVarVal.add v

proc iGetVar(name: string; v: var uint64): bool =
  for i in 0 ..< gInspVarName.len:
    if gInspVarName[i] == name:
      v = gInspVarVal[i]
      return true
  result = false

proc iSetVarP(name: string; p: Il2CppPtr) = iSetVar(name, cast[uint64](p))

proc iRefreshAnchors() =
  ## Rebound every batch from the pointers this host ALREADY holds, so a
  ## session never has to start from a raw address somebody copied out of a
  ## log. Only anchors that are actually live are bound; one that is nil this
  ## frame is bound to 0 and says so in `anchors`, which is itself an answer
  ## ("the overlay has not built yet").
  iSetVarP("preloader", gInspPreloader)
  # `_alphaVersionLabel` @ +0x20 and `_sessionModeText` @ +0x128 on PreloaderUI
  # -- the two fields the version brand and the menu mode-text feature already
  # depend on, so they are as verified as anything in this host.
  if duOk(gInspPreloader, 0x130'i32):
    iSetVarP("verlabel", cReadPtrAt(gInspPreloader, 0x20'i32))
    iSetVarP("modetext", cReadPtrAt(gInspPreloader, 0x128'i32))
  iSetVarP("duanchor", gDuAnchorTmp)     # the TMP the overlay clones from
  iSetVarP("duroot", gDuRootGo)          # the GameObject it parents clones to
  iSetVarP("gameworld", gDuGameWorld)    # the live GameWorld, when in a raid
  iSetVarP("you", gDuYou)                # the local player, when in a raid
  iSetVarP("settings", gMi2Self)         # the live SettingsScreen, once opened
  for i in 0 ..< 8:
    if gSuiTabPtr[i] != 0'u64:
      iSetVar("tab" & $i, gSuiTabPtr[i])

# ---------------------------------------------------------------------------
# Address expressions
#
# `ATOM ( '+' HEX | '@' HEX )*`
#
#   ATOM    `0x...` / decimal / `$name`
#   `+0x18` add 0x18            -- move within the object
#   `@0x18` DEREF at +0x18      -- follow the reference field there
#
# Walking with `@` is the whole navigation model, and it is the model because
# it is the only one that works: metadata says `_rectTransform` is at +0x78 and
# the live object reads null there, so the answer came from walking `@` hops
# from an object we had already verified. Every `@` is `duOk`-gated and every
# one writes a breadcrumb first, so a wrong hop reports which hop it was rather
# than dying anonymously.
# ---------------------------------------------------------------------------
proc iEval(ex: string; v: var uint64; err: var string): bool =
  err = ""
  v = 0'u64
  if ex.len == 0:
    err = "empty address expression"
    return false
  # ---- the atom ----
  var i = 0
  var atom = ""
  if ex[0] == '$':
    i = 1
    while i < ex.len and ex[i] != '+' and ex[i] != '@':
      atom.add ex[i]
      inc i
    if not iGetVar(atom, v):
      err = "no such anchor or variable: $" & atom
      return false
  else:
    while i < ex.len and ex[i] != '+' and ex[i] != '@':
      atom.add ex[i]
      inc i
    if not iParseU(atom, v):
      err = "not an address: " & atom
      return false
  # ---- the chain ----
  var hop = 0
  while i < ex.len:
    let op = ex[i]
    inc i
    var num = ""
    while i < ex.len and ex[i] != '+' and ex[i] != '@':
      num.add ex[i]
      inc i
    var off = 0'u64
    if num.len == 0:
      off = 0'u64
    elif not iParseU(num, off):
      err = "not an offset: " & num
      return false
    inc hop
    if hop > InspMaxWalk:
      err = "expression has more than " & $InspMaxWalk & " hops"
      return false
    if op == '+':
      v = v + off
    else:
      # THE BREADCRUMB, written BEFORE the dereference and not after. If the
      # VEH guard fires on the next instruction this is what names the hop.
      let base = cast[Il2CppPtr](v)
      iMark(("deref +0x" & iHexPad(off, 2) & " of " & iPtrU(v)), base)
      if not duOk(base, int32(off) + 8'i32):
        err = "cannot deref +0x" & iHexPad(off, 2) & " of " & iPtrU(v) &
              " (not readable)"
        return false
      v = cast[uint64](cReadPtrAt(base, int32(off)))
  result = true

# ---------------------------------------------------------------------------
# Typed reads
# ---------------------------------------------------------------------------
proc iTypeSize(t: string): int32 =
  ## Width in bytes, and -1 for "not a type this REPL knows" -- which is a
  ## refusal, never a default, because a guessed width is a read past the end
  ## of an object.
  result = -1'i32
  case t
  of "i8", "u8", "bool": result = 1'i32
  of "i16", "u16": result = 2'i32
  of "i32", "u32", "f32": result = 4'i32
  of "i64", "u64", "f64", "ptr", "str", "klass": result = 8'i32
  else: result = -1'i32

proc iReadTyped(p: Il2CppPtr; t: string; outp: var string): bool =
  ## `p` is the FINAL address -- the expression evaluator has already applied
  ## every `+` and `@`. One `aowl_is_readable` for exactly the width of the
  ## type, then the read.
  let size = iTypeSize(t)
  if size < 0:
    outp = "unknown type: " & t
    return false
  var buf = default(array[8, uint8])
  iMark(("read " & t & " at " & iPtr(p)), p)
  if cInspReadBytes(p, 0'i32, size, cast[ptr uint8](addr buf[0])) == 0'i32:
    outp = "not readable for " & $int(size) & " bytes at " & iPtr(p)
    return false
  var raw = 0'u64
  for i in 0 ..< int(size):
    raw = raw or (uint64(buf[i]) shl uint64(i * 8))
  case t
  of "u8": outp = $int(raw)
  of "i8":
    let s8 = (if raw >= 0x80'u64: int(raw) - 256 else: int(raw))
    outp = $s8
  of "u16": outp = $int(raw)
  of "i16":
    let s16 = (if raw >= 0x8000'u64: int(raw) - 65536 else: int(raw))
    outp = $s16
  of "u32": outp = $int64(raw) & "  (0x" & iHexPad(raw, 8) & ")"
  of "i32":
    let s32 = int32(uint32(raw))
    outp = $int(s32) & "  (0x" & iHexPad(raw, 8) & ")"
  of "u64", "i64": outp = $int64(raw) & "  (0x" & iHexPad(raw, 16) & ")"
  of "f32": outp = iFmtF(float64(cInspBitsF32(uint32(raw)))) &
                   "  (bits 0x" & iHexPad(raw, 8) & ")"
  of "f64": outp = iFmtF(cInspBitsF64(raw)) & "  (bits 0x" & iHexPad(raw, 16) & ")"
  of "bool": outp = (if raw != 0'u64: "true" else: "false") & "  (0x" &
                    iHexPad(raw, 2) & ")"
  of "ptr":
    let q = cast[Il2CppPtr](raw)
    outp = iPtrU(raw) &
           (if raw == 0'u64: "  NULL"
            elif duOk(q, 8'i32): "  readable"
            else: "  NOT readable")
  of "klass":
    # Every live IL2CPP object carries its `Il2CppClass*` at offset 0. That is
    # the ONE piece of type information reflection's death leaves reachable,
    # and it is enough to answer "are these two objects the same type".
    let q = cast[Il2CppPtr](raw)
    outp = iPtrU(raw) & (if duOk(q, 8'i32): "  (klass, readable)"
                         else: "  (not a readable klass)")
  of "str":
    # `System.String`: length @ +0x10, UTF-16 @ +0x14. The host's own fixed
    # layout, and self-validating -- a slot that is not a String does not
    # accidentally decode to text.
    let q = cast[Il2CppPtr](raw)
    if raw == 0'u64:
      outp = "NULL"
    else:
      let s = suiReadString(q)
      outp = "\"" & s & "\" (String* " & iPtrU(raw) & ", len " & $s.len & ")"
  else:
    outp = "unknown type: " & t
    return false
  result = true

# ---------------------------------------------------------------------------
# The verified call-target tables
#
# Nothing new is verified here. `invoke2.nim` and `debugui.nim` already carry
# byte-signature tables for the functions this project actually calls, and each
# entry is checked against ORIGINAL bytes -- these are functions nothing
# detours, so re-verifying them is safe. (The one function that DOES get a jump
# written into it is `PreloaderUI::Update`, and this feature deliberately never
# verifies that: it rides a slot rather than re-checking a trampoline. That is
# the exact trap currently self-rejecting `uxMenuModeText`.)
# ---------------------------------------------------------------------------
proc iTargetCount(): int = int(cMi2TargetCount()) + int(cDuTargetCount())

proc iTargetName(i: int): string =
  if i < int(cMi2TargetCount()):
    readCString(cMi2Name(int32(i)))
  else:
    readCString(cDuName(int32(i) - cMi2TargetCount()))

proc iTargetRva(i: int): uint64 =
  if i < int(cMi2TargetCount()):
    uint64(cMi2Rva(int32(i)))
  else:
    uint64(cDuRva(int32(i) - cMi2TargetCount()))

proc iTargetFn(i: int): Il2CppPtr =
  if i < int(cMi2TargetCount()):
    cMi2Fn(int32(i))
  else:
    cDuFn(int32(i) - cMi2TargetCount())

proc iContains(hay, needle: string): bool =
  if needle.len == 0:
    return true
  if needle.len > hay.len:
    return false
  for start in 0 .. hay.len - needle.len:
    var ok = true
    for k in 0 ..< needle.len:
      if hay[start + k] != needle[k]:
        ok = false
        break
    if ok:
      return true
  result = false

proc iFindTarget(pattern: string; idx: var int; hits: var int): bool =
  ## Case-insensitive substring, and AMBIGUITY IS AN ERROR rather than a
  ## first-match: `call name:get_name` must not silently pick `set_name`
  ## because it happened to sort first.
  let want = iLower(pattern)
  hits = 0
  idx = -1
  for i in 0 ..< iTargetCount():
    if iContains(iLower(iTargetName(i)), want):
      inc hits
      if idx < 0:
        idx = i
  result = hits == 1

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
proc iCmdAnchors() =
  iOut("  anchors and variables (" & $gInspVarName.len & "):")
  for i in 0 ..< gInspVarName.len:
    let v = gInspVarVal[i]
    let p = cast[Il2CppPtr](v)
    iOut("    $" & gInspVarName[i] & " = " & iPtrU(v) &
         (if v == 0'u64: "   (not live yet)"
          elif duOk(p, 8'i32): "   klass=" & iPtrU(cast[uint64](cReadPtrAt(p, 0'i32)))
          else: "   (not readable)"))

proc iCmdTargets(pattern: string) =
  var shown = 0
  iOut("  verified direct-call targets matching \"" & pattern & "\":")
  for i in 0 ..< iTargetCount():
    let n = iTargetName(i)
    if not iContains(iLower(n), iLower(pattern)):
      continue
    if shown >= 40:
      iOut("    ... more matches; narrow the pattern")
      return
    inc shown
    let fn = iTargetFn(i)
    iOut("    " & n & "  rva=0x" & iHexPad(iTargetRva(i), 7) &
         (if fn == nil: "  UNVERIFIED on this build" else: "  ok " & iPtr(fn)))
  if shown == 0:
    iOut("    (none)")

proc iCmdDump(p: Il2CppPtr; n: int32) =
  ## Raw bytes, sixteen to a line, hex and ASCII. The fallback for when
  ## metadata says one thing and the live object says another -- and the first
  ## thing to reach for when a field read comes back null, because the value
  ## is very often four or eight bytes away from where it was expected.
  iMark(("dump " & $int(n) & " bytes at " & iPtr(p)), p)
  let span = cInspReadableSpan(p, 0'i32, n)
  if span <= 0'i32:
    iErr("nothing readable at " & iPtr(p))
    return
  if span < n:
    iOut("  only " & $int(span) & " of " & $int(n) &
         " bytes are readable here; showing what is:")
  var buf = default(array[InspMaxDumpBytes, uint8])
  if cInspReadBytes(p, 0'i32, span, cast[ptr uint8](addr buf[0])) == 0'i32:
    iErr("read failed at " & iPtr(p))
    return
  var off = 0
  while off < int(span):
    var hexPart = ""
    var txtPart = ""
    for k in 0 ..< 16:
      if off + k < int(span):
        let b = buf[off + k]
        hexPart.add InspHexDigits[int(b shr 4'u8)]
        hexPart.add InspHexDigits[int(b and 0xF'u8)]
        hexPart.add ' '
        txtPart.add (if b >= 0x20'u8 and b < 0x7F'u8: char(b) else: '.')
      else:
        hexPart.add "   "
    iOut("    +0x" & iHexPad(uint64(off), 3) & "  " & hexPart & " |" & txtPart & "|")
    off = off + 16

proc iCmdFields(p: Il2CppPtr; n: int32) =
  ## A BEST-EFFORT field table, and the "best-effort" is the honest part: with
  ## reflection dead there is no field list to read, so each 8-byte slot is
  ## classified by what its bytes LOOK like. It is a guess. It is also, in
  ## practice, the fastest way to discover that the offset the metadata gave
  ## you reads null while the pointer you actually want is two slots along.
  iMark(("fields at " & iPtr(p)), p)
  let span = cInspReadableSpan(p, 0'i32, n)
  if span < 8'i32:
    iErr("nothing readable at " & iPtr(p))
    return
  iOut("  slot table for " & iPtr(p) & " (" & $int(span) &
       " readable bytes; classification is a GUESS from the bytes, not metadata)")
  var off = 0
  while off + 8 <= int(span):
    var buf = default(array[8, uint8])
    if cInspReadBytes(p, int32(off), 8'i32, cast[ptr uint8](addr buf[0])) == 0'i32:
      break
    var raw = 0'u64
    for k in 0 ..< 8:
      raw = raw or (uint64(buf[k]) shl uint64(k * 8))
    var note = ""
    let q = cast[Il2CppPtr](raw)
    if raw == 0'u64:
      note = "null"
    elif duOk(q, 8'i32):
      let klass = cReadPtrAt(q, 0'i32)
      note = "ptr -> readable"
      if duOk(klass, 8'i32):
        note = note & ", klass=" & iPtrU(cast[uint64](klass))
        let s = suiReadString(q)
        if s.len > 0:
          note = note & ", String \"" & s & "\""
    else:
      let lo = uint32(raw and 0xFFFFFFFF'u64)
      let hi = uint32(raw shr 32'u64)
      note = "i32 " & $int(int32(lo))
      let f = cInspBitsF32(lo)
      if f > -100000.0 and f < 100000.0 and (f > 0.00001 or f < -0.00001):
        note = note & " / f32 " & iFmtF(float64(f))
      if hi != 0'u32:
        note = note & " | hi i32 " & $int(int32(hi))
      if off == 0:
        note = note & "   <- offset 0 is the Il2CppClass* on a live object"
    iOut("    +0x" & iHexPad(uint64(off), 3) & "  " & iHexPad(raw, 16) & "  " & note)
    off = off + 8

proc iCmdScan(p: Il2CppPtr; span: int32; t, valueTok: string) =
  ## The fallback for when metadata says one thing and the live object says
  ## another: search the object's bytes for a plausibly-shaped value and report
  ## the OFFSET. "The float 90 is at +0x120, not the +0x118 the dump implied"
  ## is a five-second answer here and was a rebuild cycle before.
  let size = iTypeSize(t)
  if size < 0 or t == "str" or t == "klass":
    iErr("scan needs a fixed-width type (i8..f64, ptr, bool)")
    return
  var want = 0'u64
  if t == "f32":
    var f = 0.0
    if not iParseF(valueTok, f):
      iErr("not a number: " & valueTok)
      return
    want = uint64(cInspF32Bits(float32(f)))
  elif t == "f64":
    var f = 0.0
    if not iParseF(valueTok, f):
      iErr("not a number: " & valueTok)
      return
    want = cInspF64Bits(f)
  elif not iParseU(valueTok, want):
    iErr("not a value: " & valueTok)
    return
  iMark(("scan " & $int(span) & " bytes at " & iPtr(p)), p)
  let have = cInspReadableSpan(p, 0'i32, span)
  if have < size:
    iErr("nothing readable at " & iPtr(p))
    return
  var mask = 0xFFFFFFFFFFFFFFFF'u64
  if size < 8'i32:
    mask = (1'u64 shl uint64(int(size) * 8)) - 1'u64
  let target = want and mask
  var hits = 0
  var off = 0
  while off + int(size) <= int(have):
    var buf = default(array[8, uint8])
    if cInspReadBytes(p, int32(off), size, cast[ptr uint8](addr buf[0])) != 0'i32:
      var raw = 0'u64
      for k in 0 ..< int(size):
        raw = raw or (uint64(buf[k]) shl uint64(k * 8))
      if raw == target:
        inc hits
        iOut("    found " & t & " " & valueTok & " at +0x" & iHexPad(uint64(off), 3))
        if hits >= 32:
          iOut("    ... stopping at 32 hits")
          return
    # Byte-granular, not slot-granular, deliberately: a field that is NOT
    # 8-aligned is exactly the case a slot-aligned scan would miss, and
    # missing it is what sends somebody back into a rebuild cycle.
    inc off
  if hits == 0:
    iOut("    no match for " & t & " " & valueTok & " in " & $int(have) &
         " readable bytes")

proc iCmdParent(start: Il2CppPtr; depth: int) =
  ## The parent chain, named at every step -- and the single most useful thing
  ## in this file. Walking UP from an object we have already verified is the
  ## ONLY reliable navigation available on this build: it is how the
  ## settings-row container was finally reached after `_rectTransform`@0x78
  ## kept reading null.
  ##
  ## The route is `Component::get_transform` to get onto the Transform, then
  ## `Transform::get_parent` repeatedly, with `Object::get_name` and
  ## `GameObject::get_activeSelf` at each level. Every function is one of the
  ## byte-verified targets; an unverified build simply gets fewer columns.
  var idx = 0
  var hits = 0
  var fnTransform: Il2CppPtr = nil
  var fnParent: Il2CppPtr = nil
  var fnName: Il2CppPtr = nil
  var fnGo: Il2CppPtr = nil
  var fnActive: Il2CppPtr = nil
  if iFindTarget("Component::get_transform", idx, hits): fnTransform = iTargetFn(idx)
  if iFindTarget("Transform::get_parent", idx, hits): fnParent = iTargetFn(idx)
  if iFindTarget("Object::get_name", idx, hits): fnName = iTargetFn(idx)
  if iFindTarget("Component::get_gameObject", idx, hits): fnGo = iTargetFn(idx)
  if iFindTarget("GameObject::get_activeSelf", idx, hits): fnActive = iTargetFn(idx)
  # This walk is made of CALLS, not field reads. Say so once, up front, with
  # the RVAs -- so if it ever escapes, the log already names every function it
  # could have escaped in, without another cycle to find out.
  iOut("  via Transform::get_parent, Component::get_transform, " &
       "Object::get_name, Component::get_gameObject, " &
       "GameObject::get_activeSelf (calls, not field reads)")
  if fnParent == nil:
    iErr("Transform::get_parent did not verify on this build; cannot walk")
    return
  var cur = start
  # `get_transform` on something that is already a Transform returns itself, so
  # this is safe whether the caller handed us a component or a transform.
  if fnTransform != nil and duOk(cur, 0x20'i32):
    iMark(("Component::get_transform on " & iPtr(cur)), cur)
    let t = cast[Il2CppPtr](cInspUP(fnTransform, cur, nil))
    if duOk(t, 0x20'i32):
      cur = t
  var level = 0
  let cap = (if depth > InspMaxWalk: InspMaxWalk elif depth < 1: 1 else: depth)
  while level < cap:
    if not duOk(cur, 0x20'i32):
      iOut("    [" & $level & "] " & iPtr(cur) & "  (not readable; chain ends)")
      return
    var line = "    [" & $level & "] transform=" & iPtr(cur) &
               " klass=" & iPtrU(cast[uint64](cReadPtrAt(cur, 0'i32)))
    if fnName != nil:
      iMark(("Object::get_name on " & iPtr(cur)), cur)
      let sp = cast[Il2CppPtr](cInspUP(fnName, cur, nil))
      line = line & " name=\"" & suiReadString(sp) & "\""
    if fnGo != nil and fnActive != nil:
      iMark(("Component::get_gameObject on " & iPtr(cur)), cur)
      let go = cast[Il2CppPtr](cInspUP(fnGo, cur, nil))
      if duOk(go, 0x20'i32):
        iMark(("GameObject::get_activeSelf on " & iPtr(go)), go)
        let act = cInspUP(fnActive, go, nil)
        line = line & " go=" & iPtr(go) &
               " activeSelf=" & (if (act and 1'u64) != 0'u64: "true" else: "false")
    iOut(line)
    iMark(("Transform::get_parent on " & iPtr(cur)), cur)
    let par = cast[Il2CppPtr](cInspUP(fnParent, cur, nil))
    if par == nil:
      iOut("    [" & $(level + 1) & "] (null parent -- this is the hierarchy root)")
      return
    cur = par
    inc level
  iOut("    ... stopped at depth " & $cap)

proc iCmdCanvas(p: Il2CppPtr) =
  ## "Does this thing have a Canvas?" -- the open root-cause question for the
  ## overlay, and one that reflection would answer in one call and cannot.
  ##
  ## The reachable route is the one `debugui.nim` already uses: a
  ## `UnityEngine.UI.Graphic` (which every TextMeshProUGUI is) caches the
  ## Canvas it draws on in `m_Canvas`, a plain reference field. So this reads
  ## that field raw and then CALLS `Canvas::get_renderMode` /
  ## `get_sortingOrder` / `get_scaleFactor` on whatever came back -- three
  ## byte-verified getters whose answers cross-check the field: a non-Canvas
  ## would not produce a render mode of 0/1/2 and a sane scale factor.
  let off = cDuOffTmpGCanvas()
  if not duOk(p, off + 8'i32):
    iErr("not readable to +0x" & iHexPad(uint64(off), 2) & " at " & iPtr(p))
    return
  iMark(("Graphic.m_Canvas +0x" & iHexPad(uint64(off), 2)), p)
  let canvas = cReadPtrAt(p, off)
  iOut("  Graphic.m_Canvas (+0x" & iHexPad(uint64(off), 2) & ") = " & iPtr(canvas) &
       (if canvas == nil: "   <- NO cached Canvas on this Graphic" else: ""))
  if not duOk(canvas, 0x20'i32):
    if canvas != nil:
      iErr("that Canvas pointer is not readable")
    return
  iOut("  canvas klass = " & iPtrU(cast[uint64](cReadPtrAt(canvas, 0'i32))))
  # WHY THESE THREE ARE CALLS AND NOT FIELD READS, AND WHY THAT MATTERS.
  #
  # `renderMode`, `sortingOrder` and `scaleFactor` are NOT managed fields and
  # cannot be read the way `read $verlabel+0x60 ptr` reads one. Their prologues
  # are the IL2CPP INTERNAL-CALL shape --
  #
  #     40 53              push rbx
  #     48 83 EC 20        sub  rsp, 0x20
  #     48 8B 05 xx xx xx xx   mov  rax, [rip+...]   <- the icall pointer cache
  #     48 8B D9           mov  rbx, rcx
  #
  # -- a thin managed wrapper that forwards into Unity's C++ engine. A
  # UnityEngine.Object's real state lives in that C++ object, reached through
  # `m_CachedPtr` at +0x10 on the managed wrapper. There is no managed field
  # holding a render mode to read instead; the call is the only route.
  #
  # Which is exactly why the liveness gate below is mandatory. If `m_CachedPtr`
  # is 0 -- a destroyed Unity object (the "fake null" every Unity user meets),
  # or a pointer that was never a UnityEngine.Object because the m_Canvas
  # offset was wrong for this build -- then the native side dereferences that
  # zero or that garbage, and the fault happens INSIDE Unity's C++ where no
  # amount of care on our side can predict it. That is the `canvas $verlabel`
  # escape: the field reads before it all succeeded, and then we called into
  # native code on an object whose native half we had never checked.
  let nativeOk = duOk(canvas, 0x18'i32)
  let native = (if nativeOk: cReadPtrAt(canvas, 0x10'i32) else: nil)
  iOut("  Canvas m_CachedPtr (+0x10) = " & iPtr(native) &
       (if native == nil: "   <- NO native object" else: "   (native half is live)"))
  if native == nil:
    iErr("refusing to call Canvas::get_renderMode / get_sortingOrder / " &
         "get_scaleFactor on this pointer. They are internal calls into " &
         "Unity's C++ engine and they dereference m_CachedPtr, which is 0 " &
         "here -- so calling them would fault inside native code. Either " &
         "this object is a destroyed Unity object, or +0x" &
         iHexPad(uint64(off), 2) & " is not really Graphic.m_Canvas on this " &
         "build. The klass pointer above is the thing to check.")
    return
  var idx = 0
  var hits = 0
  # Every CALL announces itself with its name and RVA before it is made, so an
  # escape in the log is instantly attributable to a call rather than to a
  # field read -- the two fail in completely different places and want
  # completely different fixes.
  if iFindTarget("Canvas::get_renderMode", idx, hits):
    let fn = iTargetFn(idx)
    if fn != nil:
      iOut("  via UnityEngine.Canvas::get_renderMode @0x" &
           iHexPad(iTargetRva(idx), 6) & " (internal call)")
      iMark(("Canvas::get_renderMode"), canvas)
      let m = cInspUP(fn, canvas, nil) and 0xFFFFFFFF'u64
      iOut("  renderMode = " & $int64(m) &
           (if m == 0'u64: "  (ScreenSpaceOverlay)"
            elif m == 1'u64: "  (ScreenSpaceCamera)"
            elif m == 2'u64: "  (WorldSpace  <-- a clone landed on its OWN canvas)"
            else: "  (not a render mode -- this is probably NOT a Canvas)"))
  if iFindTarget("Canvas::get_sortingOrder", idx, hits):
    let fn = iTargetFn(idx)
    if fn != nil:
      iOut("  via UnityEngine.Canvas::get_sortingOrder @0x" &
           iHexPad(iTargetRva(idx), 6) & " (internal call)")
      iMark(("Canvas::get_sortingOrder"), canvas)
      iOut("  sortingOrder = " & $int(int32(uint32(cInspUP(fn, canvas, nil)))))
  if iFindTarget("Canvas::get_scaleFactor", idx, hits):
    let fn = iTargetFn(idx)
    if fn != nil:
      iOut("  via UnityEngine.Canvas::get_scaleFactor @0x" &
           iHexPad(iTargetRva(idx), 6) & " (internal call)")
      iMark(("Canvas::get_scaleFactor"), canvas)
      iOut("  scaleFactor = " & iFmtF(float64(cInspFP(fn, canvas, nil))))

proc iNavExplain(t: int32; name: string; rva: uint32) =
  ## Say WHICH of the five ways to fail actually happened, and on a signature
  ## mismatch print the bytes side by side. "Did not verify (or is a stub)"
  ## covers five different causes and identifies none of them; every time this
  ## project has shipped a message like that it has cost a full cycle.
  let r = cNavReason()
  iErr(name & " @0x" & iHexPad(uint64(rva), 6) & " did not verify -- " &
       (if r == 1: "GameAssembly.dll is not loaded (impossible here; a bug)"
        elif r == 2: "VirtualQuery failed on that address: the RVA is almost " &
                     "certainly wrong for this build"
        elif r == 3: "that page is not committed: the RVA is wrong for this build"
        elif r == 4: "that page is not executable: the RVA points at data, " &
                     "not code -- wrong RVA for this build"
        elif r == 6: "the live bytes there are a STUB (ret / ret n). The RVA " &
                     "resolves but the function does nothing, so calling it " &
                     "would be a silent no-op. Find the real entry point."
        elif r == 5: "the prologue does not match the expected signature"
        else: "no reason was recorded, which is itself a bug"))
  if cNavActualValid() != 0'i32:
    var act = ""
    var exp = ""
    for i in 0 ..< 16:
      if i > 0:
        act.add ' '
        exp.add ' '
      act.add iHexPad(uint64(cNavActualAt(int32(i))), 2)
      let e = cNavExpectedAt(t, int32(i))
      exp.add (if e < 0: "??" else: iHexPad(uint64(e), 2))
    iOut("    actual   " & act)
    iOut("    expected " & exp)

proc iNavFind(want: string; fn: var Il2CppPtr; rva: var uint32): bool =
  ## Resolve one navigation target by substring, byte-verified through the
  ## prologue snapshot AND shape-checked against being a do-nothing stub.
  fn = nil
  rva = 0'u32
  for i in 0 ..< int(cNavTargetCount()):
    let nm = readCString(cNavName(int32(i)))
    if iContains(iLower(nm), iLower(want)):
      fn = cNavFn(int32(i))
      rva = cNavRva(int32(i))
      if fn == nil:
        iNavExplain(int32(i), nm, rva)
        return false
      return true
  iErr("no navigation target matches \"" & want & "\"")
  result = false

proc iNavGate(what: string): bool =
  ## THE WRITE GATE, WITH A REASON. Navigation calls into game code and changes
  ## what is on screen, so it needs `liveInspectorWrite` in the config AND an
  ## explicit `allow write` in the batch. A refusal here must never be
  ## mistakable for "the click missed" -- so it names which of the two gates is
  ## shut and exactly how to open it.
  if not gInspWriteOn:
    iErr(what & " REFUSED: liveInspectorWrite is false in aowlspt-host.json. " &
         "Nothing was called and nothing on screen changed. Set it to true " &
         "and restart the client.")
    return false
  if not gInspAllowWrite:
    iErr(what & " REFUSED: this batch has not said `allow write`. Nothing was " &
         "called and nothing on screen changed. Put `allow write` on a line " &
         "before this one.")
    return false
  result = true

proc iCmdOpen(toks: seq[string]) =
  ## `open [GROUP]` -- EFT.UI.SettingsScreen::ShowScreen(screen, group).
  if not iNavGate("open"):
    return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("ShowScreen", fn, rva):
    return
  var screen = gMi2Self
  if screen == nil:
    iErr("no live SettingsScreen is known yet ($settings is null). The host " &
         "learns it the first time the screen is opened by hand, so open " &
         "Settings once manually and this will work from then on.")
    return
  var group = 0'u64
  if toks.len > 1:
    var err = ""
    discard iEval(toks[1], group, err)
  iOut("  via EFT.UI.SettingsScreen::ShowScreen @0x" &
       iHexPad(uint64(rva), 6) & " (call) on " & iPtr(screen) &
       ", group=" & $int(group))
  iMark("SettingsScreen::ShowScreen", screen)
  discard cInspUPI(fn, screen, int32(group), nil)
  iOut("  ShowScreen returned. It is ASYNCHRONOUS -- the screen it asked for " &
       "does not exist yet. Follow with `until $settings+0x118` before " &
       "reading the tab.")

proc iCmdTab(toks: seq[string]) =
  ## `tab PTR [0|1]` -- EFT.UI.SettingsTab::set_IsSelected(tab, value).
  if toks.len < 2:
    iErr("usage: tab PTR [0|1]")
    return
  if not iNavGate("tab"):
    return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("set_IsSelected", fn, rva):
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  let tab = cast[Il2CppPtr](v)
  if not duOk(tab, 0xA0'i32):
    iErr("that tab pointer is not readable to +0xA0; refusing to call.")
    return
  var val = 1'u64
  if toks.len > 2:
    var e2 = ""
    discard iEval(toks[2], val, e2)
  let latchBefore = cReadPtrAt(tab, cNavOffFirstSel())
  iOut("  via EFT.UI.SettingsTab::set_IsSelected @0x" &
       iHexPad(uint64(rva), 6) & " (call) on " & iPtr(tab) &
       ", value=" & $int(val))
  iMark("SettingsTab::set_IsSelected", tab)
  discard cInspUPI(fn, tab, int32(val), nil)
  let latchAfter = cReadPtrAt(tab, cNavOffFirstSel())
  iOut("  first-select latch (+0x" & iHexPad(uint64(cNavOffFirstSel()), 2) &
       ") " & iPtrU(cast[uint64](latchBefore)) & " -> " &
       iPtrU(cast[uint64](latchAfter)) &
       (if latchBefore != latchAfter:
          "   <- FIRST select: OnFirstSelect/CreateControls ran, so " &
          "_createdControls will populate over the next frames"
        else: "   (already selected before, no control creation)"))

proc iCmdState(toks: seq[string]) =
  ## `state` -- what is on screen right now, as FIELD READS only.
  ##
  ## The point of this command is that automation without verification is
  ## worse than no automation: a failed navigation step that goes unnoticed
  ## corrupts every step after it, and does so silently. Everything here is a
  ## guarded field read -- no calls -- so `state` itself can never be the thing
  ## that breaks.
  iOut("  anchors: $preloader=" & iPtr(gInspPreloader) &
       " $settings=" & iPtr(gMi2Self))
  iOut("  inspector: menu anchor slot=" & $gInspSlot &
       ", in-raid anchor slot=" & $gInspSlot2 &
       ", dispatches=" & $gInspFires & " (of those in-raid=" &
       $gInspDrainFires & ")")
  if gInspPreloader == nil:
    iOut("  menu: PreloaderUI anchor is null -- either the menu has not built " &
         "yet, or the session is in a raid (where PreloaderUI does not tick).")
  let ss = gMi2Self
  if ss == nil:
    iOut("  settings: NOT KNOWN. The host learns the SettingsScreen pointer " &
         "the first time that screen is opened; it has not been opened this " &
         "session. This is why the anchor is null -- not a read failure.")
    return
  if not duOk(ss, cNavOffInitTabs() + 8'i32):
    iErr("the SettingsScreen pointer is not readable to +0x" &
         iHexPad(uint64(cNavOffInitTabs()), 3) & "; reporting nothing rather " &
         "than reporting garbage.")
    return
  let cur = cReadPtrAt(ss, cNavOffCurrentTab())
  let init = cReadPtrAt(ss, cNavOffInitTabs())
  iOut("  settings: _currentTab(+0x" & iHexPad(uint64(cNavOffCurrentTab()), 3) &
       ")=" & iPtr(cur) & "  _initializedTabs(+0x" &
       iHexPad(uint64(cNavOffInitTabs()), 3) & ")=" & iPtr(init))
  if cur == nil:
    iOut("  no tab is selected yet (the screen may still be building).")
    return
  if duOk(cur, 0xA0'i32):
    iOut("  current tab: klass=" & iPtrU(cast[uint64](cReadPtrAt(cur, 0'i32))) &
         " _createdControls(+0x" & iHexPad(uint64(cNavOffCreated()), 2) & ")=" &
         iPtr(cReadPtrAt(cur, cNavOffCreated())) &
         " latch(+0x" & iHexPad(uint64(cNavOffFirstSel()), 2) & ")=" &
         iPtrU(cast[uint64](cReadPtrAt(cur, cNavOffFirstSel()))))

proc iResolveCallTarget(tok: string; fn: var Il2CppPtr; label: var string): bool =
  ## `name:<substring>` picks one of the byte-verified targets; `rva:0x...`
  ## takes a raw RVA and puts it through `aowl_insp_code`, which is four
  ## questions: committed, executable, inside the `il2cpp` PE section (generated
  ## code is NOT in `.text` on this build), and NOT already carrying a detour.
  ## An optional `/xxbytes` suffix on an RVA adds a byte-exact prologue check
  ## for a caller who knows what the function should start with.
  fn = nil
  label = tok
  if tok.len > 5 and tok[0] == 'n' and tok[1] == 'a' and tok[2] == 'm' and
     tok[3] == 'e' and tok[4] == ':':
    var pat = ""
    for i in 5 ..< tok.len:
      pat.add tok[i]
    var idx = 0
    var hits = 0
    if not iFindTarget(pat, idx, hits):
      if hits == 0:
        iErr("no verified target matches \"" & pat & "\" (try `targets " & pat & "`)")
      else:
        iErr($hits & " verified targets match \"" & pat &
             "\"; be more specific (try `targets " & pat & "`)")
      return false
    fn = iTargetFn(idx)
    label = iTargetName(idx) & " @0x" & iHexPad(iTargetRva(idx), 7)
    if fn == nil:
      iErr(label & " did not verify by prologue on this build")
      return false
    return true
  if tok.len > 4 and tok[0] == 'r' and tok[1] == 'v' and tok[2] == 'a' and
     tok[3] == ':':
    var rvaTok = ""
    var sig = ""
    var afterSlash = false
    for i in 4 ..< tok.len:
      if tok[i] == '/':
        afterSlash = true
      elif afterSlash:
        sig.add tok[i]
      else:
        rvaTok.add tok[i]
    var rva = 0'u64
    if not iParseU(rvaTok, rva):
      iErr("not an RVA: " & rvaTok)
      return false
    let p = cInspCode(rva)
    if p == nil:
      let why = case int(cInspReason())
                of 1: "GameAssembly.dll is not loaded"
                of 2: "that RVA is outside the image"
                of 3: "not committed or not executable"
                of 4: "outside the `il2cpp` section (generated code lives there, " &
                      "not in .text) -- refusing"
                of 5: "the first bytes are a JUMP: something already detours " &
                      "this function, so what is here is a TRAMPOLINE and not " &
                      "the function. Refusing rather than calling it."
                else: "refused"
      iErr("rva 0x" & iHexPad(rva, 7) & ": " & why)
      return false
    if sig.len > 0 and not iPrologueOk(p, sig):
      iErr("rva 0x" & iHexPad(rva, 7) & ": prologue does not match " & sig)
      return false
    fn = p
    label = "rva 0x" & iHexPad(rva, 7) & " -> " & iPtr(p) &
            (if sig.len > 0: " (prologue verified)" else: " (unverified prologue)")
    return true
  iErr("a call target is `name:<substring>` or `rva:0x...[/<prologue hex>]`")
  result = false

proc iCmdCall(toks: seq[string]) =
  ## `call TARGET SIG [ARG...] [mi=EXPR]`
  ##
  ## SIG is `<ret>_<argshape>` -- ret in u/i/l/p/f/b/s/v, argshape one of the
  ## shapes `aowlspt_inspect.h` provides. `s` decodes a String* return, which
  ## is the self-validating one: a wrong call does not return readable text by
  ## accident.
  if toks.len < 3:
    iErr("usage: call TARGET SIG [ARG...] [mi=EXPR]  (see `help`)")
    return
  var fn: Il2CppPtr = nil
  var label = ""
  if not iResolveCallTarget(toks[1], fn, label):
    return
  let sig = iLower(toks[2])
  var retKind = ""
  var shape = ""
  var seenUnderscore = false
  for i in 0 ..< sig.len:
    if sig[i] == '_':
      seenUnderscore = true
    elif seenUnderscore:
      shape.add sig[i]
    else:
      retKind.add sig[i]
  if not seenUnderscore:
    iErr("SIG looks like `p_p` (pointer return, one pointer argument); got " & sig)
    return
  # Arguments, and the hidden trailing MethodInfo*.
  var mi: Il2CppPtr = nil
  var args: seq[string] = @[]
  for i in 3 ..< toks.len:
    let t = toks[i]
    if t.len > 3 and t[0] == 'm' and t[1] == 'i' and t[2] == '=':
      var e = ""
      for k in 3 ..< t.len:
        e.add t[k]
      var v = 0'u64
      var err = ""
      if not iEval(e, v, err):
        iErr(err)
        return
      mi = cast[Il2CppPtr](v)
    else:
      args.add t
  if shape.len != args.len:
    iErr("SIG " & sig & " wants " & $shape.len & " argument(s); got " & $args.len)
    return
  # Evaluate each argument in the class its position declares.
  var ap: array[4, Il2CppPtr]
  var ai: array[4, int32]
  var af: array[4, float32]
  for i in 0 ..< 4:
    ap[i] = nil
    ai[i] = 0'i32
    af[i] = 0.0'f32
  for i in 0 ..< args.len:
    let cls = shape[i]
    if cls == 'f':
      var f = 0.0
      if not iParseF(args[i], f):
        iErr("argument " & $i & " is not a number: " & args[i])
        return
      af[i] = float32(f)
    else:
      var v = 0'u64
      var err = ""
      if not iEval(args[i], v, err):
        iErr("argument " & $i & ": " & err)
        return
      ap[i] = cast[Il2CppPtr](v)
      ai[i] = int32(uint32(v and 0xFFFFFFFF'u64))
  if not gInspAllowWrite:
    iErr("`call` executes real game code and is not read-only, so it needs " &
         "`allow write` in this batch (and the liveInspectorWrite flag)")
    return
  iOut("  calling " & label & " sig=" & sig & " mi=" & iPtr(mi))
  iMark(("CALL " & label), fn)
  var raw = 0'u64
  var fval = 0.0'f32
  var isFloat = (retKind == "f")
  var handled = true
  if isFloat:
    case shape
    of "": fval = cInspFV(fn, mi)
    of "p": fval = cInspFP(fn, ap[0], mi)
    of "pp": fval = cInspFPP(fn, ap[0], ap[1], mi)
    of "pi", "pb": fval = cInspFPI(fn, ap[0], ai[1], mi)
    else: handled = false
  else:
    case shape
    of "": raw = cInspUV(fn, mi)
    of "p": raw = cInspUP(fn, ap[0], mi)
    of "pp": raw = cInspUPP(fn, ap[0], ap[1], mi)
    of "ppp": raw = cInspUPPP(fn, ap[0], ap[1], ap[2], mi)
    of "pppp": raw = cInspUPPPP(fn, ap[0], ap[1], ap[2], ap[3], mi)
    of "pi", "pb": raw = cInspUPI(fn, ap[0], ai[1], mi)
    of "pl": raw = cInspUPL(fn, ap[0], int64(cast[uint64](ap[1])), mi)
    of "pf": raw = cInspUPF(fn, ap[0], af[1], mi)
    of "pff": raw = cInspUPFF(fn, ap[0], af[1], af[2], mi)
    of "i", "b": raw = cInspUI(fn, ai[0], mi)
    else: handled = false
  if not handled:
    iErr("argument shape \"" & shape & "\" is not one this build provides a " &
         "thunk for. Struct-by-value arguments and struct returns are " &
         "deliberately refused rather than guessed at.")
    return
  if isFloat:
    iOut("  -> f32 " & iFmtF(float64(fval)))
    return
  case retKind
  of "v": iOut("  -> returned without faulting (void)")
  of "b": iOut("  -> bool " & (if (raw and 1'u64) != 0'u64: "true" else: "false"))
  of "i": iOut("  -> i32 " & $int(int32(uint32(raw and 0xFFFFFFFF'u64))))
  of "l", "u": iOut("  -> i64 " & $int64(raw) & " (0x" & iHexPad(raw, 16) & ")")
  of "s":
    let sp = cast[Il2CppPtr](raw)
    iOut("  -> String* " & iPtrU(raw) & " = \"" & suiReadString(sp) & "\"")
  else:
    let q = cast[Il2CppPtr](raw)
    iSetVar("_", raw)
    iOut("  -> ptr " & iPtrU(raw) &
         (if raw == 0'u64: "  NULL"
          elif duOk(q, 8'i32): "  readable, klass=" &
               iPtrU(cast[uint64](cReadPtrAt(q, 0'i32))) & "   (bound to $_)"
          else: "  NOT readable"))

# ---------------------------------------------------------------------------
# `il2cpp_string_new`, by the shape the rest of this host uses: the text goes
# in a global and the thunk takes no argument, because the guard carries
# exactly one pointer and a string is easier held in a global than marshalled
# through it. NOT separately guarded -- the command body is already inside one
# `aowl_p_p_seh` and that guard is not re-entrant.
# ---------------------------------------------------------------------------
var gInspStrText: string = ""

proc inspNewStringImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_insp_newstring", cdecl.} =
  result = newString(gRt, gInspStrText)

proc iCmdWrite(toks: seq[string]) =
  ## Two switches, both required. The flag `liveInspectorWrite` is the
  ## session-level one the player sets; `allow write` is the per-batch one, so
  ## a command file written for reading cannot store into a live managed object
  ## because a line was mistyped.
  if toks.len < 4:
    iErr("usage: write EXPR TYPE VALUE")
    return
  if not gInspWriteOn:
    iErr("writes need `liveInspectorWrite: true` in aowlspt-host.json")
    return
  if not gInspAllowWrite:
    iErr("writes need an `allow write` line earlier in this batch")
    return
  var addrv = 0'u64
  var err = ""
  if not iEval(toks[1], addrv, err):
    iErr(err)
    return
  let t = iLower(toks[2])
  let size = iTypeSize(t)
  if size < 0 or t == "klass":
    iErr("cannot write type " & t)
    return
  let p = cast[Il2CppPtr](addrv)
  var raw = 0'u64
  if t == "str":
    # A managed String, allocated by `il2cpp_string_new` -- the one allocation
    # primitive that still works on this build -- then its pointer stored raw.
    # Exactly the recipe the version brand and the F3 overlay already use.
    gInspStrText = toks[3]
    let s = inspNewStringImpl(cast[Il2CppPtr](0))
    if s == nil or cIsReadable(s, 0x14'i32) == 0'i32:
      iErr("il2cpp_string_new did not return a usable String")
      return
    raw = cast[uint64](s)
    iOut("  allocated String* " & iPtrU(raw) & " = \"" & toks[3] & "\"")
  elif t == "f32":
    var f = 0.0
    if not iParseF(toks[3], f):
      iErr("not a number: " & toks[3])
      return
    raw = uint64(cInspF32Bits(float32(f)))
  elif t == "f64":
    var f = 0.0
    if not iParseF(toks[3], f):
      iErr("not a number: " & toks[3])
      return
    raw = cInspF64Bits(f)
  elif t == "bool":
    raw = (if iLower(toks[3]) == "true" or toks[3] == "1": 1'u64 else: 0'u64)
  elif t == "ptr":
    if not iEval(toks[3], raw, err):
      iErr(err)
      return
  elif not iParseU(toks[3], raw):
    iErr("not a value: " & toks[3])
    return
  var buf = default(array[8, uint8])
  for i in 0 ..< 8:
    buf[i] = uint8((raw shr uint64(i * 8)) and 0xFF'u64)
  iMark(("WRITE " & t & " at " & iPtr(p)), p)
  if cInspWriteBytes(p, 0'i32, size, cast[ptr uint8](addr buf[0])) == 0'i32:
    iErr("that address is not safely writable for " & $int(size) & " bytes")
    return
  var back = ""
  discard iReadTyped(p, t, back)
  iOut("  wrote " & t & " at " & iPtr(p) & "; reads back " & back)

proc iCmdImage() =
  ## Where GameAssembly.dll is, and where its `il2cpp` section is. Worth a
  ## command of its own because it is the one thing every RVA in every note in
  ## this project is relative to, and because "is that RVA even in the
  ## generated-code section" is the first question to ask of a `call` that
  ## refuses.
  let base = cInspModuleBase()
  iOut("  GameAssembly.dll base = " & iPtr(base) &
       (if base == nil: "   (not loaded)" else: ""))
  let s0 = cInspIl2Start()
  let s1 = cInspIl2End()
  if s0 == 0'u64:
    iOut("  no `il2cpp` section found in the PE headers")
  else:
    iOut("  il2cpp section = " & iPtrU(s0) & " .. " & iPtrU(s1) &
         "  (rva 0x" & iHexPad(s0 - cast[uint64](base), 7) & " .. 0x" &
         iHexPad(s1 - cast[uint64](base), 7) & ")")
    iOut("  a `call rva:` target must land inside that range; generated managed " &
         "code is NOT in .text on this build")

proc iCmdHelp() =
  iOut("  aowlspt live inspector -- commands (addresses are EXPR, see below)")
  iOut("    anchors                       list named anchors + variables")
  iOut("    let NAME EXPR                 bind a name to an address")
  iOut("    read EXPR TYPE                typed read")
  iOut("    write EXPR TYPE VALUE         typed write (needs `allow write`)")
  iOut("    dump EXPR [N]                 N raw bytes, hex + ascii")
  iOut("    fields EXPR [N]               per-8-byte-slot guess table")
  iOut("    scan EXPR N TYPE VALUE        find the offset of a value")
  iOut("    parent EXPR [DEPTH]           walk the Transform parent chain")
  iOut("    canvas EXPR                   the Graphic's cached Canvas + its mode")
  iOut("    call TARGET SIG [ARG..]       direct RVA call (needs `allow write`)")
  iOut("    targets [SUBSTR]              list byte-verified call targets")
  iOut("  -- state + navigation (navigation needs `allow write`) --")
  iOut("    state | where                 what screen/tab is up RIGHT NOW")
  iOut("                                  e.g.  state")
  iOut("    wait N                        park the batch for N frames")
  iOut("                                  e.g.  wait 10")
  iOut("    until EXPR [FRAMES]           park until the ptr at EXPR is non-0")
  iOut("                                  e.g.  until $settings+0x118 120")
  iOut("    open [GROUP]                  SettingsScreen::ShowScreen (async!)")
  iOut("                                  e.g.  allow write | open 0")
  iOut("    tab EXPR [0|1]                SettingsTab::set_IsSelected")
  iOut("                                  e.g.  tab $settings@0x118 1")
  iOut("    image                         GameAssembly base + il2cpp section")
  iOut("    allow write                   arm writes/calls for this batch")
  iOut("    echo TEXT                     put a marker in the output")
  iOut("  TYPE  i8 u8 i16 u16 i32 u32 i64 u64 f32 f64 ptr bool str klass")
  iOut("  EXPR  ATOM ( +0xNN | @0xNN )*   `+` moves, `@` DEREFERENCES")
  iOut("        ATOM is 0x<hex>, a decimal, or $name")
  iOut("        e.g.  $preloader@0x20        the version label")
  iOut("              $verlabel+0xe0         where TMP.m_text lives")
  iOut("  TARGET  name:<substring>  or  rva:0x<hex>[/<expected prologue hex>]")
  iOut("  SIG     <ret>_<args>, ret in v/b/i/l/p/f/s, args in p/i/b/f/l")
  iOut("        e.g.  s_p   String return, one pointer argument (get_name)")

# ---------------------------------------------------------------------------
# One command, executed. Called ONLY from inside the VEH guard.
# ---------------------------------------------------------------------------
proc iExec(line: string) =
  let toks = iSplit(line)
  if toks.len == 0:
    return
  let cmd = iLower(toks[0])
  if cmd.len > 0 and cmd[0] == '#':
    return
  iOut("> " & line)
  case cmd
  of "help", "?":
    iCmdHelp()
  of "echo":
    var s = ""
    for i in 1 ..< toks.len:
      if i > 1: s.add ' '
      s.add toks[i]
    iOut("  " & s)
  of "anchors":
    iCmdAnchors()
  of "image":
    iCmdImage()
  of "allow":
    if toks.len > 1 and iLower(toks[1]) == "write":
      if not gInspWriteOn:
        iErr("`allow write` refused: liveInspectorWrite is not set in " &
             "aowlspt-host.json. Reads still work.")
      else:
        gInspAllowWrite = true
        iOut("  writes and calls are armed FOR THIS BATCH ONLY")
    else:
      iErr("the only thing to allow is `write`")
  of "targets":
    var pat = ""
    if toks.len > 1:
      pat = toks[1]
    iCmdTargets(pat)
  of "let":
    if toks.len < 3:
      iErr("usage: let NAME EXPR")
    else:
      var v = 0'u64
      var err = ""
      if not iEval(toks[2], v, err):
        iErr(err)
      else:
        iSetVar(toks[1], v)
        iOut("  $" & toks[1] & " = " & iPtrU(v))
  of "read":
    if toks.len < 3:
      iErr("usage: read EXPR TYPE")
    else:
      var v = 0'u64
      var err = ""
      if not iEval(toks[1], v, err):
        iErr(err)
      else:
        var s = ""
        if iReadTyped(cast[Il2CppPtr](v), iLower(toks[2]), s):
          iOut("  " & iPtrU(v) & " as " & iLower(toks[2]) & " = " & s)
          if iLower(toks[2]) == "ptr":
            var raw = 0'u64
            var buf = default(array[8, uint8])
            if cInspReadBytes(cast[Il2CppPtr](v), 0'i32, 8'i32,
                              cast[ptr uint8](addr buf[0])) != 0'i32:
              for k in 0 ..< 8:
                raw = raw or (uint64(buf[k]) shl uint64(k * 8))
              iSetVar("_", raw)
        else:
          iErr(s)
  of "write":
    iCmdWrite(toks)
  of "dump", "fields":
    if toks.len < 2:
      iErr("usage: " & cmd & " EXPR [N]")
    else:
      var v = 0'u64
      var err = ""
      if not iEval(toks[1], v, err):
        iErr(err)
      else:
        var n = 128'u64
        if toks.len > 2 and not iParseU(toks[2], n):
          iErr("not a byte count: " & toks[2])
          return
        if n > uint64(InspMaxDumpBytes):
          n = uint64(InspMaxDumpBytes)
        if cmd == "dump":
          iCmdDump(cast[Il2CppPtr](v), int32(n))
        else:
          iCmdFields(cast[Il2CppPtr](v), int32(n))
  of "scan":
    if toks.len < 5:
      iErr("usage: scan EXPR N TYPE VALUE")
    else:
      var v = 0'u64
      var err = ""
      if not iEval(toks[1], v, err):
        iErr(err)
        return
      var n = 0'u64
      if not iParseU(toks[2], n):
        iErr("not a byte count: " & toks[2])
        return
      if n > uint64(InspMaxDumpBytes):
        n = uint64(InspMaxDumpBytes)
      iCmdScan(cast[Il2CppPtr](v), int32(n), iLower(toks[3]), toks[4])
  of "parent":
    if toks.len < 2:
      iErr("usage: parent EXPR [DEPTH]")
    else:
      var v = 0'u64
      var err = ""
      if not iEval(toks[1], v, err):
        iErr(err)
        return
      var d = 8'u64
      if toks.len > 2:
        discard iParseU(toks[2], d)
      iCmdParent(cast[Il2CppPtr](v), int(d))
  of "children":
    iErr("children is not reachable on this build: Transform's child accessors " &
         "are not in the byte-verified target tables and reflection is dead. " &
         "Walk UP with `parent` from an object you have already verified -- " &
         "that is how the settings-row container was reached.")
  of "open":
    iCmdOpen(toks)
  of "tab":
    iCmdTab(toks)
  of "state", "where":
    iCmdState(toks)
  of "wait", "until":
    # Handled by the batch runner itself, which has to park and resume across
    # frames. Reaching here means the runner did not intercept it, which would
    # be a bug in the runner rather than an unknown command -- say that plainly
    # instead of pretending the command does not exist.
    iErr(cmd & " was not intercepted by the batch runner; this is an internal " &
         "inconsistency, not a bad command. Nothing was waited on.")
  of "canvas":
    if toks.len < 2:
      iErr("usage: canvas EXPR   (EXPR is a Graphic, e.g. a TextMeshProUGUI)")
    else:
      var v = 0'u64
      var err = ""
      if not iEval(toks[1], v, err):
        iErr(err)
      else:
        iCmdCanvas(cast[Il2CppPtr](v))
  of "call":
    iCmdCall(toks)
  else:
    iErr("unknown command \"" & cmd & "\" -- try `help`")

# ---------------------------------------------------------------------------
# THE GUARD.
#
# ONE `aowl_p_p_seh` per command, never nested. Per command rather than per
# batch on purpose: a batch is twenty lines of exploration, and a bad address
# on line three must not hide lines four to twenty -- that is the whole point
# of the instrument. The guard carries exactly one pointer, so the command
# index goes in a global, exactly as `invoke2.nim`'s step number does.
# ---------------------------------------------------------------------------
{.emit: """
extern void* aowl_insp_body(void* a);
static void* aowl_insp_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_insp_body, a);
}
""".}
proc cInspGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_insp_guarded", nodecl.}

proc inspBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_insp_body", cdecl.} =
  ## STILL ONE `aowl_p_p_seh` PER ENTRY, AND STILL NEVER NESTED. The anchor
  ## refresh is dispatched through this same single body rather than getting a
  ## guard of its own precisely so that rule keeps holding: only one of the two
  ## branches runs per guarded call, and neither branch enters the guard again.
  if gInspBodyMode == 1:
    iRefreshAnchors()
  else:
    iExec(gInspCmds[gInspCurIdx])
  result = cast[Il2CppPtr](1)

# ---------------------------------------------------------------------------
# Unity's half: run the batch.
# ---------------------------------------------------------------------------
const InspWaitCap = 300
  ## Hard frame cap on any one `wait`/`until` -- about five seconds at 60fps.
  ## A condition that never comes true must not park the channel forever; it
  ## reports honestly and the batch CONTINUES, because the commands after a
  ## failed wait are usually the ones that explain why it failed.

var gInspWaitIdx = -1
  ## Which command index the current wait belongs to, so re-entry can tell
  ## "first frame of this wait" from "still waiting".

proc iIsWaitCmd(line: string): bool =
  let toks = iSplit(line)
  if toks.len == 0:
    return false
  let c = iLower(toks[0])
  result = (c == "wait" or c == "until")

proc iWaitStep(line: string; idx: int): bool =
  ## One frame's worth of a `wait`/`until`. Returns true when the batch may
  ## move on, false to park for another frame.
  ##
  ##   wait N            -- park for N frames, unconditionally.
  ##   until EXPR [N]    -- park until the pointer at EXPR reads non-zero,
  ##                        at most N frames (default the cap).
  ##
  ## `until` exists because navigation is asynchronous: `ShowScreen` returns
  ## long before the screen it asked for exists, so a script that reads
  ## `_currentTab` on the next line reads the value from BEFORE the open. That
  ## is not a race we can win by guessing a sleep length; it has to be a
  ## condition that is actually tested.
  let toks = iSplit(line)
  let verb = iLower(toks[0])
  let first = (gInspWaitIdx != idx)
  if first:
    gInspWaitIdx = idx
    var frames = InspWaitCap
    let argIdx = (if verb == "wait": 1 else: 2)
    if toks.len > argIdx:
      var n = 0'u64
      var err = ""
      if iEval(toks[argIdx], n, err) and int(n) > 0:
        frames = int(n)
    if frames > InspWaitCap:
      frames = InspWaitCap
    gInspUntilLeft = frames
    if verb == "until" and toks.len < 2:
      iErr("usage: until EXPR [FRAMES]  -- waits until the ptr at EXPR is non-zero")
      gInspWaitIdx = -1
      return true
    iOut("  " & verb & ": waiting up to " & $frames & " frame(s)" &
         (if verb == "until": " for " & toks[1] & " to read non-zero" else: ""))
  if verb == "until":
    var v = 0'u64
    var err = ""
    if iEval(toks[1], v, err):
      var raw = 0'u64
      var buf = default(array[8, uint8])
      if cInspReadBytes(cast[Il2CppPtr](v), 0'i32, 8'i32,
                        cast[ptr uint8](addr buf[0])) != 0'i32:
        for k in 0 ..< 8:
          raw = raw or (uint64(buf[k]) shl uint64(k * 8))
        if raw != 0'u64:
          iOut("  until: satisfied after " &
               $(gInspUntilLeft.abs) & " frame(s) remaining; value = " &
               iPtrU(raw))
          iSetVar("_", raw)
          gInspWaitIdx = -1
          return true
  dec gInspUntilLeft
  if gInspUntilLeft <= 0:
    # A TIMEOUT IS REPORTED, NOT SWALLOWED, and the batch goes on.
    if verb == "until":
      iErr("until: TIMED OUT -- " & toks[1] & " never read non-zero within " &
           "the frame cap. The batch continues; the commands after this one " &
           "will show what the state actually is.")
    gInspWaitIdx = -1
    return true
  result = false

proc inspRunBatch() =
  # A RESUMED batch keeps everything: its output so far, its variables, and its
  # write permission. Only a genuinely new batch starts clean. Getting this
  # wrong would silently drop the first half of every batch that waited.
  let resuming = gInspSuspended
  if not resuming:
    gInspOut = @[]
    gInspOutBytes = 0
    gInspAllowWrite = false
    gInspResumeAt = 0
  gInspSuspended = false
  # THE ANCHOR REFRESH IS NOW GUARDED. It was not, and it sits between "the
  # rider observed a pending batch" and "the rider cleared the pending flag" --
  # so anything that escaped here left the flag set forever, produced no
  # breadcrumb (only the per-command guard writes one), incremented no fault
  # counter and tripped no self-disable. That is exactly the silent 537-times
  # stall that was observed: dispatched, saw the batch, never finished it, said
  # nothing. It reads live IL2CPP object fields off pointers cached from
  # earlier frames, which is precisely the class of thing that needs a guard.
  gInspPhase = 1
  gInspBodyMode = 1
  iMark("anchor refresh (start of batch)", gInspPreloader)
  let anchorsOk = cInspGuarded(cast[Il2CppPtr](0)) != nil
  gInspBodyMode = 0
  if not resuming:
    iOut("aowlspt live inspector -- batch " & $gInspBatch & ", " &
         $gInspCmds.len & " command(s), on Unity thread " & $int(cThreadId()))
  if not anchorsOk:
    inc gInspFaults
    iOut("  !! the anchor refresh FAULTED (caught; the game survived). " &
         "LAST HOP: " & readCString(cInspCrumb()) & "  at " &
         iPtr(cInspCrumbPtr()))
    iOut("  !! anchors may be stale or missing for this batch; the commands " &
         "below still ran")
  var i = gInspResumeAt
  while i < gInspCmds.len:
    gInspPhase = 2
    gInspCurIdx = i
    # A `wait`/`until` parks the batch HERE and returns. The rider re-enters
    # next frame and resumes at this same index, so the condition is retested
    # once per frame with a hard frame cap.
    if iIsWaitCmd(gInspCmds[i]):
      if iWaitStep(gInspCmds[i], i):
        inc i
        gInspResumeAt = i
        continue
      gInspResumeAt = i
      gInspSuspended = true
      gInspPhase = 0
      return
    iMark(("start of command: " & gInspCmds[i]), cast[Il2CppPtr](0))
    if cInspGuarded(cast[Il2CppPtr](0)) == nil:
      # THE ONE LINE THIS WHOLE FEATURE EXISTS TO MAKE POSSIBLE. A caught fault
      # that does not say where it landed is worth almost nothing; this names
      # the last hop attempted and the pointer it was attempted on.
      inc gInspFaults
      iOut("  !! FAULTED (caught; the game survived). LAST HOP: " &
           readCString(cInspCrumb()) & "  at " & iPtr(cInspCrumbPtr()))
      iOut("  !! fault " & $gInspFaults & " of " & $InspMaxFaults &
           " before the inspector switches itself off for this session")
      if gInspFaults >= InspMaxFaults:
        gInspOff = true
        iOut("  !! too many faults; the live inspector is now OFF for this " &
             "session. Restart the client to re-arm it.")
        i = gInspCmds.len
    inc i
  gInspResumeAt = 0
  gInspWaitIdx = -1
  iOut("aowlspt live inspector -- batch " & $gInspBatch & " complete, " &
       $gInspOut.len & " line(s)")

proc inspTick() =
  ## Called once per frame from the shared `PreloaderUI::Update` firing. The
  ## lock-free `aowl_insp_have` is the whole per-frame cost when there is
  ## nothing queued -- one interlocked load and a not-taken branch, the same
  ## discipline `mainDrain` follows.
  if gInspOff:
    return
  # ESCAPE RECOVERY. If a batch is still marked in-flight when the rider is
  # next entered, the previous run did not return normally -- it left through
  # a longjmp, taking the completion handshake with it. An escape cannot log
  # itself, by definition, so it is detected here on the following frame and
  # reported then. Without this the channel simply stops, which is what it did.
  if gInspInFlight >= 0:
    let escaped = gInspInFlight
    let phase = gInspPhase
    gInspInFlight = -1
    gInspPhase = 0
    gInspBodyMode = 0
    inc gInspEscapes
    iOut("  !! batch " & $escaped & " ESCAPED its guard during " &
         (if phase == 1: "the anchor refresh"
          elif phase == 2: "command " & $(gInspCurIdx + 1) &
                           " (" & gInspCmds[gInspCurIdx] & ")"
          else: "the completion handshake") &
         " -- it did not return normally. LAST HOP: " &
         readCString(cInspCrumb()) & "  at " & iPtr(cInspCrumbPtr()))
    iOut("  !! the channel has been recovered; whatever ran before the escape " &
         "is above. Escapes this session: " & $gInspEscapes)
    cInspLock()
    gInspBatchDone = escaped
    cInspUnlock()
    if gInspEscapes >= InspMaxFaults:
      gInspOff = true
      iOut("  !! too many escapes; the live inspector is now OFF for this " &
           "session. Restart the client to re-arm it.")
    return
  # RESUME A PARKED BATCH. The pending flag was consumed when the batch was
  # first claimed, so this path is not gated on it -- the batch is already
  # ours and is simply not finished.
  if gInspSuspended:
    gInspInFlight = gInspBatch
    inspRunBatch()
    gInspInFlight = -1
    if gInspSuspended:
      return
    cInspLock()
    gInspBatchDone = gInspBatch
    cInspUnlock()
    return
  if cInspHave() == 0'i32:
    return
  inc gInspTicks
  # CONSUME THE FLAG BEFORE RUNNING, NOT AFTER.
  #
  # The flag used to be cleared on the line AFTER `inspRunBatch()`, so anything
  # that escaped the batch skipped the clear and left the channel wedged at
  # pending=1 for the rest of the session -- every later edit to the command
  # file ignored, with no explanation. Claiming the batch first makes that
  # impossible: once the rider has taken a batch, the flag is down whatever
  # happens next, and a failure costs one batch instead of the channel.
  cInspSetPending(0'i32)
  gInspInFlight = gInspBatch
  inspRunBatch()
  gInspPhase = 3
  gInspInFlight = -1
  gInspPhase = 0
  # A SUSPENDED batch is not a finished batch. Publishing the handshake here
  # would hand a half-run batch's output to the tick thread as if it were the
  # answer, and the rest of the commands would then run against a channel that
  # had already been reset.
  if gInspSuspended:
    return
  cInspLock()
  gInspBatchDone = gInspBatch
  cInspUnlock()

proc inspectFired(regs: Il2CppPtr) =
  ## The rider on `EFT.UI.PreloaderUI::Update`, dispatched by slot identity from
  ## `patchFired`. RCX is the live `PreloaderUI` -- captured as the ROOT ANCHOR
  ## and otherwise untouched. This never suppresses the original.
  ##
  ## The counter is incremented FIRST, before any early-out, because its whole
  ## job is to answer "was this rider dispatched at all?" -- a counter that only
  ## advanced when the rider did work could not answer that question.
  inc gInspFires
  if not gInspFiredLogged:
    gInspFiredLogged = true
    # THE TIMESTAMP THAT MAKES THE LOG READABLE. `PreloaderUI::Update` does not
    # tick until the client leaves the loading screen, which on a cold start is
    # many seconds after the host has armed and after the first batch may
    # already have been handed over. Without this line that gap is invisible and
    # a batch that was simply EARLY looks identical to a rider that is broken.
    okLog "live inspector: rider FIRST DISPATCHED on thread " &
          $int(cThreadId()) & " (slot " & $gInspSlot & "); " &
          "EFT.UI.PreloaderUI::Update is now ticking and batches will drain"
  if gInspOff:
    return
  let selfPtr = cRegsInt(regs, 0'i32)
  if selfPtr != 0'u64:
    gInspPreloader = cast[Il2CppPtr](selfPtr)
  inspTick()

proc inspectDrainFired() =
  ## THE IN-RAID ENTRY POINT, from the main drain's slot.
  ##
  ## Deliberately NOT `inspectFired`: on that anchor RCX is a
  ## `TarkovApplication`, not a `PreloaderUI`, and writing it into
  ## `gInspPreloader` would poison the `$preloader` anchor with an object of
  ## the wrong type -- every field read off it would then be garbage that
  ## looked plausible. So this touches no anchor at all and only drains.
  ##
  ## Counted separately for the same reason `gInspFires` exists: so the log can
  ## say WHICH anchor is carrying the session rather than leaving it to be
  ## inferred.
  inc gInspFires
  inc gInspDrainFires
  if gInspOff:
    return
  inspTick()

# ---------------------------------------------------------------------------
# The host thread's half: the file channel.
# ---------------------------------------------------------------------------
proc inspWriteOut() =
  ## The answer, as a file beside the DLL and as log lines. Both, deliberately:
  ## the file is what a script reads, the log is what the human watching the
  ## console sees, and a channel that only did one of those would be missing
  ## half of the human-in-the-loop situation this exists for.
  var text = ""
  cInspLock()
  for i in 0 ..< gInspOut.len:
    text.add gInspOut[i]
    text.add "\n"
  cInspUnlock()
  discard writeTextFile(gInspOutPath, text)
  let lines = iLines(text)
  for i in 0 ..< lines.len:
    okLog "inspect| " & lines[i]

proc inspectPoll(now: uint64) =
  ## On the host's own tick thread, from the tick loop. Reads the command file
  ## only when its CONTENT has changed, so an idle session costs one shared
  ## file open every 250 ms and nothing else.
  ##
  ## Content-change is the trigger rather than a timestamp because a timestamp
  ## on a network or editor-rewritten file is the least reliable thing about
  ## it. To run the same commands twice, change a comment line -- which is what
  ## the shell driver does with a serial number.
  if not gInspOn or gInspOff:
    return
  # The answer, whenever Unity has finished one.
  var done = -1
  cInspLock()
  done = gInspBatchDone
  cInspUnlock()
  if done >= 0 and done == gInspBatch and cInspHave() == 0'i32 and
     gInspOut.len > 0:
    inspWriteOut()
    gInspHandedMs = 0'u64
    cInspLock()
    gInspBatchDone = -1
    gInspOut = @[]
    cInspUnlock()
  if now < gInspNextPollMs:
    return
  gInspNextPollMs = now + 250'u64
  if cInspHave() != 0'i32:
    # THE EARLY-BATCH CASE, AND WHY IT IS NOT A TIMEOUT.
    #
    # `EFT.UI.PreloaderUI::Update` does not tick until the client is off the
    # loading screen. On a cold start the host arms, the command file is read,
    # and a batch is handed over MANY SECONDS before the rider is first
    # dispatched -- measured live at 1.3s vs 15.5s. The old code started an 8s
    # stopwatch at handover, so that first batch was declared "never picked up"
    # SIX SECONDS BEFORE THE DETOUR HAD EVER RUN, and then DISCARDED it: it
    # cleared the pending flag and wiped the output buffer. The commands were
    # destroyed while the machinery underneath them was perfectly healthy, and
    # the report blamed the dispatch.
    #
    # A stopwatch is the wrong instrument here. The question is not "how long
    # has this been queued" but "has the thing that drains it run AT ALL". If
    # the rider has never been dispatched, the batch has not yet had its
    # chance, so it WAITS -- indefinitely, and without losing anything. The
    # timeout below now means what it always claimed to mean: the rider is
    # demonstrably running and STILL is not draining the queue.
    if gInspFires == 0:
      if gInspHandedMs != 0'u64 and now - gInspHandedMs > InspStuckMs and
         gInspWaitBatch != gInspBatch:
        gInspWaitBatch = gInspBatch
        okLog "live inspector: batch " & $gInspBatch & " is QUEUED and will " &
              "run as soon as EFT.UI.PreloaderUI::Update starts ticking -- " &
              "the rider (slot " & $gInspSlot & ") has not been dispatched " &
              "yet, which on a cold start just means the client is still on " &
              "the loading screen. Nothing has been lost; reach the MENU."
      return
    if gInspHandedMs != 0'u64 and now - gInspHandedMs > InspStuckMs:
      # Read the flag BEFORE clearing it. The previous version cleared pending
      # on the line above the report and then printed "pending flag now = 0",
      # which is self-inflicted and reads as evidence of a bug that is not
      # there.
      let pendingAtReport = int(cInspHave())
      cInspSetPending(0'i32)
      gInspHandedMs = 0'u64
      cInspLock()
      gInspOut = @[]
      gInspOutBytes = 0
      cInspUnlock()
      iOut("aowlspt live inspector -- batch " & $gInspBatch &
           " was never picked up by Unity's thread within " &
           $int(InspStuckMs div 1000'u64) & "s.")
      iOut("  The commands did NOT run. (The rider HAS been dispatched " &
           $gInspFires & " time(s), so this is a real stall, not a batch " &
           "that simply arrived before the detour started ticking.)")
      iOut("  pending flag as the timeout found it = " & $pendingAtReport)
      # THE THREE HYPOTHESES, SEPARATED BY MEASUREMENT rather than by prose.
      # Every previous version of this message guessed; these counters know.
      iOut("  inspector slot = " & $gInspSlot &
           " (-1 means nothing is armed); rider dispatched " & $gInspFires &
           " time(s); ran with a batch pending " & $gInspTicks & " time(s); " &
           "self-disabled = " & $gInspOff)
      if gInspSlot < 0:
        iOut("  DIAGNOSIS: NOT ARMED. Nothing claimed or aliased the " &
             "EFT.UI.PreloaderUI::Update slot, so there is nothing to run " &
             "from. Look for a line starting 'live inspector armed'.")
      elif gInspTicks == 0:
        iOut("  DIAGNOSIS: DISPATCHED BUT NEVER SAW THE BATCH. The rider ran " &
             $gInspFires & " time(s) but the pending flag read 0 every time, " &
             "so the HANDOFF is what is broken, not the detour and not the " &
             "dispatch.")
      elif gInspFaults > 0 or gInspEscapes > 0:
        iOut("  DIAGNOSIS: the rider saw the batch and did not complete it, " &
             "and there IS recorded evidence of why: " & $gInspFaults &
             " caught fault(s) and " & $gInspEscapes & " guard escape(s) " &
             "this session. The last hop attempted is above.")
      else:
        # NO EVIDENCE MEANS NO ACCUSATION. The previous text asserted "suspect
        # a fault that escaped the per-command guard" whenever it got this far,
        # while self-disabled was false and no breadcrumb existed anywhere --
        # a confident wrong answer that cost a full cycle. State only what was
        # actually measured.
        iOut("  DIAGNOSIS: the rider saw the batch and DECLINED before " &
             "executing it. No fault and no guard escape was recorded, so " &
             "this is not a crash being swallowed -- some gate between the " &
             "pending check and execution returned early. Every such gate " &
             "logs its reason; look for a 'declined' line above.")
      inspWriteOut()
      cInspLock()
      gInspOut = @[]
      cInspUnlock()
    return
  var text = ""
  if not readShared(gInspCmdPath, text):
    return
  if text == gInspLastText:
    return
  gInspLastText = text
  var cmds: seq[string] = @[]
  let lines = iLines(text)
  for i in 0 ..< lines.len:
    let toks = iSplit(lines[i])
    if toks.len == 0:
      continue
    if toks[0].len > 0 and toks[0][0] == '#':
      continue
    if cmds.len >= InspMaxCmds:
      break
    cmds.add lines[i]
  if cmds.len == 0:
    # NOT SILENT. The file changed, so the user did something and is waiting
    # for an answer; "every line was blank or a #comment" is that answer.
    # `#`-prefixed serial lines are skipped by design, so a file containing
    # ONLY a bumped serial lands here and would otherwise look like a hang.
    info "live inspector: the command file changed but parsed to 0 commands " &
         "(every line was blank or a #comment). Nothing was queued."
    return
  inc gInspBatch
  cInspLock()
  gInspCmds = cmds
  gInspBatchDone = -1
  cInspUnlock()
  cInspSetPending(1'i32)
  gInspHandedMs = now
  info "live inspector: batch " & $gInspBatch & " (" & $cmds.len &
       " command(s)) handed to Unity's thread; answers land in " & gInspOutPath

proc inspectInit(dir: string) =
  ## Paths and the first-run template. Writing the template is the cheapest
  ## documentation there is: the file the player must edit already exists and
  ## already says what to put in it.
  gInspCmdPath = joinPath(dir, "aowlspt-inspect.txt")
  gInspOutPath = joinPath(dir, "aowlspt-inspect-out.txt")
  if not gInspOn:
    return
  var existing = ""
  if not readShared(gInspCmdPath, existing):
    discard writeTextFile(gInspCmdPath,
      "# aowlspt live inspector -- edit this file while the game runs.\n" &
      "# Every SAVE with changed content runs the whole file on Unity's main\n" &
      "# thread; answers appear in aowlspt-inspect-out.txt and in the host log.\n" &
      "# To re-run unchanged commands, bump this serial:  serial 1\n" &
      "help\n" &
      "anchors\n")
  # Seed the namespace so `anchors` says something before the first frame.
  iSetVar("_", 0'u64)

proc bindInspect(verbose: bool): bool =
  ## THE THIRD RIDER on `EFT.UI.PreloaderUI::Update`.
  ##
  ## When another rider has already claimed the slot this ALIASES onto it and
  ## does not verify at all -- there is nothing to verify, since it is not
  ## installing a detour, only adding a dispatch arm to one that exists.
  ##
  ## When it DOES have to attach its own, it verifies through
  ## `cDuPreloaderTarget`, which since the prologue-snapshot fix compares
  ## against the ORIGINAL bytes recorded by `aowl_pro_prime_all` before any
  ## feature bound (`abi/aowlspt_prologue.h`), not against live memory. So the
  ## check is exact and strict and CANNOT self-reject because another feature
  ## detoured the function first -- which was the live trap that produced
  ## "menu mode text: 0 target(s) verified, 1 rejected" on a correct RVA.
  # THE SECOND ANCHOR, claimed first because it is the one that survives a raid
  # load. This is an ALIAS onto the slot the bridge's main drain already holds
  # (`EFT.TarkovApplication::Update`, which ticks for the whole session); no
  # second detour is installed, so the documented crash history of the
  # static-RVA path for that function is not in play here. When the bridge
  # never bound a drain this stays -1 and the inspector is menu-only.
  if gInspSlot2 < 0 and gDrainSlot >= 0:
    gInspSlot2 = gDrainSlot
    okLog "live inspector: IN-RAID anchor armed as a rider on the main " &
          "drain's existing detour (slot " & $gInspSlot2 & ") -- commands " &
          "will keep running after the menu goes away"
  if gInspSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  if gDebugUiSlot >= 0:
    gInspSlot = gDebugUiSlot
    okLog "live inspector armed as a RIDER on the debug overlay's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gInspSlot & ")"
    return true
  if gModeTextSlot >= 0:
    gInspSlot = gModeTextSlot
    okLog "live inspector armed as a RIDER on the menu mode-text feature's " &
          "existing EFT.UI.PreloaderUI::Update detour (slot " & $gInspSlot & ")"
    return true
  let fn = cDuPreloaderTarget()
  if fn == nil:
    if verbose:
      info "live inspector: EFT.UI.PreloaderUI::Update did not verify on this " &
           "build and no other feature holds it; the MENU anchor is not armed"
    # Not a failure if the in-raid anchor took: the instrument still works,
    # just not on the menu. Saying "nothing bound" when one anchor IS bound
    # would be the same kind of confident-and-wrong message this file has
    # already cost cycles to.
    return gInspSlot2 >= 0
  if attachDrain("EFT.UI.PreloaderUI::Update", fn, cast[Il2CppMethod](0),
                 true, verbose, 14'i32):
    okLog "live inspector armed on EFT.UI.PreloaderUI::Update (per-frame, " &
          "Unity thread); drop commands into " & gInspCmdPath
    return true
  result = gInspSlot2 >= 0
