## aowlspt-host-il2cpp -- the client host for post-1.0 Tarkov.
##
## A native DLL injected into `EscapeFromTarkov.exe`. It loads aowlspt mods and
## implements `AowlHostApi` for them against the IL2CPP runtime.
##
## What makes this possible, and why there is no BepInEx underneath it: post-1.0
## Tarkov is IL2CPP, so there are no managed assemblies to load a plugin into --
## but Unity's IL2CPP runtime exports its whole C API from `GameAssembly.dll`.
## `aowl/src/aowlspt/il2cpp.nim` binds it; this file is the host built on top.
##
## The shape of a run:
##
##   1. A C constructor starts a thread (`aowlspt_hostboot.h` explains why it
##      must be a thread and not the constructor itself).
##   2. That thread waits for the game to bring IL2CPP up. It is injected
##      before the runtime exists, so this is a poll, not an assumption.
##   3. It attaches itself to the IL2CPP domain. Skipping this does not fail
##      loudly -- it corrupts the GC's view of the stack and the process dies
##      somewhere else, much later.
##   4. It loads every mod under `mods/`, and ticks them.
##
## What a client mod gets here: `log`, `config_get`, `now_ms`, `invoke_main`,
## `schedule`, events, `patch` -- an x64 inline detour on the compiled method --
## and the escape hatch, `resolve` and `call`, which on this side means reaching
## any type and any method in the game by name.
##
## `invoke_main` means Unity's main thread when it can. The host detours a
## method the engine calls once per frame on that thread and drains the queue
## from inside it; `bindMainDrain` holds the candidate list and the honest
## account of which of them exist. When none can be detoured the queue runs on
## the host's own thread, exactly as it used to, and the log says so in those
## words rather than letting the name imply otherwise. A mod can ask:
## `call("aowlspt.host::main_thread")`.
##
## Mods can also come and go while the game runs. `modcontrol` answers the mod
## manager's control protocol, and -- because the manager lives in the *backend*
## process and an event cannot cross a process boundary -- this host also asks
## the backend directly, over the overlay's existing HTTP worker, which
## client-side mods should be running. See `takeModSet` and
## `host/common/modcontrol.nim`. It is a poll and never a push: no
## `backendPort`, no answer, or an answer that does not parse whole, and this
## host runs exactly what it loaded at boot.
##
## A patch may be a *prefix* or a *postfix*. A postfix takes a second thunk
## path: it calls the original rather than tail-jumping into it, so it regains
## control and can hand the handler what the method returned -- and may replace
## it. That costs two refusals, both checked at registration rather than found
## at run time: a value-type return wider than a register, which comes back
## through a buffer this host cannot read the layout of, and a compiled call
## with stack arguments, which a *called* original would look for in the thunk's
## frame. `postfixRefusal` in `invoke.nim` is both of them.
##
## `handle_pointer` turns a handle into the address of the object behind it, so
## a mod can reach `this` on its own fast path rather than through `call`. The
## address is good for the call it was got in and no longer; `handle_pin` is the
## way to keep one, and pins the object until the mod releases it.
##
## What it does not get: `db_get`/`db_patch` and `route_register`, which are
## server-side and return `ErrUnsupported`; and a *finalizer* patch, whose whole
## contract is the exception in flight, which does not cross this ABI.

import std/[strutils, syncio]
import aowlspt/il2cpp
import aowlspt/fast
import aowlsptinstall/winfs
import modstore
import modhost
import modcontrol
import jsonpath
import aowloverlay
import aowlgraphics
import invoke

{.emit: """#include "aowlspt_shim.h" """.}
## The revision-3 live-object entry points. A separate header, and only this
## host includes it: `handle_pointer` and `handle_pin` mean nothing without a
## managed heap, and naming them in the shared shim would make every nimony
## binary that includes it have to define them. See `aowlspt_live.h`.
{.emit: """#include "aowlspt_live.h" """.}
{.emit: """#include "aowlspt_hostboot.h" """.}
{.emit: """#include "aowlspt_beclient.h" """.}
{.emit: """#include "aowlspt_detour.h" """.}
## The typed patch frame. Included here as well as through `aowlspt_abi.h`
## because this file names its pool directly; the include guard makes the second
## one free.
{.emit: """#include "aowlspt_frame.h" """.}

# --------------------------------------------------- the main-thread handoff
#
# `invoke_main` used to mean "the host's own attached thread", which is not the
# thread Unity runs its player loop on, so a callback that touched a Unity
# object was a crash waiting for a frame. The fix is to detour a method Unity
# calls once per frame on that thread and drain the queue from inside it -- see
# `bindMainDrain` for which methods, and why the host cannot know at compile
# time which of them exists.
#
# This block is the part nimony cannot express: a lock, and counters read
# without one. The lock itself now comes from `abi/aowlspt_lock.h` -- it used
# to be a byte-for-byte copy of the one in `abi/aowlspt_net.h`, kept separate
# only because that header also pulls in winsock2 and zlib, neither of which
# belongs in a DLL injected into the game. The split header has the lock and
# nothing else, so this host can share it and still import nothing but
# kernel32.
{.emit: """#include "aowlspt_lock.h" """.}
{.emit: """
/* `aowl_lock` guards `gPending`. A mod calls `invoke_main` from a worker
 * thread; the drain runs on the game thread. That is a real handoff between two
 * threads neither of which the other knows about, so it needs a lock rather
 * than an argument about how unlikely the interleaving is.
 *
 * It is the process-wide lock from `aowlspt_lock.h` rather than one of this
 * host's own: this queue is the only thing in the client host that is contended
 * at all, and a second lock would be a second ordering to get wrong for no
 * measured gain. */

/* Read without the lock, on every frame, by the drain. A plain LONG rather
 * than a queue walk: the empty case is the only case most frames, and it has to
 * cost a load and a branch. It is written only under the lock, so the worst a
 * racing reader can see is the value from a moment ago -- which delays a
 * callback by one frame and cannot corrupt anything. */
static volatile LONG aowl_mq_count = 0;

/* The thread the drain hook fires on, claimed by the first frame that reaches
 * it. Claimed with an interlocked exchange rather than a plain store because
 * nothing guarantees the hooked method is called from one thread only -- and if
 * it is not, two threads draining the same queue would run one mod's callbacks
 * concurrently. Whoever gets there first is the main thread; anyone else is
 * counted and sent away. */
static volatile LONG aowl_mq_tid = 0;
static volatile LONG aowl_mq_alien = 0;
static LONG aowl_mq_fires = 0;   /* main thread only, so no interlock needed */

static void aowl_mq_set_count(int32_t n) { aowl_mq_count = (LONG)n; }
static int32_t aowl_mq_get_count(void) { return (int32_t)aowl_mq_count; }
static uint32_t aowl_mq_thread(void) { return (uint32_t)aowl_mq_tid; }
static int32_t aowl_mq_alien_fires(void) { return (int32_t)aowl_mq_alien; }
static int32_t aowl_mq_fire_count(void) { return (int32_t)aowl_mq_fires; }

/* The whole per-frame cost of an empty queue: two loads, two branches, one
 * increment. No allocation, no lock, no logging, and no call into the runtime.
 * Returns 1 only when this thread owns the drain *and* there is something to
 * run -- so the caller's slow path is entered on the frames that need it and no
 * others.
 *
 * The interlocked claim runs once, on the first frame, and never again: the
 * common path reads `aowl_mq_tid` plainly and compares. */
static int32_t aowl_mq_enter(void) {
    LONG me = (LONG)GetCurrentThreadId();
    LONG owner = aowl_mq_tid;
    if (owner == 0) {
        InterlockedCompareExchange(&aowl_mq_tid, me, 0);
        owner = aowl_mq_tid;
    }
    if (owner != me) { InterlockedIncrement(&aowl_mq_alien); return 0; }
    aowl_mq_fires++;
    return aowl_mq_count != 0;
}

/* The callback the per-frame bench runs, and the counter that proves it ran.
 *
 * A benchmark of the drain has to go all the way through `aowl_invoke_callback`
 * -- the trampoline, the slice build, the indirect call -- because that is what
 * a mod's callback costs to reach. A loop that stopped short of it would time
 * the queue and report it as the price of a callback.
 *
 * It is a real `AowlCallbackFn`, registered nowhere and owned by no mod, so
 * nothing about it can outlive the bench or be reached by a mod. The hit
 * counter is what the harness reads to know the loop actually dispatched:
 * a drain that dropped every entry on the floor would otherwise time as
 * wonderfully fast. */
static volatile LONG aowl_bench_hits = 0;
static AowlStatus AOWLSPT_CALL aowl_bench_cb(void* user, AowlSlice payload,
                                             AowlBuffer* out) {
    (void)user; (void)payload; (void)out;
    aowl_bench_hits++;
    return AOWLSPT_OK;
}
static void* aowl_bench_cb_ptr(void) { return (void*)aowl_bench_cb; }
static int32_t aowl_bench_hit_count(void) { return (int32_t)aowl_bench_hits; }
""".}

proc cMqLock() {.importc: "aowl_lock", nodecl.}
proc cMqUnlock() {.importc: "aowl_unlock", nodecl.}

# ------------------------------------------------------- the host's tables
#
# `cMqLock` was named for the main-thread queue because that is all it used to
# guard. It guards the rest of this host's mutable state now, and the rename
# would cost more than it explains, so this block is the explanation instead.
#
# **Three threads touch these tables.** The host's own tick loop loads and
# unloads mods and drops what they registered. The game's thread runs every
# patch firing and the per-frame drain. And *any* thread a mod cares to create
# calls `resolve`, `call`, `handle_release`, `event_subscribe` and `patch` --
# the ABI never said a mod may not, and a mod that polls the game from a worker
# is doing the thing this host exists to allow.
#
# Until now none of it was guarded. The symptom was an occasional failed shrink
# of the handle table under churn, which is the mild end of the same fault: a
# `seq` that grows reallocates, and a thread indexing the old buffer while
# another has moved it is a read of freed memory rather than a wrong number.
#
# **What is guarded**: the handle table and its free queue (`gHandles`,
# `gHandleIsObject`, `gHandleGc`, `gHandleFree`), the subscription list
# (`gSubs`), and the *rows* of the patch table (`gPatches`) as they are written
# and torn down. `gPending` always was.
#
# **What is deliberately not guarded, and why:**
#
#  * **The firing path.** `patchFired` -> `typedFire` runs on the game's thread
#    inside a patched method, thousands of times a second, and a lock there is
#    frame time. It is measured rather than argued about: the typed prefix path
#    is 23 ns end to end (`perfbench`), and an uncontended `EnterCriticalSection`
#    /`LeaveCriticalSection` pair is of the same order -- so guarding it would
#    cost most of what the typed path was built to save. It stays off the lock,
#    and is made safe another way: `gPatches` is grown to the detour engine's
#    full slot capacity **once, at startup** (`reservePatchRows`), so the
#    backing array never moves under a firing. A row is written before its hook
#    is attached and cleared after its hook is removed, and `live` is the flag
#    that gates the read.
#
#  * **The typed path's handles.** It takes none. That is what makes the
#    above possible: `typedFire` hands the mod a borrowed view of the saved
#    registers and touches no host table at all. The **JSON** firing path does
#    take handles, and it *is* locked -- around the describe and around the
#    reclaim, never around the call into the mod.
#
#  * **`cMqEnter`,** the drain's per-frame "is this my thread and is there
#    anything to do". It is two loads and a branch by design and is already
#    correct without a lock; see its own comment.
#
#  * **`modhost.gMods`.** A mod row is added on the host's tick thread and read
#    from mod threads (`config_get`, the store). It only ever grows and is
#    never compacted, so the failure mode is a reallocation under a reader, the
#    same as the handle table's -- but the lock for it belongs in `modhost`,
#    which the backend shares, and this host cannot add it alone. It is left as
#    it is and said out loud rather than half-fixed here.
#
# One lock and not several, for the reason `aowlspt_lock.h` gives: everything
# under it is touched at human rates or on paths that already cost hundreds of
# nanoseconds, and one lock nobody has to reason about the ordering of is worth
# more than a set of finer ones somebody eventually takes in two orders. It is
# a Windows critical section, so a mod handler that calls back into the host on
# the same thread re-enters rather than deadlocking -- but no host call holds it
# across a call into a mod, which is the rule that actually matters.
proc tablesLock() {.inline.} = cMqLock()
proc tablesUnlock() {.inline.} = cMqUnlock()
proc cMqSetCount(n: int32) {.importc: "aowl_mq_set_count", nodecl.}
proc cMqCount(): int32 {.importc: "aowl_mq_get_count", nodecl.}
proc cMqThread(): uint32 {.importc: "aowl_mq_thread", nodecl.}
proc cMqAlienFires(): int32 {.importc: "aowl_mq_alien_fires", nodecl.}
proc cMqFireCount(): int32 {.importc: "aowl_mq_fire_count", nodecl.}
proc cMqEnter(): int32 {.importc: "aowl_mq_enter", nodecl.}
proc cBenchCb(): Il2CppPtr {.importc: "aowl_bench_cb_ptr", nodecl.}
proc cBenchHits(): int32 {.importc: "aowl_bench_hit_count", nodecl.}

# --------------------------------------------------------------- C surface

proc cModulePath(buf: Il2CppPtr; cap: int32): int32 {.
  importc: "aowl_sys_module_path", nodecl.}
proc cNowMs(): uint64 {.importc: "aowl_sys_now_ms", nodecl.}
proc cSleep(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}
proc cThreadId(): uint32 {.importc: "aowl_sys_thread_id", nodecl.}
proc cIsCodePointer(p: Il2CppPtr): int32 {.
  importc: "aowl_is_code_pointer", nodecl.}

## Fills `handle_pointer`/`handle_pin` and only then grows the struct's reported
## `size`. `aowl_hostapi_new` leaves both null and reports the revision-2 size,
## because a mod is told it may trust `size` before calling an appended pointer
## and that has to stay true of a host without a managed heap.
proc cHostApiArmLive(p: Il2CppPtr) {.importc: "aowl_hostapi_arm_live", nodecl.}
## Revision 4's `patch_typed`, armed separately from the live pair because they
## are separate capabilities -- see `aowlspt_live.h`. Called right after it, so
## `size` only ever grows.
proc cHostApiArmTyped(p: Il2CppPtr) {.importc: "aowl_hostapi_arm_typed", nodecl.}

## The typed patch frame: a pooled, borrowed view of the thunk's saved
## registers, handed to a mod instead of a JSON payload. `aowlspt_frame.h` has
## the mechanism and the lifetime rule.
proc cFrameSlot(depth: int32): Il2CppPtr {.importc: "aowl_frame_slot", nodecl.}
proc cFrameArm(f, regs, kinds: Il2CppPtr; argc, retKind: int32;
               flags: uint32; self: uint64) {.importc: "aowl_frame_arm", nodecl.}
proc cFrameDisarm(f: Il2CppPtr) {.importc: "aowl_frame_disarm", nodecl.}
proc cFrameDepthMax(): int32 {.importc: "aowl_frame_depth_max", nodecl.}
proc cInvokeTypedPatch(cb, user, frame: Il2CppPtr): int32 {.
  importc: "aowl_invoke_typed_patch", nodecl.}
proc cFreeBuf(p: Il2CppPtr) {.importc: "aowl_host_release", nodecl.}

const
  FrameFlagPostfix = 0x1'u32
  FrameFlagStatic = 0x2'u32

proc cInvokePatchArgs(cb, user, target: Il2CppPtr; tlen: int32;
                      args: Il2CppPtr; alen: int32;
                      outPtr, outLen: Il2CppPtr): int32 {.
  importc: "aowl_invoke_patch_args", nodecl.}


proc cHookNew(): Il2CppPtr {.importc: "aowl_hook_new", nodecl.}
proc cHookFree(p: Il2CppPtr) {.importc: "aowl_hook_free", nodecl.}
proc cHookAttach(p, target: Il2CppPtr): int32 {.importc: "aowl_hook_attach", nodecl.}
proc cHookRemove(p: Il2CppPtr): int32 {.importc: "aowl_hook_remove", nodecl.}
proc cHookStolen(p: Il2CppPtr): int32 {.importc: "aowl_hook_stolen", nodecl.}
proc cHookCapacity(): int32 {.importc: "aowl_hook_capacity", nodecl.}

# The BattlEye service guard, armed in the C constructor before this file's
# `hostMain` exists as a running thread. `aowlspt_beguard.h` says why it cannot
# wait for the boot thread and why it patches an import table rather than a
# function. All this side does is read what it did, once there is a log.
proc cBecNeuter(): int32 {.importc: "aowl_beclient_neuter", nodecl.}
var cBecBaseFound {.importc: "aowl_bec_base_found", nodecl.}: int32
var cBecIsInstSeen {.importc: "aowl_bec_isinst_seen", nodecl.}: int32
var cBecRestartSeen {.importc: "aowl_bec_restart_seen", nodecl.}: int32
proc cBeArmed(): int32 {.importc: "aowl_be_guard_armed", nodecl.}
proc cBeModule(): int32 {.importc: "aowl_be_guard_module", nodecl.}
proc cBeAnswered(): int32 {.importc: "aowl_be_guard_answered", nodecl.}
proc cBeOpened(): int32 {.importc: "aowl_be_guard_opened", nodecl.}

# The IL2CPP readiness flag, armed in the same constructor and set on the
# game's own thread when `il2cpp_init` returns. `aowlspt_il2cppready.h` has
# why this is watched rather than polled for.
proc cIl2Ready(): int32 {.importc: "aowl_il2_is_ready", nodecl.}
proc cIl2Armed(): int32 {.importc: "aowl_il2_guard_armed", nodecl.}
proc cIl2Seen(): int32 {.importc: "aowl_il2_guard_seen", nodecl.}
proc cIl2Rc(): int32 {.importc: "aowl_il2_guard_rc", nodecl.}
proc cIl2Calls(): int32 {.importc: "aowl_il2_guard_calls", nodecl.}
## How many slots the engine has live, and how many it has back on its free
## list. Both are read only by `aowlspt.host::table_stats`; they exist because
## "the slot was reclaimed" is otherwise unobservable from outside the engine,
## and a reclaim that silently did not happen is exactly the failure that ends
## a session twenty minutes in.
proc cHookUsed(): int32 {.importc: "aowl_hook_used", nodecl.}

