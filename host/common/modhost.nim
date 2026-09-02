## Loading and running aowlspt mods -- the loader **both** hosts use.
##
## The client host (inside the game) and the backend server have almost nothing
## in common: one drives IL2CPP, the other serves HTTP. But a *mod* must load
## and behave identically on both, and that is the part this module owns --
## discovery, the ABI version probe, `describe`/`init`/`on_load`, ticking, and
## unloading.
##
## `backend/aowlbackend.nim` and `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` both
## import it. The client host used to carry a near-verbatim copy of the same
## logic inline -- its own `LoadedMod`, `loadMod`, `discoverMods`, `unloadMods`,
## `unloadOne` -- and that copy is gone. It was debt rather than a design: the
## two drifted, and the last three fixes here had to be made twice.
##
## What the client host holds *per mod* that the backend does not -- detour
## slots, IL2CPP GC handles, a main-thread queue -- is deliberately still not in
## `LoadedMod`. It lives in that host, keyed by the same index, and comes out
## through `setModTeardown`. Widening this object with fields one side cannot
## fill is how the copy started.
##
## Two seams exist for the client host and are nil on the server:
##
##  * `setModTeardown` -- drop everything a mod registered, before its library
##    is freed. The backend installs one too.
##  * `setHostBlockArm` -- a chance to fill in host-block entries only one host
##    can implement. The client host arms the revision-3 live-object pointers
##    there; `aowl_hostapi_new` cannot, because it builds every host's block.
##
## What stays with each host is the `aowlspt_nim_*` surface: the functions
## `aowlspt_shim.h` calls back into to implement `AowlHostApi`. Those genuinely
## differ per side, and each binary must define its own set because the shim's
## vtable is built from them.

import std/[strutils, syncio]
import aowlsptinstall/winfs
import jsonpath

{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_profile.h" """.}

# ---------------------------------------------------------------------------
# THE PER-MOD PROFILER's one hook into the loader (abi/aowlspt_profile.h).
#
# `tickMods` below is the ONE place in the whole project where every mod's
# per-frame work is dispatched, on every host -- the client host, the backend
# and the simulator all call it. That makes it the only honest place to answer
# "which mod is costing frame time", and it is why the profiler is here rather
# than in a mod: a mod cannot time its siblings.
#
# It is OFF by default and it is off in the shipped build. With `enabled` clear,
# `aowl_prof_begin` is one volatile load and a return, so the cost of carrying
# this is a load and a predicted branch per mod per tick. Nothing here allocates:
# the slot index is registered ONCE per mod (idempotent, by guid) and lives in
# the LoadedMod record; the accumulators are int64s in a shared page.
proc cProfSlot*(name: cstring; kind: int32): int32 {.
  importc: "aowl_prof_slot", nodecl.}
proc cProfBegin*(slot: int32) {.importc: "aowl_prof_begin", nodecl.}
proc cProfEnd*(slot: int32) {.importc: "aowl_prof_end", nodecl.}
proc cProfEnabled*(): int32 {.importc: "aowl_prof_is_enabled", nodecl.}
proc cProfFrame*() {.importc: "aowl_prof_frame", nodecl.}
proc cProfTickBoundary*() {.importc: "aowl_prof_tick_boundary", nodecl.}
proc cProfCalibrate*() {.importc: "aowl_prof_calibrate", nodecl.}

const ProfKindMod* = 1'i32

## ---------------------------------------------------------------------------
## Giving a mod's allocator back when the mod goes
## ---------------------------------------------------------------------------
##
## Every nimony binary statically links its own mimalloc, and mimalloc reserves
## and commits a 32 MiB arena the first time that binary allocates anything. A
## mod DLL is a nimony binary, so each *load* commits one -- and `FreeLibrary`
## unmaps the image without touching it, because the arena is process memory
## the image no longer has any code to release.
##
## Measured, not guessed: `hostharness --churn` cycles a mod through load and
## unload and reads the process's committed private space. Two hundred cycles
## committed 6.4 GB in two hundred and three regions of exactly 32768 KB, with
## every host table flat and the host's own live heap moving by well under a
## kilobyte a cycle. That is 32 MB per toggle of a switch in the mod manager.
##
## mimalloc names this case itself -- "should be done if mimalloc is statically
## linked into another shared library which is repeatedly loaded/unloaded" --
## and answers it with `mi_process_done`, which every mod exports because the
## static link does. On its own it collects the heap and keeps the arenas; it
## releases them when `destroy_on_exit` is set, which is asked for through the
## environment rather than through `mi_option_set` so that nothing here depends
## on the ordinal of an enum in a vendored header this repo does not include.
##
## The danger mimalloc warns about -- a dangling pointer into memory that has
## just been unmapped -- is the reason this is called at exactly one point and
## not one instruction earlier. By the time `unloadOne` reaches `cFreeLibrary`
## the mod's `on_unload` has run, the host's teardown has dropped every
## registration, and the three host-owned structures are freed. Nothing the
## host still holds came out of the mod's allocator: `AowlModInfo`'s slices are
## copied into host strings at load, and every `AowlBuffer` a mod returns is
## consumed and released inside the call that asked for it. That is the ABI's
## "borrowed in, owned out" rule, and this depends on it.
{.emit: """
static void aowl_mod_alloc_prepare(void) {
    /* Read by each mod's own mimalloc when it initialises, which happens after
     * `LoadLibrary` -- so setting it once, before any mod is loaded, reaches
     * every one of them. */
    SetEnvironmentVariableA("MIMALLOC_DESTROY_ON_EXIT", "1");
}
static int32_t aowl_mod_alloc_teardown(void* module) {
    if (!module) return 0;
    void* f = (void*)GetProcAddress((HMODULE)module, "mi_process_done");
    if (!f) return 0;
    ((void(*)(void))f)();
    return 1;
}

/* THE TWO MEASUREMENTS BEHIND "did the unload actually release the file".
 *
 * A logical unload and a file release are different events, and until these
 * existed the host reported the first and the user wanted the second. Measured
 * live: an unload that logged `completed=1`, `epoch=1` and `unloaded Bot AI`
 * left the DLL locked, so a rebuild could not be copied over it. Every counter
 * said success and the feature was impossible.
 *
 * Neither of these mutates anything. They are the instrument, not the fix. */

/* Is this path still a loaded module? UNCHANGED_REFCOUNT is the whole point:
 * asking must not itself take a reference, which is the bug this is hunting. */
static int32_t aowl_sys_module_loaded(const char* path) {
    HMODULE h = NULL;
    if (!path) return 0;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           path, &h)) return 1;
    return 0;
}

/* Can this path be opened for writing with no sharing -- i.e. could a rebuild
 * be copied over it? Returns 0 for yes, otherwise the Win32 error, of which
 * ERROR_SHARING_VIOLATION (32) is the one that means "still mapped".
 *
 * OPEN_EXISTING and an immediate CloseHandle: this opens for write and writes
 * nothing, so a probe that runs on a file we then decide to keep has not
 * touched it. */
static int32_t aowl_sys_path_writable(const char* path) {
    HANDLE f;
    if (!path) return -1;
    f = CreateFileA(path, GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return (int32_t)GetLastError();
    CloseHandle(f);
    return 0;
}
""".}


type HostPtr* = nil pointer

proc cModAllocPrepare*() {.importc: "aowl_mod_alloc_prepare", nodecl.}
proc cModAllocTeardown*(module: HostPtr): int32 {.
  importc: "aowl_mod_alloc_teardown", nodecl.}

proc cSysNowMs*(): uint64 {.importc: "aowl_sys_now_ms", nodecl.}
proc cSysSleep*(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}
proc cSysThreadId*(): uint32 {.importc: "aowl_sys_thread_id", nodecl.}
proc cSysModulePath*(buf: HostPtr; cap: int32): int32 {.
  importc: "aowl_sys_module_path", nodecl.}
proc cLoadLibrary*(path: cstring): HostPtr {.
  importc: "aowl_sys_load_library", nodecl.}
proc cFreeLibrary*(h: HostPtr) {.importc: "aowl_sys_free_library", nodecl.}
proc cModuleLoaded*(path: cstring): int32 {.
  importc: "aowl_sys_module_loaded", nodecl.}
proc cPathWritable*(path: cstring): int32 {.
  importc: "aowl_sys_path_writable", nodecl.}
proc cGetProc*(h: HostPtr; name: cstring): HostPtr {.
  importc: "aowl_sys_get_proc", nodecl.}
proc cSysLastError*(): uint32 {.importc: "aowl_sys_last_error", nodecl.}

proc cModInfoNew*(): HostPtr {.importc: "aowl_modinfo_new", nodecl.}
proc cModInfoFree*(p: HostPtr) {.importc: "aowl_modinfo_free", nodecl.}
proc cModInfoSides*(p: HostPtr): uint32 {.importc: "aowl_modinfo_sides", nodecl.}
proc cModInfoFlags*(p: HostPtr): uint32 {.importc: "aowl_modinfo_flags", nodecl.}
proc cModInfoGuidPtr*(p: HostPtr): HostPtr {.importc: "aowl_modinfo_guid_ptr", nodecl.}
proc cModInfoGuidLen*(p: HostPtr): int32 {.importc: "aowl_modinfo_guid_len", nodecl.}
proc cModInfoNamePtr*(p: HostPtr): HostPtr {.importc: "aowl_modinfo_name_ptr", nodecl.}
proc cModInfoNameLen*(p: HostPtr): int32 {.importc: "aowl_modinfo_name_len", nodecl.}
proc cModInfoAuthorPtr*(p: HostPtr): HostPtr {.importc: "aowl_modinfo_author_ptr", nodecl.}
proc cModInfoAuthorLen*(p: HostPtr): int32 {.importc: "aowl_modinfo_author_len", nodecl.}
proc cModInfoVersionPtr*(p: HostPtr): HostPtr {.importc: "aowl_modinfo_version_ptr", nodecl.}
proc cModInfoVersionLen*(p: HostPtr): int32 {.importc: "aowl_modinfo_version_len", nodecl.}

proc cModAbiVersion*(fn: HostPtr): uint32 {.importc: "aowl_mod_abi_version", nodecl.}
proc cModDescribe*(fn, info: HostPtr): int32 {.importc: "aowl_mod_describe", nodecl.}
proc cModInit*(fn, host, outApi: HostPtr): int32 {.importc: "aowl_mod_init", nodecl.}

proc cModApiNew*(): HostPtr {.importc: "aowl_modapi_new", nodecl.}
proc cModApiFree*(p: HostPtr) {.importc: "aowl_modapi_free", nodecl.}
proc cModApiHasUpdate*(p: HostPtr): int32 {.importc: "aowl_modapi_has_update", nodecl.}
proc cModApiOnLoad*(p: HostPtr): int32 {.importc: "aowl_modapi_on_load", nodecl.}
proc cModApiOnUpdate*(p: HostPtr; elapsed: int64): int32 {.
  importc: "aowl_modapi_on_update", nodecl.}
proc cModApiOnUnload*(p: HostPtr): int32 {.importc: "aowl_modapi_on_unload", nodecl.}

proc cHostApiNew*(ctx: HostPtr; side: int32;
                  hostName, hostVersion, sptVersion, gameVersion,
                  modDir, dataDir: cstring): HostPtr {.
  importc: "aowl_hostapi_new", nodecl.}
