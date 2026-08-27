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
var gTxtFound = 0
var gTxtActive = false
var gTxtBudgetLeft = 0
var gTxtOwnerIdx = -1
var gTxtOwnerBatch = -1
var gTxtFrames = 0
var gTxtTypeStr: Il2CppPtr = nil
  ## `findtext` state, deliberately separate from `find`'s own -- same shape,
  ## same resume contract (see gFindQueue et al. above), but a DIFFERENT
  ## search so the two verbs never stomp each other's frontier. `gTxtTypeStr`
  ## is the "TextMeshProUGUI" managed string, allocated ONCE per search
  ## (il2cpp_string_new) and reused for every node's GetComponent call --
  ## never re-allocated per node, which is what keeps this out of the
  ## per-frame-managed-allocation trap.

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
  # The live SettingsScreen `this`, once opened. `gSettingsLiveSelf` (set by the
  # `ShowScreen` postfix that actually drives Phase 1/2/3, first-fire AND every
  # revisit) is preferred over `gMi2Self` (set only by the separate invoke2
  # ladder proof, which may never fire): the anchor must reflect whichever probe
  # is ACTUALLY running, not assume a specific one is.
  iSetVarP("settings", iInspSettingsSelf())
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
  InspFindSliceMs = 12'u64
    ## THE REAL BUDGET. A node count is a poor proxy for "am I about to make
    ## the game stutter"; wall time is the actual thing that matters. One
    ## invocation gives up after this many milliseconds and reports exactly
    ## where it stopped, so a deep hierarchy costs several resumptions rather
    ## than one long freeze.
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
  InspTextFindMaxBudget = 60000
    ## Ceiling on an explicit request. Kept well under `find`'s ceiling for the
    ## same reason: a managed call per node is heavier than a pointer chase.