proc cHookFreeCount(): int32 {.importc: "aowl_hook_free_count", nodecl.}
## Firings the engine dropped because the slot they belonged to had been
## released and re-claimed while they were in flight. Reported in
## `table_stats` because a race that is being caught and a race that is not
## happening are the same number from outside -- and this is the number.
proc cHookStaleFires(): int32 {.importc: "aowl_hook_stale_fires", nodecl.}
## Hands a slot back to the engine, after its hook has been removed and freed.
## Without this the pool was one-way: sixteen patches into a session -- which a
## player switching a mod off and on again reaches quickly -- every further
## `patch()` was refused with fifteen slots holding nothing.
proc cHookRelease(slot: int32) {.importc: "aowl_hook_release", nodecl.}
## Reserves the next free slot without installing anything, so this file can
## fill `gPatches[slot]` **before** the jump lands. The thunk can fire on the
## instruction after the install and it indexes `gPatches` by slot, so the row
## has to exist first -- which means the slot number has to.
proc cHookClaim(): int32 {.importc: "aowl_hook_claim", nodecl.}
proc cHookAttachAt(p, target: Il2CppPtr; slot: int32): int32 {.
  importc: "aowl_hook_attach_at", nodecl.}
## Arms a slot's postfix path. Called *before* `cHookAttach`, never after: the
## thunk reads this table on every firing and can fire the instant the jump
## lands, so a slot armed a moment late would spend its first firings behaving
## like a prefix -- which for a mod scaling a return value is a wrong number
## rather than a missing one.
proc cHookSetPostfix(slot: int32; on: int32) {.
  importc: "aowl_hook_set_postfix", nodecl.}
## The engine's own text for an install code. Kept there rather than mirrored
## here: the codes were split apart once already -- "could not be relocated"
## used to mean four different things -- and a copy of that table in this file
## would have gone on printing the old sentence for the new code.
proc cHookErrorText(rc: int32): Il2CppPtr {.
  importc: "aowl_hook_error_text", nodecl.}

const
  HostName = "aowlspt-host-il2cpp"
  HostVersion = "0.1.0"

  # `SideClient` and the shared status codes (`StatusOk`, `ErrBadArg`, and the
  # rest) come from `modhost`. Only the two this host answers on its own are
  # declared here.
  PatchSkipStatus = 1'i32
  ErrDisposed = -8'i32

# --------------------------------------------------------------- state

## What this host keeps *per mod* -- detour slots, GC handles, queued
## main-thread callbacks -- is below, keyed by the mod's index in
## `modhost.gMods`. The mod itself (`LoadedMod`, the table, the loader) is
## `host/common/modhost.nim`, shared with the backend.

type
  Patch = object
    ## One installed detour, and the mod callback it belongs to. Indexed by the
    ## slot the detour engine handed out, so the firing path is an array index
    ## rather than a search.
    hook: Il2CppPtr
    cb: Il2CppPtr
    user: Il2CppPtr
    target: string
    ## The target name as NUL-terminated bytes, built once. The firing path
    ## runs inside a patched game method and must not allocate.
    targetC: seq[byte]
    live: bool
    ## The method itself, kept so the firing path can decode the arguments
    ## against its declared signature without looking anything up.
    meth: Il2CppMethod
    ## Whether this patch asked for arguments. Decoding them builds a JSON
    ## array inside a method the game may call thousands of times a frame, so
    ## it is opt-in: a patch that only counts calls does not pay for it.
    wantArgs: bool
    ## Whether the patch may suppress the original. A patch that returns
    ## `PatchSkip` without having asked is a mistake, not an instruction.
    canSkip: bool
    ## Which mod installed it. Needed to take a mod's detours out when the mod
    ## goes: a detour whose handler lives in a freed library is a jump into
    ## unmapped memory the next time the game calls that method.
    ##
    ## -1 for the host's own drain hook, which no mod owns and no mod unload
    ## may remove.
    modIndex: int
    ## The host's own per-frame drain hook rather than a mod's patch. It goes
    ## through the same engine and occupies a real slot, because the engine
    ## hands slots out in order and this file indexes `gPatches` by slot -- a
    ## hook the host installed outside that table would shift every mod's slot
    ## by one and fire the wrong handler.
    isDrain: bool
    ## A postfix: the thunk calls the original and comes back, and the handler
    ## runs then, with what it returned. Mirrored into the engine's
    ## `aowl_post_table` before the hook is attached, because the thunk reads
    ## that table and can fire the instant the jump lands.
    isPostfix: bool
    ## A **typed** patch (ABI revision 4): the handler is given a borrowed view
    ## of the saved registers rather than a JSON description of them, and `cb`
    ## is an `AowlTypedPatchFn` rather than an `AowlPatchFn`. The two shapes take
    ## different numbers of parameters, so calling one through the other is a
    ## crash rather than a type error -- which is why this is a field the firing
    ## path branches on rather than something inferred.
    typed: bool
    ## The declared kind of each parameter and of the return, worked out **once**
    ## here rather than per firing. This is where the JSON path's cost actually
    ## goes: it asks the runtime what everything is on every call, and the answer
    ## cannot change between calls.
    kinds: seq[uint8]
    retKind: uint8
    ## `AOWL_FRAME_F_STATIC` for a static method, pre-computed for the same
    ## reason: it is a property of the signature, not of the firing.
    frameFlags: uint32

  Sub = object
    ## An event subscription. Client-side events are how one mod tells another
    ## something happened without either knowing the other exists.
    name: string
    cb: Il2CppPtr
    user: Il2CppPtr
    modIndex: int

  Pending = object
    ## A callback a mod asked to have run on the game's main thread, or after a
    ## delay. Held as raw pointers because nimony cannot hold a `proc` it did
    ## not declare; it goes back out through the C trampoline.
    cb: Il2CppPtr
    user: Il2CppPtr
    dueMs: uint64
    modIndex: int
    ## The host's own proof-of-thread entry rather than a mod's callback. It
    ## carries no function pointer: it is queued from the host thread and its
    ## only effect is that the drain records which thread ran it, which is the
    ## one fact this whole path exists to establish.
    selfTest: bool

proc deadPatch(): Patch =
  ## An empty row. Used for two things and they are the same thing: filling the
  ## gap when the engine hands back a slot above the end of this table, and
  ## clearing a row whose detour has been removed so that the slot can be
  ## claimed again. Every pointer in it is null, so a firing that somehow
  ## reaches it finds `live` false and returns.
  result = Patch(hook: cast[Il2CppPtr](0), cb: cast[Il2CppPtr](0),
                 user: cast[Il2CppPtr](0), target: "", targetC: @[0'u8],
                 live: false, meth: cast[Il2CppMethod](0), wantArgs: false,
                 canSkip: false, modIndex: -2, isDrain: false,
                 isPostfix: false, typed: false, kinds: @[], retKind: 0'u8,
                 frameFlags: 0'u32)

var gDir = ""
var gRt = Il2Cpp(handle: cast[Il2CppPtr](0), loaded: false, lastError: 0'i32,
                 missing: @[])
var gDomain: Il2CppPtr = cast[Il2CppPtr](0)
var gReady = false
var gPending: seq[Pending] = @[]

## The drain's own snapshot buffer, reused frame after frame.
##
## `takeDue` used to build a fresh `seq` for what was due and a second one for
## what was not, and hand the second back to `gPending`. Two allocations and a
## free every frame a per-frame chain is armed -- which is every frame, since
## the whole point of `everyMain` is that something is always queued. Measured
## on the stand-in that was 1148 ns a frame; reusing this buffer and compacting
## `gPending` in place is 300, and the host's cumulative allocation count stops
## moving at all while a chain runs.
##
## Only the thread that won `aowl_mq_tid` ever touches it, which is what makes
## a shared buffer safe: `cMqEnter` lets exactly one thread past. The two paths
## that are *not* that thread -- `runPending` on the host's tick thread, and a
## drain re-entered from inside a callback -- take `drainDue`, which brings its
## own. `gDraining` is what tells the second case apart.
var gDue: seq[Pending] = @[]
var gDraining = false

# --------------------------------------------------------- the frame bench
#
# What a mod pays per frame, measured on the thread that actually pays it.
#
# Everything else in this host that is timed is timed by `perfbench`, which
# links the fast path and the runtime into one binary and never loads the host
# at all. That is the right shape for the *call* costs and the wrong shape for
# these: the drain runs on whichever thread won `aowl_mq_tid`, inside a method
# the detour engine rewrote, with the host's own allocator and the host's own
# lock. A loop in another binary would be measuring a copy.
#
# So the bench runs *here*, from inside `mainDrain`, armed by a `call` target
# and read back through another. `gBenchIters` is the arm: non-zero means the
# next frame runs the loops instead of the drain, and `runFrameBench` clears it
# before it starts so that the `mainDrain` calls it makes do not recurse.
var gBenchIters = 0
var gBenchReport = ""
  ## Filled on the drain thread, read from a mod's thread through
  ## `aowlspt.host::frame_bench`. A plain string rather than anything guarded:
  ## it is written once by one thread and read after, and the worst a racing
  ## reader sees is the empty string it started with, which reads as "not
  ## ready" and is exactly right.
var gBenchRuns = 0
var gLastError = ""
var gHandles: seq[Il2CppPtr] = @[]
var gHandleIsObject: seq[bool] = @[]
## For an object handle, the IL2CPP GC handle keeping it alive; zero for a type
## handle. Parallel to `gHandles` because a mod-facing handle is an index and
## the three must stay in step.
var gHandleGc: seq[uint32] = @[]

## Released handle slots, waiting to be handed out again.
##
## The table used to be append-only: `handle_release` emptied a slot and
## nothing ever took it back, so a mod that resolved and released once a frame
## grew this by one entry a frame for the length of a raid. `fireHandler` hid
## the worst of it -- a patch argument's handles are usually at the top and the
## table is shrunk back -- which is why it went unnoticed: the leak is on the
## paths a *mod* drives, not the one the host drives.
##
## A queue rather than a stack, and the reason is the diagnostic rather than the
## memory. A handle number handed straight back out means a mod using a released
## handle gets somebody else's object instead of "handle 7 has already been
## released"; recycling oldest-first puts every other freed slot in between, so
## the sentence survives for as long as there is anything else to hand out. It
## is a delay and not a guarantee, and the guarantee -- a generation in the high
## bits of the handle -- would change every handle number a mod ever prints.
##
## `gHandleFreeHead` is where the queue starts; the seq in front of it is
## compacted rather than shifted, because a shift is a copy per release.
var gHandleFree: seq[int32] = @[]
var gHandleFreeHead = 0

var gPatches: seq[Patch] = @[]

## What the patch paths have cost, cumulatively, so that "allocation-free" is a
## measurement rather than a claim.
##
## `gPatchPayloadBytes` is every byte of JSON this host has built to describe a
## firing, and `gPatchHandlesTaken` every GC handle it has registered for one.
## Both are exactly the work the typed path removes, and both are readable from
## a mod through `call("aowlspt.host::patch_stats")` -- so a test can fire a
## typed hook twenty thousand times and assert that neither moved by one. The
## same test against the JSON hook moves them by twenty thousand.
##
## Counters rather than a flag, and cumulative rather than per-firing, because
## the interesting assertion is "this number did not change", which needs a
## number.
var gPatchPayloadBytes = 0'i64
var gPatchHandlesTaken = 0'i64
var gPatchFires = 0'i64
var gTypedFires = 0'i64
## Firings that arrived deeper than the frame pool and fell back to letting the
## original run. Reported because a non-zero value here means a mod is not being
## called, which is exactly the kind of silence that should be visible.
var gTypedTooDeep = 0'i64
var gSubs: seq[Sub] = @[]

## How deep the stack is inside a patch handler, and which handle indices that
## firing created. `handle_pointer` uses them to tell "the object a hook is
## looking at right now" from "a handle number a hook wrote down last frame".
##
## A count rather than a flag because a handler may itself call something the
## host has patched -- reentering `patchFired` -- and a flag would have the
## inner firing's return clear the outer one's scope.
var gPatchDepth = 0
var gPatchHandleMark = 0
var gPatchHandleTop = 0

proc reservePatchRows() =
  ## Every row the detour engine can ever hand out, present before the first
  ## one is used.
  ##
  ## This is what lets the firing path stay off the lock. `gPatches` used to be
  ## grown on demand -- `while gPatches.len <= claimed: add` -- and a `seq` that
  ## grows *moves*, so a patch installed from a mod's worker thread could
  ## reallocate the array while the game's thread was indexing it inside a
  ## patched method. Filling it to the engine's capacity once means the array
  ## never moves again: a row is only ever written, and `live` says whether the
  ## firing path should read it.
  ##
  ## Sixteen rows of nulls. The `while` loops at the two install sites are kept
  ## as they were -- they are now no-ops, and a capacity that grows one day
  ## should not depend on this having been called.
  let cap = int(cHookCapacity())
  while gPatches.len < cap:
    gPatches.add deadPatch()


## The slot the drain hook took, or -1 when nothing bound. Checked first in the
## firing path, so it must be a value no real slot can have.
var gDrainSlot = -1
## Which method it bound to, for the log and for `aowlspt.host::main_thread`.
var gDrainMethod = ""
## Whether the bound method runs **once** per frame.
##
## Three of the four candidates do; `UnityEngine.Time::get_deltaTime` is the
## last resort precisely because it does not -- it is called many times a frame
## by whatever the game is doing. A mod dividing the firing count by wall-clock
## time and calling the answer a frame rate is right for three of them and
## wrong for the fourth, and it has no way to tell which it got.
##
## So the host says. This is a fact about the method the host chose, and a mod
## guessing at it from a name list is a mod that has to be edited every time
## this list is.
var gDrainPerFrame = false
## The host's own thread, recorded at boot. `invoke_main` runs here when no
## candidate bound, and the difference between this and the drain thread is the
## proof that the drain is somewhere else.
var gHostThreadId = 0'u32
## Whether the host has already written the "this is the main thread" line. The
## drain never logs -- it runs inside the game's update path -- so the host
## thread notices and reports it instead.
var gDrainProven = false
var gAlienReported = false
var gStallReported = false
## The drain's liveness, watched from the tick loop. `gLastFire` is the fire
## count last seen and `gLastFireMs` when it last changed; if the count stops
## moving while work is queued, the hook has gone quiet -- the method it bound
## may only exist inside a raid -- and the host thread takes the queue back.
var gLastFire = 0
var gLastFireMs = 0'u64
var gDrainStalled = false

# ------------------------------------------------------- logging, helpers
#
# `info`/`warn`/`fail`/`okLog`, the clock they stamp with, `readBytes` and
# `ownDirectory` all come from `modhost` now. One log file, one line format,
# one `openLog`, opened by `hostMain` with this host's banner.
#
# `modhost.readBytes` is a single `copyMem` where this file's copy walked the
# buffer through `aowl_byte_at` one byte at a time. That is how every string
# argument crosses the ABI on this side, patch arguments included, so the
# cheaper one is the one worth keeping.

# --------------------------------------------------------------- host API
#
# These are what a mod calls. Each one is reached from C in
# `aowlspt_shim.h`, which unpacks the ABI structs so that nothing here has to
# know what an AowlSlice looks like.

proc hostLog(ctx: Il2CppPtr; level: int32; msg: Il2CppPtr; len: int32) {.
    exportc: "aowlspt_nim_log", cdecl.} =
  let text = readBytes(msg, len)
  case level
  of 4'i32: warn text
  of 5'i32: fail text
  of 3'i32: okLog text
  else: info text

proc hostLastError(ctx: Il2CppPtr; outPtr: Il2CppPtr; outLen: Il2CppPtr) {.
    exportc: "aowlspt_nim_last_error", cdecl.} =
  ## The buffer must outlive the call, so it points into a module-level string
  ## rather than a temporary. Documented in the ABI as valid until the next
  ## host call, which is exactly this lifetime.
  if gLastError.len == 0:
    discard cOutCopy(outPtr, outLen, cast[Il2CppPtr](0), 0'i32)
    return
  discard cOutCopy(outPtr, outLen,
                   cast[Il2CppPtr](toCString(gLastError)),
                   int32(gLastError.len))

proc hostConfigGet(ctx: Il2CppPtr; key: Il2CppPtr; keyLen: int32;
                   outPtr: Il2CppPtr; outLen: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_config_get", cdecl.} =
  ## Config is `config.json` beside the mod. Read per call rather than cached:
  ## a client mod's config is read a handful of times at load, and a stale
  ## cache is a worse problem than a file read.
  let k = readBytes(key, keyLen)
  discard cOutCopy(outPtr, outLen, cast[Il2CppPtr](0), 0'i32)
  # An empty key is the whole document. A mod with fifty settings reading them
  # in one round trip rather than fifty is the reason, and `aowlspt.nim` has
  # documented it as the behaviour all along.
  # Which mod is asking is carried in `ctx`, which is its index.
  let idx = int(cast[uint](ctx))
  if idx < 0 or idx >= modhost.modCount():
    gLastError = "no such mod context"
    return ErrBadArg
  # Through `modhost.configRead`, which is where the backend and the simulator
  # now read it too. This host answered `ErrNotFound` for a `config.json` that
  # did not parse -- the same status as "no such setting" -- so a client mod
  # with a BOM'd or half-written config was told its settings were absent and
  # ran the raid on defaults. `ErrConfigParse` is the answer now, and the
  # message names the file and the fault rather than the key.
  var text = ""
  var cfgErr = ""
  let cfgSt = modhost.configRead(idx, text, cfgErr)
  if cfgSt != StatusOk:
    gLastError = cfgErr
    # The whole document comes back even unparsed -- see the backend's copy of
    # this for why. A mod must be able to tell "broken" from "absent", and the
    # bytes are half of how it does that.
    if cfgSt == ErrConfigParse and k.len == 0 and text.len > 0:
      var raw = text
      discard cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(raw)),
                       int32(raw.len))
    return cfgSt
  # A dotted-path lookup, and the same one the backend uses. This was a
  # substring search for `"key"`, which matches inside `"MaxHealth"` when asked
  # for `Health`, matches inside any string value containing it, and could not
  # address a nested member at all -- so a mod's config had to be flat on this
  # side and could be nested on the other.
  var value = ""
  if k.len == 0:
    value = text
    var v0 = value
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(v0)),
                    int32(v0.len))
  if not pathGet(text, k, value):
    gLastError = "no such key: " & k
    return ErrNotFound
  var v = value
  result = cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(v)),
                    int32(v.len))

proc hostConfigSet(ctx: Il2CppPtr; key: Il2CppPtr; keyLen: int32;
                   val: Il2CppPtr; valLen: int32): int32 {.
    exportc: "aowlspt_nim_config_set", cdecl.} =
  gLastError = "the client host does not write config"
  result = ErrUnsupported