proc cHostApiFree*(p: HostPtr) {.importc: "aowl_hostapi_free", nodecl.}
proc cHostApiPtr*(p: HostPtr): HostPtr {.importc: "aowl_hostapi_ptr", nodecl.}
proc cAbiVersionExpected*(): uint32 {.importc: "aowl_abi_version_expected", nodecl.}
proc cOutCopy*(outPtr, outLen, src: HostPtr; len: int32): int32 {.
  importc: "aowl_out_copy", nodecl.}
proc cInvokeCallback*(cb, user, payload: HostPtr; len: int32): int32 {.
  importc: "aowl_invoke_callback", nodecl.}
proc cInvokePatch*(cb, user, target: HostPtr; tlen: int32): int32 {.
  importc: "aowl_invoke_patch", nodecl.}
proc cByteAt*(p: HostPtr; i: uint64): uint8 {.importc: "aowl_byte_at", nodecl.}

## ---------------------------------------------------------------------------
## Keeping a mod's library mapped while a thread is inside it
## ---------------------------------------------------------------------------
##
## The teardown drops every registration the host can see -- routes, event
## subscriptions, timers, detours -- before `cFreeLibrary`. What it cannot drop
## is a pointer a *thread is already carrying*: the backend's `matchRoute`
## copies a route out under the registration lock and `runRoute` invokes it with
## no lock held (deliberately: a handler may register a route, and a walk
## holding the lock across the call would wait on itself). So a worker can be
## between the copy and the call, or inside the call, at the moment the control
## thread reaches `FreeLibrary`, and the answer to that is a reference held
## across the dispatch.
##
## **The cost argument that rules a refcount out for a patch firing does not
## apply here.** An uncontended `InterlockedIncrement`/`InterlockedDecrement`
## pair measures 7.3 ns on this machine; a route handler costs about 423 us, so
## the pair is two thousandths of one percent of it. A detour firing costs
## 2.9 ns and could not pay it, which is why trampolines are retired instead.
##
## **The ordering is the whole of the difficulty**, and it is written down here
## because getting it backwards does not remove the window, it moves it:
##
##  * `modEnter` **increments first and then tests** the draining flag, and
##    gives the reference back if it is set. Testing first loses to a drain
##    that begins between the test and the increment: the drain reads a count
##    of zero, frees the library, and the caller then enters it.
##  * `unloadOne` **sets draining first and then reads the count**. Reading
##    first loses to an enter that begins between the read and the store.
##
## Both sides are a store followed by a load of the *other* location, and both
## are interlocked, so on x86-64 each is a full barrier and neither pair can be
## reordered. That is what makes the two-line argument sound: suppose an enter
## succeeded -- it read `draining == 0` after its own increment -- and suppose
## the drain's read of the count nevertheless missed that increment. Then the
## count read precedes the increment, the draining store precedes the count
## read, and so the draining store precedes the increment, which precedes the
## enter's read of draining. The enter would have seen `1` and refused.
## Contradiction: no enter can succeed unnoticed, so a drain that reaches zero
## has nobody inside.
##
## **Neither the flag nor the counter may live in a `seq`.** `gMods` grows from
## the control thread while workers read it, and a growing `seq` reallocates --
## which is the same use-after-free one table over, found twice already in this
## codebase (`gRoutes` in the backend, `gMadeDirs` in the mod store). They live
## in fixed C storage indexed by the mod's index, which is the number every
## host already keys everything else on.
##
## The table is fixed and finite, and a slot is consumed per *load* rather than
## per mod, because `unloadOne` keeps a dead mod's slot rather than compacting
## `gMods` (every context pointer handed to a mod is its index). `loadMod`
## refuses past the end rather than loading a mod whose routes could never be
## entered -- 16384 loads is far beyond a session that toggles mods from a
## panel, and `gMods` itself would be tens of megabytes by then.
{.emit: """
#define AOWL_MOD_SLOTS 16384

/* Separate arrays rather than one struct: the flag is read on the way into
 * every route handler and the counter is written there, and a mod's two
 * fields sharing a cache line with its neighbour's costs nothing worth the
 * padding to avoid. */
static LONG64 aowl_mod_inflight[AOWL_MOD_SLOTS];
static LONG   aowl_mod_draining[AOWL_MOD_SLOTS];

static int32_t aowl_mod_slots(void) { return (int32_t)AOWL_MOD_SLOTS; }

static int32_t aowl_mod_enter(int64_t index) {
    if (index < 0 || index >= AOWL_MOD_SLOTS) return 0;
    /* Increment, *then* test. See the note above: the other order reopens the
     * window rather than closing it. */
    InterlockedIncrement64(&aowl_mod_inflight[index]);
    if (InterlockedCompareExchange(&aowl_mod_draining[index], 0, 0) != 0) {
        InterlockedDecrement64(&aowl_mod_inflight[index]);
        return 0;
    }
    return 1;
}

static void aowl_mod_leave(int64_t index) {
    if (index < 0 || index >= AOWL_MOD_SLOTS) return;
    InterlockedDecrement64(&aowl_mod_inflight[index]);
}

static void aowl_mod_drain_begin(int64_t index) {
    if (index < 0 || index >= AOWL_MOD_SLOTS) return;
    InterlockedExchange(&aowl_mod_draining[index], 1);
}

/* Only ever called when a drain gave up: the mod stays loaded, so it must
 * start answering again. A worker refused while this was set got a clean
 * refusal, which is the correct answer to "this mod is going away" even when
 * it then does not. */
static void aowl_mod_drain_cancel(int64_t index) {
    if (index < 0 || index >= AOWL_MOD_SLOTS) return;
    InterlockedExchange(&aowl_mod_draining[index], 0);
}

static int64_t aowl_mod_inflight_of(int64_t index) {
    if (index < 0 || index >= AOWL_MOD_SLOTS) return 0;
    return (int64_t)InterlockedCompareExchange64(&aowl_mod_inflight[index], 0, 0);
}
""".}

proc cModSlots(): int32 {.importc: "aowl_mod_slots", nodecl.}
proc cModEnter(index: int64): int32 {.importc: "aowl_mod_enter", nodecl.}
proc cModLeave(index: int64) {.importc: "aowl_mod_leave", nodecl.}
proc cModDrainBegin(index: int64) {.importc: "aowl_mod_drain_begin", nodecl.}
proc cModDrainCancel(index: int64) {.importc: "aowl_mod_drain_cancel", nodecl.}
proc cModInflight(index: int64): int64 {.importc: "aowl_mod_inflight_of", nodecl.}

const
  ModSlotLimit* = 16384
    ## Must match `AOWL_MOD_SLOTS` above. One per *load*, not per mod.

  DrainDeadlineMs* = 5000
    ## How long `unloadOne` waits for the threads inside a mod to come out
    ## before it gives up and leaves the mod loaded.
    ##
    ## The unload runs on the host's own loop -- the backend's serve thread,
    ## the client host's tick thread -- so waiting here stops ticks and timers,
    ## and an unbounded wait would hand one wedged handler the whole host. Five
    ## seconds is far above the ~423 us a handler costs and below the ten the
    ## session lock already allows itself, so a drain that expires means a
    ## handler that is not coming back rather than one that is merely slow.

proc modEnter*(index: int): bool =
  ## Take a reference to the mod at `index` for the duration of a call into it.
  ## `false` means the mod is being unloaded and the call must not be made --
  ## the caller owes the requester a clean refusal, not a call.
  ##
  ## Paired with `modLeave` on **every** path out, including the failing ones.
  ## A reference leaked here is an unload that times out and a mod that can
  ## never be taken off, which is a far quieter bug than the one this closes.
  result = cModEnter(int64(index)) != 0'i32

proc modGuardable*(index: int): bool =
  ## Whether `index` names a slot the guard covers at all.
  ##
  ## This exists because `modEnter` folds two different answers into one
  ## `false`: **"out of range"** and **"being unloaded"**. A caller that reads
  ## the second meaning into the first silently drops work that was never a
  ## mod's to begin with -- and that is not hypothetical. `tools/hostharness`
  ## subscribes to events under context `0x7FFF` on purpose, a number no mod
  ## table reaches, so its own registrations survive the churn it measures.
  ## Guarding that subscriber turned "there is no library here to protect" into
  ## "skip this subscriber", and the reply to `aowlspt.host.mods.list`
  ## disappeared.
  ##
  ## So: ask this first, and only take the guard for an index it answers true
  ## for. Every host does it the same way, from here, rather than each carrying
  ## a copy of the bound.
  ##
  ## The bound is the fixed slot count and **not** `modCount()`, deliberately.
  ## A count that moved between the enter and the leave would drop a
  ## `modLeave`, and a reference leaked here is an unload that times out and a
  ## mod that can never be taken off -- a far quieter bug than the one the
  ## guard closes.
  result = index >= 0 and index < int(cModSlots())

proc modLeave*(index: int) =
  ## Give back what `modEnter` took. Only ever call this after a `modEnter`
  ## that answered `true`.
  cModLeave(int64(index))

proc modInflight*(index: int): int64 =
  ## How many threads are inside this mod right now. For diagnostics and for
  ## the tests; the unload path uses it through `drainMod`.
  result = cModInflight(int64(index))

