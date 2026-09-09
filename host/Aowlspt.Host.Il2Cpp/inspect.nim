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
## PRIMED EAGERLY, and this note used to say the opposite. It said the lazy
## capture was correct here because "nothing detours either of these at all".
## That was wrong, and it cost a live diagnosis: `settingsui.nim` puts a
## postfix detour on `SettingsScreen::ShowScreen`, so by the time the inspector
## first verified that target the bytes there were our own JMP, the lazy
## snapshot recorded the trampoline as the original, and `open` refused a
## correct target while blaming the game build.
##
## `aowl_pro_prime_all` is emitted before this file and so cannot NAME this
## table -- but it can call a function that does, which is what
## `aowl_pro_prime_navui` below is. It is defined here, where the table is
## visible, and called from there, where the ordering guarantee lives.
{.emit: """#include "aowlspt_navui.h" """.}
## COMPONENT ENUMERATION. Included after `aowlspt_navui.h` (it reuses the array
## offsets that file established) and after `aowlspt_nameindex.h`, which
## `aowlhost.nim` emits far earlier -- the type table lives in the SAME index
## file as the method table, so there is one build stamp and one artifact.
{.emit: """#include "aowlspt_components.h" """.}
{.emit: """
static void aowl_pro_prime_navui(void) {
    int32_t i;
    for (i = 0; i < aowl_nav_target_count(); i++)
        aowl_pro_prime(aowl_nav_target_rva(i));
}
""".}
proc cNavTargetCount(): int32 {.importc: "aowl_nav_target_count", nodecl.}
proc cNavFn(i: int32): Il2CppPtr {.importc: "aowl_nav_target_at", nodecl.}
proc cNavName(i: int32): cstring {.importc: "aowl_nav_target_name", nodecl.}
proc cNavRva(i: int32): uint32 {.importc: "aowl_nav_target_rva", nodecl.}
proc cNavOffCurrentTab(): int32 {.importc: "aowl_nav_off_currenttab", nodecl.}
proc cNavOffInitTabs(): int32 {.importc: "aowl_nav_off_inittabs", nodecl.}
proc cNavOffFirstSel(): int32 {.importc: "aowl_nav_off_firstsel", nodecl.}
proc cNavOffCreated(): int32 {.importc: "aowl_nav_off_created", nodecl.}
proc cNavOffOnClick(): int32 {.importc: "aowl_nav_off_onclick", nodecl.}
proc cNavOffInteract(): int32 {.importc: "aowl_nav_off_interact", nodecl.}
proc cNavOffIsOn(): int32 {.importc: "aowl_nav_off_ison", nodecl.}
proc cNavOffCachedPtr(): int32 {.importc: "aowl_nav_off_cachedptr", nodecl.}
proc cNavOffCurSelected(): int32 {.importc: "aowl_nav_off_curselected", nodecl.}
proc cNavOffArrLen(): int32 {.importc: "aowl_nav_off_arrlen", nodecl.}
proc cNavOffArrData(): int32 {.importc: "aowl_nav_off_arrdata", nodecl.}
proc cNavSetSceneHandle(h: int32) {.importc: "aowl_nav_set_scene_handle", nodecl.}
proc cNavSceneHandlePtr(): Il2CppPtr {.
  importc: "aowl_nav_scene_handle_ptr", nodecl.}
proc cNavIcallReady(): int32 {.importc: "aowl_nav_icall_ready", nodecl.}
proc cNavNewString(s: cstring): Il2CppPtr {.
  importc: "aowl_mi2_string_new", nodecl.}
## The reflection-based System.Type route (il2cpp_class_from_name ->
## class_get_type -> type_get_object) is DELIBERATELY NOT BOUND HERE. It is
## implemented and documented in `aowlspt_navui.h`, but the string overload of
## GetComponent needs none of it, and this build's standing verdict is that
## most of the reflection surface faults with no probe result ever recorded.
## Binding an unproven fallback that is never reached would be dead risk.
## CLICK-RECORDER MOUSE EDGE. Read via Win32 GetAsyncKeyState(VK_LBUTTON), NOT
## through IL2CPP: UnityEngine.Input is not in the verified nav table, and a
## plain kernel/user32 call cannot fault inside Unity's C++ the way a managed
## icall on a dead wrapper can. This is a pure native read of the OS's async
## key state -- cheap enough to poll every armed frame, and it touches no
## managed object at all, so it stays outside the IL2CPP guard's concerns.
{.emit: """
static int32_t aowl_rec_lbutton_down(void) {
    return (GetAsyncKeyState(VK_LBUTTON) & 0x8000) ? 1 : 0;
}
""".}
proc cRecLButtonDown(): int32 {.importc: "aowl_rec_lbutton_down", nodecl.}
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

# ---- struct-by-value RETURN decoding, borrowed from aowlspt_debugui.h ----
#
# MEASURED (abi/aowlspt_debugui.h, dumped prologues, not assumed): on this
# build's Win64 IL2CPP ABI, a Vector2 (8 bytes) comes back PACKED IN RAX --
# `aowl_insp_u_p` (already used above for plain pointer/int returns) captures
# it unmodified, so decoding it is just unpacking the same uint64 two floats
# were memcpy'd into on the way out. A Vector3 (12 bytes) or Rect (16 bytes)
# is bigger than 8 bytes, so Win64 returns it through a HIDDEN BUFFER
# (retbuf in RCX, this in RDX, MethodInfo* in R8) -- `aowl_du_call_sret_p`
# is that shape, already proven live by the overlay's `get_rect` reads.
# These are the SAME C statics debugui.nim's thunks use (one nimony TU), so
# no second copy of the sret plumbing is written here.
proc cDuCallUP2(fn, self: Il2CppPtr): uint64 {.
  importc: "aowl_du_call_u_p", nodecl.}
proc cDuVec2X2(packed: uint64): float64 {.importc: "aowl_du_vec2_x", nodecl.}
proc cDuVec2Y2(packed: uint64): float64 {.importc: "aowl_du_vec2_y", nodecl.}
proc cDuCallSretP2(fn, self: Il2CppPtr; nfloats: int32): int32 {.
  importc: "aowl_du_call_sret_p", nodecl.}
proc cDuSret0_2(): float64 {.importc: "aowl_du_sret_0", nodecl.}
proc cDuSret1_2(): float64 {.importc: "aowl_du_sret_1", nodecl.}
proc cDuSret2_2(): float64 {.importc: "aowl_du_sret_2", nodecl.}
proc cDuSret3_2(): float64 {.importc: "aowl_du_sret_3", nodecl.}
proc cInspF32Bits(v: float32): uint32 {.importc: "aowl_insp_f32_to_bits", nodecl.}
proc cInspF64Bits(v: float64): uint64 {.importc: "aowl_insp_f64_to_bits", nodecl.}

# ---------------------------------------------------------------------------
# THE F2 LIVE-INSPECTOR OVERLAY CAPTURE TAP (abi/aowlspt_inspoverlay.h)
#
# A ring of the inspector's recent commands + answer lines, plus a snapshot of
# its bound anchors, both written from HERE (Unity's thread, as a batch runs)
# and read by the D3D11 overlay in `Present` to draw the F2 panel -- see
# `inspoverlay.nim`, included right after this file. The native side owns the
# lock, the fixed buffers and the truncation; this side only feeds it. Every
# feed is gated on `gIoCapture`, which stays false (zero cost) until the overlay
# feature actually arms itself, so a build with `inspectorOverlay` off pays
# nothing but a not-taken branch on each answer line.
# ---------------------------------------------------------------------------
{.emit: """#include "aowlspt_inspoverlay.h" """.}
proc cIoPush(kind: int32; s: cstring) {.importc: "aowl_io_push", nodecl.}
proc cIoAnchorBegin() {.importc: "aowl_io_anchor_begin", nodecl.}
proc cIoAnchorAdd(s: cstring) {.importc: "aowl_io_anchor_add", nodecl.}
proc cIoAnchorCommit() {.importc: "aowl_io_anchor_commit", nodecl.}

var gIoCapture = false   ## set true by inspoverlay.nim once the panel is armed
var gIoTapBuf: array[64, char]   ## Unity-thread scratch; nimony forbids cstring()

proc ioBufC(s: string): cstring =
  ## Copy a Nim string into a fixed NUL-terminated char buffer and hand back a
  ## cstring to it -- nimony refuses `cstring(nonLiteral)`, and the C side copies
  ## immediately (under its own lock), so reusing one buffer is safe. Written on
  ## Unity's thread only, sequentially, so no second writer races it.
  var n = s.len
  if n > 63: n = 63
  for i in 0 ..< n:
    gIoTapBuf[i] = s[i]
  gIoTapBuf[n] = chr(0)
  cast[cstring](addr gIoTapBuf[0])

proc ioTap(kind: int32; s: string) {.inline.} =
  ## One captured activity line. The C side reads and truncates to 63, so a huge
  ## `dump` line costs one bounded copy, not an unbounded one.
  if gIoCapture:
    cIoPush(kind, ioBufC(s))

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
  InspFlightRepMs  = 10000'u64
    ## How long a batch may be handed over and undelivered before the host says
    ## so, unconditionally. Deliberately SHORTER than every other bound here and
    ## deliberately without preconditions: the other reports each describe one
    ## specific cause and each has a gate that can be false, which is how a
    ## batch handed at 3.3s produced not one line in the following three
    ## minutes. This one only knows that a batch went in and nothing came out.
  InspFlightRepEvery = 15000'u64
    ## And how often it repeats while that stays true, so a genuinely long
    ## `until` costs a line every 15s rather than four a second.
  InspDeadlineMs   = 30000'u64
    ## HOW LONG A CLAIMED BATCH MAY RUN BEFORE THE CHANNEL ABANDONS IT.
    ##
    ## Before this existed, one command that never returned to the dispatcher
    ## cost the channel for the WHOLE SESSION: every later batch was ignored and
    ## the out file served the stuck batch's answers forever. Losing one batch's
    ## answers is vastly better than losing the instrument, so after this long
    ## the batch is abandoned, loudly, and the poll is re-armed.
    ##
    ## Generous on purpose: a legitimate batch parks on `wait`/`until` for many
    ## frames, and 30s is far beyond any honest one while still being a fraction
    ## of the session the old behaviour destroyed.
  InspDeadlineFires = 900
    ## AND the rider must have been dispatched at least this many times since the
    ## claim. This is the half of the deadline that keeps it safe during a raid
    ## load: issuing commands while a raid loads stalls the Unity main thread
    ## (facts #245/#261), so wall-clock alone would abandon a batch that was
    ## simply waiting for a frame that had not come yet. At ~60fps this is ~15s
    ## of REAL ticking, so both bounds must be satisfied and the slower one wins.

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
var gKlassSeen: seq[uint64] = @[]
  ## KLASS POINTERS OBSERVED THIS SESSION.
  ##
  ## Every managed object begins with a pointer to its Il2CppClass, so walking
  ## the hierarchy hands us a klass pointer for free at every node. Keeping the
  ## distinct ones lets a field read be sanity-checked: if a slot that is
  ## supposed to hold a managed OBJECT contains a value we have already seen as
  ## the TYPE of something, that field is not what we think it is and the
  ## offset is being read off the wrong kind of object.
  ##
  ## This is not hypothetical. `click` on a Transform read +0x100 and got
  ## 0x...f2f0a0, which was the RectTransform klass -- and reported it as
  ## `m_OnClick`. Two different "Buttons" produced the identical value, which
  ## is impossible for a real per-instance UnityEvent and was the tell.
var gFindQueue: seq[Il2CppPtr] = @[]
var gFindHead = 0
var gFindWant = ""
var gFindVisited = 0
var gFindInvalidSkips = 0
  ## Dequeued nodes that failed `duOk`/`iUnityAlive` and were never actually
  ## examined -- counted separately from `gFindVisited` so a search whose
  ## ENTIRE frontier was garbage cannot be reported as "searched
  ## EXHAUSTIVELY, genuinely NOT PRESENT". Visiting nothing valid is not the
  ## same fact as searching everything and finding nothing.
var gFindFound = 0
var gFindActive = false
var gFindBudgetLeft = 0
  ## Nodes still allowed to THIS search, carried across frames. The time slice
  ## bounds one frame's work; this bounds the whole search. Separating them is
  ## what lets a search span frames without ever being able to run away.
var gFindSuspend = false
  ## Set when a search ran out of TIME but not budget. The batch runner parks
  ## the batch and re-enters the same command next frame, so a deep hierarchy
  ## is walked over several frames automatically instead of making a human
  ## type `find more` repeatedly.
var gFindOwnerIdx = -1
var gFindOwnerBatch = -1
  ## Which command of which BATCH owns the in-progress search, so re-entering
  ## that command RESUMES it instead of starting it again from the root.
  ##
  ## The batch number matters and is not belt-and-braces: `find more` keeps a
  ## search alive ACROSS batches by design, so without it a later batch whose
  ## command at the same index happened to be a different `find` would silently
  ## resume the OLD search and report matches for the wrong name.
var gFindFrames = 0
  ## A `find` that stopped on a cap leaves its frontier here, so `find more`
  ## continues instead of re-walking the nodes it already rejected. Restarting
  ## a capped search from scratch can never reach past the cap, which made the
  ## cap message's own advice impossible to follow.
var gTxtQueue: seq[Il2CppPtr] = @[]
var gTxtHead = 0
var gTxtWant = ""
var gTxtVisited = 0
var gTxtInvalidSkips = 0
var gTxtActiveOnly = true
  ## default ACTIVE-ONLY, matching `aowl ui`'s default -- a hit on an
  ## inactive node hands the caller a control it cannot press (fact #72:
  ## pressing one returns ok=True and does nothing). `findtext SUBSTR ... all`
  ## opts into including inactive nodes, same spelling family as `aowl ui`'s
  ## `--all`.
var gTxtInactiveSkipped = 0
var gTxtActiveUnknown = 0
  ## Hits whose activeInHierarchy could NOT be established (the runtime call
  ## did not answer, or it DISAGREED with the parent chain). These are neither
  ## skipped nor presented as pressable: "I could not look" is not a pass.
var gTxtActiveNote = ""
  ## First activeInHierarchy disagreement/derivation note of this search, so
  ## the report can say WHY a hit is tagged UNKNOWN instead of leaving the
  ## reader to guess.
var gTxtFound = 0
var gTxtActive = false
var gTxtBudgetLeft = 0
var gTxtOwnerIdx = -1
var gTxtOwnerBatch = -1
var gTxtFrames = 0
var gTmpTypeObj: Il2CppPtr = nil
  ## The live `System.Type` for `TMPro.TextMeshProUGUI`, resolved through the
  ## OFFLINE name index (no reflection) once per frame slice. This replaced
  ## the "TextMeshProUGUI" managed string that
  ## `GetComponent(String)` never matched -- see `iInspSeedTextType`.
var gTxtSeedWhy = ""
var gTxtTmpSeen = 0
  ## THE POSITIVE CONTROL. How many nodes this search found a TMP component
  ## ON -- not how many matched the substring. Zero TMP components across a
  ## large, active subtree does not mean the text is absent; it means the
  ## predicate is not seeing components at all, and the verdict must say so.
var gTxtTmpNull = 0
var gTxtTmpKlass = 0'u64
var gTxtKlassNote = ""
  ## `findtext` state, deliberately separate from `find`'s own -- same shape,
  ## same resume contract (see gFindQueue et al. above), but a DIFFERENT
  ## search so the two verbs never stomp each other's frontier. The type
  ## handle is `gTmpTypeObj` above: a System.Type resolved once per frame
  ## slice, never per node, and `GetComponent(Type)` allocates nothing -- so
  ## the predicate stays out of the per-frame-managed-allocation trap that
  ## the old per-node string would have fallen into.

var gInspPolls = 0
  ## Times `inspectPoll` has been ENTERED. If this stops advancing while the
  ## rider keeps dispatching, the host tick thread is blocked or dead -- a
  ## completely different fault from anything inside the poll, and one that
  ## nothing previously distinguished.
var gInspReads = 0            ## successful reads of the command file
var gInspReadFails = 0        ## readShared() said no
var gInspUnchanged = 0        ## read fine, content identical to last time
var gInspLastQueueMs = 0'u64  ## when a batch was last handed over
var gInspLastWatchMs = 0'u64  ## rate limit for the watchdog
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
var gInspRunningBatch = -1
  ## THE BATCH THE UNITY THREAD IS ACTUALLY EXECUTING.
  ##
  ## `gInspBatch` is the batch the HOST thread has most recently QUEUED, and
  ## the two are not the same number once a batch can span frames: a parked
  ## search holds the Unity thread for many frames, during which the poll can
  ## read a new command file and increment `gInspBatch`. The completion
  ## handshake used to publish `gInspBatchDone = gInspBatch`, which in that
  ## window labels the FINISHED batch with the NEW batch's number -- so the
  ## host writes out the old batch's answers as if they were the new one's,
  ## and the real answers to the new commands are never recognised.
  ##
  ## Latching the number at claim time removes the race entirely.
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

var gInspDelivered = -1
  ## THE COUNTER THAT MAKES "WEDGED" DECIDABLE, and the reason the old watchdog
  ## could not tell a wedge from an idle channel.
  ##
  ## `gInspBatchDone` is a HANDSHAKE, not a history: the poll sets it back to -1
  ## the instant it has written the answers out. So `done=-1` is the state of a
  ## perfectly healthy channel that has delivered everything, AND the state of a
  ## batch that never finished -- one number, two opposite meanings. Anything
  ## that reads `done < batch` as "wedged" (in the host or in a tool) will call
  ## a healthy idle channel wedged, which is the same class of confidently wrong
  ## answer this instrument exists to abolish.
  ##
  ## `gInspDelivered` is the history: the highest batch whose answers actually
  ## reached the out file. It is only ever moved forward, never reset.
var gInspClaimMs = 0'u64
  ## Wall clock when the Unity thread CLAIMED the current batch (as opposed to
  ## `gInspHandedMs`, which is when the host thread queued it). The deadline is
  ## measured from the claim, because the interval before the claim already has
  ## its own, different diagnosis.
var gInspClaimFires = 0
  ## `gInspFires` at claim time. The deadline needs BOTH a wall-clock bound and
  ## a dispatch bound: during a raid load the Unity main thread legitimately
  ## stops for a long time (facts #245/#261), and a purely wall-clock deadline
  ## would abandon a batch that was merely waiting for a frame. Requiring the
  ## rider to have been dispatched many times since the claim means we only ever
  ## abandon a batch the Unity thread is demonstrably alive and NOT finishing.
var gInspAbandons = 0
  ## Batches abandoned by the deadline this session.
var gInspInjectStall = false
  ## FAULT INJECTION, armed only by the `stalltest` command. A deadline that has
  ## never abandoned anything is not a deadline -- it is untested code on the
  ## one path that only runs when everything else has already failed.
var gInspStallBatch = -1     ## which batch `stalltest` armed, for the log

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
var gInspOffReported = false
  ## Whether the self-disable has been published from the POLL side. The
  ## announcement itself is made on the thread that decided (`inspGoOff`); this
  ## is the one that flushes the dead batch's answers to the out file, and it
  ## must happen exactly once rather than every 250ms forever.
var gInspFlightRepMs = 0'u64
  ## Last time the "handed but not delivered" heartbeat spoke. That report is
  ## the answer to the failure this whole block of state exists for: a batch
  ## that is handed over and then delivers NOTHING, while satisfying neither
  ## the QUEUED explanation (which needs `gInspFires == 0`) nor the deadline
  ## (which needs a claim, 30s AND 900 dispatches). Every one of those has a
  ## precondition that can be false; this one has none beyond "a batch was
  ## handed over and has not been delivered".
var gInspBlockedText = ""
  ## The last command-file content that was READ but REFUSED because a batch
  ## was still in flight. Kept so the refusal is reported once per distinct
  ## edit instead of four times a second -- and, more importantly, so that the
  ## edit is NOT recorded in `gInspLastText`, which is what makes it queue by
  ## itself as soon as the channel frees.
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
  ##
  ## AN EXPLICITLY QUOTED EMPTY TOKEN IS KEPT. `""` used to vanish here,
  ## because both flush sites tested `cur.len > 0` -- so `findtext "" $settings
  ## 40000` arrived as three tokens and every argument SHIFTED ONE LEFT:
  ## `$settings` was taken as the needle and `40000` as the root, and the
  ## report then described, in full detail, a search nobody had asked for.
  ## Silently changing which argument is which is the worst class of answer
  ## this instrument can give, so an empty quoted run now becomes a real empty
  ## token and the verb that receives it can refuse it by name.
  result = @[]
  var cur = ""
  var i = 0
  var inQuote = false
  var wasQuoted = false
  while i < s.len:
    let c = s[i]
    if inQuote:
      if c == '"':
        inQuote = false
      else:
        cur.add c
    elif c == '"':
      inQuote = true
      wasQuoted = true
    elif iIsSpace(c):
      if cur.len > 0 or wasQuoted:
        result.add cur
        cur = ""
        wasQuoted = false
    else:
      cur.add c
    inc i
  if cur.len > 0 or wasQuoted:
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
  # THE OVERLAY TAP, before the output cap: the F2 panel is a live glance and
  # must keep scrolling even after the file transcript has hit its per-batch
  # ceiling. The ring has its own capacity and discards its own oldest.
  ioTap(1'i32, s)
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

proc iUnboundWhy(name: string): string =
  ## Why a `$name` that EXISTS in the namespace but holds 0 is a REFUSAL and
  ## not an address.
  ##
  ## MEASURED live 2026-09-02 14:42, in one batch:
  ##
  ##     component $g2 AnimatedToggle   -> "! GetComponent returned NULL --
  ##                                        this is an ANSWER, not a crash."
  ##     call rva:0x55ba430 v_pb $comp 1
  ##                                    -> "!! FAULTED (caught) ... fault 1 of 8"
  ##
  ## The lookup had already said NO, and the very next line called into game
  ## code with a null receiver anyway -- three times in that batch, three of
  ## the session's eight faults, on an anchor that was not bound. A zero anchor
  ## is not an address; it is the ABSENCE of one, and the only correct thing to
  ## do with it is refuse BEFORE any game code runs.
  result = "$" & name & " is UNBOUND (it holds 0), so nothing was read and " &
           "nothing was called. "
  case name
  of "comp":
    result = result & "The last `component` lookup returned NULL and unbound " &
      "$comp rather than leaving it holding the previous batch's pointer -- " &
      "which used to press a control nobody asked for and print a plausible, " &
      "entirely fictional field map. Run `component` again and check that it " &
      "actually says FOUND before calling or pressing anything."
  else:
    result = result & "`anchors` lists what is bound this batch and `state` " &
      "says WHY one is not. An anchor reading 0 is an ANSWER (the object has " &
      "not spawned yet, or the host has not learned it), not an address to " &
      "walk from."

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
  # `$duanchor` and `$duroot` are GONE, not left reading nil. They named the
  # TextMeshProUGUI the F3 overlay cloned from and the GameObject it parented
  # clones to, and the F3 overlay no longer clones or parents anything: it
  # submits screen-space draw commands to the shared region and the D3D11
  # overlay rasterises them in Present. An anchor that always reads null is
  # indistinguishable from one whose object has not spawned yet, which is
  # exactly the kind of answer the inspector must never give.
  iSetVarP("gameworld", gDuGameWorld)    # the live GameWorld, when in a raid
  iSetVarP("you", gDuYou)                # the local player, when in a raid
  # The live SettingsScreen `this`, once opened. `gSettingsLiveSelf` (set by the
  # `ShowScreen` postfix that actually drives Phase 1/2/3, first-fire AND every
  # revisit) is preferred over `gMi2Self` (set only by the separate invoke2
  # ladder proof, which may never fire): the anchor must reflect whichever probe
  # is ACTUALLY running, not assume a specific one is.
  iSetVarP("settings", iInspSettingsSelf())
  for i in 0 ..< 8:
    if gSuiTabPtr[i] != 0'u64:
      iSetVar("tab" & $i, gSuiTabPtr[i])
  # PUBLISH the freshly-rebound anchors to the F2 overlay's snapshot, so the
  # panel shows exactly what this batch is walking from. Runs on Unity's thread,
  # inside the batch's own guard; `$` of a uint is allocation but this is once
  # per batch (~4 Hz at most), not per frame. Only when the overlay is armed.
  if gIoCapture:
    cIoAnchorBegin()
    var published = 0
    for i in 0 ..< gInspVarName.len:
      if published >= 24:
        break
      # Skip the scratch `_` and zero-valued slots -- a "$x=0x0" line is noise;
      # the panel's job is to show what is actually bound.
      if gInspVarName[i] == "_" or gInspVarVal[i] == 0'u64:
        continue
      cIoAnchorAdd(ioBufC("$" & gInspVarName[i] & "=" & iPtrU(gInspVarVal[i])))
      inc published
    cIoAnchorCommit()

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
    # THE UNBOUND-ANCHOR REFUSAL, and it lives HERE, in the one evaluator every
    # verb already calls, rather than in each consumer. `call`, `click`,
    # `invoke`, `press`, `label`, `rect`, `scan`, `write`, `component` itself
    # and `find`'s root slot all inherit it, and they cannot drift apart the
    # way per-verb copies would. A LITERAL 0 is still accepted -- someone who
    # types 0 means it -- but a NAME whose lookup just failed is never an
    # address, and never reaches a call.
    if v == 0'u64:
      err = iUnboundWhy(atom)
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
  ##
  ## THE LEVEL NUMBERING, STATED ONCE AND ENFORCED HERE.
  ## `[0]` is ALWAYS THE NODE YOU PASSED (normalised to its Transform, so a
  ## component and its Transform give the same `[0]`); `[1]` is its parent, and
  ## so on. DEPTH counts levels PRINTED, so `parent X 1` prints X alone and
  ## says so rather than looking like a broken walk.
  ##
  ## It was reported as inconsistent -- the node itself as `[0]` in one call
  ## and the parent as `[0]` in another. The reachable cause is a GAMEOBJECT
  ## argument: `Component::get_transform` on a GameObject is a native type
  ## confusion that can return a plausible OTHER transform, and `[0]` is then
  ## a different object with a different name for a reason nothing prints.
  ## That is refused at the dispatch site now, and the contract is printed
  ## below on every call, so the two can never again be told apart by guessing.
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
  iOut("  [0] is THE NODE YOU PASSED; [1] is its parent, upward. DEPTH counts " &
       "levels PRINTED, so `parent EXPR 1` prints only the node itself.")
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

const InspKlassMax = 128

var gGoKlass: seq[uint64] = @[]
  ## KLASS POINTERS KNOWN TO BE `UnityEngine.GameObject`.
  ##
  ## Learned only from sources that return a GameObject BY CONTRACT --
  ## `Scene::GetRootGameObjects` and `Component::get_gameObject` -- never
  ## guessed. `UnityEngine.GameObject` is sealed, so in practice this holds one
  ## value.
  ##
  ## It exists because the tree walker takes TRANSFORMS, and feeding it a
  ## GameObject reads `Transform` methods off the wrong type. The observed
  ## fault on "[Technical Systems]" was the LUCKY outcome of that: an
  ## unlucky one returns a plausible child count and walks into unrelated
  ## memory, inventing a hierarchy of wrong children with wrong names and
  ## never faulting at all. Two roots were walked before the faulting one, and
  ## "did not fault" is not evidence that those were right.
  ##
  ## A blacklist rather than a Transform whitelist, deliberately: Transform has
  ## subclasses (RectTransform, and anything the game defines), so a whitelist
  ## would refuse legitimate objects it had not happened to see yet. Refusing
  ## exactly what is known to be the WRONG type has no false negatives.

proc iKlassOf(p: Il2CppPtr): uint64 =
  ## The Il2CppClass* every managed object carries at +0. A guarded read, so
  ## this is safe on anything.
  result = 0'u64
  if p == nil or not duOk(p, 8'i32):
    return
  result = cast[uint64](cReadPtrAt(p, 0'i32))

proc iNoteKlass(p: Il2CppPtr) =
  ## Remember this object's type. Called from every traversal, where klass
  ## pointers are free.
  let k = iKlassOf(p)
  if k == 0'u64:
    return
  for i in 0 ..< gKlassSeen.len:
    if gKlassSeen[i] == k:
      return
  if gKlassSeen.len < InspKlassMax:
    gKlassSeen.add k

proc iNoteGameObject(p: Il2CppPtr) =
  ## Record this object's klass as a GameObject klass. Only ever called on
  ## pointers a target returned as a GameObject by contract.
  let k = iKlassOf(p)
  if k == 0'u64:
    return
  for i in 0 ..< gGoKlass.len:
    if gGoKlass[i] == k:
      return
  if gGoKlass.len < 16:
    gGoKlass.add k

var gTfKlass: seq[uint64] = @[]
  ## KLASS POINTERS KNOWN TO BE A `UnityEngine.Transform` (or a subclass).
  ##
  ## The mirror image of `gGoKlass`, and learned the same way: only from
  ## sources that return a Transform BY CONTRACT -- `Transform::GetChild`,
  ## the scene-root walk, and `Component::get_transform`. Never guessed.
  ##
  ## Unlike GameObject, Transform is NOT sealed -- RectTransform is the common
  ## subclass and the game may define more -- so this holds several values and
  ## is used only as a BLACKLIST: "this is definitely a Transform, and you
  ## asked for a component". Refusing exactly what is known to be wrong has no
  ## false negatives, which a Transform whitelist could not promise.
  ##
  ## It exists because `children`/`find`/`tree`/`roots` all hand back
  ## Transforms, so a Transform is what an agent has in hand at the moment it
  ## reaches for a component verb -- and every component verb reading a
  ## Transform's fields gets a plausible answer rather than an error.

proc iNoteTransform(p: Il2CppPtr) =
  ## Record this object's klass as a Transform klass. Only ever called on
  ## pointers a target returned as a Transform by contract.
  let k = iKlassOf(p)
  if k == 0'u64:
    return
  for i in 0 ..< gTfKlass.len:
    if gTfKlass[i] == k:
      return
  if gTfKlass.len < 16:
    gTfKlass.add k

proc iIsTransform(p: Il2CppPtr): bool =
  let k = iKlassOf(p)
  if k == 0'u64:
    return false
  for i in 0 ..< gTfKlass.len:
    if gTfKlass[i] == k:
      return true
  result = false

proc iIsGameObject(p: Il2CppPtr): bool =
  let k = iKlassOf(p)
  if k == 0'u64:
    return false
  for i in 0 ..< gGoKlass.len:
    if gGoKlass[i] == k:
      return true
  result = false

proc iRefuseIfGameObject(p: Il2CppPtr; what: string): bool =
  ## THE GUARD THAT MAKES THIS CLASS OF MISTAKE LOUD.
  ##
  ## Returns true (and explains) when `p` is a GameObject being handed to
  ## something that wants a Transform. The point is not the crash we already
  ## saw -- that one announced itself -- but the silent case: `Transform`
  ## methods read off a GameObject can return a plausible child count and walk
  ## into unrelated memory, producing a hierarchy that is entirely fictional
  ## and never faults. A wrong answer delivered confidently is the worst thing
  ## this instrument can do.
  if not iIsGameObject(p):
    return false
  iErr(what & " was given a GameObject (klass " & iPtrU(iKlassOf(p)) & ") " &
       "where a TRANSFORM is required. Transform methods read off a " &
       "GameObject land on unrelated memory and can invent a plausible-looking " &
       "hierarchy WITHOUT faulting, so this refuses rather than guessing. " &
       "Convert it first -- every $rN is already a Transform; for a GameObject " &
       "from elsewhere use its $gN partner.")
  result = true

proc iIsKnownKlass(v: uint64): bool =
  result = false
  if v == 0'u64:
    return
  for i in 0 ..< gKlassSeen.len:
    if gKlassSeen[i] == v:
      return true

proc iUnityAlive(p: Il2CppPtr): bool =
  ## Is the NATIVE half of this UnityEngine.Object still there?
  ##
  ## Most of the tree-walking primitives on this build -- `get_childCount`,
  ## `get_activeSelf`, `get_activeInHierarchy`, `Component::get_gameObject`,
  ## `Component::get_transform` -- are IL2CPP internal-call wrappers. They
  ## dereference `m_CachedPtr` at +0x10 and, when it is zero, fault INSIDE
  ## Unity's C++ where no guard of ours can reach. A managed wrapper whose
  ## native half is gone is Unity's famous "fake null": it is a perfectly
  ## readable object that compares equal to null and kills the process if you
  ## call anything on it.
  ##
  ## So every call into one of those goes through here first. This is a plain
  ## guarded field read and cannot itself fault.
  if not duOk(p, cNavOffCachedPtr() + 8'i32):
    return false
  result = cReadPtrAt(p, cNavOffCachedPtr()) != nil

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

const
  InspMaxChildren = 64     ## per `children` listing
  InspFindDefBudget = 20000
    ## DEFAULT nodes per `find` invocation. The old value was 4000 and, worse,
    ## the same constant was used as the hard maximum -- so a caller who asked
    ## for 40000 was silently clamped back to 4000 and told "node budget 4000".
    ## A default and a ceiling are different numbers and are now separate.
  InspFindMaxBudget = 250000
    ## Ceiling on an explicit request. Large, because the real constraint is
    ## not the node count -- it is not stalling the Unity thread, which the
    ## time slice below enforces directly.
  InspFindMaxHits = 24
  InspFindMaxFrames = 240
    ## HOW LONG ONE SEARCH MAY HOLD THE CHANNEL. A parked batch is still an
    ## IN-FLIGHT batch, so while a search spans frames no new command file can
    ## be picked up. At the maximum node budget an unbounded search could hold
    ## the channel for minutes, which from the outside is indistinguishable
    ## from the channel being dead -- the exact failure this instrument exists
    ## to abolish, reintroduced by the feature meant to make it nicer. Four
    ## seconds at 60fps, then it stops and says so.
  InspTreeMaxNodes = 3000
  InspTreeMaxDepth = 16
  InspTextFindDefBudget = InspFindDefBudget
    ## DEFAULT nodes per `findtext` invocation. Used to be 4000 (much lower
    ## than `find`'s 20000) on the theory that each node here costs a managed
    ## GetComponent CALL, not a raw field read -- but the REAL backstop is
    ## the 12ms per-frame time slice below, not the node count, exactly as
    ## `InspFindMaxFrames`'s comment already says for `find`. Measured: a
    ## whole-scene `findtext` at the old default reported "visited 4000,
    ## frontier 18376" -- STOPPED EARLY was the normal outcome, not the
    ## exceptional one. Aligned with `find`'s default; `findtext more`
    ## resumes cheaply regardless, so a search that is genuinely slow just
    ## takes more frames, not a worse default.
  InspTextBlindMinNodes = 200
    ## THE POSITIVE-CONTROL THRESHOLD. Above this many nodes visited, a search
    ## that saw ZERO TMP components has told us about its own predicate, not
    ## about the text: any real UI subtree of this size on this client carries
    ## captions. Below it, "no TMP here" is an ordinary and truthful outcome,
    ## so the control would be a false alarm. 200 is chosen against the
    ## measured 1263-node Settings screen, which is 6x it.
  InspTextFindMaxBudget = 60000
    ## Ceiling on an explicit request. Kept well under `find`'s ceiling for the
    ## same reason: a managed call per node is heavier than a pointer chase.

var InspFindSliceMs = 12'u64
  ## THE REAL BUDGET, and now a runtime var (was a const) so the host flag
  ## `inspectorSliceMs` can raise it. A node count is a poor proxy for "am I
  ## about to make the game stutter"; wall time is the actual thing that matters.
  ## One frame of a find/findtext/tree walk gives up after this many ms and
  ## reports exactly where it stopped, so a deep hierarchy costs several
  ## resumptions rather than one long freeze.
  ##
  ## DEFAULT 12 ms -- unchanged unless `inspectorSliceMs` is set -- so nothing
  ## about the shipped behaviour moves. Raising it (e.g. 100-250 ms) lets a big
  ## menu-time search finish in one or a few frames, near-instant at the cost of
  ## a brief hang, which is fine for DEV/inspecting at the MENU.
  ##
  ## DANGER (fact #261): a large slice must NOT be used during a raid LOAD -- it
  ## stalls the Unity main thread and errors the deploy. It is an opt-in dev/menu
  ## accelerator; keep it modest (or 0/unset) for any run that will load a raid.
  ## This is the per-FRAME time cap, SEPARATE from the per-command NODE budget
  ## that find/findtext already accept.

# --- MOVED UP 2026-09-02, not rewritten -----------------------------------
# The klass-name reader and the receiver-type gate used to live ~1500 lines
# further down, after `components`. `findtext` now needs them: its predicate
# resolves a component by TYPE and then CONFIRMS the returned object's klass
# chain, so the confirmation has to be declared before the search. Moved
# verbatim rather than duplicated -- two copies of a type gate is how the two
# copies come to disagree.
# --------------------------------------------------------------------------
proc cCompNameOf(klass: Il2CppPtr): int32 {.importc: "aowl_comp_name_of", nodecl.}
proc cCompNameBuf(): cstring {.importc: "aowl_comp_name_buf", nodecl.}
proc cCompIsKnownType(s: cstring): int32 {.
  importc: "aowl_comp_is_known_type", nodecl.}
proc cCompTypeRva(s: cstring): uint32 {.importc: "aowl_comp_type_rva", nodecl.}
proc cCompMax(): int32 {.importc: "aowl_comp_max", nodecl.}
proc cCompOffName(): int32 {.importc: "aowl_comp_off_name", nodecl.}
proc cCompDataAt(rva: uint64): Il2CppPtr {.importc: "aowl_comp_data_at", nodecl.}

proc iKlassName(k: uint64; verified: var bool): string =
  ## The type name of an Il2CppClass, READ RAW AND THEN CHECKED.
  ##
  ## `il2cpp_class_get_name` is not an accessor on this build -- it is a
  ## TLS thread-attach wrapper, which is the most likely reason calling it
  ## faults -- so the name comes out of the struct directly. The `namespaze`
  ## offset is measured from `il2cpp_class_get_namespace`'s own instruction
  ## bytes; the `name` offset one slot earlier is INFERRED, and therefore is
  ## never trusted on its own. Whatever string comes back must be a type that
  ## exists in this build's metadata, per the offline table. If it is not,
  ## this returns the string with `verified = false` and the caller prints it
  ## as UNVERIFIED rather than as a type.
  verified = false
  result = ""
  if k == 0'u64:
    return
  let kp = cast[Il2CppPtr](k)
  if not duOk(kp, 0x20'i32):
    return
  iMark("Il2CppClass name/namespace raw read", kp)
  if cCompNameOf(kp) == 0'i32:
    return
  result = readCString(cCompNameBuf())
  if result.len == 0:
    return
  var nm = result
  verified = cCompIsKnownType(toCString(nm)) != 0'i32

# ---------------------------------------------------------------------------
# THE RECEIVER TYPE CHECK, and why every verb that calls a typed method needs it
#
# MEASURED, live, today: `tab` was handed an `EFT.UI.AnimatedToggle` and then a
# `UnityEngine.CanvasRenderer`. It called `EFT.UI.Settings.SettingsTab::
# set_IsSelected` on both, wrote +0x90 on objects that have no such field, and
# printed a perfectly plausible "first-select latch ... -> ..." line each time.
# Nothing faulted in a way the batch survived (`escapes=1` on the channel
# counters) and the Settings screen ended up desynced -- GRAPHICS highlighted
# with the Game panel showing.
#
# That is the worst failure this instrument can produce, and it is not
# preventable by a readability check: `duOk(tab, 0xA0)` passes on ANY object
# that is at least 0xA0 bytes, which is nearly all of them. The only question
# that separates "this call is correct" from "this call is a blind write into a
# stranger's fields" is WHAT TYPE THE RECEIVER IS.
#
# So: read the klass name out of the object and walk `Il2CppClass.parent` until
# the wanted type appears or the chain ends at System.Object. Three outcomes,
# never two -- YES / NO / INCONCLUSIVE -- because "I could not read the chain"
# is not "it is the right type", and flattening those two is the same mistake
# in a different place.
# ---------------------------------------------------------------------------

proc swWidgetIsToggle(widget: Il2CppPtr; chain: var string): int =
  ## Forward-declared in `settingswrite.nim`: is this component a
  ## UnityEngine.UI.Toggle, by the same parent-chain walk `tab` uses?
  result = iKlassIs(widget, "UnityEngine.UI.Toggle", chain)

proc swKlassFullName(k: uint64; known: var bool): string =
  ## The settings census's way to a klass NAME -- forward-declared in
  ## `settingswrite.nim`, which is included before `aowlspt_components.h` is
  ## emitted, so the body lives here. The same reader the `components` verb
  ## uses: name and namespace off the Il2CppClass with page checks, verified
  ## against the offline name index; "" when nothing readable.
  result = iKlassName(k, known)

const
  InspKlassParentOff = 0x58'i32
    ## `Il2CppClass.parent`. MEASURED out of the shipped GameAssembly.dll, from
    ## `il2cpp_class_get_parent`'s OWN BODY -- the same method
    ## `abi/aowlspt_components.h` used for `namespaze`, not a guess:
    ##
    ##   il2cpp_class_get_parent         40 53 48 83 ec 20 48 8b c2 48 8b d9
    ##                                   48 85 d2 74 23 41 b8 20 00 00 00 ...
    ##                                   85 c0 75 0a 48 8b 43 58  <- [rbx+0x58]
    ##   il2cpp_class_get_declaring_type  ... same body ... 48 8b 43 50
    ##   il2cpp_class_get_element_class   48 8b 41 40 c3   (folded accessor)
    ##
    ## 0x40 / 0x50 / 0x58 are consecutive slots of the canonical Il2CppClass
    ## head, and `element_class` at 0x40 is independently a one-instruction
    ## accessor, so the three corroborate each other.
    ##
    ## The FIELD IS READ, NEVER THE EXPORT CALLED. `il2cpp_class_get_parent` is
    ## one of the TOKEN-GATED exports (`48 85 d2` tests a second argument we do
    ## not pass, then `41 b8 20` -> a 32-byte memcmp); on mismatch those return
    ## a uniform random non-zero uint64, which passes a nil check and kills the
    ## client on first dereference.
  InspKlassChainMax = 24
    ## Cap on the walk. The deepest real chain measured offline is 10
    ## (EFT.UI.Settings.SettingsScreen -> System.Object); 24 is slack with a
    ## hard stop, because an unbounded loop on the Unity thread is a hang.

  KlassNo = 0
  KlassYes = 1
  KlassUnknown = -1

proc iKlassIs(p: Il2CppPtr; wanted: string; chain: var string): int =
  ## Does `p`'s type derive from (or equal) `wanted`? `chain` always comes back
  ## holding whatever WAS read, so a refusal can name the actual type.
  ##
  ## Every name is validated against the offline type table before it is
  ## believed (`iKlassName`'s `verified` out-parameter). An unverified name
  ## stops the walk with INCONCLUSIVE rather than being compared: if the name
  ## offset were wrong for this object, comparing garbage to `wanted` would
  ## answer NO with total confidence, and a confident NO is as bad as a
  ## confident YES.
  chain = ""
  var k = iKlassOf(p)
  if k == 0'u64:
    return KlassUnknown
  var hop = 0
  while hop < InspKlassChainMax:
    let kp = cast[Il2CppPtr](k)
    if not duOk(kp, InspKlassParentOff + 8'i32):
      if chain.len > 0: chain.add " <- "
      chain.add "<klass " & iPtrU(k) & " unreadable>"
      return KlassUnknown
    var verified = false
    let nm = iKlassName(k, verified)
    if nm.len == 0:
      if chain.len > 0: chain.add " <- "
      chain.add "<klass " & iPtrU(k) & " has no readable name>"
      return KlassUnknown
    if chain.len > 0: chain.add " <- "
    chain.add nm
    if not verified:
      chain.add " (UNVERIFIED -- not a type on this build)"
      return KlassUnknown
    if nm == wanted:
      return KlassYes
    let par = cast[uint64](cReadPtrAt(kp, InspKlassParentOff))
    if par == 0'u64:
      # The chain terminated at System.Object with every name verified. This
      # is the ONLY way to answer NO, and it is a complete answer.
      return KlassNo
    if par == k:
      chain.add " <- (self-referential parent; chain is not walkable)"
      return KlassUnknown
    k = par
    inc hop
  chain.add " <- ... (chain longer than " & $InspKlassChainMax & " hops)"
  result = KlassUnknown

proc iRequireKlass(p: Il2CppPtr; wanted, verb: string): bool =
  ## THE GATE. True only on a POSITIVE, COMPLETE answer.
  var chain = ""
  let r = iKlassIs(p, wanted, chain)
  if r == KlassYes:
    iOut("  receiver type: " & chain & "   -- IS a " & wanted)
    return true
  if r == KlassNo:
    iErr(verb & " REFUSED -- WRONG RECEIVER TYPE. This object is " & chain &
         ", which does not derive from " & wanted & ". Nothing was called. " &
         "A " & wanted & " method run on it would impose " & wanted & "'s " &
         "field layout on unrelated memory, RETURN NORMALLY, and print a " &
         "plausible line: that is measured, not hypothetical -- `tab` on an " &
         "EFT.UI.AnimatedToggle and on a UnityEngine.CanvasRenderer wrote " &
         "+0x90 on both and desynced the Settings screen without faulting.")
    return false
  iErr(verb & " REFUSED -- TYPE INCONCLUSIVE. The klass chain could not be " &
       "read to the end: " &
       (if chain.len > 0: chain else: "no klass pointer at all") &
       ". 'I could not look' is not 'it is the right type', so nothing was " &
       "called. Try `components " & (if verb == "open": "$settings" else: "EXPR") &
       "` to see what this object actually is.")
  result = false


proc iTypeObjectFor(fullName: string; why: var string): Il2CppPtr =
  ## A live `System.Type` for a FULLY-QUALIFIED type name, with no reflection
  ## anywhere in the chain:
  ##
  ##   "Ns.Type" -> offline index key `Ns.Type::@type/0` -> the RVA of the
  ##   STATIC `Il2CppType` -> `System.Type::GetTypeFromHandle`, whose argument
  ##   is a `RuntimeTypeHandle`: a one-field struct whose value IS that
  ##   pointer, so on Win64 it is a plain pointer in RCX.
  ##
  ## This is `components`' route, factored out, because `findtext` now needs
  ## the same thing per search. `why` is always set on failure -- a silent nil
  ## here would be indistinguishable from "the type has no components", and
  ## those are different facts.
  result = nil
  why = ""
  if cNameIdxReady() == 0'i32:
    why = "the offline name index is not loaded, so no Il2CppType address is " &
          "available: " & readCString(cNameIdxReason())
    return
  var fn = fullName
  let rva = cCompTypeRva(toCString(fn))
  if rva == 0'u32:
    why = "\"" & fullName & "\" has no `::@type` entry in the offline index " &
          "(not a type on this build, or its name mapped to two Il2CppType " &
          "descriptors and was DROPPED rather than guessed at)"
    return
  let td = cCompDataAt(uint64(rva))
  if td == nil or not duOk(td, 16'i32):
    why = "the index gave Il2CppType RVA 0x" & iHexPad(uint64(rva), 6) &
          " for " & fullName & ", but that address is not readable here"
    return
  var fnH: Il2CppPtr = nil
  var rvaH = 0'u32
  if not iNavFind("Type::GetTypeFromHandle", fnH, rvaH):
    why = "System.Type::GetTypeFromHandle did not byte-verify on this build"
    return
  iMark("System.Type::GetTypeFromHandle", td)
  let t = cast[Il2CppPtr](cInspUP(fnH, td, nil))
  if t == nil or not duOk(t, 0x20'i32):
    why = "GetTypeFromHandle returned " & iPtr(t) &
          ", which is not a usable System.Type"
    return
  result = t

proc iInspSeedTextType(): bool =
  ## Get the `System.Type` for `TMPro.TextMeshProUGUI` that findtext's
  ## predicate needs. Called ONCE PER FRAME SLICE, never per node.
  ##
  ## WHAT THIS REPLACED, AND WHY -- MEASURED 2026-09-02, build 1.1.0.1.46777.
  ## It used to allocate the managed STRING "TextMeshProUGUI" and hand it to
  ## `Component::GetComponent(String)` at every node. That call never faulted
  ## and never answered: `findtext e $settings 40000 all` visited ALL 1263
  ## nodes of an OPEN Settings screen -- a screen made of captions -- and
  ## reported `0 match(es) ... genuinely NOT PRESENT`, while `label` reads TMP
  ## text off those very nodes. Unity's string overload matches through a
  ## runtime type-name lookup that does not resolve on this IL2CPP build, so
  ## it returned NULL for every node. A predicate that cannot say yes makes
  ## EVERY absence verdict vacuous (CLAUDE.md 9b), which is what it did.
  ##
  ## The Type overload matches by KLASS IDENTITY inside the runtime, which is
  ## the thing we actually want to ask, and `GetComponent(Type)` allocates
  ## NOTHING -- unlike `GetComponents(Type)`, which returns an array and is
  ## therefore banned from a per-node path.
  ##
  ## Re-derived each slice rather than cached across frames: GetTypeFromHandle
  ## returns the runtime's own cached Type object, so this is a lookup and not
  ## an allocation, and re-deriving means a search that spans frames never
  ## carries a stale managed pointer over a GC.
  if gTmpTypeObj != nil and duOk(gTmpTypeObj, 0x20'i32):
    return true
  var why = ""
  gTmpTypeObj = iTypeObjectFor("TMPro.TextMeshProUGUI", why)
  if gTmpTypeObj == nil:
    gTxtSeedWhy = why
    return false
  gTxtSeedWhy = ""
  result = true

proc iNavFindQuiet(want: string; fn: var Il2CppPtr): bool =
  ## Same lookup, no logging. `find` calls this thousands of times inside one
  ## frame; the loud version would bury the answer in identical error lines.
  fn = nil
  for i in 0 ..< int(cNavTargetCount()):
    if iContains(iLower(readCString(cNavName(int32(i)))), iLower(want)):
      fn = cNavFn(int32(i))
      return fn != nil
  result = false

proc iGetComponentOfType(target, typeObj: Il2CppPtr;
                         why: var string): Il2CppPtr =
  ## `GetComponent(System.Type)` with the overload picked from the receiver's
  ## KLASS, never assumed.
  ##
  ## MEASURED: `UnityEngine.GameObject` declares NO `GetComponent(string)` on
  ## this build (offline `typemethods`), so the table entry that used to be
  ## called "GameObject::GetComponent(String)" @0x52A8510 is in fact
  ## `GetComponent(Type)`. Passing it an `Il2CppString*` is what faulted
  ## `component <GameObject> TextMeshProUGUI` five times out of five.
  result = nil
  why = ""
  if typeObj == nil or not duOk(typeObj, 0x20'i32):
    why = "no usable System.Type was resolved, so nothing was called"
    return
  if not duOk(target, 0x20'i32) or not iUnityAlive(target):
    why = "the receiver is not readable, or its native half is null"
    return
  let isGo = iIsGameObject(target)
  let overload = (if isGo: "GameObject::GetComponent(Type)"
                  else: "Component::GetComponent(Type)")
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet(overload, fn) or fn == nil:
    why = overload & " did not resolve, or its prologue did not verify"
    return
  iMark(overload, target)
  let c = cast[Il2CppPtr](cInspUPP(fn, target, typeObj, nil))
  if c == nil:
    why = "GetComponent(Type) returned NULL -- an ANSWER: this object has no " &
          "component of that type"
    return
  if not duOk(c, 0x20'i32):
    why = "GetComponent(Type) returned " & iPtr(c) & ", which is not readable"
    return
  iNoteKlass(c)
  result = c

proc iChildCount(t: Il2CppPtr; n: var int): bool =
  ## `Transform::get_childCount` is an ICALL, so the liveness check is not
  ## optional politeness -- it is the difference between an answer and a
  ## process death.
  n = 0
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet("get_childCount", fn):
    return false
  # Refuse the wrong TYPE before touching the object, not after.
  if iIsGameObject(t):
    return false
  if not iUnityAlive(t):
    return false
  iMark("Transform::get_childCount", t)
  n = int(int32(uint32(cInspUP(fn, t, nil) and 0xFFFFFFFF'u64)))
  # A negative or absurd count means we are not looking at a Transform. Refuse
  # it rather than looping on it: an unbounded loop on the Unity thread is a
  # hang, and a hang is the one failure this instrument must never cause.
  if n < 0 or n > 8192:
    n = 0
    return false
  result = true

proc iChildAt(t: Il2CppPtr; i: int): Il2CppPtr =
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet("GetChild", fn):
    return nil
  if iIsGameObject(t):
    return nil
  if not iUnityAlive(t):
    return nil
  iMark("Transform::GetChild", t)
  result = cast[Il2CppPtr](cInspUPI(fn, t, int32(i), nil))

proc iTransformOfGameObject(go: Il2CppPtr): Il2CppPtr =
  ## `GameObject::get_transform` @0x52A8AE0 -- the GameObject-side accessor.
  ##
  ## NOT `Component::get_transform`: that is a Component method, and calling it
  ## on a GameObject is the very type confusion this exists to fix. The two
  ## have almost the same name and completely different receivers, which is
  ## exactly how the wrong one gets used.
  result = nil
  var idx = 0
  var hits = 0
  if not iFindTarget("GameObject::get_transform", idx, hits):
    return
  let fn = iTargetFn(idx)
  if fn == nil or not iUnityAlive(go):
    return
  iMark("GameObject::get_transform", go)
  let t = cast[Il2CppPtr](cInspUP(fn, go, nil))
  if duOk(t, 0x20'i32):
    result = t

proc iGameObjectOf(p: Il2CppPtr): Il2CppPtr =
  ## The GameObject behind a Component/Transform. Almost everything downstream
  ## -- components, activeSelf, clicking -- wants the GameObject rather than
  ## the Transform, and having to fetch it by hand each time is exactly the
  ## kind of step where the wrong pointer gets carried forward.
  result = nil
  var idx = 0
  var hits = 0
  if not iFindTarget("Component::get_gameObject", idx, hits):
    return
  let fn = iTargetFn(idx)
  if fn == nil or not iUnityAlive(p):
    return
  iMark("Component::get_gameObject", p)
  let go = cast[Il2CppPtr](cInspUP(fn, p, nil))
  if duOk(go, 0x20'i32):
    # A GameObject by contract: record its klass so the walker can recognise
    # and refuse one. This is why the guard is armed even in a session that
    # never runs `roots`.
    iNoteGameObject(go)
    result = go

proc iObjName(p: Il2CppPtr): string =
  ## `Object::get_name` is a real managed body, but it still ends up in native
  ## code, so the same liveness rule applies.
  result = ""
  var idx = 0
  var hits = 0
  if not iFindTarget("Object::get_name", idx, hits):
    return
  let fn = iTargetFn(idx)
  if fn == nil or not iUnityAlive(p):
    return
  iMark("Object::get_name", p)
  result = suiReadString(cast[Il2CppPtr](cInspUP(fn, p, nil)))

# MOVED UP 2026-09-02: `children` now makes the same Component->Transform
# conversion `tree` does, so this has to be declared before it.
proc iToTransform(p: Il2CppPtr): Il2CppPtr =
  ## `get_transform` on something that is already a Transform returns itself,
  ## so this is safe for a component or a transform alike.
  result = p
  var idx = 0
  var hits = 0
  if iFindTarget("Component::get_transform", idx, hits):
    let fn = iTargetFn(idx)
    if fn != nil and iUnityAlive(p):
      iMark("Component::get_transform", p)
      let t = cast[Il2CppPtr](cInspUP(fn, p, nil))
      if duOk(t, 0x20'i32):
        result = t

proc iCmdChildren(toks: seq[string]) =
  ## `children EXPR [N]` -- DOWNWARD traversal, the thing the inspector could
  ## never do. Walking up a parent chain can never reach a Button, so without
  ## this the instrument could look at anything and touch nothing.
  if toks.len < 2:
    iErr("usage: children EXPR [N]")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  var t = cast[Il2CppPtr](v)
  if not duOk(t, 0x20'i32):
    iErr("that pointer is not readable; refusing to walk it.")
    return
  if iRefuseIfGameObject(t, "children"):
    return
  # ONE PREDICATE FOR BOTH VERBS. `tree` converts its argument with
  # `iToTransform` and `children` did not, so the two DISAGREED about the same
  # anchor: `tree $settings 2` walked it happily while `children $settings`
  # refused with "probably not a Transform". Neither answer was wrong about
  # what it did -- `$settings` is a SettingsScreen COMPONENT, not a Transform,
  # and get_childCount on a component is meaningless -- but a tool that gives
  # two different verdicts for one pointer teaches the operator to distrust
  # both. `Component::get_transform` on something that is already a Transform
  # returns itself, so this is the same step `tree` takes, not a new risk.
  let t0 = t
  t = iToTransform(t)
  if t != t0:
    iOut("  " & iPtr(t0) & " is a Component, not a Transform; listing the " &
         "children of its Transform " & iPtr(t) & " (this is the same " &
         "conversion `tree` makes -- the two verbs now agree).")
  if not iUnityAlive(t):
    iErr("that object's native half (m_CachedPtr +0x" &
         iHexPad(uint64(cNavOffCachedPtr()), 2) & ") is NULL. Every child " &
         "primitive on this build is an internal call that would dereference " &
         "it and fault inside Unity's C++. Refusing to call. This is either a " &
         "destroyed object or not a UnityEngine.Object at all.")
    return
  var count = 0
  if not iChildCount(t, count):
    iErr("could not read a sane child count; this is probably not a Transform.")
    return
  var want = InspMaxChildren
  if toks.len > 2:
    var n = 0'u64
    var e2 = ""
    if iEval(toks[2], n, e2) and int(n) > 0:
      want = int(n)
  if want > InspMaxChildren:
    want = InspMaxChildren
  iOut("  childCount = " & $count &
       (if count > want: "  (showing first " & $want & ")" else: ""))
  iOut("  via Transform::GetChild / get_childCount, Object::get_name (calls)")
  var i = 0
  while i < count and i < want:
    let c = iChildAt(t, i)
    if c == nil or not duOk(c, 0x20'i32):
      iOut("    [" & $i & "] <child not readable>")
    else:
      iNoteKlass(c)
      # A child from `Transform::GetChild` is a TRANSFORM by contract.
      iNoteTransform(c)
      let go = iGameObjectOf(c)
      if go != nil:
        iNoteKlass(go)
        iSetVar("g" & $i, cast[uint64](go))
      iSetVar("c" & $i, cast[uint64](c))
      iOut("    [" & $i & "] transform=" & iPtr(c) & " ($c" & $i & ")" &
           "  go=" & iPtr(go) & (if go != nil: " ($g" & $i & ")" else: "") &
           "  name=\"" & iObjName(c) & "\"")
    inc i
  let shown = min(count, want)
  if shown > 0:
    iOut("  transforms bound to $c0..$c" & $(shown - 1) &
         ", GameObjects to $g0..$g" & $(shown - 1) &
         ". NOTE: these are TRANSFORMS, not components -- `click` needs the " &
         "Button, so go through `component $g0 Button` first.")
  else:
    iOut("  this transform has no children.")

proc iParentName(p: Il2CppPtr): string =
  ## The parent's name, for disambiguation. A bare `name="Background"` is
  ## almost useless on a UI screen that has nine of them; the parent is
  ## usually what identifies which one it is.
  result = ""
  var idx = 0
  var hits = 0
  if not iFindTarget("Transform::get_parent", idx, hits):
    return
  let fn = iTargetFn(idx)
  if fn == nil or not iUnityAlive(p):
    return
  iMark("Transform::get_parent", p)
  let par = cast[Il2CppPtr](cInspUP(fn, p, nil))
  if par == nil or not duOk(par, 0x20'i32):
    return
  result = iObjName(par)

var gFnGoOfComponent: Il2CppPtr = nil
var gFnActiveInHierarchy: Il2CppPtr = nil
var gFnActiveSelfOfGo: Il2CppPtr = nil
var gFnParentOfTransform: Il2CppPtr = nil
var gActiveFnsResolved = false

proc iEnsureActiveFns(): bool =
  ## Resolve `Component::get_gameObject` and `GameObject::get_activeInHierarchy`
  ## ONCE and cache them, the same way `iInspSeedTextType` caches the managed
  ## string for `findtext` -- a per-node `iFindTarget` lookup on top of a
  ## per-node managed call would double the cost of an already-heavier walk.
  if gActiveFnsResolved:
    return gFnGoOfComponent != nil and gFnActiveInHierarchy != nil
  gActiveFnsResolved = true
  var idx = 0
  var hits = 0
  if iFindTarget("Component::get_gameObject", idx, hits):
    gFnGoOfComponent = iTargetFn(idx)
  if iFindTarget("GameObject::get_activeInHierarchy", idx, hits):
    gFnActiveInHierarchy = iTargetFn(idx)
  # The SECOND, INDEPENDENT derivation's two functions. Cached here rather
  # than in their own resolver so there is exactly one place that can fail
  # and exactly one cached answer about whether the active predicate is
  # cross-checkable on this build.
  if iFindTarget("GameObject::get_activeSelf", idx, hits):
    gFnActiveSelfOfGo = iTargetFn(idx)
  if iFindTarget("Transform::get_parent", idx, hits):
    gFnParentOfTransform = iTargetFn(idx)
  result = gFnGoOfComponent != nil and gFnActiveInHierarchy != nil

type IActiveRecv = enum
  ## WHAT KIND OF OBJECT THE ACTIVE PREDICATE WAS HANDED.
  ##
  ## MEASURED 2026-09-02: `assert-active 0x2709c6c2d80`, where that pointer is
  ## the GameObject the host's `native tabs INVENTORY` line prints as
  ## `strip=<ptr>`, FAULTED inside `Component::get_gameObject [active]` and
  ## burned "fault 1 of 8" from the session budget -- while `tree`/`parent` on
  ## the SAME pointer correctly refused it as "a GameObject where a TRANSFORM
  ## is required". The active predicate was the one path that took the
  ## Component hop unconditionally, so a GameObject -- the single most common
  ## pointer an agent has in hand -- was a fault instead of an input.
  ##
  ## So classify the receiver BEFORE the first call, exactly as the Transform
  ## walkers already do. A GameObject is not a broken input to `assert-active`;
  ## it is the answer's natural receiver.
  ActRecvGameObject   ## klass is known to be a GameObject -> call get_activeInHierarchy DIRECTLY
  ActRecvComponent    ## a live Unity object that is not a known GameObject -> Component::get_gameObject hop
  ActRecvUnknown      ## unreadable / fake-null -> NOTHING EXAMINED, no verdict

proc iActiveClassify(cur: Il2CppPtr): IActiveRecv =
  ## Three outcomes, never two. `ActRecvUnknown` is a REFUSAL, not "inactive":
  ## nothing was examined, so nothing is known.
  ##
  ## The GameObject test is the same learned klass blacklist `iRefuseIfGameObject`
  ## uses (`gGoKlass`, populated only from pointers a target returned as a
  ## GameObject BY CONTRACT), so this classification cannot disagree with the
  ## refusal `tree`/`parent` print about the same pointer.
  if cur == nil or not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
    return ActRecvUnknown
  if iIsGameObject(cur):
    return ActRecvGameObject
  result = ActRecvComponent

proc iActiveRecvLabel(cur: Il2CppPtr): string =
  ## One line naming which receiver path was taken, for the verbs that report
  ## a single pointer. Silent on the ordinary Component case.
  case iActiveClassify(cur)
  of ActRecvGameObject:
    "  receiver is a GAMEOBJECT -> called GameObject::get_activeInHierarchy " &
    "directly (no Component::get_gameObject hop)"
  of ActRecvComponent: ""
  of ActRecvUnknown:
    "  receiver could not be classified -- NOTHING EXAMINED"

proc iActiveInHierarchy(cur: Il2CppPtr): (bool, bool) =
  ## (ok, active). `activeInHierarchy` rather than `activeSelf`: a node that
  ## is itself active but sits under an inactive ancestor is still
  ## unpressable (fact #72 -- a press on an inactive GameObject returns
  ## success and does NOTHING), so `activeSelf` alone would still mislead.
  ## ok=false means the state could not be determined (function unresolved
  ## on this build, or a hop was unreadable) -- callers must NOT assume
  ## "active" in that case.
  result = (false, false)
  if not iEnsureActiveFns():
    return
  var go = cur
  case iActiveClassify(cur)
  of ActRecvUnknown:
    return
  of ActRecvGameObject:
    # ALREADY the GameObject. Taking the Component hop here is the measured
    # fault: `Component::get_gameObject` on a GameObject reads a Component's
    # fields off a GameObject's layout.
    discard
  of ActRecvComponent:
    iMark("Component::get_gameObject [active]", cur)
    go = cast[Il2CppPtr](cInspUP(gFnGoOfComponent, cur, nil))
    if not duOk(go, 0x20'i32) or not iUnityAlive(go):
      return
  iMark("GameObject::get_activeInHierarchy", go)
  let act = cInspUP(gFnActiveInHierarchy, go, nil)
  result = (true, (act and 1'u64) != 0'u64)

const InspActiveClimbMax = 64
  ## Cap on the parent climb of the derived active check. A hierarchy 64 deep
  ## is already absurd; a corrupt parent pointer that cycles is not, and an
  ## uncapped climb inside a frame is the rule-4 failure.

proc iActiveChainDerived(cur: Il2CppPtr; blocker: var string): (bool, bool) =
  ## SECOND, INDEPENDENT derivation of activeInHierarchy: climb the Transform
  ## parent chain and AND together `GameObject::get_activeSelf` at every
  ## level, exactly as `parent`'s ladder prints it.
  ##
  ## WHY A SECOND ONE EXISTS. A single call to
  ## `GameObject::get_activeInHierarchy` is a check that cannot fail: if that
  ## RVA resolves to this build's universal empty-body stub (`ret 0`, shared
  ## by 6,438 methods) the call returns whatever was left in RAX, and an odd
  ## leftover reads back as `active=true` for a node sitting under an
  ## INACTIVE ancestor. That is exactly the shape measured on
  ## `CharacterSlotView_pvp` under an inactive `CharacterSelectionScreen`.
  ## The climb cannot be fooled the same way, because it reads a different
  ## function at every one of several levels and disagrees loudly.
  ##
  ## (ok, active). ok=false means NO verdict -- a function was unresolved, a
  ## hop was unreadable, or the climb hit its cap. `blocker` names the first
  ## level found inactive, which is the thing a caller actually wants to know.
  result = (false, false)
  blocker = ""
  if not iEnsureActiveFns():
    return
  if gFnActiveSelfOfGo == nil or gFnParentOfTransform == nil:
    return
  # `node` must be a TRANSFORM: the climb calls Component::get_gameObject and
  # Transform::get_parent on it. A GameObject receiver is converted with
  # GameObject::get_transform first -- NOT Component::get_transform, which is
  # the same type confusion in the other direction.
  var node = cur
  case iActiveClassify(cur)
  of ActRecvUnknown:
    return
  of ActRecvGameObject:
    iMark("GameObject::get_activeSelf [active chain, GO receiver]", cur)
    let a0 = cInspUP(gFnActiveSelfOfGo, cur, nil)
    if (a0 and 1'u64) == 0'u64:
      blocker = iObjName(cur)
      return (true, false)
    node = iTransformOfGameObject(cur)
    if node == nil or not duOk(node, 0x20'i32) or not iUnityAlive(node):
      # Its own activeSelf is true but the ancestors were never examined ->
      # NO verdict. Returning "active" here would be a check that cannot fail.
      return
  of ActRecvComponent:
    discard
  var hops = 0
  while hops < InspActiveClimbMax:
    if not duOk(node, 0x20'i32) or not iUnityAlive(node):
      return
    iMark("Component::get_gameObject [active chain]", node)
    let go = cast[Il2CppPtr](cInspUP(gFnGoOfComponent, node, nil))
    if not duOk(go, 0x20'i32) or not iUnityAlive(go):
      return
    iMark("GameObject::get_activeSelf [active chain]", go)
    let a = cInspUP(gFnActiveSelfOfGo, go, nil)
    if (a and 1'u64) == 0'u64:
      blocker = iObjName(node)
      result = (true, false)
      return
    iMark("Transform::get_parent [active chain]", node)
    let par = cast[Il2CppPtr](cInspUP(gFnParentOfTransform, node, nil))
    if par == nil:
      # Reached the top of the hierarchy with every level active.
      result = (true, true)
      return
    if not duOk(par, 0x20'i32) or not iUnityAlive(par):
      return
    node = par
    inc hops
  # THE CAP IS NOT A VERDICT. Falling out of the loop means the chain was
  # longer than the cap (or cycles), so nothing is known -- do not return
  # "active" for a chain that was never finished.

proc iActiveInHierarchyChecked(cur: Il2CppPtr; note: var string): (bool, bool) =
  ## THE predicate. `assert-active`, `findtext`'s ACTIVE scope and every HIT
  ## line's `activeInHierarchy=` tag all go through this one proc, so the
  ## filter and the label can never disagree with each other, and neither can
  ## disagree with what `assert-active` reports about the same pointer.
  ##
  ## Three outcomes, never two: agree -> that value; DISAGREE -> INCONCLUSIVE
  ## (ok=false) with a note naming both answers, because one of the two
  ## instruments is lying and picking a winner would just pick a lie; only one
  ## available -> that one, noted.
  note = ""
  if iActiveClassify(cur) == ActRecvUnknown:
    note = "active-receiver: NOTHING EXAMINED for " & iPtr(cur) &
           " -- it is not readable, or its native half is gone (Unity " &
           "fake-null). No active/inactive verdict was formed."
    return (false, false)
  let (callOk, callAct) = iActiveInHierarchy(cur)
  var blocker = ""
  let (chainOk, chainAct) = iActiveChainDerived(cur, blocker)
  if callOk and chainOk:
    if callAct == chainAct:
      result = (true, callAct)
    else:
      note = "activeInHierarchy CROSS-CHECK DISAGREEMENT on " & iPtr(cur) &
             ": GameObject::get_activeInHierarchy said " &
             (if callAct: "true" else: "false") &
             ", but the parent chain (get_activeSelf at every level) said " &
             (if chainAct: "true" else: "false") &
             (if blocker.len > 0: " -- inactive ancestor \"" & blocker & "\""
              else: "") &
             ". One of the two is wrong, so this node's pressability is " &
             "INCONCLUSIVE and it is NOT reported as pressable."
      result = (false, false)
  elif callOk:
    result = (true, callAct)
  elif chainOk:
    note = "activeInHierarchy was DERIVED from the parent chain for " &
           iPtr(cur) & " (GameObject::get_activeInHierarchy did not answer)" &
           (if (not chainAct) and blocker.len > 0:
              "; inactive ancestor \"" & blocker & "\"" else: "") & "."
    result = (true, chainAct)
  else:
    result = (false, false)

proc iHierRoot(p: Il2CppPtr): Il2CppPtr =
  ## Climb to the top of the hierarchy. ONLY called when the caller did not
  ## name a root -- doing it unconditionally is the bug that made every
  ## `find X $someRoot` silently search the whole tree from the top instead,
  ## and made the ROOT argument look like it was being ignored.
  result = p
  var idx = 0
  var hits = 0
  if iFindTarget("Transform::get_root", idx, hits):
    let fn = iTargetFn(idx)
    if fn != nil and iUnityAlive(p):
      iMark("Transform::get_root", p)
      let r = cast[Il2CppPtr](cInspUP(fn, p, nil))
      if duOk(r, 0x20'i32):
        result = r

const
  FindDone     = 0   ## frontier exhausted -- a genuinely complete answer
  FindOutOfTime = 1  ## this FRAME is up, but the search may continue
  FindOutOfBudget = 2 ## the whole search's node budget is spent
  FindEnoughHits = 3  ## the match cap was reached
  FindOutOfFrames = 4
    ## THE SEARCH HELD THE CHANNEL FOR `InspFindMaxFrames` FRAMES AND WAS CUT
    ## OFF. Never returned by `iFindStep` -- the step function cannot know how
    ## many frames it has had; it is substituted by the caller when a
    ## `FindOutOfTime` is not allowed to park again.
    ##
    ## It exists because the report had no way to say this. MEASURED: a search
    ## that visited 30,720 of an 80,000 node budget printed "STOPPED EARLY on
    ## the NODE BUDGET", which sent the reader to raise a budget that was not
    ## the limiter and had 49,280 nodes left in it. Naming the wrong cause is
    ## worse than naming none: it is actionable and the action does nothing.

proc iFindStep(): int =
  ## One FRAME's slice of the breadth-first walk.
  ##
  ## Two budgets, deliberately separate, because they answer different
  ## questions. The TIME slice bounds what one frame may do -- this runs on the
  ## Unity thread, so the failure to avoid is a stalled client, which costs the
  ## whole session rather than one answer. The NODE budget bounds the entire
  ## search across however many frames it takes. Conflating them is what forced
  ## a human to type `find more`: running out of time looked identical to
  ## running out of permission.
  let started = cNowMs()
  var spent = 0
  while gFindHead < gFindQueue.len:
    if gFindBudgetLeft <= 0:
      return FindOutOfBudget
    if gFindFound >= InspFindMaxHits:
      return FindEnoughHits
    if (spent and 127) == 0 and cNowMs() - started > InspFindSliceMs:
      return FindOutOfTime
    let cur = gFindQueue[gFindHead]
    inc gFindHead
    inc spent
    dec gFindBudgetLeft
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
      inc gFindInvalidSkips
      continue
    inc gFindVisited
    iNoteKlass(cur)
    let nm = iObjName(cur)
    if nm.len > 0 and iContains(iLower(nm), gFindWant):
      inc gFindFound
      iSetVar("f" & $gFindFound, cast[uint64](cur))
      let pn = iParentName(cur)
      iOut("    HIT " & iPtr(cur) & " name=\"" & nm & "\"" &
           (if pn.len > 0: "  parent=\"" & pn & "\"" else: "") &
           "   ($f" & $gFindFound & ")")
    var n = 0
    if iChildCount(cur, n):
      var k = 0
      while k < n and k < InspMaxChildren:
        let c = iChildAt(cur, k)
        if c != nil:
          gFindQueue.add c
        inc k
  result = FindDone

proc iFindReportGeneric(status: int; visited, frames, found, invalidSkips,
                         frontier: int; verb, subjectAbsent, blindNote: string;
                         active: var bool; ownerIdx, ownerBatch: var int) =
  ## Shared reporting contract for `find` and `findtext`. Only called when the
  ## search has actually STOPPED -- running out of time is not stopping, that
  ## path parks and resumes and says nothing, because a progress report every
  ## frame would bury the answer.
  ##
  ## `verb` is "find"/"findtext" (for the `<verb> more` hint); `subjectAbsent`
  ## is the noun phrase for a genuine miss ("That name"/"No TMP text
  ## containing that substring").
  iOut("  visited " & $visited & " node(s) over " & $frames &
       " frame(s), " & $found & " match(es), frontier " & $frontier &
       " node(s)" &
       (if invalidSkips > 0:
          ", " & $invalidSkips & " unreadable/invalid node(s) skipped"
        else: ""))
  if status == FindDone:
    active = false
    ownerIdx = -1
    ownerBatch = -1
    if visited == 0:
      # Nothing was ever actually examined -- either the root(s) were all
      # invalid, or the frontier was empty. "EXHAUSTIVELY searched" and
      # "genuinely NOT PRESENT" are both claims about work that was done, and
      # none was. Say that plainly instead.
      iOut("  -- NOTHING WAS EXAMINED (0 valid nodes visited" &
           (if invalidSkips > 0:
              ", " & $invalidSkips & " root/node(s) were unreadable or " &
              "not a valid Transform"
            else: "") &
           "). This is NOT evidence the search subject is absent -- it " &
           "means the search never actually looked. Check the root pointer.")
    elif found == 0 and blindNote.len > 0:
      # THE THIRD OUTCOME. The walk completed and matched nothing, but the
      # caller has evidence that its own PREDICATE never saw the thing it
      # tests -- so "exhaustive" is true of the traversal and says nothing
      # about the subject. A verdict of NOT PRESENT here would be a check
      # that cannot fail, which is the bug this whole report contract exists
      # to prevent (CLAUDE.md 9b). Three outcomes, never two.
      iOut("  -- INCONCLUSIVE, NOT a miss. The traversal was exhaustive; the " &
           "PREDICATE was not usable. " & blindNote)
    else:
      iOut("  -- the subtree was searched EXHAUSTIVELY. " &
           (if found == 0:
              subjectAbsent & " is genuinely NOT PRESENT under this root."
            else: "Every match is listed above."))
  elif status == FindEnoughHits:
    active = true
    iOut("  -- stopped at the match cap (" & $InspFindMaxHits & "). There may " &
         "be more; `" & verb & " more` continues from the frontier above.")
  elif status == FindOutOfFrames:
    # NAME THE ACTUAL LIMITER. This branch used to fall into the one below and
    # blame the node budget, which was measurably not what stopped it.
    active = true
    iOut("  -- STOPPED EARLY on the FRAME CAP (" & $InspFindMaxFrames &
         " frames), NOT on the node budget: " & $visited & " node(s) were " &
         "visited and the budget still has room. A parked batch holds the " &
         "channel, so one search may not hold it forever. This is NOT proof " &
         "the subject is absent. Continue with `" & verb & " more` -- the " &
         "frontier above is KEPT, so it resumes rather than re-walking -- or " &
         "search from a narrower root, or raise `inspectorSliceMs` so each " &
         "frame covers more ground (menu only; a large slice during a raid " &
         "LOAD stalls the Unity thread).")
  else:
    active = true
    # THE HONEST CAP MESSAGE, unchanged in substance: "not found within budget"
    # and "not present" are different facts and must never be conflated.
    iOut("  -- STOPPED EARLY on the NODE BUDGET. This is NOT proof the " &
         "subject is absent. Continue with `" & verb & " more` (it RESUMES " &
         "from the frontier above and does not re-walk what it already " &
         "rejected), or re-run with a bigger budget, or search from a " &
         "narrower root.")
  if found > 0:
    iOut("  matches are bound to $f1..$f" & $found & " for the rest of this batch")

proc iFindStopReason(st: int; budgetLeft, frames: int): int =
  ## WHY DID THIS SEARCH STOP -- asked only of a step result the caller has
  ## decided NOT to park.
  ##
  ## `iFindStep` returns `FindOutOfTime` for the end of a FRAME SLICE, which is
  ## normally a park-and-resume and not a stop at all. When the caller stops on
  ## it anyway, the slice is not the limiter: the FRAME CAP is (or the node
  ## budget, if that ran out in the same step -- then the budget is the honest
  ## answer and it wins). Reporting a stop with the step's own status is how
  ## "STOPPED EARLY on the NODE BUDGET" came to be printed for a search with
  ## 49,280 unspent nodes.
  if st != FindOutOfTime:
    return st
  if budgetLeft <= 0:
    return FindOutOfBudget
  result = FindOutOfFrames

proc iFindReport(status: int) =
  iFindReportGeneric(status, gFindVisited, gFindFrames, gFindFound,
                      gFindInvalidSkips, gFindQueue.len - gFindHead,
                      "find", "That name", "", gFindActive, gFindOwnerIdx,
                      gFindOwnerBatch)
  # `find`'s predicate is a raw name compare on a node it already walked --
  # it has no separate instrument that can go blind -- so it passes no blind
  # note. That is a statement about this predicate, not a default.

proc iCollectByName(want: string; roots: seq[Il2CppPtr]; budget: int;
                    maxHits: int; into: var seq[Il2CppPtr];
                    exhaustive: var bool): int =
  ## Collect EVERY node whose GameObject name contains `want`, breadth-first
  ## from `roots`, bounded by BOTH a node budget and a single 12ms time slice.
  ## `exhaustive` reports whether the frontier was drained (a complete answer)
  ## or the walk stopped early -- `pressname` MUST treat a non-exhaustive walk
  ## as INCONCLUSIVE, never as "that many candidates exist". Atomic on purpose:
  ## one call, one frame's slice, no cross-frame resume, because a navigation
  ## press must decide on a single consistent snapshot of the tree.
  into = @[]
  exhaustive = true
  var queue: seq[Il2CppPtr] = @[]
  for r in roots:
    if r != nil:
      queue.add r
  var head = 0
  var seen = 0
  let started = cNowMs()
  let w = iLower(want)
  while head < queue.len:
    if seen >= budget:
      exhaustive = false
      break
    if (seen and 255) == 0 and cNowMs() - started > InspFindSliceMs:
      exhaustive = false
      break
    if into.len >= maxHits:
      exhaustive = false
      break
    let cur = queue[head]
    inc head
    inc seen
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
      continue
    let nm = iObjName(cur)
    if nm.len > 0 and iContains(iLower(nm), w):
      into.add cur
    var n = 0
    if iChildCount(cur, n):
      var k = 0
      while k < n and k < InspMaxChildren:
        let c = iChildAt(cur, k)
        if c != nil:
          queue.add c
        inc k
  result = into.len

proc iFindTextStep(): int =
  ## One FRAME's slice of the breadth-first walk, mirroring `iFindStep` exactly
  ## in shape and budgets -- see that proc's comment for the two-budget
  ## rationale. The difference is what happens AT each node: instead of a raw
  ## name compare, this asks the node's GameObject for a TextMeshProUGUI
  ## component and reads ITS text, because `find`'s own name match cannot see
  ## what a control DISPLAYS.
  ##
  ## fact #88: a caption can live on any of several TMPs under one control, so
  ## this walks EVERY node (not just leaves, not just the first hit) rather
  ## than stopping at the first TMP found under a subtree -- each TMP in
  ## practice sits on its own GameObject, so a full node-by-node walk already
  ## covers all of them without a second, heavier per-node component listing.
  ## THE PREDICATE IS NOW KLASS IDENTITY, NOT A TYPE-NAME STRING.
  ## `Component::GetComponent(Type)` @0x52A45E0 matches inside the runtime by
  ## class, takes the `System.Type` resolved once per slice from the offline
  ## index, and allocates nothing. The string overload it replaced returned
  ## NULL on all 1263 nodes of an open Settings screen -- see
  ## `iInspSeedTextType` for that measurement.
  # A SEEDING FAILURE MID-SEARCH IS A STOP, NOT A COMPLETION. Returning
  # FindDone here would let the report say "searched EXHAUSTIVELY" about a
  # frame in which the predicate did not exist -- the same wrong-answer shape
  # this whole change is about. FindOutOfBudget reports STOPPED EARLY.
  if not iInspSeedTextType():
    gTxtKlassNote = "the System.Type for TMPro.TextMeshProUGUI stopped " &
      "resolving mid-search (" & gTxtSeedWhy & "), so this search STOPPED " &
      "rather than finished; no absence verdict is available"
    return FindOutOfBudget
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet("Component::GetComponent(Type)", fn) or fn == nil:
    gTxtKlassNote = "Component::GetComponent(Type) @0x52A45E0 did not " &
      "resolve or did not byte-verify, so nothing could be asked of any node"
    return FindOutOfBudget
  let started = cNowMs()
  var spent = 0
  while gTxtHead < gTxtQueue.len:
    if gTxtBudgetLeft <= 0:
      return FindOutOfBudget
    if gTxtFound >= InspFindMaxHits:
      return FindEnoughHits
    if (spent and 63) == 0 and cNowMs() - started > InspFindSliceMs:
      return FindOutOfTime
    let cur = gTxtQueue[gTxtHead]
    inc gTxtHead
    inc spent
    dec gTxtBudgetLeft
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
      inc gTxtInvalidSkips
      continue
    inc gTxtVisited
    iNoteKlass(cur)
    # EVERY HOP GUARDED. `cur` is a Transform by contract (queue is seeded and
    # fed only from Transforms below), so the Component overload is correct
    # here without the GameObject/Component branch `component` needs.
    iMark("Component::GetComponent(Type) [findtext]", cur)
    let comp = cast[Il2CppPtr](cInspUPP(fn, cur, gTmpTypeObj, nil))
    if comp == nil:
      inc gTxtTmpNull
    if comp != nil and duOk(comp, 0xE8'i32) and iUnityAlive(comp):
      # THE POSITIVE CONTROL, counted at the source: a TMP component was
      # actually returned for this node. `gTxtTmpSeen == 0` over a large walk
      # is the signature of a blind predicate, and the report refuses to say
      # NOT PRESENT in that case.
      inc gTxtTmpSeen
      # KLASS IDENTITY, CONFIRMED ONCE PER DISTINCT KLASS, not per node. The
      # runtime already matched by class; this checks that what came back
      # really is a TextMeshProUGUI by walking its Il2CppClass.parent chain
      # and validating every name against this build's metadata. A repeat of
      # a klass already confirmed costs one pointer compare.
      let ck = iKlassOf(comp)
      if ck != 0'u64 and ck != gTxtTmpKlass and gTxtKlassNote.len == 0:
        var chain = ""
        let verdict = iKlassIs(comp, "TMPro.TextMeshProUGUI", chain)
        if verdict == KlassYes:
          gTxtTmpKlass = ck
        elif verdict == KlassNo:
          gTxtKlassNote = "the component returned for the TMP type is " &
            chain & ", which does NOT derive from TMPro.TextMeshProUGUI -- " &
            "the hits below are suspect"
        else:
          gTxtKlassNote = "the klass chain of the returned component could " &
            "not be read to the end (" & chain & "); hits are reported but " &
            "their type is UNCONFIRMED"
      # `comp` is a real Component pointer returned by GetComponent by
      # contract -- unlike `label`'s EXPR, it is never a bare Transform, so
      # no klass-confusion guard is needed here. `sp` (m_text at +0xE0) IS
      # guarded exactly as `label` guards it: a known-klass value there means
      # type confusion, not a String, and must not be dereferenced as one.
      iNoteKlass(comp)
      let sp = cReadPtrAt(comp, 0xE0'i32)
      if sp != nil and not iIsKnownKlass(cast[uint64](sp)) and duOk(sp, 0x18'i32):
        let txt = suiReadString(sp)
        if txt.len > 0 and iContains(iLower(txt), gTxtWant):
          # THE SAME PREDICATE `assert-active` USES, and the same one the
          # tag below prints -- one evaluation, one truth. Evaluated per HIT,
          # not per node, so the parent climb costs at most InspFindMaxHits
          # ladders per search.
          var actNote = ""
          let (activeOk, active) = iActiveInHierarchyChecked(cur, actNote)
          if actNote.len > 0 and gTxtActiveNote.len == 0:
            gTxtActiveNote = actNote
          if gTxtActiveOnly and activeOk and not active:
            inc gTxtInactiveSkipped
          else:
            if not activeOk:
              # NOT a silent inclusion: an unestablished active state is
              # counted and tagged, because "I could not look" is not "yes".
              inc gTxtActiveUnknown
            inc gTxtFound
            iSetVar("f" & $gTxtFound, cast[uint64](cur))
            let nm = iObjName(cur)
            let pn = iParentName(cur)
            let activeTag = (if not activeOk:
                               "  activeInHierarchy=UNKNOWN (NOT verified " &
                               "pressable)"
                              elif active: "  activeInHierarchy=true"
                              else: "  activeInHierarchy=FALSE (unpressable)")
            iOut("    HIT " & iPtr(cur) &
                 (if nm.len > 0: "  name=\"" & nm & "\"" else: "") &
                 (if pn.len > 0: "  parent=\"" & pn & "\"" else: "") &
                 "  text=\"" & txt & "\"" & activeTag &
                 "   ($f" & $gTxtFound & ")")
    var n = 0
    if iChildCount(cur, n):
      var k = 0
      while k < n and k < InspMaxChildren:
        let c = iChildAt(cur, k)
        if c != nil:
          gTxtQueue.add c
        inc k
  result = FindDone

proc iFindTextReport(status: int) =
  ## Same reporting contract as `iFindReport` -- STOPPED EARLY is never
  ## conflated with NOT PRESENT, and NOTHING EXAMINED is never conflated with
  ## either. Additionally states which SCOPE (active-only vs all) was
  ## searched -- "EXHAUSTIVELY" while silently skipping or silently including
  ## unpressable nodes is the same wrong-answer class as the other findtext
  ## defects (fact #72: a press on an inactive node returns ok=True and does
  ## nothing).
  # THE POSITIVE CONTROL, EVALUATED HERE AND NOWHERE ELSE.
  #
  # `gTxtTmpSeen` counts nodes that RETURNED a TMP component, which is a
  # different question from how many matched the substring. If a large,
  # normally caption-rich walk found ZERO components, the predicate is blind
  # and no absence verdict is available -- that is exactly the state the old
  # string-overload predicate was in permanently, and it reported "genuinely
  # NOT PRESENT" for 1263 nodes of an open Settings screen.
  #
  # The threshold is on NODES VISITED, not on hits: a 5-node search that
  # legitimately contains no TMP must still be able to answer NOT PRESENT.
  var blindNote = ""
  if gTxtVisited > InspTextBlindMinNodes and gTxtTmpSeen == 0:
    blindNote = "INCONCLUSIVE: no TMP component was seen on any node, " &
      "the predicate is blind. " & $gTxtVisited & " node(s) were visited and " &
      "Component::GetComponent(Type) returned NULL on every one of them (" &
      $gTxtTmpNull & " NULLs), so this search never had a way to say yes. " &
      "This is NOT evidence the text is absent. Check that the offline name " &
      "index is loaded (`state`) and that TMPro.TextMeshProUGUI resolved."
  iFindReportGeneric(status, gTxtVisited, gTxtFrames, gTxtFound,
                      gTxtInvalidSkips, gTxtQueue.len - gTxtHead,
                      "findtext", "No TMP text containing that substring",
                      blindNote,
                      gTxtActive, gTxtOwnerIdx, gTxtOwnerBatch)
  if gTxtTmpSeen > 0:
    iOut("  predicate control: " & $gTxtTmpSeen & " node(s) carried a " &
         "TextMeshProUGUI (of " & $gTxtVisited & " visited) -- the predicate " &
         "demonstrably CAN answer yes on this subtree.")
  if gTxtKlassNote.len > 0:
    iErr("klass identity: " & gTxtKlassNote)
  if gTxtActiveOnly:
    iOut("  scope: ACTIVE nodes only (activeInHierarchy, cross-checked " &
         "against the parent chain -- the same predicate `assert-active` " &
         "uses)" &
         (if gTxtInactiveSkipped > 0:
            "; " & $gTxtInactiveSkipped & " inactive hit(s) skipped -- " &
            "re-run as `findtext ... all` to include them"
          else: ""))
  if gTxtActiveUnknown > 0:
    iErr("INCONCLUSIVE for " & $gTxtActiveUnknown & " hit(s): their " &
         "activeInHierarchy could not be established, so they are listed but " &
         "NOT claimed pressable. Confirm each with `assert-active $fN` " &
         "before pressing it.")
  if gTxtActiveNote.len > 0:
    iErr("active predicate: " & gTxtActiveNote)
  else:
    iOut("  scope: ALL nodes, active and inactive -- `all` was passed, so " &
         "some hits above may be unpressable; check activeInHierarchy on " &
         "each before pressing")

const InspMaxScenes = 24
const InspMaxRootsPerScene = 96

proc iRootsOfHandle(handle: int32; label: string; into: var seq[Il2CppPtr];
                    report: bool; bound: var int) =
  ## Enumerate one scene's root GameObjects, given its handle.
  ##
  ## The COUNT is taken from the returned array, not from
  ## `GetRootCountInternal`. The array is the authority: it is what we actually
  ## walk, so believing anything else about its length is a way to be
  ## confidently wrong about the thing in front of us.
  var fnRoots: Il2CppPtr = nil
  if not iNavFindQuiet("Scene::GetRootGameObjects", fnRoots):
    return
  cNavSetSceneHandle(handle)
  iMark("Scene::GetRootGameObjects", cNavSceneHandlePtr())
  let arr = cast[Il2CppPtr](cInspUP(fnRoots, cNavSceneHandlePtr(), nil))
  if arr == nil or not duOk(arr, cNavOffArrData() + 8'i32):
    if report:
      iOut("    " & label & ": no readable root array")
    return
  let alen = cReadI32At(cast[Il2CppPtr](cast[uint64](arr) +
                        uint64(cNavOffArrLen())))
  if alen < 0 or alen > InspMaxRootsPerScene:
    if report:
      iOut("    " & label & ": root array length " & $alen &
           " is not credible; skipped")
    return
  if report and alen == 0:
    iOut("    " & label & ": 0 roots")
  var k = 0
  while k < alen:
    let go = cReadPtrAt(arr, cNavOffArrData() + int32(k * 8))
    if go != nil and duOk(go, 0x20'i32):
      iNoteKlass(go)
      # These are GAMEOBJECTS by contract -- record the klass so the walker can
      # refuse one if it ever reaches it untranslated.
      iNoteGameObject(go)
      # CONVERT TO A TRANSFORM HERE, ONCE, at the boundary. Everything
      # downstream -- children, tree, parent, find -- operates on Transforms,
      # so a $rN that meant something different from $c0 or $f1 would be a trap
      # waiting for someone to walk into it later.
      let t = iTransformOfGameObject(go)
      if t == nil:
        if report:
          iOut("    [skip] " & iPtr(go) & " name=\"" & iObjName(go) &
               "\" has no readable Transform")
      else:
        iNoteKlass(t)
        # `GameObject::get_transform` returns a TRANSFORM by contract.
        iNoteTransform(t)
        into.add t
        if report:
          iSetVar("r" & $bound, cast[uint64](t))
          iSetVar("rgo" & $bound, cast[uint64](go))
          iOut("    [$r" & $bound & "] transform=" & iPtr(t) &
               "  go=" & iPtr(go) & " ($rgo" & $bound & ")" &
               "  name=\"" & iObjName(t) & "\"   (" & label & ")")
        inc bound
    inc k

proc iSceneNameOf(handle: int32): string =
  result = ""
  var fnName: Il2CppPtr = nil
  if not iNavFindQuiet("Scene::GetNameInternal", fnName):
    return
  iMark("Scene::GetNameInternal", cast[Il2CppPtr](0))
  result = suiReadString(cast[Il2CppPtr](cInspUI(fnName, handle, nil)))

proc iAnchorSceneHandle(ok: var bool; anchor: Il2CppPtr = nil): int32 =
  ## Ask Unity which scene a KNOWN-LIVE object belongs to.
  ##
  ## `anchor` is the object to ask. Pass your OWN live object; `nil` falls back
  ## to `gInspPreloader`, which is what every caller used to get implicitly.
  ##
  ## THE PARAMETER EXISTS BECAUSE THE IMPLICIT FALLBACK CAUSED THREE SEPARATE
  ## BUGS IN ONE DAY. `gInspPreloader` has exactly ONE writer in the whole
  ## host -- `inspectFired`, the live inspector's rider -- so any feature that
  ## reached scene roots through here was silently depending on the inspector
  ## being armed AND having ticked first. When it had not, `iSceneRoots`
  ## returned zero roots, and callers reported a confident "not found" for a
  ## search that had barely run: the mode-button hider searched 66 nodes and
  ## announced "no MenuScreen within 3 levels of ANY root". The same shape is
  ## already recorded as fact #108 (the `$settings` anchor read a global only a
  ## separate experimental hook ever wrote) and it took out the version brand
  ## too, which polled for a `PreloaderUI` anchor it could never obtain.
  ##
  ## A caller with its own live object should pass it and depend on nothing.
  ##
  ## This is what reaches the objects `SceneManager` will not enumerate. On
  ## this build the menu lives in the DontDestroyOnLoad scene, which
  ## `sceneCount`/`GetSceneAt` exclude by design -- so every scene they DO
  ## report has zero roots and the interesting hierarchy is invisible to them.
  ## Asking a live object for its own scene is a real answer from the runtime,
  ## not a hierarchy climb presented as a scene root.
  ok = false
  result = 0'i32
  var seed = anchor
  if seed == nil: seed = gInspPreloader
  if seed == nil:
    return
  let go = iGameObjectOf(seed)
  if go == nil or not iUnityAlive(go):
    return
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet("GameObject::get_scene_Injected", fn):
    return
  cNavSetSceneHandle(0'i32)
  iMark("GameObject::get_scene_Injected", go)
  # rcx = the GameObject, rdx = Scene* out param.
  discard cInspUPP(fn, go, cNavSceneHandlePtr(), nil)
  result = cReadI32At(cNavSceneHandlePtr())
  ok = true

var gInspDdolHandle = 0'i32
var gInspDdolKnown = false
  ## THE DontDestroyOnLoad SCENE HANDLE, REMEMBERED FOR THE SESSION.
  ##
  ## MEASURED, from inside a live Woods raid: `roots` returned only the
  ## LOCATION scene's roots (`woods_terrain`, `AICoversData`, `Location
  ## Scene`, ...) and NOT `Common UI` / `Menu UI` / `Preloader UI`. Rootless
  ## `find MenuScreen 80000` + two `find more` then ended "searched
  ## EXHAUSTIVELY ... genuinely NOT PRESENT" for a screen that was alive. That
  ## verdict was false, and it is the reason `tools/exitraid.py` refused every
  ## attempt with "no `Common UI` scene root".
  ##
  ## THE CAUSE: DontDestroyOnLoad is reached by asking a LIVE ANCHOR which
  ## scene it belongs to, and the only anchor here is `gInspPreloader`, written
  ## solely by `EFT.UI.PreloaderUI::Update` -- which does not tick in a raid.
  ## In-raid that anchor is stale or its native half is gone, so
  ## `iAnchorSceneHandle` answers "could not look", and the union silently
  ## collapsed to the scenes SceneManager lists.
  ##
  ## THE FIX: a scene HANDLE is all `Scene::GetRootGameObjects` needs -- no
  ## anchor, no hierarchy climb. DontDestroyOnLoad is created once per process,
  ## so the handle learned at the menu is still the right handle in a raid. It
  ## is cached here and REVALIDATED BY NAME on every use: if the handle no
  ## longer names DontDestroyOnLoad it is dropped and said so, never
  ## enumerated on faith.

proc iSceneRoots(into: var seq[Il2CppPtr]; report: bool;
                 anchor: Il2CppPtr = nil): int =
  ## Every root GameObject we can legitimately reach, from two sources:
  ## the scenes SceneManager enumerates, and the scene a live anchor actually
  ## belongs to (which is how DontDestroyOnLoad is reached).
  ##
  ## `anchor` is that live object. Pass your own; `nil` keeps the historical
  ## behaviour of using `gInspPreloader`, which ONLY the live inspector's rider
  ## ever writes -- see `iAnchorSceneHandle` for why depending on that
  ## implicitly is a trap, and what it cost.
  result = 0
  var fnCount: Il2CppPtr = nil
  var fnAt: Il2CppPtr = nil
  var fnLoaded: Il2CppPtr = nil
  var fnRootCount: Il2CppPtr = nil
  var rva = 0'u32
  var seen: seq[int32] = @[]

  if iNavFind("SceneManager::get_sceneCount", fnCount, rva) and
     iNavFind("SceneManager::GetSceneAt", fnAt, rva):
    discard iNavFindQuiet("Scene::GetIsLoadedInternal", fnLoaded)
    discard iNavFindQuiet("Scene::GetRootCountInternal", fnRootCount)
    iMark("SceneManager::get_sceneCount", cast[Il2CppPtr](0))
    let n = int(int32(uint32(cInspUV(fnCount, nil) and 0xFFFFFFFF'u64)))
    if n < 0 or n > InspMaxScenes:
      if report:
        iErr("sceneCount came back as " & $n & ", which is not credible; " &
             "refusing to loop on it.")
    else:
      if report:
        iOut("  " & $n & " scene(s) from SceneManager")
      var si = 0
      while si < n:
        iMark("SceneManager::GetSceneAt", cast[Il2CppPtr](0))
        let handle = int32(uint32(cInspUI(fnAt, int32(si), nil) and
                                  0xFFFFFFFF'u64))
        let sname = iSceneNameOf(handle)
        var loaded = true
        if fnLoaded != nil:
          iMark("Scene::GetIsLoadedInternal", cast[Il2CppPtr](0))
          loaded = (cInspUI(fnLoaded, handle, nil) and 1'u64) != 0'u64
        var rc = -1
        if fnRootCount != nil:
          iMark("Scene::GetRootCountInternal", cast[Il2CppPtr](0))
          rc = int(int32(uint32(cInspUI(fnRootCount, handle, nil) and
                                0xFFFFFFFF'u64)))
        if report:
          iOut("  scene[" & $si & "] handle=" & $int(handle) & " name=\"" &
               sname & "\" loaded=" & (if loaded: "true" else: "false") &
               (if rc >= 0: " rootCount=" & $rc else: ""))
        if loaded:
          seen.add handle
          iRootsOfHandle(handle, sname, into, report, result)
        inc si

  # THE SCENE SCENEMANAGER DOES NOT LIST.
  var haveAnchor = false
  var ah = iAnchorSceneHandle(haveAnchor, anchor)
  if not haveAnchor and anchor == nil and gSettingsLiveSelf != nil:
    # SECOND ANCHOR, NOT A SECOND GUESS. The SettingsScreen also lives in
    # DontDestroyOnLoad and, unlike PreloaderUI, it is not tied to a screen
    # that stops ticking in a raid -- so when the primary anchor is dead this
    # can still get a REAL answer from the runtime (`get_scene_Injected`),
    # which is the only kind of scene answer this file accepts. If it too
    # fails, nothing is assumed: the remembered-handle path below is the
    # remaining route and it revalidates by name.
    ah = iAnchorSceneHandle(haveAnchor, gSettingsLiveSelf)
    if haveAnchor and report:
      iOut("  ($preloader could not be asked; used the live SettingsScreen " &
           "as the scene anchor instead)")
  if haveAnchor:
    var already = false
    for i in 0 ..< seen.len:
      if seen[i] == ah:
        already = true
    if not already:
      let an = iSceneNameOf(ah)
      if an == "DontDestroyOnLoad":
        gInspDdolHandle = ah
        gInspDdolKnown = true
      seen.add ah
      if report:
        iOut("  scene[anchor] handle=" & $int(ah) & " name=\"" & an &
             "\"  <- the scene $preloader actually belongs to. SceneManager " &
             "does NOT list it, which on this build is where the live UI is.")
      iRootsOfHandle(ah, an, into, report, result)
    elif report:
      iOut("  ($preloader's scene, handle=" & $int(ah) &
           ", is already listed above)")
  elif report:
    iOut("  (could not ask $preloader which scene it belongs to; either the " &
         "anchor is null or GameObject::get_scene_Injected did not verify -- " &
         "in a RAID that is expected, because PreloaderUI::Update does not " &
         "tick there. The remembered DontDestroyOnLoad handle below is what " &
         "covers that case.)")

  # THE SCENE NEITHER SCENEMANAGER NOR THE ANCHOR CAN REACH RIGHT NOW.
  #
  # In a raid the anchor is dead and SceneManager lists only the location
  # scene, so without this the union is missing exactly the scene the menu
  # lives in -- and both `roots` and rootless `find` then report a confident
  # absence for objects that are alive. The handle is revalidated by NAME
  # before it is used, so a stale or recycled handle is dropped rather than
  # enumerated.
  if gInspDdolKnown:
    var already = false
    for i in 0 ..< seen.len:
      if seen[i] == gInspDdolHandle:
        already = true
    if not already:
      let dn = iSceneNameOf(gInspDdolHandle)
      if dn == "DontDestroyOnLoad":
        if report:
          iOut("  scene[ddol] handle=" & $int(gInspDdolHandle) &
               " name=\"" & dn & "\"  <- REMEMBERED from when an anchor could " &
               "still be asked. This is what makes Common UI / Menu UI / " &
               "Preloader UI reachable IN A RAID, where PreloaderUI does not " &
               "tick and the anchor is gone.")
        seen.add gInspDdolHandle
        iRootsOfHandle(gInspDdolHandle, dn, into, report, result)
      else:
        gInspDdolKnown = false
        if report:
          iOut("  (the remembered DontDestroyOnLoad handle " &
               $int(gInspDdolHandle) & " now names \"" & dn & "\", so it is " &
               "NOT that scene any more and was DROPPED rather than " &
               "enumerated on faith.)")
proc iSceneNamePresent*(needle: string): int32 =
  ## THREE OUTCOMES, never two (CLAUDE.md 9b):
  ##    1  a scene SceneManager lists is named exactly `needle`
  ##    0  SceneManager was successfully enumerated and NO scene matched
  ##   -1  I COULD NOT LOOK -- a nav entry did not verify, or sceneCount came
  ##       back at a value that is not credible. "-1" is a refusal and a caller
  ##       must NOT read it as "absent".
  ##
  ## Names ONLY: no root enumeration, no GetRootGameObjects (which allocates).
  ## This exists so the raid-phase gate can see `SessionEndUIScene` -- the
  ## post-raid results screen, which is the single scene SceneManager lists at
  ## that moment -- without paying for `iSceneRoots`.
  var fnCount: Il2CppPtr = nil
  var fnAt: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFindQuiet("SceneManager::get_sceneCount", fnCount):
    return -1'i32
  if not iNavFindQuiet("SceneManager::GetSceneAt", fnAt):
    return -1'i32
  var fnName: Il2CppPtr = nil
  if not iNavFindQuiet("Scene::GetNameInternal", fnName):
    return -1'i32
  discard rva
  iMark("SceneManager::get_sceneCount", cast[Il2CppPtr](0))
  let n = int(int32(uint32(cInspUV(fnCount, nil) and 0xFFFFFFFF'u64)))
  if n < 0 or n > InspMaxScenes:
    return -1'i32
  var si = 0
  while si < n:
    iMark("SceneManager::GetSceneAt", cast[Il2CppPtr](0))
    let handle = int32(uint32(cInspUI(fnAt, int32(si), nil) and 0xFFFFFFFF'u64))
    if iSceneNameOf(handle) == needle:
      return 1'i32
    inc si
  0'i32

proc iCmdRoots(toks: seq[string]) =
  ## `roots` -- every root GameObject of every loaded scene, bound to $r0..$rN.
  ##
  ## This is what makes the inspector usable from a cold menu. Without it every
  ## search was reachability-limited to whatever tree we already had a pointer
  ## into, which in the menu is one PreloaderUI object -- and the screens worth
  ## driving live under a different root entirely.
  var seeded: seq[Il2CppPtr] = @[]
  iOut("  via SceneManager::get_sceneCount / GetSceneAt, " &
       "Scene::GetNameInternal / GetIsLoadedInternal / GetRootCountInternal, " &
       "GameObject::get_scene_Injected, Scene::GetRootGameObjects " &
       "(calls; the last one ALLOCATES)")
  let n = iSceneRoots(seeded, true)
  if n == 0:
    iErr("no scene roots were enumerated anywhere -- neither in the scenes " &
         "SceneManager lists nor in the scene $preloader belongs to. If a " &
         "target did not verify, the reason was printed with it above. Note " &
         "that scenes legitimately reporting 0 roots is Unity telling the " &
         "truth, not a failure to read them.")
    return
  iOut("  " & $n & " root(s) bound to $r0..$r" & $(n - 1) &
       " as TRANSFORMS -- the same kind of pointer $c0 and $f1 are, so they " &
       "go straight into children/tree/parent/find. The GameObject of each is " &
       "$rgo0..$rgo" & $(n - 1) & " (that is what `component` wants).")
  iOut("  e.g.  find PvE $r9        or   children $r9")

proc iTokIsWordy(s: string): bool =
  ## True when a token is made ONLY of letters (plus the `-`/`_` a caption
  ## picks up), i.e. a token that can never be an anchor (`$x`), a hex
  ## pointer (`0x..`) or a budget (digits). Such a token in the ROOT slot is
  ## always a typo -- almost always an UNQUOTED multi-word needle whose
  ## second word landed where the root belongs.
  if s.len == 0:
    return false
  var sawAlpha = false
  for i in 0 ..< s.len:
    let c = s[i]
    if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'):
      sawAlpha = true
    elif c == '-' or c == '_':
      discard
    else:
      return false
  result = sawAlpha

proc iFindIsGrammarWord(s: string): bool =
  ## The three bare words that are part of the grammar rather than a root.
  let t = iLower(s)
  result = t == "all" or t == "more" or t == "in"

proc iFindNothingExamined(cmdName: string) =
  ## Print the SAME completeness verdict `iFindReportGeneric` prints when a
  ## walk visited zero nodes, so a refusal before the walk is classified by a
  ## parser exactly like a refusal during one. A refusal that carries no
  ## completeness line reads to a consumer that only counts hits as "0 hits,
  ## nothing wrong" -- which is the silent-wrong-answer class this whole
  ## report contract exists to prevent (CLAUDE.md 9b).
  iOut("  visited 0 node(s) over 0 frame(s), 0 match(es), frontier 0 node(s)")
  iOut("  -- NOTHING WAS EXAMINED (0 valid nodes visited). This is NOT " &
       "evidence the search subject is absent -- it means `" & cmdName &
       "` refused before it looked. Nothing was searched.")

proc iNameSame(a, b: string): bool =
  ## Case-insensitive EQUALITY, not containment. The distinction is the whole
  ## point of `iFindRootByName`.
  iLower(a) == iLower(b)

proc iFindRootScan(want: string; roots: seq[Il2CppPtr]; budget: int;
                   exact: var Il2CppPtr; exactCount: var int;
                   loose: var Il2CppPtr; looseName: var string;
                   exhaustive: var bool) =
  ## ONE breadth-first walk that answers BOTH questions a root-by-name lookup
  ## has: is there an EXACT name match (and is it unique), and -- only so the
  ## refusal can name it -- is there a substring-only near-miss.
  ##
  ## `exhaustive` reports whether the frontier was actually drained. A scan
  ## that ran out of budget or out of frame time has NOT established that no
  ## root by that name exists, and the caller must not turn it into an
  ## absence verdict.
  exact = nil
  exactCount = 0
  loose = nil
  looseName = ""
  exhaustive = false
  var queue: seq[Il2CppPtr] = @[]
  var i = 0
  while i < roots.len:
    queue.add roots[i]
    inc i
  var head = 0
  var seen = 0
  let started = cNowMs()
  let w = iLower(want)
  while head < queue.len:
    if seen >= budget:
      return
    if (seen and 255) == 0 and cNowMs() - started > InspFindSliceMs:
      return
    let cur = queue[head]
    inc head
    inc seen
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
      continue
    let nm = iObjName(cur)
    if nm.len > 0:
      if iNameSame(nm, want):
        inc exactCount
        if exact == nil:
          exact = cur
      elif loose == nil and iContains(iLower(nm), w):
        loose = cur
        looseName = nm
    var n = 0
    if iChildCount(cur, n):
      var k = 0
      while k < n and k < InspMaxChildren:
        let c = iChildAt(cur, k)
        if c != nil:
          queue.add c
        inc k
  exhaustive = true

proc iFindRootByName(want: string; cmdName: string;
                     root: var Il2CppPtr): bool =
  ## `find X in ROOT` / `findtext X in ROOT` -- resolve ROOT BY NAME.
  ##
  ## MEASURED DEFECT THIS REPLACES: the old resolver took ONE token, matched
  ## by SUBSTRING, and searched only the tree `$preloader` happens to belong
  ## to. `find X in Menu UI` therefore read the root name as "Menu", matched
  ## "Context Menu Area" by substring, searched that, and reported X
  ## "genuinely NOT PRESENT under this root" -- a confidently wrong absence
  ## about a root nobody asked for. Quoting it (`in "Menu UI"`) found no root
  ## at all, because the real "Menu UI" is a SCENE ROOT and the old scan
  ## never looked at the scene roots.
  ##
  ## So, in order: EXACT name among the scene roots; then EXACT name anywhere
  ## in the hierarchy; then REFUSE, naming the substring match it would have
  ## silently picked. A substring-only match is never used.
  root = nil
  var roots: seq[Il2CppPtr] = @[]
  let nRoots = iSceneRoots(roots, false)
  if nRoots == 0 or roots.len == 0:
    if gInspPreloader == nil:
      iErr(cmdName & ": scene-root enumeration is unavailable and " &
           "$preloader is null, so a root could not be resolved by name at " &
           "all. Nothing was searched.")
      iFindNothingExamined(cmdName)
      return false
    roots = @[]
    roots.add iHierRoot(iToTransform(gInspPreloader))
    iOut("  NOTE: scene-root enumeration did not work, so the root name is " &
         "resolved only within the tree $preloader belongs to.")

  # PASS 1 -- EXACT, among the scene roots THEMSELVES. This is the pass that
  # makes `in "Menu UI"` work: a scene root is not a child of anything, so a
  # hierarchy walk seeded elsewhere structurally cannot reach it.
  var topHit: Il2CppPtr = nil
  var topCount = 0
  var i = 0
  while i < roots.len:
    let r = roots[i]
    inc i
    if not duOk(r, 0x20'i32) or not iUnityAlive(r):
      continue
    if iNameSame(iObjName(r), want):
      inc topCount
      if topHit == nil:
        topHit = r
  if topCount == 1:
    root = topHit
    iOut("  root \"" & want & "\" resolved by EXACT name among the " &
         $roots.len & " scene root(s) to " & iPtr(root) & ".")
    return true
  if topCount > 1:
    iErr(cmdName & " REFUSED: " & $topCount & " scene roots are named " &
         "exactly \"" & want & "\", so `in " & want & "` is ambiguous. " &
         "Pass a pointer (`roots` prints $r0..$rN). Nothing was searched.")
    iFindNothingExamined(cmdName)
    return false

  # PASS 2 -- EXACT, anywhere reachable from every scene root.
  var exact: Il2CppPtr = nil
  var exactCount = 0
  var loose: Il2CppPtr = nil
  var looseName = ""
  var exhaustive = false
  iFindRootScan(want, roots, InspFindDefBudget, exact, exactCount,
                loose, looseName, exhaustive)
  if exactCount == 1:
    root = exact
    iOut("  root \"" & want & "\" resolved by EXACT name to " & iPtr(root) &
         ".")
    return true
  if exactCount > 1:
    iErr(cmdName & " REFUSED: " & $exactCount & " objects are named exactly " &
         "\"" & want & "\", so the root is ambiguous and picking the first " &
         "would be a guess. Pass a pointer instead. Nothing was searched.")
    iFindNothingExamined(cmdName)
    return false

  # PASS 3 -- NOTHING EXACT. A substring near-miss is REFUSED, not used, and
  # is named so the caller can see what the old resolver would have searched.
  if loose != nil:
    iErr(cmdName & " REFUSED: no object is named exactly \"" & want &
         "\". The closest match by substring is \"" & looseName & "\" at " &
         iPtr(loose) & ", and searching THAT and calling the result an " &
         "absence is the confidently-wrong answer this refusal exists to " &
         "prevent. If you meant it, pass its pointer, or spell the name in " &
         "full (quote it: " & cmdName & " NAME in \"" & looseName &
         "\"). Nothing was searched.")
    iFindNothingExamined(cmdName)
    return false
  if not exhaustive:
    iErr(cmdName & " REFUSED: the root-name scan STOPPED EARLY (budget " &
         $InspFindDefBudget & " nodes / one " & $int(InspFindSliceMs) &
         "ms slice) without finding \"" & want & "\", so it is NOT known " &
         "whether that root exists. Nothing was searched.")
    iFindNothingExamined(cmdName)
    return false
  iErr(cmdName & " REFUSED: no object named exactly \"" & want & "\" exists " &
       "under any of the " & $roots.len & " scene root(s) (the scan drained " &
       "its frontier). `roots` lists the top-level names. Nothing was " &
       "searched.")
  iFindNothingExamined(cmdName)
  result = false

proc iFindInRootName(toks: seq[string]; inTok: int; cmdName: string;
                     name: var string; nextTok: var int): bool =
  ## Collect the ROOT NAME that follows the `in` keyword.
  ##
  ## A quoted token (`in "Menu UI"`) arrives from `iSplit` as ONE token and is
  ## taken whole. An UNQUOTED run of bare words (`in Menu UI`) is JOINED into
  ## one name and said so -- the old code took `toks[inTok+1]` alone, so
  ## `in Menu UI` silently meant `in Menu`, which is the measured defect.
  ## The first token that is not a bare word ends the name and is the BUDGET.
  name = ""
  nextTok = inTok + 1
  if toks.len <= inTok + 1:
    iErr(cmdName & ": `in` must be followed by a root NAME (quote it if it " &
         "has spaces: " & cmdName & " NAME in \"Menu UI\"). Nothing was " &
         "searched.")
    iFindNothingExamined(cmdName)
    return false
  var i = inTok + 1
  # The first token is taken WHATEVER it looks like -- a quoted run may
  # legitimately contain digits or punctuation ("Tab 1").
  name = toks[i]
  inc i
  var joined = 1
  while i < toks.len and iTokIsWordy(toks[i]) and
        not iFindIsGrammarWord(toks[i]):
    name.add ' '
    name.add toks[i]
    inc i
    inc joined
  nextTok = i
  if joined > 1:
    iOut("  NOTE: the " & $joined & " bare words after `in` were joined into " &
         "one root name \"" & name & "\". Quote it (`in \"" & name &
         "\"`) to say so explicitly; the unquoted form used to be read as " &
         "just \"" & toks[inTok + 1] & "\".")
  result = true

proc iFindRefuseWordyRoot(toks: seq[string]; startTok: int;
                          cmdName: string): bool =
  ## MEASURED TWICE, by two different agents, on the same night:
  ## `findtext Interface language $settings 40000 all` takes ONE token as the
  ## needle, hands `language` to the root resolver, and answers
  ## `not an address: language` with 0 hits and no completeness line. A
  ## consumer that counts hits reads that as "nothing is wrong".
  ##
  ## So: a letters-only token in the ROOT slot REFUSES THE WHOLE COMMAND and
  ## says exactly what happened and exactly how to spell it instead. Returns
  ## true when it refused.
  if toks.len <= startTok:
    return false
  if not iTokIsWordy(toks[startTok]):
    return false
  if iFindIsGrammarWord(toks[startTok]):
    return false
  # Rebuild what the caller almost certainly meant: the needle plus the run of
  # bare words that followed it, quoted as one token.
  var quoted = (if toks.len > 1: toks[1] else: "")
  var i = startTok
  while i < toks.len and iTokIsWordy(toks[i]) and not iFindIsGrammarWord(toks[i]):
    quoted.add ' '
    quoted.add toks[i]
    inc i
  var rest = ""
  while i < toks.len:
    rest.add ' '
    rest.add toks[i]
    inc i
  if rest.len == 0:
    rest = " $settings 40000 all"
  iErr(cmdName & ": needle is ONE token; \"" & toks[startTok] &
       "\" was read as the ROOT and is not one. Quote a multi-word needle: " &
       cmdName & " \"" & quoted & "\"" & rest)
  iFindNothingExamined(cmdName)
  result = true

proc iFindResolveRoot(toks: seq[string]; startTok: int; cmdName: string;
                       root: var Il2CppPtr; rootExplicit: var bool;
                       budgetTok: var int): bool =
  ## Shared disambiguation for the `NAME [ROOT] [BUDGET]` grammar, shared by
  ## `find` and `findtext`, given the token index right after NAME (normally
  ## 2). A single bare token after NAME is AMBIGUOUS -- it used to always be
  ## read as ROOT, which made `find NAME 200000` (or `findtext NAME 300000`)
  ## silently walk the "root" that decimal reads as, visit one bogus node,
  ## and claim the name/text "genuinely NOT PRESENT" -- a confidently wrong
  ## answer. Disambiguate by READABILITY: only treat it as a root if it
  ## actually reads back as a live Transform/GameObject; otherwise it is a
  ## BUDGET, which is what a plain integer almost always means here.
  ## Returns false (having already `iErr`'d) if an eval failed.
  ##
  ## Checked FIRST, before any eval: a letters-only token in the ROOT slot is
  ## an unquoted multi-word needle, not a root (see `iFindRefuseWordyRoot`).
  if iFindRefuseWordyRoot(toks, startTok, cmdName):
    return false
  if toks.len == startTok + 1:
    var v = 0'u64
    var err = ""
    if not iEval(toks[startTok], v, err):
      iErr(err)
      return false
    let cand = cast[Il2CppPtr](v)
    if duOk(cand, 0x20'i32):
      if iRefuseIfGameObject(cand, cmdName):
        return false
      root = cand
      rootExplicit = true
      budgetTok = startTok + 1
      iOut("  NOTE: \"" & toks[startTok] & "\" reads as a live pointer, so " &
           "it is being treated as ROOT, not BUDGET. If you meant a " &
           "budget, pass an explicit root too: `" & cmdName & " ... $someRoot " &
           toks[startTok] & "`.")
    else:
      budgetTok = startTok
      iOut("  NOTE: \"" & toks[startTok] & "\" does not read back as a live " &
           "pointer, so it is being treated as BUDGET, not ROOT. Searching " &
           "every scene root (as if no root were given). If you meant a " &
           "root, pass a pointer that is actually live.")
  elif toks.len > startTok:
    var v = 0'u64
    var err = ""
    if not iEval(toks[startTok], v, err):
      iErr(err)
      return false
    root = cast[Il2CppPtr](v)
    if iRefuseIfGameObject(root, cmdName):
      return false
    rootExplicit = true
    budgetTok = startTok + 1
  result = true

proc iFindValidateRoot(root: var Il2CppPtr; rootExplicit: bool): bool =
  ## Shared: an explicit root MUST read back as a live Transform before any
  ## walk starts -- refused up front, the same way `tree` refuses one,
  ## instead of being walked and then reported as an exhaustive, confident
  ## miss.
  if rootExplicit:
    root = iToTransform(root)
    if not duOk(root, 0x20'i32):
      iErr("that root pointer is not readable as a Transform; refusing to " &
           "walk it. (The unconverted pointer read back readable, but " &
           "`Component::get_transform` on it did not -- something changed " &
           "underneath, or it was never a Transform/GameObject.)")
      return false
  result = true

proc iFindParseBudget(toks: seq[string]; budgetTok, defBudget,
                       maxBudget: int): int =
  ## Shared: an explicit budget token, clamped to the command's ceiling. The
  ## default and the ceiling are deliberately different constants per
  ## `InspFindDefBudget`'s comment -- a caller asking for more than the
  ## default must not be silently clamped back down to it.
  result = defBudget
  if toks.len > budgetTok:
    var b = 0'u64
    var e = ""
    if iEval(toks[budgetTok], b, e) and int(b) > 0:
      result = int(b)
  if result > maxBudget:
    result = maxBudget

proc iFindParseBudgetNoted(toks: seq[string]; budgetTok, defBudget,
                           maxBudget: int; cmdName: string): int =
  ## Same as `iFindParseBudget`, but SAYS SO when the requested budget was
  ## clamped -- a caller who asked for 150000 and got a silent 60000 has no
  ## way to know the ceiling exists, let alone what it is.
  var requested = -1
  if toks.len > budgetTok:
    var b = 0'u64
    var e = ""
    if iEval(toks[budgetTok], b, e) and int(b) > 0:
      requested = int(b)
  result = iFindParseBudget(toks, budgetTok, defBudget, maxBudget)
  if requested > maxBudget:
    iOut("  NOTE: requested budget " & $requested & " exceeds `" & cmdName &
         "`'s ceiling of " & $maxBudget & " nodes; clamped to " & $maxBudget &
         ". The real backstop is the " & $int(InspFindSliceMs) & "ms " &
         "per-frame time slice, not the node count -- raising this ceiling " &
         "is a deliberate code change, not a per-call override.")

proc iCmdFindText(toks: seq[string]) =
  ## `findtext SUBSTR [ROOT] [BUDGET] [all]` -- find controls by the TEXT
  ## THEY DISPLAY, not by GameObject name. Mirrors `find`'s resume/budget/
  ## report contract exactly (see iCmdFind); the differences are the
  ## per-node test, and that a hit is checked against `activeInHierarchy`
  ## and, by DEFAULT, an inactive hit is skipped rather than reported --
  ## matching the Nimony `aowl ui` driver's default and fact #72 (pressing a
  ## control on an inactive GameObject returns success and does nothing).
  ## Pass a trailing `all` to include inactive hits (same spelling family as
  ## `aowl ui`'s `--all`).
  if gTxtActive and gTxtOwnerIdx == gInspCurIdx and gTxtOwnerBatch == gInspBatch:
    inc gTxtFrames
    let st = iFindTextStep()
    if st == FindOutOfTime and gTxtBudgetLeft > 0 and
       gTxtFrames < InspFindMaxFrames:
      gFindSuspend = true
      return
    iFindTextReport(iFindStopReason(st, gTxtBudgetLeft, gTxtFrames))
    return

  if toks.len < 2:
    iErr("usage: findtext SUBSTR [ROOT] [BUDGET] [all] | findtext SUBSTR " &
         "in ROOTNAME [BUDGET] [all] | findtext more [BUDGET]")
    return

  if iLower(toks[1]) == "more":
    if not gTxtActive:
      iErr("there is no capped text search to continue. Run `findtext " &
           "SUBSTR ...` first.")
      return
    var budget = InspTextFindDefBudget
    if toks.len > 2:
      var b = 0'u64
      var e = ""
      if iEval(toks[2], b, e) and int(b) > 0:
        budget = int(b)
    if budget > InspTextFindMaxBudget:
      budget = InspTextFindMaxBudget
    if not iInspSeedTextType():
      iErr("could not resolve a System.Type for TMPro.TextMeshProUGUI, so " &
           "the predicate has nothing to match with and NOTHING WAS " &
           "SEARCHED (this is not a miss): " & gTxtSeedWhy)
      return
    iOut("  resuming text search for \"" & gTxtWant & "\" from a frontier of " &
         $(gTxtQueue.len - gTxtHead) & " node(s), budget " & $budget)
    gTxtBudgetLeft = budget
    gTxtOwnerIdx = gInspCurIdx
    gTxtOwnerBatch = gInspBatch
    gTxtFrames = 1
    let st = iFindTextStep()
    if st == FindOutOfTime and gTxtBudgetLeft > 0 and
       gTxtFrames < InspFindMaxFrames:
      gFindSuspend = true
      return
    iFindTextReport(iFindStopReason(st, gTxtBudgetLeft, gTxtFrames))
    return

  if not iInspSeedTextType():
    iErr("could not resolve a System.Type for TMPro.TextMeshProUGUI, so the " &
         "predicate has nothing to match with and NOTHING WAS SEARCHED " &
         "(this is not a miss): " & gTxtSeedWhy)
    return

  # `all` is a trailing keyword, stripped before ROOT/BUDGET parsing so it
  # cannot be misread as either -- `findtext SUBSTR ROOT BUDGET all` and
  # `findtext SUBSTR all` both work. Same spelling family as `aowl ui`'s
  # `--all`, which is what the Nimony UI driver uses for the identical
  # opt-in.
  var ftoks = toks
  let includeInactive = ftoks.len > 2 and iLower(ftoks[^1]) == "all"
  if includeInactive:
    ftoks.setLen(ftoks.len - 1)

  # AN EMPTY NEEDLE IS A REFUSAL, NOT A SEARCH.
  #
  # `findtext "" $settings 40000` used to drop the empty token during
  # splitting and SHIFT the arguments left: `$settings` became the needle,
  # `40000` became the root, and the report described a search nobody asked
  # for. An empty substring also matches every string trivially, so there is
  # no reading of it that produces a useful answer.
  if ftoks[1].len == 0:
    iErr("findtext REFUSED: the needle is empty. An empty substring matches " &
         "every label, and an empty token shifts ROOT/BUDGET one place left " &
         "-- so this is a typo, not a query. Nothing was searched.")
    return

  let want = ftoks[1]
  var root: Il2CppPtr = nil
  var rootExplicit = false
  var budgetTok = 3
  if ftoks.len > 2 and iLower(ftoks[2]) == "in":
    # `findtext SUBSTR in ROOTNAME [BUDGET] [all]`. `findtext` did NOT accept
    # `in` at all before: the keyword fell through to the pointer parser and
    # came back "not an address: in", so the one spelling that works for
    # `find` was a parse error here.
    var rootName = ""
    var afterName = 0
    if not iFindInRootName(ftoks, 2, "findtext", rootName, afterName):
      return
    if not iFindRootByName(rootName, "findtext", root):
      return
    rootExplicit = true
    budgetTok = afterName
  elif not iFindResolveRoot(ftoks, 2, "findtext", root, rootExplicit,
                            budgetTok):
    return
  if not iFindValidateRoot(root, rootExplicit):
    return
  let budget = iFindParseBudgetNoted(ftoks, budgetTok, InspTextFindDefBudget,
                                      InspTextFindMaxBudget, "findtext")

  gTxtQueue = @[]
  var seededRoots = 0
  if rootExplicit:
    gTxtQueue.add root
  else:
    seededRoots = iSceneRoots(gTxtQueue, false)
    if seededRoots == 0:
      if gInspPreloader == nil:
        iErr("scene-root enumeration is unavailable and $preloader is null, " &
             "so there is nothing to search from. Pass a root explicitly.")
        return
      iOut("  NOTE: scene-root enumeration did not work, so this searches " &
           "only the tree $preloader belongs to. A miss here is NOT proof " &
           "the text is absent from the game.")
      gTxtQueue.add iHierRoot(iToTransform(gInspPreloader))
  gTxtHead = 0
  gTxtWant = iLower(want)
  gTxtVisited = 0
  gTxtInvalidSkips = 0
  gTxtActiveOnly = not includeInactive
  gTxtInactiveSkipped = 0
  gTxtActiveUnknown = 0
  gTxtActiveNote = ""
  # The positive control is per SEARCH, not per frame -- a resumed search
  # keeps counting, so `findtext more` cannot inherit a stale "the predicate
  # works" from a previous needle.
  gTxtTmpSeen = 0
  gTxtTmpNull = 0
  gTxtTmpKlass = 0'u64
  gTxtKlassNote = ""
  gTxtFound = 0
  gTxtActive = false
  gTxtBudgetLeft = budget
  gTxtOwnerIdx = gInspCurIdx
  gTxtOwnerBatch = gInspBatch
  gTxtFrames = 1
  iOut("  searching " &
       (if rootExplicit: "from " & iPtr(root) & " name=\"" & iObjName(root) & "\""
        else: "ALL " & $seededRoots & " scene root(s)") &
       " for TMP text containing \"" & want & "\" (case-insensitive; budget " &
       $budget & " nodes, " & $int(InspFindSliceMs) & "ms per frame, " &
       "continuing across frames automatically; scope: " &
       (if gTxtActiveOnly: "ACTIVE nodes only -- pass `all` to include inactive"
        else: "ALL nodes, active and inactive") & ")")
  let st = iFindTextStep()
  if st == FindOutOfTime and gTxtBudgetLeft > 0 and
     gTxtFrames < InspFindMaxFrames:
    gTxtActive = true
    gFindSuspend = true
    return
  iFindTextReport(iFindStopReason(st, gTxtBudgetLeft, gTxtFrames))

proc iCmdFind(toks: seq[string]) =
  ## `find NAME [ROOT] [BUDGET]`
  ## `find NAME in ROOTNAME [BUDGET]`   -- ROOT resolved by name
  ## `find more [BUDGET]`               -- RESUME a search that hit a cap
  ##
  ## Matching is case-insensitive substring on the GameObject name.
  ##
  ## KNOWN GAP, DELIBERATELY LEFT: `find` has the same active/inactive blind
  ## spot `findtext` had (a hit may sit on an inactive node and be
  ## unpressable, fact #72) and does NOT report `activeInHierarchy` or
  ## filter by it. Left unchanged here because `find` is used for MORE than
  ## locating pressable controls (e.g. confirming a name exists anywhere,
  ## active or not) and a default flip is a bigger behavior change than this
  ## pass should make silently -- flagging it rather than changing it.
  # ---- AUTOMATIC CONTINUATION ----
  # This same command index already owns a search that ran out of FRAME time.
  # Resume it rather than restarting: re-running from the root would re-walk
  # everything already rejected and could never make progress past the slice.
  if gFindActive and gFindOwnerIdx == gInspCurIdx and
     gFindOwnerBatch == gInspBatch:
    inc gFindFrames
    let st = iFindStep()
    if st == FindOutOfTime and gFindBudgetLeft > 0 and
       gFindFrames < InspFindMaxFrames:
      gFindSuspend = true
      return
    iFindReport(iFindStopReason(st, gFindBudgetLeft, gFindFrames))
    return

  if toks.len < 2:
    iErr("usage: find NAME [ROOT] [BUDGET] | find NAME in ROOTNAME [BUDGET] | find more [BUDGET]")
    return

  # ---- resume ----
  if iLower(toks[1]) == "more":
    if not gFindActive:
      iErr("there is no capped search to continue. Run `find NAME ...` first.")
      return
    var budget = InspFindDefBudget
    if toks.len > 2:
      var b = 0'u64
      var e = ""
      if iEval(toks[2], b, e) and int(b) > 0:
        budget = int(b)
    if budget > InspFindMaxBudget:
      budget = InspFindMaxBudget
    iOut("  resuming search for \"" & gFindWant & "\" from a frontier of " &
         $(gFindQueue.len - gFindHead) & " node(s), budget " & $budget)
    gFindBudgetLeft = budget
    gFindOwnerIdx = gInspCurIdx
    gFindOwnerBatch = gInspBatch
    gFindFrames = 1
    let st = iFindStep()
    if st == FindOutOfTime and gFindBudgetLeft > 0 and
       gFindFrames < InspFindMaxFrames:
      gFindSuspend = true
      return
    iFindReport(iFindStopReason(st, gFindBudgetLeft, gFindFrames))
    return

  # ---- new search ----
  let want = toks[1]
  var root: Il2CppPtr = nil
  var rootExplicit = false
  var budgetTok = 3

  if toks.len > 2 and iLower(toks[2]) == "in":
    # `find X in Y` -- Y is a NAME. EXACT match, scene roots first, and a
    # substring-only match REFUSES (see iFindRootByName).
    var rootName = ""
    var afterName = 0
    if not iFindInRootName(toks, 2, "find", rootName, afterName):
      return
    if not iFindRootByName(rootName, "find", root):
      return
    rootExplicit = true
    budgetTok = afterName
  else:
    # `find NAME [ROOT] [BUDGET]` -- shared with `findtext`'s identical
    # grammar (see `iFindResolveRoot`/`iFindValidateRoot`).
    if not iFindResolveRoot(toks, 2, "find", root, rootExplicit, budgetTok):
      return

  if not iFindValidateRoot(root, rootExplicit):
    return

  let budget = iFindParseBudgetNoted(toks, budgetTok, InspFindDefBudget,
                                      InspFindMaxBudget, "find")

  gFindQueue = @[]
  var seededRoots = 0
  if rootExplicit:
    gFindQueue.add root
  else:
    # NO ROOT NAMED -> SEARCH EVERY SCENE ROOT.
    #
    # The old default was `$preloader` climbed to its hierarchy root, which
    # could only ever reach the one tree the host already had a pointer into.
    # In the menu that is the Preloader UI, and the screens actually worth
    # driving live under a different scene root -- so the default was
    # structurally incapable of finding them, and said "not present" about
    # things that were merely unreachable. Seeding from every scene root is
    # what makes a bare `find NAME` mean what a person expects.
    seededRoots = iSceneRoots(gFindQueue, false)
    if seededRoots == 0:
      # Fall back rather than fail: if scene enumeration did not verify on
      # this build, the old reachable-subtree search is still better than
      # nothing -- but say so, so a narrow result is not mistaken for a
      # complete one.
      if gInspPreloader == nil:
        iErr("scene-root enumeration is unavailable and $preloader is null, " &
             "so there is nothing to search from. Pass a root explicitly.")
        return
      iOut("  NOTE: scene-root enumeration did not work, so this searches " &
           "only the tree $preloader belongs to. A miss here is NOT proof " &
           "the name is absent from the game.")
      gFindQueue.add iHierRoot(iToTransform(gInspPreloader))
  gFindHead = 0
  gFindWant = iLower(want)
  gFindVisited = 0
  gFindInvalidSkips = 0
  gFindFound = 0
  gFindActive = false
  gFindBudgetLeft = budget
  gFindOwnerIdx = gInspCurIdx
  gFindOwnerBatch = gInspBatch
  gFindFrames = 1
  iOut("  searching " &
       (if rootExplicit: "from " & iPtr(root) & " name=\"" & iObjName(root) & "\""
        else: "ALL " & $seededRoots & " scene root(s)") &
       " for name containing \"" & want & "\" (case-insensitive; budget " &
       $budget & " nodes, " & $int(InspFindSliceMs) & "ms per frame, " &
       "continuing across frames automatically)")
  let st = iFindStep()
  if st == FindOutOfTime and gFindBudgetLeft > 0 and
     gFindFrames < InspFindMaxFrames:
    # Out of frame time but not out of permission: park and carry on next
    # frame. Silent by design -- a progress line every frame would bury the
    # matches this is supposed to surface.
    gFindActive = true
    gFindSuspend = true
    return
  iFindReport(iFindStopReason(st, gFindBudgetLeft, gFindFrames))

proc iCmdTree(toks: seq[string]) =
  ## `tree EXPR [DEPTH]` -- the subtree, indented, capped.
  ##
  ## "Show me what is under this" is the most common UI question and was the
  ## one thing traversal still could not answer: `children` gives exactly one
  ## level, and `find` needs a name you may not know yet. This is how you learn
  ## the name.
  if toks.len < 2:
    iErr("usage: tree EXPR [DEPTH]")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  var root = cast[Il2CppPtr](v)
  if not duOk(root, 0x20'i32):
    iErr("that pointer is not readable; refusing to walk it.")
    return
  if iRefuseIfGameObject(root, "tree"):
    return
  root = iToTransform(root)
  if not iUnityAlive(root):
    iErr("that object's native half is NULL, so every child accessor would " &
         "fault inside Unity's C++. Refusing to walk it.")
    return
  var depth = 4
  if toks.len > 2:
    var d = 0'u64
    var e = ""
    if iEval(toks[2], d, e) and int(d) > 0:
      depth = int(d)
  if depth > InspTreeMaxDepth:
    depth = InspTreeMaxDepth
  iOut("  tree from " & iPtr(root) & " name=\"" & iObjName(root) &
       "\" (max depth " & $depth & ", max " & $InspTreeMaxNodes & " nodes)")
  # Explicit stacks rather than recursion: recursion depth on the Unity thread
  # is not something to leave to chance inside a detour.
  var stackNode: seq[Il2CppPtr] = @[]
  var stackDepth: seq[int] = @[]
  stackNode.add root
  stackDepth.add 0
  var nodes = 0
  var truncated = false
  let started = cNowMs()
  while stackNode.len > 0:
    if nodes >= InspTreeMaxNodes:
      truncated = true
      break
    if (nodes and 127) == 0 and cNowMs() - started > InspFindSliceMs * 2'u64:
      truncated = true
      break
    let cur = stackNode[stackNode.len - 1]
    let d = stackDepth[stackDepth.len - 1]
    stackNode.setLen(stackNode.len - 1)
    stackDepth.setLen(stackDepth.len - 1)
    inc nodes
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
      continue
    var indent = "    "
    for k in 0 ..< d:
      indent = indent & "  "
    iNoteKlass(cur)
    var n = 0
    let okCount = iChildCount(cur, n)
    iOut(indent & (if d == 0: "" else: "+ ") & "\"" & iObjName(cur) & "\"  " &
         iPtr(cur) & (if okCount and n > 0: "  (" & $n & " child)" else: ""))
    if d >= depth or not okCount:
      continue
    # Push in reverse so children print in natural order.
    var k = n - 1
    if k > InspMaxChildren - 1:
      k = InspMaxChildren - 1
    while k >= 0:
      let c = iChildAt(cur, k)
      if c != nil:
        stackNode.add c
        stackDepth.add (d + 1)
      dec k
  iOut("  " & $nodes & " node(s) printed" &
       (if truncated:
          "  -- STOPPED EARLY on a cap; this subtree is larger than the " &
          "budget. Deepen selectively with `tree $child` rather than raising " &
          "the depth here."
        else: "  -- complete."))

proc iCompChildHint(typeName: string): string =
  ## The measured "it is on a CHILD" note, shared by both NULL branches of
  ## `component` so the two cannot say different things.
  result = " The control is very often on a CHILD of the node asked about: " &
    "`children EXPR 3`, then `component $gN " & typeName & "` on the child " &
    "that carries it."
  if iContains(iLower(typeName), "animatedtoggle"):
    result = result & " MEASURED 2026-09-02: a ControlToggle(Clone) carries " &
      "NO AnimatedToggle itself -- it is on its CHILD named " &
      "\"AnimatedToggle\", which is exactly what `children $cN 3` binds as " &
      "$gN."

proc iCmdComponentBody(toks: seq[string]): bool =
  ## `component EXPR TypeName [more...]` -- resolve a component on a
  ## GameObject or Transform.
  ##
  ## THIS IS THE MISSING LINK. `children` and `find` return TRANSFORMS, and a
  ## Transform is not a Button -- reading Button offsets off one produced a
  ## klass pointer that was reported as `m_OnClick`. Everything that acts on a
  ## control needs the COMPONENT, and this is the only way to get from one to
  ## the other.
  # CLEAR `$comp` FIRST -- above the usage check, above everything that can
  # fail. `result` defaults to false, so every bare `return` below is "did NOT
  # bind" and only the two FOUND paths say `return true`; the wrapper turns
  # that false into an out-loud UNBOUND line. An unbind nobody announces is
  # the same defect one step later.
  #
  # PRE-EXISTING BUILD BREAK, fixed here on 2026-09-02 and NOT part of the
  # change this commit is about. The comment above says "`result` defaults to
  # false", and nimony no longer accepts that as a proof: it rejected all nine
  # bare `return`s in this body with "cannot prove that result has been
  # initialized". MEASURED: `python tools/buildlock.py build host` fails with
  # exactly these nine errors on this branch with EVERY unrelated change
  # stashed, so the branch as committed does not compile. Writing the default
  # the comment already claimed is the whole fix and changes no behaviour.
  result = false
  iSetVar("comp", 0'u64)
  if toks.len < 3:
    iErr("usage: component EXPR TypeName   (e.g. component $g0 Button)")
    return
  # WHY IT IS CLEARED FIRST.
  #
  # It used to keep its previous value when a lookup failed, and that is the
  # single most dangerous thing this instrument has done. A batch reading
  #
  #     component <node> Button      -> NULL, "this is an ANSWER, not a crash"
  #     click $comp                  -> pressed the PREVIOUS batch's component
  #
  # does not look wrong. It looks like an answer followed by an action, and the
  # action reports a full Button field readout -- interactable, m_OnClick -- of
  # an object that is not a Button and was never asked for. That was observed
  # THREE times in one session: twice pressing a TMP_Text left over from an
  # earlier batch, and once printing a complete, entirely fictional field map
  # of a Button that does not exist. Every one of those readouts was plausible.
  #
  # So a failed lookup now leaves `$comp` UNBOUND, and every consumer of an
  # unbound anchor refuses. The rule is that a stale answer must never be
  # reachable through a name whose lookup just failed.
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  var target = cast[Il2CppPtr](v)
  if not duOk(target, 0x20'i32) or not iUnityAlive(target):
    iErr("not readable, or its native half is null; refusing to call.")
    return
  # THE STRING ROUTE. No Il2CppClass, no System.Type, no MethodInfo, no
  # reflection -- only `il2cpp_string_new`, which the version brand already
  # proves works on the Unity thread. A Transform IS a Component, so this
  # takes exactly what `children` hands back.
  # PICK THE OVERLOAD FROM THE KLASS, AND SPEND NO FAULT ON THE CHOICE.
  #
  # `Component::GetComponent` and `GameObject::GetComponent` are different
  # functions over different native types, and both classes carry
  # `m_CachedPtr` at +0x10 -- so handing a GameObject to the Component
  # overload passes `duOk`, passes `iUnityAlive`, and then faults inside
  # Unity's C++ reading a native GameObject through a native Component
  # layout. That was the shape of this command until now: it always called
  # the Component overload, whatever it was given.
  #
  # `gGoKlass` is learned only from sources that return a GameObject BY
  # CONTRACT, so this is a fact about the pointer, not a guess, and it is a
  # klass compare -- it costs nothing and cannot fault.
  # THE TYPE ROUTE FIRST, AND WHY THE OLD OVERLOAD CHOICE WAS THE FAULT.
  #
  # MEASURED offline (`typemethods UnityEngine.GameObject`): this build's
  # GameObject declares NO `GetComponent(string)` -- only `GetComponent(Type)`
  # @0x52A8510. This command used to pick that RVA for a GameObject receiver,
  # believing it to be the string overload, and hand it an `Il2CppString*`.
  # That is a managed type confusion inside Unity's own code and it is what
  # faulted `component <GameObject> TextMeshProUGUI` 5/5 tonight -- five of
  # the session's eight faults, spent on a mislabelled table entry.
  #
  # So: if the name resolves to a real Il2CppType in the offline index, the
  # TYPE overload is used, which matches by klass identity and works on both
  # receivers. Only if it does not (a short name like `Button`) do we fall
  # back to the STRING overload -- and that one exists ONLY on Component, so
  # a GameObject receiver is converted to its Transform first rather than
  # being handed to a function that does not take a string.
  var wantType = toks[2]
  var typeWhy = ""
  let tobj = iTypeObjectFor(wantType, typeWhy)
  if tobj != nil:
    var why = ""
    let c = iGetComponentOfType(target, tobj, why)
    if c == nil:
      iErr("via GetComponent(Type) on " & iPtr(target) & ": " & why &
           ". (This is the klass-identity route: the offline index resolved " &
           toks[2] & " to a real Il2CppType, so a NULL here is an ANSWER " &
           "about this object, not a name-matching failure.)" &
           iCompChildHint(toks[2]))
      return
    iSetVar("comp", cast[uint64](c))
    iOut("  FOUND " & toks[2] & " component = " & iPtr(c) &
         "  klass=" & iPtrU(iKlassOf(c)) & "   ($comp)   " &
         "via GetComponent(System.Type) -- klass identity, no string match")
    iOut("  bound to $comp -- e.g.  allow write   then   click $comp")
    return true
  iOut("  \"" & toks[2] & "\" did not resolve as a fully-qualified type in " &
       "the offline index (" & typeWhy & "), so the STRING overload is used " &
       "instead. Prefer the fully-qualified name (e.g. " &
       "TMPro.TextMeshProUGUI, UnityEngine.UI.Button): that route matches by " &
       "klass identity rather than by Unity's short-name lookup.")
  # The string overload is a Component method and nothing else on this build.
  var strTarget = target
  if iIsGameObject(target):
    let t = iTransformOfGameObject(target)
    if t == nil:
      iErr("this is a GameObject and there is no string GetComponent on " &
           "GameObject in this build, so its Transform is needed as the " &
           "receiver -- and GameObject::get_transform did not return one. " &
           "Nothing was called and no fault was spent.")
      return
    strTarget = t
    iOut("  target is a GameObject; the string overload exists only on " &
         "Component, so its Transform " & iPtr(t) & " is the receiver.")
  let overload = "Component::GetComponent(String)"
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind(overload, fn, rva):
    return
  # The wrapper's failure branch RAISES a missing-method exception, and a
  # managed throw from inside our own call on the Unity thread is not something
  # to discover empirically. Ask first, off the hot path.
  if cNavIcallReady() == 0'i32:
    iErr("the icall \"UnityEngine.Component::GetComponent(System.String)\" is " &
         "NOT registered in this runtime, so calling the wrapper would take " &
         "its failure branch and RAISE a missing-method exception inside the " &
         "detour. Nothing was called.")
    return
  # `toCString` takes a mutable string, so the type name goes through a local.
  var typeName = toks[2]
  let sp = cNavNewString(toCString(typeName))
  if sp == nil:
    iErr("il2cpp_string_new returned null for \"" & toks[2] &
         "\"; nothing was called.")
    return
  iOut("  via UnityEngine." & overload & " @0x" &
       iHexPad(uint64(rva), 6) & " (call) on " & iPtr(strTarget) &
       "   type string = " & iPtr(sp))
  iMark(overload, strTarget)
  let comp = cast[Il2CppPtr](cInspUPP(fn, strTarget, sp, nil))
  if comp == nil:
    iErr("GetComponent returned NULL -- this is an ANSWER, not a crash. " &
         "Either this object genuinely has no " & toks[2] & " (it may be a " &
         "container, with the control on a child), or Unity's SHORT-NAME " &
         "match did " &
         "not accept \"" & toks[2] & "\". Unity matches this overload by " &
         "short type name; if you suspect the latter, try the fully-qualified " &
         "name, e.g. UnityEngine.UI.Button." & iCompChildHint(toks[2]))
    return
  iNoteKlass(comp)
  iSetVar("comp", cast[uint64](comp))
  iOut("  FOUND " & toks[2] & " component = " & iPtr(comp) &
       "  klass=" & iPtrU(iKlassOf(comp)) & "   ($comp)")
  iOut("  bound to $comp -- e.g.  allow write   then   click $comp")
  return true

proc iCmdComponent(toks: seq[string]) =
  ## THE UNBIND IS ANNOUNCED. `iCmdComponentBody` unbinds `$comp` before it can
  ## fail and reports whether it re-bound it; a failure that only clears the
  ## anchor silently is indistinguishable, in the out-file, from one that left
  ## the previous batch's pointer in place -- and the next line in a batch is
  ## usually the one that calls into game code.
  if not iCmdComponentBody(toks):
    iOut("  $comp is UNBOUND -- this lookup did not produce a component, so " &
         "the previous binding (if any) was DISCARDED rather than left to be " &
         "clicked or called. Any call/click/invoke/press on $comp below this " &
         "line will REFUSE, not fault.")


proc iGetComponentQuiet(target: Il2CppPtr; typeName: string;
                        why: var string): Il2CppPtr =
  ## `GetComponent(String)` with no narration -- the same overload choice and
  ## the same pre-flight as `iCmdComponent`, for verbs that need a component
  ## as a STEP rather than as an answer. `why` is set on every failure path,
  ## because a silent nil here would be indistinguishable from "the object has
  ## no such component", and those are different facts.
  result = nil
  why = ""
  if not duOk(target, 0x20'i32) or not iUnityAlive(target):
    why = "the object is not readable, or its native half is null"
    return
  # The STRING overload exists ONLY on UnityEngine.Component in this build
  # (MEASURED: `typemethods UnityEngine.GameObject` lists GetComponent(Type)
  # and no string form). Handing a GameObject to the RVA that was mislabelled
  # "GameObject::GetComponent(String)" passed a String where a System.Type was
  # expected, and faulted. So a GameObject receiver is converted to its
  # Transform, which IS a Component, rather than being passed through.
  var recv = target
  if iIsGameObject(target):
    let t = iTransformOfGameObject(target)
    if t == nil:
      why = "this is a GameObject, the string GetComponent overload does not " &
            "exist on GameObject in this build, and get_transform gave no " &
            "Component receiver -- so nothing could be asked"
      return
    recv = t
  let overload = "Component::GetComponent(String)"
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind(overload, fn, rva):
    why = overload & " did not byte-verify on this build"
    return
  if cNavIcallReady() == 0'i32:
    why = "the GetComponent(System.String) icall is not registered in this " &
          "runtime, so the wrapper would take its raise branch"
    return
  var tn = typeName
  let sp = cNavNewString(toCString(tn))
  if sp == nil:
    why = "il2cpp_string_new returned null for \"" & typeName & "\""
    return
  iMark(overload, recv)
  let comp = cast[Il2CppPtr](cInspUPP(fn, recv, sp, nil))
  if comp == nil:
    why = "GetComponent(\"" & typeName & "\") returned NULL -- an ANSWER: " &
          "this object has no such component"
    return
  iNoteKlass(comp)
  result = comp

proc iCmdComponents(toks: seq[string]) =
  ## `components EXPR [BaseType]` -- LIST what an object actually has, instead
  ## of interrogating it one type name at a time.
  ##
  ## `component EXPR Type` is a yes/no oracle that charges for wrong guesses:
  ## a wrong-but-safe name is free, a wrong-and-unlucky one spends one of the
  ## eight faults that end the session. Naming a control nobody can already
  ## name therefore costs a session, and it has.
  ##
  ## THE ROUTE, which uses no reflection at all:
  ##   `Ns.Type::@type/0` in the offline index -> static `Il2CppType*`
  ##   -> `System.Type::GetTypeFromHandle` (a one-field struct, so a plain
  ##      pointer in RCX)
  ##   -> `GameObject::GetComponents(Type)` -> `Component[]`
  ##   -> each element's klass -> a raw name read, VALIDATED against the same
  ##      offline table.
  ##
  ## The default base type is `UnityEngine.Component`, which is every
  ## component of any kind. `UnityEngine.MonoBehaviour` narrows it to scripts.
  if toks.len < 2:
    iErr("usage: components EXPR [BaseType]   (default base " &
         "UnityEngine.Component; use UnityEngine.MonoBehaviour for scripts " &
         "only). Names must be FULLY QUALIFIED here -- this is an index " &
         "lookup, not Unity's short-name match.")
    return
  for i in 0 ..< 16:
    iSetVar("k" & $i, 0'u64)
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  var target = cast[Il2CppPtr](v)
  if not duOk(target, 0x20'i32) or not iUnityAlive(target):
    iErr("not readable, or its native half is null; refusing to call. " &
         "Nothing was called and no fault was spent.")
    return

  # `GetComponents` is a GameObject method. A Transform is not a GameObject,
  # and calling it on one would be the same native type confusion that makes
  # `component` fault -- so convert, rather than hope.
  var go = target
  if not iIsGameObject(target):
    let g = iGameObjectOf(target)
    if g == nil:
      iErr("this is not a known GameObject and Component::get_gameObject " &
           "did not return one, so there is nothing to enumerate. " &
           "GetComponents was NOT called.")
      return
    go = g
    iOut("  target is a Component/Transform; enumerating its GameObject " &
         iPtr(go) & " instead.")

  if cNameIdxReady() == 0'i32:
    iErr("the offline name index is not loaded, so neither the base type's " &
         "Il2CppType address nor the type-name validation is available. " &
         "Nothing was called. Reason: " & readCString(cNameIdxReason()))
    return

  var baseName = (if toks.len >= 3: toks[2] else: "UnityEngine.Component")
  var bn = baseName
  let typeRva = cCompTypeRva(toCString(bn))
  if typeRva == 0'u32:
    iErr("\"" & baseName & "\" has no `::@type` entry in the offline index. " &
         "Either it is not a type on this build, or its name maps to two " &
         "different Il2CppType descriptors and was DROPPED rather than " &
         "guessed at. Nothing was called. Check offline with:  python " &
         "tools/il2cpp_nameindex.py type <idx> " & baseName)
    return
  let typeDesc = cCompDataAt(uint64(typeRva))
  if typeDesc == nil or not duOk(typeDesc, 16'i32):
    iErr("the index gave Il2CppType RVA 0x" & iHexPad(uint64(typeRva), 6) &
         " for " & baseName & " but that address is not readable in this " &
         "process. Nothing was called. (Note this resolves as DATA, not " &
         "code -- a static Il2CppType lives in .data.)")
    return

  var fnHandle: Il2CppPtr = nil
  var rvaHandle = 0'u32
  if not iNavFind("Type::GetTypeFromHandle", fnHandle, rvaHandle):
    return
  var fnGet: Il2CppPtr = nil
  var rvaGet = 0'u32
  if not iNavFind("GameObject::GetComponents(Type)", fnGet, rvaGet):
    return

  iOut("  base " & baseName & "  Il2CppType @0x" &
       iHexPad(uint64(typeRva), 6) & " = " & iPtr(typeDesc) &
       "   (offline index, round-tripped at generation)")
  iMark("System.Type::GetTypeFromHandle", typeDesc)
  let tobj = cast[Il2CppPtr](cInspUP(fnHandle, typeDesc, nil))
  if tobj == nil or not duOk(tobj, 0x20'i32):
    iErr("GetTypeFromHandle returned " & iPtr(tobj) & ", which is not a " &
         "usable System.Type. GetComponents was NOT called.")
    return

  iMark("GameObject::GetComponents(Type)", go)
  let arr = cast[Il2CppPtr](cInspUPP(fnGet, go, tobj, nil))
  if arr == nil:
    iErr("GetComponents returned NULL -- this is an ANSWER, not a crash: " &
         "the object has no component deriving from " & baseName & ".")
    return
  if not duOk(arr, cNavOffArrData() + 8'i32):
    iErr("GetComponents returned " & iPtr(arr) & " but that is not a " &
         "readable array header; nothing was dereferenced.")
    return
  var n = int(cast[uint64](cReadPtrAt(arr, cNavOffArrLen())) and 0xFFFFFFFF'u64)
  let capped = n > int(cCompMax())
  if n < 0: n = 0
  if capped:
    n = int(cCompMax())
  iOut("  " & (if capped: "MORE THAN " else: "") & $n &
       " component(s) on " & iPtr(go) &
       (if capped: "  -- capped at " & $cCompMax() & "; the rest are not listed"
        else: ""))

  var unver = 0
  for i in 0 ..< n:
    let slot = cNavOffArrData() + int32(i * 8)
    if not duOk(arr, slot + 8'i32):
      iErr("element " & $i & ": the array slot is not readable; stopping here.")
      break
    let c = cReadPtrAt(arr, slot)
    if c == nil:
      iOut("    [" & $i & "] NULL")
      continue
    let k = iKlassOf(c)
    var verified = false
    let nm = iKlassName(k, verified)
    if i < 16:
      iSetVarP("k" & $i, c)
    iNoteKlass(c)
    if verified:
      iOut("    [" & $i & "] " & nm & "   " & iPtr(c) &
           "  klass=" & iPtrU(k) & (if i < 16: "   ($k" & $i & ")" else: ""))
    else:
      inc unver
      iOut("    [" & $i & "] UNVERIFIED name " &
           (if nm.len == 0: "(unreadable)" else: "\"" & nm & "\"") &
           " -- NOT a type in this build's metadata, so it is NOT reported " &
           "as a type name. " & iPtr(c) & "  klass=" & iPtrU(k) &
           (if i < 16: "   ($k" & $i & ")" else: ""))
  if unver > 0 and unver == n:
    iErr("EVERY name failed validation. That is the signature of the " &
         "Il2CppClass.name offset (0x" & iHexPad(uint64(cCompOffName()), 2) &
         ", the one INFERRED offset in this path) being wrong for this " &
         "build -- not of the components being exotic. The pointers above " &
         "are still real components and still usable; only the names are " &
         "withheld.")
  elif unver > 0:
    iOut("  " & $unver & " name(s) did not validate; those lines say so " &
         "individually. A mix means those specific klasses, not the offset.")
  if n > 0:
    var last = n - 1
    if last > 15: last = 15
    iOut("  bound to $k0" & (if last > 0: "..$k" & $last else: "") &
         " -- feed straight into  label $k0 / click $k0 / call $k0 ...")

proc iRectVec2Getter(p: Il2CppPtr; pattern, label: string) =
  ## Shared body for `rect`'s five Vector2-by-value getters (packed 8 bytes
  ## IN RAX -- see the note above `cDuCallUP2`). A top-level proc, not nested,
  ## so it does not depend on nimony closure support this file has no other
  ## precedent for.
  var idx = 0
  var hits = 0
  if not iFindTarget(pattern, idx, hits):
    iOut("  " & label & ": target \"" & pattern & "\" not resolvable " &
         "(missing or ambiguous in the verified-target table -- see `targets`)")
    return
  let fn = iTargetFn(idx)
  if fn == nil:
    iOut("  " & label & ": prologue verify FAILED for @0x" &
         iHexPad(iTargetRva(idx), 6) & " -- refusing to call")
    return
  iMark(pattern, p)
  let packed = cDuCallUP2(fn, p)
  let x = cDuVec2X2(packed)
  let y = cDuVec2Y2(packed)
  iOut("  " & label & " = (" & iFmtF(x) & ", " & iFmtF(y) & ")   via @0x" &
       iHexPad(iTargetRva(idx), 6))

proc iCmdRect(toks: seq[string]) =
  ## `rect EXPR` -- RectTransform geometry, from targets already byte-verified
  ## for the overlay. Useful for confirming that something actually happened:
  ## a selected tile usually changes size or position, and that is a field
  ## read rather than a screenshot.
  if toks.len < 2:
    iErr("usage: rect EXPR")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  let p = cast[Il2CppPtr](v)
  if not duOk(p, 0x20'i32) or not iUnityAlive(p):
    iErr("not readable, or its native half is null; refusing to call.")
    return
  iOut("  klass = " & iPtrU(iKlassOf(p)) &
       "   (a Transform that is NOT a RectTransform has no rect -- the " &
       "outermost menu roots are plain Transforms)")

  # Vector2-by-value getters: packed 8 bytes IN RAX (measured, see the note
  # above cDuCallUP2).
  iRectVec2Getter(p, "RectTransform::get_anchoredPosition", "anchoredPosition")
  iRectVec2Getter(p, "RectTransform::get_sizeDelta",         "sizeDelta       ")
  iRectVec2Getter(p, "RectTransform::get_anchorMin",         "anchorMin       ")
  iRectVec2Getter(p, "RectTransform::get_anchorMax",         "anchorMax       ")
  iRectVec2Getter(p, "RectTransform::get_pivot",             "pivot           ")

  # Rect-by-value: 16 bytes, bigger than 8 -> hidden-buffer (sret) return.
  block rectBlock:
    var idx = 0
    var hits = 0
    if not iFindTarget("RectTransform::get_rect", idx, hits):
      iOut("  rect (x,y,w,h): target not resolvable")
      break rectBlock
    let fn = iTargetFn(idx)
    if fn == nil:
      iOut("  rect (x,y,w,h): prologue verify FAILED for @0x" &
           iHexPad(iTargetRva(idx), 6) & " -- refusing to call")
      break rectBlock
    iMark("RectTransform::get_rect", p)
    if cDuCallSretP2(fn, p, 4'i32) == 0'i32:
      iOut("  rect (x,y,w,h): call returned a non-finite/absurd value " &
           "(NaN or |v|>1e9) -- refusing to print a plausible-looking number")
    else:
      iOut("  rect (x,y,w,h) = (" & iFmtF(cDuSret0_2()) & ", " &
           iFmtF(cDuSret1_2()) & ", " & iFmtF(cDuSret2_2()) & ", " &
           iFmtF(cDuSret3_2()) & ")   via @0x" & iHexPad(iTargetRva(idx), 6))

  iOut("  NOTE: Vector2 getters decode via RAX (8-byte pack); get_rect " &
       "decodes via the hidden-buffer sret convention Win64 uses for a " &
       "struct >8 bytes. Both measured from GameAssembly.dll prologues, " &
       "not assumed -- see abi/aowlspt_debugui.h.")

proc iCmdLabel(toks: seq[string]) =
  ## `label EXPR` -- the text of a TMP label, read as a field.
  ## `TMP_Text.m_text` sits at +0xE0 on this build, which is how the version
  ## brand and the menu mode-text feature both read it.
  if toks.len < 2:
    iErr("usage: label EXPR")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  let p = cast[Il2CppPtr](v)
  if iRefuseIfGameObject(p, "label"):
    return
  if not duOk(p, 0xE8'i32):
    iErr("not readable to +0xE8, so it cannot be a TMP_Text.")
    return
  # A TRANSFORM IS READABLE TO +0xE8 TOO, and that is the trap.
  #
  # `label <transform>` used to print `m_text(+0xE0) = <some pointer>` and
  # `text = ""` -- a complete, well-formed, entirely meaningless answer, and
  # "the label is empty" is a conclusion someone then acts on. It happened on
  # this build while hunting the version label: the real text was
  # "1.1.0.1.46777 | PvE" on a TextMeshProUGUI one hop away, and the empty
  # string came from reading +0xE0 of the TRANSFORM.
  #
  # `children`, `find`, `tree` and `roots` all hand back TRANSFORMS, so that is
  # the overwhelmingly likely thing to be holding. Refuse it by klass identity,
  # learned by contract from those same walkers -- never guessed.
  if iIsTransform(p):
    iErr("that is a TRANSFORM (klass " & iPtrU(iKlassOf(p)) & "), not a " &
         "TMP_Text. +0xE0 on a Transform is unrelated memory and reading it " &
         "yields a plausible-looking empty string -- which reads as \"the " &
         "label is empty\" and is not an answer at all. `children`, `find`, " &
         "`tree` and `roots` all return Transforms. Resolve the text " &
         "component first:  component " & toks[1] & " TextMeshProUGUI")
    return
  let sp = cReadPtrAt(p, 0xE0'i32)
  if iIsKnownKlass(cast[uint64](sp)):
    iErr("TYPE CONFUSION: +0xE0 holds a known KLASS pointer, so this is not a " &
         "TMP_Text. Nothing was read.")
    return
  iOut("  klass = " & iPtrU(iKlassOf(p)) &
       "   m_text(+0xE0) = " & iPtr(sp))
  if sp == nil:
    iOut("  (null -- the label has no text object yet)")
    return
  iOut("  text = \"" & suiReadString(sp) & "\"")

proc iCmdSetText(toks: seq[string]) =
  ## `settext EXPR TEXT...` -- WRITE a label's text, through the game's own
  ## setters, and then read it back.
  ##
  ## The inspector could already read every label in the game and change none
  ## of them, and that asymmetry cost real cycles: the only way to try a text
  ## change was to edit the host, rebuild, deploy and relaunch -- the exact
  ## loop this instrument exists to abolish -- and the first four attempts at
  ## the version label all failed for reasons that a single live write would
  ## have shown in seconds.
  ##
  ## IT DOES NOT POKE `m_text` AND HOPE. A raw store into `m_text` appears to
  ## work and is then silently clobbered, because `LocalizedText` re-applies
  ## its own string on the next locale pass. So this reuses `swRelabelControl`
  ## -- the routine `settingsRelabelProbe` already proves on this build -- which
  ## calls `LocalizedText::SetLabelText` first, then `TMP_Text::set_text` plus
  ## the real `set_havePropertiesChanged` repaint latch, and only falls back to
  ## a raw store when neither setter verified. `control` is nil here because a
  ## plain label is not a SettingControl; that route simply declines and the
  ## TMP route does the work.
  ##
  ## AND IT VERIFIES BY READING BACK. "The setter returned" is not evidence.
  ## The text is read before and after and both are printed, so a write that
  ## was accepted and then reverted is visible as itself rather than as
  ## success.
  if toks.len < 3:
    iErr("usage: settext EXPR TEXT...   (EXPR is a TMP_Text component, not a " &
         "Transform -- resolve it with `component $gN TextMeshProUGUI`)")
    return
  if not iNavGate("settext"):
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  if v == 0'u64:
    iErr("settext was given a NULL pointer" &
         (if toks[1].len > 1 and toks[1][0] == '$':
            " -- the anchor " & toks[1] & " is NOT BOUND"
          else: "") & ". Nothing was written.")
    return
  let p = cast[Il2CppPtr](v)
  if iRefuseIfGameObject(p, "settext"):
    return
  if iIsTransform(p):
    iErr("that is a TRANSFORM (klass " & iPtrU(iKlassOf(p)) & "), not a " &
         "TMP_Text -- writing text at +0xE0 of a Transform would store a " &
         "String pointer into unrelated memory. Resolve the text component " &
         "first:  component " & toks[1] & " TextMeshProUGUI")
    return
  if not duOk(p, 0xE8'i32):
    iErr("not readable to +0xE8, so it cannot be a TMP_Text. Nothing was " &
         "written.")
    return
  if not iUnityAlive(p):
    iErr("that component's native half is NULL (destroyed object). Nothing " &
         "was written.")
    return
  # Everything after the pointer is the text, spaces preserved, so a label can
  # contain them without quoting rules nobody will remember.
  var text = ""
  var i = 2
  while i < toks.len:
    if i > 2:
      text.add " "
    text.add toks[i]
    i = i + 1
  let before = suiReadString(cReadPtrAt(p, 0xE0'i32))
  iOut("  before = \"" & before & "\"")
  iMark("settext: swRelabelControl", p)
  let ok = swRelabelControl(cast[Il2CppPtr](0), p, text)
  if not ok:
    iErr("no write route succeeded -- neither LocalizedText::SetLabelText nor " &
         "TMP_Text::set_text verified, and the raw m_text slot was not safely " &
         "writable. The label is exactly as the game left it.")
    return
  iOut("  routes  = " & gSwLastRoutes)
  let after = suiReadString(cReadPtrAt(p, 0xE0'i32))
  iOut("  after  = \"" & after & "\"")
  if after == text:
    iOut("  VERIFIED: the label now reads what was asked for.")
  elif after == before:
    iOut("  !! the write was accepted but the text is UNCHANGED. Something " &
         "re-applied the old string -- LocalizedText does exactly that on a " &
         "locale pass. Re-apply from a per-frame hook if it has to survive.")
  else:
    iOut("  !! the text changed but is not what was asked for -- the game " &
         "rewrote it between the store and this read.")

proc iCmdPress(toks: seq[string]) =
  ## `press EXPR [OFFSET]` -- fire an EFT button's OnClick, which is the only
  ## way to press anything in this game's menus.
  ##
  ## WHY THIS EXISTS, and it is not a convenience wrapper.
  ##
  ## `click`/`invoke` speak `UnityEngine.UI.Button`: interactable at +0xD8,
  ## m_OnClick at +0x100. EFT's menus contain no such thing. Every button is an
  ## `EFT.UI.DefaultUIButton`, whose chain is UIElement -> InteractableElement
  ## -> ButtonFeedback -> DefaultUIButton and touches Button nowhere. Measured,
  ## not assumed: GetComponent("Button") and GetComponent("Selectable") both
  ## return NULL on one while GetComponent("MonoBehaviour") returns it, and
  ## that same probe shows Unity's string overload DOES match base names.
  ##
  ## On that layout +0x100 is `_iconContainer`, a GAMEOBJECT -- which is
  ## exactly what `invoke` read as m_OnClick, and calling UnityEvent::Invoke on
  ## a GameObject is what made a batch escape its guard. The real event is
  ## `OnClick`, a UnityEvent, at +0x120, from the field table:
  ##
  ##   0xa0 _onPointerClickSound bool   0xb8 _text string   0x100 _iconContainer
  ##   0x108 _button TweenAnimatedButton   0x120 OnClick UnityEvent
  ##
  ## The other near miss is worth naming too, because it produced a convincing
  ## symptom: calling `ButtonFeedback::OnPointerClick` PLAYS THE CLICK SOUND
  ## and does nothing else -- audible feedback that feels like a successful
  ## press while the button has not been pressed. ButtonFeedback is the sound
  ## layer, precisely as its name says.
  ##
  ## The offset is overridable because DefaultUIButton is the common case, not
  ## the only one; a control with its event elsewhere takes `press $c 0x128`.
  if toks.len < 2:
    iErr("usage: press EXPR [OFFSET]   -- EXPR is an EFT button component " &
         "(component $gN DefaultUIButton); OFFSET defaults to 0x120, " &
         "DefaultUIButton.OnClick")
    return
  if not iNavGate("press"):
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  if v == 0'u64:
    iErr("press was given a NULL pointer" &
         (if toks[1].len > 1 and toks[1][0] == '$':
            " -- the anchor " & toks[1] & " is NOT BOUND"
          else: "") & ". Nothing was called.")
    return
  let p = cast[Il2CppPtr](v)
  if iRefuseIfGameObject(p, "press"):
    return
  if iIsTransform(p):
    iErr("that is a TRANSFORM, not a button COMPONENT. `children`, `find` and " &
         "`tree` all return Transforms. Resolve the component first:  " &
         "component " & toks[1] & " DefaultUIButton")
    return
  var off = 0x120'i32
  var offGiven = false
  if toks.len > 2:
    var o = 0'u64
    var e = ""
    if iEval(toks[2], o, e) and int(o) > 0 and int(o) < 0x400:
      off = int32(o)
      offGiven = true
    else:
      iErr("that offset is not a small positive number; refusing to read a " &
           "wild slot. Nothing was called.")
      return
  if not duOk(p, off + 8'i32) or not iUnityAlive(p):
    iErr("not readable to +0x" & iHexPad(uint64(off), 3) &
         ", or its native half is null. Nothing was called.")
    return
  # THE RECEIVER TYPE CHECK -- but only for the DEFAULT offset.
  #
  # +0x120 is `EFT.UI.DefaultUIButton.OnClick` and means nothing on any other
  # type, so a bare `press` must prove it has a DefaultUIButton. An EXPLICIT
  # offset is the documented escape hatch for a control that keeps its event
  # somewhere else, so requiring DefaultUIButton there would refuse exactly the
  # case the parameter exists for -- the klass chain is PRINTED instead, so the
  # caller can see what they are pressing rather than being asked to trust it.
  if not offGiven:
    if not iRequireKlass(p, "EFT.UI.DefaultUIButton", "press"):
      return
  else:
    var chain = ""
    discard iKlassIs(p, "EFT.UI.DefaultUIButton", chain)
    iOut("  receiver type: " &
         (if chain.len > 0: chain else: "UNREADABLE") &
         "   (explicit offset given, so the DefaultUIButton requirement is " &
         "waived -- the UnityEvent shape checks below still apply)")
  # Name the button before pressing it. `_text` at +0xB8 is what the label
  # reads, so the output says WHICH button was pressed rather than only that
  # something was -- the difference between evidence and a claim.
  var what = ""
  if duOk(p, 0xC0'i32):
    let tp = cReadPtrAt(p, 0xB8'i32)
    if tp != nil and not iIsKnownKlass(cast[uint64](tp)):
      what = suiReadString(tp)
  let ev = cReadPtrAt(p, off)
  iOut("  target klass = " & iPtrU(iKlassOf(p)) &
       (if what.len > 0: "   _text(+0xB8) = \"" & what & "\"" else: "") &
       "   OnClick(+0x" & iHexPad(uint64(off), 3) & ") = " & iPtr(ev))
  if ev == nil:
    iErr("that slot is NULL -- no handler is wired to this button, so " &
         "pressing it could not do anything. Nothing was called.")
    return
  if iIsGameObject(ev):
    iErr("that slot holds a GAMEOBJECT, not a UnityEvent -- on " &
         "DefaultUIButton +0x100 is `_iconContainer` and this is what that " &
         "mistake looks like. Did you mean the default +0x120? Nothing was " &
         "called.")
    return
  if iIsKnownKlass(cast[uint64](ev)):
    iErr("that slot holds a KLASS POINTER already seen as another object's " &
         "type, so it cannot be a per-instance UnityEvent. Nothing was called.")
    return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("UnityEvent::Invoke", fn, rva):
    return
  iOut("  via UnityEngine.Events.UnityEvent::Invoke @0x" &
       iHexPad(uint64(rva), 6) & " (call) on " & iPtr(ev))
  iMark("press: UnityEvent::Invoke", ev)
  discard cInspUP(fn, ev, nil)
  iOut("  returned without faulting.")
  iOut("  NOTE: that the handler returned is NOT proof the intended thing " &
       "happened -- a click handler acts on OTHER objects. Confirm the " &
       "EFFECT with `state`, `roots`, or `until`, never with this line.")

proc iCmdClick(toks: seq[string]; useInvoke: bool) =
  ## `click PTR` -- EFT's own path: `Button::Press`, which re-checks IsActive
  ## and IsInteractable and then fires m_OnClick exactly as a real click does.
  ## `invoke PTR` -- fire `m_OnClick` directly via `UnityEvent::Invoke`,
  ## skipping those checks, for a control that is deliberately not
  ## interactable.
  ##
  ## AND IT VERIFIES. Reporting "clicked" because a call returned is exactly
  ## the failure this instrument exists to abolish -- it is the same class of
  ## claim as a missed synthetic click. So the interactable flag and the
  ## m_OnClick pointer are read BEFORE (as plain field reads, no calls), the
  ## call is announced, and the state is read again AFTER and reported.
  let verb = (if useInvoke: "invoke" else: "click")
  if toks.len < 2:
    iErr("usage: " & verb & " PTR   -- PTR is a Button component")
    return
  if not iNavGate(verb):
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  if v == 0'u64:
    var why = ""
    if toks[1].len > 1 and toks[1][0] == '$':
      why = " -- the anchor " & toks[1] & " is NOT BOUND. A `component` " &
            "lookup that fails now leaves $comp unbound rather than stale, " &
            "and this is that guard speaking: resolve the component first, " &
            "and check that the lookup above actually said FOUND."
    iErr(verb & " was given a NULL pointer" & why & ". Nothing was called.")
    return
  let btn = cast[Il2CppPtr](v)
  if iRefuseIfGameObject(btn, verb):
    return
  if not duOk(btn, cNavOffOnClick() + 8'i32):
    iErr("that pointer is not readable to +0x" &
         iHexPad(uint64(cNavOffOnClick()), 3) & ", so it cannot be a Button. " &
         "Nothing was called.")
    return
  if not iUnityAlive(btn):
    iErr("that Button's native half is NULL (destroyed object). Nothing was " &
         "called.")
    return
  # THE RECEIVER TYPE CHECK, BEFORE any Button-shaped field is read.
  #
  # The two checks further down (a GameObject or a klass pointer in the
  # m_OnClick slot) are inferences ABOUT the layout from values found at
  # Button's offsets. This asks the question directly, and it is strictly
  # stronger: `UnityEngine.CanvasRenderer` has neither a GameObject nor a klass
  # pointer at +0x100, so it would have passed both of them.
  if not iRequireKlass(btn, "UnityEngine.UI.Button", verb):
    return
  # Field reads, corroborated by the getters' own inlined bodies -- no calls,
  # so this pre-flight can never itself be what breaks.
  let interact = cReadI32At(cast[Il2CppPtr](cast[uint64](btn) +
                            uint64(cNavOffInteract()))) and 0xFF'i32
  let onClick = cReadPtrAt(btn, cNavOffOnClick())
  iOut("  target klass = " & iPtrU(iKlassOf(btn)))
  iOut("  Button m_Interactable(+0x" & iHexPad(uint64(cNavOffInteract()), 3) &
       ") = " & (if interact != 0'i32: "true" else: "false") &
       "   m_OnClick(+0x" & iHexPad(uint64(cNavOffOnClick()), 3) & ") = " &
       iPtr(onClick))
  # THE TYPE-CONFUSION CHECK.
  #
  # These offsets are only meaningful on a Button. Read off a Transform they
  # land on unrelated memory and produce values that look plausible -- which is
  # far worse than an obvious failure, because the guard then refuses for a
  # reason that is true but irrelevant, and the real problem stays hidden.
  #
  # A managed object pointer can never legitimately equal a klass pointer. If
  # +0x100 holds something we have already seen as the TYPE of another object,
  # we are reading the wrong kind of object and must say so instead of
  # continuing to describe it as `m_OnClick`.
  # THE SECOND TYPE-CONFUSION CHECK, and the one that costs a real escape.
  #
  # The check below catches a KLASS pointer in the m_OnClick slot. It does not
  # catch an ordinary OBJECT of the wrong type, and that is the case that
  # actually got through: on EFT's `DefaultUIButton`, +0x100 holds a
  # GAMEOBJECT. It is not a klass pointer, so the check below passed it, and
  # `UnityEvent::Invoke` was called on a GameObject. The batch ESCAPED its
  # guard -- caught, the game survived, but the whole batch died.
  #
  # `DefaultUIButton` is where this comes from, and it is worth stating
  # plainly because it governs every EFT control: it is NOT a
  # `UnityEngine.UI.Button`. Measured, not assumed -- `GetComponent("Button")`
  # and `GetComponent("Selectable")` both return NULL on it while
  # `GetComponent("MonoBehaviour")` returns it, and Unity's string overload
  # DOES match base type names (that same probe proves it). So Button's field
  # layout is meaningless on every button in this game's menus, and this
  # refuses instead of reading it.
  if iIsGameObject(onClick):
    iErr("TYPE CONFUSION: the value at +0x" &
         iHexPad(uint64(cNavOffOnClick()), 3) & " (" & iPtr(onClick) &
         ") is a GAMEOBJECT, not a UnityEvent -- so this component does not " &
         "have UnityEngine.UI.Button's field layout and is NOT a Button. " &
         "EFT's own controls (DefaultUIButton and friends) are plain " &
         "MonoBehaviours, not Buttons: GetComponent(\"Button\") and " &
         "GetComponent(\"Selectable\") both return NULL on them. Nothing was " &
         "called -- calling UnityEvent::Invoke on this pointer is what made " &
         "an earlier batch escape its guard.")
    return
  if iIsKnownKlass(cast[uint64](onClick)):
    iErr("TYPE CONFUSION: the value at +0x" &
         iHexPad(uint64(cNavOffOnClick()), 3) & " (" & iPtr(onClick) &
         ") is a KLASS POINTER already seen as the type of another object -- " &
         "it cannot be a per-instance UnityEvent. This pointer is almost " &
         "certainly a Transform or GameObject, NOT a Button component: " &
         "`children` and `find` return TRANSFORMS. Nothing was called. " &
         "Resolve the Button first with `component " & toks[1] & " Button`.")
    return
  if onClick == nil:
    iErr("m_OnClick is NULL -- this object has no click handler, so it is " &
         "either not a Button or not wired up. Nothing was called.")
    return
  if not useInvoke and interact == 0'i32:
    iErr("the Button is NOT interactable, so Button::Press would check that " &
         "and do nothing -- a call that 'succeeds' and changes nothing is the " &
         "worst possible outcome here. Nothing was called. Use `invoke` to " &
         "fire m_OnClick anyway if that is really what you want.")
    return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if useInvoke:
    if not iNavFind("UnityEvent::Invoke", fn, rva):
      return
    iOut("  via UnityEngine.Events.UnityEvent::Invoke @0x" &
         iHexPad(uint64(rva), 6) & " (call) on " & iPtr(onClick))
    iMark("UnityEvent::Invoke", onClick)
    discard cInspUP(fn, onClick, nil)
  else:
    if not iNavFind("Button::Press", fn, rva):
      return
    iOut("  via UnityEngine.UI.Button::Press @0x" & iHexPad(uint64(rva), 6) &
         " (call) on " & iPtr(btn))
    iMark("Button::Press", btn)
    discard cInspUP(fn, btn, nil)
  # THE AFTER-READ. Whether anything actually changed is a question about the
  # game's state, not about our call returning.
  let interact2 = cReadI32At(cast[Il2CppPtr](cast[uint64](btn) +
                             uint64(cNavOffInteract()))) and 0xFF'i32
  iOut("  returned without faulting. m_Interactable now " &
       (if interact2 != 0'i32: "true" else: "false") &
       (if interact2 != interact: "  (CHANGED)" else: "  (unchanged)"))
  iOut("  NOTE: a handler that returns normally is not proof the intended " &
       "thing happened -- most click handlers act on OTHER objects. Follow " &
       "with `state`, or `until` on whatever the click was supposed to " &
       "create, to confirm the effect rather than the call.")

proc iInspSettingsSelf(): Il2CppPtr =
  ## The best-known live SettingsScreen `this`. `gSettingsLiveSelf` is set by
  ## the `ShowScreen` postfix that actually drives Phase 1/2/3 (settingsui.nim);
  ## `gMi2Self` is set only by the separate invoke2 ladder proof, which is a
  ## different hook (`EnsureTabInitialized` postfix) and may never fire in a
  ## given session. Preferring the former is what makes `state` match reality
  ## rather than asserting a specific probe ran.
  if gSettingsLiveSelf != nil: gSettingsLiveSelf else: gMi2Self

const
  InspGroupMax = 4
    ## `ESettingsGroup`, MEASURED offline out of this build's metadata
    ## (`il2cpp_resolve.py fields ESettingsGroup`, HASDEFAULT column):
    ##   Screen=0  Game=1  Sound=2  Control=3  PostFX=4
    ## Note `Screen` is the GRAPHICS tab. There is no member above 4, so a
    ## larger number is not a group at all.

proc iGroupByName(tok: string; group: var uint64): bool =
  ## Names -> the enum, case-insensitively, plus the common aliases a person
  ## actually types. The bug this replaces: `open Graphics` evaluated
  ## "Graphics" as an EXPRESSION, got 0 out of a failed parse whose return
  ## value was DISCARDED, and opened Game -- an unknown name silently became
  ## group 0, which is a check that cannot fail.
  let t = iLower(tok)
  if t == "screen" or t == "graphics" or t == "display" or t == "video":
    group = 0'u64
  elif t == "game" or t == "gameplay":
    group = 1'u64
  elif t == "sound" or t == "audio":
    group = 2'u64
  elif t == "control" or t == "controls" or t == "keybinds":
    group = 3'u64
  elif t == "postfx" or t == "post-fx" or t == "post" or t == "postprocessing":
    group = 4'u64
  else:
    return false
  result = true

proc iCmdOpen(toks: seq[string]) =
  ## `open [GROUP]` -- EFT.UI.SettingsScreen::ShowScreen(screen, group).
  ##
  ## GROUP is a NAME (Screen/Graphics, Game, Sound, Control, PostFX) or the
  ## enum number 0..4. An unknown name is REFUSED with the list; it is never
  ## quietly read as 0.
  if not iNavGate("open"):
    return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("ShowScreen", fn, rva):
    return
  var screen = iInspSettingsSelf()
  if screen == nil:
    iErr("no live SettingsScreen is known yet ($settings is null). It is " &
         "learned by the ShowScreen postfix or the invoke2 ladder hook, " &
         "whichever fires first, so open Settings once manually (with the " &
         "relevant flag on -- see `state` for which hooks are armed) and " &
         "this will work from then on.")
    return
  # ---- WHAT GROUP, EXACTLY. A name that is not a group is a REFUSAL. ----
  var group = 0'u64
  if toks.len > 1:
    if not iGroupByName(toks[1], group):
      var err = ""
      if not iEval(toks[1], group, err) or group > uint64(InspGroupMax):
        iErr("\"" & toks[1] & "\" is not a settings group. Nothing was " &
             "called. ESettingsGroup on this build has exactly five members " &
             "(measured from metadata): 0 Screen (the GRAPHICS tab; aliases " &
             "graphics/display/video), 1 Game, 2 Sound (audio), 3 Control " &
             "(controls), 4 PostFX. Names are case-insensitive. This used to " &
             "evaluate an unknown name to 0 and open Screen, which is why " &
             "`open Graphics` appeared to open the wrong tab -- it was not " &
             "wrong about Graphics, it was ignoring the word entirely.")
        return
  else:
    iOut("  NOTE: no group named, so this uses 0 (Screen -- the GRAPHICS " &
         "tab), which is what a bare `open` has always done.")
  # ---- IS THE SCREEN IN A CALLABLE STATE? ----
  #
  # MEASURED: `open N` issued immediately after pressing BACK escaped the SEH
  # guard -- ShowScreen ran on a screen that was mid-close. `$settings` does
  # NOT go null across a close (the same pointer comes back on reopen), so the
  # pointer being non-nil proves nothing at all about whether calling into it
  # is safe. `activeInHierarchy` is the state that actually differs, and it is
  # a call we already make everywhere else.
  if not iUnityAlive(screen):
    iErr("open REFUSED: the SettingsScreen's native half is NULL (Unity's " &
         "fake null -- the managed object is readable and the C++ object is " &
         "gone). ShowScreen would fault inside Unity where no guard of ours " &
         "reaches. Nothing was called.")
    return
  var actNote = ""
  let (actOk, act) = iActiveInHierarchyChecked(screen, actNote)
  if not actOk:
    iErr("open REFUSED: activeInHierarchy could not be read for the " &
         "SettingsScreen (Component::get_gameObject / " &
         "GameObject::get_activeInHierarchy did not answer, or the two " &
         "derivations disagreed" &
         (if actNote.len > 0: ": " & actNote else: "") &
         "), so whether it is in a callable state is UNKNOWN. Nothing was called -- 'I could not " &
         "look' is not 'it is fine'.")
    return
  if not act:
    iErr("open REFUSED: the SettingsScreen is NOT active in the hierarchy -- " &
         "it is closed or mid-close. ShowScreen on a closing screen is what " &
         "made an earlier batch ESCAPE its guard (channel counter escapes=1). " &
         "Nothing was called. Reopen Settings, or if you have just pressed " &
         "BACK, wait for it: put `until $settings+0x" &
         iHexPad(uint64(cNavOffInitTabs()), 3) & " 120` before this line.")
    return
  if not iRequireKlass(screen, "EFT.UI.Settings.SettingsScreen", "open"):
    return
  iOut("  via EFT.UI.SettingsScreen::ShowScreen @0x" &
       iHexPad(uint64(rva), 6) & " (call) on " & iPtr(screen) &
       ", group=" & $int(group))
  iMark("SettingsScreen::ShowScreen", screen)
  discard cInspUPI(fn, screen, int32(group), nil)
  iOut("  ShowScreen returned. It is ASYNCHRONOUS -- the screen it asked for " &
       "does not exist yet. Follow with `until $settings+0x118` before " &
       "reading the tab.")

const
  InspToggleIsOnOff = 0x120'i32
    ## `UnityEngine.UI.Toggle.m_IsOn`, from `il2cpp_resolve.py fields
    ## UnityEngine.UI.Toggle` -- and it is the SAME offset EFT.UI.AnimatedToggle
    ## inherits, so the before/after read below is valid for both.
  InspToggleSetIsOnRva = 0x55ba430'u64
  InspToggleSetIsOnSig = "4533c941b001e9"
    ## `UnityEngine.UI.Toggle::set_isOn(bool)` -- a tail-jump thunk:
    ##   xor r9d,r9d ; mov r8b,1 ; jmp Toggle::Set(bool value, bool send)
    ## so the trailing MethodInfo* we pass in R8 is overwritten by the thunk
    ## itself and NULL-MethodInfo is not merely tolerated here, it is
    ## irrelevant. UNIQUE (not a shared RVA), and this is a CALL, not a detour.

proc iCmdTab(toks: seq[string]) =
  ## `tab EXPR [0|1]` -- SELECT A SETTINGS TAB THE WAY THE PLAYER DOES.
  ##
  ## It used to call `EFT.UI.Settings.SettingsTab::set_IsSelected`, and that is
  ## two separate bugs measured live in one session:
  ##
  ##  1. IT DID NOT TYPE-CHECK. Handed an `EFT.UI.AnimatedToggle` and then a
  ##     `UnityEngine.CanvasRenderer`, it called SettingsTab's setter on both,
  ##     wrote +0x90 on objects with no such field, printed a plausible
  ##     "first-select latch" line, and left the screen desynced.
  ##  2. EVEN ON A REAL SettingsTab IT MOVED THE HIGHLIGHT AND NOT THE PANEL.
  ##     The screen switches on the tab TOGGLE's `onValueChanged`, not on
  ##     `set_IsSelected` -- so the observable outcome was GRAPHICS highlighted
  ##     with the Game panel still showing. A verb that changes the appearance
  ##     of the thing you asked for while not doing it is the worst shape of
  ##     answer this instrument produces.
  ##
  ## So it now drives `Toggle::set_isOn`, which is what a real click reaches,
  ## and it verifies against the FINISHED STATE -- the SettingsScreen's own
  ## `_currentTab` before and after -- rather than against its own write.
  if toks.len < 2:
    iErr("usage: tab EXPR [0|1]   -- EXPR is an EFT.UI.Settings.SettingsTab " &
         "or the tab's own Toggle/AnimatedToggle")
    return
  if not iNavGate("tab"):
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  if v == 0'u64:
    iErr("tab was given a NULL pointer" &
         (if toks[1].len > 1 and toks[1][0] == '$':
            " -- the anchor " & toks[1] & " is NOT BOUND"
          else: "") & ". Nothing was called.")
    return
  let given = cast[Il2CppPtr](v)
  if iRefuseIfGameObject(given, "tab"):
    return
  if not duOk(given, InspToggleIsOnOff + 8'i32) or not iUnityAlive(given):
    iErr("that pointer is not readable to +0x" &
         iHexPad(uint64(InspToggleIsOnOff), 3) & ", or its native half is " &
         "null. Nothing was called.")
    return

  # ---- WHAT DID WE ACTUALLY GET? Exactly two answers are accepted. ----
  var chainTab = ""
  let isTab = iKlassIs(given, "EFT.UI.Settings.SettingsTab", chainTab)
  var chainTog = ""
  let isTog = iKlassIs(given, "UnityEngine.UI.Toggle", chainTog)
  var toggle: Il2CppPtr = nil
  if isTog == KlassYes:
    iOut("  receiver type: " & chainTog & "   -- IS a UnityEngine.UI.Toggle, " &
         "using it directly")
    toggle = given
  elif isTab == KlassYes:
    iOut("  receiver type: " & chainTab &
         "   -- IS an EFT.UI.Settings.SettingsTab; looking for its Toggle")
    # The Toggle is a COMPONENT, not a field: SettingsTab's field table
    # (offline) has no toggle slot at all -- 0x80 OnLoadingInProgress,
    # 0x88 _createdControls, 0x90 <IsInitialized>. So it is fetched by
    # GetComponent on the tab's own GameObject, which is where a real click
    # lands. Unity's string overload matches BASE type names, so "Toggle"
    # catches EFT.UI.AnimatedToggle too.
    var why = ""
    let go = iGameObjectOf(given)
    if go != nil:
      toggle = iGetComponentQuiet(go, "Toggle", why)
    if toggle == nil:
      iErr("tab REFUSED: this IS a SettingsTab, but no Toggle component was " &
           "found on its GameObject (" & why & "). Nothing was called. The " &
           "screen switches on the tab toggle's onValueChanged, so without " &
           "the Toggle there is nothing to drive -- `set_IsSelected` alone " &
           "moves the HIGHLIGHT and leaves the panel behind, which is the " &
           "bug this verb was rewritten to stop. Find it with `components " &
           toks[1] & "` and pass it here directly.")
      return
  else:
    iErr("tab REFUSED -- WRONG RECEIVER TYPE. As a SettingsTab this reads " &
         (if chainTab.len > 0: chainTab else: "nothing readable") &
         "; as a Toggle it reads " &
         (if chainTog.len > 0: chainTog else: "nothing readable") &
         ". It is neither, so nothing was called. Measured: this verb " &
         "previously accepted an EFT.UI.AnimatedToggle and a " &
         "UnityEngine.CanvasRenderer, called SettingsTab::set_IsSelected on " &
         "each, wrote +0x90 on both and desynced the Settings screen without " &
         "faulting.")
    return

  # The component we ended up with must itself be a Toggle. On the
  # GetComponent path Unity's short-name match is a CONTRACT, not a proof --
  # so it is checked, not assumed.
  if not iRequireKlass(toggle, "UnityEngine.UI.Toggle", "tab"):
    return
  if not duOk(toggle, InspToggleIsOnOff + 8'i32) or not iUnityAlive(toggle):
    iErr("the Toggle is not readable to +0x" &
         iHexPad(uint64(InspToggleIsOnOff), 3) & ", or its native half is " &
         "null. Nothing was called.")
    return

  var val = 1'u64
  if toks.len > 2:
    var e2 = ""
    if not iEval(toks[2], val, e2) or val > 1'u64:
      iErr("the value must be 0 or 1. Nothing was called.")
      return

  # ---- THE CALL, BYTE-VERIFIED AT ITS RVA ----
  let fn = cInspCode(InspToggleSetIsOnRva)
  if fn == nil:
    let why = case int(cInspReason())
              of 1: "GameAssembly.dll is not loaded"
              of 2: "that RVA is outside the image"
              of 3: "not committed or not executable"
              of 4: "outside the `il2cpp` section"
              of 5: "the first bytes are a JUMP -- something already detours " &
                    "this, so what is here is a TRAMPOLINE and not the function"
              else: "refused"
    iErr("Toggle::set_isOn @0x" & iHexPad(InspToggleSetIsOnRva, 7) &
         " did not resolve: " & why & ". Nothing was called.")
    return
  if not iPrologueOk(fn, InspToggleSetIsOnSig):
    iErr("Toggle::set_isOn @0x" & iHexPad(InspToggleSetIsOnRva, 7) &
         " does not start with " & InspToggleSetIsOnSig & " on this build. " &
         "Nothing was called -- an RVA that no longer verifies is a wrong " &
         "address, not a reason to call it anyway.")
    return

  # ---- READ THE FINISHED STATE, NOT OUR OWN WRITE ----
  #
  # `m_IsOn` is what we set, so re-reading it proves only that the store
  # happened. `_currentTab` on the SettingsScreen is what the PANEL follows,
  # and it is a different object we do not touch -- that is the assertion
  # worth making, and the one that would have caught the highlight-without-
  # panel bug the first time.
  let ss = iInspSettingsSelf()
  var curBefore: Il2CppPtr = nil
  var haveScreen = false
  if ss != nil and duOk(ss, cNavOffCurrentTab() + 8'i32):
    curBefore = cReadPtrAt(ss, cNavOffCurrentTab())
    haveScreen = true
  let onBefore = cReadI32At(cast[Il2CppPtr](cast[uint64](toggle) +
                            uint64(InspToggleIsOnOff))) and 0xFF'i32
  iOut("  via UnityEngine.UI.Toggle::set_isOn @0x" &
       iHexPad(InspToggleSetIsOnRva, 7) & " (call, prologue verified) on " &
       iPtr(toggle) & ", value=" & $int(val) &
       "   m_IsOn(+0x" & iHexPad(uint64(InspToggleIsOnOff), 3) & ") was " &
       (if onBefore != 0'i32: "true" else: "false"))
  iMark("Toggle::set_isOn", toggle)
  discard cInspUPI(fn, toggle, int32(val), nil)
  let onAfter = cReadI32At(cast[Il2CppPtr](cast[uint64](toggle) +
                           uint64(InspToggleIsOnOff))) and 0xFF'i32
  iOut("  returned without faulting. m_IsOn now " &
       (if onAfter != 0'i32: "true" else: "false") &
       (if onAfter != onBefore: "  (CHANGED)" else: "  (unchanged)"))
  if not haveScreen:
    iOut("  _currentTab: NOT CHECKED -- no live SettingsScreen is known " &
         "($settings is null), so whether the PANEL followed is UNKNOWN. " &
         "That is inconclusive, not success.")
  else:
    let curAfter = cReadPtrAt(ss, cNavOffCurrentTab())
    iOut("  SettingsScreen._currentTab(+0x" &
         iHexPad(uint64(cNavOffCurrentTab()), 3) & ") " &
         iPtrU(cast[uint64](curBefore)) & " -> " & iPtrU(cast[uint64](curAfter)) &
         (if curAfter != curBefore:
            "   <- the PANEL followed"
          else:
            "   <- UNCHANGED. The panel did NOT switch. Either this tab was " &
            "already current, or onValueChanged has not run yet -- it can be " &
            "a frame late, so re-read with `state` before concluding."))

proc iCmdState(toks: seq[string]) =
  ## `state` -- what is on screen right now, as FIELD READS only.
  ##
  ## The point of this command is that automation without verification is
  ## worse than no automation: a failed navigation step that goes unnoticed
  ## corrupts every step after it, and does so silently. Everything here is a
  ## guarded field read -- no calls -- so `state` itself can never be the thing
  ## that breaks.
  iOut("  anchors: $preloader=" & iPtr(gInspPreloader) &
       " $settings=" & iPtr(iInspSettingsSelf()))
  iOut("  inspector: menu anchor slot=" & $gInspSlot &
       ", in-raid anchor slot=" & $gInspSlot2 &
       ", dispatches=" & $gInspFires & " (of those in-raid=" &
       $gInspDrainFires & ")")
  iOut("  channel: polls=" & $gInspPolls & " reads=" & $gInspReads &
       " readFails=" & $gInspReadFails & " unchanged=" & $gInspUnchanged &
       " batch=" & $gInspBatch & " ticks=" & $gInspTicks &
       " faults=" & $gInspFaults & " escapes=" & $gInspEscapes)
  if gInspPreloader == nil:
    iOut("  menu: PreloaderUI anchor is null -- either the menu has not built " &
         "yet, or the session is in a raid (where PreloaderUI does not tick).")
  let ss = iInspSettingsSelf()
  if ss == nil:
    iOut("  settings: NOT KNOWN. Two independent hooks can learn this pointer " &
         "-- the `ShowScreen` postfix (settingsUiProbe / settingsRelabelProbe / " &
         "settingsBindProbe / settingsPages) and the invoke2 ladder proof " &
         "(EnsureTabInitialized postfix) -- and neither has reported one yet " &
         "this session. Most likely cause: the Settings screen has not been " &
         "opened, OR it has been opened but the flag that arms one of those " &
         "hooks is off. Check `python tools/hostcfg.py show` and the host log " &
         "for 'settings probe: ShowScreen (postfix) first fired' before " &
         "assuming this is a read failure.")
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

var gInspStrCount = 0

proc iCmdStr(toks: seq[string]) =
  ## `str TEXT...` -- allocate a managed `System.String` and BIND it, so it can
  ## be passed to `call`.
  ##
  ## Why this verb exists: `call` evaluates every non-float argument through
  ## `iEval`, which yields a pointer. There was no way to produce a String*
  ## pointer inside a batch at all. `write EXPR str TEXT` allocates one, but
  ## only as a side effect of storing it into a slot that already exists -- so
  ## calling ANY game method that takes a string meant finding some live object
  ## with a spare string field, clobbering it, and reading the pointer back.
  ## That is a write to game state in order to perform a read, which is exactly
  ## the trade this tool should never make the caller take.
  ##
  ## The text is the REST OF THE LINE from token 1 on, rejoined with single
  ## spaces -- the tokenizer splits on whitespace, and a message worth passing
  ## to a game method almost always has a space in it. Runs of whitespace are
  ## therefore collapsed; that is a real limitation and it is stated here rather
  ## than left to be discovered.
  ##
  ## Binds `$str0`, `$str1`, ... per batch, and `$_` to the most recent, so:
  ##
  ##     allow write
  ##     str Hello from the inspector
  ##     call rva:0x156b930 v_ppp $preloader $str0 0
  ##
  ## Needs `allow write` and `liveInspectorWrite`: `il2cpp_string_new` really
  ## allocates in the managed heap. It is the ONE allocation primitive proven to
  ## work on this build (CLAUDE.md section 5), and it is what the version brand
  ## and the F3 overlay already use, so this adds no new capability -- only a
  ## way to reach the existing one without collateral damage.
  if toks.len < 2:
    iErr("usage: str TEXT...   (the rest of the line becomes the string)")
    return
  if not gInspWriteOn:
    iErr("`str` allocates a managed String via il2cpp_string_new, so it needs " &
         "`liveInspectorWrite: true` in aowlspt-host.json")
    return
  if not gInspAllowWrite:
    iErr("`str` allocates in the managed heap, so it needs an `allow write` " &
         "line earlier in this batch")
    return
  var text = ""
  for i in 1 ..< toks.len:
    if text.len > 0:
      text.add ' '
    text.add toks[i]
  gInspStrText = text
  let s = inspNewStringImpl(cast[Il2CppPtr](0))
  if s == nil or cIsReadable(s, 0x14'i32) == 0'i32:
    # Never bind on failure. A stale `$str0` from an earlier batch silently
    # standing in for a string that was never allocated is the exact shape of
    # the `$comp` bug this inspector already had once.
    iErr("il2cpp_string_new did not return a usable String for \"" & text &
         "\"; nothing was allocated and no anchor was bound")
    return
  # Self-check, and deliberately one that CAN fail: decode the object we just
  # made back through the ordinary String reader and compare it, character for
  # character, with what was asked for. A pointer that does not read back as the
  # requested text is not a String, and handing it to `call` would put an
  # arbitrary pointer in an argument register of live game code.
  #
  # Note this is a check on the FINISHED STATE (what the object now contains),
  # not on our own write (that il2cpp_string_new returned non-null) -- CLAUDE.md
  # section 9b. Non-null was the check that could not fail.
  let back = suiReadString(s)
  if back != text:
    iErr("il2cpp_string_new returned " & iPtrU(cast[uint64](s)) &
         " but reading it back gives \"" & back & "\", not the \"" & text &
         "\" that was requested. REFUSING to bind it -- that is not the " &
         "String it claims to be, and passing it to `call` would hand game " &
         "code an arbitrary pointer.")
    return
  let name = "str" & $gInspStrCount
  inc gInspStrCount
  iSetVarP(name, s)
  iSetVar("_", cast[uint64](s))
  iOut("  allocated String* " & iPtrU(cast[uint64](s)) & " len=" & $text.len &
       " = \"" & back & "\"   (read back and verified; bound to $" & name &
       " and $_)")

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
  # THE FIELDREF VERDICT ON A DELIBERATELY RAW WRITE.
  #
  # This verb stays raw on purpose -- it is the one escape hatch in the tree
  # (WRITE-AUDIT #10) and an operator debugging a live client has to be able to
  # write things the metadata has never heard of. What it must not do is write
  # into a slot the metadata DOES know about without saying so: `write <expr>
  # i32 -1` into a reference slot is a literal match for the producer of the
  # 0x00000000FFFFFFFF that killed the liveness walk.
  #
  # ADVISORY, never a refusal. And it says NOTHING unless it can name a
  # FieldRef whose receiver at `p - off` presents an ADMITTED klass -- matching
  # on the offset alone would be a confidently wrong answer, which is worse
  # than none. "no known field" is therefore not "safe"; it is "the table
  # cannot claim this address", and it says exactly that.
  var frWhy = 0'i32
  let frRow = cFrLookup(p, size, frWhy)
  if frRow >= 0'i32:
    let what = $cFrRowType(frRow) & "." & $cFrRowField(frRow)
    if frWhy == 1'i32:
      iOut("  FIELDREF WARNING: " & iPtr(p) & " is " & what & ", which the " &
           "metadata declares an 8-byte managed REFERENCE. Writing " &
           $int(size) & " byte(s) of " & t & " there is exactly the store " &
           "the typed path refuses (R1): a 4-byte -1 into a zeroed reference " &
           "slot IS 0x00000000FFFFFFFF. Proceeding, because this verb is the " &
           "deliberate escape hatch -- but that is what you are doing.")
    elif frWhy == 2'i32:
      iOut("  FIELDREF WARNING: " & iPtr(p) & " is inside " & what &
           ", which is " & $int(cFrRowWidth(frRow)) & " byte(s) wide; this " &
           "write of " & $int(size) & " byte(s) runs past the end of it.")
    else:
      iOut("  fieldref: " & iPtr(p) & " is " & what & " (" &
           $int(cFrRowWidth(frRow)) & " bytes, " &
           (if cFrRowIsRef(frRow) != 0'i32: "reference" else: "value") &
           "); the typed path would allow this width.")
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

# ===========================================================================
# THE VISIBILITY VERBS -- `visible`, `screenrect`, `canvasorder`,
# `whydidntitdraw`
#
# THE GAP THEY CLOSE
# ------------------
# Everything above this point answers "does it EXIST": a pointer, a name, a
# child count, a field. Nothing answered "is it ON SCREEN", and that gap cost
# six rounds on one feature. The F3 debug overlay clones TMP labels into the
# game's canvas; three of those rounds were genuine pointer bugs (a destroyed
# wrapper, a cached `m_rectTransform` that passed both readability AND liveness
# gates, an off-by-one in a positional index table). Each fix was real. Then the
# walk SUCCEEDED -- clones made, nested Canvas disabled, zero faults -- and
# still nothing appeared, and there was no question we could ask that would
# distinguish a working walk from a broken one. That is the whole reason these
# verbs exist.
#
# THE DISCIPLINE (CLAUDE.md 9b)
# -----------------------------
# THREE OUTCOMES, NEVER TWO. Every factor below is a tri-state: YES, NO, or
# "I could not look", and the third is never quietly folded into the second.
# A verdict of NOT VISIBLE names the factor that killed it AND the call that
# measured it; a verdict of INCONCLUSIVE names the factor we could not read and
# why. "Nothing appeared" plus "no faults" is exactly the evidence we already
# had, and it is worth nothing.
#
# The arithmetic -- the alpha fold, the on-screen classification, the
# degenerate-rect test -- is NOT written here. It lives in `abi/aowlspt_visible.h`
# and is asserted offline by `tests/overlayhost/vistest.c`, because pure logic
# that can only be exercised inside a running Tarkov client is logic that never
# gets tested.
#
# THE SAFETY RULES THESE PATHS OBEY
# ---------------------------------
#   * EVERY managed target is resolved BY NAME through `iFindTarget`, which
#     returns a function only after a 16-byte prologue byte-verify against the
#     startup snapshot. No positional index into a C table appears anywhere in
#     this block -- that is the 2026-08-24 defect (`DuGetParent` resolving to
#     `Transform::set_localPosition`) and a name lookup is structurally immune
#     to it.
#   * `iVisSelfOk` -- readability AND `m_CachedPtr` liveness -- runs before
#     EVERY use of a pointer as `this`, not once at entry. That distinction is
#     the whole of fact #184: a pointer that passed both gates at the top of a
#     walk had been destroyed by the time it was used four hops later.
#   * ONE `aowl_p_p_seh`, the one `iExec` already wraps each command in.
#     Nothing here adds a guard; a nested guard disarms the outer one.
#   * Every ancestor walk is capped (`VisMaxClimb`), every scan is capped.
#   * `iMark` names the hop before every dereference and before every call, so
#     a caught fault reports WHICH factor was being measured.
# ===========================================================================

# The generic (retbuf, this, &Vector3, MethodInfo*) thunk, added to
# aowlspt_debugui.h beside the one Camera::WorldToScreenPoint already used.
proc cDuCallSretPV3(fn, self: Il2CppPtr; ax, ay, az: float64;
                    nfloats: int32): int32 {.
  importc: "aowl_du_call_sret_p_v3", nodecl.}

# The pure arithmetic, from abi/aowlspt_visible.h.
proc cVisAlphaReset() {.importc: "aowl_vis_alpha_reset", nodecl.}
proc cVisAlphaPush(a: float64; ign: int32): int32 {.
  importc: "aowl_vis_alpha_push", nodecl.}
proc cVisAlphaOk(): int32 {.importc: "aowl_vis_alpha_ok", nodecl.}
proc cVisAlphaValue(): float64 {.importc: "aowl_vis_alpha_value", nodecl.}
proc cVisAlphaCount(): int32 {.importc: "aowl_vis_alpha_count", nodecl.}
proc cVisOnScreen(x0, y0, x1, y1: float64; sw, sh, known: int32): int32 {.
  importc: "aowl_vis_onscreen", nodecl.}
proc cVisDegenerate(w, h: float64): int32 {.
  importc: "aowl_vis_degenerate", nodecl.}
proc cVisScaleCollapsed(sx, sy: float64): int32 {.
  importc: "aowl_vis_scale_collapsed", nodecl.}
proc cVisAlphaInvisible(a: float64): int32 {.
  importc: "aowl_vis_alpha_invisible", nodecl.}

# THE BACK-BUFFER SIZE. `region.nim` is `include`d AFTER this file into the same
# translation unit, so its `#include "aowlspt_region.h"` has not been seen yet
# when this code is emitted. These are forward declarations of the three
# `static` functions that header defines -- a static forward declaration
# followed by a later static definition is ordinary C, and it is the reason the
# screen size here is the REAL published one rather than a hardcoded 1920x1080.
# `_known` is checked FIRST and separately every time: it is the only way to
# tell "not published yet" from "zero pixels wide", and a check that cannot tell
# those apart reports a node in the top-left corner as a finding.
{.emit: """
static int32_t aowl_region_screen_w(void);
static int32_t aowl_region_screen_h(void);
static int32_t aowl_region_screen_known(void);
""".}
proc cVisScrW(): int32 {.importc: "aowl_region_screen_w", nodecl.}
proc cVisScrH(): int32 {.importc: "aowl_region_screen_h", nodecl.}
proc cVisScrKnown(): int32 {.importc: "aowl_region_screen_known", nodecl.}

const
  VisMaxClimb = 24   ## ancestors walked for Canvas / CanvasGroup
  VisMaxRoots = 24   ## scene roots enumerated by `canvasorder`
  VisMaxKids  = 64   ## direct children of a root inspected by `canvasorder`

proc iVisSelfOk(p: Il2CppPtr): bool =
  ## THE GATE THAT MUST RUN BEFORE EVERY USE AS `this`, not once per walk.
  ## `duOk` proves the memory is mapped and the right size. `iUnityAlive`
  ## proves the NATIVE half is still there. A managed wrapper whose native half
  ## is gone -- Unity's "fake null" -- passes the first and fails the second,
  ## and calling an internal-call getter on one faults inside Unity's C++ where
  ## no guard of ours reaches.
  result = duOk(p, 0x20'i32) and iUnityAlive(p)

proc iVisFn(pattern: string; why: var string): Il2CppPtr =
  ## Resolve a managed target BY NAME, and say precisely which of the two ways
  ## it failed. "not resolvable" and "prologue verify FAILED" want completely
  ## different fixes, and reporting a wrong reason is worse than reporting none
  ## (fact #129).
  result = nil
  why = ""
  var idx = 0
  var hits = 0
  if not iFindTarget(pattern, idx, hits):
    why = "\"" & pattern & "\" is not a unique row of the verified-target " &
          "table on this build (see `targets`)"
    return
  let fn = iTargetFn(idx)
  if fn == nil:
    why = "\"" & pattern & "\" @0x" & iHexPad(iTargetRva(idx), 6) &
          " FAILED its 16-byte prologue verify -- refusing to call it"
    return
  result = fn

proc iVisBool(pattern: string; self: Il2CppPtr; val: var bool;
              why: var string): bool =
  ## Returns COULD-WE-LOOK. `val` is only meaningful when it returns true.
  val = false
  let fn = iVisFn(pattern, why)
  if fn == nil:
    return false
  if not iVisSelfOk(self):
    why = "the receiver for " & pattern & " is unreadable, or its native " &
          "half (m_CachedPtr) is null -- refusing to call"
    return false
  iMark(pattern & " [visible]", self)
  val = (cInspUP(fn, self, nil) and 1'u64) != 0'u64
  result = true

proc iVisI32(pattern: string; self: Il2CppPtr; val: var int;
             why: var string): bool =
  val = 0
  let fn = iVisFn(pattern, why)
  if fn == nil:
    return false
  if not iVisSelfOk(self):
    why = "the receiver for " & pattern & " is unreadable, or its native " &
          "half (m_CachedPtr) is null -- refusing to call"
    return false
  iMark(pattern & " [visible]", self)
  val = int(int32(uint32(cInspUP(fn, self, nil) and 0xFFFFFFFF'u64)))
  result = true

proc iVisPtr(pattern: string; self: Il2CppPtr; val: var Il2CppPtr;
             why: var string): bool =
  val = nil
  let fn = iVisFn(pattern, why)
  if fn == nil:
    return false
  if not iVisSelfOk(self):
    why = "the receiver for " & pattern & " is unreadable, or its native " &
          "half (m_CachedPtr) is null -- refusing to call"
    return false
  iMark(pattern & " [visible]", self)
  let p = cast[Il2CppPtr](cInspUP(fn, self, nil))
  if p != nil and not duOk(p, 0x20'i32):
    why = pattern & " returned 0x" & iHexPad(cast[uint64](p), 16) &
          ", which is not readable memory -- treating it as UNKNOWN rather " &
          "than as an object"
    return false
  val = p
  result = true

proc iVisF32(pattern: string; self: Il2CppPtr; val: var float64;
             why: var string): bool =
  val = 0.0
  let fn = iVisFn(pattern, why)
  if fn == nil:
    return false
  if not iVisSelfOk(self):
    why = "the receiver for " & pattern & " is unreadable, or its native " &
          "half (m_CachedPtr) is null -- refusing to call"
    return false
  iMark(pattern & " [visible]", self)
  val = float64(cInspFP(fn, self, nil))
  result = true

proc iVisSret(pattern: string; self: Il2CppPtr; nfloats: int32;
              why: var string): bool =
  ## A struct >8 bytes returned through the hidden buffer. Results land in the
  ## `cDuSret0_2..3_2` statics. Returns false -- and leaves them alone -- when
  ## the call produced a NaN or an absurd magnitude, because a garbage
  ## geometry number that still looks like a number is this whole file's
  ## reason for existing.
  let fn = iVisFn(pattern, why)
  if fn == nil:
    return false
  if not iVisSelfOk(self):
    why = "the receiver for " & pattern & " is unreadable, or its native " &
          "half (m_CachedPtr) is null -- refusing to call"
    return false
  iMark(pattern & " [visible]", self)
  if cDuCallSretP2(fn, self, nfloats) == 0'i32:
    why = pattern & " returned a non-finite or absurd value (NaN, or " &
          "|v| > 1e9) -- refusing to report a plausible-looking number"
    return false
  result = true

proc iVisComponent(target: Il2CppPtr; typeName: string; comp: var Il2CppPtr;
                   why: var string): bool =
  ## Returns COULD-WE-ASK. A `true` with `comp == nil` means the component is
  ## GENUINELY ABSENT -- an answer. A `false` means we could not look, and the
  ## caller must not treat that as absence.
  ##
  ## The overload is chosen from the receiver's KLASS, never assumed: both
  ## GameObject and Component carry `m_CachedPtr` at +0x10, so handing a
  ## GameObject to `Component::GetComponent` passes every gate and then faults
  ## inside Unity on a native type confusion (fact #68). `$comp` is deliberately
  ## NOT touched here -- a diagnostic verb must not leave a pressable anchor
  ## bound to something the operator did not ask for.
  comp = nil
  why = ""
  if not iVisSelfOk(target):
    why = "the receiver is unreadable, or its native half is null"
    return false
  # Same correction as `iGetComponentQuiet`: on this build the string
  # overload is declared by UnityEngine.Component ONLY, so a GameObject
  # receiver is converted to its Transform instead of being sent to
  # GetComponent(Type) with a String in RDX.
  var recv = target
  if iIsGameObject(target):
    let t = iTransformOfGameObject(target)
    if t == nil:
      why = "this is a GameObject and no Component receiver could be " &
            "obtained from it, so the string overload could not be asked"
      return false
    recv = t
  let overload = "Component::GetComponent(String)"
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet(overload, fn) or fn == nil:
    why = overload & " did not resolve or did not verify on this build"
    return false
  if cNavIcallReady() == 0'i32:
    why = "the UnityEngine.Component::GetComponent(System.String) icall is " &
          "NOT registered in this runtime, so the wrapper would take its " &
          "failure branch and RAISE inside the detour"
    return false
  var tn = typeName
  let sp = cNavNewString(toCString(tn))
  if sp == nil:
    why = "il2cpp_string_new returned null for \"" & typeName & "\""
    return false
  iMark(overload & " [visible " & typeName & "]", recv)
  let c = cast[Il2CppPtr](cInspUPP(fn, recv, sp, nil))
  if c != nil and not duOk(c, 0x20'i32):
    why = "GetComponent(\"" & typeName & "\") returned 0x" &
          iHexPad(cast[uint64](c), 16) & ", which is not readable memory"
    return false
  comp = c
  result = true

proc iVisFindGraphic(node: Il2CppPtr; comp: var Il2CppPtr; which: var string;
                     why: var string): bool =
  ## Unity's string overload matches by SHORT TYPE NAME, so there is no single
  ## name that finds every Graphic. Several are tried, most specific first, and
  ## the one that hit is reported -- so "no Graphic" is a statement about six
  ## attempted names rather than about one guess.
  comp = nil
  which = ""
  why = ""
  let names = @["TextMeshProUGUI", "Image", "RawImage", "Text",
                "MaskableGraphic", "Graphic"]
  var asked = 0
  var i = 0
  while i < names.len:
    var c: Il2CppPtr = nil
    var w = ""
    if iVisComponent(node, names[i], c, w):
      inc asked
      if c != nil:
        comp = c
        which = names[i]
        why = ""
        return true
    else:
      why = w
    inc i
  if asked == 0:
    # We never managed to ASK. That is INCONCLUSIVE, not "no Graphic".
    return false
  why = ""
  result = true

proc iVisParentOf(t: Il2CppPtr): Il2CppPtr =
  result = nil
  var why = ""
  let fn = iVisFn("Transform::get_parent", why)
  if fn == nil:
    return nil
  if not iVisSelfOk(t):
    return nil
  iMark("Transform::get_parent [visible]", t)
  let p = cast[Il2CppPtr](cInspUP(fn, t, nil))
  if p != nil and duOk(p, 0x20'i32):
    result = p

proc iVisNearestCanvas(node: Il2CppPtr; canvas: var Il2CppPtr;
                       depth: var int; why: var string): bool =
  ## The nearest enabled-or-not Canvas at or above `node`. Returns COULD-WE-LOOK.
  canvas = nil
  depth = -1
  why = ""
  var cur = iToTransform(node)
  var d = 0
  var asked = 0
  while cur != nil and d < VisMaxClimb:
    var c: Il2CppPtr = nil
    var w = ""
    if iVisComponent(cur, "Canvas", c, w):
      inc asked
      if c != nil:
        canvas = c
        depth = d
        return true
    else:
      why = w
    cur = iVisParentOf(cur)
    inc d
  if asked == 0:
    if why == "":
      why = "no ancestor could be asked for a Canvas"
    return false
  result = true

proc iVisRenderModeName(m: int): string =
  case m
  of 0: result = "ScreenSpaceOverlay"
  of 1: result = "ScreenSpaceCamera"
  of 2: result = "WorldSpace"
  else: result = "NOT a render mode -- this is probably not a Canvas"

# ---------------------------------------------------------------------------
# screenrect
# ---------------------------------------------------------------------------

proc iVisScreenRect(node: Il2CppPtr; x0, y0, x1, y1: var float64;
                    modeOut: var int; note: var string): bool =
  ## Local rect corners -> WORLD via `Transform::TransformPoint` -> PIXELS.
  ##
  ## For a ScreenSpaceOverlay canvas a world unit IS a back-buffer pixel, so
  ## the world point is already the answer -- that is a property of overlay
  ## canvases, not an approximation. For ScreenSpaceCamera / WorldSpace the
  ## world point must go through `Camera::WorldToScreenPoint`, and if there is
  ## no `Camera.main` the honest answer is that we could not look.
  ##
  ## Unity screen space has its ORIGIN AT THE BOTTOM-LEFT, y up. Everything
  ## printed by these verbs is in that space and says so.
  x0 = 0.0; y0 = 0.0; x1 = 0.0; y1 = 0.0
  modeOut = -1
  note = ""
  let t = iToTransform(node)
  if not iVisSelfOk(t):
    note = "the node's Transform is unreadable or its native half is null"
    return false
  var why = ""
  if not iVisSret("RectTransform::get_rect", t, 4'i32, why):
    note = "get_rect: " & why & ". (A plain Transform is not a " &
           "RectTransform and genuinely has no rect -- the outermost menu " &
           "roots are plain Transforms.)"
    return false
  let rx = cDuSret0_2()
  let ry = cDuSret1_2()
  let rw = cDuSret2_2()
  let rh = cDuSret3_2()

  let fnTp = iVisFn("Transform::TransformPoint(Vector3)", why)
  if fnTp == nil:
    note = "TransformPoint: " & why
    return false
  if not iVisSelfOk(t):
    note = "the node's native half went away between get_rect and " &
           "TransformPoint -- re-checked before each use, which is why this " &
           "is a refusal and not a fault"
    return false
  iMark("Transform::TransformPoint [lower-left]", t)
  if cDuCallSretPV3(fnTp, t, rx, ry, 0.0, 3'i32) == 0'i32:
    note = "TransformPoint on the lower-left corner returned a non-finite " &
           "or absurd value"
    return false
  let wlx = cDuSret0_2()
  let wly = cDuSret1_2()
  let wlz = cDuSret2_2()
  if not iVisSelfOk(t):
    note = "the node's native half went away mid-walk"
    return false
  iMark("Transform::TransformPoint [upper-right]", t)
  if cDuCallSretPV3(fnTp, t, rx + rw, ry + rh, 0.0, 3'i32) == 0'i32:
    note = "TransformPoint on the upper-right corner returned a non-finite " &
           "or absurd value"
    return false
  let wux = cDuSret0_2()
  let wuy = cDuSret1_2()
  let wuz = cDuSret2_2()

  # Which space are those world points in? That is the CANVAS's question.
  var canvas: Il2CppPtr = nil
  var depth = 0
  var w2 = ""
  if not iVisNearestCanvas(node, canvas, depth, w2):
    note = "could not determine the Canvas above this node (" & w2 &
           "), so a world point cannot be turned into pixels"
    return false
  if canvas == nil:
    note = "there is NO Canvas at or above this node within " &
           $VisMaxClimb & " ancestors. A UI graphic with no canvas draws " &
           "nothing at all, and there is no pixel rect to compute."
    return false
  var mode = 0
  if not iVisI32("Canvas::get_renderMode", canvas, mode, w2):
    note = "Canvas::get_renderMode: " & w2
    return false
  modeOut = mode

  if mode == 0:
    # Overlay: world units ARE back-buffer pixels.
    x0 = wlx; y0 = wly; x1 = wux; y1 = wuy
    note = "ScreenSpaceOverlay -- world units are back-buffer pixels, so " &
           "these ARE the pixels (no camera projection involved)."
    return true

  # Camera or world space: project.
  let fnCam = iVisFn("Camera::get_main", w2)
  if fnCam == nil:
    note = "render mode is " & iVisRenderModeName(mode) & ", which needs a " &
           "camera projection, and Camera::get_main: " & w2
    return false
  iMark("Camera::get_main [visible]", nil)
  let cam = cast[Il2CppPtr](cInspUV(fnCam, nil))
  if cam == nil or not iVisSelfOk(cam):
    note = "render mode is " & iVisRenderModeName(mode) & ", which needs a " &
           "camera projection, but Camera.main is null or not live right " &
           "now. This is UNKNOWN, not off-screen."
    return false
  let fnW2S = iVisFn("Camera::WorldToScreenPoint(Vector3)", w2)
  if fnW2S == nil:
    note = "Camera::WorldToScreenPoint: " & w2
    return false
  iMark("Camera::WorldToScreenPoint [lower-left]", cam)
  if cDuCallSretPV3(fnW2S, cam, wlx, wly, wlz, 3'i32) == 0'i32:
    note = "WorldToScreenPoint on the lower-left corner returned a " &
           "non-finite value -- the projection matrix was probably not ready"
    return false
  x0 = cDuSret0_2(); y0 = cDuSret1_2()
  let z0 = cDuSret2_2()
  if not iVisSelfOk(cam):
    note = "the camera's native half went away mid-projection"
    return false
  iMark("Camera::WorldToScreenPoint [upper-right]", cam)
  if cDuCallSretPV3(fnW2S, cam, wux, wuy, wuz, 3'i32) == 0'i32:
    note = "WorldToScreenPoint on the upper-right corner returned a " &
           "non-finite value"
    return false
  x1 = cDuSret0_2(); y1 = cDuSret1_2()
  let z1 = cDuSret2_2()
  if z0 <= 0.0 and z1 <= 0.0:
    note = iVisRenderModeName(mode) & " -- BOTH corners have z <= 0, i.e. " &
           "they are BEHIND the camera. x/y are still finite and are " &
           "MEANINGLESS; nothing draws."
    return true
  note = iVisRenderModeName(mode) & " -- projected through Camera.main " &
         "(z = " & iFmtF(z0) & " .. " & iFmtF(z1) & "; z <= 0 is behind the " &
         "camera)."
  result = true

proc iCmdScreenRect(toks: seq[string]) =
  ## `screenrect EXPR` -- where this node actually lands on the back buffer.
  if toks.len < 2:
    iErr("usage: screenrect EXPR")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  let p = cast[Il2CppPtr](v)
  if not iVisSelfOk(p):
    iErr("not readable, or its native half is null; refusing to call.")
    return
  var x0 = 0.0
  var y0 = 0.0
  var x1 = 0.0
  var y1 = 0.0
  var mode = -1
  var note = ""
  if not iVisScreenRect(p, x0, y0, x1, y1, mode, note):
    iOut("  screenrect: INCONCLUSIVE -- " & note)
    return
  iOut("  " & note)
  iOut("  pixel corners (origin BOTTOM-LEFT, y up):")
  iOut("    lower-left  = (" & iFmtF(x0) & ", " & iFmtF(y0) & ")")
  iOut("    upper-right = (" & iFmtF(x1) & ", " & iFmtF(y1) & ")")
  var w = x1 - x0
  var h = y1 - y0
  if w < 0.0: w = -w
  if h < 0.0: h = -h
  iOut("    size        = " & iFmtF(w) & " x " & iFmtF(h) & " px")
  let known = cVisScrKnown()
  let sw = cVisScrW()
  let sh = cVisScrH()
  if known == 0'i32:
    iOut("  back buffer: SIZE NOT PUBLISHED YET (aowl_region_screen_known " &
         "= 0). On-screen-ness is INCONCLUSIVE -- it is NOT off-screen. " &
         "A hardcoded or zero size here is how a layout silently collapses " &
         "into the top-left corner.")
  else:
    iOut("  back buffer: " & $int(sw) & " x " & $int(sh) & " px (published)")
  let cls = int(cVisOnScreen(x0, y0, x1, y1, sw, sh, known))
  case cls
  of 2: iOut("  on screen:   YES, wholly inside the back buffer")
  of 1: iOut("  on screen:   PARTIALLY -- it crosses an edge")
  of 0: iOut("  on screen:   NO -- this rect does not touch the back buffer " &
             "at all. That alone is a complete explanation for seeing nothing.")
  else: iOut("  on screen:   INCONCLUSIVE -- the back-buffer size is not " &
             "known, or a corner was NaN/absurd. Not a 'no'.")
  let deg = int(cVisDegenerate(w, h))
  if deg == 1:
    iOut("  size:        DEGENERATE -- under half a pixel in one axis, so " &
         "it draws nothing whatever else is true of it.")
  elif deg < 0:
    iOut("  size:        INCONCLUSIVE (non-finite)")

# ---------------------------------------------------------------------------
# canvasorder
# ---------------------------------------------------------------------------

proc iVisReportCanvas(tag: string; canvas: Il2CppPtr) =
  var w = ""
  var order = 0
  var mode = 0
  var en = false
  var scale = 0.0
  var line = "  " & tag & " canvas=" & iPtr(canvas)
  if iVisI32("Canvas::get_sortingOrder", canvas, order, w):
    line = line & " sortingOrder=" & $order
  else:
    line = line & " sortingOrder=UNKNOWN"
  if iVisI32("Canvas::get_renderMode", canvas, mode, w):
    line = line & " mode=" & iVisRenderModeName(mode)
  else:
    line = line & " mode=UNKNOWN"
  if iVisBool("Behaviour::get_enabled", canvas, en, w):
    line = line & " enabled=" & (if en: "yes" else: "NO")
  else:
    line = line & " enabled=UNKNOWN"
  if iVisF32("Canvas::get_scaleFactor", canvas, scale, w):
    line = line & " scaleFactor=" & iFmtF(scale)
  iOut(line)

proc iCmdCanvasOrder(toks: seq[string]) =
  ## `canvasorder [EXPR]` -- which Canvas draws in front of which.
  ##
  ## TWO SCOPES, and it always states which one it used, because a census that
  ## quietly searched a subset is the shape of fact #129.
  ##   * with EXPR: every Canvas on that node's ANCESTOR CHAIN, nearest first.
  ##     Cheap, exact, and the one that answers "what am I actually drawing on".
  ##   * without: the scene ROOTS and their DIRECT CHILDREN only. That is a
  ##     deliberate SCOPE, not a complete census -- a Canvas deeper than one
  ##     level is not listed, and the summary says so. A full-tree scan would
  ##     cost a managed string allocation and a GetComponent call per node over
  ##     thousands of nodes, inside one frame.
  if toks.len >= 2:
    var v = 0'u64
    var err = ""
    if not iEval(toks[1], v, err):
      iErr(err)
      return
    let p = cast[Il2CppPtr](v)
    if not iVisSelfOk(p):
      iErr("not readable, or its native half is null; refusing to call.")
      return
    iOut("  scope: the ANCESTOR CHAIN of " & iPtr(p) & ", nearest first, " &
         "capped at " & $VisMaxClimb & " levels.")
    var cur = iToTransform(p)
    var d = 0
    var found = 0
    var asked = 0
    while cur != nil and d < VisMaxClimb:
      var c: Il2CppPtr = nil
      var w = ""
      if iVisComponent(cur, "Canvas", c, w):
        inc asked
        if c != nil:
          inc found
          iVisReportCanvas("depth=" & $d & " (" & iObjName(cur) & ")", c)
      cur = iVisParentOf(cur)
      inc d
    if asked == 0:
      iOut("  INCONCLUSIVE: not one ancestor could be asked for a Canvas.")
    elif found == 0:
      iOut("  answered by asking " & $asked & " ancestor(s): there is NO " &
           "Canvas above this node. A UI graphic with no Canvas draws nothing.")
    else:
      iOut("  " & $found & " Canvas(es) on the chain, from " & $asked &
           " ancestor(s) asked. The NEAREST enabled one is the one this " &
           "node draws on; a higher sortingOrder draws IN FRONT.")
    return

  var roots: seq[Il2CppPtr] = @[]
  let nroots = iSceneRoots(roots, true)
  if nroots == 0 or roots.len == 0:
    iOut("  canvasorder: INCONCLUSIVE -- NOT ONE scene root was enumerated " &
         "(see `roots`), so nothing was examined. That is 'I could not " &
         "look', not 'there are no canvases'.")
    return
  var nodes = 0
  var found = 0
  var asked = 0
  var truncated = false
  for i in 0 ..< roots.len:
    if i >= VisMaxRoots:
      truncated = true
      break
    # `iSceneRoots` hands back GAMEOBJECTS. The child walkers take
    # TRANSFORMS, and feeding one a GameObject reads a plausible childCount
    # and invents a hierarchy of wrong children WITHOUT faulting -- so the
    # conversion is explicit and klass-driven, never assumed.
    let rgo = roots[i]
    if iVisSelfOk(rgo):
      let r = (if iIsGameObject(rgo): iTransformOfGameObject(rgo)
               else: iToTransform(rgo))
      if r != nil and iVisSelfOk(r):
        var c: Il2CppPtr = nil
        var w = ""
        inc nodes
        if iVisComponent(r, "Canvas", c, w):
          inc asked
          if c != nil:
            inc found
            iVisReportCanvas("root '" & iObjName(r) & "'", c)
        var n = 0
        if iChildCount(r, n):
          var k = 0
          while k < n and k < VisMaxKids:
            let ch = iChildAt(r, k)
            inc k
            if ch != nil and iVisSelfOk(ch):
              inc nodes
              var c2: Il2CppPtr = nil
              var w2 = ""
              if iVisComponent(ch, "Canvas", c2, w2):
                inc asked
                if c2 != nil:
                  inc found
                  iVisReportCanvas("  '" & iObjName(r) & "'/'" &
                                   iObjName(ch) & "'", c2)
          if n > VisMaxKids:
            truncated = true
  iOut("  scope: scene ROOTS and their DIRECT CHILDREN only -- " & $nodes &
       " node(s) examined, " & $asked & " asked successfully, " & $found &
       " Canvas(es) found." &
       (if truncated: " TRUNCATED by a cap: a Canvas beyond it is NOT listed."
        else: ""))
  iOut("  This is a SCOPE, not a census. A Canvas nested deeper than one " &
       "level below a scene root will not appear here, and its absence from " &
       "this list is NOT evidence it does not exist. Use `canvasorder EXPR` " &
       "for the exact chain above a node.")
  if found > 0:
    iOut("  Higher sortingOrder draws IN FRONT. If your Canvas is listed " &
         "with a LOWER order than the game's, that is why your thing is " &
         "behind it -- and it is the one visibility factor `visible` cannot " &
         "settle on its own.")

# ---------------------------------------------------------------------------
# visible
# ---------------------------------------------------------------------------

proc iVisEval(p: Il2CppPtr; verbose: bool): int =
  ## The measurement behind `visible`, factored out so `visible` (verbose) and
  ## `pressname` (silent) share ONE implementation and CANNOT DRIFT -- the only
  ## difference is whether each factor line is printed. Returns a THREE-STATE
  ## verdict, never two: 1 = VISIBLE, 0 = NOT VISIBLE (a factor was MEASURED to
  ## kill it), -1 = INCONCLUSIVE (a factor could not be read). "Could not look"
  ## is never a yes.
  ##
  ## The factors are evaluated in the order the renderer would kill them, and
  ## the FIRST definite killer wins the verdict. A factor that could not be
  ## read does not become a killer and does not become a pass -- it downgrades
  ## the verdict to INCONCLUSIVE and is named.
  template vo(s: string) =
    if verbose: iOut(s)
  if not iVisSelfOk(p):
    if verbose:
      iErr("not readable, or its native half is null; refusing to call. " &
           "That is itself an answer: a destroyed Unity wrapper draws nothing.")
    return -1

  var killer = ""      ## the first DEFINITE reason it is not visible
  var unknowns: seq[string] = @[]
  var w = ""

  vo("  node = " & iPtr(p) & "  '" & iObjName(p) & "'")

  # 1. activeInHierarchy.
  var actNote = ""
  let (actOk, active) = iActiveInHierarchyChecked(p, actNote)
  if not actOk:
    unknowns.add ((if actNote.len > 0: actNote & "  " else: "") &
                 "activeInHierarchy could not be read (Component::" &
                 "get_gameObject / GameObject::get_activeInHierarchy did not " &
                 "resolve, or a hop was unreadable)")
    vo("  activeInHierarchy : UNKNOWN")
  else:
    vo("  activeInHierarchy : " & (if active: "yes" else: "NO"))
    if not active and killer == "":
      killer = "the GameObject is INACTIVE in the hierarchy. Nothing under " &
               "an inactive object renders, and it is not pressable either " &
               "(fact #72 -- a press returns success and does nothing)."

  # 2. The Graphic, its enabled flag and its colour alpha.
  var graphic: Il2CppPtr = nil
  var gname = ""
  if not iVisFindGraphic(p, graphic, gname, w):
    unknowns.add ("whether this node has a Graphic could not be determined (" &
                 w & ")")
    vo("  graphic           : UNKNOWN")
  elif graphic == nil:
    vo("  graphic           : none (asked for TextMeshProUGUI, Image, " &
       "RawImage, Text, MaskableGraphic, Graphic). This node draws " &
       "nothing ITSELF -- it may still be a container whose CHILDREN draw.")
  else:
    vo("  graphic           : " & gname & " @" & iPtr(graphic))
    var gEn = false
    if iVisBool("Behaviour::get_enabled", graphic, gEn, w):
      vo("  graphic.enabled   : " & (if gEn: "yes" else: "NO"))
      if not gEn and killer == "":
        killer = "the " & gname & " component is DISABLED. The object is " &
                 "there, the rect is there, and the renderer skips it."
    else:
      unknowns.add ("Graphic.enabled: " & w)
      vo("  graphic.enabled   : UNKNOWN")
    if iVisSret("UI.Graphic::get_color", graphic, 4'i32, w):
      let ca = cDuSret3_2()
      vo("  graphic.color     : rgba(" & iFmtF(cDuSret0_2()) & ", " &
         iFmtF(cDuSret1_2()) & ", " & iFmtF(cDuSret2_2()) & ", " &
         iFmtF(ca) & ")")
      let inv = int(cVisAlphaInvisible(ca))
      if inv == 1 and killer == "":
        killer = "the Graphic's own colour alpha is " & iFmtF(ca) &
                 " -- below 1/255, so nothing survives an 8-bit blend."
      elif inv < 0:
        unknowns.add ("the Graphic's colour alpha was not a finite number")
    else:
      unknowns.add ("Graphic.color: " & w)
      vo("  graphic.color     : UNKNOWN")

  # 3. The CanvasGroup alpha chain, folded with `ignoreParentGroups` honoured.
  cVisAlphaReset()
  var cur = iToTransform(p)
  var d = 0
  var groupsAsked = 0
  var chainBroken = false
  while cur != nil and d < VisMaxClimb:
    var cg: Il2CppPtr = nil
    var w2 = ""
    if not iVisComponent(cur, "CanvasGroup", cg, w2):
      chainBroken = true
      unknowns.add ("a CanvasGroup lookup " & $d & " level(s) up failed (" &
                   w2 & "), so the alpha chain is incomplete")
      break
    inc groupsAsked
    if cg != nil:
      var a = 0.0
      var ign = false
      if not iVisF32("CanvasGroup::get_alpha", cg, a, w2):
        chainBroken = true
        unknowns.add ("CanvasGroup.alpha " & $d & " level(s) up: " & w2)
        break
      if not iVisBool("CanvasGroup::get_ignoreParentGroups", cg, ign, w2):
        # Not knowing this is NOT a small gap: it decides whether ancestors
        # count at all, so folding on regardless would produce a confident
        # wrong number.
        chainBroken = true
        unknowns.add ("CanvasGroup.ignoreParentGroups " & $d &
                     " level(s) up: " & w2 & " -- without it the fold would " &
                     "be a guess, so it stopped here")
        break
      vo("  canvasGroup       : depth=" & $d & " alpha=" & iFmtF(a) &
         (if ign: " ignoreParentGroups=YES (chain ends here)" else: ""))
      if cVisAlphaPush(a, (if ign: 1'i32 else: 0'i32)) != 0'i32:
        break
    cur = iVisParentOf(cur)
    inc d
  if groupsAsked == 0 and chainBroken:
    vo("  canvasGroup alpha : UNKNOWN")
  elif cVisAlphaOk() == 0'i32:
    unknowns.add ("a CanvasGroup returned an alpha that is not a usable " &
                 "number, so the folded alpha is UNKNOWN")
    vo("  canvasGroup alpha : UNKNOWN (a group returned an unusable value)")
  else:
    let fa = cVisAlphaValue()
    vo("  canvasGroup alpha : " & iFmtF(fa) & "  (from " &
       $int(cVisAlphaCount()) & " group(s)" &
       (if chainBroken: ", chain INCOMPLETE" else: "") & ")")
    if not chainBroken and int(cVisAlphaInvisible(fa)) == 1 and killer == "":
      killer = "a CanvasGroup above this node folds the alpha to " &
               iFmtF(fa) & ". The object is built, positioned and enabled, " &
               "and it is fully transparent."

  # 4. The Canvas it draws on.
  var canvas: Il2CppPtr = nil
  var cdepth = 0
  if not iVisNearestCanvas(p, canvas, cdepth, w):
    unknowns.add ("the Canvas above this node could not be determined (" & w & ")")
    vo("  canvas            : UNKNOWN")
  elif canvas == nil:
    vo("  canvas            : NONE within " & $VisMaxClimb & " ancestors")
    if killer == "":
      killer = "there is NO Canvas at or above this node. A UI graphic " &
               "with no Canvas is never submitted to the renderer at all."
  else:
    if verbose: iVisReportCanvas("canvas            : depth=" & $cdepth, canvas)
    var cEn = false
    if iVisBool("Behaviour::get_enabled", canvas, cEn, w):
      if not cEn and killer == "":
        killer = "the Canvas this node draws on is DISABLED. This is the " &
                 "single most common reason a correctly built, correctly " &
                 "parented clone never appears -- Object::Instantiate copies " &
                 "a nested Canvas onto the clone, and disabling it is also " &
                 "how the overlay makes a clone fall through to its parent."
    else:
      unknowns.add ("Canvas.enabled: " & w)

  # 5. Scale.
  if iVisSret("Transform::get_lossyScale", iToTransform(p), 3'i32, w):
    let sx = cDuSret0_2()
    let sy = cDuSret1_2()
    vo("  lossyScale        : (" & iFmtF(sx) & ", " & iFmtF(sy) & ", " &
       iFmtF(cDuSret2_2()) & ")")
    let sc = int(cVisScaleCollapsed(sx, sy))
    if sc == 1 and killer == "":
      killer = "the world (lossy) scale is collapsed to zero in x or y, so " &
               "the node occupies no pixels however big its rect is."
    elif sc < 0:
      unknowns.add ("the lossy scale was not a finite number")
  else:
    unknowns.add ("Transform.lossyScale: " & w)
    vo("  lossyScale        : UNKNOWN")

  # 6. The pixel rect.
  var x0 = 0.0
  var y0 = 0.0
  var x1 = 0.0
  var y1 = 0.0
  var mode = -1
  var note = ""
  if not iVisScreenRect(p, x0, y0, x1, y1, mode, note):
    unknowns.add ("the screen rect could not be computed (" & note & ")")
    vo("  screen rect       : UNKNOWN -- " & note)
  else:
    var rw = x1 - x0
    var rh = y1 - y0
    if rw < 0.0: rw = -rw
    if rh < 0.0: rh = -rh
    let known = cVisScrKnown()
    vo("  screen rect       : (" & iFmtF(x0) & ", " & iFmtF(y0) & ") .. (" &
       iFmtF(x1) & ", " & iFmtF(y1) & ")  = " & iFmtF(rw) & " x " &
       iFmtF(rh) & " px   [" & note & "]")
    let deg = int(cVisDegenerate(rw, rh))
    if deg == 1 and killer == "":
      killer = "the rect is DEGENERATE on screen -- " & iFmtF(rw) & " x " &
               iFmtF(rh) & " px, under half a pixel in one axis. A " &
               "zero-size RectTransform was one of the invisible layers in " &
               "the version-label saga."
    elif deg < 0:
      unknowns.add ("the screen rect size was not a finite number")
    if known == 0'i32:
      unknowns.add ("the back-buffer size has not been published " &
                   "(aowl_region_screen_known = 0), so on-screen-ness is " &
                   "UNKNOWN -- explicitly NOT 'off screen'")
      vo("  on screen         : UNKNOWN (back-buffer size not published)")
    else:
      let cls = int(cVisOnScreen(x0, y0, x1, y1, cVisScrW(), cVisScrH(), known))
      case cls
      of 2: vo("  on screen         : YES (" & $int(cVisScrW()) & "x" &
               $int(cVisScrH()) & " back buffer)")
      of 1: vo("  on screen         : PARTIALLY -- crosses an edge")
      of 0:
        vo("  on screen         : NO -- outside the " & $int(cVisScrW()) &
           "x" & $int(cVisScrH()) & " back buffer")
        if killer == "":
          killer = "the node's pixel rect lies entirely OFF the back " &
                   "buffer. Everything about it is correct except where it is."
      else:
        unknowns.add ("on-screen-ness was INCONCLUSIVE (a corner was not a " &
                     "finite number)")

  # ---- the verdict -------------------------------------------------------
  vo("")
  if killer != "":
    vo("  VERDICT: NOT VISIBLE.")
    vo("  CAUSE:   " & killer)
    if unknowns.len > 0:
      vo("  (Also " & $unknowns.len & " factor(s) could not be read; the " &
         "cause above was MEASURED, so it stands regardless.)")
    return 0
  elif unknowns.len > 0:
    vo("  VERDICT: INCONCLUSIVE -- every factor that could be read passed, " &
       "and " & $unknowns.len & " could NOT be read. This is not a 'yes'.")
    var i = 0
    while i < unknowns.len and i < 8:
      vo("    - " & unknowns[i])
      inc i
    if unknowns.len > 8:
      vo("    - ... and " & $(unknowns.len - 8) & " more")
    return -1
  else:
    vo("  VERDICT: VISIBLE as far as this node's own state goes -- active, " &
       "graphic enabled, opaque, on an enabled Canvas, non-degenerate, and " &
       "on the back buffer.")
    vo("  NOT PROVEN: whether something DRAWS OVER IT. Occlusion is a " &
       "question about other Canvases' sortingOrder and about siblings " &
       "later in the draw order, and no field read on this node can " &
       "settle it. Run `canvasorder` and compare.")
    return 1

proc iCmdVisible(toks: seq[string]) =
  ## `visible EXPR` -- the composite answer, with a VERDICT and the factor that
  ## produced it. Delegates the measurement to `iVisEval` in verbose mode, so it
  ## and `pressname` can never disagree.
  if toks.len < 2:
    iErr("usage: visible EXPR")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  discard iVisEval(cast[Il2CppPtr](v), true)

# ---------------------------------------------------------------------------
# pressname -- the atomic find -> visible-filter -> component -> press.
# ---------------------------------------------------------------------------
const
  PressNameMaxHits = 48
    ## Cap on name matches collected. A name that matches this many nodes is
    ## too ambiguous to be a press target anyway; the verdict will refuse.
  PressNameBudget = 200000
    ## NODE BUDGET FOR THE WHOLE (now multi-frame) SEARCH.
    ##
    ## It used to be `InspFindDefBudget` (20,000) spent in ONE 12ms slice, and
    ## that is smaller than the live scene: MEASURED, `pressname BackButton`
    ## with no root searched all 16 scene roots, STOPPED EARLY at 20,000
    ## visited with a frontier of ~13k-15k, and reported "0 name match(es) ...
    ## INCONCLUSIVE" for a button that was on screen at the time. The verdict
    ## was honest; the search was simply too small to reach the answer, and
    ## there was no way to continue it.
    ## Now the walk resumes across frames until it is EXHAUSTIVE, so the budget
    ## only has to be bigger than the scene, not bigger than one frame.

# ---- the cross-frame walk state, exactly the shape `find` uses ----
var gPnQueue: seq[Il2CppPtr] = @[]
var gPnHead = 0
var gPnWant = ""
var gPnHits: seq[Il2CppPtr] = @[]
var gPnVisited = 0
var gPnSkips = 0
var gPnBudgetLeft = 0
var gPnFrames = 0
var gPnActive = false
var gPnOwnerIdx = -1
var gPnOwnerBatch = -1
var gPnRootDesc = ""
  ## `pressname` is ONE command that must park and re-enter, so its frontier
  ## has to outlive the frame exactly as `find`'s does. Deliberately its OWN
  ## state and not `find`'s: sharing would let a `find` in the same batch eat
  ## the press target's frontier, which is the class of bug that made the
  ## `find`/`findtext` split necessary in the first place.
  ##
  ## The ATOMICITY the old one-slice walk was defending is preserved where it
  ## matters: the visible-filter and the press still happen in ONE frame, on
  ## the finished hit list. Only the NAME SEARCH spans frames, and a node that
  ## died mid-search fails `duOk`/`iUnityAlive` at the visible check anyway.

proc iPressNameStep(): int =
  ## One FRAME's slice. Same two-budget contract as `iFindStep`: the time slice
  ## bounds the frame, the node budget bounds the whole search.
  let started = cNowMs()
  var spent = 0
  let w = gPnWant
  while gPnHead < gPnQueue.len:
    if gPnBudgetLeft <= 0:
      return FindOutOfBudget
    if gPnHits.len >= PressNameMaxHits:
      return FindEnoughHits
    if (spent and 127) == 0 and cNowMs() - started > InspFindSliceMs:
      return FindOutOfTime
    let cur = gPnQueue[gPnHead]
    inc gPnHead
    inc spent
    dec gPnBudgetLeft
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
      inc gPnSkips
      continue
    inc gPnVisited
    let nm = iObjName(cur)
    if nm.len > 0 and iContains(iLower(nm), w):
      gPnHits.add cur
    var n = 0
    if iChildCount(cur, n):
      var k = 0
      while k < n and k < InspMaxChildren:
        let c = iChildAt(cur, k)
        if c != nil:
          gPnQueue.add c
        inc k
  result = FindDone

proc iPressComponentAndFire(node: Il2CppPtr; why: var string): bool =
  ## Resolve `DefaultUIButton` on `node` (a Transform or component) and fire its
  ## OnClick at +0x120, exactly as `press` does -- read/validate the UnityEvent
  ## slot, then call UnityEvent::Invoke. Returns true iff it actually fired.
  ## Every failure names itself and returns false; nothing is ever blind-called.
  ##
  ## `why` IS NOT OPTIONAL, and that is the fix. MEASURED: `pressname` printed
  ## "the single VISIBLE candidate could not be pressed (see the line above)"
  ## and the line above could not be found in the out-file -- a FAIL verdict
  ## pointing at a reason that was not there. The caller now gets the reason as
  ## a VALUE and prints it ON THE SAME LINE as the verdict, so the two cannot be
  ## separated by buffering, truncation, or an intervening line.
  why = ""
  var comp: Il2CppPtr = nil
  var w = ""
  if not iVisComponent(node, "DefaultUIButton", comp, w):
    why = "GetComponent(DefaultUIButton) could not even be asked (" & w & ")"
    iErr(why & ". Nothing was pressed.")
    return false
  if comp == nil:
    # The node named right and is on screen, but the button component is not
    # on THIS node. Measured on SettingsScreen/BackButton: the caller then
    # succeeded by hand with `children` -> `component $cN DefaultUIButton`, so
    # "no DefaultUIButton here" must name the one thing that fixes it.
    why = "this node has NO DefaultUIButton component of its own (the button " &
          "may be on a CHILD -- `children` then `component $cN " &
          "DefaultUIButton` then `press $comp` is the manual route, and it " &
          "has worked on a node pressname refused)"
    iErr(why & ". Nothing was pressed.")
    return false
  let off = cNavOffOnClick()   ## 0x120 on this build (DefaultUIButton.OnClick)
  if not duOk(comp, off + 8'i32) or not iUnityAlive(comp):
    why = "the DefaultUIButton is not readable to +0x" &
          iHexPad(uint64(off), 3) & ", or its native half is null"
    iErr(why & ". Nothing was pressed.")
    return false
  let ev = cReadPtrAt(comp, off)
  var what = ""
  if duOk(comp, 0xC0'i32):
    let tp = cReadPtrAt(comp, 0xB8'i32)
    if tp != nil and not iIsKnownKlass(cast[uint64](tp)):
      what = suiReadString(tp)
  iOut("  DefaultUIButton = " & iPtr(comp) &
       (if what.len > 0: "   _text(+0xB8) = \"" & what & "\"" else: "") &
       "   OnClick(+0x" & iHexPad(uint64(off), 3) & ") = " & iPtr(ev))
  if ev == nil:
    why = "OnClick(+0x" & iHexPad(uint64(off), 3) & ") is NULL -- no handler " &
          "is wired to this button"
    iErr(why & ". Nothing was pressed.")
    return false
  if iIsGameObject(ev) or iIsKnownKlass(cast[uint64](ev)):
    why = "the OnClick slot holds a GameObject or a known klass pointer, not " &
          "a per-instance UnityEvent"
    iErr(why & ". Refusing to call it.")
    return false
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("UnityEvent::Invoke", fn, rva):
    why = "UnityEvent::Invoke did not byte-verify on this build"
    return false
  iMark("pressname: UnityEvent::Invoke", ev)
  discard cInspUP(fn, ev, nil)
  iOut("  pressed via UnityEngine.Events.UnityEvent::Invoke @0x" &
       iHexPad(uint64(rva), 6) & ". NOTE: that the handler returned is NOT " &
       "proof the intended effect happened -- confirm with `state`/`roots`.")
  result = true

proc iCmdPressName(toks: seq[string]) =
  ## `pressname NAME [ROOT]` -- find GameObjects named like NAME (under ROOT, or
  ## across every scene root), keep ONLY the ones whose `visible` verdict is
  ## VISIBLE, and press that one -- but ONLY if there is EXACTLY ONE. Zero,
  ## many, an incomplete search, or an unresolved button all REFUSE and say why.
  ## This collapses the find -> visible -> component -> press dance (fact #240)
  ## into one atomic, falsifiable step: the property it guarantees is "exactly
  ## one VISIBLE candidate was pressed, or nothing was".
  if toks.len < 2:
    iErr("usage: pressname NAME [ROOT]")
    return
  if not iNavGate("pressname"):
    return

  # ---- AUTOMATIC CONTINUATION, exactly as `find` does it ----
  # The name search now spans frames. Re-entering this command at the same
  # index RESUMES the frontier; restarting it would re-walk everything already
  # rejected and could never get past one frame's slice -- which is why the
  # old one-slice walk could report "0 name match(es) ... INCONCLUSIVE" for a
  # button that was on screen, with no way to continue.
  var resuming = false
  if gPnActive and gPnOwnerIdx == gInspCurIdx and gPnOwnerBatch == gInspBatch:
    resuming = true
    inc gPnFrames
  if not resuming:
    let want = toks[1]
    var roots: seq[Il2CppPtr] = @[]
    var rootDesc = ""
    if toks.len > 2:
      var rv = 0'u64
      var e = ""
      if not iEval(toks[2], rv, e):
        iErr(e)
        return
      let rp = iToTransform(cast[Il2CppPtr](rv))
      if rp == nil or not duOk(rp, 0x20'i32) or not iUnityAlive(rp):
        iErr("the ROOT \"" & toks[2] & "\" does not read back as a live " &
             "Transform; nothing was searched. (An unreadable ROOT is exactly " &
             "how a search reports a false 'not present'.)")
        return
      roots.add rp
      rootDesc = "from " & iPtr(rp) & " name=\"" & iObjName(rp) & "\""
    else:
      let n = iSceneRoots(roots, false)
      if n == 0:
        iErr("scene-root enumeration did not work on this build, so pressname " &
             "has nothing to search from. Pass an explicit ROOT. (INCONCLUSIVE)")
        return
      rootDesc = "ALL " & $n & " scene root(s)"
    gPnQueue = @[]
    for r in roots:
      if r != nil:
        gPnQueue.add r
    gPnHead = 0
    gPnWant = iLower(want)
    gPnHits = @[]
    gPnVisited = 0
    gPnSkips = 0
    gPnBudgetLeft = PressNameBudget
    gPnFrames = 1
    gPnActive = true
    gPnOwnerIdx = gInspCurIdx
    gPnOwnerBatch = gInspBatch
    gPnRootDesc = rootDesc
    iOut("  pressname \"" & want & "\": searching " & rootDesc &
         " (budget " & $PressNameBudget & " nodes, " &
         $int(InspFindSliceMs) & "ms per frame, continuing across frames " &
         "automatically until EXHAUSTIVE)")

  let st = iPressNameStep()
  if st == FindOutOfTime and gPnBudgetLeft > 0 and
     gPnFrames < InspFindMaxFrames:
    # Out of frame TIME, not out of permission: park and carry on next frame.
    # Silent by design -- a progress line every frame would bury the verdict.
    gFindSuspend = true
    return
  gPnActive = false
  gPnOwnerIdx = -1
  gPnOwnerBatch = -1
  let stopped = iFindStopReason(st, gPnBudgetLeft, gPnFrames)
  let exhaustive = (stopped == FindDone)
  var hits = gPnHits
  let nHits = hits.len
  iOut("  pressname \"" & gPnWant & "\": searched " & gPnRootDesc & ", " &
       $gPnVisited & " node(s) over " & $gPnFrames & " frame(s), frontier " &
       $(gPnQueue.len - gPnHead) & " node(s), found " & $nHits &
       " name match(es)" &
       (if exhaustive: " (search EXHAUSTIVE)"
        elif stopped == FindOutOfFrames:
          " (STOPPED EARLY on the FRAME CAP of " & $InspFindMaxFrames &
          " frames -- NOT the node budget, which still has " &
          $gPnBudgetLeft & " left)"
        elif stopped == FindEnoughHits:
          " (STOPPED EARLY at the match cap of " & $PressNameMaxHits & ")"
        else: " (STOPPED EARLY on the NODE BUDGET of " &
              $PressNameBudget & ")"))
  if nHits == 0:
    if exhaustive:
      iErr("FAIL: no GameObject named like \"" & gPnWant & "\" exists under " &
           "the searched roots. Nothing was pressed.")
    else:
      iErr("INCONCLUSIVE: no match found, but the search did not finish, so " &
           "absence is not proven. Narrow with a ROOT and retry. Nothing was " &
           "pressed.")
    return
  # Filter to the VISIBLE ones, reusing the SAME measurement `visible` prints.
  var visible: seq[Il2CppPtr] = @[]
  var inconclusive = 0
  var i = 0
  while i < hits.len:
    case iVisEval(hits[i], false)
    of 1: visible.add hits[i]
    of -1: inc inconclusive
    else: discard
    inc i
  iOut("  of those, VISIBLE=" & $visible.len & "  not-visible=" &
       $(hits.len - visible.len - inconclusive) & "  inconclusive=" &
       $inconclusive)
  if visible.len == 1:
    let node = visible[0]
    iOut("  pressing the single VISIBLE candidate " & iPtr(node) &
         " name=\"" & iObjName(node) & "\"")
    var why = ""
    if iPressComponentAndFire(node, why):
      iOut("  pressname: PASS -- exactly one VISIBLE candidate, pressed.")
    else:
      # THE REASON GOES ON THIS LINE. "see the line above" was a verdict
      # pointing at evidence that could not be found in the out-file at all.
      iOut("  pressname: FAIL -- the single VISIBLE candidate could not be " &
           "pressed: " &
           (if why.len > 0: why
            else: "NO REASON WAS RECORDED, which is itself a bug in this " &
                  "verb -- treat this as INCONCLUSIVE, not as 'unpressable'") &
           ". Nothing else was tried.")
    return
  if visible.len == 0:
    if inconclusive > 0:
      iErr("INCONCLUSIVE: no candidate proved VISIBLE, but " & $inconclusive &
           " could not be fully evaluated. Nothing was pressed.")
    else:
      iErr("FAIL: " & $hits.len & " name match(es), but NONE is visible " &
           "(inactive, off-screen, transparent, or on a disabled Canvas). An " &
           "inactive node is not pressable (fact #72). Nothing was pressed.")
    return
  iErr("REFUSED (ambiguous): " & $visible.len & " candidates are ALL VISIBLE, " &
       "so pressing one would be a guess. Narrow with a ROOT, or press the " &
       "specific one with `component`+`press`. Nothing was pressed.")

# ---------------------------------------------------------------------------
# CLICK RECORDER. Log what UI control a human just clicked, so a real
# play-through can be turned into a menu-navigation script.
#
# CAPTURE ROUTE: EventSystem.current.currentSelectedGameObject. On a left-mouse
# DOWN edge (detected with Win32 GetAsyncKeyState -- a native read, never an
# IL2CPP call), the input module selects the pressed Selectable, so the
# EventSystem's currentSelectedGameObject IS the clicked control for any
# selectable UI (which EFT buttons are). Reliability caveat, stated honestly: a
# click on a NON-selectable clickable, or on empty space, does not change the
# selection, so a `clickrec:` line then names the LAST selected control or says
# it had none -- it never invents one.
#
# SAFETY: armed OFF by default; only READS (no `allow write`); the whole body
# runs under the inspector's single SEH guard (body mode 2), never nested; the
# managed capture happens ONLY in a short window after a click edge, never on an
# idle frame; every hop is VirtualQuery/liveness-checked; and it self-disables
# after RecMaxFaults caught faults.
# ---------------------------------------------------------------------------
const
  RecMaxAncestors  = 32   ## cap on the parent-path walk
  RecCaptureFrames = 6    ## frames to look for the selection after a click edge
  RecMaxFaults     = 8    ## caught faults before the recorder disarms itself

var
  gRecOn      = false     ## armed by `record on`; read-only, persists across batches
  gRecPrevDown = false    ## previous frame's left-button state, for edge detect
  gRecPending  = 0        ## >0 while trying to capture after a click edge
  gRecFaults   = 0        ## caught faults; self-disable at RecMaxFaults

proc iRecCaption(node: Il2CppPtr): string =
  ## The EFT DefaultUIButton caption on `node`, if it has one: _text at +0xB8.
  result = ""
  var comp: Il2CppPtr = nil
  var w = ""
  if iVisComponent(node, "DefaultUIButton", comp, w) and comp != nil:
    if duOk(comp, 0xC0'i32):
      let tp = cReadPtrAt(comp, 0xB8'i32)
      if tp != nil and not iIsKnownKlass(cast[uint64](tp)):
        result = suiReadString(tp)

proc iRecReport(go: Il2CppPtr) =
  ## Emit exactly ONE `clickrec:` line to the host log for GameObject `go`:
  ## its name, full root->leaf transform path, the nearest DefaultUIButton
  ## caption at/above it, and the scene-root (screen) name. Uses okLog, not
  ## iOut, because the recorder runs OUTSIDE any batch and iOut's buffer is only
  ## flushed when a batch completes.
  let nm = iObjName(go)
  var chainNames: seq[string] = @[]
  var caption = ""
  var rootName = ""
  var cur = iTransformOfGameObject(go)
  var d = 0
  while cur != nil and d < RecMaxAncestors:
    let cn = iObjName(cur)
    chainNames.add cn
    rootName = cn
    if caption == "":
      let cap = iRecCaption(cur)
      if cap.len > 0: caption = cap
    cur = iVisParentOf(cur)
    inc d
  var path = ""
  var i = chainNames.len - 1
  while i >= 0:
    if path.len > 0: path.add "/"
    path.add chainNames[i]
    dec i
  okLog "clickrec: go=\"" & nm & "\"" &
        (if caption.len > 0: "  caption=\"" & caption & "\"" else: "") &
        "  screen=\"" & rootName & "\"  path=" & path

proc inspRecorderBody() =
  ## Body mode 2, run once per armed frame under the inspector's single SEH
  ## guard (never nested -- inspTick invokes it through the same cInspGuarded
  ## machinery as a command, sequentially). Native mouse read first; managed
  ## capture only inside the post-click window.
  let downNow = cRecLButtonDown() != 0'i32
  let edge = downNow and not gRecPrevDown
  gRecPrevDown = downNow
  if edge and gRecPending == 0:
    # A fresh click. The input module sets the selection in ITS Update, whose
    # order against ours is undefined, so allow a few frames for it to land
    # rather than reading a stale selection on the edge frame itself.
    gRecPending = RecCaptureFrames
  if gRecPending <= 0:
    return
  dec gRecPending
  let lastTry = gRecPending == 0
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet("EventSystem::get_current", fn) or fn == nil:
    if lastTry:
      okLog "clickrec: (EventSystem::get_current did not resolve/verify on " &
            "this build -- cannot name the clicked control)"
    return
  iMark("clickrec: EventSystem::get_current", nil)
  let es = cast[Il2CppPtr](cInspUV(fn, nil))   ## static getter: RCX = MethodInfo* (nil)
  if es == nil or not duOk(es, cNavOffCurSelected() + 8'i32) or
     not iUnityAlive(es):
    if lastTry:
      okLog "clickrec: (no active EventSystem, or it is not readable)"
    return
  let go = cReadPtrAt(es, cNavOffCurSelected())
  if go == nil or not duOk(go, 0x20'i32) or not iUnityAlive(go):
    if lastTry:
      okLog "clickrec: (click selected nothing -- a non-selectable control or " &
            "empty space)"
    return
  gRecPending = 0     ## captured; close the window so it emits exactly once
  iRecReport(go)

proc iCmdRecord(toks: seq[string]) =
  ## `record on` / `record off` -- arm or disarm the click recorder. Read-only,
  ## so it needs `liveInspector` but NOT `liveInspectorWrite`.
  if toks.len < 2 or (iLower(toks[1]) != "on" and iLower(toks[1]) != "off"):
    iOut("  usage: record on | record off   (currently " &
         (if gRecOn: "ON" else: "OFF") & ")")
    return
  if iLower(toks[1]) == "on":
    gRecOn = true
    gRecPrevDown = false
    gRecPending = 0
    iOut("  click recorder ARMED. Left-click UI controls in the client; each " &
         "click writes one `clickrec:` line to aowlspt-host.log. It only " &
         "READS. Route: EventSystem.currentSelectedGameObject (reliable for " &
         "selectable controls; a non-selectable click names the last selection).")
  else:
    gRecOn = false
    iOut("  click recorder DISARMED.")

# ---------------------------------------------------------------------------
# whydidntitdraw
# ---------------------------------------------------------------------------

proc iCmdWhyDidntItDraw(toks: seq[string]) =
  ## `whydidntitdraw EXPR` -- the guided chain: `visible`, then `screenrect`,
  ## then the Canvas chain, then ONE sentence naming the first failing
  ## condition. It runs the same code paths, so it cannot disagree with them.
  if toks.len < 2:
    iErr("usage: whydidntitdraw EXPR")
    return
  iOut("  == 1/3  visible ==")
  iCmdVisible(toks)
  iOut("")
  iOut("  == 2/3  screenrect ==")
  iCmdScreenRect(toks)
  iOut("")
  iOut("  == 3/3  canvasorder (ancestor chain) ==")
  iCmdCanvasOrder(toks)
  iOut("")
  iOut("  Read the VERDICT line in section 1. If it says NOT VISIBLE, the " &
       "CAUSE line beneath it is the first failing condition and the only " &
       "one worth fixing right now -- the later factors were still " &
       "evaluated, but a renderer stops at the first. If it says " &
       "INCONCLUSIVE, the listed factors are the ones to make readable " &
       "before drawing any conclusion; INCONCLUSIVE is not a 'no'. If it " &
       "says VISIBLE, this node's own state is not the problem: compare the " &
       "sortingOrder in section 3 against the game's own canvases, because " &
       "drawing BEHIND something is the one cause no field read on this " &
       "node can rule out.")

# ===========================================================================
# ASSERTIONS -- turning a batch from a transcript into a TEST
#
# Every assertion has THREE outcomes and reports one of exactly three prefixes:
#
#     PASS           the finished state was read, and it is what was claimed
#     FAIL           the finished state was read, and it is NOT what was claimed
#     INCONCLUSIVE   the state could NOT be read, so nothing was established
#
# INCONCLUSIVE is not a soft pass and is never folded into either of the other
# two. "I could not look" is the outcome this whole instrument exists to keep
# distinguishable (CLAUDE.md 9b), and an assertion verb that could only ever
# say PASS would be exactly the defect it is meant to catch. Concretely, each
# verb below is INCONCLUSIVE when the expression does not evaluate, when the
# memory is not readable, when the object is Unity-fake-null, or when the
# helper function it needs did not byte-verify on this build.
#
# The counters below are per BATCH, and a resumed batch keeps them -- the same
# rule the output buffer and `allow write` already follow, because a batch that
# parked on `until` is one test, not two.
# ===========================================================================
var gAssPass = 0
var gAssFail = 0
var gAssInc = 0

proc iAssPass(msg: string) =
  inc gAssPass
  iOut("  PASS: " & msg)

proc iAssFail(msg: string) =
  inc gAssFail
  iOut("  FAIL: " & msg)

proc iAssInc(msg: string) =
  inc gAssInc
  iOut("  INCONCLUSIVE: " & msg &
       "  -- nothing was established; this is NOT a pass and NOT a failure.")

proc iAssRead(p: Il2CppPtr; t: string; raw: var uint64): bool =
  ## Raw little-endian read of exactly the type's width. Separate from
  ## `iReadTyped` on purpose: that one returns a HUMAN string (with the hex
  ## suffix, the `readable` note, the quotes), and comparing rendered text
  ## would make `assert X i32 == 5` depend on formatting rather than on the
  ## value. Returns false for "could not look", which the callers turn into
  ## INCONCLUSIVE rather than into a failure.
  raw = 0'u64
  let size = iTypeSize(t)
  if size < 0:
    return false
  var buf = default(array[8, uint8])
  iMark(("assert read " & t & " at " & iPtr(p)), p)
  if cInspReadBytes(p, 0'i32, size, cast[ptr uint8](addr buf[0])) == 0'i32:
    return false
  for i in 0 ..< int(size):
    raw = raw or (uint64(buf[i]) shl uint64(i * 8))
  result = true

proc iAssSigned(t: string; raw: uint64): int64 =
  ## Sign-extend by declared width, so `assert p i32 == -1` means what it says.
  case t
  of "i8": result = (if raw >= 0x80'u64: int64(raw) - 256'i64 else: int64(raw))
  of "i16": result = (if raw >= 0x8000'u64: int64(raw) - 65536'i64 else: int64(raw))
  of "i32": result = int64(int32(uint32(raw)))
  of "i64": result = cast[int64](raw)
  else: result = cast[int64](raw)

proc iAssIsSigned(t: string): bool =
  result = (t == "i8" or t == "i16" or t == "i32" or t == "i64")

proc iAssIsFloat(t: string): bool =
  result = (t == "f32" or t == "f64")

proc iAssFloatOf(t: string; raw: uint64): float64 =
  if t == "f32": float64(cInspBitsF32(uint32(raw))) else: cInspBitsF64(raw)

proc iAssCmpNum(op: string; a, b: float64; ok: var bool): bool =
  ## Returns false for "that is not an operator I know" (a REFUSAL, not a
  ## failure). Float equality uses a relative tolerance, because an exact `==`
  ## on a value that came out of a matrix multiply is a check that can only
  ## ever fail, which is the mirror image of a check that can only ever pass.
  ok = false
  result = true
  var d = a - b
  if d < 0.0: d = -d
  var mag = (if a < 0.0: -a else: a)
  let mb = (if b < 0.0: -b else: b)
  if mb > mag: mag = mb
  let tol = 0.000001 + mag * 0.000001
  case op
  of "==": ok = d <= tol
  of "!=": ok = d > tol
  of "<": ok = a < b
  of "<=": ok = a <= b
  of ">": ok = a > b
  of ">=": ok = a >= b
  else: result = false

proc iCmdAssert(toks: seq[string]) =
  ## `assert EXPR TYPE OP VALUE`
  ##   OP is == != < <= > >=  for every numeric type;
  ##   for `str` it is == != contains, compared against the REST of the line.
  if toks.len < 5:
    iErr("usage: assert EXPR TYPE OP VALUE   (OP: == != < <= > >= ; for " &
         "TYPE str also `contains`).  Nothing was asserted.")
    return
  let t = iLower(toks[2])
  let op = toks[3]
  if iTypeSize(t) < 0:
    iErr("assert: \"" & t & "\" is not a type this REPL knows, so no width " &
         "could be chosen and NOTHING was read. Nothing was asserted.")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iAssInc("assert " & toks[1] & ": the expression did not evaluate (" &
            err & ")")
    return
  let p = cast[Il2CppPtr](v)
  var raw = 0'u64
  if not iAssRead(p, t, raw):
    iAssInc("assert " & toks[1] & " " & t & ": " & iPtr(p) &
            " is not readable for " & $int(iTypeSize(t)) & " byte(s)")
    return
  # Everything below here HAS the finished state in hand, so from this point
  # the only two outcomes left are PASS and FAIL.
  if t == "str":
    var want = ""
    for i in 4 ..< toks.len:
      if i > 4: want.add ' '
      want.add toks[i]
    if raw == 0'u64:
      # A null String* is a real, readable answer: the field IS null.
      let hit = (op == "!=")
      if hit: iAssPass("the String* at " & iPtr(p) & " is NULL, and != \"" &
                       want & "\"")
      else: iAssFail("the String* at " & iPtr(p) & " is NULL; expected " & op &
                     " \"" & want & "\"")
      return
    let got = suiReadString(cast[Il2CppPtr](raw))
    var ok = false
    case op
    of "==": ok = (got == want)
    of "!=": ok = (got != want)
    of "contains": ok = iContains(got, want)
    else:
      iErr("assert: \"" & op & "\" is not an operator for TYPE str (use == " &
           "!= contains). Nothing was asserted.")
      return
    if ok:
      iAssPass("string at " & iPtr(p) & " = \"" & got & "\"  " & op & "  \"" &
               want & "\"")
    else:
      iAssFail("string at " & iPtr(p) & " = \"" & got & "\"  which is NOT " &
               op & " \"" & want & "\"")
    return
  # Numeric / pointer / bool.
  var wantTok = toks[4]
  var got = 0.0
  var wantV = 0.0
  if iAssIsFloat(t):
    got = iAssFloatOf(t, raw)
    if not iParseF(wantTok, wantV):
      iErr("assert: \"" & wantTok & "\" is not a number. Nothing was asserted.")
      return
  elif t == "bool":
    got = (if (raw and 1'u64) != 0'u64: 1.0 else: 0.0)
    let w = iLower(wantTok)
    if w == "true": wantV = 1.0
    elif w == "false": wantV = 0.0
    else:
      var wu = 0'u64
      if not iParseU(wantTok, wu):
        iErr("assert: \"" & wantTok & "\" is not true/false or a number. " &
             "Nothing was asserted.")
        return
      wantV = (if wu != 0'u64: 1.0 else: 0.0)
  elif iAssIsSigned(t):
    got = float64(iAssSigned(t, raw))
    var neg = false
    var tok2 = wantTok
    if tok2.len > 0 and tok2[0] == '-':
      neg = true
      var rest = ""
      for k in 1 ..< tok2.len: rest.add tok2[k]
      tok2 = rest
    var wu = 0'u64
    if not iParseU(tok2, wu):
      iErr("assert: \"" & wantTok & "\" is not an integer. Nothing was asserted.")
      return
    wantV = (if neg: -float64(wu) else: float64(wu))
  else:
    got = float64(raw)
    var wu = 0'u64
    if not iParseU(wantTok, wu):
      iErr("assert: \"" & wantTok & "\" is not an integer. Nothing was asserted.")
      return
    wantV = float64(wu)
  var ok = false
  if not iAssCmpNum(op, got, wantV, ok):
    iErr("assert: \"" & op & "\" is not an operator I know (== != < <= > >=). " &
         "Nothing was asserted.")
    return
  var shown = ""
  discard iReadTyped(p, t, shown)
  if ok:
    iAssPass(toks[1] & " as " & t & " = " & shown & "   " & op & " " & wantTok)
  else:
    iAssFail(toks[1] & " as " & t & " = " & shown & "   is NOT " & op & " " &
             wantTok)

proc iCmdAssertActive(toks: seq[string]) =
  ## `assert-active EXPR` / `assert-inactive EXPR`.
  ##
  ## Uses `GameObject::get_activeInHierarchy`, NOT `activeSelf`: fact #72 is
  ## that a press on a node under an inactive ancestor returns success and does
  ## nothing, so `activeSelf` would be a check that passes for an unpressable
  ## node. `iActiveInHierarchy` reports (ok, active), and ok=false is exactly
  ## the INCONCLUSIVE case -- the function did not verify on this build, or a
  ## hop was unreadable.
  let want = (iLower(toks[0]) != "assert-inactive")
  if toks.len < 2:
    iErr("usage: " & iLower(toks[0]) & " EXPR. Nothing was asserted.")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iAssInc(iLower(toks[0]) & " " & toks[1] & ": expression did not evaluate (" &
            err & ")")
    return
  let p = cast[Il2CppPtr](v)
  if not duOk(p, 0x20'i32):
    iAssInc(iLower(toks[0]) & " " & toks[1] & ": " & iPtr(p) &
            " is not readable, so its active state was never asked for")
    return
  if not iUnityAlive(p):
    iAssInc(iLower(toks[0]) & " " & toks[1] & ": " & iPtr(p) &
            " is readable but Unity-FAKE-NULL (native half destroyed), so " &
            "asking it for activeInHierarchy would be a call into a dead object")
    return
  # LITERALLY the same proc `findtext`'s ACTIVE scope and HIT tag call, so the
  # two instruments cannot answer differently about the same pointer -- which
  # is the defect this replaced: a findtext HIT presented as pressable while
  # `assert-active` on the same card said activeInHierarchy=false.
  # SAY WHICH RECEIVER PATH WAS TAKEN. A GameObject pointer is a VALID input
  # here -- it used to fault (see `IActiveRecv`) -- and the reader deserves to
  # know that no Component hop happened.
  let recvLine = iActiveRecvLabel(p)
  if recvLine.len > 0:
    iOut(recvLine)
  var actNote = ""
  let (okq, act) = iActiveInHierarchyChecked(p, actNote)
  if not okq:
    iAssInc(iLower(toks[0]) & " " & toks[1] & ": activeInHierarchy could not " &
            "be determined (Component::get_gameObject or " &
            "GameObject::get_activeInHierarchy did not verify on this build, " &
            "a hop was unreadable, or the two derivations disagreed)" &
            (if actNote.len > 0: ".  " & actNote else: ""))
    return
  if act == want:
    iAssPass(toks[1] & " activeInHierarchy = " &
             (if act: "true" else: "false") & ", as claimed")
  else:
    iAssFail(toks[1] & " activeInHierarchy = " &
             (if act: "true" else: "false") & ", but " & iLower(toks[0]) &
             " claimed " & (if want: "true" else: "false") &
             (if act: "" else: ".  An INACTIVE node is NOT pressable: a press " &
              "on one reports success and does nothing (fact #72)."))

proc iCmdAssertPtr(toks: seq[string]) =
  ## `assert-null EXPR` / `assert-nonnull EXPR` / `assert-readable EXPR`.
  ##
  ## Deliberately three separate claims. `readable` is a claim about MEMORY;
  ## `nonnull` is a claim about the VALUE STORED at that address. They are
  ## different questions and conflating them is how "readability is liveness"
  ## keeps getting re-invented -- so `assert-nonnull` additionally reports
  ## Unity fake-null when the pointer is non-zero but its native half is gone,
  ## and calls that a FAIL, because a fake-null object is not a live one.
  let verb = iLower(toks[0])
  if toks.len < 2:
    iErr("usage: " & verb & " EXPR. Nothing was asserted.")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iAssInc(verb & " " & toks[1] & ": expression did not evaluate (" & err & ")")
    return
  let p = cast[Il2CppPtr](v)
  if verb == "assert-readable":
    if duOk(p, 8'i32):
      iAssPass(toks[1] & " = " & iPtr(p) & " is readable for 8 bytes. NOTE: " &
               "readable is NOT alive -- use assert-nonnull or assert-active " &
               "for that.")
    else:
      iAssFail(toks[1] & " = " & iPtr(p) &
               " is NOT committed/readable memory (VirtualQuery refused)")
    return
  var raw = 0'u64
  if not iAssRead(p, "ptr", raw):
    iAssInc(verb & " " & toks[1] & ": " & iPtr(p) & " is not readable for 8 " &
            "bytes, so the pointer stored there was never read")
    return
  if verb == "assert-null":
    if raw == 0'u64: iAssPass(toks[1] & " holds NULL, as claimed")
    else: iAssFail(toks[1] & " holds " & iPtrU(raw) & ", which is NOT null")
    return
  # assert-nonnull
  if raw == 0'u64:
    iAssFail(toks[1] & " holds NULL")
    return
  let q = cast[Il2CppPtr](raw)
  if not duOk(q, 0x20'i32):
    iAssFail(toks[1] & " holds " & iPtrU(raw) & ", which is non-zero but is " &
             "NOT readable memory -- a non-zero value is not an object.")
    return
  if not iUnityAlive(q):
    iAssFail(toks[1] & " holds " & iPtrU(raw) & ", readable, but Unity " &
             "FAKE-NULL: the managed wrapper is there and the native object " &
             "at +0x10 is gone. In C# this compares == null.")
    return
  iSetVar("_", raw)
  iAssPass(toks[1] & " holds " & iPtrU(raw) &
           ", readable and native-alive  ($_)")

proc iCmdAssertName(toks: seq[string]) =
  ## `assert-name EXPR SUBSTR` -- the object's GameObject name CONTAINS SUBSTR.
  ## Case-insensitive, matching `find`'s own predicate exactly, so the two
  ## cannot disagree about what "this node is called X" means.
  if toks.len < 3:
    iErr("usage: assert-name EXPR SUBSTR. Nothing was asserted.")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iAssInc("assert-name " & toks[1] & ": expression did not evaluate (" &
            err & ")")
    return
  let p = cast[Il2CppPtr](v)
  if not duOk(p, 0x20'i32) or not iUnityAlive(p):
    iAssInc("assert-name " & toks[1] & ": " & iPtr(p) & " is not readable, " &
            "or is Unity-fake-null; its name was never asked for")
    return
  let nm = iObjName(p)
  if nm.len == 0:
    # An EMPTY name is not an answer -- `Object::get_name` returning "" is
    # indistinguishable here from the call not having produced anything, and
    # the `label` verb's `text = ""` trap is exactly this shape.
    iAssInc("assert-name " & toks[1] & ": Object::get_name produced an EMPTY " &
            "string, which is indistinguishable from the name not having been " &
            "read at all")
    return
  if iContains(iLower(nm), iLower(toks[2])):
    iAssPass(toks[1] & " is named \"" & nm & "\", which contains \"" &
             toks[2] & "\"")
  else:
    iAssFail(toks[1] & " is named \"" & nm & "\", which does NOT contain \"" &
             toks[2] & "\"")

proc iCmdVerdict() =
  ## The machine-readable line. Emitted automatically at the end of any batch
  ## that ran an assertion, and available on demand mid-batch.
  ##
  ## The precedence is FAIL > INCONCLUSIVE > PASS, and INCONCLUSIVE is above
  ## PASS on purpose: a batch where two checks passed and one could not look
  ## has NOT demonstrated the property it was written to demonstrate.
  if gAssPass + gAssFail + gAssInc == 0:
    iOut("  ASSERTIONS: none ran in this batch. There is no verdict to give " &
         "-- that is not a pass.")
    return
  iOut("  ASSERTIONS: " & $gAssPass & " pass, " & $gAssFail & " fail, " &
       $gAssInc & " inconclusive")
  if gAssFail > 0:
    iOut("  BATCH VERDICT: FAIL")
  elif gAssInc > 0:
    iOut("  BATCH VERDICT: INCONCLUSIVE")
  else:
    iOut("  BATCH VERDICT: PASS")

# ===========================================================================
# NAVIGATION -- path, siblings
# ===========================================================================
const InspPathMax = 24

proc iCmdPath(toks: seq[string]) =
  ## `path EXPR` -- the full hierarchy path of a node, as one line.
  ##
  ## Three outcomes, because a path can be genuinely incomplete: the walk stops
  ## at a null parent (COMPLETE -- that is the hierarchy root), at an
  ## unreadable hop (INCOMPLETE, and it says which level), or at the depth cap
  ## (TRUNCATED). A path printed without that distinction reads as absolute
  ## when it may only be a suffix.
  if toks.len < 2:
    iErr("usage: path EXPR")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  var cur = cast[Il2CppPtr](v)
  if not duOk(cur, 0x20'i32):
    iErr("not readable at " & iPtr(cur) & "; no path was walked.")
    return
  if not iUnityAlive(cur):
    iErr("readable but Unity-FAKE-NULL at " & iPtr(cur) &
         " -- walking a destroyed object's parent chain is a call into a " &
         "dead object. No path was walked.")
    return
  var idx = 0
  var hits = 0
  var fnParent: Il2CppPtr = nil
  if iFindTarget("Transform::get_parent", idx, hits): fnParent = iTargetFn(idx)
  if fnParent == nil:
    iErr("Transform::get_parent did not byte-verify on this build; no path " &
         "could be walked. This is INCONCLUSIVE, not an empty path.")
    return
  cur = iToTransform(cur)
  var names: seq[string] = @[]
  var level = 0
  var status = 2   # 0 complete, 1 incomplete, 2 truncated
  while level < InspPathMax:
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
      status = 1
      break
    let nm = iObjName(cur)
    names.add (if nm.len > 0: nm else: "<unnamed " & iPtr(cur) & ">")
    iMark(("Transform::get_parent [path] on " & iPtr(cur)), cur)
    let par = cast[Il2CppPtr](cInspUP(fnParent, cur, nil))
    if par == nil:
      status = 0
      break
    cur = par
    inc level
  var line = ""
  var k = names.len - 1
  while k >= 0:
    line.add '/'
    line.add names[k]
    dec k
  if status == 0:
    iOut("  " & line)
    iOut("  -- COMPLETE: the walk reached a null parent, so this path is " &
         "absolute within its scene root.")
  elif status == 1:
    iOut("  ..." & line)
    iOut("  -- INCOMPLETE: the chain stopped at an unreadable or fake-null " &
         "ancestor after " & $names.len & " level(s). The leading `...` is " &
         "NOT decoration: the part above this is unknown.")
  else:
    iOut("  ..." & line)
    iOut("  -- TRUNCATED at the depth cap of " & $InspPathMax &
         " levels. The part above this was never walked.")

proc iCmdSiblings(toks: seq[string]) =
  ## `siblings EXPR` -- the node's parent's children, with THIS one marked.
  ## The point is sibling INDEX and neighbourhood, which is how nearly every
  ## row/tab/list control in this UI is actually identified.
  if toks.len < 2:
    iErr("usage: siblings EXPR")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iErr(err)
    return
  var me = cast[Il2CppPtr](v)
  if not duOk(me, 0x20'i32) or not iUnityAlive(me):
    iErr("not readable, or Unity-fake-null; no siblings were enumerated.")
    return
  me = iToTransform(me)
  var idx = 0
  var hits = 0
  var fnParent: Il2CppPtr = nil
  if iFindTarget("Transform::get_parent", idx, hits): fnParent = iTargetFn(idx)
  if fnParent == nil:
    iErr("Transform::get_parent did not byte-verify on this build; nothing " &
         "was enumerated. INCONCLUSIVE, not 'no siblings'.")
    return
  iMark(("Transform::get_parent [siblings] on " & iPtr(me)), me)
  let par = cast[Il2CppPtr](cInspUP(fnParent, me, nil))
  if par == nil:
    iOut("  this node has a NULL parent -- it is a hierarchy root, so it has " &
         "no siblings. That is an ANSWER, not a failure to look. Use `roots` " &
         "to see the other roots of its scene.")
    return
  if not duOk(par, 0x20'i32) or not iUnityAlive(par):
    iErr("the parent at " & iPtr(par) & " is not readable or is fake-null; " &
         "no siblings were enumerated.")
    return
  var n = 0
  if not iChildCount(par, n):
    iErr("the parent's childCount could not be read; no siblings were " &
         "enumerated. INCONCLUSIVE.")
    return
  iOut("  parent " & iPtr(par) & " \"" & iObjName(par) & "\" has " & $n &
       " child(ren)")
  var shown = 0
  var mine = -1
  var k = 0
  while k < n and k < InspMaxChildren:
    let c = iChildAt(par, k)
    if c != nil:
      iSetVar("s" & $k, cast[uint64](c))
      let isMe = (c == me)
      if isMe: mine = k
      var actNote = ""
      let (okq, act) = iActiveInHierarchyChecked(c, actNote)
      iOut("    [" & $k & "] " & iPtr(c) & " \"" & iObjName(c) & "\"  " &
           (if okq: (if act: "active" else: "INACTIVE")
            else: "active=UNKNOWN") &
           (if actNote.len > 0: "  [" & actNote & "]" else: "") &
           "   ($s" & $k & ")" & (if isMe: "   <<< THIS" else: ""))
      inc shown
    else:
      iOut("    [" & $k & "] (null child slot)")
    inc k
  if n > InspMaxChildren:
    iOut("  -- listed " & $InspMaxChildren & " of " & $n &
         "; the rest were NOT examined.")
  if mine < 0:
    iOut("  !! the node you asked about was NOT among its own parent's " &
         "children. That is a contradiction, not a result -- most likely the " &
         "expression is a COMPONENT and `siblings` compared the Transform. " &
         "Treat this listing as INCONCLUSIVE.")
  else:
    iOut("  -- sibling index of the node you asked about: " & $mine)

# ===========================================================================
# findcomp -- search by COMPONENT TYPE
# ===========================================================================
const InspFindCompDefBudget = 600
  ## Deliberately far smaller than `find`'s budget. Each node here costs a
  ## MANAGED CALL (`Component::GetComponent(String)`) rather than a field read,
  ## so this walk is roughly two orders of magnitude more expensive per node
  ## and runs on the Unity thread. A generous default here would stall the
  ## client, which costs the session rather than the answer.
const InspFindCompMaxHits = 32
const InspFindCompMaxBudget = 4000
  ## The ceiling, not the default. Raising it is a deliberate code change: the
  ## real backstop is the 12ms frame slice, and a caller who asks for 200000
  ## here gets told it was clamped rather than being quietly given 600.

proc iCmdFindComp(toks: seq[string]) =
  ## `findcomp TypeName [ROOT] [BUDGET]` -- every node under ROOT that HAS a
  ## component of that type.
  ##
  ## "Find the object with a PostProcessLayer" is a question `find` (name) and
  ## `findtext` (displayed text) both structurally cannot answer. The route is
  ## the one `component` already proves: one `il2cpp_string_new` for the type
  ## name, reused for every node, then the Component overload of GetComponent
  ## on each Transform. Transforms come out of the child walk BY CONTRACT, so
  ## the GameObject/Component overload confusion that faults inside Unity
  ## cannot arise here.
  ##
  ## ATOMIC: one frame's slice, no cross-frame resume. A partial answer is
  ## reported as STOPPED EARLY and is never described as exhaustive.
  if toks.len < 2:
    iErr("usage: findcomp TypeName [ROOT] [BUDGET]   (e.g. findcomp Button)")
    return
  if cNavIcallReady() == 0'i32:
    iErr("the icall \"UnityEngine.Component::GetComponent(System.String)\" is " &
         "NOT registered in this runtime, so every node would take the " &
         "wrapper's failure branch and RAISE. NOTHING was searched -- this is " &
         "INCONCLUSIVE, not an empty result.")
    return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("Component::GetComponent(String)", fn, rva):
    return
  var root: Il2CppPtr = nil
  var rootExplicit = false
  var budgetTok = 2
  if not iFindResolveRoot(toks, 2, "findcomp", root, rootExplicit, budgetTok):
    return
  let budget = iFindParseBudgetNoted(toks, budgetTok, InspFindCompDefBudget,
                                     InspFindCompMaxBudget, "findcomp")
  var roots: seq[Il2CppPtr] = @[]
  if rootExplicit:
    if not iFindValidateRoot(root, true):
      return
    roots.add root
  else:
    let nroots = iSceneRoots(roots, false)
    if nroots == 0 or roots.len == 0:
      iErr("no scene roots were reachable, so NOTHING was searched. This is " &
           "INCONCLUSIVE, not 'that component does not exist'.")
      return
  var typeName = toks[1]
  let sp = cNavNewString(toCString(typeName))
  if sp == nil:
    iErr("il2cpp_string_new returned null for \"" & toks[1] &
         "\"; nothing was searched.")
    return
  iOut("  via UnityEngine.Component::GetComponent(String) @0x" &
       iHexPad(uint64(rva), 6) & " on each node, budget " & $budget &
       " node(s), one frame slice")
  var queue: seq[Il2CppPtr] = @[]
  for r in roots:
    if r != nil: queue.add r
  var head = 0
  var seen = 0
  var visited = 0
  var skips = 0
  var found = 0
  var stopped = 0   # 0 exhausted, 1 budget, 2 time, 3 hit cap
  let started = cNowMs()
  while head < queue.len:
    if seen >= budget:
      stopped = 1
      break
    if (seen and 15) == 0 and cNowMs() - started > InspFindSliceMs:
      stopped = 2
      break
    if found >= InspFindCompMaxHits:
      stopped = 3
      break
    let cur = queue[head]
    inc head
    inc seen
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
      inc skips
      continue
    inc visited
    iMark("Component::GetComponent(String) [findcomp]", cur)
    let comp = cast[Il2CppPtr](cInspUPP(fn, cur, sp, nil))
    if comp != nil and duOk(comp, 0x20'i32):
      inc found
      iNoteKlass(comp)
      iSetVar("k" & $found, cast[uint64](comp))
      iSetVar("kn" & $found, cast[uint64](cur))
      var actNote = ""
      let (okq, act) = iActiveInHierarchyChecked(cur, actNote)
      iOut("    HIT node=" & iPtr(cur) & " \"" & iObjName(cur) & "\"  " &
           toks[1] & "=" & iPtr(comp) & "  " &
           (if okq: (if act: "active" else: "INACTIVE -- NOT pressable")
            else: "active=UNKNOWN") &
           (if actNote.len > 0: "  [" & actNote & "]" else: "") &
           "   ($k" & $found & " = component, $kn" & $found & " = node)")
    var n = 0
    if iChildCount(cur, n):
      var k = 0
      while k < n and k < InspMaxChildren:
        let c = iChildAt(cur, k)
        if c != nil: queue.add c
        inc k
  iOut("  visited " & $visited & " node(s), " & $found & " match(es), " &
       "frontier " & $(queue.len - head) & " node(s)" &
       (if skips > 0: ", " & $skips & " unreadable/fake-null node(s) skipped"
        else: ""))
  if visited == 0:
    iOut("  -- NOTHING WAS EXAMINED (0 valid nodes visited). This is NOT " &
         "evidence that no " & toks[1] & " exists -- the search never looked.")
  elif stopped == 0:
    iOut("  -- the subtree was searched EXHAUSTIVELY. " &
         (if found == 0:
            "No node under this root has a component Unity's SHORT-NAME match " &
            "accepts as \"" & toks[1] & "\". If you suspect the NAME rather " &
            "than the absence, retry fully qualified (e.g. " &
            "UnityEngine.UI.Button)."
          else: "Every match is listed above."))
  elif stopped == 3:
    iOut("  -- STOPPED at the match cap (" & $InspFindCompMaxHits &
         "). There are probably more; narrow the root.")
  elif stopped == 1:
    iOut("  -- STOPPED EARLY on the NODE BUDGET (" & $budget & "). This is " &
         "NOT proof of absence. Re-run with a bigger budget or a narrower root.")
  else:
    iOut("  -- STOPPED EARLY on the 12ms FRAME SLICE, which is why this verb " &
         "has no `more`: each node costs a managed call. This is NOT proof of " &
         "absence. Narrow the root and re-run.")

# ===========================================================================
# whyread -- why is this expression not giving me an answer
#
# NOTE ON NAMING: `why` is ALREADY an alias for `whydidntitdraw` and is left
# exactly as it was. Rebinding a verb modders may already have in scripts, to
# something that answers a different question, is precisely the class of silent
# change this instrument is supposed to be incapable of.
# ===========================================================================
proc iCmdWhyRead(toks: seq[string]) =
  if toks.len < 2:
    iErr("usage: whyread EXPR   (explains WHY an expression is or is not usable)")
    return
  var v = 0'u64
  var err = ""
  if not iEval(toks[1], v, err):
    iOut("  1. the EXPRESSION did not evaluate: " & err)
    iOut("  -- nothing was read. Syntax is  $anchor | 0xhex  then any number " &
         "of  +0xNN  (move) or  @0xNN  (move then DEREFERENCE). An unbound " &
         "$name is a refusal, not a zero.")
    return
  let p = cast[Il2CppPtr](v)
  iOut("  1. the expression evaluates to " & iPtr(p))
  if v == 0'u64:
    iOut("  -- it is NULL. Most often the anchor it started from is unbound " &
         "(check `anchors`, and `state` for WHY an anchor is null), or a `@` " &
         "hop dereferenced a slot that holds zero.")
    return
  if not duOk(p, 8'i32):
    iOut("  2. VirtualQuery says this address is NOT committed/readable for " &
         "even 8 bytes.")
    let s = cInspIl2Start()
    let e = cInspIl2End()
    if s != 0'u64 and v >= s and v < e:
      iOut("  -- it IS inside the `il2cpp` CODE section. That is a function " &
           "address, not an object; reading fields off it is meaningless.")
    else:
      iOut("  -- and it is not inside the module's code section either. This " &
           "is the signature of a value used as a pointer: a small integer " &
           "(a budget typed where a root belonged), a field VALUE rather than " &
           "a field ADDRESS, or a freed object.")
    return
  iOut("  2. it IS readable (VirtualQuery, 8 bytes minimum).")
  var kraw = 0'u64
  if not iAssRead(p, "ptr", kraw):
    iOut("  3. but the klass slot at +0x00 could not be read. INCONCLUSIVE " &
         "about whether this is a managed object.")
    return
  if kraw == 0'u64 or not duOk(cast[Il2CppPtr](kraw), 0x20'i32):
    iOut("  3. the slot at +0x00 is " & iPtrU(kraw) & ", which is NOT a " &
         "readable Il2CppClass*. Every live IL2CPP object carries one there, " &
         "so this is readable memory that is probably NOT a managed object " &
         "-- a struct, a buffer, or the middle of one.")
    return
  var verified = false
  let kn = iKlassName(kraw, verified)
  iOut("  3. klass = " & iPtrU(kraw) &
       (if kn.len == 0: "  (name unreadable)"
        elif verified: "  type \"" & kn & "\" (VERIFIED against this build's " &
                       "metadata)"
        else: "  raw name \"" & kn & "\" -- UNVERIFIED: no such type in this " &
              "build's metadata, so do not trust it"))
  if iIsTransform(p):
    iOut("  4. its klass matches one learned from a source that returns a " &
         "Transform BY CONTRACT, so tree walkers accept it.")
  elif iIsGameObject(p):
    iOut("  4. its klass matches one learned from a GameObject-by-contract " &
         "source. Transform walkers REFUSE it on purpose: fed to `children` " &
         "it once read a plausible childCount and invented a hierarchy of " &
         "wrong children without faulting. Use `component`/`comp` or the " &
         "$rN form rather than $rgoN.")
  else:
    iOut("  4. its klass is not one of the Transform/GameObject klasses this " &
         "session has learned. That is not a verdict -- it only means no " &
         "by-contract source has handed back this type yet.")
  if not iUnityAlive(p):
    iOut("  5. UNITY FAKE NULL: the native half at +0x10 (m_CachedPtr) is " &
         "zero. In C# this object compares == null. It is readable and it is " &
         "DEAD; readability is not liveness, and calling a Unity method on it " &
         "faults inside Unity's C++, outside anything we can attribute.")
    return
  iOut("  5. native half at +0x10 is non-zero, so this is a LIVE Unity " &
       "object, not a fake-null husk.")
  var actNote = ""
  let (okq, act) = iActiveInHierarchyChecked(p, actNote)
  if okq:
    iOut("  6. activeInHierarchy = " & (if act: "true" else: "false") &
         (if act: "" else: "  -- INACTIVE, therefore NOT pressable: a press " &
          "returns success and does nothing (fact #72)."))
  else:
    iOut("  6. activeInHierarchy could not be determined on this build; that " &
         "is INCONCLUSIVE, not 'active'." &
         (if actNote.len > 0: "  " & actNote else: ""))

# ===========================================================================
# watch -- sample one value across frames and report what CHANGED
# ===========================================================================
const InspWatchCap = 240
const InspWatchMaxReport = 16

var gWatchIdx = -1
var gWatchLeft = 0
var gWatchSamples = 0
var gWatchUnread = 0
var gWatchChanges = 0
var gWatchReported = 0
var gWatchHave = false
var gWatchLast = 0'u64
var gWatchFirst = 0'u64

proc iIsWatchCmd(line: string): bool =
  let toks = iSplit(line)
  if toks.len == 0: return false
  result = (iLower(toks[0]) == "watch")

proc iWatchStep(line: string; idx: int): bool =
  ## One frame's sample of `watch EXPR TYPE [N]`. Returns true when the batch
  ## may move on.
  ##
  ## This exists because a value that is WRONG ONE FRAME IN THIRTY is invisible
  ## to `read`, and `read` run twice is indistinguishable from a value that
  ## never moved. Sampling with a per-frame comparison is the only way this
  ## instrument can say "it flickered" rather than "it looked fine when I
  ## asked". The expression is RE-EVALUATED every frame on purpose: a pointer
  ## chain whose middle hop is republished is exactly the lifecycle bug this
  ## is for, and caching the final address would hide it.
  let toks = iSplit(line)
  let first = (gWatchIdx != idx)
  if toks.len < 3:
    if first:
      iErr("usage: watch EXPR TYPE [FRAMES]. Nothing was watched.")
    gWatchIdx = -1
    return true
  let t = iLower(toks[2])
  if iTypeSize(t) < 0:
    if first:
      iErr("watch: \"" & t & "\" is not a type this REPL knows. Nothing was " &
           "watched.")
    gWatchIdx = -1
    return true
  if first:
    gWatchIdx = idx
    var frames = 60
    if toks.len > 3:
      var n = 0'u64
      var e2 = ""
      if iEval(toks[3], n, e2) and int(n) > 0: frames = int(n)
    if frames > InspWatchCap: frames = InspWatchCap
    gWatchLeft = frames
    gWatchSamples = 0
    gWatchUnread = 0
    gWatchChanges = 0
    gWatchReported = 0
    gWatchHave = false
    iOut("  watch: sampling " & toks[1] & " as " & t & " once per frame for " &
         $frames & " frame(s)")
  var v = 0'u64
  var err = ""
  var raw = 0'u64
  if not iEval(toks[1], v, err):
    inc gWatchUnread
  elif not iAssRead(cast[Il2CppPtr](v), t, raw):
    inc gWatchUnread
  else:
    inc gWatchSamples
    if not gWatchHave:
      gWatchHave = true
      gWatchFirst = raw
      gWatchLast = raw
      var shown = ""
      discard iReadTyped(cast[Il2CppPtr](v), t, shown)
      iOut("    frame 0: " & shown)
    elif raw != gWatchLast:
      inc gWatchChanges
      if gWatchReported < InspWatchMaxReport:
        inc gWatchReported
        var shown = ""
        discard iReadTyped(cast[Il2CppPtr](v), t, shown)
        iOut("    CHANGED at sample " & $gWatchSamples & ": " & iPtrU(gWatchLast) &
             " -> " & shown)
      gWatchLast = raw
  dec gWatchLeft
  if gWatchLeft > 0:
    return false
  gWatchIdx = -1
  # THE HONEST SUMMARY. "Never changed" and "was never readable" are different
  # facts and are reported as different facts.
  iOut("  watch: " & $gWatchSamples & " readable sample(s), " & $gWatchUnread &
       " unreadable frame(s), " & $gWatchChanges & " change(s)" &
       (if gWatchChanges > gWatchReported:
          " (" & $gWatchReported & " shown; the rest were counted only)"
        else: ""))
  if gWatchSamples == 0:
    iOut("  -- NOTHING WAS SAMPLED. The expression never evaluated or never " &
         "read in any frame. This says nothing about whether the value is " &
         "stable; it says the instrument could not look. INCONCLUSIVE.")
  elif gWatchUnread > 0:
    iOut("  -- the value was UNREADABLE in " & $gWatchUnread & " of the " &
         "frames sampled. That is itself a lifecycle result: something in " &
         "the chain was being destroyed and recreated. Changes counted above " &
         "cover only the frames that read.")
  elif gWatchChanges == 0:
    iOut("  -- the value was READ in every frame and NEVER changed. That is a " &
         "real negative over this window only; a flicker rarer than " &
         $gWatchSamples & " frames would not have been seen.")
  else:
    iOut("  -- the value CHANGED " & $gWatchChanges & " time(s) over " &
         $gWatchSamples & " frames. It is not stable.")
  result = true

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
  iOut("    visible EXPR                  IS IT ON SCREEN -- composite verdict")
  iOut("       active/graphic-enabled/colour alpha/CanvasGroup chain/Canvas")
  iOut("       enabled+order+mode/lossyScale/pixel rect, then a VERDICT of")
  iOut("       NOT VISIBLE + the CAUSE, VISIBLE, or INCONCLUSIVE. Never two.")
  iOut("    screenrect EXPR               the rect in REAL back-buffer pixels")
  iOut("       (origin bottom-left). Says UNKNOWN, not 'off screen', when the")
  iOut("       back-buffer size has not been published.")
  iOut("    canvasorder [EXPR]            live Canvases: sortingOrder, mode,")
  iOut("       enabled. With EXPR, the exact ancestor chain; without, scene")
  iOut("       roots + their direct children only (a SCOPE, not a census).")
  iOut("    whydidntitdraw EXPR           guided: visible + screenrect +")
  iOut("       canvasorder, then the first failing condition in a sentence.")
  iOut("    call TARGET SIG [ARG..]       direct RVA call (needs `allow write`)")
  iOut("    str TEXT...                   allocate a managed String -> $str0..")
  iOut("       and $_, so it can be passed to `call`. The REST OF THE LINE is")
  iOut("       the text (runs of whitespace collapse to one space). Needs")
  iOut("       `allow write` -- il2cpp_string_new really allocates.")
  iOut("    targets [SUBSTR]              list byte-verified call targets")
  iOut("  -- state + navigation (navigation needs `allow write`) --")
  iOut("    state | where                 what screen/tab is up RIGHT NOW")
  iOut("                                  e.g.  state")
  iOut("    wait N                        park the batch for N frames")
  iOut("                                  e.g.  wait 10")
  iOut("    until EXPR [FRAMES]           park until the ptr at EXPR is non-0")
  iOut("                                  e.g.  until $settings+0x118 120")
  iOut("    open [GROUP]                  SettingsScreen::ShowScreen (async!)")
  iOut("       GROUP is a NAME or 0..4: 0 Screen (aka Graphics/display),")
  iOut("       1 Game, 2 Sound (audio), 3 Control(s), 4 PostFX. An unknown")
  iOut("       name is REFUSED, never read as 0. Refuses too if the screen is")
  iOut("       not activeInHierarchy (closing/closed) -- wait, do not retry.")
  iOut("                                  e.g.  allow write | open graphics")
  iOut("    tab EXPR [0|1]                SELECT A TAB THE WAY A CLICK DOES:")
  iOut("       Toggle::set_isOn on the tab's own toggle. EXPR is a")
  iOut("       EFT.UI.Settings.SettingsTab (its Toggle is looked up) or the")
  iOut("       Toggle itself; ANY OTHER TYPE IS REFUSED by klass, and the")
  iOut("       screen's _currentTab is read back to show the PANEL followed.")
  iOut("    raidexit | raidexit status    LEAVE THE RAID, host-native:")
  iOut("       ShowInRaid -> DISCONNECT -> LEAVE -> results NextButton, each")
  iOut("       step asserting the target is ACTIVE before pressing. Verdict is")
  iOut("       an ACTIVE PlayButton under `Menu UI`, read off the live tree.")
  iOut("    raid [MAP] | raid status      ARM THE HOST-NATIVE RAID ENTRY NOW")
  iOut("       (~1s menu-to-READY, in-process -- not a UI tree walk). MAP")
  iOut("       defaults to autoRaidMap. Refuses if a live GameWorld says we")
  iOut("       are in a raid. ASYNCHRONOUS: the outcome is the host log.")
  iOut("  -- hierarchy (children/find are READ-ONLY; click/invoke need write) --")
  iOut("    parent EXPR [DEPTH]           the parent chain upward. [0] IS THE")
  iOut("       NODE YOU PASSED, [1] its parent; DEPTH counts levels PRINTED.")
  iOut("       A GameObject is REFUSED (pass its Transform).")
  iOut("    children EXPR [N]             list child transforms, bind $c0..$cN")
  iOut("                                  e.g.  children $preloader")
  iOut("    tree EXPR [DEPTH]             the subtree, indented (learn names)")
  iOut("                                  e.g.  tree $preloader 3")
  iOut("    roots                         every scene root -> $r0..$rN")
  iOut("                                  e.g.  roots")
  iOut("    find NAME [ROOT] [BUDGET]     name search; NO ROOT = ALL scenes")
  iOut("    find NAME in ROOTNAME         narrow by a root named, not " &
       "pointed; EXACT name, quote if it has spaces (in \"Menu UI\")")
  iOut("    find more [BUDGET]            RESUME a search that hit its cap")
  iOut("       A cap message NAMES which cap: FRAME CAP vs NODE BUDGET. The")
  iOut("       frontier is kept either way, so `more` never re-walks.")
  iOut("    findtext SUBSTR [ROOT] [BUDGET] [all]  TEXT A CONTROL DISPLAYS")
  iOut("    findtext SUBSTR in ROOTNAME   same, root resolved by EXACT name")
  iOut("                                  (TMP_Text only), not GameObject name")
  iOut("                                  ACTIVE nodes only by default; `all`")
  iOut("                                  includes inactive (unpressable) hits")
  iOut("    findtext more [BUDGET]        RESUME a text search that hit its cap")
  iOut("    component EXPR TypeName       GameObject/Transform -> component")
  iOut("    components EXPR [BaseType]    LIST every component, named  -> $k0..")
  iOut("                                  e.g.  component $g0 Button   -> $comp")
  iOut("    rect EXPR                     RectTransform geometry probe")
  iOut("    label EXPR                    TMP_Text.m_text as a field read")
  iOut("    settext EXPR TEXT...          WRITE a label, via the real setters")
  iOut("                                  e.g.  find PvE")
  iOut("    press EXPR [OFF]              EFT DefaultUIButton.OnClick (+0x120)")
  iOut("    pressname NAME [ROOT]         find -> keep the ONE VISIBLE -> press")
  iOut("                                  it. Refuses on 0 or >1 visible (write)")
  iOut("       The name search now RESUMES ACROSS FRAMES until EXHAUSTIVE, and")
  iOut("       a FAIL prints the failing check ON THE VERDICT LINE.")
  iOut("    record on | record off        log every UI click as `clickrec:`")
  iOut("                                  to the host log (read-only)")
  iOut("    click EXPR                    Button::Press (checks interactable)")
  iOut("                                  e.g.  allow write | click $f1")
  iOut("    invoke EXPR                   fire m_OnClick directly, no checks")
  iOut("                                  e.g.  tab $settings@0x118 1")
  iOut("    image                         GameAssembly base + il2cpp section")
  iOut("    allow write                   arm writes/calls for this batch")
  iOut("    echo TEXT                     put a marker in the output")
  iOut("  -- ASSERTIONS: a batch becomes a TEST. Three outcomes, always. --")
  iOut("    assert EXPR TYPE OP VALUE     OP: == != < <= > >= ; str also")
  iOut("                                  `contains`. f32/f64 use a relative")
  iOut("                                  tolerance, not exact ==")
  iOut("                                  e.g.  assert $verlabel+0xe0 str contains v1.0")
  iOut("    assert-active EXPR            activeInHierarchy (NOT activeSelf)")
  iOut("    assert-inactive EXPR          the negative form")
  iOut("    assert-null EXPR              the PTR STORED at EXPR is 0")
  iOut("    assert-nonnull EXPR           ...is non-0, readable AND not")
  iOut("                                  Unity-fake-null. Fake-null is a FAIL")
  iOut("    assert-readable EXPR          EXPR itself is committed memory")
  iOut("                                  (readable is NOT alive)")
  iOut("    assert-name EXPR SUBSTR       GameObject name contains SUBSTR")
  iOut("    verdict                       print the running tally now")
  iOut("       Every batch that ran an assertion ends with two grep-able lines:")
  iOut("         ASSERTIONS: <n> pass, <n> fail, <n> inconclusive")
  iOut("         BATCH VERDICT: PASS | FAIL | INCONCLUSIVE")
  iOut("       Precedence is FAIL > INCONCLUSIVE > PASS. A batch with no")
  iOut("       assertions prints NO verdict -- that is not a pass.")
  iOut("  -- lifecycle + diagnosis --")
  iOut("    watch EXPR TYPE [FRAMES]      sample once per FRAME (default 60,")
  iOut("                                  cap 240) and report every CHANGE.")
  iOut("                                  Re-evaluates the whole expression")
  iOut("                                  each frame, so a republished middle")
  iOut("                                  hop shows up. Separates 'never")
  iOut("                                  changed' from 'never readable'.")
  iOut("    whyread EXPR | explain EXPR   WHY an expression is unusable: bad")
  iOut("                                  parse / not committed / a code")
  iOut("                                  address / no klass / UNVERIFIED klass")
  iOut("                                  name / Unity fake-null / inactive.")
  iOut("                                  (`why` remains whydidntitdraw.)")
  iOut("  -- more navigation --")
  iOut("    path EXPR                     full /A/B/C hierarchy path. Says")
  iOut("                                  COMPLETE / INCOMPLETE / TRUNCATED --")
  iOut("                                  a leading `...` means the top is")
  iOut("                                  unknown, not decoration")
  iOut("    siblings EXPR | sibs EXPR     the parent's children -> $s0..$sN,")
  iOut("                                  with THIS one marked and its index")
  iOut("    findcomp TypeName [ROOT] [BUDGET]")
  iOut("                                  find nodes that HAVE a component of")
  iOut("                                  that type -> $k1.. (component) and")
  iOut("                                  $kn1.. (node). One managed call PER")
  iOut("                                  NODE, so budget defaults to 600 and")
  iOut("                                  there is no `more`; a partial answer")
  iOut("                                  says STOPPED EARLY, never exhaustive")
  iOut("  pact SUB [ARGS]                 IN-RAID ACTUATION of the local")
  iOut("                                  player (flag playerActuation, and")
  iOut("                                  `allow write`). SUB is status |")
  iOut("                                  magcycle | wait N | move X Y FRAMES |")
  iOut("                                  look DX DY | fire on|off | aim on|off")
  iOut("                                  | sprint on|off | jump | prone |")
  iOut("                                  pose D | lean D | command N | reload.")
  iOut("                                  ASYNCHRONOUS: this queues, the ANSWER")
  iOut("                                  is a host-log line `pact-rpc: ...`")
  iOut("  TYPE  i8 u8 i16 u16 i32 u32 i64 u64 f32 f64 ptr bool str klass")
  iOut("  EXPR  ATOM ( +0xNN | @0xNN )*   `+` moves, `@` DEREFERENCES")
  iOut("        ATOM is 0x<hex>, a decimal, or $name")
  iOut("        e.g.  $preloader@0x20        the version label")
  iOut("              $verlabel+0xe0         where TMP.m_text lives")
  iOut("  TARGET  name:<substring>  or  rva:0x<hex>[/<expected prologue hex>]")
  iOut("  SIG     <ret>_<args>, ret in v/b/i/l/p/f/s, args in p/i/b/f/l")
  iOut("        e.g.  s_p   String return, one pointer argument (get_name)")

# ---------------------------------------------------------------------------
# THE `raid` MAILBOX -- trigger the HOST-NATIVE fast raid entry ON DEMAND.
#
# WHY. Driving the menu with `findtext`/`pressname` from outside is SLOW: every
# step is a file round-trip plus a multi-frame tree walk, and the user's verdict
# on it tonight was blunt. `autoraid.nim` already does the whole menu->READY
# sequence INSIDE the client, riding the TarkovApplication::Update drain, at a
# measured ~970ms menu-to-READY -- but it only ever armed itself at LAUNCH, from
# the `uxAutoRaid` flag, so there was no way to say "go NOW".
#
# WHY A MAILBOX AND NOT A CALL, again. `autoraid.nim` is `include`d AFTER this
# file (aowlhost.nim:6516 vs :6486) and nimony does not forward-resolve procs
# across an include boundary reliably. This is the same wire `pact` uses, for
# the same reason -- and it deliberately does NOT reimplement any of autoraid's
# discovery: it arms autoraid's own state machine and autoraid does the work.
#
# WHAT THIS VERB CAN AND CANNOT PROVE. It can prove a request was ACCEPTED and
# it can refuse on the one precondition it can positively establish -- a live
# GameWorld means we are in a raid. It CANNOT prove the main menu is up: that
# is autoraid's WAIT-MENU step, which already discovers a visible MenuScreen
# PlayButton and refuses/times out on its own. So the answer here is
# ASYNCHRONOUS and this verb says so: the outcome is host-log lines
# (`autoRaid: ...`, `raid phase = LOADING/DEPLOYED`), never this reply.
# ---------------------------------------------------------------------------
var gInspRaidReq = ""     ## pending map name; "-" means "autoRaidMap default"
var gInspRaidSeq = 0'i64  ## requests accepted
var gInspRaidAns = ""     ## set by autoraid.nim's drain (armed / refused / failed)
var gInspRaidStage = ""   ## set by autoraid.nim's arGoto on every step change

var gInspExitReq = ""     ## non-empty means "leave the raid"; drained by autoraid.nim
var gInspExitAns = ""     ## set by raidExitDrainTick
var gInspExitStage = ""   ## set by xrGoto on every step change
  ## THE `raidexit` MAILBOX. Same wire, same reason as `raid` and `pact`:
  ## the state machine lives in autoraid.nim, which is `include`d after this
  ## file, so this deposits a request and that drains it.

proc iCmdRaidExit(toks: seq[string]) =
  ## `raidexit` -- LEAVE THE RAID, host-native, and verify against the tree.
  ## `raidexit status` -- what the leave sequence is doing.
  if toks.len > 1 and iLower(toks[1]) == "status":
    iOut("  raidexit: pending=" &
         (if gInspExitReq.len > 0: "yes" else: "no") &
         "  stage: " & (if gInspExitStage.len > 0: gInspExitStage
                        else: "(never armed this session)"))
    iOut("  last answer: " & (if gInspExitAns.len > 0: gInspExitAns
                              else: "(none yet)"))
    iOut("  NOTE: this reports what the drain last PUBLISHED, not a fresh " &
         "measurement. The full trail is the host log (`raidExit:` lines).")
    return
  if not iNavGate("raidexit"):
    return
  # REFUSE WHEN NOT IN A RAID -- and prove it positively rather than inferring
  # it from scene roots, which is exactly what was measured to be wrong in a
  # raid tonight (the location scene was all `roots` could see).
  if gDuGameWorld == nil or not duOk(gDuGameWorld, 0x20'i32):
    iErr("raidexit REFUSED: no live GameWorld is readable, so this session " &
         "is not in a raid as far as anything measurable here is concerned. " &
         "Nothing was armed. (This is a positive test for BEING in a raid; it " &
         "does not claim to know what screen you are on instead.)")
    return
  if gInspExitReq.len > 0:
    iErr("a raidexit request is STILL PENDING -- the drain has not run since " &
         "it was queued. Nothing was armed.")
    return
  gInspExitReq = "go"
  iOut("  queued: leave the raid, host-native.")
  iOut("  SEQUENCE: MenuScreen::ShowInRaid -> wait for _disconnectButton to " &
       "become activeInHierarchy -> press DISCONNECT -> LeaveButton (skipped " &
       "if it never appears) -> the Session End UI NextButton per results " &
       "page -> VERIFY.")
  iOut("  THE VERDICT IS READ OFF THE LIVE TREE: an ACTIVE, pressable " &
       "PlayButton under `Menu UI`. Queued is NOT out -- watch " &
       "`raidexit status` or the host log's `raidExit:` lines.")

proc iCmdRaid(toks: seq[string]) =
  ## `raid [MAP]`  -- arm the host-native raid entry NOW
  ## `raid status` -- what autoraid is doing, as autoraid itself reports it
  if toks.len > 1 and iLower(toks[1]) == "status":
    iOut("  raid: accepted=" & $gInspRaidSeq &
         "  pending=" & (if gInspRaidReq.len > 0: "\"" & gInspRaidReq & "\""
                         else: "(none)"))
    iOut("  stage: " & (if gInspRaidStage.len > 0: gInspRaidStage
                        else: "(autoraid has not reported a stage this " &
                              "session -- it has never been armed, or the " &
                              "drain has not run since)"))
    iOut("  last answer: " & (if gInspRaidAns.len > 0: gInspRaidAns
                              else: "(none yet)"))
    iOut("  NOTE: `status` reports what the drain last PUBLISHED. It is not a " &
         "fresh measurement of the menu; the authoritative trail is the host " &
         "log (`autoRaid:` and `raid phase =` lines).")
    return
  if not iNavGate("raid"):
    return
  # THE ONE PRECONDITION THIS SIDE CAN POSITIVELY ESTABLISH.
  #
  # A live, readable GameWorld means a raid is running -- driving the menu
  # state machine then would walk a hierarchy that is not the menu, during a
  # raid, which is exactly the case fact #261 says must never happen.
  #
  # The converse is NOT asserted: a null GameWorld is not proof we are at the
  # menu, and this refuses to pretend otherwise (the same mistake `state` was
  # corrected for -- claiming not-in-raid from an anchor slot). Whether the
  # MENU is actually up is autoraid's WAIT-MENU step, which looks for a
  # VISIBLE MenuScreen PlayButton and times out saying so.
  if gDuGameWorld != nil and duOk(gDuGameWorld, 0x20'i32):
    iErr("raid REFUSED: a live GameWorld is present (" & iPtr(gDuGameWorld) &
         "), so this session is IN A RAID. The raid-entry state machine walks " &
         "the MENU hierarchy and must never run during a raid load (fact " &
         "#261). Nothing was armed. Leave the raid first.")
    return
  if gInspRaidReq.len > 0:
    iErr("a raid request (map \"" & gInspRaidReq & "\") is STILL PENDING -- " &
         "the drain has not run since it was queued. Nothing was armed. This " &
         "is a queue-depth refusal, not a failure of the request.")
    return
  var map = "-"
  if toks.len > 1:
    map = toks[1]
    if map.len > 32:
      iErr("that map name is " & $map.len & " characters; refusing to queue " &
           "it. Nothing was armed.")
      return
  gInspRaidReq = map
  gInspRaidSeq = gInspRaidSeq + 1
  iOut("  queued #" & $gInspRaidSeq & ": arm the HOST-NATIVE raid entry" &
       (if map == "-": " with the configured autoRaidMap"
        else: " with map \"" & map & "\""))
  iOut("  ACCEPTED IS NOT ENTERED. The next drain frame arms autoraid's state " &
       "machine (WAIT-MENU -> PLAY -> NEXT.. -> SELECT-MAP -> READY); the " &
       "outcome is host-log lines `autoRaid: ...` and `raid phase = " &
       "LOADING/DEPLOYED`. Read the log, or `raid status`, not this line.")
  if gInspRaidAns.len > 0:
    iOut("  previous answer: " & gInspRaidAns)

# ---------------------------------------------------------------------------
# THE `pact` MAILBOX -- the one wire between an OUTSIDE PROCESS and in-raid
# actuation.
#
# WHY A MAILBOX AND NOT A CALL. `pact.nim` is `include`d AFTER this file
# (it stands on `iUnityAlive`/`iKlassOf` and on `raidphase.nim`, which itself
# stands on `iSceneNamePresent`), and aowlhost.nim states at that include that
# nimony forward-resolves procs across an include boundary "not reliably
# enough". So `iExec` CANNOT call `pactMagCycle` directly. It deposits the
# request here; `pactDrainTick`, later in the same module, drains it.
#
# WHY THIS CHANNEL AT ALL. A client-side mod cannot serve HTTP, and a host
# config key is a LEVEL, not an EDGE -- it can express "actuation is on" but not
# "do one magazine cycle NOW", and it has nowhere to put an answer. The
# inspector file channel is already an external -> Unity-main-thread pipe with a
# per-command SEH guard, a serial line to re-run, and an output file.
#
# THE ANSWER IS ASYNCHRONOUS AND THIS VERB SAYS SO. Accepting a request is NOT
# evidence that it happened; the outcome is a HOST LOG line (`pact magcycle:
# COMPLETE ...`, or the matching `warn`, or the `pact-rpc: status ...` line).
# Anything that consumes this must read the log, not this verb's reply.
# ---------------------------------------------------------------------------
var gInspPactReq = ""     ## one pending request, verbatim; "" means none
var gInspPactSeq = 0'i64  ## requests accepted
var gInspPactAns = ""     ## the previous request's answer, set by pact.nim
var gInspPactDrop = 0'i64 ## requests refused because one was still pending

proc iCmdPact(toks: seq[string]) =
  if not gInspAllowWrite:
    iErr("`pact` is refused: it CALLS INTO GAME CODE and moves the local " &
         "player. Set liveInspectorWrite in aowlspt-host.json and put " &
         "`allow write` in this batch. Nothing was queued.")
    return
  if toks.len < 2:
    iOut("  usage: pact status | magcycle | wait N | move X Y FRAMES |")
    iOut("         look DX DY | fire on|off | aim on|off | sprint on|off |")
    iOut("         jump | prone | pose D | lean D | command N | reload")
    iOut("  accepted=" & $gInspPactSeq & " refused-busy=" & $gInspPactDrop)
    if gInspPactAns.len > 0:
      iOut("  last answer: " & gInspPactAns)
    else:
      iOut("  last answer: (none yet -- answers arrive on the next drain " &
           "frame, in aowlspt-host.log, prefixed `pact-rpc:`)")
    return
  if gInspPactReq.len > 0:
    gInspPactDrop = gInspPactDrop + 1
    iErr("a pact request (" & gInspPactReq & ") is STILL PENDING -- the drain " &
         "has not run since it was queued. Nothing was queued. This is a " &
         "queue-depth refusal, not a failure of the request.")
    return
  var s = ""
  for i in 1 ..< toks.len:
    if i > 1: s.add ' '
    s.add toks[i]
  gInspPactReq = s
  gInspPactSeq = gInspPactSeq + 1
  iOut("  queued #" & $gInspPactSeq & ": pact " & s)
  iOut("  ACCEPTED IS NOT DONE. The outcome is a host-log line prefixed " &
       "`pact-rpc:` (and, for magcycle, `pact magcycle: COMPLETE` or a " &
       "matching warn). Read the log; do not read this line as a result.")
  if gInspPactAns.len > 0:
    iOut("  previous answer: " & gInspPactAns)

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
  # ECHO ONCE PER COMMAND, NOT ONCE PER FRAME. A frame-spanning `find` (or
  # `findtext`) re-enters this same command every frame until it finishes,
  # and echoing each time produced 32 identical `> find PvE` lines wrapped
  # around the results -- and, before this fixed, 57 `> findtext SETTINGS`
  # lines around a 4-line answer, because this check only ever covered
  # `find`'s resume flag. The echo belongs to the command being CLAIMED, not
  # to each slice of its work, for EITHER walker.
  let isFindResume = gFindActive and gFindOwnerIdx == gInspCurIdx and
                      gFindOwnerBatch == gInspBatch
  let isFindTextResume = gTxtActive and gTxtOwnerIdx == gInspCurIdx and
                          gTxtOwnerBatch == gInspBatch
  if not (isFindResume or isFindTextResume):
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
  of "stalltest":
    # FAULT INJECTION FOR THE DEADLINE. A deadline that has never abandoned
    # anything is not a deadline, it is untested code on the one path that runs
    # only after everything else has already failed -- so there is a supported
    # way to make it fire on purpose.
    #
    # This parks the batch permanently: the rider re-parks it every frame and it
    # can never complete. It does NOT block the Unity thread and it does NOT
    # loop, so an armed stall costs one branch per frame and the game keeps
    # rendering. The ONLY way out is the deadline, which is exactly the property
    # being proved.
    if not gInspWriteOn or not gInspAllowWrite:
      iErr("`stalltest` refused: it deliberately wedges a batch, so it needs " &
           "liveInspectorWrite AND an `allow write` line earlier in this " &
           "batch. Reads are unaffected.")
    else:
      gInspInjectStall = true
      gInspStallBatch = gInspRunningBatch
      # Park through the SAME mechanism a long `find` uses -- the command loop
      # owns `gInspSuspended`/`gInspResumeAt` and setting them from inside a
      # command body would not make the loop return, it would just fall through
      # to the next command. This flag is checked immediately after the guarded
      # body and parks the batch at this exact index.
      gFindSuspend = true
      iOut("  stalltest: batch " & $gInspRunningBatch & " is now WEDGED ON " &
           "PURPOSE and will never complete. Commands after this one will " &
           "NOT run.")
      iOut("  EXPECT: the watchdog to report WEDGED naming this batch, then " &
           "an ABANDONED line after " & $int(InspDeadlineMs div 1000'u64) &
           "s and " & $InspDeadlineFires & " rider dispatches, then the " &
           "channel to accept the NEXT batch normally. If the next batch is " &
           "ignored, the deadline did not work and that is the bug.")
      warn "live inspector: stalltest ARMED -- batch " & $gInspRunningBatch &
           " has been wedged deliberately to exercise the deadline."
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
  of "str":
    iCmdStr(toks)
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
      # A GameObject here makes `[0]` a DIFFERENT object than the one asked
      # about (Component::get_transform on a GameObject is the documented
      # native type confusion), which is the reachable cause of `parent`
      # having appeared to number its levels two different ways.
      if not iRefuseIfGameObject(cast[Il2CppPtr](v), "parent"):
        iCmdParent(cast[Il2CppPtr](v), int(d))
  of "children":
    iCmdChildren(toks)
  of "find":
    iCmdFind(toks)
  of "findtext":
    iCmdFindText(toks)
  of "tree":
    iCmdTree(toks)
  of "roots":
    iCmdRoots(toks)
  of "component", "comp":
    iCmdComponent(toks)
  of "components", "comps":
    iCmdComponents(toks)
  of "rect":
    iCmdRect(toks)
  of "label":
    iCmdLabel(toks)
  of "settext":
    iCmdSetText(toks)
  of "press":
    iCmdPress(toks)
  of "pressname":
    iCmdPressName(toks)
  of "click":
    iCmdClick(toks, false)
  of "invoke":
    iCmdClick(toks, true)
  of "open":
    iCmdOpen(toks)
  of "tab":
    iCmdTab(toks)
  of "raid":
    iCmdRaid(toks)
  of "raidexit":
    iCmdRaidExit(toks)
  of "state", "where":
    iCmdState(toks)
  of "record", "rec":
    iCmdRecord(toks)
  of "wait", "until":
    # Handled by the batch runner itself, which has to park and resume across
    # frames. Reaching here means the runner did not intercept it, which would
    # be a bug in the runner rather than an unknown command -- say that plainly
    # instead of pretending the command does not exist.
    iErr(cmd & " was not intercepted by the batch runner; this is an internal " &
         "inconsistency, not a bad command. Nothing was waited on.")
  of "visible", "vis":
    iCmdVisible(toks)
  of "screenrect":
    iCmdScreenRect(toks)
  of "canvasorder":
    iCmdCanvasOrder(toks)
  of "whydidntitdraw", "why":
    iCmdWhyDidntItDraw(toks)
  of "whyread", "explain":
    iCmdWhyRead(toks)
  of "assert":
    iCmdAssert(toks)
  of "assert-active", "assert-inactive":
    iCmdAssertActive(toks)
  of "assert-null", "assert-nonnull", "assert-readable":
    iCmdAssertPtr(toks)
  of "assert-name":
    iCmdAssertName(toks)
  of "verdict":
    iCmdVerdict()
  of "path":
    iCmdPath(toks)
  of "siblings", "sibs":
    iCmdSiblings(toks)
  of "findcomp":
    iCmdFindComp(toks)
  of "watch":
    # Same shape as `wait`/`until`: the batch runner parks and resumes it
    # across frames, so reaching here means the runner did not intercept it.
    # Say that plainly rather than pretending the verb does not exist.
    iErr("watch was not intercepted by the batch runner; this is an internal " &
         "inconsistency, not a bad command. Nothing was sampled.")
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
  of "pact":
    iCmdPact(toks)
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
  elif gInspBodyMode == 2:
    inspRecorderBody()
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

proc inspGoOff(why: string) =
  ## THE SELF-DISABLE, AND WHY IT NOW HAS TO SAY SO IN THE HOST LOG.
  ##
  ## Both announcements of a self-disable used to be `iOut` lines -- i.e. lines
  ## in the BATCH OUTPUT BUFFER. That buffer only ever reaches the out file and
  ## the log through `inspWriteOut`, which is called from `inspectPoll`, which
  ## returned at its very FIRST line once `gInspOff` was set. So the instant the
  ## inspector switched itself off it destroyed the only copy of the reason,
  ## stopped delivering answers, stopped watchdogging and stopped reading the
  ## command file: an entire session of perfect silence, produced by the one
  ## event that most needed announcing. That is a check that cannot fail.
  ##
  ## Announced HERE, before the flag is set, on the thread that decided it, so
  ## the reason exists in the log whatever happens to the buffer afterwards.
  if gInspOff:
    return
  warn "live inspector: SELF-DISABLED for this session -- " & why &
       ". faults=" & $gInspFaults & " escapes=" & $gInspEscapes &
       " batch=" & $gInspBatch & " running=" & $gInspRunningBatch &
       " delivered=" & $gInspDelivered & " phase=" & $gInspPhase &
       ". The command file will NOT be read again until the client is " &
       "restarted; whatever answers the last batch produced are published " &
       "on the next poll and then the channel stays quiet BY DESIGN."
  gInspOff = true

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
    # Assertion counters are per BATCH and a resumed batch keeps them -- a
    # batch that parked on `until` is ONE test, not two. Resetting them here
    # (in the not-resuming arm only) is what makes that true.
    gAssPass = 0
    gAssFail = 0
    gAssInc = 0
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
    if iIsWatchCmd(gInspCmds[i]):
      # `watch` parks exactly like `wait`, one sample per frame. It gets its
      # own step proc rather than sharing `iWaitStep`, because a wait that
      # finishes early and a watch that finishes early mean opposite things.
      if gWatchIdx != i:
        iOut("> " & gInspCmds[i])
      if iWatchStep(gInspCmds[i], i):
        inc i
        gInspResumeAt = i
        continue
      gInspResumeAt = i
      gInspSuspended = true
      gInspPhase = 0
      return
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
    # The command itself into the F2 panel's ring, tagged as a command so the
    # overlay can colour it apart from the answer lines that follow.
    ioTap(0'i32, "> " & gInspCmds[i])
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
        inspGoOff("too many caught faults in one session (" & $gInspFaults &
                  " of a budget of " & $InspMaxFaults & "); the last was in " &
                  "command " & $(i + 1) & " of " & $gInspCmds.len)
        iOut("  !! too many faults; the live inspector is now OFF for this " &
             "session. Restart the client to re-arm it.")
        i = gInspCmds.len
    # A LONG SEARCH PARKS ITSELF HERE. `find` gives up its frame after 12ms
    # rather than stalling the client, and asks to be re-entered at the SAME
    # index next frame. That is the difference between a search that spans
    # frames automatically and one that makes a human type `find more` until
    # it finishes. The command re-runs, recognises that it already owns an
    # in-progress search, and resumes the frontier instead of restarting.
    if gFindSuspend:
      gFindSuspend = false
      gInspResumeAt = i
      gInspSuspended = true
      gInspPhase = 0
      return
    inc i
  gInspResumeAt = 0
  gInspWaitIdx = -1
  # THE MACHINE-READABLE VERDICT. Emitted only when the batch actually ran an
  # assertion, so an exploratory batch is not given a spurious PASS -- "no
  # checks ran" and "every check passed" must never print the same line.
  if gAssPass + gAssFail + gAssInc > 0:
    iCmdVerdict()
  iOut("aowlspt live inspector -- batch " & $gInspRunningBatch & " complete, " &
       $gInspOut.len & " line(s)")

proc inspTick() =
  ## Called once per frame from the shared `PreloaderUI::Update` firing. The
  ## lock-free `aowl_insp_have` is the whole per-frame cost when there is
  ## nothing queued -- one interlocked load and a not-taken branch, the same
  ## discipline `mainDrain` follows.
  # Watch the HOST thread from here, because a stuck poll cannot watch itself.
  # BEFORE the self-disable check, not after: a channel that has switched
  # itself off still has a host tick thread, and "the poll thread died" must
  # stay reportable in exactly the session where the other half of the
  # instrument has already given up. It used to sit below the early-out, so
  # `gInspOff` silenced BOTH watchdogs at once.
  inspPollWatchdog()
  if gInspOff:
    return
  # THE CLICK RECORDER. Its own guarded pass, BEFORE any batch handling and
  # never nested inside one. Gated on `record on`, so an unarmed session pays
  # only this branch. A caught fault counts toward a self-disable rather than
  # faulting every frame forever.
  if gRecOn:
    gInspBodyMode = 2
    let recOk = cInspGuarded(cast[Il2CppPtr](0)) != nil
    gInspBodyMode = 0
    if not recOk:
      inc gRecFaults
      okLog "clickrec: !! recorder FAULTED (caught; game survived). LAST HOP: " &
            readCString(cInspCrumb()) & "  at " & iPtr(cInspCrumbPtr()) &
            "  (fault " & $gRecFaults & " of " & $RecMaxFaults & ")"
      gRecPending = 0
      if gRecFaults >= RecMaxFaults:
        gRecOn = false
        okLog "clickrec: !! too many faults; recorder DISARMED for this session."
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
      inspGoOff("too many guard escapes (" & $gInspEscapes & " of a budget " &
                "of " & $InspMaxFaults & "); the last escaped batch was " &
                $escaped)
      iOut("  !! too many escapes; the live inspector is now OFF for this " &
           "session. Restart the client to re-arm it.")
    return
  # RESUME A PARKED BATCH. The pending flag was consumed when the batch was
  # first claimed, so this path is not gated on it -- the batch is already
  # ours and is simply not finished.
  if gInspSuspended:
    # THE INJECTED STALL RE-PARKS ITSELF. `stalltest` exists to prove the
    # deadline abandons a batch that never finishes, so it must not be able to
    # finish: it is re-parked every frame until the deadline takes it away.
    if gInspInjectStall:
      return
    let ranBatch = gInspRunningBatch
    gInspInFlight = ranBatch
    inspRunBatch()
    gInspInFlight = -1
    # WAS THIS BATCH ABANDONED WHILE IT RAN? The deadline runs on the HOST tick
    # thread precisely because the Unity thread may be the thing that is stuck,
    # so a batch can be abandoned underneath the very frame that finally makes
    # progress. Its output has already been published with an ABANDONED banner
    # and a new batch may already be queued, so anything this late arrival has
    # to say is dropped rather than mixed into the next batch's answers.
    if gInspRunningBatch != ranBatch:
      gInspSuspended = false
      return
    if gInspSuspended:
      return
    cInspLock()
    gInspBatchDone = ranBatch
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
  gInspRunningBatch = gInspBatch
  gInspInFlight = gInspBatch
  # THE DEADLINE CLOCK STARTS AT THE CLAIM, not at the handover. The two are
  # different questions with different answers: "nobody picked it up" is already
  # diagnosed by `InspStuckMs` on the poll thread, and blaming a slow command
  # for a dispatch that never happened is exactly the confidently wrong report
  # this file keeps having to un-write.
  gInspClaimMs = cNowMs()
  gInspClaimFires = gInspFires
  let ranBatch = gInspRunningBatch
  inspRunBatch()
  gInspPhase = 3
  gInspInFlight = -1
  gInspPhase = 0
  if gInspRunningBatch != ranBatch:
    # Abandoned mid-flight; see the note on the resume path above.
    gInspSuspended = false
    return
  # A SUSPENDED batch is not a finished batch. Publishing the handshake here
  # would hand a half-run batch's output to the tick thread as if it were the
  # answer, and the rest of the commands would then run against a channel that
  # had already been reset.
  if gInspSuspended:
    return
  cInspLock()
  gInspBatchDone = gInspRunningBatch
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

var gInspPollSeen = 0
var gInspPollCheck = 0

proc inspPollWatchdog() =
  ## THE OTHER HALF OF THE WATCHDOG, and the important half.
  ##
  ## A poll that is BLOCKED cannot report that it is blocked -- every check
  ## inside `inspectPoll` is unreachable in exactly the case that matters most.
  ## So the Unity-thread rider watches the host thread instead: it counts its
  ## own dispatches, and every ~600 of them (about ten seconds) it asks whether
  ## `inspectPoll` has been entered at all since the last check.
  ##
  ## This is the check that distinguishes the two top-level causes of a dead
  ## channel, which no previous version could tell apart:
  ##   poll counter frozen -> the HOST TICK THREAD is stuck or dead, and
  ##                          nothing inside the inspector is at fault
  ##   poll counter moving -> the poll runs and is declining to queue, and its
  ##                          own watchdog line says why
  inc gInspPollCheck
  if gInspPollCheck < 600:
    return
  gInspPollCheck = 0
  if gInspPolls == gInspPollSeen:
    warn "live inspector: the HOST TICK THREAD has not entered inspectPoll " &
         "in ~600 rider frames, so the command file is not being read at all. " &
         "The rider is fine (" & $gInspFires & " dispatches); the poll side " &
         "is stuck. Nothing the inspector does on Unity's thread can fix " &
         "that -- look at the host tick loop."
  gInspPollSeen = gInspPolls

proc inspectPoll(now: uint64) =
  ## On the host's own tick thread, from the tick loop. Reads the command file
  ## only when its CONTENT has changed, so an idle session costs one shared
  ## file open every 250 ms and nothing else.
  ##
  ## Content-change is the trigger rather than a timestamp because a timestamp
  ## on a network or editor-rewritten file is the least reliable thing about
  ## it. To run the same commands twice, change a comment line -- which is what
  ## the shell driver does with a serial number.
  inc gInspPolls
  if not gInspOn:
    return
  if gInspOff:
    # A DEAD CHANNEL STILL OWES ONE EXPLANATION AND ONE FILE.
    #
    # `gInspOff` used to be part of the line above, which made this proc return
    # before the delivery block, before the deadline, before the watchdog and
    # before the command file was ever read again. The answers of the batch
    # that self-disabled -- including the line saying WHY -- sat in `gInspOut`
    # forever, the out file kept a previous boot's mtime, and every later edit
    # to the command file was swallowed without a word. Silence is the one
    # failure this instrument may not have, so the OFF state publishes what it
    # has, says so once, and only THEN goes quiet.
    if not gInspOffReported:
      gInspOffReported = true
      if gInspOut.len > 0:
        iOut("aowlspt live inspector -- the channel is OFF; the lines above " &
             "are the last batch's answers, published late.")
        inspWriteOut()
        cInspLock()
        gInspOut = @[]
        gInspOutBytes = 0
        gInspBatchDone = -1
        cInspUnlock()
      warn "live inspector: polling has STOPPED because the channel is OFF " &
           "(self-disabled). faults=" & $gInspFaults & " escapes=" &
           $gInspEscapes & " batch=" & $gInspBatch & " delivered=" &
           $gInspDelivered & " running=" & $gInspRunningBatch &
           ". Edits to " & gInspCmdPath & " will be IGNORED for the rest of " &
           "this session; restart the client to re-arm it."
    return
  # LATE ARMING OF THE IN-RAID ANCHOR. `bindInspect` runs ONCE, early. If the
  # bridge had not yet bound its main drain at that moment, `gInspSlot2` stayed
  # -1 for the entire session and the inspector was silently menu-only -- which
  # is exactly what `state` reported: in-raid anchor slot=-1, in-raid
  # dispatches=0 after 150k menu dispatches. Retrying here, on the host thread
  # once per poll, costs one integer compare and arms the anchor whenever the
  # drain actually appears.
  if gInspSlot2 < 0 and gDrainSlot >= 0:
    gInspSlot2 = gDrainSlot
    okLog "live inspector: IN-RAID anchor armed late as a rider on the main " &
          "drain's detour (slot " & $gInspSlot2 & "); commands will now " &
          "survive a raid load"
  # The answer, whenever Unity has finished one.
  var done = -1
  cInspLock()
  done = gInspBatchDone
  cInspUnlock()
  if done >= 0 and cInspHave() == 0'i32 and
     gInspOut.len > 0:
    inspWriteOut()
    gInspHandedMs = 0'u64
    # THE HISTORY, MOVED FORWARD EXACTLY HERE -- at the moment the answers
    # reached the out file, which is the only event that means "delivered".
    # `gInspBatchDone` is cleared on the next line and is therefore useless as
    # a record of what completed; this is what the watchdog reads instead.
    if done > gInspDelivered:
      gInspDelivered = done
    if gInspRunningBatch == done:
      gInspRunningBatch = -1
      gInspClaimMs = 0'u64
    cInspLock()
    gInspBatchDone = -1
    gInspOut = @[]
    cInspUnlock()
  if now < gInspNextPollMs:
    return
  gInspNextPollMs = now + 250'u64
  # ---------------------------------------------------------------------------
  # THE COMMAND FILE IS READ ON EVERY POLL, INCLUDING WHILE A BATCH IS PENDING.
  #
  # It used to be read only after the pending branch had returned, so while a
  # batch was in flight the host could not even SEE that the human had written
  # a new one -- the edit was swallowed with no line anywhere. Reading first
  # costs one shared open per 250ms in a state that is supposed to be brief,
  # and buys the refusal message below.
  # ---------------------------------------------------------------------------
  var text = ""
  let readOk = readShared(gInspCmdPath, text)
  # STRIP A LEADING UTF-8 BOM.
  #
  # `Set-Content -Encoding utf8` on Windows PowerShell 5.1 -- the obvious way a
  # Windows user writes this file -- prepends EF BB BF. Those three bytes then
  # ride on the front of the FIRST line, so command one of every batch arrives
  # as "﻿#1" or "﻿state" and is rejected as an unknown command while
  # every other line works. A batch that silently loses exactly its first
  # instruction is a nasty thing to debug from the outside.
  #
  # Stripped here, BEFORE the change-comparison, so the cached text and the
  # parsed text are the same bytes and a BOM cannot cause a phantom "changed".
  if readOk and text.len >= 3 and
     text[0] == '\xEF' and text[1] == '\xBB' and text[2] == '\xBF':
    var stripped = ""
    for i in 3 ..< text.len:
      stripped.add text[i]
    text = stripped
  if readOk:
    inc gInspReads
  else:
    inc gInspReadFails
  let unchanged = readOk and text == gInspLastText
  if unchanged:
    inc gInspUnchanged
  # ---------------------------------------------------------------------------
  # THE HEARTBEAT ON A BATCH THAT WAS HANDED OVER AND DELIVERED NOTHING.
  #
  # THIS IS THE LINE THE INSTRUMENT WAS MISSING, and its absence cost a whole
  # session: batch 1 was handed at 3.3s, the rider first dispatched at 17.2s,
  # and then NOTHING was ever said again. Every existing report had a
  # precondition that happened to be false --
  #   the QUEUED explanation      needs `gInspFires == 0`
  #   the "never picked up" stall needs the pending flag STILL set
  #   the deadline                needs a claim, 30s AND 900 dispatches
  #   the idle/wedged watchdog    sits BELOW the pending early-out
  #   everything                  sits below the `gInspOff` early-out
  # -- so five reports covering five states left the sixth state mute.
  #
  # This one has no precondition beyond the fact that defines the fault: a
  # batch was handed to Unity's thread and its answers have not reached the
  # out file. It NAMES the state rather than diagnosing it, because naming a
  # measured state cannot be confidently wrong and a diagnosis can.
  # ---------------------------------------------------------------------------
  if gInspHandedMs != 0'u64 and gInspDelivered < gInspBatch and
     now > gInspHandedMs and now - gInspHandedMs > InspFlightRepMs and
     (gInspFlightRepMs == 0'u64 or now - gInspFlightRepMs > InspFlightRepEvery):
    gInspFlightRepMs = now
    var cmdText = "(none)"
    if gInspCurIdx >= 0 and gInspCurIdx < gInspCmds.len:
      cmdText = gInspCmds[gInspCurIdx]
    warn "live inspector: batch " & $gInspBatch & " HANDED but NOT DELIVERED " &
         "after " & $int((now - gInspHandedMs) div 1000'u64) & "s. state: " &
         (if gInspRunningBatch >= 0:
            "CLAIMED (running=" & $gInspRunningBatch & ", held " &
            (if gInspClaimMs != 0'u64 and now > gInspClaimMs:
               $int((now - gInspClaimMs) div 1000'u64)
             else: "?") & "s, " &
            $(gInspFires - gInspClaimFires) & " dispatches since the claim)"
          else: "NOT CLAIMED by Unity's thread") &
         " phase=" & $gInspPhase & " cmd=" & $(gInspCurIdx + 1) & "/" &
         $gInspCmds.len & " (" & cmdText & ") resumeAt=" & $gInspResumeAt &
         " suspended=" & $gInspSuspended & " pending=" & $int(cInspHave()) &
         " fires=" & $gInspFires & " ticks=" & $gInspTicks &
         " faults=" & $gInspFaults & " escapes=" & $gInspEscapes &
         " off=" & $gInspOff & " delivered=" & $gInspDelivered &
         " outLines=" & $gInspOut.len & " done=" & $gInspBatchDone &
         " claimMs=" & $gInspClaimMs
    if gInspClaimMs == 0'u64 and gInspRunningBatch >= 0:
      warn "live inspector: ...and `claimMs` is 0 while a batch is marked " &
           "running, so the DEADLINE CAN NEVER FIRE for it. That is a host " &
           "bug, not a client stall; the batch is being released now."
      gInspRunningBatch = -1
      gInspSuspended = false
      gInspInFlight = -1
      cInspSetPending(0'i32)
      gInspLastText = ""
  # ---------------------------------------------------------------------------
  # THE DEADLINE ON AN IN-FLIGHT BATCH.
  #
  # This runs on the HOST TICK THREAD, and it has to: the thing it is watching
  # is the Unity thread, and a check that lives on the stuck thread cannot run.
  # It is also why this must never block -- it reads counters and returns.
  #
  # It fires only when BOTH bounds are exceeded (see `InspDeadlineFires`): long
  # enough in wall clock AND the rider demonstrably dispatched hundreds of times
  # since the claim without finishing. A raid load stalls the main thread for a
  # long time legitimately, and that case fails the second bound.
  # ---------------------------------------------------------------------------
  if gInspRunningBatch >= 0 and gInspDelivered < gInspRunningBatch and
     gInspClaimMs != 0'u64 and now - gInspClaimMs > InspDeadlineMs and
     gInspFires - gInspClaimFires > InspDeadlineFires:
    let stuck = gInspRunningBatch
    let heldMs = now - gInspClaimMs
    let phase = gInspPhase
    let idx = gInspCurIdx
    var cmdText = "(index out of range)"
    if idx >= 0 and idx < gInspCmds.len:
      cmdText = gInspCmds[idx]
    inc gInspAbandons
    # Tear the batch down BEFORE announcing it, so the announcement describes a
    # channel that is already re-armed rather than one that is about to be.
    gInspRunningBatch = -1
    gInspInFlight = -1
    gInspSuspended = false
    gInspPhase = 0
    gInspBodyMode = 0
    gInspInjectStall = false
    gInspStallBatch = -1
    gInspClaimMs = 0'u64
    gInspHandedMs = 0'u64
    cInspSetPending(0'i32)
    # RE-ARM THE CONTENT COMPARISON. The poll only queues when the command file
    # DIFFERS from the last text it read, so after an abandon the obvious human
    # response -- resend the same batch -- would be swallowed as "unchanged".
    # Clearing this makes the very next read look new, whatever it contains.
    gInspLastText = ""
    warn "live inspector: batch " & $stuck & " ABANDONED after " &
         $int(heldMs div 1000'u64) & "s held on Unity's thread (" &
         $(gInspFires - gInspClaimFires) & " rider dispatches since it was " &
         "claimed, so the thread is alive and this batch is not finishing). " &
         "It was in " &
         (if phase == 1: "the anchor refresh"
          elif phase == 2: "command " & $(idx + 1) & " of " & $gInspCmds.len &
                           ": " & cmdText
          else: "the completion handshake") &
         ". Abandons this session: " & $gInspAbandons
    warn "live inspector: the channel is RE-ARMED and will accept new " &
         "batches. One batch's answers were lost; the channel was not."
    iOut("aowlspt live inspector -- batch " & $stuck & " was ABANDONED after " &
         $int(heldMs div 1000'u64) & "s.")
    iOut("  It did not return to the dispatcher. Whatever it had answered " &
         "before that point is above; the rest of the batch DID NOT RUN.")
    iOut("  stuck at: " &
         (if phase == 1: "the anchor refresh"
          elif phase == 2: "command " & $(idx + 1) & " of " & $gInspCmds.len &
                           " -- " & cmdText
          else: "the completion handshake"))
    iOut("  The channel has been re-armed. Re-send your batch; it will be " &
         "accepted even if the file content is byte-identical. Do NOT re-send " &
         "the command named above until you know why it stalled.")
    inspWriteOut()
    cInspLock()
    gInspOut = @[]
    gInspOutBytes = 0
    gInspBatchDone = -1
    cInspUnlock()
    gInspDelivered = stuck
    return
  if cInspHave() != 0'i32:
    # A SECOND EDIT WHILE THE FIRST BATCH IS STILL PENDING IS REFUSED OUT LOUD.
    #
    # This branch returns, so before the fix a human who saw nothing happen and
    # did the obvious thing -- rewrite the file with a smaller batch -- got
    # exactly the same nothing, twice, with no line to say the second write had
    # even been noticed. `gInspLastText` is deliberately NOT updated, so the
    # refused edit queues by itself the moment the channel frees.
    if readOk and not unchanged and text != gInspBlockedText:
      gInspBlockedText = text
      warn "live inspector: the command file CHANGED while batch " &
           $gInspBatch & " is still in flight; your new batch is NOT queued " &
           "yet (pending=" & $int(cInspHave()) & ", running=" &
           $gInspRunningBatch & ", fires=" & $gInspFires & "). It has been " &
           "kept, not dropped: it will be queued as soon as batch " &
           $gInspBatch & " is delivered or abandoned."
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

  # THE WATCHDOG. A channel that stops accepting commands and says nothing is
  # the exact failure class this instrument exists to abolish, and it has now
  # happened twice: once when the timeout destroyed early batches, and once
  # when the poll stopped queueing anything at all. Both times the log was
  # SILENT, so the only evidence was an absence, and an absence cannot be
  # debugged.
  #
  # So: if the rider is demonstrably alive and no batch has been queued for a
  # while, say so, and print the state that distinguishes the possible causes
  # instead of leaving them to be inferred:
  #   readFails climbing   -> the file cannot be opened (locked, moved, gone)
  #   unchanged climbing   -> the file IS being read and looks identical, so
  #                           either the edit is landing somewhere else or the
  #                           content really is the same
  #   polls not climbing   -> this line would not print at all, which is
  #                           itself the answer: the host tick thread is stuck
  if gInspFires > 0 and gInspLastQueueMs != 0'u64 and
     now - gInspLastQueueMs > 10000'u64 and
     (gInspLastWatchMs == 0'u64 or now - gInspLastWatchMs > 15000'u64):
    gInspLastWatchMs = now
    # THE HEADLINE MUST AGREE WITH THE COUNTERS UNDERNEATH IT.
    #
    # This line used to say "no batch queued" unconditionally, and printed
    # `batch=9 done=-1` on the same line -- a diagnostic stating the opposite of
    # its own evidence, which is the worst thing this project produces. Worse,
    # BOTH readings of it were available and it never chose: `done=-1` is the
    # normal state of a healthy channel that has delivered everything, because
    # the delivery path clears it. So the headline is now chosen from
    # `gInspDelivered`, which is a history and not a handshake, and it names
    # three distinguishable states rather than asserting one.
    let secs = $int((now - gInspLastQueueMs) div 1000'u64)
    var head = ""
    if gInspRunningBatch >= 0 and gInspDelivered < gInspRunningBatch:
      head = "WEDGED -- batch " & $gInspRunningBatch & " was claimed by " &
             "Unity's thread " &
             (if gInspClaimMs != 0'u64 and now > gInspClaimMs:
                $int((now - gInspClaimMs) div 1000'u64)
              else: "?") &
             "s ago and has NOT completed" &
             (if gInspCurIdx >= 0 and gInspCurIdx < gInspCmds.len:
                "; it is stuck at command " & $(gInspCurIdx + 1) & " of " &
                $gInspCmds.len & ": " & gInspCmds[gInspCurIdx]
              else: "") &
             ". It will be ABANDONED and the channel re-armed once it has " &
             "held for " & $int(InspDeadlineMs div 1000'u64) & "s AND the " &
             "rider has dispatched " & $InspDeadlineFires & " more times."
    elif gInspDelivered >= gInspBatch:
      head = "IDLE and HEALTHY -- batch " & $gInspBatch & " completed and its " &
             "answers were delivered. No NEW batch has been queued for " &
             secs & "s because the command file's CONTENT has not changed. " &
             "That is a fact about the writer, not about the host: check that " &
             "your edits are reaching the file named below (bump a #serial), " &
             "and note that a channel with nothing to do looks exactly like " &
             "this."
    else:
      head = "batch " & $gInspBatch & " is QUEUED and has not been claimed " &
             "for " & secs & "s"
    warn "live inspector: " & head & " -- the rider IS " &
         "dispatching (" & $gInspFires & " fires). polls=" & $gInspPolls &
         " reads=" & $gInspReads & " readFails=" & $gInspReadFails &
         " unchanged=" & $gInspUnchanged &
         " lastRead=" & $text.len & "B lastKnown=" & $gInspLastText.len & "B" &
         " pending=" & $int(cInspHave()) & " batch=" & $gInspBatch &
         " delivered=" & $gInspDelivered & " running=" & $gInspRunningBatch &
         " done(handshake,cleared-on-delivery)=" & $gInspBatchDone &
         " suspended=" & $gInspSuspended & " abandons=" & $gInspAbandons &
         " inFlight=" & $gInspInFlight & "  file=" & gInspCmdPath
    if gInspReadFails > 0 and not readOk:
      warn "live inspector: the command file could NOT be opened on this " &
           "poll. If that persists the channel is dead until it can be read " &
           "-- check the path above exists and that nothing holds it open " &
           "without FILE_SHARE_READ."

  if not readOk:
    return
  if unchanged:
    return
  # A BATCH THAT HAS BEEN CLAIMED BUT NOT DELIVERED STILL OWNS `gInspCmds`.
  #
  # The pending flag is consumed at the claim, so a batch parked on `wait` /
  # `until` / a long `find` leaves this path wide open: the poll would queue a
  # new batch straight over the command list the Unity thread is iterating,
  # renumber it, and resume the parked batch at the OLD index into the NEW
  # commands. Refusing here -- loudly, and without consuming the edit -- makes
  # that impossible, and the deadline above bounds how long the refusal can
  # last.
  if gInspRunningBatch >= 0 and gInspDelivered < gInspRunningBatch:
    if text != gInspBlockedText:
      gInspBlockedText = text
      warn "live inspector: batch " & $gInspRunningBatch & " is still in " &
           "flight on Unity's thread; your new batch is NOT queued (it was " &
           "kept, not dropped, and goes in as soon as that batch is " &
           "delivered or abandoned). It is at phase " & $gInspPhase &
           ", command " & $(gInspCurIdx + 1) & " of " & $gInspCmds.len &
           ", suspended=" & $gInspSuspended & "."
    return
  gInspBlockedText = ""
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
  gInspLastQueueMs = now
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
    existing = "# aowlspt live inspector -- edit this file while the game runs.\n" &
      "# Every SAVE with changed content runs the whole file on Unity's main\n" &
      "# thread; answers appear in aowlspt-inspect-out.txt and in the host log.\n" &
      "# To re-run unchanged commands, bump this serial:  serial 1\n" &
      "help\n" &
      "anchors\n"
    discard writeTextFile(gInspCmdPath, existing)
  # WHATEVER IS ALREADY ON DISK AT BOOT IS NOT RUN, AND THAT IS SAID.
  #
  # The trigger is documented as a CONTENT CHANGE, but `gInspLastText` started
  # empty, so the first poll of every boot found the previous session's file
  # "changed" and ran it. That is how a 58-command batch left over from an
  # earlier session was handed to Unity's thread 3.3 seconds into a boot,
  # against anchors from a client that was still on the loading screen --
  # commands nobody asked for, at the worst possible moment, and with the
  # host log giving no hint where they came from. Seeding the comparison with
  # what is on disk makes the documented rule true.
  if existing.len >= 3 and existing[0] == '\xEF' and existing[1] == '\xBB' and
     existing[2] == '\xBF':
    var stripped = ""
    for i in 3 ..< existing.len:
      stripped.add existing[i]
    existing = stripped
  gInspLastText = existing
  var staleCmds = 0
  let staleLines = iLines(existing)
  for i in 0 ..< staleLines.len:
    let toks = iSplit(staleLines[i])
    if toks.len == 0:
      continue
    if toks[0].len > 0 and toks[0][0] == '#':
      continue
    inc staleCmds
  if staleCmds > 0:
    info "live inspector: a stale command file was already on disk at " &
         "startup (" & $staleCmds & " command(s)); it was NOT run. Only a " &
         "CHANGE to the file's content queues a batch -- bump the #serial " &
         "line to run what is there. file=" & gInspCmdPath
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