proc hostDbGet(ctx: Il2CppPtr; path: Il2CppPtr; pathLen: int32;
               outPtr, outLen: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_db_get", cdecl.} =
  ## The database is the backend's. Answering "unsupported" here is the ABI's
  ## own way of saying a side lacks a capability, and it lets one mod binary
  ## ship to both sides with a `side()` guard rather than two builds.
  discard cOutCopy(outPtr, outLen, cast[Il2CppPtr](0), 0'i32)
  gLastError = "the client has no database; db_get is server-side"
  result = ErrUnsupported

proc hostDbPatch(ctx: Il2CppPtr; path: Il2CppPtr; pathLen: int32;
                 patch: Il2CppPtr; patchLen: int32): int32 {.
    exportc: "aowlspt_nim_db_patch", cdecl.} =
  gLastError = "the client has no database; db_patch is server-side"
  result = ErrUnsupported

proc hostRouteRegister(ctx: Il2CppPtr; url: Il2CppPtr; urlLen: int32;
                       kind: int32; cb, user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_route_register", cdecl.} =
  gLastError = "the client does not serve HTTP; routes are server-side"
  result = ErrUnsupported

proc hostNowMs(ctx: Il2CppPtr): int64 {.
    exportc: "aowlspt_nim_now_ms", cdecl.} =
  result = modhost.elapsedMs()

proc freeHandleCount(): int = gHandleFree.len - gHandleFreeHead

# The handle table's internals -- `pushFreeHandle`, `takeHandleSlot`,
# `trimHandles`, `newHandle`, `handleTarget` -- assume the lock is already
# held, and the entry points below take it. Nothing here takes it twice on
# purpose; a critical section is re-entrant on the same thread, so a nesting
# that slips through is harmless rather than a hang, but the discipline is
# "lock at the door".

proc pushFreeHandle(idx: int) =
  ## A slot that has just been emptied. Compacted here rather than on the way
  ## out: a run that releases millions of handles would otherwise grow this
  ## queue by one entry per release even though it never holds more than a
  ## handful at a time.
  if gHandleFreeHead >= 64:
    var kept: seq[int32] = @[]
    for i in gHandleFreeHead ..< gHandleFree.len:
      kept.add gHandleFree[i]
    gHandleFree = kept
    gHandleFreeHead = 0
  gHandleFree.add int32(idx)

proc takeHandleSlot(): int =
  ## The oldest freed slot that is still empty, or -1 to append.
  ##
  ## Nothing is handed out while a patch handler is running. `fireHandler`
  ## reclaims everything between the marks it took on the way in, so a slot
  ## handed to the handler from inside that range would be freed underneath the
  ## mod that had just been given it. Appending there is free anyway: those
  ## handles are given back when the handler returns.
  result = -1
  if gPatchDepth > 0:
    return
  while gHandleFreeHead < gHandleFree.len:
    let i = int(gHandleFree[gHandleFreeHead])
    inc gHandleFreeHead
    # Stale entries: `fireHandler` shrinks the table, so a queued index may be
    # off the end of it, and a slot may have been refilled by the append path.
    if i >= 0 and i < gHandles.len and not gHandleIsObject[i] and
       gHandles[i] == nil and gHandleGc[i] == 0'u32:
      return i

proc trimHandles() =
  ## Drops empty slots off the end of the table.
  ##
  ## The free list keeps the table from growing when a slot is released and
  ## another is taken, but it cannot answer the other half: `describeResult`,
  ## `describeArgs` and `readField` in `invoke.nim` **append**, because they are
  ## handed the three sequences and not this file's bookkeeping. Every call that
  ## returns an object and every firing that describes one therefore extends the
  ## table by a slot that the free list can only fill later, and a run that does
  ## nothing but call and release grew it by one per call for the session.
  ##
  ## So the tail is trimmed instead, which costs a loop over trailing empties
  ## and leaves the table the size of the most handles held at once rather than
  ## the number ever taken. Only at depth zero: inside a patch handler the
  ## firing's own handles sit at the top and `fireHandler` is about to reclaim
  ## them by index.
  if gPatchDepth > 0:
    return
  var n = gHandles.len
  while n > 0 and not gHandleIsObject[n - 1] and gHandles[n - 1] == nil and
        gHandleGc[n - 1] == 0'u32:
    dec n
  if n < gHandles.len:
    shrink(gHandles, n)
    shrink(gHandleIsObject, n)
    shrink(gHandleGc, n)

proc newHandle(target: Il2CppPtr; isObject: bool; gc: uint32): uint64 =
  ## One handle, into a reclaimed slot where there is one. The number a mod
  ## sees is the index plus one, exactly as it always was.
  ##
  ## The door for every *append*, and therefore the one that has to hold the
  ## lock: `resolve` on a mod's worker thread and a release on another are the
  ## pair that reallocates this table under a reader.
  tablesLock()
  let slot = takeHandleSlot()
  if slot >= 0:
    gHandles[slot] = target
    gHandleIsObject[slot] = isObject
    gHandleGc[slot] = gc
    result = uint64(slot + 1)
  else:
    gHandles.add target
    gHandleIsObject.add isObject
    gHandleGc.add gc
    result = uint64(gHandles.len)
  tablesUnlock()

proc handleTarget(idx: int): Il2CppPtr =
  ## What a handle points at *now*.
  ##
  ## For an object that means asking the GC handle, every time, rather than
  ## caching the pointer: the collector moves objects, so a pointer that was
  ## right last frame is not a pointer that is right this frame. A collected
  ## object comes back null, which callers report rather than dereference.
  result = cast[Il2CppPtr](0)
  if idx < 0 or idx >= gHandles.len:
    return
  if gHandleIsObject[idx]:
    if gHandleGc[idx] != 0'u32:
      result = gcHandleTarget(gRt, gHandleGc[idx])
  else:
    result = gHandles[idx]

proc liveHandles(): seq[Il2CppPtr] =
  ## A snapshot for `bindArgs`, which takes a plain sequence. Rebuilt per call
  ## rather than kept: handles are counted in tens and correctness here is worth
  ## more than the copy.
  ##
  ## Under the lock, and a *copy* rather than a view, which is what makes the
  ## caller safe: `bindArgs` runs outside the lock and would otherwise be
  ## indexing a table another thread can reallocate underneath it.
  result = @[]
  tablesLock()
  for i in 0 ..< gHandles.len:
    result.add handleTarget(i)
  tablesUnlock()

proc hostHandleRelease(ctx: Il2CppPtr; handle: uint64) {.
    exportc: "aowlspt_nim_handle_release", cdecl.} =
  ## Called from whichever thread the mod is on, which is the whole reason this
  ## takes the lock: releasing a handle empties a slot and queues it, and a
  ## release racing a `resolve` on another thread is two writers on one table.
  tablesLock()
  let idx = int(handle) - 1
  if idx >= 0 and idx < gHandles.len:
    let wasHeld = gHandleIsObject[idx] or gHandles[idx] != nil
    if gHandleIsObject[idx] and gHandleGc[idx] != 0'u32:
      gcHandleFree(gRt, gHandleGc[idx])
      gHandleGc[idx] = 0'u32
    gHandles[idx] = cast[Il2CppPtr](0)
    gHandleIsObject[idx] = false
    # The slot goes back on the queue, so the table stays the size of what is
    # actually held rather than the number of handles ever taken. Only when it
    # held something: releasing the same handle twice must not queue it twice,
    # which would hand the same slot out to two callers.
    if wasHeld:
      pushFreeHandle(idx)
      trimHandles()
  tablesUnlock()

proc hostHandlePointer(ctx: Il2CppPtr; handle: uint64;
                       outAddress: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_handle_pointer", cdecl.} =
  ## The address of the object a handle names, for a mod's own fast path.
  ##
  ## This is the whole of the bridge, and almost all of it is refusals -- which
  ## is the point. A handle is safe *because* the host asks the GC handle every
  ## time; an address is the thing that is not safe, and the only useful
  ## guarantee to add is that a bad one is never produced in the first place.
  ##
  ## So: the address is read afresh from the GC handle on every call (never
  ## cached -- the collector moves objects and a cache would be exactly the bug
  ## this exists to avoid), a type handle is refused rather than answered with a
  ## class pointer, a released or collected handle is refused, and a handle
  ## belonging to a patch firing that has already returned is refused. The last
  ## one is the one a mod will actually hit: `this` is reclaimed by `patchFired`
  ## when the handler returns, so asking afterwards answers `ErrDisposed`
  ## instead of the address the object used to be at.
  var zero = 0'u64
  copyMem(outAddress, cast[Il2CppPtr](addr zero), 8)
  if not gReady:
    gLastError = "the IL2CPP runtime is not up yet"
    return ErrUnsupported
  let idx = int(handle) - 1
  if idx < 0:
    gLastError = "no such handle: " & $int(handle)
    return ErrNotFound

  # Every fact about the table is taken in one go, under the lock, and the
  # refusals below are decided from the copies. Reading the table a field at a
  # time across six branches would be six chances for another thread to move it
  # -- and the answer this returns is an *address*, which is the one thing here
  # it is not acceptable to be wrong about.
  tablesLock()
  let tableLen = gHandles.len
  let inRange = idx < tableLen
  let isObject = inRange and gHandleIsObject[idx]
  let raw = (if inRange: gHandles[idx] else: cast[Il2CppPtr](0))
  let target = (if isObject: handleTarget(idx) else: cast[Il2CppPtr](0))
  let patchMark = gPatchHandleMark
  let patchTop = gPatchHandleTop
  tablesUnlock()
  # The refusal a mod will actually meet, and it comes first because it is the
  # only one whose right answer is a sentence rather than a code. A handle that
  # a patch firing took out and no longer holds is either off the end of the
  # table (the usual case -- the firing shrank it back) or an emptied slot; both
  # mean the same thing, and "no such handle" would send the reader looking for
  # a bug in their bookkeeping instead of at the lifetime.
  if idx >= patchMark and idx < patchTop and not isObject:
    gLastError = "handle " & $int(handle) &
                 " was a patch argument and its handler has returned; the " &
                 "host reclaimed it there. An address taken in a hook is good " &
                 "for the length of that hook -- read what you need inside it, " &
                 "or `pinHandle` the object if you must keep it."
    return ErrDisposed
  if not inRange:
    gLastError = "no such handle: " & $int(handle)
    return ErrNotFound
  if not isObject:
    # A slot holding a class pointer is a handle from `resolve`; an empty one is
    # a handle that has been released. Different mistakes, different sentences.
    if raw != nil:
      gLastError = "handle " & $int(handle) &
                   " names a type, not a live object; there is no instance " &
                   "address for it. A handle from `resolve` is for `call` and " &
                   "for naming a class, not for the fast path."
      return ErrBadArg
    gLastError = "handle " & $int(handle) & " has already been released"
    return ErrDisposed
  let p = target
  if p == nil:
    gLastError = "handle " & $int(handle) &
                 " refers to an object the game has collected or that has " &
                 "already been released"
    return ErrDisposed
  var v = uint64(cast[uint](p))
  copyMem(outAddress, cast[Il2CppPtr](addr v), 8)
  result = StatusOk

proc hostHandlePin(ctx: Il2CppPtr; handle: uint64;
                   outHandle: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_handle_pin", cdecl.} =
  ## A second handle over the same object, this one **pinned**.
  ##
  ## A pinned object does not move, so the address behind a pinned handle stays
  ## correct across frames -- which is the only way a mod can honestly keep one.
  ## It is a separate handle rather than a mode on the existing one because the
  ## lifetimes differ: the original may be a patch argument the host reclaims in
  ## a moment, and the pin is the mod's, released when the mod says so.
  ##
  ## The cost is real and it is why this is not the default. The collector must
  ## work around that address for as long as the pin lives, and a mod that pins
  ## per hook rather than per session would pin at frame rate. `handle_release`
  ## on the pinned handle is what ends it.
  var zero = 0'u64
  copyMem(outHandle, cast[Il2CppPtr](addr zero), 8)
  if not gReady:
    gLastError = "the IL2CPP runtime is not up yet"
    return ErrUnsupported
  let idx = int(handle) - 1
  # As in `handle_pointer`: one look at the table, and the branches decided
  # from the copies.
  tablesLock()
  let inRange = idx >= 0 and idx < gHandles.len
  let isObject = inRange and gHandleIsObject[idx]
  let p = (if isObject: handleTarget(idx) else: cast[Il2CppPtr](0))
  tablesUnlock()
  if not inRange:
    gLastError = "no such handle: " & $int(handle)
    return ErrNotFound
  if not isObject:
    gLastError = "handle " & $int(handle) & " names a type, not a live object"
    return ErrBadArg
  if p == nil:
    gLastError = "handle " & $int(handle) &
                 " refers to an object the game has collected"
    return ErrDisposed
  let gc = gcHandleNew(gRt, p, true)
  if gc == 0'u32:
    gLastError = "the runtime would not give a pinned handle for handle " &
                 $int(handle)
    return ErrGeneric
  var v = newHandle(cast[Il2CppPtr](0), true, gc)
  copyMem(outHandle, cast[Il2CppPtr](addr v), 8)
  result = StatusOk

proc hostResolve(ctx: Il2CppPtr; typeName: Il2CppPtr; nameLen: int32;
                 outHandle: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_resolve", cdecl.} =
  ## Client-side, "resolving a service" means finding a type in the game. The
  ## handle it returns is what `call`'s `#<handle>::Member` form addresses.
  let name = readBytes(typeName, nameLen)
  if name.len == 0:
    gLastError = "empty type name"
    return ErrBadArg
  if not gReady:
    gLastError = "the IL2CPP runtime is not up yet"
    return ErrUnsupported
  let c = findClass(gRt, name)
  if c == nil:
    gLastError = "no such type: " & name
    return ErrNotFound
  let h = newHandle(c, false, 0'u32)
  # The out-parameter is a uint64*; write it as eight bytes.
  discard cOutCopy(cast[Il2CppPtr](0), cast[Il2CppPtr](0),
                   cast[Il2CppPtr](0), 0'i32)
  var tmp = h
  copyMem(outHandle, cast[Il2CppPtr](addr tmp), 8)
  result = StatusOk

proc mainThreadReport(): string =
  ## What `call("aowlspt.host::main_thread")` answers.
  ##
  ## A mod has to be able to ask, because the answer decides what it may do: a
  ## callback that touches a Unity object is correct when `bound` is true and a
  ## crash when it is false, and nothing else in the ABI tells those apart.
  ## `bound` is only true once the hook has actually fired -- a hook that is
  ## installed but has never been reached has proved nothing.
  let bound = gDrainSlot >= 0 and cMqFireCount() > 0
  result = "{\"bound\":" & (if bound: "true" else: "false") &
           ",\"method\":\"" & gDrainMethod & "\"" &
           ",\"mainThreadId\":" & $int(cMqThread()) &
           ",\"hostThreadId\":" & $int(gHostThreadId) &
           ",\"frames\":" & $int(cMqFireCount()) &
           ",\"perFrame\":" & (if gDrainPerFrame: "true" else: "false") &
           ",\"otherThreadFires\":" & $int(cMqAlienFires()) &
           ",\"stalled\":" & (if gDrainStalled: "true" else: "false") & "}"

proc tableStatsReport(): string =
  ## Every table this host keeps, by size, in one reply.
  ##
  ## `patch_stats` answers what the patch paths have *cost*; this answers what
  ## the host is still *holding*. The two questions are different and only the
  ## second one finds a leak: a counter that grows is the point of a counter,
  ## whereas a table that grows with the number of cycles rather than with the
  ## number of live things is a bug wherever it is.
  ##
  ## Read by `hostharness --churn`, which samples it every few hundred cycles
  ## and fits a line through each figure. So every number here is a *size*, not
  ## an event count, and each one has a shape it is supposed to have:
  ##
  ##   `patches`   bounded by the slot pool; `patchesLive` is how many are armed
  ##   `hookUsed`  the engine's own live-slot count, which must agree
  ##   `handles`   grows with handles a mod holds and must come back down
  ##   `subs`, `pending`, `mods` -- `mods` is the one that grows by design, and
  ##   the reason is `modIndexOf`: a context pointer is an index, so a dead slot
  ##   is kept rather than compacted.
  ##
  ## `allocCount` is this binary's mimalloc block count -- cumulative, so
  ## nothing lowers it. It is here rather than in `aowlspt/fast` on the mod side
  ## because the allocator is per binary and the host's own is the one a mod
  ## cannot see.
  # Under the lock: this walks three tables that other threads write, and it is
  # asked for by a mod -- so it is exactly the reader that used to see a table
  # mid-move. It is also read by `hostharness --churn` between cycles, where a
  # count that was off by one would be reported as a slope.
  tablesLock()
  var patchesLive = 0
  for i in 0 ..< gPatches.len:
    if gPatches[i].live: inc patchesLive
  var handlesLive = 0
  for i in 0 ..< gHandles.len:
    if gHandleIsObject[i] or gHandles[i] != nil: inc handlesLive
  let handleCount = gHandles.len
  let patchCount = gPatches.len
  let subCount = gSubs.len
  let freeHandles = freeHandleCount()
  tablesUnlock()
  var modsLive = 0
  for i in 0 ..< modhost.modCount():
    if modhost.modIsLive(i): inc modsLive
  result = "{\"patches\":" & $patchCount &
           ",\"patchesLive\":" & $patchesLive &
           ",\"hookUsed\":" & $int(cHookUsed()) &
           ",\"hookFree\":" & $int(cHookFreeCount()) &
           ",\"hookCapacity\":" & $int(cHookCapacity()) &
           ",\"staleFires\":" & $int(cHookStaleFires()) &
           ",\"handles\":" & $handleCount &
           ",\"handlesLive\":" & $handlesLive &
           ",\"handlesFree\":" & $freeHandles &
           ",\"subs\":" & $subCount &
           ",\"pending\":" & $int(cMqCount()) &
           ",\"mods\":" & $modhost.modCount() &
           ",\"modsLive\":" & $modsLive &
           ",\"drainSlot\":" & $gDrainSlot &
           ",\"drainStalled\":" & (if gDrainStalled: "true" else: "false") &
           ",\"allocCount\":" & $allocationCount() &
           ",\"allocBytes\":" & $allocatedBytes() &
           ",\"allocLive\":" & $liveBytes() & "}"

proc hostCall(ctx: Il2CppPtr; target: Il2CppPtr; targetLen: int32;
              args: Il2CppPtr; argsLen: int32;
              outPtr: Il2CppPtr; outLen: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_call", cdecl.} =
  ## The escape hatch, and on this side it is the whole client API: any type,
  ## any method, by name.
  ##
  ##   `Namespace.Type::Member`  a static member
  ##   `#7::Member`              a member on a handle from `resolve`
  ##
  ## Arguments are a JSON array. They are bound to the *declared* parameter
  ## types rather than guessed from their JSON shape -- see `invoke.nim` for
  ## why that distinction is not cosmetic.
  discard cOutCopy(outPtr, outLen, cast[Il2CppPtr](0), 0'i32)
  let spec = readBytes(target, targetLen)
  let argText = readBytes(args, argsLen)

  # One target that is not a game type: where `invoke_main` will actually run.
  # Answered before the runtime check, because the answer is meaningful -- "the
  # host thread, and no main thread was found" -- even with no runtime at all.
  # A dot in the type part keeps it clear of any real IL2CPP type, whose class
  # name never contains one.
  # What the two patch paths have cost. Here rather than in a log line because
  # the interesting assertion is a mod-side one -- fire a typed hook twenty
  # thousand times and check that `payloadBytes` and `handlesTaken` did not
  # move -- and a number a test can read is the only way to make
  # "allocation-free" a measurement instead of a promise.
  if spec == "aowlspt.host::patch_stats":
    var report = "{\"fires\":" & $gPatchFires &
                 ",\"typedFires\":" & $gTypedFires &
                 ",\"payloadBytes\":" & $gPatchPayloadBytes &
                 ",\"handlesTaken\":" & $gPatchHandlesTaken &
                 ",\"typedTooDeep\":" & $gTypedTooDeep &
                 ",\"frameDepth\":" & $int(cFrameDepthMax()) & "}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # Every table this host holds, by size. `patch_stats` above says what the
  # patch paths have cost; this says what is still held, which is the only one
  # of the two a leak shows up in.
  if spec == "aowlspt.host::table_stats":
    var report = tableStatsReport()
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # The per-frame path, timed on the thread that pays for it. Two targets and
  # not one: arming has to happen from here and the loops have to run over
  # there, so the caller arms, waits a frame or two, and asks again. A report
  # that is not ready yet says so rather than blocking a mod's thread on a
  # frame that may never come -- on a build where nothing bound, it will not.
  if spec == "aowlspt.host::frame_bench_arm":
    if gDrainSlot < 0:
      gLastError = "no per-frame method is bound, so there is no frame to " &
                   "measure; the drain is on the host's own thread"
      return ErrUnsupported
    var iters = 20000
    if argText.len > 0:
      var v = 0
      var any = false
      for ci in 0 ..< argText.len:
        let ch = argText[ci]
        if ch >= '0' and ch <= '9':
          v = v * 10 + (ord(ch) - ord('0'))
          any = true
      if any and v > 0: iters = v
    # Capped, because the loops run *inside a frame* on the game's thread and
    # nothing about this target is privileged -- any mod can ask for it. At the
    # cap the frame it lands in is a few hundred milliseconds, which is a
    # visible hitch and not a hang; a mod that asks for a billion gets the cap
    # rather than a frozen client.
    if iters > 200000: iters = 200000
    gBenchReport = ""
    gBenchIters = iters
    var armed = "{\"armed\":true,\"iters\":" & $iters & "}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(armed)),
                    int32(armed.len))

  if spec == "aowlspt.host::frame_bench":
    var report = gBenchReport
    if report.len == 0:
      report = "{\"ready\":false,\"runs\":" & $gBenchRuns & "}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  if spec == "aowlspt.host::main_thread":
    var report = mainThreadReport()
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # The graphics mod pushes its grade here. The args are a compact JSON object
  # of post-process params; the host forwards them, verbatim, to the native
  # post-process module. Answered without the runtime because the renderer lives
  # entirely in D3D11 and has nothing to do with IL2CPP being up.
  if spec == "aowlspt.host::gfx_apply":
    graphicsApplyJson(argText)
    var ack = "{\"ok\":true,\"running\":" &
              (if graphicsRunning(): "true" else: "false") &
              ",\"frames\":" & $int(graphicsFrames()) & "}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(ack)),
                    int32(ack.len))

  if not gReady:
    gLastError = "the IL2CPP runtime is not up yet"
    return ErrUnsupported

  let sep = find(spec, "::")
  if sep < 0:
    gLastError = "target must be Type::Member, got: " & spec
    return ErrBadArg
  let typePart = spec.substr(0, sep - 1)
  let member = spec.substr(sep + 2)

  var cls: Il2CppClass = cast[Il2CppClass](0)
  var instance: Il2CppObject = cast[Il2CppObject](0)
  if typePart.len > 0 and typePart[0] == '#':
    var idx = 0
    for i in 1 ..< typePart.len:
      let ch = typePart[i]
      if ch >= '0' and ch <= '9':
        idx = idx * 10 + (ord(ch) - ord('0'))
      else:
        gLastError = "malformed handle in: " & spec
        return ErrBadArg
    # A handle is either a type (from `resolve`) or a live object (from a call
    # that returned one). Both are reachable, and which one it is decides
    # whether the invoke gets an instance. Both facts are taken together under
    # the lock, because this runs on whatever thread the mod called from.
    tablesLock()
    let known = idx > 0 and idx <= gHandles.len
    let h = (if known: handleTarget(idx - 1) else: cast[Il2CppPtr](0))
    let objectHandle = known and gHandleIsObject[idx - 1]
    tablesUnlock()
    if not known:
      gLastError = "no such handle: " & typePart
      return ErrNotFound
    if objectHandle:
      if h == nil:
        gLastError = "handle " & typePart &
                     " refers to an object the game has collected"
        return ErrDisposed
      instance = h
      cls = objectClass(gRt, h)
    else:
      cls = h
  else:
    cls = findClass(gRt, typePart)

  if cls == nil:
    gLastError = "no such type: " & typePart
    return ErrNotFound

  var values: seq[JsonValue] = @[]
  var parseError = ""
  if not parseArgs(argText, values, parseError):
    gLastError = parseError
    return ErrDecode

  # `@name` is a field rather than a method. A property compiles to `get_X` and
  # is reachable through an ordinary call; a field has no method behind it, and
  # half of what a mod wants to read on this game is a field -- often a private
  # one, which is what reflection is for. No new ABI entry: the escape hatch is
  # already the thing that means "reach what the header has no door for".
  if member.len > 1 and member[0] == '@':
    let fieldName = member.substr(1)
    var fieldError = ""
    if values.len == 0:
      # `readField` may register a handle for a reference field, so it appends
      # to the table and has to do it under the lock.
      tablesLock()
      let text = readField(gRt, cls, instance, fieldName, gHandles,
                           gHandleIsObject, gHandleGc, fieldError)
      tablesUnlock()
      if fieldError.len > 0:
        gLastError = fieldError & " on " & typePart
        return ErrNotFound
      var t = text
      return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(t)),
                      int32(t.len))
    if values.len != 1:
      gLastError = "writing a field takes one value, got " & $values.len
      return ErrBadArg
    var live = liveHandles()
    if not writeField(gRt, cls, instance, fieldName, values[0], live,
                      fieldError):
      gLastError = fieldError & " on " & typePart
      return ErrBadArg
    return StatusOk

  let m = findMethod(gRt, cls, member, values.len)
  if m == nil:
    gLastError = "no method " & member & "/" & $values.len & " on " & typePart
    return ErrNotFound

  var argBlock: ArgsPtr = cast[ArgsPtr](0)
  if values.len > 0:
    argBlock = cArgsNew(int32(values.len))
    if argBlock == nil:
      gLastError = "too many arguments (" & $values.len & ")"
      return ErrBadArg
    var bindError = ""
    var live = liveHandles()
    if not bindArgs(gRt, m, values, live, argBlock, bindError):
      cArgsFree(argBlock)
      gLastError = bindError
      return ErrBadArg

  var exc: Il2CppException = cast[Il2CppException](0)
  let res = invoke(gRt, m, instance,
                   (if argBlock == nil: cast[Il2CppPtr](0) else: cArgsPtr(argBlock)),
                   exc)
  if argBlock != nil:
    cArgsFree(argBlock)

  if exc != nil:
    gLastError = "managed exception from " & spec
    return ErrGeneric

  # And the same for the return: a method that returns an object costs a handle.
  tablesLock()
  let text = describeResult(gRt, m, res, gHandles, gHandleIsObject, gHandleGc)
  tablesUnlock()
  if text.len == 0:
    return StatusOk
  var t = text
  result = cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(t)),
                    int32(t.len))

proc modGuarded(index: int): bool =
  ## Whether `index` names a row the unload counter can speak about at all.
  ##
  ## A context pointer *is* a mod index for a mod, and `loadMod` refuses past
  ## `ModSlotLimit`, so every real mod is in range. But not every registration
  ## in this host's tables comes from a mod: `hostharness` subscribes under
  ## `0x7FFF` on purpose -- a number no mod table reaches, so that its own
  ## subscriptions survive the mod churn it is there to measure -- and the
  ## overlay and the host itself register under indices of their own.
  ##
  ## `modEnter` answers `false` for those, because its bounds check and its
  ## draining check share one return value. Taken at face value that turns
  ## "there is no library here to protect" into "skip this subscriber", which
  ## is how the churn gate lost the reply to `aowlspt.host.mods.list`. So the
  ## two cases are separated here: out of range means *not a mod*, and a
  ## non-mod is delivered to without a reference because there is nothing that
  ## could be unloaded out from under it.
  ##
  ## A constant rather than `modCount()` deliberately. The count moves on the
  ## tick thread, and an index that tested in-range on the way in and out-of-
  ## range on the way out would drop a `modLeave` and wedge that mod's unload
  ## for good. `ModSlotLimit` cannot change, so the two ends always agree.
  result = index >= 0 and index < modhost.ModSlotLimit

proc deliverEvent(n, body: string; fromIndex: int): int =
  ## One event to every subscriber but `fromIndex`. Factored out because the
  ## **host** emits as well now: the mod-control replies come from here and
  ## pass `-1`, which is not a mod index, so nobody is skipped.
  ## The matching subscribers are taken out under the lock and called outside
  ## it -- the same shape `drainDue` uses, and for the same reason: a subscriber
  ## is a mod's code, it may take as long as it likes and may subscribe again
  ## from inside itself, and holding the host's one lock across it would block
  ## every other thread behind whatever it does. Delivering from a snapshot also
  ## means a mod unloaded mid-delivery cannot shorten the list underneath this
  ## loop.
  ##
  ## The snapshot is exactly what makes a reference necessary. Not shortening
  ## the list is only half the problem: the other half is that these `cb`
  ## pointers point *into the subscriber's library*, and the list they came from
  ## is no longer the thing that keeps that library mapped. `dropModRegistrations`
  ## empties `gSubs` and then `FreeLibrary` runs, and this loop is still holding
  ## the copy. An emit reaches here on the game thread inside a patch while the
  ## host's tick thread is in `modcontrol.drain`, so the two genuinely overlap.
  ## `modhost.modEnter` is the count that unload can see; the ordering that makes
  ## the pair correct is written down where they are.
  ##
  ## A subscriber that is draining is skipped rather than refused loudly -- an
  ## event is a broadcast, and a mod on its way out is exactly a mod that no
  ## longer wants to hear anything. That is the backend's rule for the same loop.
  result = 0
  var cbs: seq[Il2CppPtr] = @[]
  var users: seq[Il2CppPtr] = @[]
  var owners: seq[int] = @[]
  tablesLock()
  for i in 0 ..< gSubs.len:
    if gSubs[i].name != n or gSubs[i].modIndex == fromIndex:
      continue
    cbs.add gSubs[i].cb
    users.add gSubs[i].user
    owners.add gSubs[i].modIndex
  tablesUnlock()
  for i in 0 ..< cbs.len:
    let guard = modGuarded(owners[i])
    if guard and not modhost.modEnter(owners[i]):
      continue
    var b = body
    let st = cInvokeCallback(cbs[i], users[i],
                             cast[Il2CppPtr](toCString(b)), int32(body.len))
    if guard:
      modhost.modLeave(owners[i])
    if st != StatusOk:
      warn "a subscriber to " & n & " returned " & $int(st)
    inc result

proc hostEmit(name, payload: string) =
  discard deliverEvent(name, payload, -1)

proc hostEventEmit(ctx: Il2CppPtr; name: Il2CppPtr; nameLen: int32;
                   payload: Il2CppPtr; payloadLen: int32): int32 {.
    exportc: "aowlspt_nim_event_emit", cdecl.} =
  ## Synchronous, and on whatever thread emitted -- which on this side is
  ## usually the game thread inside a patch. Queueing instead would be safer and
  ## would also mean a mod cannot react to a hook before the hooked method runs,
  ## which is the main reason to have events here at all.
  let n = readBytes(name, nameLen)
  let body = readBytes(payload, payloadLen)
  let from1 = int(cast[uint](ctx))
  # A mod-control request is recorded and performed from the host's own loop.
  # Never from here: this stack is usually the game thread inside a patch, and
  # for an unload it can run through the very mod being unloaded.
  let control = modcontrol.submit(n, body)
  let delivered = deliverEvent(n, body, from1)
  if delivered == 0 and not control:
    info "event " & n & " (no subscribers)"
  result = StatusOk

proc enqueue(cb, user: Il2CppPtr; dueMs: uint64; modIndex: int;
             selfTest: bool) =
  ## The only way into `gPending`, from any thread.
  ##
  ## Under the lock because the caller may be a mod's worker thread while the
  ## drain is running on the game thread -- appending to a seq that another
  ## thread is rebuilding is a corrupted list, not a lost callback. The count
  ## is republished inside the lock so the drain's lock-free empty check can
  ## never see a queue that has entries.
  cMqLock()
  gPending.add Pending(cb: cb, user: user, dueMs: dueMs, modIndex: modIndex,
                       selfTest: selfTest)
  cMqSetCount(int32(gPending.len))
  cMqUnlock()

proc takeDue(due: var seq[Pending]) =
  ## Moves everything due out of `gPending` into `due`, under the lock.
  ##
  ## What is *not* due is compacted down in place rather than copied into a
  ## second seq that replaces `gPending`. The old shape allocated twice a frame
  ## -- once for `due` and once for the replacement -- and freed the buffer
  ## `gPending` already had, so the next frame allocated again. Compacting keeps
  ## that buffer, and `due` is the caller's to reuse, so a steady per-frame
  ## chain allocates nothing at all.
  ##
  ## The write to `gPending[w]` is only ever at an index the read has already
  ## passed (`w <= r` always), so the compaction cannot overwrite an entry it
  ## has not looked at.
  shrink(due, 0)
  cMqLock()
  if gPending.len > 0:
    let now = cNowMs()
    var w = 0
    for r in 0 ..< gPending.len:
      let p = gPending[r]
      if p.dueMs <= now:
        due.add p
      else:
        if w != r:
          gPending[w] = p
        inc w
    if w != gPending.len:
      shrink(gPending, w)
      cMqSetCount(int32(w))
  cMqUnlock()

proc runDue(due: var seq[Pending]) =
  ## Runs what `takeDue` lifted out, **outside** the lock.
  ##
  ## Outside it on purpose: a callback is a mod's code, it may take as long as
  ## it likes, and it may call `invoke_main` again. Running it with the lock
  ## held would block every other thread behind whatever it does. Taking the
  ## work out first is the same shape the backend's timer queue uses.
  for p in due:
    if p.selfTest:
      # The proof, and the reason it is an entry in the queue rather than a
      # log line at bind time: it went in from the host thread and comes out
      # here, so the thread it names is the thread a mod's callback would get.
      # Says where, and -- when nothing bound -- what that means. A mod author
      # reading this log should not have to know that thread 21728 is the
      # host's own to know the callback was not on Unity's.
      if gDrainSlot < 0:
        warn "invoke_main self-test ran on thread " & $int(cThreadId()) &
             ", the host's own thread and not Unity's; a callback queued " &
             "with invoke_main must not touch a Unity object"
      else:
        okLog "invoke_main self-test ran on thread " & $int(cThreadId())
    else:
      # A reference on the owning mod, held across the callback.
      #
      # This is the one dispatch in this host that genuinely races the unload,
      # and it is worth being exact about why. The queue is emptied under the
      # lock above and `dropModRegistrations` rebuilds it under the same lock,
      # so a callback still in `gPending` when a mod is torn down is dropped
      # correctly. What the lock cannot reach is the callback already lifted
      # into `due`: `p.cb` is a function pointer into the mod's library and
      # this loop runs on **Unity's main thread**, while `unloadOne` runs on the
      # host's tick thread a few lines below `modcontrol.drain`. Between the
      # `cMqUnlock` above and this call the tick thread is free to run the
      # teardown and `FreeLibrary`, and then this is a jump into unmapped
      # memory on the game's own thread.
      #
      # `runPending` reaches the same loop from the tick thread, where the
      # unload cannot be concurrent -- the guard is simply uncontended there.
      #
      # The pair costs about 11 ns uncontended. This runs once per due callback
      # rather than once per frame: `mainDrain` returns inside `cMqEnter` when
      # the queue is empty, so a frame with nothing due never reaches here, and
      # a frame with something due is already paying for a call into a mod.
      # A `selfTest` entry is the host's own and has no mod behind it, and
      # `modGuarded` covers the other non-mod queuers -- the harness queues
      # through `invoke_main` and `schedule` under `0x7FFF` exactly as it
      # subscribes under it, and dropping those callbacks would silently gut
      # the churn gate's timer arm rather than fail it.
      let guard = modGuarded(p.modIndex)
      if not guard or modhost.modEnter(p.modIndex):
        discard cInvokeCallback(p.cb, p.user, cast[Il2CppPtr](0), 0'i32)
        if guard:
          modhost.modLeave(p.modIndex)

proc drainDue() =
  ## The drain with a buffer of its own.
  ##
  ## Two callers, and neither is the drain thread in its ordinary frame:
  ## `runPending`, which is the host's tick thread taking the queue back when
  ## no per-frame method bound or the one that did went quiet; and `mainDrain`
  ## re-entered from inside a callback, where `gDue` is already being walked a
  ## frame down the stack. Both are rare and neither is per-frame, so both pay
  ## for their own seq rather than sharing one that would need a lock.
  var due: seq[Pending] = @[]
  takeDue(due)
  runDue(due)

proc runFrameBench()

proc mainDrain() =
  ## The per-frame drain, called from inside a method Unity runs on its main
  ## thread. Everything expensive is behind `cMqEnter`, which answers "is this
  ## my thread, and is there anything to do" in a handful of instructions.
  ##
  ## The bench arm ahead of it is a load of a global and a not-taken branch --
  ## sub-nanosecond, and it is inside the loop the bench times, so the figure
  ## the bench reports includes it rather than excluding its own cost. It is
  ## here rather than in `patchFired` because this is the proc a mod's frame
  ## actually pays for, and a benchmark of the drain that did not run on the
  ## drain's own thread would be measuring a different function.
  if gBenchIters != 0:
    runFrameBench()
  if cMqEnter() == 0'i32:
    return
  if gDraining:
    # Re-entered from inside a callback: `gDue` is live further down this
    # stack, so this nesting takes its own. Without this the inner drain would
    # shrink the buffer the outer one is walking.
    drainDue()
    return
  gDraining = true
  takeDue(gDue)
  runDue(gDue)
  gDraining = false

const BenchModIndex = 0x7FFF0
  ## Past `ModSlotLimit`, so `modGuarded` answers false and the bench's own
  ## entries are dispatched without a `modEnter`/`modLeave` pair on a mod that
  ## does not own them. The pair is about 11 ns and a real mod's callback does
  ## pay it; that is said in the report rather than folded into a row, because
  ## a bench that took a reference on somebody else's library would be holding
  ## an unload open for as long as it ran.

proc benchRow(name: string; t0, t1: int64; iters: int): string =
  ## One row, in picoseconds as well as nanoseconds: the empty-queue drain is a
  ## handful of instructions, and an integer nanosecond figure would round it
  ## to 4 or 5 and hide every change worth making to it.
  let total = nanosBetween(t0, t1)
  result = "{\"op\":\"" & name & "\",\"ns\":" & $(total div int64(iters)) &
           ",\"ps\":" & $((total * 1000'i64) div int64(iters)) &
           ",\"iters\":" & $iters & ",\"totalNs\":" & $total & "}"

proc runFrameBench() =
  ## The per-frame path, timed on the per-frame thread.
  ##
  ## Runs inside one frame of the game (one firing of the detoured method), so
  ## the iteration counts are chosen to keep that frame in the tens of
  ## milliseconds: a stand-in does not care, and this never runs unless a
  ## harness asked for it.
  let base = gBenchIters
  # Cleared first, and that is not tidiness: every loop below calls `mainDrain`,
  # which checks this. Leaving it set is an infinite recursion on the game's
  # own thread.
  gBenchIters = 0
  if base <= 0: return

  let fast = base * 10
  let slow = base
  let cb = cBenchCb()
  let nothing = cast[Il2CppPtr](0)

  # The queue goes aside for the duration. A per-frame chain armed by a mod is
  # almost certainly in it right now, and the empty-queue row would otherwise
  # be timing that mod's callback a hundred thousand times.
  cMqLock()
  var saved = gPending
  gPending = @[]
  cMqSetCount(0'i32)
  cMqUnlock()

  let hits0 = int(cBenchHits())

  # A: nothing queued. This is what every frame costs when no mod has anything
  # pending, which is most frames of most raids.
  let a0 = perfCounter()
  for i in 0 ..< fast:
    mainDrain()
  let a1 = perfCounter()

  # B: something queued, not yet due -- a `schedule` waiting out its delay. The
  # gate lets this frame through and the walk finds nothing to run, so this is
  # the cost of *holding* a timer, per frame, per entry.
  enqueue(cb, nothing, 0xFFFFFFFFFFFF'u64, BenchModIndex, false)
  let b0 = perfCounter()
  for i in 0 ..< fast:
    mainDrain()
  let b1 = perfCounter()
  cMqLock()
  shrink(gPending, 0)
  cMqSetCount(0'i32)
  cMqUnlock()

  # C: the queue turned around once, with no dispatch. Subtracting this from D
  # is what the trampoline into a mod costs.
  var scratch: seq[Pending] = @[]
  let c0 = perfCounter()
  for i in 0 ..< slow:
    enqueue(cb, nothing, 0'u64, BenchModIndex, false)
    takeDue(scratch)
  let c1 = perfCounter()

  # D: one frame of an armed `everyMain` chain -- the mod re-queues itself and
  # the next frame's drain runs it. The allocation counter brackets exactly this
  # loop, because this is the loop that used to allocate two seqs a frame.
  let alloc0 = allocationCount()
  let d0 = perfCounter()
  for i in 0 ..< slow:
    enqueue(cb, nothing, 0'u64, BenchModIndex, false)
    mainDrain()
  let d1 = perfCounter()
  let alloc1 = allocationCount()

  # E and F: what row B is made of. A row that says "31 ns" and nothing else
  # invites a rewrite of the wrong half; these two say how much of it is the
  # gate and how much is the lock, and therefore whether there is anything left
  # to win.
  let e0 = perfCounter()
  for i in 0 ..< fast:
    discard cMqEnter()
  let e1 = perfCounter()

  let f0 = perfCounter()
  for i in 0 ..< fast:
    cMqLock()
    cMqUnlock()
  let f1 = perfCounter()

  let g0 = perfCounter()
  var nowSink = 0'u64
  for i in 0 ..< fast:
    nowSink = nowSink + cNowMs()
  let g1 = perfCounter()

  let hits1 = int(cBenchHits())

  # Whatever arrived from another thread while the bench ran goes back on the
  # end of what was taken aside, in the order it arrived.
  cMqLock()
  for i in 0 ..< gPending.len:
    saved.add gPending[i]
  gPending = saved
  cMqSetCount(int32(gPending.len))
  cMqUnlock()

  gBenchReport = "{\"rows\":[" &
    benchRow("mainDrain, queue empty", a0, a1, fast) & "," &
    benchRow("mainDrain, one entry queued not due", b0, b1, fast) & "," &
    benchRow("enqueue + takeDue, no dispatch", c0, c1, slow) & "," &
    benchRow("enqueue + mainDrain, one chain frame", d0, d1, slow) & "," &
    benchRow("cMqEnter alone, the gate", e0, e1, fast) & "," &
    benchRow("cMqLock plus cMqUnlock, uncontended", f0, f1, fast) & "," &
    benchRow("cNowMs", g0, g1, fast) &
    "],\"nowSink\":" & $(nowSink and 1'u64) &
    ",\"dispatches\":" & $(hits1 - hits0) &
    ",\"chainFrames\":" & $slow &
    ",\"allocDelta\":" & $(alloc1 - alloc0) & "}"
  inc gBenchRuns

proc fireHandler(i: int; payload: string; handleMark, handleTop: int;
                 replacement: var string): int32 =
  ## Hands one payload to a mod's patch handler and cleans up after it.
  ##
  ## Shared by the prefix and the postfix paths because everything except *when*
  ## it happens is the same: the same trampoline into the mod, the same
  ## owned-buffer rule for a replacement, and above all the same handle
  ## lifetime. Every reference in the payload cost a GC handle, and they are all
  ## given back here -- a handler on a per-frame method that was expected to
  ## release them itself would pin objects at frame rate, which is a trap rather
  ## than a contract.
  ##
  ## The table is only shortened when nothing else was added to it while the
  ## handler ran: a handler that called `resolve`, or a method that returned an
  ## object, got handles of its own with higher indices and those are its to
  ## keep. In that case the slots are emptied in place, so nothing is freed
  ## twice and no live handle is renumbered.
  replacement = ""

  # While the handler runs, these two say which handles it may take an address
  # for; afterwards they say which ones it may not. Saved and restored rather
  # than assigned, because a handler is free to call something the host has
  # patched, and an inner firing's cleanup must not close the outer one's scope.
  let prevMark = gPatchHandleMark
  let prevTop = gPatchHandleTop
  gPatchHandleMark = handleMark
  gPatchHandleTop = handleTop
  inc gPatchDepth

  var outPtr: Il2CppPtr = cast[Il2CppPtr](0)
  var outLen = 0'i32
  var a = payload
  let st = cInvokePatchArgs(gPatches[i].cb, gPatches[i].user,
                            cast[Il2CppPtr](addr gPatches[i].targetC[0]),
                            int32(gPatches[i].targetC.len - 1),
                            (if payload.len > 0: cast[Il2CppPtr](toCString(a))
                             else: cast[Il2CppPtr](0)),
                            int32(payload.len),
                            cast[Il2CppPtr](addr outPtr),
                            cast[Il2CppPtr](addr outLen))
  dec gPatchDepth

  if outPtr != nil and outLen > 0'i32:
    replacement = readBytes(outPtr, outLen)
  if outPtr != nil:
    cFreeBuf(outPtr)

  # The reclaim, under the lock and *after* the mod has returned -- never
  # around the call itself. A handler is a mod's code: it may take as long as
  # it likes, it may call `resolve` on this thread (which re-enters the lock
  # harmlessly) or start a thread that does (which would block behind it for
  # as long as the handler ran).
  if handleTop > handleMark:
    tablesLock()
    for k in handleMark ..< handleTop:
      if gHandleIsObject[k] and gHandleGc[k] != 0'u32:
        gcHandleFree(gRt, gHandleGc[k])
      gHandleGc[k] = 0'u32
      gHandles[k] = cast[Il2CppPtr](0)
      gHandleIsObject[k] = false
    if gHandles.len == handleTop:
      shrink(gHandles, handleMark)
      shrink(gHandleIsObject, handleMark)
      shrink(gHandleGc, handleMark)
    else:
      # The handler took handles of its own, so the table cannot be shortened
      # without renumbering them. The firing's own slots are emptied in place
      # above and queued here, which is what stops a handler that calls
      # `resolve` from leaving a hole per firing.
      for k in handleMark ..< handleTop:
        pushFreeHandle(k)
    if gPatchDepth == 0:
      trimHandles()
    tablesUnlock()

  if gPatchDepth > 0:
    # Nested: the outer firing's handles are live again and its scope is the
    # one `handle_pointer` should be judging against.
    gPatchHandleMark = prevMark
    gPatchHandleTop = prevTop
  # Otherwise the range stays as it is, dead, so that a mod asking for one of
  # these afterwards is told what it did rather than "no such handle".
  result = st

proc typedFire(i: int; regs: Il2CppPtr; postfix: bool): int32 =
  ## One firing of a typed patch: arm a pooled frame over the registers the
  ## thunk already saved, call the mod, disarm.
  ##
  ## Compare it with `fireHandler` above, which is the JSON path: that one builds
  ## a string describing the arguments, registers a GC handle for every reference
  ## in it, hands the string across the ABI where the mod copies it into its own
  ## heap and parses it, takes a host-allocated buffer back, and gives every
  ## handle up again. This one stores six words and calls.
  ##
  ## Nothing here touches `gPatchPayloadBytes` or `gPatchHandlesTaken`, and that
  ## is the point: `call("aowlspt.host::patch_stats")` reports both, so a test
  ## can fire a typed hook twenty thousand times and assert that neither moved.
  ##
  ## `gPatchDepth` is raised around the call for the same reason `fireHandler`
  ## raises it -- a handler may itself call something this host has patched --
  ## and it is also what picks the frame out of the pool, so a nested firing
  ## cannot overwrite the outer one's view of the registers.
  if gPatchDepth >= int(cFrameDepthMax()):
    # Deeper than the pool. Letting the original run is the only safe answer:
    # reusing a live frame would hand the inner handler the outer firing's
    # registers, which is a plausible set of arguments rather than an error.
    gTypedTooDeep = gTypedTooDeep + 1
    return 0'i32
  let f = cFrameSlot(int32(gPatchDepth))
  if f == nil:
    gTypedTooDeep = gTypedTooDeep + 1
    return 0'i32
  var flags = gPatches[i].frameFlags
  if postfix: flags = flags or FrameFlagPostfix
  var selfPtr = 0'u64
  if (flags and FrameFlagStatic) == 0'u32:
    selfPtr = cRegsInt(regs, 0'i32)
  # `addr` of element zero rather than the seq itself: the frame points at the
  # bytes, and the array was built at registration and is never rewritten.
  let kinds = (if gPatches[i].kinds.len > 0:
                 cast[Il2CppPtr](addr gPatches[i].kinds[0])
               else: cast[Il2CppPtr](0))
  cFrameArm(f, regs, kinds, int32(gPatches[i].kinds.len),
            int32(gPatches[i].retKind), flags, selfPtr)
  inc gPatchDepth
  gTypedFires = gTypedFires + 1
  let st = cInvokeTypedPatch(gPatches[i].cb, gPatches[i].user, f)
  dec gPatchDepth
  # Before anything else can return. A mod that stored the frame reads a cleared
  # one from here on, and every accessor in `aowlspt_frame.h` refuses it by name
  # rather than answering with the registers of whatever fired next.
  cFrameDisarm(f)
  # No `applyPatchReturn` and no `canSkip` gate. The mod wrote the replacement
  # itself, through a setter that checked it against the declared return kind
  # and answered whether it had written -- so by the time a skip reaches here the
  # value in the frame is of the right shape or the mod chose not to claim one.
  result = (if st == PatchSkipStatus: 1'i32 else: 0'i32)

proc patchFired(slot: int32; regs: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## Called from the detour thunk, on the game thread, inside the patched
  ## method, with every argument register saved in `regs`.
  ##
  ## Returns 0 to let the original run and 1 to suppress it. Suppression is the
  ## sharpest thing this file does: the original never executes, and whatever is
  ## left in the return register is what the game gets. So it happens only when
  ## the patch asked for it *and* a return value of the declared type could
  ## actually be produced -- a skip with garbage in RAX is worse than no skip.
  ##
  ## The cheap path stays cheap. A patch that did not ask for arguments does no
  ## decoding, no allocation and no logging, exactly as before.
  let i = int(slot)
  # The host's own drain hook comes first, and by identity rather than by
  # scanning: it fires on every frame of the game and must not walk anything.
  if i == gDrainSlot:
    mainDrain()
    return 0'i32
  if i < 0 or i >= gPatches.len:
    return 0'i32
  if not gPatches[i].live:
    return 0'i32
  if gPatches[i].isPostfix:
    # A postfix does its work in `patchReturned`, and the thunk branches on the
    # engine's own table before it gets here, so this is unreachable while the
    # two agree. It is checked anyway: if they ever disagreed, running a postfix
    # handler as a prefix would hand it a `result` from the previous call.
    return 0'i32
  gPatchFires = gPatchFires + 1
  if gPatches[i].typed:
    return typedFire(i, regs, false)

  var argsText = ""
  # Where the handle table stood before the arguments were described, so the
  # handles describing them can be given back afterwards. Every reference
  # argument costs a GC handle, and a handler that forgot to release one would
  # pin one object per call -- on a method the game runs per frame per bot,
  # that is a leak measured in objects per second. Expecting a mod to remember
  # on that path is not a contract, it is a trap.
  # The one place the firing path touches a shared table, and the one place it
  # takes the lock. `describeArgs` registers a GC handle per reference argument
  # and appends each to the table, which a mod's worker thread may be appending
  # to at the same moment. It is affordable *here* and nowhere else on this
  # path: the JSON hook already costs some 625 ns a firing, so a critical
  # section is a percent or two of it, where on the typed path -- 23 ns, and no
  # handles at all -- it would be most of the cost.
  tablesLock()
  let handleMark = gHandles.len
  if gPatches[i].wantArgs and gPatches[i].meth != nil:
    argsText = describeArgs(gRt, gPatches[i].meth, regs,
                            gHandles, gHandleIsObject, gHandleGc)
  let handleTop = gHandles.len
  tablesUnlock()
  gPatchPayloadBytes = gPatchPayloadBytes + int64(argsText.len)
  gPatchHandlesTaken = gPatchHandlesTaken + int64(handleTop - handleMark)

  var replacement = ""
  let st = fireHandler(i, argsText, handleMark, handleTop, replacement)

  if st != PatchSkipStatus:
    return 0'i32
  if not gPatches[i].canSkip:
    # Asked to skip without having registered for it. Refused rather than
    # honoured: the mod believes it is a prefix that suppresses, and finding out
    # here beats finding out from a game that behaves strangely.
    return 0'i32
  if gPatches[i].meth == nil:
    return 0'i32
  if not applyPatchReturn(gRt, gPatches[i].meth, regs,
                          (if replacement.len > 0: replacement else: "null")):
    return 0'i32
  result = 1'i32

proc patchReturned(slot: int32; regs: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch_returned", cdecl.} =
  ## The postfix half, called from the thunk **after** the original returned,
  ## still on the game thread and still inside the patched call.
  ##
  ## `regs` holds the argument registers saved on entry, plus what the original
  ## produced: RAX at `ret` and XMM0 at `retf`. Returns 0 to hand the caller
  ## what the original produced and 1 to hand it what the handler wrote instead.
  ##
  ## The payload is the prefix payload with one member added:
  ##
  ##     {"this":{...},"args":[...],"result":6.0}
  ##     {"result":6.0}                            -- no AOWLSPT_PATCH_ARGS
  ##
  ## `result` is always there, whether or not the patch asked for arguments: it
  ## is one value read out of a register, it costs no GC handle unless the
  ## method returns a reference, and it is the reason a postfix exists at all.
  ## The arguments stay opt-in for the reason they always were -- building that
  ## array inside a method the game runs thousands of times a frame is the
  ## expensive half.
  ##
  ## The arguments reported are the **entry** values, because that is where they
  ## still exist: the registers were saved on the way in and the original has
  ## since had its way with everything else. Harmony's postfix has the same
  ## property for by-value parameters and this host cannot do better.
  let i = int(slot)
  if i < 0 or i >= gPatches.len:
    return 0'i32
  if not gPatches[i].live:
    return 0'i32
  if gPatches[i].meth == nil:
    return 0'i32
  gPatchFires = gPatchFires + 1
  if gPatches[i].typed:
    return typedFire(i, regs, true)

  # As on the prefix path: the whole of the table-touching part under the lock,
  # and nothing else.
  tablesLock()
  let handleMark = gHandles.len
  var payload = ""
  # A reference return costs a GC handle exactly as a reference argument does,
  # so the result is described inside the same mark/top bracket and reclaimed by
  # the same cleanup.
  let resultText = describeReturn(gRt, gPatches[i].meth, regs,
                                  gHandles, gHandleIsObject, gHandleGc)
  if gPatches[i].wantArgs:
    let argsText = describeArgs(gRt, gPatches[i].meth, regs,
                                gHandles, gHandleIsObject, gHandleGc)
    # `describeArgs` ends in `}`; the result goes in beside `this` and `args`
    # rather than wrapping them, so a handler reads one object either way and
    # `"args"` still means the declared parameters and nothing else.
    payload = argsText.substr(0, argsText.len - 2) & ",\"result\":" &
              resultText & "}"
  else:
    payload = "{\"result\":" & resultText & "}"
  let handleTop = gHandles.len
  tablesUnlock()
  gPatchPayloadBytes = gPatchPayloadBytes + int64(payload.len)
  gPatchHandlesTaken = gPatchHandlesTaken + int64(handleTop - handleMark)

  var replacement = ""
  let st = fireHandler(i, payload, handleMark, handleTop, replacement)

  if st != PatchSkipStatus:
    return 0'i32
  # No `canSkip` gate here, and that asymmetry is deliberate. A prefix skip from
  # a patch that never asked for arguments is almost always a misregistration --
  # the mod thinks it is suppressing and is not. A postfix replacement cannot be
  # that mistake: the handler was handed the original's answer and returned a
  # different one, which is unambiguous whichever way it registered.
  if not applyPatchReturn(gRt, gPatches[i].meth, regs,
                          (if replacement.len > 0: replacement else: "null")):
    # The declared return type is one no value could be built for. The
    # original's answer stands, which is the only safe way to be wrong here.
    return 0'i32
  result = 1'i32

proc installPatch(ctx: Il2CppPtr; target: Il2CppPtr; targetLen: int32;
                  kind: int32; cb: Il2CppPtr; user: Il2CppPtr;
                  typed: bool): int32 =
  ## Detours a compiled method, which is this side's answer to a Harmony patch.
  ##
  ## One body for both the JSON patch and the typed one, because everything
  ## about *installing* a detour is the same: the same name split, the same
  ## method lookup, the same code-pointer check, the same two postfix refusals,
  ## the same slot bookkeeping. Only what happens when it fires differs, and
  ## that is one field on `Patch`. Two copies of this would be two copies of the
  ## slot-ordering argument below, and one of them would eventually be wrong.
  ##
  ## `kind` carries two things: the patch kind in its low bits, and
  ## `AOWLSPT_PATCH_ARGS` (0x10) to ask for the original arguments. Arguments
  ## are opt-in because decoding them costs a JSON build inside a method the
  ## game may call thousands of times a frame, and a patch that only counts
  ## calls should not pay for that.
  ##
  ## A patch that asked for arguments may also return `PatchSkip` with a
  ## replacement result, and the original will not run.
  ##
  ## A **postfix** runs the other way round: the thunk calls the original,
  ## regains control, and hands the handler what it returned. Two method shapes
  ## cannot carry one and are refused here rather than installed and quietly
  ## useless -- see `postfixRefusal`.
  let spec = readBytes(target, targetLen)
  if cb == nil:
    gLastError = "patch needs a handler"
    return ErrBadArg
  if not gReady:
    gLastError = "the IL2CPP runtime is not up yet"
    return ErrUnsupported

  # `kind` low bits are the patch kind.
  #
  # A prefix and a postfix are two different thunk paths rather than two
  # readings of one: a prefix tail-jumps into the trampoline, which is what
  # makes the original's return value, its stack arguments and its return
  # address correct by construction; a postfix has to *call* it and come back,
  # and pays for that with the two refusals below. Neither is ever silently
  # substituted for the other -- a postfix that behaved like a prefix would hand
  # a mod scaling a getter's result a value the original had not produced yet,
  # and the number it wrote would be wrong rather than absent.
  #
  # A finalizer is still refused, and not for want of machinery: its whole
  # contract is about the exception in flight, and an exception does not cross
  # this ABI in any form the other side could act on. An unwind out of the
  # original does not even reach the postfix path -- it skips the rest of the
  # thunk by definition -- so there is nothing here to build it out of.
  let patchKind = kind and 0x0F'i32
  let isPostfix = patchKind == 1'i32
  if patchKind != 0'i32 and not isPostfix:
    gLastError = "unsupported patch kind " & $int(patchKind) &
                 (if patchKind == 2'i32:
                    "; a finalizer patch is not bridged, because a managed " &
                    "exception cannot cross this ABI"
                  else: "")
    return ErrUnsupported

  let sep = find(spec, "::")
  if sep < 0:
    gLastError = "patch target must be Type::Method, got: " & spec
    return ErrBadArg
  let typePart = spec.substr(0, sep - 1)
  let member = spec.substr(sep + 2)

  let cls = findClass(gRt, typePart)
  if cls == nil:
    gLastError = "no such type: " & typePart
    return ErrNotFound

  # -1 matches any arity: a patch names a method, not a signature.
  let m = findMethod(gRt, cls, member, -1)
  if m == nil:
    gLastError = "no method " & member & " on " & typePart
    return ErrNotFound

  let fn = methodPointer(gRt, m)
  if fn == nil:
    gLastError = "could not read a usable code pointer for " & spec &
                 " (the method may not be compiled yet)"
    return ErrUnsupported

  # The two shapes a postfix cannot carry, checked against the method rather
  # than against the patch kind alone: a value-type return wider than a
  # register, which comes back through a buffer whose layout this host cannot
  # read, and a compiled call with stack arguments, which a called original
  # would look for in the thunk's frame. Both would install cleanly and be
  # wrong at run time, which is why they are refused at registration with a
  # sentence naming which one it was.
  if isPostfix:
    let refusal = postfixRefusal(gRt, m, spec)
    if refusal.len > 0:
      gLastError = refusal
      return ErrUnsupported

  # The slot comes from the engine, and it comes *first*.
  #
  # This used to be `gPatches.len` and a check afterwards that the engine had
  # agreed. It agreed because both counters only ever went up -- and that was
  # the bug rather than the invariant: removing a detour freed its trampoline
  # and put the method's bytes back, but neither the engine's slot nor this
  # table's row was ever spare again, so a mod switched off and on again spent
  # a slot each time and the sixteenth cycle was the end of patching for the
  # session. Now the engine hands out a reclaimed slot and this file writes the
  # row at that index, which makes the two agree by construction rather than by
  # a check that could only ever report the disagreement.
  # From here to the end of this proc, under the lock.
  #
  # A mod may call `patch` from any thread it likes, and the host's own tick
  # thread may be taking another mod's detours out at the same moment: the
  # engine's free list, its generation table and this file's row for the slot
  # are three structures that have to move together, and two threads claiming
  # slots at once would interleave through all three. It is not on the firing
  # path -- installing a detour happens at human rates -- so this is the cheap
  # half of the bargain the block at the top of this file describes.
  tablesLock()
  let claimed = cHookClaim()
  if claimed < 0'i32:
    tablesUnlock()
    gLastError = "no free patch slots (" & $int(cHookCapacity()) &
                 " in use); every one of them belongs to a live patch"
    return ErrUnsupported

  let hook = cHookNew()
  if hook == nil:
    cHookRelease(claimed)
    tablesUnlock()
    gLastError = "out of memory"
    return ErrGeneric

  var targetBytes = newSeq[byte](spec.len + 1)
  for k in 0 ..< spec.len:
    targetBytes[k] = byte(spec[k])
  targetBytes[spec.len] = 0'u8
  # `AOWLSPT_PATCH_ARGS` is not consulted for a typed patch, and a typed prefix
  # may always suppress. Both because the flag exists to avoid a cost that does
  # not arise here: the arguments are in the frame whether or not anybody reads
  # them, so there is no "registered without arguments" state for a suppression
  # to be a mistake about.
  let wantArgs = (not typed) and (kind and 0x10'i32) != 0'i32
  # The shapes, worked out once. This is the whole optimisation: `frameKinds`
  # asks the runtime what every parameter is, here, at registration -- and the
  # JSON path asks the same questions on every firing for an answer that cannot
  # have changed.
  let kinds = frameKinds(gRt, m)
  let retKind = argKindOf(gRt, methodReturnType(gRt, m))
  let frameFlags = (if methodIsStatic(gRt, m): FrameFlagStatic else: 0'u32)
  # The row is written before the hook lands, never after, and at the slot the
  # engine handed out. The table is grown with dead rows where it has to be:
  # the engine may hand back slot 3 while this table is two rows long, and a
  # row that is not there when the thunk fires is a firing that indexes past
  # the end.
  while gPatches.len <= int(claimed):
    gPatches.add deadPatch()
  gPatches[int(claimed)] = Patch(hook: hook, cb: cb, user: user, target: spec,
                     targetC: targetBytes, live: false, meth: m,
                     wantArgs: wantArgs, canSkip: wantArgs or typed,
                     modIndex: int(cast[uint](ctx)), isDrain: false,
                     isPostfix: isPostfix, typed: typed, kinds: kinds,
                     retKind: retKind, frameFlags: frameFlags)
  # Armed before the hook lands, never after. The thunk reads the engine's
  # table on entry and the game can reach the patched method on the very next
  # instruction, so a postfix armed a moment late would run its first firings as
  # a prefix -- and a prefix handler that was written as a postfix reads a
  # `result` that does not exist yet.
  cHookSetPostfix(claimed, (if isPostfix: 1'i32 else: 0'i32))
  let rc = cHookAttachAt(hook, fn, claimed)
  if rc != 0'i32:
    cHookSetPostfix(claimed, 0'i32)
    gPatches[int(claimed)] = deadPatch()
    cHookFree(hook)
    cHookRelease(claimed)
    tablesUnlock()
    gLastError = "could not patch " & spec & ": " &
                 readCString(cHookErrorText(rc))
    return ErrGeneric

  let slot = claimed
  gPatches[int(slot)].live = true
  tablesUnlock()
  okLog "patched " & spec & " (" & $int(cHookStolen(hook)) & " bytes" &
        (if isPostfix: ", postfix" else: "") &
        (if typed: ", typed" else: "") & ")"
  result = StatusOk

proc hostPatch(ctx: Il2CppPtr; target: Il2CppPtr; targetLen: int32;
               kind: int32; cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch", cdecl.} =
  ## `AowlHostApi.patch`: the handler is handed a JSON description of the
  ## firing.
  installPatch(ctx, target, targetLen, kind, cb, user, false)

proc hostPatchTyped(ctx: Il2CppPtr; target: Il2CppPtr; targetLen: int32;
                    kind: int32; cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch_typed", cdecl.} =
  ## `AowlHostApi.patch_typed` (ABI revision 4): the handler is handed a
  ## borrowed view of the registers instead.
  ##
  ## A separate export rather than a flag on `hostPatch`, because `cb` is a
  ## different function-pointer shape -- an `AowlTypedPatchFn` takes two
  ## parameters where an `AowlPatchFn` takes four -- and the two are both
  ## `void*` by the time they reach this file. Getting that wrong would be a
  ## handler reading its frame out of a register nobody set, so the distinction
  ## is made where the type still exists: in `aowlspt_live.h`, on the way in.
  installPatch(ctx, target, targetLen, kind, cb, user, true)

proc bindMainDrain(verbose: bool): bool =
  ## Detours a method Unity calls once per frame on its main thread, so that
  ## `invoke_main` can be drained from *there* rather than from the host's own
  ## attached thread.
  ##
  ## Which method is a research question this host cannot answer at compile
  ## time, and this is the honest state of it.
  ##
  ## Unity's player loop is native C++ and is not in the metadata, so there is
  ## no `PlayerLoop::Update` to look up. What is reachable by name is *managed*
  ## code the loop calls, and a candidate has to be all four of: called every
  ## frame, called on the main thread only, present for the whole session, and
  ## compiled into a function whose first bytes the detour engine can relocate.
  ## The four below are tried in order, most specific first:
  ##
  ##   `EFT.MainApplication::Update` -- the game's own root behaviour. If it
  ##   exists it is the best of these: once a frame, main thread, alive from the
  ##   menu to the desktop. The name is what the class is called in pre-1.0
  ##   dumps and has **not** been verified against a post-1.0 client by anyone
  ##   who wrote this file, which is exactly why this is a list and not a
  ##   constant.
  ##
  ##   `EFT.GameWorld::Update` -- narrower, and certain to be absent in the
  ##   menu, so it can only ever be the answer inside a raid. Kept because a
  ##   raid is where a mod most wants the main thread, and because binding late
  ##   beats not binding.
  ##
  ##   `UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate` -- uGUI's per-frame
  ##   layout and graphic rebuild, driven from `Canvas.willRenderCanvases` on
  ##   the main thread. Engine code, so it is present whenever the UI module is,
  ##   which for this game is always. This is the reliable fallback.
  ##
  ##   `UnityEngine.Time::get_deltaTime` -- last, and reluctantly. It is a Unity
  ##   API that may only be called from the main thread, so whoever calls it is
  ##   on that thread; but it is called *many* times per frame rather than once,
  ##   and it is a small function whose compiled body may well be shorter than
  ##   the fourteen bytes a jump needs -- in which case the engine refuses it
  ##   and this loop moves on, which is the right outcome rather than a failure.
  ##
  ## Whichever binds gets the same treatment: an empty drain costs a handful of
  ## instructions, so being called ten times a frame instead of once is a
  ## difference in noise rather than in frame time.
  ##
  ## The hook goes through the same engine and the same slot table as a mod's
  ## patch, and is entered in `gPatches` like one. It has to be: the engine
  ## hands slots out in ascending order and the firing path indexes `gPatches`
  ## by slot, so a host hook kept outside that table would shift every mod's
  ## slot by one and deliver each patch to the wrong handler.
  if gDrainSlot >= 0:
    return true
  if not gReady:
    return false

  # Built here rather than as a module-level `seq`: a global whose initialiser
  # is a call is silently left zeroed in an `--app:lib` build.
  var candidates: seq[string] = @[]
  candidates.add "EFT.MainApplication::Update"
  candidates.add "EFT.GameWorld::Update"
  candidates.add "UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate"
  candidates.add "UnityEngine.Time::get_deltaTime"

  # Whether each candidate runs once per frame, in the same order. The first
  # three are the player loop calling a method it calls once; the last is a
  # property anything may read, several times a frame, which is why it is the
  # last resort. A mod is told this through `aowlspt.host::main_thread` so it
  # can say "frames" only when that is what it is counting.
  var perFrame: seq[bool] = @[]
  perFrame.add true
  perFrame.add true
  perFrame.add true
  perFrame.add false

  var candidateIndex = -1

  for spec in candidates:
    inc candidateIndex
    let sep = find(spec, "::")
    if sep < 0:
      continue
    let typePart = spec.substr(0, sep - 1)
    let member = spec.substr(sep + 2)

    let cls = findClass(gRt, typePart)
    if cls == nil:
      if verbose: info "no per-frame candidate " & typePart & " in this build"
      continue
    # -1: a per-frame update takes no arguments, but naming an arity here would
    # miss an overload set and there is nothing to gain from being strict.
    let m = findMethod(gRt, cls, member, -1)
    if m == nil:
      if verbose: info typePart & " has no " & member
      continue
    let fn = methodPointer(gRt, m)
    if fn == nil:
      if verbose: info "no usable code pointer for " & spec
      continue

    # Same lock as `installPatch`, for the same reason: this claims a slot and
    # writes its row, and a mod's `patch` on another thread does too. It is the
    # host's own hook, and it is not exempt from the rule.
    tablesLock()
    let claimed = cHookClaim()
    if claimed < 0'i32:
      tablesUnlock()
      warn "no free patch slots for the main-thread drain"
      return false
    let hook = cHookNew()
    if hook == nil:
      cHookRelease(claimed)
      tablesUnlock()
      return false

    var targetBytes = newSeq[byte](spec.len + 1)
    for k in 0 ..< spec.len:
      targetBytes[k] = byte(spec[k])
    targetBytes[spec.len] = 0'u8
    while gPatches.len <= int(claimed):
      gPatches.add deadPatch()
    gPatches[int(claimed)] = Patch(hook: hook, cb: cast[Il2CppPtr](0),
                       user: cast[Il2CppPtr](0), target: spec,
                       targetC: targetBytes, live: true, meth: m,
                       wantArgs: false, canSkip: false, modIndex: -1,
                       isDrain: true, isPostfix: false, typed: false,
                       kinds: @[], retKind: 0'u8, frameFlags: 0'u32)
    let rc = cHookAttachAt(hook, fn, claimed)
    if rc != 0'i32:
      gPatches[int(claimed)] = deadPatch()
      cHookFree(hook)
      cHookRelease(claimed)
      tablesUnlock()
      if verbose:
        info "cannot drain from " & spec & ": " &
             readCString(cHookErrorText(rc))
      continue

    let slot = claimed
    gDrainSlot = int(slot)
    tablesUnlock()
    gDrainMethod = spec
    gDrainPerFrame = candidateIndex < perFrame.len and perFrame[candidateIndex]
    okLog "main-thread drain bound to " & spec & " (" &
          $int(cHookStolen(hook)) & " bytes)" &
          (if gDrainPerFrame: "" else:
             "; it runs more than once a frame, so its firing count is not a " &
             "frame count")
    return true

  result = false

proc hostEventSubscribe(ctx: Il2CppPtr; name: Il2CppPtr; nameLen: int32;
                        cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_event_subscribe", cdecl.} =
  let n = readBytes(name, nameLen)
  if n.len == 0 or cb == nil:
    gLastError = "a subscription needs a name and a handler"
    return ErrBadArg
  tablesLock()
  gSubs.add Sub(name: n, cb: cb, user: user, modIndex: int(cast[uint](ctx)))
  tablesUnlock()
  okLog "subscribed to " & n
  result = StatusOk

# --------------------------------------------------------------- store

proc guidOf(idx: int): string = modhost.modGuidOf(idx)

proc hostStoreGet(ctx: Il2CppPtr; key: Il2CppPtr; keyLen: int32;
                  outPtr, outLen: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_store_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[Il2CppPtr](0), 0'i32)
  let k = readBytes(key, keyLen)
  let guid = guidOf(int(cast[uint](ctx)))
  if guid.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  var value = ""
  var error = ""
  if not storeRead(guid, k, value, error):
    gLastError = error
    return ErrNotFound
  var v = value
  result = cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(v)), int32(v.len))

proc hostStoreSet(ctx: Il2CppPtr; key: Il2CppPtr; keyLen: int32;
                  val: Il2CppPtr; valLen: int32): int32 {.
    exportc: "aowlspt_nim_store_set", cdecl.} =
  let k = readBytes(key, keyLen)
  let v = readBytes(val, valLen)
  let guid = guidOf(int(cast[uint](ctx)))
  if guid.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  var error = ""
  if not storeWrite(guid, k, v, error):
    gLastError = error
    return ErrGeneric
  result = StatusOk

proc hostStoreList(ctx: Il2CppPtr; prefix: Il2CppPtr; prefixLen: int32;
                   outPtr, outLen: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_store_list", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[Il2CppPtr](0), 0'i32)
  let p = readBytes(prefix, prefixLen)
  let guid = guidOf(int(cast[uint](ctx)))
  if guid.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  var v = storeKeys(guid, p)
  result = cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(v)), int32(v.len))

proc hostInvokeMain(ctx: Il2CppPtr; cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_invoke_main", cdecl.} =
  ## Queued for whichever thread drains it, which is the point of this whole
  ## file's newest part: when a per-frame method could be detoured, that is
  ## Unity's own main thread and the name means what it says. When none could,
  ## it is the host's own attached thread, and the log says so at boot rather
  ## than letting the name imply otherwise. A mod can ask which it got --
  ## `call("aowlspt.host::main_thread")`.
  if cb == nil:
    return ErrBadArg
  enqueue(cb, user, cNowMs(), int(cast[uint](ctx)), false)
  result = StatusOk

proc hostSchedule(ctx: Il2CppPtr; delayMs: int32; cb: Il2CppPtr;
                  user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_schedule", cdecl.} =
  ## Same queue, same thread as `invoke_main`, and deliberately so.
  ##
  ## The alternative was to leave delayed callbacks on the host thread, where
  ## the timing is better: the host ticks every 16ms regardless of what the
  ## game is doing, whereas the drain resolves a delay at frame granularity and
  ## a frame can be long. That was rejected. A mod that says "do this in two
  ## seconds" almost always means work of the same kind `invoke_main` carries,
  ## and if `schedule` stayed on the host thread the only way to get a *delayed
  ## main-thread* call would be to schedule a callback that calls `invoke_main`,
  ## paying two hops and an extra frame for something the host can just do. The
  ## cost is honest and small: a delay is now "at the first frame at or after
  ## the deadline", not "within a millisecond of it".
  if cb == nil:
    return ErrBadArg
  var d = delayMs
  if d < 0'i32: d = 0'i32
  enqueue(cb, user, cNowMs() + uint64(d), int(cast[uint](ctx)), false)
  result = StatusOk

# --------------------------------------------------------------- mods
#
# The loader is `host/common/modhost.nim` and is shared with the backend:
# discovery, the ABI version probe, `describe`/`init`/`on_load`, the mod table,
# ticking, and taking one out again. This host used to carry a near-verbatim
# copy of all of it. What is left here is the part that is genuinely this
# host's: what a mod leaves behind in *this* process, and the one entry in the
# host block only a host with a managed heap can fill.

proc armLive(hostBlock: Il2CppPtr) =
  ## `modhost.setHostBlockArm` calls this once per mod, after
  ## `aowl_hostapi_new` has built the block and before `aowlspt_init` is handed
  ## it. See `cHostApiArmLive` above for why the shared builder cannot do it.
  cHostApiArmLive(hostBlock)
  # And revision 4, after it, so `size` only ever grows. Two calls rather than
  # one because they are two capabilities: `handle_pointer` needs a managed heap
  # and `patch_typed` needs the detour engine, and `size` is a statement about
  # what was filled rather than about which header this was built from.
  cHostApiArmTyped(hostBlock)

proc dropModRegistrations(index: int) =
  ## Everything the mod at `index` left in this host, dropped before its library
  ## is freed.
  ##
  ## Order within this proc does not matter; the order *around* it does, and the
  ## loader guarantees it -- this runs after the mod's `on_unload` and before
  ## `FreeLibrary`. Every item here holds a function pointer into that library,
  ## so anything missed becomes a call into unmapped memory: a detour the game
  ## still jumps to, a subscriber an event still reaches, a timer that still
  ## comes due.
  tablesLock()
  var kept: seq[Sub] = @[]
  for sub1 in gSubs:
    if sub1.modIndex != index:
      kept.add sub1
  gSubs = kept
  tablesUnlock()

  # Under the lock, because the drain runs on the game thread and may be part
  # way through this same list while a mod is being unloaded.
  cMqLock()
  var keptPending: seq[Pending] = @[]
  for pend in gPending:
    if pend.modIndex != index:
      keptPending.add pend
  gPending = keptPending
  cMqSetCount(int32(gPending.len))
  cMqUnlock()

  # The detours, under the lock: this releases slots back to the engine while
  # another thread may be claiming one, and it bumps each slot's generation --
  # which is what makes a firing that is in flight right now get dropped rather
  # than delivered to whoever takes the slot next. `okLog` is inside it and
  # that is a file write under a lock; it happens once per removed detour, on
  # an unload, and the alternative is collecting the names to print afterwards
  # for no benefit anybody can measure.
  tablesLock()
  for i in 0 ..< gPatches.len:
    if gPatches[i].live and gPatches[i].modIndex == index:
      let what = gPatches[i].target
      gPatches[i].live = false
      discard cHookRemove(gPatches[i].hook)
      # The engine's postfix table is indexed by slot and outlives the hook, so
      # it is cleared here too. A slot left armed would send the next patch to
      # take it down the postfix path with a prefix handler on the other end.
      cHookSetPostfix(int32(i), 0'i32)
      cHookFree(gPatches[i].hook)
      # And the slot itself, which is the whole point of a teardown that runs
      # while the game is still going. Without this the pool was one-way: the
      # method's bytes went back and the trampoline was freed, but the slot
      # stayed spent, so sixteen mod toggles into a session `patch()` answered
      # "no free patch slots" with every one of them holding nothing.
      #
      # The row is cleared to match. `cHookRelease` may hand this slot out
      # again, and a stale row would put the old mod's handler pointer -- into
      # a library that has been freed -- behind the new patch's number.
      gPatches[i] = deadPatch()
      cHookRelease(int32(i))
      okLog "removed the detour on " & what
  tablesUnlock()

proc digitsIn(text: string): int =
  ## The last run of digits in a string, as a number. Used on a url, where the
  ## port is the only number that can appear after the host -- `127.0.0.1:6969`
  ## gives 6969 rather than 127.
  result = 0
  var n = 0
  var any = false
  for ch in text:
    if ch >= '0' and ch <= '9':
      n = n * 10 + (ord(ch) - ord('0'))
      any = true
    else:
      if any:
        result = n
      n = 0
      any = false
  if any:
    result = n

proc readBackendPort(): int =
  ## The port the backend is on. Zero means "do not try", and the overlay then
  ## shows what the host knows rather than nothing at all.
  ##
  ## Two places, in order. `aowlspt-host.json`'s `backendPort` is the player's
  ## own setting and wins. Failing that, `backend.json` -- which the **installer**
  ## writes, naming the backend it just installed. Without that second half the
  ## shipped default (`backendPort: 0`) left the overlay and the in-game mod
  ## manager switched off on every fresh install, next to a file that said
  ## exactly where the backend was, and the only way to find out was to read the
  ## documentation for a setting nobody knew they needed.
  result = 0
  var text = ""
  if readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    var value = ""
    if pathGet(text, "backendPort", value):
      result = digitsIn(value)
  if result > 0:
    return
  var cfg = ""
  if readTextFile(joinPath(gDir, "backend.json"), cfg):
    var url = ""
    if pathGet(cfg, "backendUrl", url):
      let port = digitsIn(url)
      # A url with no port in it (`http://localhost/`) means the default HTTP
      # port, which this backend never listens on; treating that as a port
      # would have the host talk to something that is not it.
      if port > 0 and port < 65536:
        result = port

proc removePatches() =
  ## Every detour comes out before the host stops. Leaving one installed means
  ## the game jumps into a DLL that may be gone.
  tablesLock()
  for i in 0 ..< gPatches.len:
    if gPatches[i].live:
      gPatches[i].live = false
      discard cHookRemove(gPatches[i].hook)
      cHookSetPostfix(int32(i), 0'i32)
      cHookFree(gPatches[i].hook)
      gPatches[i] = deadPatch()
      cHookRelease(int32(i))
  tablesUnlock()

proc readSyncMs(): int =
  ## How often to ask the backend which client-side mods should be running,
  ## from `aowlspt-host.json`, key `modSyncMs`. Zero switches the whole thing
  ## off and leaves this host doing exactly what it did before it existed.
  ##
  ## Three seconds by default. It is a control loop over loaded code, not a
  ## display: the change it reacts to is a person clicking a switch, and the
  ## difference between reacting in one second and in three is not worth a
  ## request per second for the rest of the session.
  result = 3000
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    return
  var value = ""
  if pathGet(text, "modSyncMs", value):
    var n = 0
    var any = false
    for ch in value:
      if ch >= '0' and ch <= '9':
        n = n * 10 + (ord(ch) - ord('0'))
        any = true
    if any: result = n

proc stopOverlay() =
  if overlayRunning():
    overlayStop()

proc opsCount(): int = modhost.modCount()
proc opsGuid(i: int): string = modhost.modGuidOf(i)
proc opsName(i: int): string = modhost.modNameOf(i)
proc opsVersion(i: int): string = modhost.modVersionOf(i)
proc opsPath(i: int): string = modhost.modPathOf(i)
proc opsLive(i: int): bool = modhost.modIsLive(i)
proc opsFlags(i: int): uint32 = modhost.modFlagsOf(i)
proc opsIndex(guid: string): int = modhost.modIndexOf(guid)

proc opsCanUnload(ignored: int): bool = modhost.hasTeardown()
  ## True here in every run that reached `hostMain`, which installs
  ## `dropModRegistrations` before it loads anything. Asked of the loader
  ## rather than answered `true` outright: the loader is what refuses an
  ## unload without a teardown, and a capabilities reply that disagreed with it
  ## would have the manager offer a switch that always answers "deferred".

proc opsLoad(path: string): bool =
  modhost.loadOne(path, modhost.SideClient, HostName, HostVersion)

proc opsUnload(guid: string): string =
  ## Empty on success; otherwise the sentence the manager shows.
  ##
  ## `modhost.unloadByGuid` runs the mod's `on_unload`, then the teardown
  ## installed below -- which is where this host's detours, subscriptions and
  ## queued callbacks go -- and only then frees the library. The slot is kept
  ## rather than removed, because every context pointer handed to a mod is its
  ## index and compacting would repoint the survivors at their neighbours.
  var err = ""
  if not modhost.unloadByGuid(guid, err):
    return (if err.len > 0: err else: "the host refused to unload " & guid)
  # The overlay's row, marked stopped rather than dropped. Read back out of the
  # slot, which is still there: the loader keeps dead slots so that the context
  # pointers it handed out stay pointing at the right mod, and a dead slot
  # still carries what that mod said about itself.
  for i in 0 ..< modhost.modCount():
    if modhost.modGuidOf(i) == guid:
      overlaySetMod(guid, modhost.modNameOf(i), modhost.modVersionOf(i), false)
  result = ""

proc opsLog(msg: string) = info msg

proc startModControl() =
  modcontrol.controlInit(HostName, HostVersion, modhost.SideClient,
                         hostEmit,
                         HostOps(count: opsCount, guidOf: opsGuid,
                                 nameOf: opsName, versionOf: opsVersion,
                                 pathOf: opsPath, liveOf: opsLive,
                                 flagsOf: opsFlags, indexOf: opsIndex,
                                 canUnload: opsCanUnload, load: opsLoad,
                                 unload: opsUnload, log: opsLog))

# --------------------------------------------------------------- runtime

proc waitForIl2Cpp(timeoutMs: int): bool =
  ## The host is injected before the game has built its runtime, so this waits.
  ##
  ## What it waits *on* is the correction of a crash. This used to poll
  ## `il2cpp_domain_get` until it answered, on the reasoning -- written in the
  ## comment that was here -- that the module appears well before the domain
  ## does, so the module alone is not enough to go on. The first half of that
  ## is true. The conclusion drawn from it was not: `il2cpp_domain_get` before
  ## `il2cpp_init` has run does not return nil, it reads a global that has not
  ## been written and faults inside the runtime. On the first real client this
  ## took the game down, with our own frame directly above the runtime's in
  ## `Player.log`. There is nothing here that can be polled, because *asking is
  ## the unsafe act*.
  ##
  ## So the signal comes from the other side: `aowlspt_il2cppready.h` arms a
  ## replacement for `GetProcAddress` in `UnityPlayer.dll`'s import table in
  ## the DLL constructor, and sets a flag when the `il2cpp_init` it handed out
  ## returns. Until that flag is set this touches nothing in the runtime -- not
  ## even to open it, since `openIl2Cpp` resolves exports and there is no need
  ## to have them before there is a domain to use them on.
  var waited = 0
  var nextNote = 10000
  # Said as soon as it is known, not at the end.
  #
  # The timeout report below carries the same numbers, and on the first real
  # client it never printed once: the game exited in under ten seconds, so the
  # only line that would have explained why was one the process did not live
  # long enough to write. A diagnosis that is only produced after a two-minute
  # wait is not available for any failure that is faster than two minutes --
  # which is most of them.
  var toldInit = 0
  while waited < timeoutMs:
    if cIl2Calls() != toldInit:
      toldInit = cIl2Calls()
      if cIl2Rc() != 0:
        okLog "il2cpp_init returned " & $cIl2Rc() & " after " & $waited & "ms"
      else:
        fail "il2cpp_init returned 0 after " & $waited & "ms, which is a " &
             "failure: the runtime did not initialise. Nothing will resolve, " &
             "and this is the game's own failure rather than the host's"
    if cIl2Ready() != 0:
      if not gRt.loaded:
        gRt = openIl2Cpp("")
      if gRt.loaded:
        # Safe now, and only now. A nil here is a real answer rather than a
        # fault, and is reported as one instead of being retried forever.
        let d = domainGet(gRt)
        if d != nil:
          gDomain = d
          okLog "IL2CPP is up after " & $(waited div 100 * 100) & "ms: " &
                "il2cpp_init returned " & $cIl2Rc() & " and was handed out " &
                $cIl2Seen() & " time(s)"
          return true
        fail "il2cpp_init returned " & $cIl2Rc() & " but there is no domain; " &
             "refusing to call into the runtime"
        return false
      fail "il2cpp_init has run but GameAssembly.dll could not be opened"
      return false
    cSleep(100'i32)
    waited = waited + 100
    if waited >= nextNote:
      # Otherwise a slow launch is indistinguishable from a hung host -- and
      # since the arming is what makes this terminate, say whether it happened.
      if cIl2Armed() == 0:
        warn "still waiting for the runtime (" & $(waited div 1000) & "s), " &
             "and nothing is watching for it: the il2cpp_init lookup was " &
             "never armed, so this will wait out its timeout"
      else:
        info "still waiting for the runtime (" & $(waited div 1000) & "s)"
      nextNote = nextNote + 10000
  # Not just "it did not come up": what was watched, whether the watch was
  # armed, and what the runtime said the last time it was asked to initialise.
  # A zero here is `il2cpp_init` reporting failure, which is a different
  # problem from a slow disk and must not read like one.
  fail "the runtime did not come up: the il2cpp_init lookup was " &
       (if cIl2Armed() != 0: "armed" else: "NOT armed") &
       ", init was handed out " & $cIl2Seen() & " time(s), called " &
       $cIl2Calls() & " time(s), and last returned " & $cIl2Rc() &
       " (non-zero is success)"
  result = false

proc readWaitMs(): int =
  ## `aowlspt-host.json` beside the DLL, key `waitForRuntimeMs`.
  ##
  ## Two minutes suits a cold launch of the real game off a slow disk. A test
  ## harness has no runtime coming at all and wants to find that out in
  ## seconds, which is the whole reason this is a setting rather than a
  ## constant.
  result = 120000
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    return
  let needle = "\"waitForRuntimeMs\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  var v = 0
  var any = false
  while i < text.len and text[i] >= '0' and text[i] <= '9':
    v = v * 10 + (ord(text[i]) - ord('0'))
    any = true
    inc i
  if any:
    result = v

# ------------------------------------------------------- backend key dump
#
# One-shot, diagnostic: read the client's baked HTTP body-crypto material so a
# captured session can be decrypted offline. Post-1.0 encrypts /client/game/*
# response bodies with AES (see reference_post1_aes_layer); the key and IV pool
# live as static byte[] fields on the global `HTTPTransportManager`. The three
# reads below (byte_at / read_ptr / is_readable) are the same C shims il2cpp.nim
# uses; they are re-declared here because that module keeps them file-private.
proc hByteAt(p: Il2CppPtr; i: uint64): uint8 {.importc: "aowl_byte_at", nodecl.}
proc hReadPtr(p: Il2CppPtr; off: int32): Il2CppPtr {.importc: "aowl_read_ptr", nodecl.}
proc hReadable(p: Il2CppPtr; size: int32): int32 {.importc: "aowl_is_readable", nodecl.}

proc il2ByteArrayHex(arrPtr: Il2CppPtr): string =
  ## An IL2CPP `byte[]` as hex: element count at +0x18, data at +0x20. Every
  ## read is VirtualQuery-guarded to its FULL extent first -- a raw read past a
  ## committed region faults on the host thread and takes the whole game down
  ## (which is exactly what an under-guarded first attempt did).
  if arrPtr == nullPtr() or hReadable(arrPtr, 0x20'i32) == 0'i32:
    return "<unreadable>"
  let n = int(cast[uint](hReadPtr(arrPtr, 0x18'i32)))
  if n < 0 or n > 8192: return "<len " & $n & ">"
  if hReadable(arrPtr, int32(0x20 + n)) == 0'i32:
    return "<data unreadable, len " & $n & ">"
  const digits = "0123456789abcdef"
  result = ""
  for i in 0 ..< n:
    let b = hByteAt(arrPtr, uint64(0x20 + i))
    result.add digits[int(b shr 4'u8)]
    result.add digits[int(b and 0xF'u8)]

proc staticFieldPtr(cls: Il2CppClass; fieldName: string): Il2CppPtr =
  ## No `runtimeClassInit` here: it RUNS the managed static constructor, and on
  ## the host's own (non-Unity) thread that faults and kills the game. By the
  ## time this runs the client has long since initialised the class itself, so
  ## the static data is already there to read -- these are pure C-API reads.
  okLog "keydump: findField " & fieldName
  let f = findField(gRt, cls, fieldName)
  okLog "keydump: findField returned"
  if f == nullPtr():
    warn "keydump: field " & fieldName & " not found"
    return nullPtr()
  let sdata = staticFieldData(gRt, cls)
  okLog "keydump: staticFieldData returned"
  if sdata == nullPtr():
    warn "keydump: no static data for " & fieldName
    return nullPtr()
  let off = fieldOffset(gRt, f)
  okLog "keydump: " & fieldName & " off=" & $off
  if off < 0 or off > 65536: return nullPtr()
  if hReadable(sdata, int32(off + 8)) == 0'i32:
    warn "keydump: static slot for " & fieldName & " unreadable"
    return nullPtr()
  result = hReadPtr(sdata, int32(off))

proc dumpBackendKey() =
  okLog "keydump: starting"
  var count = 0
  let assemblies = domainGetAssemblies(gRt, gDomain, count)
  if assemblies == nil: return
  # Find the class by ENUMERATING real classes (imageGetClass by index) and
  # matching the name -- classFromName with an empty namespace handed back bogus
  # non-NULL pointers whose name read faulted. Every class from imageGetClass is
  # a real one, so className on it is safe (guarded anyway).
  var cls: Il2CppClass = nullPtr()
  for i in 0 ..< count:
    let image = assemblyGetImage(gRt, assemblyAt(assemblies, i))
    if image == nil: continue
    if imageGetName(gRt, image) != "Assembly-CSharp.dll": continue
    let cc = imageGetClassCount(gRt, image)
    okLog "keydump: scanning " & $cc & " classes in Assembly-CSharp"
    for k in 0 ..< cc:
      let c = imageGetClass(gRt, image, k)
      if c == nullPtr() or hReadable(c, 8'i32) == 0'i32: continue
      if classNameSafe(gRt, c) == "HTTPTransportManager":
        cls = c
        break
    break
  if cls == nullPtr():
    warn "keydump: HTTPTransportManager not found by enumeration"
    return
  okLog "keydump: found HTTPTransportManager, reading statics"
  let keyPtr = staticFieldPtr(cls, "_key")
  okLog "KEYDUMP _key: " & il2ByteArrayHex(keyPtr)
  let poolPtr = staticFieldPtr(cls, "_ivPool")
  if poolPtr == nullPtr() or hReadable(poolPtr, 0x28'i32) == 0'i32:
    warn "keydump: _ivPool unreadable"
  else:
    let n = int(cast[uint](hReadPtr(poolPtr, 0x18'i32)))
    okLog "KEYDUMP _ivPool outer-len: " & $n
    # As a flat byte[] (in case the pool is one contiguous buffer):
    okLog "KEYDUMP _ivPool flat: " & il2ByteArrayHex(poolPtr)
    # As a jagged byte[][] (elements are byte[] pointers at +0x20 + i*8):
    if n > 0 and n <= 64 and hReadable(poolPtr, int32(0x20 + n * 8)) != 0'i32:
      for i in 0 ..< n:
        let inner = hReadPtr(poolPtr, int32(0x20 + i * 8))
        okLog "KEYDUMP _ivPool[" & $i & "]: " & il2ByteArrayHex(inner)

proc reportRuntime() =
  let gaps = missingEssential(gRt)
  if gaps.len > 0:
    for g in gaps:
      fail "essential IL2CPP entry point missing: " & g
    return
  okLog "IL2CPP runtime bound, all essential entry points present"

  # Neuter the BattlEye anti-cheat validation gate now that GameAssembly.dll is
  # mapped (two static .text byte patches; see aowlspt_beclient.h). Without it
  # the client shows "Anticheat loading failed / Game restart required" when the
  # menu reaches online play and quits. This is separate from the BE service
  # guard armed in the constructor.
  let becLanded = cBecNeuter()
  if cBecBaseFound == 0:
    warn "anti-cheat: GameAssembly.dll not found; BE client gate not patched"
  elif becLanded >= 2:
    okLog "anti-cheat: BE client validation gate neutered (2/2 patches)"
  else:
    warn "anti-cheat: only " & $becLanded & "/2 BE patches landed" &
         " (IsInstanceSuccessfully seen=" & $cBecIsInstSeen &
         ", OnRequestRestart seen=" & $cBecRestartSeen &
         "); offsets may not match this client build"

  var count = 0
  let assemblies = domainGetAssemblies(gRt, gDomain, count)
  if assemblies == nil:
    warn "no assemblies from the domain"
    return
  info $count & " assemblies loaded"

  var total = 0
  for i in 0 ..< count:
    let image = assemblyGetImage(gRt, assemblyAt(assemblies, i))
    if image == nil:
      continue
    total = total + imageGetClassCount(gRt, image)
  info $total & " types visible"

# --------------------------------------------------------------- main

## The last complaint written about the backend's mod set, so a server that is
## answering the wrong thing says so once rather than once every three seconds.
var gSyncError = ""

## The route the mod-sync feed is polling, without the report on the end of it,
## and how often. Empty when this host is not asking the backend anything.
var gSyncBase = ""
var gSyncMs = 0
## The last path actually handed to the feed, so an unchanged report costs
## nothing. `gReportSeq` starts at -1 rather than 0 because 0 is a real sequence
## -- the one a host has before it has decided anything -- and starting equal to
## it would suppress the first report this host ever makes.
var gSyncPath = ""
var gReportSeq = -1
var gReportNextMs = 0'u64

proc hex16(v: uint64): string =
  const digits = "0123456789abcdef"
  result = ""
  var started = false
  var shift = 60
  while shift >= 0:
    let nib = int((v shr uint64(shift)) and 0xF'u64)
    if nib != 0 or started or shift == 0:
      started = true
      result.add digits[nib]
    shift = shift - 4

proc publishReport(now: uint64) =
  ## Put what this host has actually done about the mods onto the end of the
  ## path it is already polling.
  ##
  ## This is the return leg, and it is deliberately not a channel. The client
  ## host has exactly one way to reach the backend -- the overlay's worker
  ## thread, which exists for the panel -- and `aowl_ov_sync_start` can be
  ## called again to change the path it fetches. So the report goes in the query
  ## string of the next poll: no socket, no thread, no request that would not
  ## have been made anyway, and nothing new that can fail. A push would have had
  ## to choose a moment to reach a server that may be down, which is the one
  ## property this side has spent the whole design refusing to depend on.
  ##
  ## Two reasons to rebuild, and only two:
  ##
  ##  * the report changed -- something was loaded, refused, or settled;
  ##  * the last one did not fit, and the rest are waiting their turn.
  ##
  ## Both are rate-limited to the poll interval, because the path is read by the
  ## worker once per poll and rewriting it faster changes nothing that anyone
  ## reads.
  if gSyncBase.len == 0:
    return
  let fresh = modcontrol.reportSeq() != gReportSeq
  let rotate = modcontrol.reportPending() and now >= gReportNextMs
  if not fresh and not rotate:
    return
  gReportSeq = modcontrol.reportSeq()
  gReportNextMs = now + uint64(gSyncMs)
  let path = modcontrol.reportPath(gSyncBase)
  if path == gSyncPath:
    return
  gSyncPath = path
  overlaySyncStart(path, int32(gSyncMs))
  # Only when something actually changed. A stage with more mods than fit in one
  # path rotates through them for the life of the process, and a line per
  # rotation would be a log line every few seconds saying nothing new.
  if fresh:
    info "telling the backend what happened to its mods: " & path

proc takeModSet() =
  ## Read the newest answer the backend gave about which client-side mods
  ## should be running, and queue whatever it takes to match it.
  ##
  ## Called from the host's own loop and nowhere else, immediately before
  ## `modcontrol.drain` performs what it queued. Both halves of that matter:
  ## the answer arrives on the overlay's worker thread and is only *read* here,
  ## and the load or unload itself happens in the drain, on this thread, with
  ## nothing but this host's own frames on the stack.
  ##
  ## Nothing at all happens on a poll that brought no answer, which is most of
  ## them, and nothing at all happens on an answer that does not parse. That is
  ## the whole safety argument: every failure of the far end -- down, starting,
  ## restarting, serving a 404, serving a body too big for the buffer --
  ## converges on "leave the mods alone", because the only thing that can move
  ## a mod is a complete document that says so.
  let doc = overlaySyncTake()
  if doc.len == 0:
    return
  var want: seq[DesiredMod] = @[]
  var err = ""
  if not parseDesired(doc, want, err):
    if err != gSyncError:
      gSyncError = err
      warn "the backend's client mod set was not usable, so nothing was " &
           "changed: " & err
    return
  if gSyncError.len > 0:
    gSyncError = ""
    okLog "the backend's client mod set is readable again"
  applyDesired(want, joinPath(gDir, "mods"))

proc runPending() =
  ## The host thread's half.
  ##
  ## Silent while the drain hook is bound and firing -- those callbacks belong
  ## to the game thread now. It stays as the fallback for two cases, and both
  ## are real: no candidate bound at all, and a hook that bound and then stopped
  ## firing, which is what happens if the method it bound only exists during a
  ## raid. A mod whose callbacks stop arriving because a hook went quiet is a
  ## worse failure than one whose callbacks arrive on the wrong thread, so the
  ## host takes them back and says so.
  if cMqCount() == 0'i32:
    return
  if gDrainSlot >= 0 and not gDrainStalled:
    return
  drainDue()

proc hostMain() {.exportc: "aowlspt_nim_host_main", cdecl.} =
  modhost.startClock()
  gDir = modhost.ownDirectory()
  if gDir.len == 0:
    return

  # A fresh log each launch. The interesting failure is always this run's.
  gHostThreadId = cThreadId()
  modhost.openLog(joinPath(gDir, "aowlspt-host.log"),
    HostName & " " & HostVersion & "\n" &
    "directory " & gDir & "\n" &
    "thread " & $int(gHostThreadId) & "\n\n")

  # The first thing said, because it is the first thing that happened and
  # because a client that does not start says nothing else. The guard ran in
  # the constructor, long before this log existed; these are its counters.
  #
  # Four states, and they are deliberately not collapsed into "on" and "off".
  # No UnityPlayer.dll at all is `hostharness` and the stand-in runtime, where
  # there is correctly nothing to do. The module present with none of the four
  # imports is a client without BSG's guard -- a different client, or a version
  # that dropped it -- and is also nothing to do. The module present with the
  # imports and nothing patched is a *failure*, and it is the one that must not
  # look like the other two, because the symptom is the game refusing to start
  # with no explanation anywhere.
  if cBeModule() == 0:
    info "no UnityPlayer.dll in this process, so BSG's BattlEye service " &
         "guard is not a question here"
  elif cBeArmed() == 0:
    info "UnityPlayer.dll imports none of the service-manager calls BSG's " &
         "BattlEye guard uses; nothing was patched and nothing needed to be"
  elif cBeArmed() < 4:
    warn "BSG's BattlEye service guard: only " & $cBeArmed() & " of 4 " &
         "import slots were patched. The client may still refuse to start, " &
         "and if it does, that is why"
  else:
    okLog "BSG's BattlEye service guard is answered from inside the process " &
          "(4 import slots); BattlEye is not installed, started or loaded"

  # The same constructor, the other patch. Reported separately and before the
  # wait, because if this did not arm the wait cannot succeed and the reason
  # has to be on the line above the symptom rather than 120 seconds below it.
  if cIl2Armed() == 0 and cBeModule() != 0:
    warn "the il2cpp_init lookup could not be armed; the runtime will be " &
         "reported as unavailable however long the game takes to come up"

  # Before a single mod is loaded, because the loader refuses an unload it has
  # no teardown for and the manager is told so in the capabilities reply.
  # `dropModRegistrations` is this host's half: subscriptions, queued
  # main-thread callbacks, and the detours the backend has no equivalent of.
  modhost.setModTeardown(dropModRegistrations)
  # And the half of the host block `aowl_hostapi_new` cannot fill.
  modhost.setHostBlockArm(armLive)

  # Before the first patch of any kind, including the host's own drain hook:
  # once this has run, `gPatches` never moves again, which is what lets the
  # firing path read it on the game's thread without a lock.
  reservePatchRows()

  storeInit(gDir)

  let waitMs = readWaitMs()
  info "waiting for the IL2CPP runtime (up to " & $(waitMs div 1000) & "s)"
  if not waitForIl2Cpp(waitMs):
    warn "the IL2CPP runtime did not come up within " &
         $(waitMs div 1000) & "s"
    warn "mods will load, but resolve and call will report it as unavailable"
  else:
    gReady = true
    # Attaching is not optional and not deferrable: every call this thread
    # makes into the runtime from here on depends on it.
    let t = threadAttach(gRt, gDomain)
    if t == nil:
      fail "il2cpp_thread_attach failed; refusing to call into the runtime"
      gReady = false
    else:
      reportRuntime()
      # Before any mod loads, and for one reason that is not about timing: the
      # detour engine hands out slots in ascending order and the firing path
      # indexes `gPatches` by slot, so the host's own hook has to claim slot 0
      # before a mod can claim it. Failing here is not fatal -- the queue keeps
      # running on this thread, which is what it did before any of this existed.
      if not bindMainDrain(true):
        warn "no per-frame method could be detoured, so invoke_main runs on " &
             "the host's own thread (" & $int(gHostThreadId) & ") and not " &
             "Unity's; a callback that touches a Unity object is unsafe"

  let modsDir = joinPath(gDir, "mods")
  # The runtime may not have come up, and that deliberately does not stop this:
  # a client mod that only logs, schedules and talks to the backend works
  # perfectly well without IL2CPP, and a host injected into a process that has
  # none at all is exactly what `hostharness --inject` is. `resolve` and `call`
  # report it; loading does not gate on it.
  if modhost.loadAll(modsDir, modhost.SideClient, HostName, HostVersion) == 0:
    info "no mods loaded; the host will idle"

  # The overlay, on this thread and not a moment earlier.
  #
  # It creates a window, a D3D11 device and a thread. Every one of those
  # deadlocks under the loader lock, so it cannot go anywhere near `DllMain` --
  # this is the boot thread the constructor started, which is exactly the place
  # for it. A failure is a warning: a host that loses its overlay still runs
  # every mod, and a game that will not start because a panel would not draw is
  # a worse trade than no panel.
  # F12 opens the in-game settings panel (the revamped settings screen), matching
  # the BepInEx/SPT muscle memory where F12 opened the mod-config manager. The
  # panel is the D3D11 Present overlay — the one injection technique proven stable
  # on this client (static byte-patch / hand-drawn overlay), rather than the
  # crash-prone live-managed IL2CPP settings UI. See the F12 spike notes.
  if overlayStart(VkF12, int32(readBackendPort())):
    okLog "overlay ready (F12 opens settings)"
    for i in 0 ..< modhost.modCount():
      if modhost.modIsLive(i):
        overlaySetMod(modhost.modGuidOf(i), modhost.modNameOf(i),
                      modhost.modVersionOf(i), true)
  else:
    warn "the overlay did not start: " & overlayStatus()

  # Full-frame post-process (aowl.graphics). Started AFTER the overlay on
  # purpose: both detour DXGI Present through the same trampoline engine, and
  # installing graphics last makes it the outer hook — it regrades the raw game
  # frame, then the trampoline reaches the overlay, which draws its UI crisp on
  # top of the graded image. A failure here is a missing effect, never fatal:
  # the C side latches broken and the detour becomes a pass-through.
  if graphicsStart():
    okLog "graphics post-process ready — " & graphicsStatus()
  else:
    warn "the graphics post-process did not start: " & graphicsStatus()

  # The mods are up, so the host can start answering the manager. Before this
  # point a control request is ignored rather than queued.
  startModControl()

  # And the other half of it, which is the half that works across a process
  # boundary.
  #
  # `startModControl` wires this host into the manager's *event* protocol, and
  # on the server that is the whole story: the manager and the host share an
  # event channel because they share a process. Here they do not. Nothing in
  # this process ever emits `aowlspt.host.mods.unload`, so until now a player
  # switching off a client-side mod changed a stored selection on the server and
  # nothing at all in the game until it was restarted.
  #
  # So the client asks instead. The overlay's worker thread -- which already
  # exists, already polls, and is already the one HTTP client in this process --
  # fetches the manager's client-side decisions every few seconds, and the tick
  # loop below turns the newest whole answer into loads and unloads. The
  # direction matters: the backend is asked, never listened to, so a backend
  # that is down, starting or answering something else leaves this host running
  # precisely what it is running.
  let syncPort = readBackendPort()
  let syncMs = readSyncMs()
  if syncPort <= 0:
    info "no backendPort in aowlspt-host.json, so this host cannot ask the " &
         "server which mods to run; it loads what is in mods/ and keeps it"
  elif syncMs <= 0:
    info "modSyncMs is 0, so live mod control from the server is off"
  else:
    # The host's own version goes in the path: the manager checks each mod's
    # `pipeline` range against it, and without it the range would be matched
    # against the backend's version instead -- a different program, allowed to
    # be at a different version.
    gSyncBase = "/aowlspt/mods/client/" & HostVersion
    gSyncMs = syncMs
    gSyncPath = gSyncBase
    # Name this process before the first poll goes out. Only a host that asks
    # gets a session, because a session is only ever used to answer -- and the
    # answer exists to stop the manager holding a verdict from a client that has
    # since been restarted, which looks authoritative and is about a process
    # that no longer exists.
    let session = hex16(cNowMs() * 65536'u64 +
                        uint64(gHostThreadId and 0xFFFF'u32))
    modcontrol.reportSession(session)
    overlaySyncStart(gSyncPath, int32(syncMs))
    okLog "asking the backend on port " & $syncPort & " which client mods " &
          "should be running, every " & $syncMs & "ms; this host reports back " &
          "as session " & session

  okLog "host running"

  # Queued from *this* thread, drained by whoever drains. When the two are
  # different threads, the line it writes is the proof -- not the claim -- that
  # `invoke_main` leaves this thread and arrives on Unity's.
  enqueue(cast[Il2CppPtr](0), cast[Il2CppPtr](0), cNowMs(), -1, true)

  var lastTick = cNowMs()
  gLastFireMs = lastTick
  var nextBindTry = lastTick + 5000'u64
  # One-shot backend-key dump, deferred until the client has reached its menu
  # and initialised HTTPTransportManager on its own -- reading (or worse,
  # force-initialising) it right after il2cpp_init faults and kills the game.
  var keyDumpAt = lastTick + 20000'u64
  var keyDumped = false
  # Backend-key runtime dump left in but disabled: reading IL2CPP class metadata
  # from the host's own thread faults too readily on the real client, even behind
  # VEH-guarded name reads. Ground-truth response shapes come from offline
  # analysis of the decrypted metadata + binary disassembly instead.
  discard keyDumpAt
  discard keyDumped
  while true:
    cSleep(16'i32)
    let now = cNowMs()
    let elapsed = int64(now - lastTick)
    lastTick = now

    # Retry while nothing is bound. The first candidate that is worth having is
    # a game type, and the game's own types come up long after the runtime
    # does -- resolving once at boot would report a false negative for the rest
    # of the session. Quiet after the first attempt: the reasons do not change.
    if gDrainSlot < 0 and gReady and now >= nextBindTry:
      nextBindTry = now + 5000'u64
      if bindMainDrain(false):
        okLog "the main-thread drain bound late, on " & gDrainMethod

    let fires = int(cMqFireCount())
    if fires != gLastFire:
      gLastFire = fires
      gLastFireMs = now
      if gDrainStalled:
        gDrainStalled = false
        okLog "the main-thread drain is firing again on " & gDrainMethod
      if not gDrainProven:
        gDrainProven = true
        # Reported from here rather than from the drain: the drain runs inside
        # the game's update path and opening a log file there would cost a file
        # handle on a frame, every frame it first fires.
        let mainTid = int(cMqThread())
        okLog "the drain fires on thread " & $mainTid & "; the host runs on " &
              $int(gHostThreadId)
        if uint32(mainTid) == gHostThreadId:
          # Only possible if the hooked method were somehow called from this
          # very thread, which would mean it is not the player loop's.
          warn "the drain fires on the host's own thread, so it is not " &
               "Unity's; invoke_main is no better placed than it was"
        else:
          okLog "invoke_main now runs on Unity's main thread (" &
                gDrainMethod & ")"
    elif gDrainSlot >= 0 and not gDrainStalled and cMqCount() != 0'i32 and
         now - gLastFireMs > 2000'u64:
      # The hook is installed and the game has stopped calling it -- which is
      # exactly what happens if it bound to something that only exists during a
      # raid. Callbacks that never arrive are a worse failure than callbacks on
      # the wrong thread, so this thread takes the queue back and says so.
      gDrainStalled = true
      if not gStallReported:
        gStallReported = true
        warn "the main-thread drain has not fired for 2s with work queued; " &
             "running it on the host thread until it comes back"

    if not gAlienReported and cMqAlienFires() > 0'i32:
      gAlienReported = true
      # The hooked method turned out to be called from more than one thread.
      # Only the first thread to reach it ever drains, so this is a note about
      # the candidate rather than a fault -- but it means the choice was not as
      # main-thread-only as it looked.
      warn gDrainMethod & " also runs on other threads; only thread " &
           $int(cMqThread()) & " drains the queue"

    runPending()
    takeModSet()
    # Live mod control, off the emitting stack -- the only place in this host a
    # mod is loaded or unloaded while the game is running.
    modcontrol.drain()
    # And the answer, on the way back out. It rides the next poll of the same
    # route the desired set came in on -- see `publishReport`.
    publishReport(now)
    modhost.tickMods(elapsed)