proc iInspSeedTextType(): bool =
  ## Allocate the "TextMeshProUGUI" managed string ONCE, at search start, and
  ## reuse the same pointer for every node's GetComponent call for the rest
  ## of the search -- including across resumed frames. Allocating a fresh
  ## string per node would be exactly the per-frame managed allocation this
  ## project's rules forbid, and at thousands of nodes it would also be slow
  ## enough to fight the 12ms slice on every single node instead of once.
  if gTxtTypeStr != nil and duOk(gTxtTypeStr, 0x18'i32):
    return true
  var typeName = "TextMeshProUGUI"
  gTxtTypeStr = cNavNewString(toCString(typeName))
  result = gTxtTypeStr != nil

proc iNavFindQuiet(want: string; fn: var Il2CppPtr): bool =
  ## Same lookup, no logging. `find` calls this thousands of times inside one
  ## frame; the loud version would bury the answer in identical error lines.
  fn = nil
  for i in 0 ..< int(cNavTargetCount()):
    if iContains(iLower(readCString(cNavName(int32(i)))), iLower(want)):
      fn = cNavFn(int32(i))
      return fn != nil
  result = false

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
  result = gFnGoOfComponent != nil and gFnActiveInHierarchy != nil

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
  if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
    return
  iMark("Component::get_gameObject [active]", cur)
  let go = cast[Il2CppPtr](cInspUP(gFnGoOfComponent, cur, nil))
  if not duOk(go, 0x20'i32) or not iUnityAlive(go):
    return
  iMark("GameObject::get_activeInHierarchy", go)
  let act = cInspUP(gFnActiveInHierarchy, go, nil)
  result = (true, (act and 1'u64) != 0'u64)

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
                         frontier: int; verb, subjectAbsent: string;
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
    else:
      iOut("  -- the subtree was searched EXHAUSTIVELY. " &
           (if found == 0:
              subjectAbsent & " is genuinely NOT PRESENT under this root."
            else: "Every match is listed above."))
  elif status == FindEnoughHits:
    active = true
    iOut("  -- stopped at the match cap (" & $InspFindMaxHits & "). There may " &
         "be more; `" & verb & " more` continues from the frontier above.")
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

proc iFindReport(status: int) =
  iFindReportGeneric(status, gFindVisited, gFindFrames, gFindFound,
                      gFindInvalidSkips, gFindQueue.len - gFindHead,
                      "find", "That name", gFindActive, gFindOwnerIdx,
                      gFindOwnerBatch)

proc iFindFirstByName(want: string; root: Il2CppPtr; budget: int): Il2CppPtr =
  ## Resolve a root BY NAME, so `find X in Y` does not require already knowing
  ## Y's pointer -- which is the position everybody is in before the first
  ## search succeeds.
  result = nil
  var queue: seq[Il2CppPtr] = @[]
  queue.add root
  var head = 0
  var seen = 0
  let started = cNowMs()
  let w = iLower(want)
  while head < queue.len and seen < budget:
    if (seen and 255) == 0 and cNowMs() - started > InspFindSliceMs:
      return nil
    let cur = queue[head]
    inc head
    inc seen
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur):
      continue
    let nm = iObjName(cur)
    if nm.len > 0 and iContains(iLower(nm), w):
      return cur
    var n = 0
    if iChildCount(cur, n):
      var k = 0
      while k < n and k < InspMaxChildren:
        let c = iChildAt(cur, k)
        if c != nil:
          queue.add c
        inc k

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
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet("Component::GetComponent(String)", fn) or fn == nil:
    return FindDone
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
    iMark("Component::GetComponent(String) [findtext]", cur)
    let comp = cast[Il2CppPtr](cInspUPP(fn, cur, gTxtTypeStr, nil))
    if comp != nil and duOk(comp, 0xE8'i32) and iUnityAlive(comp):
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
          let (activeOk, active) = iActiveInHierarchy(cur)
          if gTxtActiveOnly and activeOk and not active:
            inc gTxtInactiveSkipped
          else:
            inc gTxtFound
            iSetVar("f" & $gTxtFound, cast[uint64](cur))
            let nm = iObjName(cur)
            let pn = iParentName(cur)
            let activeTag = (if not activeOk: "  activeInHierarchy=unknown"
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
  iFindReportGeneric(status, gTxtVisited, gTxtFrames, gTxtFound,
                      gTxtInvalidSkips, gTxtQueue.len - gTxtHead,
                      "findtext", "No TMP text containing that substring",
                      gTxtActive, gTxtOwnerIdx, gTxtOwnerBatch)
  if gTxtActiveOnly:
    iOut("  scope: ACTIVE nodes only (activeInHierarchy)" &
         (if gTxtInactiveSkipped > 0:
            "; " & $gTxtInactiveSkipped & " inactive hit(s) skipped -- " &
            "re-run as `findtext ... all` to include them"
          else: ""))
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
  let ah = iAnchorSceneHandle(haveAnchor, anchor)
  if haveAnchor:
    var already = false
    for i in 0 ..< seen.len:
      if seen[i] == ah:
        already = true
    if not already:
      let an = iSceneNameOf(ah)
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
         "anchor is null or GameObject::get_scene_Injected did not verify)")
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
    iFindTextReport(st)
    return

  if toks.len < 2:
    iErr("usage: findtext SUBSTR [ROOT] [BUDGET] [all] | findtext more [BUDGET]")
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
      iErr("il2cpp_string_new failed for \"TextMeshProUGUI\"; nothing was " &
           "called.")
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
    iFindTextReport(st)
    return

  if cNavIcallReady() == 0'i32:
    iErr("the icall \"UnityEngine.Component::GetComponent(System.String)\" is " &
         "NOT registered in this runtime, so findtext cannot resolve any " &
         "components. Nothing was searched.")
    return
  if not iInspSeedTextType():
    iErr("il2cpp_string_new failed for \"TextMeshProUGUI\"; nothing was " &
         "searched.")
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

  let want = ftoks[1]
  var root: Il2CppPtr = nil
  var rootExplicit = false
  var budgetTok = 3
  if not iFindResolveRoot(ftoks, 2, "findtext", root, rootExplicit, budgetTok):
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
  iFindTextReport(st)

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
    iFindReport(st)
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
    iFindReport(st)
    return

  # ---- new search ----
  let want = toks[1]
  var root: Il2CppPtr = nil
  var rootExplicit = false
  var budgetTok = 3

  if toks.len > 3 and iLower(toks[2]) == "in":
    # `find X in Y` -- Y is a NAME, resolved against the whole hierarchy first.
    var base = iToTransform(gInspPreloader)
    if base == nil:
      iErr("cannot resolve a root by name: $preloader is null, so there is " &
           "nothing to search from. Pass an explicit pointer instead.")
      return
    base = iHierRoot(base)
    let found = iFindFirstByName(toks[3], base, InspFindDefBudget)
    if found == nil:
      iErr("no object named like \"" & toks[3] & "\" was found to use as a " &
           "root. Nothing was searched.")
      return
    root = found
    rootExplicit = true
    budgetTok = 4
    iOut("  root \"" & toks[3] & "\" resolved to " & iPtr(root) &
         " name=\"" & iObjName(root) & "\"")
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
  iFindReport(st)

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

proc iCmdComponent(toks: seq[string]) =
  ## `component EXPR TypeName [more...]` -- resolve a component on a
  ## GameObject or Transform.
  ##
  ## THIS IS THE MISSING LINK. `children` and `find` return TRANSFORMS, and a
  ## Transform is not a Button -- reading Button offsets off one produced a
  ## klass pointer that was reported as `m_OnClick`. Everything that acts on a
  ## control needs the COMPONENT, and this is the only way to get from one to
  ## the other.
  if toks.len < 3:
    iErr("usage: component EXPR TypeName   (e.g. component $g0 Button)")
    return
  # CLEAR `$comp` FIRST, before anything can fail.
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
  iSetVar("comp", 0'u64)
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
  let isGo = iIsGameObject(target)
  let overload = (if isGo: "GameObject::GetComponent(String)"
                  else: "Component::GetComponent(String)")
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind(overload, fn, rva):
    return
  if isGo:
    iOut("  target is a GameObject, so the GameObject overload is used " &
         "rather than the Component one (calling Component::GetComponent on " &
         "a GameObject is a native type confusion that faults inside Unity).")
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
       iHexPad(uint64(rva), 6) & " (call) on " & iPtr(target) &
       "   type string = " & iPtr(sp))
  iMark(overload, target)
  let comp = cast[Il2CppPtr](cInspUPP(fn, target, sp, nil))
  if comp == nil:
    iErr("GetComponent returned NULL -- this is an ANSWER, not a crash. " &
         "Either this object genuinely has no " & toks[2] & " (it may be a " &
         "container, with the control on a child -- try `children` then " &
         "`component $cN " & toks[2] & "`), or Unity's SHORT-NAME match did " &
         "not accept \"" & toks[2] & "\". Unity matches this overload by " &
         "short type name; if you suspect the latter, try the fully-qualified " &
         "name, e.g. UnityEngine.UI.Button.")
    return
  iNoteKlass(comp)
  iSetVar("comp", cast[uint64](comp))
  iOut("  FOUND " & toks[2] & " component = " & iPtr(comp) &
       "  klass=" & iPtrU(iKlassOf(comp)) & "   ($comp)")
  iOut("  bound to $comp -- e.g.  allow write   then   click $comp")

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
  if toks.len > 2:
    var o = 0'u64
    var e = ""
    if iEval(toks[2], o, e) and int(o) > 0 and int(o) < 0x400:
      off = int32(o)
    else:
      iErr("that offset is not a small positive number; refusing to read a " &
           "wild slot. Nothing was called.")
      return
  if not duOk(p, off + 8'i32) or not iUnityAlive(p):
    iErr("not readable to +0x" & iHexPad(uint64(off), 3) &
         ", or its native half is null. Nothing was called.")
    return
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

proc iCmdOpen(toks: seq[string]) =
  ## `open [GROUP]` -- EFT.UI.SettingsScreen::ShowScreen(screen, group).
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
  iOut("  -- hierarchy (children/find are READ-ONLY; click/invoke need write) --")
  iOut("    children EXPR [N]             list child transforms, bind $c0..$cN")
  iOut("                                  e.g.  children $preloader")
  iOut("    tree EXPR [DEPTH]             the subtree, indented (learn names)")
  iOut("                                  e.g.  tree $preloader 3")
  iOut("    roots                         every scene root -> $r0..$rN")
  iOut("                                  e.g.  roots")
  iOut("    find NAME [ROOT] [BUDGET]     name search; NO ROOT = ALL scenes")
  iOut("    find NAME in ROOTNAME         narrow by a root named, not pointed")
  iOut("    find more [BUDGET]            RESUME a search that hit its cap")
  iOut("    findtext SUBSTR [ROOT] [BUDGET] [all]  TEXT A CONTROL DISPLAYS")
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
  iOut("    click EXPR                    Button::Press (checks interactable)")
  iOut("                                  e.g.  allow write | click $f1")
  iOut("    invoke EXPR                   fire m_OnClick directly, no checks")
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
  of "click":
    iCmdClick(toks, false)
  of "invoke":
    iCmdClick(toks, true)
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
  iOut("aowlspt live inspector -- batch " & $gInspRunningBatch & " complete, " &
       $gInspOut.len & " line(s)")

proc inspTick() =
  ## Called once per frame from the shared `PreloaderUI::Update` firing. The
  ## lock-free `aowl_insp_have` is the whole per-frame cost when there is
  ## nothing queued -- one interlocked load and a not-taken branch, the same
  ## discipline `mainDrain` follows.
  if gInspOff:
    return
  # Watch the HOST thread from here, because a stuck poll cannot watch itself.
  inspPollWatchdog()
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
    gInspBatchDone = gInspRunningBatch
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
  if not gInspOn or gInspOff:
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
    warn "live inspector: no batch queued for " &
         $int((now - gInspLastQueueMs) div 1000'u64) & "s while the rider IS " &
         "dispatching (" & $gInspFires & " fires). polls=" & $gInspPolls &
         " reads=" & $gInspReads & " readFails=" & $gInspReadFails &
         " unchanged=" & $gInspUnchanged &
         " lastRead=" & $text.len & "B lastKnown=" & $gInspLastText.len & "B" &
         " pending=" & $int(cInspHave()) & " batch=" & $gInspBatch &
         " done=" & $gInspBatchDone & " suspended=" & $gInspSuspended &
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