proc drainMod(index: int; deadlineMs: int): bool =
  ## Close the mod to new entries and wait for the ones inside to leave.
  ##
  ## The store comes first and the read second -- that order is the fix, and
  ## the argument for it is at the head of this section. On expiry the caller
  ## must `cModDrainCancel`, because a mod that stays loaded must stay
  ## answerable.
  cModDrainBegin(int64(index))
  let started = cSysNowMs()
  var spins = 0
  while cModInflight(int64(index)) > 0'i64:
    if int64(cSysNowMs() - started) > int64(deadlineMs):
      return false
    # A handler is microseconds long, so the first few passes give the thread
    # its quantum back rather than parking for a scheduler tick.
    if spins < 64:
      cSysSleep(0'i32)
      inc spins
    else:
      cSysSleep(1'i32)
  result = true

const
  SideServer* = 1'i32
  SideClient* = 2'i32
  SideSim* = 3'i32

  StatusOk* = 0'i32
  ErrGeneric* = -1'i32
  ErrNotFound* = -3'i32
  ErrBadArg* = -4'i32
  ErrDecode* = -5'i32
  ErrUnsupported* = -6'i32
  ErrConfigParse* = -10'i32
    ## `config.json` exists and is not readable JSON. Here, beside the other
    ## shared statuses, because the whole point of it is that the three hosts
    ## answer it identically -- the backend and the client host used to answer
    ## `ErrNotFound` for an unparseable config and the simulator answered
    ## `ErrGeneric`, so a mod could not tell "no such setting" from "none of
    ## your settings are real" on any host, and could not even tell the same
    ## story twice across two of them.

proc statusName*(st: int32): string =
  ## The ABI's name for a status code, for a log line a person reads.
  ##
  ## `-9` in a log is a number somebody has to go and look up in
  ## `abi/aowlspt_abi.h`; `AOWLSPT_ERR_MOD_FAULT` is the answer they were going
  ## to find there. The spelling is the header's, not a paraphrase, so that
  ## searching the log line in the tree lands on the definition.
  case st
  of 0'i32: "AOWLSPT_OK"
  of -1'i32: "AOWLSPT_ERR_GENERIC"
  of -2'i32: "AOWLSPT_ERR_ABI"
  of -3'i32: "AOWLSPT_ERR_NOT_FOUND"
  of -4'i32: "AOWLSPT_ERR_BAD_ARG"
  of -5'i32: "AOWLSPT_ERR_DECODE"
  of -6'i32: "AOWLSPT_ERR_UNSUPPORTED"
  of -7'i32: "AOWLSPT_ERR_WRONG_THREAD"
  of -8'i32: "AOWLSPT_ERR_DISPOSED"
  of -9'i32: "AOWLSPT_ERR_MOD_FAULT"
  of -10'i32: "AOWLSPT_ERR_CONFIG_PARSE"
  else: "an unnamed status"

type
  LoadedMod* = object
    path*: string
    dir*: string
    module*: HostPtr
    info*: HostPtr
    api*: HostPtr
    hostBlock*: HostPtr
    guid*: string
    name*: string
    author*: string
    version*: string
    hasUpdate*: bool
    live*: bool
    loadedAt*: int64
      ## `elapsedMs()` at the moment this mod's `init` was accepted, i.e.
      ## when it became live. Read only by the once-per-session refusal in
      ## `loadMod`, which names it so the log says WHEN the first
      ## initialisation happened rather than merely that one did:
      ## "already initialised" and "already initialised at 4.5s, by the
      ## backend's mod-set poll" are different amounts of evidence.
    tickFails*: int
      ## How many times in a row `on_update` has answered non-OK. Reset by the
      ## first tick that answers OK, so this counts a *run* of failures rather
      ## than a total: a mod that fails one tick in a thousand never
      ## accumulates. See `TickFaultLimit` and `tickMods`.
      ##
      ## Touched only by `tickMods`, which every host calls from the one thread
      ## that also loads and unloads mods -- so unlike the in-flight counter
      ## and the draining flag it may live here, in the `seq`. The argument is
      ## written out at `TickFaultLimit`.
    tickWarned*: bool
      ## Whether this mod's first failed tick has been reported. Never cleared,
      ## and that is the point: `tickFails` resets on every success, so a mod
      ## that fails one tick in four starts a fresh *run* 150 times in a
      ## session, and a line per run-start is the per-frame log flood this was
      ## supposed to avoid wearing a disguise. `tests/tickfault`'s flaky
      ## fixture is what found it.
    tickFaulted*: bool
    initTid*: uint32
      ## The OS thread id that ran this mod's `init` and `on_load`, recorded
      ## in `loadMod` at the moment the mod went live. Zero only for a row
      ## that never went through `loadMod`.
      ##
      ## MEASURED 2026-09-02 13:18 (WER dump, 0xc0000409
      ## FAST_FAIL_FATAL_APP_EXIT from `ucrtbase!abort` under
      ## `admin!mi_assert_fail`): a mod initialised on one thread and ticked
      ## on another aborts the whole PROCESS inside mimalloc, on the assertion
      ## `heap->thread_id == 0 || heap->thread_id == tid` in
      ## `mi_heap_malloc_small_zero` (vendor/mimalloc/src/alloc.c:135). Each
      ## mod DLL carries its own mimalloc whose default heap lives in that
      ## DLL's emulated TLS (`_emutls_v._mi_heap_default`), and a foreign
      ## thread allocating on it is a FAIL-FAST: it bypasses Unity's handler,
      ## so there is not even a Crash_* report to read afterwards.
      ##
      ## INFERRED, not measured: that the binding is established by the init
      ## thread specifically, rather than by emutls slot reuse after the
      ## unload/reload the same boot performed. Either way the invariant that
      ## holds is the one `tickMods` enforces: A MOD IS TICKED ONLY ON THE
      ## THREAD THAT INITIALISED IT.
    tickWrongThread*: bool
      ## `tickMods` reached this mod on a thread that is not `initTid` and
      ## REFUSED to tick it. A third state, distinct from `tickFaulted`: the
      ## mod never ran and never failed, so reporting it as faulted would
      ## report a fault that did not happen. Said once per mod.
    profSlot*: int32
      ## This mod's slot in the profiler's shared region, or -1 for "not
      ## registered yet". Registered lazily on the first tick AFTER the
      ## profiler is switched on, so a run that never enables the profiler
      ## never touches the region at all. -1 is a legal argument to
      ## `cProfBegin`/`cProfEnd`, which ignore it, so a refused registration
      ## degrades to "this mod is not profiled" and never to a fault.
      ## Set once the run above reaches `TickFaultLimit`. The mod stays
      ## **loaded** -- its routes, events, timers and detours all keep working;
      ## it simply stops being handed the tick it cannot survive.
    flags*: uint32
      ## `AowlModFlags` as the mod declared them. Kept because the mod's
      ## `AowlModInfo` is freed on unload and the answer is still wanted after
      ## that -- the mod manager asks what a *stopped* mod claims about itself
      ## in order to draw its row.

var gLogPath = ""
var gStartMs = 0'u64
var gMods*: seq[LoadedMod] = @[]

proc startClock*() =
  gStartMs = cSysNowMs()

proc elapsedMs*(): int64 =
  result = int64(cSysNowMs() - gStartMs)

const NL = "\n"

var gLogFile: File = default(File)
var gLogFileOpen = false
var gLogDropped = 0
  ## Lines the sink could not write because it could not open the file. Counted
  ## rather than discarded: a sink that loses a line and says nothing is the
  ## instrument this module exists to stop being.

proc closeLog*() =
  ## Flush and release the log handle. Idempotent; safe if none was opened.
  if gLogFileOpen:
    gLogFileOpen = false
    close(gLogFile)

proc openLog*(path, banner: string) =
  ## A fresh log each run: the interesting failure is always this one.
  closeLog()
  gLogPath = path
  gLogDropped = 0
  discard writeTextFile(gLogPath, banner)

proc fmtElapsed*(ms: int): string =
  ## Milliseconds since start as `h:mm:ss.mmm`, so a log a person reads shows a
  ## clock rather than a raw millisecond count. `aowlterm` already splits the
  ## stamp on `"] "`, so it displays this verbatim with no change.
  let h = ms div 3600000
  let m = (ms div 60000) mod 60
  let s = (ms div 1000) mod 60
  let mm = ms mod 1000
  func p2(n: int): string = (if n < 10: "0" else: "") & $n
  func p3(n: int): string =
    (if n < 100: (if n < 10: "00" else: "0") else: "") & $n
  result = $h & ":" & p2(m) & ":" & p2(s) & "." & p3(mm)

# ------------------------------------------------------------- breadcrumbs
#
# A crash-proof second witness for the log, and a first-class one, because a
# mod has already had to hand-roll this and got the path wrong -- it wrote one
# directory above where it said it did, and the run was briefly read as "no
# crumbs were written" when the crumbs were fine.
#
# What makes it a witness rather than a duplicate: it is a DIFFERENT handle,
# opened at a different moment, truncated once, capped, and written with its
# own sequence number. If the log's tail and the crumb file's tail disagree,
# the number of the last crumb says how far execution actually got -- which is
# exactly the question "it dies at X" has been answered with, using the log
# alone, for the whole life of this project.
#
# OFF by default. Armed by the host from a flag, and the host logs the value it
# actually read, because a default is not a value.

var gCrumbPath = ""
var gCrumbCap = 0
var gCrumbSeq = 0
var gCrumbFile: File = default(File)
var gCrumbOpen = false
var gCrumbDead = false

proc crumbsArmed*(): bool = gCrumbPath.len > 0 and not gCrumbDead

proc crumbArm*(path: string; cap: int): string =
  ## Arm the breadcrumb file. Returns "" on success, or the reason it refused.
  ##
  ## The path must be ABSOLUTE. That is the whole reason this returns a string
  ## instead of nothing: the hand-rolled version took a relative path, resolved
  ## it against a working directory nobody had established, and wrote a real
  ## file somewhere nobody looked. A relative path here is refused loudly, not
  ## resolved helpfully.
  gCrumbPath = ""
  gCrumbDead = false
  gCrumbSeq = 0
  if path.len < 3:
    return "the breadcrumb path is too short to be absolute: '" & path & "'"
  let absDrive = path[1] == ':' and (path[2] == '\\' or path[2] == '/')
  let absUnc = path[0] == '\\' and path[1] == '\\'
  let absRoot = path[0] == '/'
  if not (absDrive or absUnc or absRoot):
    return "the breadcrumb path must be absolute, and '" & path & "' is not"
  if cap <= 0:
    return "the breadcrumb cap must be positive, not " & $cap
  gCrumbPath = path
  gCrumbCap = cap
  result = ""

proc crumb*(tag: string) =
  ## One numbered record, on disk before this returns.
  ##
  ## Costs one bool test when disarmed, which is why `logLine` may call it
  ## unconditionally. When armed it costs a `flushFile` -- 2.4 us/record
  ## measured by `tests/logtail.c`, the same price the log sink pays.
  ##
  ## Capped: at the cap it writes one last line saying so and disarms itself,
  ## so a per-frame crumb cannot fill a disk overnight. Truncate-on-first-write
  ## rather than at arm time, so arming costs nothing and a run that never
  ## crumbs leaves the previous run's file alone to be read.
  if gCrumbPath.len == 0 or gCrumbDead:
    return
  if not gCrumbOpen:
    if not open(gCrumbFile, gCrumbPath, fmWrite):
      # Nowhere to complain to that is more reliable than this file was.
      gCrumbDead = true
      return
    gCrumbOpen = true
  inc gCrumbSeq
  if gCrumbSeq > gCrumbCap:
    write(gCrumbFile, "crumbs capped at " & $gCrumbCap & "; no more" & NL)
    flushFile(gCrumbFile)
    gCrumbDead = true
    return
  write(gCrumbFile, $gCrumbSeq & " [" & fmtElapsed(int(elapsedMs())) & "] " &
        tag & NL)
  flushFile(gCrumbFile)

proc crumbCount*(): int = gCrumbSeq

type
  LogSinkFn* = nil proc (level, msg: string)
    ## A second destination for every line this module logs. `nil proc` for the
    ## reason `TeardownFn` is one: nimony's proc types are non-nil by default.

var gLogSink: LogSinkFn = nil

proc setLogSink*(fn: LogSinkFn) =
  ## Installed by a host whose log is somewhere other than a file.
  ##
  ## The two long-lived hosts write a log beside themselves and nothing else --
  ## a server and an injected DLL have no console worth printing to. The
  ## simulator is the opposite: it is run from a terminal by a person watching
  ## the output, and the lines that matter most to them are the loader's own
  ## ("this mod does not support that side", "it was built against ABI version
  ## 2"). Those are produced in here, so without a seam they can only reach a
  ## file the person is not reading.
  ##
  ## Additive on purpose: a host that installs nothing behaves exactly as
  ## before, and a host that installs one still gets the file if it opened one.
  gLogSink = fn

proc sinkWrite(text: string) =
  ## One line to the log file, left OUTSIDE this process before returning.
  ##
  ## The handle is opened once and held. It used to be opened, written and
  ## closed per line, on the reasoning that a host which takes the process down
  ## with it needs a log that survives that -- which is true, and which
  ## close-per-line does achieve. It is not the cheapest way to achieve it.
  ##
  ## MEASURED, `tests/logtail.c` on this machine, 2000 records each:
  ##   open/write/close per line        113.8 us/record  survives a hard death
  ##   held handle + flush                2.4 us/record  survives a hard death
  ##   held handle, no flush              0.3 us/record  LOSES EVERYTHING
  ##   held handle + FlushFileBuffers  4985.4 us/record  survives a hard death
  ##
  ## So: hold the handle and `flushFile` every line. `flushFile` is one
  ## `WriteFile` of the pending bytes on nimony's native IO, or `fflush` on the
  ## libc path; either way the bytes are out of this process and in the OS file
  ## cache, which outlives it. Only losing the machine loses them -- which is
  ## what the 5 ms `FlushFileBuffers` column buys, at a price nothing on the
  ## Unity main thread may pay.
  ##
  ## The 47x is not cosmetic: this sink runs on the Unity thread, and a boot
  ## that logs 800 lines spent 91 ms of frame time inside `CreateFileW` alone.
  ##
  ## One behaviour change that is not a bug and will look like one: the handle
  ## is held for the life of the process, opened `FILE_SHARE_READ` and
  ## `FILE_SHARE_WRITE` but NOT `FILE_SHARE_DELETE`. Reading the log while the
  ## client runs is unaffected -- `tools/hostlog.py` opens read-only. DELETING
  ## it mid-run now fails, where before there was a window between two lines in
  ## which it succeeded and the host silently began a second file. Losing half
  ## a run into an unlinked inode was never the better answer.
  if not gLogFileOpen:
    if open(gLogFile, gLogPath, fmAppend):
      gLogFileOpen = true
    else:
      # Nothing to write with, and nowhere to say so. Count it; the next line
      # that does get through reports the run.
      inc gLogDropped
      return
  if gLogDropped > 0:
    let missed = gLogDropped
    gLogDropped = 0
    write(gLogFile, "[" & fmtElapsed(int(elapsedMs())) &
          "] warn   the log sink could not open " & gLogPath & " for " &
          $missed & " line(s); those lines are MISSING from this file" & NL)
  write(gLogFile, text)
  flushFile(gLogFile)

proc logLine*(level, msg: string) =
  ## Never buffered across a return: by the time this returns, the line has
  ## left the process. See `sinkWrite`, and `crumb` for the second witness.
  if gLogSink != nil:
    gLogSink(level, msg)
  crumb(level & " " & msg)
  if gLogPath.len == 0:
    return
  let text = "[" & fmtElapsed(int(elapsedMs())) & "] " & level & "  " & msg & NL
  sinkWrite(text)

var gLogVerbose = false
  ## THE VERBOSITY KNOB. Default FALSE -- quiet. It governs `debug` only; no
  ## `info`, `warn`, `ok` or `error` line is ever suppressed by it, so turning
  ## verbosity off can never hide a verdict or a failure. What it hides is
  ## routine per-poll bookkeeping that is only interesting while something is
  ## being debugged.

proc setLogVerbose*(on: bool) =
  gLogVerbose = on

proc logVerbose*(): bool =
  gLogVerbose

proc debug*(msg: string) =
  ## High-rate routine detail. DROPPED unless verbosity is on.
  ##
  ## Use this ONLY for a line that is bookkeeping -- "a request arrived", "a
  ## tick ran". Never for a verdict, never for a failure, and never for the
  ## sole evidence that a feature works: those must survive a quiet run, and a
  ## line that only appears in verbose mode is a line that is absent from every
  ## log a player ever sends us.
  if gLogVerbose:
    logLine("debug", msg)

proc info*(msg: string) = logLine("info ", msg)
proc warn*(msg: string) = logLine("warn ", msg)
proc fail*(msg: string) = logLine("error", msg)
proc okLog*(msg: string) = logLine("ok   ", msg)

proc readBytes*(p: HostPtr; len: int32): string =
  ## A host buffer as a string, in one `copyMem`.
  ##
  ## This read the buffer through `aowl_byte_at` -- a call across a translation
  ## unit **per byte**. That is nothing for a mod's guid and ruinous for a route
  ## response, which is the other thing it is used for: a 4 MB item table cost
  ## four million calls, and it was the single largest cost in serving one.
  ##
  ## `cByteAt` is still there and still right for reading one byte out of a
  ## buffer whose length nobody has established.
  result = ""
  if p == nil or len <= 0'i32:
    return
  let n = int(len)
  let dest = beginStore(result, n)
  copyMem(dest, p, n)
  endStore(result)

proc ownDirectory*(): string =
  var buf = newSeq[byte](32768)
  let n = cSysModulePath(cast[HostPtr](addr buf[0]), 32767'i32)
  if n <= 0'i32:
    return ""
  var path = ""
  for i in 0 ..< int(n):
    path.add char(buf[i])
  result = parentOf(path)

# ------------------------------------------------- what only one host can do

type
  HostBlockFn* = nil proc (hostBlock: HostPtr)
    ## A chance to finish the `AowlHostApi` block after `aowl_hostapi_new` has
    ## built it and before `aowlspt_init` is handed it.
    ##
    ## `nil proc`, not `proc`: nimony's proc types are non-nil by default, so a
    ## plain `proc` type cannot hold the nil this starts as.

var gArmHostBlock: HostBlockFn = nil

proc setHostBlockArm*(fn: HostBlockFn) =
  ## Installed once at startup by a host that fills entries the shared builder
  ## cannot. **Both long-lived hosts do**, and they fill disjoint halves.
  ##
  ## The visible consequence, written down here because it reads like a bug and
  ## is not: the IL2CPP host's block reports `size` 216 while a mod compiled
  ## against the current header measures 224. 216 is revision 4; 224 is revision
  ## 5, which is `notify_push`. The client host has no notifier and does not
  ## claim one, so a client mod's `notifyReady()` is false *by size*, correctly.
  ## See the note at the foot of `abi/aowlspt_live.h`.
  ##
  ## The IL2CPP host calls `aowl_hostapi_arm_live` to publish
  ## `handle_pointer`/`handle_pin` and `patch_typed`, which mean nothing
  ## without a managed heap. The backend calls `aowl_hostapi_arm_notify` to
  ## publish `notify_push`, which means nothing without a socket.
  ##
  ## That is why `size` alone stopped being able to answer "which capability".
  ## It is a watermark, so the backend cannot raise it to revision 5 while
  ## leaving 3 and 4 unfilled -- `aowlspt_notify.h` installs stubs for the
  ## live-pointer entries that return `ErrUnsupported`, and only then raises
  ## it. A mod's boundary test therefore means what it always meant: there is
  ## a function at that offset which will answer. It has never meant that the
  ## answer is yes.

  gArmHostBlock = fn

proc sideName*(side: int32): string =
  ## Only for the log. A host that skipped a mod should say which side it was
  ## looking for, because "does not support this side" read from a client log
  ## and a server log is the same sentence about two different things.
  case side
  of SideServer: "server"
  of SideClient: "client"
  of SideSim: "sim"
  else: "unknown"

# --------------------------------------------------------------- discovery

proc discoverMods*(root: string): seq[string] =
  ## `mods/<name>/<name>.dll`, plus any dll directly under `mods/`.
  ##
  ## One level deep only: a mod's own dependencies sit beside it, and probing
  ## those as mods would load a support library and then report it as a broken
  ## mod because it exports none of the entry points.
  result = @[]
  if not isDirectory(root):
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(root, files, dirs)
  for f in files:
    if not endsWith(toLowerAscii(f), ".dll"):
      continue
    var depth = 0
    for ch in f:
      if ch == '\\':
        inc depth
    if depth > 1:
      continue
    result.add joinPath(root, f)

# ------------------------------------------------ what the player chose
#
# `discoverMods` answers "what is here". It cannot answer "what did the player
# ask for, and in what order", and both of those were being ignored:
#
#  * A player who selected nothing still got every mod's `on_load`, its
#    database writes and its routes. The mod manager only unloaded the
#    unselected ones later, when `/aowlspt/mods/apply` was called -- so a mod
#    the panel showed as `not-selected` was serving requests until somebody
#    pressed a button, and on a host with no live control, for ever.
#  * `loadAfter` in the registry was not honoured at all. The manager resolves
#    a correct order and writes it down; nothing read it, so the order was
#    whatever `collectEntries` happened to hand back. Measured: SAIN loading
#    before MoreBots against the registry's own instruction.
#
# The manager writes the answer to both to `aowlspt-selection.json`. This is
# the half that reads it.
#
# **Missing is not the same as unreadable, and neither one may stop the host.**
# A fresh install has no selection file at all, and a host that loaded nothing
# because a file was absent would be far worse than one that loads too much --
# so absent, unreadable, not-a-selection and written-for-another-side all mean
# exactly what this module did before: walk the directory, load everything.
# They are told apart in the *log*, because "there has never been one" is
# normal and "there is one and I could not read it" is a fault somebody has to
# see.
#
# The one case that is honoured to the letter is a document this host can read
# that names at least one mod: then only the mods it names load, in the order it
# names them, and everything else installed stays on the disk doing nothing.
# That is the whole of the first failure above -- a selection that leaves a mod
# out now means the mod's `on_load` never runs, rather than meaning it runs and
# is taken out again later if somebody presses a button.
#
# An empty `load` array is refused rather than honoured, and `readSelection`
# says why at length: it is the document a manager writes when it could not
# read its own store, it is indistinguishable from one written for a player who
# chose nothing, and only one of those two readings can brick an install.

const SelectionFile* = "aowlspt-selection.json"

type
  SelectionRead* = enum
    srAbsent      ## no file anywhere; a fresh install, and not a fault
    srUnusable    ## there is one and it could not be read or made sense of
    srOtherSide   ## a selection, for a different host's side
    srHonoured    ## a selection this host will act on

var gSelectionNote = ""

proc selectionNote*(): string = gSelectionNote
  ## The path a selection was read from, or the sentence saying why one was
  ## not. Exported so a host can put it somewhere a player will look.

proc unquotedJson(raw: string): string =
  ## `pathItems` hands back each element as it was written, so a string element
  ## still has its quotes on.
  var v = strip(raw)
  if v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"':
    return v.substr(1, v.len - 2)
  result = v

proc readSelection*(modsDir: string; side: int32;
                    ids: var seq[string]): SelectionRead =
  ## The mod ids to load, in order.
  ##
  ## Two places are looked in, in order: beside the mods directory (the install
  ## root, which is where a host is told to look) and inside it. Both, because
  ## the writer and the reader are different programs shipped in the same box
  ## and a host that only accepted one of them would be a silent no-op the day
  ## the other moved.
  ids = @[]
  gSelectionNote = ""
  var candidates: seq[string] = @[]
  let root = parentOf(modsDir)
  if root.len > 0:
    candidates.add joinPath(root, SelectionFile)
  candidates.add joinPath(modsDir, SelectionFile)

  var path = ""
  var text = ""
  var present = false
  for c in candidates:
    if not exists(c):
      continue
    present = true
    path = c
    text = ""
    # `readShared` rather than `readTextFile`: the manager may hold this file
    # open, and a sharing violation read as "there is no selection" would put
    # the host back on the directory walk for a reason that has nothing to do
    # with the player.
    if readShared(c, text) and text.len > 0:
      break
    if readTextFile(c, text) and text.len > 0:
      break
    text = ""
  if not present:
    gSelectionNote = "no " & SelectionFile & " beside or inside " & modsDir
    return srAbsent
  if text.len == 0:
    gSelectionNote = path & " is there and is empty or could not be read"
    return srUnusable

  var schema = ""
  if pathGet(text, "schema", schema) and schema.len > 0 and
     not startsWith(schema, "aowlspt.selection/"):
    gSelectionNote = path & " is not a selection document (its schema is \"" &
                     schema & "\")"
    return srUnusable
  # The side is checked and not assumed. The server's manager writes a
  # server-side document; a client host that acted on one would unload every
  # client mod it has because none of them is named in it.
  var docSide = ""
  if pathGet(text, "side", docSide) and docSide.len > 0 and
     docSide != sideName(side):
    gSelectionNote = path & " was written for the " & docSide &
                     " side and this host is the " & sideName(side) & " one"
    return srOtherSide
  var items: seq[string] = @[]
  if not pathItems(text, "load", items):
    # No `load` at all, or a truncated array. Either way this is not something
    # to act on, and `pathItems` is deliberate about the difference between an
    # empty array and an absent one.
    gSelectionNote = path & " has no readable \"load\" array in it"
    return srUnusable
  for it in items:
    let id = unquotedJson(it)
    if id.len > 0:
      ids.add id
  if ids.len == 0:
    # An empty `load` is refused, and this is the one refusal worth spelling
    # out because it looks like a legitimate answer.
    #
    # A working manager always names at least itself: its own row is protected
    # precisely so that a selection cannot switch off the thing that would let
    # you switch it back on. So an empty list is never "the player chose
    # nothing" -- it is the manager saying it resolved nothing, which is what
    # it writes when its *own* stored selection could not be read. Acting on it
    # would take the manager out at the next start, and with it every route
    # that could put it back: the install would be dead with no way in.
    #
    # Measured, not imagined: `livectl` damages the manager's store on purpose,
    # restarts, and the document written in between says `"load":[]`.
    gSelectionNote = path & " names no mods at all, which is what the manager " &
                     "writes when it could not resolve anything rather than " &
                     "what it writes when nothing is chosen"
    return srUnusable
  gSelectionNote = path
  result = srHonoured

proc probeGuid(path: string; guid: var string): bool =
  ## What one library calls itself, without starting it.
  ##
  ## A selection names mods by id, and a directory names them by file, so
  ## something has to join the two. This is that: load, check the ABI version,
  ## `describe`, read the guid, and put the library straight back down. Nothing
  ## is initialised, so nothing is registered and no `on_load` runs -- which is
  ## the entire point, because the mods that are *not* selected are probed and
  ## must never start.
  ##
  ## Only ever called when there is a selection to honour. On a fresh install
  ## there is none, and then no library is opened twice.
  ##
  ## `cModAllocTeardown` before `cFreeLibrary` for the reason at the top of this
  ## file: every mod links its own mimalloc and a load that does not give the
  ## arena back costs 32 MB. Nothing survives this call, so there is nothing
  ## pointing into what it releases.
  guid = ""
  var p = path
  cModAllocPrepare()
  let module = cLoadLibrary(toCString(p))
  if module == nil:
    return false
  var symVersion = "aowlspt_abi_version"
  var symDescribe = "aowlspt_describe"
  let fnVersion = cGetProc(module, toCString(symVersion))
  let fnDescribe = cGetProc(module, toCString(symDescribe))
  var got = false
  if fnVersion != nil and fnDescribe != nil and
     cModAbiVersion(fnVersion) == cAbiVersionExpected():
    let info = cModInfoNew()
    if info != nil:
      if cModDescribe(fnDescribe, info) == StatusOk:
        guid = readBytes(cModInfoGuidPtr(info), cModInfoGuidLen(info))
        got = guid.len > 0
      cModInfoFree(info)
  discard cModAllocTeardown(module)
  cFreeLibrary(module)
  result = got

proc liveIndexOfGuid(guid: string): int =
  ## Which slot holds a LIVE mod with this guid, or -1.
  ##
  ## Deliberately NOT `modIndexOf` (declared far below, and it answers for
  ## dead slots too). A slot is KEPT after an unload -- every context pointer
  ## handed to a mod is its index -- so "is this guid in the table" and "is
  ## this mod RUNNING" are different questions. The second is the one that
  ## matters here, because unload-then-load-again is the hot reload and the
  ## manager switching a mod off and back on, and both must keep working.
  result = -1
  if guid.len == 0: return
  for i in 0 ..< gMods.len:
    if gMods[i].live and gMods[i].guid == guid:
      return i

proc atSecs(ms: int64): string =
  ## `ms` since this host started, as seconds to one decimal. "?" rather
  ## than a fabricated number when there is nothing to report.
  if ms < 0: return "?"
  result = $(ms div 1000'i64) & "." & $((ms mod 1000'i64) div 100'i64) & "s"

proc loadMod*(path: string; side: int32; hostName, hostVersion: string;
              sptVersion = ""; gameVersion = ""; homeDir = ""): bool =
  ## Brings one mod up: version probe, describe, init, on_load. A step that
  ## fails leaves the mod unloaded rather than half-loaded, and says which step.
  ##
  ## `homeDir` overrides where the mod is told it lives -- `mod_dir` in
  ## `AowlHostInfo`, and `data_dir` under it. It is empty for both long-lived
  ## hosts and must stay that way: in an install a mod *is* its directory, and
  ## a host that answered anything but the library's own parent would be
  ## lying about a path the mod then reads files out of.
  ##
  ## The simulator is the case that needs it. It runs a mod out of a source
  ## tree, where the library is at `<mod>/bin/<mod>.dll` and everything the mod
  ## owns -- `config.json`, `data/`, and for the manager the registry two
  ## levels up -- is at `<mod>/`. Deriving the directory from the library would
  ## hand every one of those a `bin/` that contains none of them, and the
  ## symptom is a mod that loads and then reports its own config missing.
  ## It is also what lets the simulator load a *copy* of the library, which is
  ## what makes `--watch` possible at all.
  var m = LoadedMod(path: path,
                    dir: (if homeDir.len > 0: homeDir else: parentOf(path)),
                    module: cast[HostPtr](0), info: cast[HostPtr](0),
                    api: cast[HostPtr](0), hostBlock: cast[HostPtr](0),
                    guid: "", name: "", author: "", version: "",
                    hasUpdate: false, live: false, loadedAt: 0'i64,
                    tickFails: 0,
                    tickWarned: false, tickFaulted: false,
                    initTid: 0'u32, tickWrongThread: false, flags: 0'u32,
                    profSlot: -1'i32)

  # Before the first `LoadLibrary` of the process and harmless on every one
  # after it: each mod's mimalloc reads this when it initialises, and without
  # it `mi_process_done` collects the heap and keeps the 32 MiB arena.
  cModAllocPrepare()
  var p = path
  m.module = cLoadLibrary(toCString(p))
  if m.module == nil:
    fail "could not load " & path & " (error " & $int(cSysLastError()) & ")"
    return false

  var symVersion = "aowlspt_abi_version"
  var symDescribe = "aowlspt_describe"
  var symInit = "aowlspt_init"
  let fnVersion = cGetProc(m.module, toCString(symVersion))
  let fnDescribe = cGetProc(m.module, toCString(symDescribe))
  let fnInit = cGetProc(m.module, toCString(symInit))

  if fnVersion == nil or fnDescribe == nil or fnInit == nil:
    fail baseName(path) & " does not export the aowlspt entry points"
    cFreeLibrary(m.module)
    return false

  let theirs = cModAbiVersion(fnVersion)
  let ours = cAbiVersionExpected()
  if theirs != ours:
    fail baseName(path) & " was built against ABI version " & $int(theirs) &
         "; this host implements " & $int(ours)
    cFreeLibrary(m.module)
    return false

  m.info = cModInfoNew()
  if m.info == nil:
    cFreeLibrary(m.module)
    return false
  if cModDescribe(fnDescribe, m.info) != StatusOk:
    fail baseName(path) & ": describe failed"
    cModInfoFree(m.info)
    cFreeLibrary(m.module)
    return false

  m.guid = readBytes(cModInfoGuidPtr(m.info), cModInfoGuidLen(m.info))
  m.name = readBytes(cModInfoNamePtr(m.info), cModInfoNameLen(m.info))
  m.author = readBytes(cModInfoAuthorPtr(m.info), cModInfoAuthorLen(m.info))
  m.version = readBytes(cModInfoVersionPtr(m.info), cModInfoVersionLen(m.info))
  m.flags = cModInfoFlags(m.info)

  # A mod that does not claim this side is skipped rather than run. The same
  # binary ships to every host, and running its client half in a server would
  # be worse than not loading it.
  let sides = cModInfoSides(m.info)
  if (sides and (1'u32 shl uint32(side))) == 0'u32:
    info m.name & " does not support the " & sideName(side) & " side; skipping"
    cModInfoFree(m.info)
    cFreeLibrary(m.module)
    return false

  # INITIALISE EXACTLY ONCE PER SESSION.
  #
  # MEASURED 2026-09-02 in aowlspt-host.log: the backend's mod-set poll
  # loaded aowl.sain at 4.5s ("the backend wants aowl.sain loaded; queueing
  # ...\mods\sain\sain.dll"), and the DEFERRED mod release then ran
  # `loadAll` over that same directory at 40.7s and loaded it a second time
  # -- 16 candidate libraries, no consultation of the loaded set. Six mods
  # got two `init` + `on_load` runs in one session. `modcontrol.doLoad` has
  # always been idempotent (`gOps.indexOf(guid) >= 0` -> noop); `loadAll`
  # never was, and nothing below it knew either.
  #
  # sain's publish-once selftest is what made this visible rather than
  # merely fatal: it PASSED at 4.5s and FAILED at 40.7s, reporting the
  # schema already published before it had declared anything. The settings
  # publish-once guard is the only reason run two refused instead of
  # freeing run one's rows under a live reader.
  #
  # Refused HERE, and not in `loadAll`, for a specific reason: `loadAll`
  # would have to learn the guid from the FILE, and the only way to do that
  # is `probeGuid` -- which ends in `cModAllocTeardown` + `cFreeLibrary`.
  # Run against a library that is already live in this process, that
  # collects the RUNNING mod's heap: a use-after-free generator standing in
  # for a use-after-free fix. By this line the library is open and has
  # described itself, so the check is one walk of a table of at most
  # `ModSlotLimit` rows and costs no second load.
  #
  # `cFreeLibrary` on the way out is correct and not a double free: this
  # call's own `cLoadLibrary` took a reference on an already-mapped module,
  # so this drops the count back to what it was. It is the same exit the
  # side check above takes, and like that one it does NOT tear the
  # allocator down.
  let already = liveIndexOfGuid(m.guid)
  if already >= 0:
    warn "mod " & m.guid & ": init #2 SKIPPED (already initialised at " &
         atSecs(gMods[already].loadedAt) & " from " & gMods[already].path &
         "). A mod's init and on_load run ONCE per session. The second run " &
         "would re-register every route, event, timer and detour the first " &
         "one registered, and re-declare its settings schema over the live " &
         "one. Nothing was loaded and the running mod is untouched: this is " &
         "two load paths reaching the same library, not a broken mod."
    cModInfoFree(m.info)
    cFreeLibrary(m.module)
    return false

  let index = gMods.len
  # Refused here rather than discovered later: past the end of the slot table
  # there is no flag and no counter for this mod, so `modEnter` would refuse
  # every request to it and the symptom would be a mod that loads and answers
  # nothing. See `ModSlotLimit`.
  if index >= ModSlotLimit:
    fail m.name & ": " & $index & " mods have been loaded in this session," &
         " which is the limit; restart the host"
    cModInfoFree(m.info)
    cFreeLibrary(m.module)
    return false
  var modDir = m.dir
  var dataDir = joinPath(m.dir, "data")
  var hn = hostName
  var hv = hostVersion
  var sv = sptVersion
  var gv = gameVersion
  m.hostBlock = cHostApiNew(cast[HostPtr](uint(index)), side,
                            toCString(hn), toCString(hv),
                            toCString(sv), toCString(gv),
                            toCString(modDir), toCString(dataDir))
  if m.hostBlock == nil:
    cModInfoFree(m.info)
    cFreeLibrary(m.module)
    return false

  # Anything the shared builder could not fill, filled now -- before `init`
  # sees the block, because a mod reads `size` and the appended pointers on the
  # way in and never looks again.
  if gArmHostBlock != nil:
    gArmHostBlock(m.hostBlock)

  m.api = cModApiNew()
  if cModInit(fnInit, cHostApiPtr(m.hostBlock), m.api) != StatusOk:
    fail m.name & ": init refused the host"
    cModApiFree(m.api)
    cHostApiFree(m.hostBlock)
    cModInfoFree(m.info)
    cFreeLibrary(m.module)
    return false

  m.hasUpdate = cModApiHasUpdate(m.api) != 0'i32
  m.live = true
  m.loadedAt = elapsedMs()
  # THE THREAD THIS MOD IS NOW BOUND TO. `init` ran on it and `on_load` is
  # about to; both allocate through the mod's own mimalloc, whose default heap
  # is thread-bound. See `initTid` and the refusal in `tickMods`.
  m.initTid = cSysThreadId()
  gMods.add m

  if cModApiOnLoad(m.api) != StatusOk:
    warn m.name & ": on_load returned an error; it stays loaded but may not work"

  okLog "loaded " & m.name & " (" & m.guid & ") v" & m.version &
        (if m.author.len > 0: " by " & m.author else: "")
  result = true

proc loadAll*(modsDir: string; side: int32; hostName, hostVersion: string;
              sptVersion = ""; gameVersion = ""): int =
  ## Every mod the player asked for, in the order they asked for -- or, when
  ## they have never been asked, every mod that is there.
  ##
  ## See `readSelection` for which of those this is and why the fallback is
  ## the loud, generous one rather than the safe-looking empty one.
  let found = discoverMods(modsDir)
  info $found.len & " candidate libraries under " & modsDir

  var wanted: seq[string] = @[]
  let sel = readSelection(modsDir, side, wanted)
  case sel
  of srAbsent:
    # A fresh install, and the only case that is silent: there is nothing
    # wrong, the player has simply never chosen.
    discard
  of srUnusable:
    warn "a selection file is there and cannot be acted on, so everything " &
         "under " & modsDir & " is loaded: " & gSelectionNote
  of srOtherSide:
    info "not using a selection file: " & gSelectionNote
  of srHonoured:
    okLog "the load order comes from " & gSelectionNote & ": " &
          $wanted.len & " mod(s) selected"

  if sel == srHonoured:
    # Which file is which mod. A selection names ids and a directory names
    # files, and only the library itself knows which id it is -- so each one is
    # opened, asked, and put back down. `probeGuid` starts nothing.
    var guids: seq[string] = @[]
    for path in found:
      var g = ""
      discard probeGuid(path, g)
      guids.add g

    var taken = newSeq[bool](found.len)
    for i in 0 ..< found.len:
      taken[i] = false
    var order: seq[int] = @[]
    for id in wanted:
      var hit = -1
      for i in 0 ..< guids.len:
        if not taken[i] and guids[i].len > 0 and guids[i] == id:
          hit = i
          break
      if hit < 0:
        info "the selection names " & id & ", which is not installed under " &
             modsDir
      else:
        taken[hit] = true
        order.add hit

    # The second refusal, and the same argument as the empty one in
    # `readSelection`: a selection that names mods and matches *none* of them
    # is not a selection about this directory -- a stale file, a copy from
    # another install, a mods folder that moved -- and acting on it would leave
    # a host running nothing with no way for the player to say otherwise.
    if order.len == 0:
      warn "the selection names " & $wanted.len & " mod(s) and not one of " &
           "them is under " & modsDir & "; it is being ignored and " &
           "everything there is loaded instead"
    else:
      for i in 0 ..< found.len:
        if not taken[i]:
          info (if guids[i].len > 0: guids[i] else: baseName(found[i])) &
               " is installed and not selected, so it is not loaded"
      for k in order:
        discard loadMod(found[k], side, hostName, hostVersion, sptVersion,
                        gameVersion)
      return gMods.len

  for path in found:
    discard loadMod(path, side, hostName, hostVersion, sptVersion, gameVersion)
  result = gMods.len

const
  TickFaultLimit* = 120
    ## How many **consecutive** non-OK answers from `on_update` it takes before
    ## a host stops calling it.
    ##
    ## The number is a duration in disguise, and the two tick rates it has to
    ## suit are 16 ms (the client host's loop and the simulator's default) and
    ## 50 ms (the backend's). 120 consecutive failures is therefore about two
    ## seconds of a mod failing every single frame in the game, and about six
    ## on the server. That is the line the threshold is drawn on: one failed
    ## tick is not a broken mod -- a mod polls for a world that is not up yet,
    ## a config read loses a race with a file being written -- and two seconds
    ## of nothing but failure is not a mod that is about to recover.
    ##
    ## It counts a **run**, not a total: any OK answer sets the count back to
    ## zero, so a mod that fails one tick in fifty for an entire session is
    ## never disabled. That is deliberate. The failure this exists to make
    ## visible is the one that is total and silent, and a mod that mostly works
    ## is not it -- disabling one mid-raid over an intermittent fault would
    ## take away more than it gave.
    ##
    ## No mod in this repository can reach even 1. Every `on_update` under
    ## `mods/` and `examples/` returns `Ok` on every path, including the early
    ## returns for the wrong side -- checked, not assumed, because whether the
    ## status is routinely non-zero for benign reasons is the whole question of
    ## whether it can be acted on at all. The ABI is unambiguous that it cannot
    ## be: `AOWLSPT_OK` is "ran fine" and `AOWLSPT_PATCH_SKIP` -- the one other
    ## status with a non-failure meaning -- belongs to patch handlers, not to
    ## this entry.

proc tickMods*(elapsed: int64) =
  ## One `on_update` per live mod, and the ABI's answer to it honoured.
  ##
  ## This used to `discard` the status, which made the whole return value
  ## decorative and made a mod that failed on every single tick completely
  ## silent -- the exact species of failure a player has no way to diagnose,
  ## because nothing anywhere says which mod stopped working or that anything
  ## stopped at all.
  ##
  ## Three rules, and each of them is a constraint the tick loop imposes:
  ##
  ##  * **Nothing here may take the host down or stall the frame.** So a
  ##    failure costs a compare and an increment, the log happens twice per mod
  ##    for the life of the process, and a faulted mod is skipped by a branch
  ##    rather than unloaded -- an unload from in here would run `on_unload`,
  ##    the host's teardown and `FreeLibrary` inside the game's frame budget,
  ##    on a mod whose own tick is on the stack one frame earlier.
  ##  * **Say it once.** The first failure *ever* is one `warn` naming the mod
  ##    and the status; crossing the threshold is one `error`. Two lines per
  ##    mod for the life of the process, and no more. A line per frame at
  ##    60 fps is its own denial of service, and it would bury the line that
  ##    mattered. "Once per run of failures" is not good enough and looked as
  ##    though it was -- see `tickWarned`.
  ##  * **Leave every other mod alone.** The loop carries on; a faulted mod's
  ##    routes, events, timers and detours are untouched, and it is still
  ##    `live`, so the manager can still unload it and a player can still see
  ##    it listed.
  ##
  ## **On the refcount discipline, and why this does not touch it.** The
  ## in-flight counter and the draining flag exist because a mod's *other*
  ## entries -- routes, events, timers -- are called from threads that are not
  ## this one, so an unload has to close the door and wait. Disabling a tick is
  ## none of that: `tickFails` and `tickFaulted` are read and written here and
  ## nowhere else, and `tickMods`, `loadMod` and `unloadOne` all run on the one
  ## thread in every host that has one (the backend's serve loop, the client
  ## host's tick thread, the simulator's single thread -- in each, `tickMods`
  ## and `modcontrol.drain` are consecutive statements in the same loop). So
  ## there is no call in flight to race: the only call this can suppress is the
  ## one this same thread would have made on the next pass.
  ##
  ## What it must **not** do, and does not, is reuse `cModDrainBegin` to mean
  ## "disabled". That flag is the unload path's, it is read on the way into
  ## every route and event handler, and setting it here would silently stop a
  ## faulted mod answering HTTP as well -- and would leave `unloadOne`'s drain
  ## looking at a flag somebody else set. `tests/tickfault` asserts that a
  ## faulted mod is still enterable for exactly that reason.
  let profOn = cProfEnabled() != 0
  # The LOADER's window boundary, once per pass rather than once per mod. On the
  # backend and the simulator it is the only boundary there is, which is what
  # makes the profiler measurable without a game running; on the client host the
  # frame rider boundary also fires and owns the frame-time histogram. It does
  # NOT write that histogram -- see `aowl_prof_boundary`.
  if profOn: cProfTickBoundary()
  # THE THREAD THIS PASS IS ON, read once. Every mod below is checked against
  # the thread that initialised it -- see the refusal inside the loop.
  let tickTid = cSysThreadId()
  for i in 0 ..< gMods.len:
    if not gMods[i].live or not gMods[i].hasUpdate or gMods[i].tickFaulted or
       gMods[i].tickWrongThread:
      continue
    # A MOD IS TICKED ONLY ON THE THREAD THAT INITIALISED IT.
    #
    # MEASURED 2026-09-02 13:18, WER dump
    # `EscapeFromTarkov.exe.16972.dmp`, 0xc0000409 FAST_FAIL_FATAL_APP_EXIT:
    # `ucrtbase!abort <- admin!mi_assert_fail <- admin!mi_malloc <-
    # admin!alloc_0 <- newWideCString <- toWide <- openIl2Cpp <- dataOpen <-
    # admin onUpdate <- modOnUpdate <- aowlspt_host_il2cpp`, on the assertion
    # `heap->thread_id == 0 || heap->thread_id == tid` in
    # `mi_heap_malloc_small_zero`. That boot had brought the deferred mods up
    # from the UNITY MAIN THREAD (the mod-loading screen's release) and then
    # ticked them from the ops thread. The previous surviving boot loaded the
    # same mod on the ops thread and ran fine.
    #
    # This is a FAIL-FAST, not a fault: `abort` takes the process down and
    # bypasses Unity's handler, so there is no Crash_* report and no SEH guard
    # anywhere can catch it. It therefore has to be refused BEFORE the call,
    # which is what this is. Skipping the tick loses that mod's update; its
    # routes, events, timers and detours are untouched.
    #
    # `initTid == 0` means the row was built by something that never went
    # through `loadMod`; that is not evidence of a wrong thread, so it is not
    # refused on.
    if gMods[i].initTid != 0'u32 and gMods[i].initTid != tickTid:
      if not gMods[i].tickWrongThread:
        gMods[i].tickWrongThread = true
        fail "mod " & gMods[i].guid & ": REFUSING to tick on thread " &
             $int(tickTid) & ", initialised on thread " &
             $int(gMods[i].initTid) & " -- the mimalloc heap is thread-bound " &
             "(measured 2026-09-02 13:18 abort in admin.dll). The mod stays " &
             "loaded and its routes, events and hooks still work; only its " &
             "tick is refused. This is said once."
      continue
    # THE PROFILER SCOPE. Registration is lazy and idempotent: it happens on
    # the first tick after the profiler is enabled, never at load, so a run
    # with the profiler off never maps the region. `profOn` is read ONCE per
    # tickMods call rather than per mod, so enabling it mid-window cannot
    # produce a window where some mods were timed and others were not.
    if profOn and gMods[i].profSlot < 0:
      # `toCString` wants a mutable string and the C side only reads it -- it
      # copies the name into the slot's fixed char[32] and keeps no pointer.
      var guidBuf = gMods[i].guid
      gMods[i].profSlot = cProfSlot(toCString(guidBuf), ProfKindMod)
    if profOn: cProfBegin(gMods[i].profSlot)
    let st = cModApiOnUpdate(gMods[i].api, elapsed)
    if profOn: cProfEnd(gMods[i].profSlot)
    if st == StatusOk:
      # A run of failures ended by a success never gets to the threshold.
      gMods[i].tickFails = 0
      continue
    if not gMods[i].tickWarned:
      # Once for the life of the process, not once per run of failures. The
      # difference is not pedantic: a mod that fails every fourth tick starts a
      # new run 150 times in a session, and "the first failure of a run" would
      # be a line every fourth frame.
      gMods[i].tickWarned = true
      warn gMods[i].guid & ": on_update returned " & $int(st) &
           " (" & statusName(st) & "). This is said once, however often it " &
           "happens; if " & $TickFaultLimit & " ticks in a row fail, the mod " &
           "stops being ticked and that is said once too."
    gMods[i].tickFails = gMods[i].tickFails + 1
    if gMods[i].tickFails >= TickFaultLimit:
      gMods[i].tickFaulted = true
      fail gMods[i].guid & " faulted, mod disabled: on_update failed " &
           $TickFaultLimit & " times in a row (last status " & $int(st) &
           ", " & statusName(st) & "). It stays loaded and its routes, " &
           "events and hooks still work -- only its tick has stopped. " &
           "Take it out and put it back, or restart the host, to try again."

proc modTickFaulted*(index: int): bool =
  ## Whether this mod has been dropped from the tick. For the mod manager's
  ## row and for the tests; nothing in the loop above reads it back through
  ## here.
  if index < 0 or index >= gMods.len:
    return false
  result = gMods[index].tickFaulted

proc modTickRefusedThread*(index: int): bool =
  ## Whether this mod's tick was REFUSED because the ticking thread is not the
  ## thread that initialised it. A THIRD outcome: any diagnostic that reports
  ## mod tick state must distinguish ticking / refused-wrong-thread /
  ## not-live, because folding this into "faulted" reports a fault that never
  ## happened and folding it into "ticking" hides a mod that is not running.
  if index < 0 or index >= gMods.len:
    return false
  result = gMods[index].tickWrongThread

proc modInitThread*(index: int): uint32 =
  ## The thread id that initialised this mod, or 0 when unknown.
  if index < 0 or index >= gMods.len:
    return 0'u32
  result = gMods[index].initTid

proc modTickFailures*(index: int): int =
  ## The current run of consecutive `on_update` failures. Zero for a healthy
  ## mod, `TickFaultLimit` for a faulted one.
  if index < 0 or index >= gMods.len:
    return 0
  result = gMods[index].tickFails

proc unloadMods*() =
  ## Every mod, on the way out of the process.
  ##
  ## Drained like `unloadOne`, with a shorter deadline and without the refusal:
  ## by the time this runs the listener is stopped and nothing new is arriving,
  ## so a thread still inside a mod is one finishing the request it already
  ## had. Waiting for it costs a moment on shutdown and removes the last window
  ## in which a worker and a `FreeLibrary` overlap. If it does not come out,
  ## this proceeds anyway and says so -- a host that cannot exit is worse than
  ## one that exits loudly.
  for i in 0 ..< gMods.len:
    if not gMods[i].live:
      continue
    if not drainMod(i, 1000):
      warn "shutting down with a request still inside " & gMods[i].name
    discard cModApiOnUnload(gMods[i].api)
    cModApiFree(gMods[i].api)
    cHostApiFree(gMods[i].hostBlock)
    cModInfoFree(gMods[i].info)
    discard cModAllocTeardown(gMods[i].module)
    cFreeLibrary(gMods[i].module)
    gMods[i].live = false

# ---------------------------------------------------------------------------
# Loading and unloading one mod, while the host keeps running
# ---------------------------------------------------------------------------
#
# A mod can be taken out and put back without stopping the server. That is worth
# having and it is not free, because a mod leaves things behind it: routes,
# event subscriptions, timers, and on the client, detours. Those live in the
# host that owns them, not here, so unloading is two halves -- this half frees
# the library, and the host's half drops what the mod registered.
#
# The order matters and is the whole of the danger. Everything the mod
# registered has to be dropped **before** its library is freed, because every
# one of those is a function pointer into it: a route still in the table after
# `FreeLibrary` is a call into unmapped memory on the next request, which is a
# crash with no stack worth reading. So the host passes a teardown it runs
# first, and this refuses to unload without one.

type
  TeardownFn* = nil proc (index: int)
    ## `nil proc`, not `proc`: nimony's pointer and proc types are non-nil by
    ## default, so a plain `proc` type cannot hold the nil this starts as -- it
    ## fails at the declaration with "expected non-nil value", which reads like
    ## a problem with the assignment rather than with the type.
    ## Drops everything the mod at `index` registered with the host. Called
    ## before the library is freed, and must be complete: whatever it misses
    ## becomes a call into unmapped memory.

var gTeardown: TeardownFn = nil

const
  ModHotReloadable* = 1'u32   ## AOWLSPT_MOD_HOT_RELOADABLE
  ModThreadSafe*    = 2'u32   ## AOWLSPT_MOD_THREAD_SAFE

proc setModTeardown*(fn: TeardownFn) =
  ## Installed once by the host at startup. Without it, `unloadOne` refuses --
  ## a host that cannot say what a mod registered cannot safely unload it.
  ##
  ## All three hosts install a `dropModRegistrations` here, and no two of them
  ## are the same proc: the backend's drops routes, event subscriptions and
  ## timers; the simulator's drops what it has; the client host's drops event
  ## subscriptions, queued main-thread callbacks (under the drain's lock) and,
  ## the one that has no server equivalent, the mod's **detours** -- a hook left
  ## installed is a game jumping into a freed DLL. That is the whole reason this is a seam rather than a field on
  ## `LoadedMod`: what a mod leaves behind is per-host, and the order it has to
  ## be dropped in is not.
  gTeardown = fn

proc hasTeardown*(): bool =
  ## Whether this host can take a mod out at all. Asked by the mod-control
  ## path so it can tell the manager the truth up front rather than accepting
  ## an unload request and refusing every one of them.
  result = gTeardown != nil

proc modCount*(): int = gMods.len

proc modIndexOf*(guid: string): int =
  result = -1
  for i in 0 ..< gMods.len:
    if gMods[i].live and gMods[i].guid == guid:
      return i

proc modPathOf*(index: int): string =
  if index < 0 or index >= gMods.len:
    return ""
  result = gMods[index].path

proc modNameOf*(index: int): string =
  if index < 0 or index >= gMods.len:
    return ""
  result = gMods[index].name

proc modIsLive*(index: int): bool =
  if index < 0 or index >= gMods.len:
    return false
  result = gMods[index].live

## THE RELEASE PROBE'S ANSWER, from the last `unloadOne` that got as far as
## freeing a library. `0` means the file was writable afterwards -- a rebuild
## can be copied over it and the reload is real. Anything else is the Win32
## error, and `32` (ERROR_SHARING_VIOLATION) means the module is still mapped.
##
## `-1` is "no unload has reached the probe this run", which is neither pass nor
## fail. Three states, and the caller must not flatten them: a run that never
## unloaded anything has not demonstrated release, and reporting that as 0 would
## be the same shape of lie this whole probe exists to catch.
var gLastRelease = -1'i32
var gLastReleaseStillMapped = false
var gForceRelease = false

proc lastReleaseCode*(): int32 = gLastRelease
proc lastReleaseStillMapped*(): bool = gLastReleaseStillMapped

proc setForceRelease*(on: bool) =
  ## Arms the capped extra-`FreeLibrary` loop in `unloadOne`.
  ##
  ## **Default OFF, and it stays off until the measurement says what the
  ## refcount actually is.** Dropping references until a module unmaps is a fix
  ## for exactly one cause -- somebody took a reference and never gave it back --
  ## and it is a way to unmap a library out from under a legitimate holder for
  ## every other cause. The probe below reports the number without this; turn it
  ## on only once the report says the count is what you think it is.
  gForceRelease = on

proc unloadOne*(index: int; error: var string): bool =
  ## Takes one mod out. The slot is kept rather than removed: every context
  ## pointer the host handed to a mod is that index, and compacting the
  ## sequence would silently repoint them at their neighbours.
  error = ""
  if index < 0 or index >= gMods.len:
    error = "no such mod"
    return false
  if not gMods[index].live:
    error = "that mod is not loaded"
    return false
  if gTeardown == nil:
    error = "this host cannot unload a mod: it has no teardown registered"
    return false

  let name = gMods[index].name

  # Before anything else: close the mod to new calls and wait for the threads
  # already inside it to come out.
  #
  # This is first rather than last because every step below is destructive to
  # a thread that is still in there -- `on_unload` lets the mod free its own
  # state, the teardown drops the registrations, and `cFreeLibrary` unmaps the
  # code being executed. The drain is what makes "the teardown happens before
  # the free" mean something for a worker that took its route out of the table
  # a moment earlier and has not called it yet.
  #
  # A drain that expires leaves the mod **loaded**. Freeing a library out from
  # under a live thread is the bug; refusing an unload is an inconvenience with
  # a message attached, and the manager can ask again.
  if not drainMod(index, DrainDeadlineMs):
    cModDrainCancel(int64(index))
    error = "a request is still running inside " & name &
            " after " & $DrainDeadlineMs & " ms; it stays loaded"
    warn error
    return false

  # The mod's own `on_unload` first, so it can save state; then everything it
  # registered; then the library.
  #
  # SAID, NOT REFUSED. `on_unload` allocates and frees through the mod's own
  # thread-bound mimalloc exactly as `on_update` does, so calling it from a
  # thread other than the one that initialised the mod is the same hazard the
  # tick refuses (see `initTid`). It is not refused here because refusing an
  # unload leaks the library and its arena for the life of the process, which
  # is worse; but if the process fail-fasts inside `mi_*` on an unload, THIS
  # line is the one that names why. Unverified live: no unload has been
  # observed crossing threads.
  if gMods[index].initTid != 0'u32 and gMods[index].initTid != cSysThreadId():
    warn "mod " & gMods[index].guid & ": unloading on thread " &
         $int(cSysThreadId()) & " but it was initialised on thread " &
         $int(gMods[index].initTid) & " -- on_unload allocates through a " &
         "thread-bound mimalloc heap. Proceeding anyway: refusing an unload " &
         "leaks the library."
  discard cModApiOnUnload(gMods[index].api)
  gTeardown(index)
  cModApiFree(gMods[index].api)
  cHostApiFree(gMods[index].hostBlock)
  cModInfoFree(gMods[index].info)
  # Last, and only here: see the note at the top of this file. Everything the
  # host holds has been freed, so nothing points into the arena this releases.
  discard cModAllocTeardown(gMods[index].module)
  cFreeLibrary(gMods[index].module)

  # AND THEN MEASURE, rather than assume. `cFreeLibrary` returns nothing and
  # decrements a refcount; if something took a second reference, this returns
  # normally, the mod is logically gone, and the file stays mapped and locked.
  # That is precisely what a live run produced: `completed=1`, `epoch=1`,
  # `unloaded Bot AI`, and a DLL that could not be overwritten.
  var probePath = gMods[index].path
  var stillMapped = cModuleLoaded(toCString(probePath)) != 0'i32
  if stillMapped and gForceRelease:
    # Capped, and each pass CONDITIONED on a fresh read rather than counted out
    # in advance -- this is not a blind write. It stops the moment the module is
    # gone, and after `ForceReleaseMax` it gives up and lets the probe below
    # report the failure honestly.
    const ForceReleaseMax = 8
    var drops = 0
    while stillMapped and drops < ForceReleaseMax:
      cFreeLibrary(gMods[index].module)
      inc drops
      stillMapped = cModuleLoaded(toCString(probePath)) != 0'i32
    warn "forceRelease dropped " & $drops & " extra reference(s) on " &
         baseName(probePath) & "; still mapped: " &
         (if stillMapped: "YES" else: "no") &
         ". Every one of those was a reference something took and never gave " &
         "back -- this is a workaround, and the count is the bug report."
  gLastReleaseStillMapped = stillMapped
  gLastRelease = cPathWritable(toCString(probePath))
  # Said always, both numbers, pass or fail. This is the line that tells a
  # logical unload from a real one, and the whole reason it exists is that the
  # counters said success while the feature was impossible.
  if gLastRelease == 0'i32 and not stillMapped:
    okLog "RELEASED " & baseName(probePath) &
          ": the file is writable, so a rebuild can replace it"
  else:
    warn "NOT RELEASED " & baseName(probePath) & ": stillMapped=" &
         (if stillMapped: "YES" else: "no") & " writeProbe=" & $int(gLastRelease) &
         (if gLastRelease == 32'i32: " (ERROR_SHARING_VIOLATION -- the image " &
                                     "is still mapped by this process)" else: "") &
         ". The mod is logically unloaded and its registrations are gone, but " &
         "the library was NOT freed, so a rebuilt DLL cannot be copied over it."

  # The draining flag is deliberately left set. The slot is never reused, so a
  # late `modEnter` for this index -- a worker that copied a route out of the
  # table before the teardown emptied it -- must go on being refused for the
  # life of the process rather than being admitted to an unmapped image.
  gMods[index].live = false
  gMods[index].api = cast[HostPtr](0)
  gMods[index].info = cast[HostPtr](0)
  gMods[index].hostBlock = cast[HostPtr](0)
  gMods[index].module = cast[HostPtr](0)
  okLog "unloaded " & name
  result = true

proc unloadByGuid*(guid: string; error: var string): bool =
  let idx = modIndexOf(guid)
  if idx < 0:
    error = "no loaded mod with guid " & guid
    return false
  result = unloadOne(idx, error)

proc loadOne*(path: string; side: int32; hostName, hostVersion: string;
              sptVersion = ""; gameVersion = ""; homeDir = ""): bool =
  ## Brings a mod up while the host is running. The same path a cold start
  ## takes, deliberately -- a mod that loads differently when added late is a
  ## mod whose bugs only appear one way round.
  result = loadMod(path, side, hostName, hostVersion, sptVersion, gameVersion,
                   homeDir)

proc modDirOf*(index: int): string =
  if index < 0 or index >= gMods.len:
    return ""
  result = gMods[index].dir

proc modGuidOf*(index: int): string =
  if index < 0 or index >= gMods.len:
    return ""
  result = gMods[index].guid


# --------------------------------------------------------------- config
#
# One config read, shared by the three hosts, because they had three and the
# three disagreed. The backend and the client host answered `ErrNotFound` for a
# `config.json` that did not parse -- the same status as "no such setting" --
# and the simulator answered `ErrGeneric` with a message. So a mod could not
# tell "this setting is absent, my default stands" from "this file is broken
# and none of my settings are real" anywhere, and got a different wrong answer
# depending on which host it happened to be running under.
#
# The consequence is on the record. A three-byte UTF-8 BOM, which Notepad and
# `Set-Content -Encoding utf8` write by default, made the mod manager read its
# `activeLists` as empty; it resolved nothing and wrote a selection file naming
# only itself, and the next start loaded one mod out of ten with no error
# anywhere. `readTextFile` strips that BOM now, so that trigger is gone -- but
# a trailing comma, a truncated write and a UTF-16 save reproduce it exactly,
# and it was the ambiguity, not the BOM, that made it silent.

var gConfigFaultWarned: uint64 = 0'u64
  ## One bit per mod index: whether this mod's broken config has already been
  ## named in the log. A mod that reads fifty settings out of a broken file
  ## would otherwise put fifty identical lines in the host log and bury the
  ## first one.
  ##
  ## A bitmask rather than a set of directory names because this is touched
  ## from whichever thread the mod called on -- sixteen workers, on the backend
  ## -- and a `seq[string]` grown from two of them at once is a data race on
  ## the allocator. A lost bit here costs one duplicate warning; a lost bit
  ## there costs a heap. Indices past 63 simply warn every time, which is the
  ## safe direction for a host nobody has yet run with 64 mods.

proc configFaultNoted(index: int): bool =
  if index < 0 or index >= 64:
    return false
  let bit = 1'u64 shl uint64(index)
  if (gConfigFaultWarned and bit) != 0'u64:
    return true
  gConfigFaultWarned = gConfigFaultWarned or bit
  result = false

proc configRead*(index: int; into: var string; err: var string): int32 =
  ## The whole `config.json` of mod `index`, or the reason there isn't one.
  ##
  ##  * `StatusOk` -- `into` holds a document that parses.
  ##  * `ErrNotFound` -- there is no `config.json`. Ordinary: a mod without one
  ##    runs on its defaults and that is a supported way to ship.
  ##  * `ErrConfigParse` -- the file is there and is not readable JSON. `err`
  ##    names the **file** and the fault, with the offset and what was found
  ##    at it, and never the key -- the key is not what is missing.
  ##
  ## `into` holds the bytes in **both** of the first two cases, including the
  ## broken one. A caller asking for the whole document asked for the file, and
  ## the file exists; handing back the status *and* what was on disk is strictly
  ## more than handing back the status alone, and it is what lets a mod that
  ## parses the document itself -- the mod manager does exactly this -- keep
  ## doing so and produce its own diagnosis. Withholding the bytes would have
  ## turned "your config is unreadable" into "you have no config", which is the
  ## same collapse of two facts into one that this whole change exists to undo.
  ##
  ## The warn line is emitted here rather than left to each host, once per mod,
  ## so that a broken config is visible to whoever is reading the host log even
  ## when the mod swallows the status and carries on. That is the case this is
  ## really for: the mod that falls back to defaults on any failure, which is
  ## most of them.
  into = ""
  err = ""
  let dir = modDirOf(index)
  if dir.len == 0:
    err = "no such mod context"
    return ErrBadArg
  let cfgPath = joinPath(dir, "config.json")
  var text = ""
  if not readTextFile(cfgPath, text):
    err = "no config.json for " & modGuidOf(index)
    return ErrNotFound
  var fault = ""
  if jsonFault(text, fault):
    err = cfgPath & " did not parse: " & fault &
          ". No key in it can be answered -- the key is not what is missing; " &
          "the file is. Every setting this mod believes it read is its own " &
          "default."
    if not configFaultNoted(index):
      warn modGuidOf(index) & ": " & err
    into = text
    return ErrConfigParse
  into = text
  result = StatusOk

proc configWrite*(index: int; key, valueJson: string; err: var string): int32 =
  ## Persist one edit into mod `index`'s own `config.json`, atomically.
  ##
  ## Every early return sets `err` and answers a real status. A write path that
  ## can only say `Ok` is the check that cannot fail; the caller has to be able
  ## to tell a persisted edit from a discarded one, and the F12 panel shows
  ## whatever `err` says.
  err = ""
  let dir = modDirOf(index)
  if dir.len == 0:
    err = "no such mod context"
    return ErrBadArg
  let cfgPath = joinPath(dir, "config.json")
  var text = ""
  var readErr = ""
  let rst = configRead(index, text, readErr)
  if rst != StatusOk:
    # Not created here. `ErrNotFound` means the mod ships no config.json and
    # inventing one gives it a file whose shape we guessed; `ErrConfigParse`
    # means rewriting would destroy whatever is actually in there.
    err = readErr
    return rst
  var merged = ""
  # `configMerge` is in `jsonpath` -- pure, no loader, no file system -- so
  # the merge rules are testable offline without a host. `tests/json`
  # exercises them directly; that is the only way the nested-refusal case
  # gets checked without a running client.
  case configMerge(text, key, valueJson, err, merged)
  of mgOk: discard
  of mgBadArg: return ErrBadArg
  of mgNotFound: return ErrNotFound
  of mgNotObject: return ErrConfigParse
  var fault = ""
  if jsonFault(merged, fault):
    err = "refusing to write " & cfgPath & ": the merged document would not " &
          "parse (" & fault & "). The value was almost certainly not a JSON " &
          "literal."
    return ErrBadArg
  # Temp file in the SAME directory, then an atomic replace. A half-written
  # config.json is a mod that runs on its defaults next start with no error
  # anywhere, which is the failure `configRead`'s docstring is entirely about.
  let tmpPath = cfgPath & ".aowltmp"
  let wr = writeTextFile(tmpPath, merged)
  if not wr.ok:
    err = "could not write " & tmpPath
    return ErrGeneric
  let mv = replaceFileAt(tmpPath, cfgPath)
  if not mv.ok:
    discard removeFileAt(tmpPath)
    err = "could not replace " & cfgPath & " (win32 " & $mv.err & ")"
    return ErrGeneric
  result = StatusOk

proc modVersionOf*(index: int): string =
  if index < 0 or index >= gMods.len:
    return ""
  result = gMods[index].version

proc modFlagsOf*(index: int): uint32 =
  if index < 0 or index >= gMods.len:
    return 0'u32
  result = gMods[index].flags
