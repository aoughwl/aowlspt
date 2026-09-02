## aowlspt — write SPT mods in aowl/nimony and ship them as native binaries.
##
## A mod is a shared library exporting three symbols. You do not write them:
## `exportMod` does, from the handlers you name.
##
## ```nim
## import aowlspt
##
## proc onLoad(): Status =
##   info "hello from a native mod"
##   discard route("/aowlspt/hello", rkStatic,
##     proc (url, body, session: string): string = """{"ok":true}""")
##   Ok
##
## exportMod(
##   guid = "aowl.hello", name = "Hello", author = "you",
##   version = "1.0.0", sptRange = "~4.1.0",
##   sides = {sideServer, sideSim}, onLoad = onLoad)
## ```
##
## Build with `installer\build\aowl.exe build-mod <path>` (and `aowl run <path>`
## to build it and hand it straight to `aowlspt-sim`), which drives nimony
## (`nimony c --app:lib`) through nifler → nimsem → hexer → the C backend →
## gcc/lld, and produces a `.dll` the SPT server host, the BepInEx client host,
## or `aowlspt-sim` will load.
##
## **No exceptions.** nimony replaces them with error-code plumbing, and
## unwinding across a C frame is undefined anyway, so every operation here
## returns a `Status` and writes its result through a `var` parameter. Check it
## or `discard` it deliberately.
##
## Two rules carry over from the C ABI:
##
##  * **Slices are borrowed.** A slice handed to a callback dies when the
##    callback returns. Everything here copies into a string before you see it.
##  * **The host owns the allocator.** Anything handed back to the host is
##    allocated with `host.alloc` — the DLL and the host do not share a heap.

import aowlspt/abi
export abi

# The scheduler table below is written by whichever thread a mod's callbacks
# happen to arrive on, which is never guaranteed to be one. See `claimTick`.
# The same lock also serialises the *reservation* of a registration slot --
# `claimRoute`, `claimEvent`, `claimPatch`, `claimTypedPatch` -- which is a
# registration-rate path and not a firing-rate one; the firing paths take no
# lock, for the reason set out above `RouteCapacity`.
#
# **Its own critical section, not the one `aowlspt/sync` hands the mod.**
# `aowlspt_lock.h` is a `static` one-time-initialised `CRITICAL_SECTION` and
# nimony emits one translation unit per module, so the include below is a
# second, independent lock -- `sync.nim` keeps the mod's, this module keeps the
# library's. That separation is not tidiness:
#
#  * a mod may call `after`, `every`, `onMainThread`, `scheduledSlots` or
#    `stopMainRepeats` from inside its own `withModLock`, and one of the
#    examples does exactly that -- `examples/lesson` samples `scheduledSlots()`
#    inside a guarded `everyMain` firing. On one shared lock that is a
#    *recursive* take, which `sync.nim` documents as unsupported even though
#    Windows would allow it. On two it is not a question.
#  * a mod holding its own lock across something slow would otherwise stall
#    every other thread's timer scheduling, which has nothing to do with it.
#
# There is no lock order to get wrong, because this one is never held across a
# call out: not into the mod's handler (see `tickTrampoline`) and not into the
# host. It is always the innermost.
{.emit: """#include "aowlspt_lock.h" """.}

# Not `inline`, for the reason `sync.nim` gives at length: `{.emit.}` is
# module-scoped, so an inline body copied into an importing mod's translation
# unit would name a function that unit has never seen declared.
proc cTickLock() {.importc: "aowl_lock", nodecl.}
proc cTickUnlock() {.importc: "aowl_unlock", nodecl.}

template withTickLock(body: untyped) =
  ## Runs `body` holding the library's table lock -- the scheduler's, and the
  ## registration tables' reservation. Never wrap a call into mod or host code
  ## in this.
  cTickLock()
  body
  cTickUnlock()

type
  RouteHandler* = proc (url, body, session: string): string
  EventHandler* = proc (payload: string): string
  TickHandler* = proc (payload: string): string
  PatchHandler* = proc (target, args: string): PatchResult

  PatchResult* = object
    ## What a patch handler decided.
    ##
    ## `skipOriginal` means "suppress" on a prefix and "replace what it
    ## returned" on a postfix. One field rather than two because it is one
    ## decision either way -- what the caller ends up with -- and the only thing
    ## that differs is whether the original has run by the time it is made.
    skipOriginal*: bool
    resultJson*: string

func patchContinue*(): PatchResult =
  PatchResult(skipOriginal: false, resultJson: "")

func patchReplace*(json: string): PatchResult =
  PatchResult(skipOriginal: true, resultJson: json)

# ---------------------------------------------------------------------------
# Host handle and handler registries
# ---------------------------------------------------------------------------
#
# **These four tables are reserved to full capacity on first use and never
# grow again**, and unlike the scheduler table above they are read with **no
# lock at all**. Both halves of that are deliberate, and the reasoning is the
# same one the IL2CPP host wrote down for its own `gPatches` (`reservePatchRows`
# in `host/Aowlspt.Host.Il2Cpp/aowlhost.nim`) -- this is the mod side of the
# identical problem.
#
# **The hazard.** A registry index travels to the host as a cookie and comes
# back on a firing, so every one of these tables is indexed by a thread that is
# not the one that wrote it:
#
#  * `routeTrampoline` runs on one of the backend's sixteen request workers.
#  * `eventTrampoline` runs on whichever thread called `emit`, which is any of
#    them.
#  * `patchTrampoline` and `typedPatchTrampoline` run on the **game's** thread,
#    inside a detoured method, thousands of times a second.
#
# And registration is *not* confined to `on_load`, whatever a mod author might
# assume. Two of this repository's own examples register from `on_update`:
# `examples/clientprobe` waits three seconds for EFT's assemblies before it can
# `patch` anything at all, and `examples/lesson` arms nine hooks from `armHooks`
# on the first tick its types resolve. That is not a mod being clever, it is the
# only honest way to hook a type that does not exist yet -- so any rule saying
# "register during `on_load` only" would forbid the one pattern the client side
# actually needs. On top of that a mod may register from a route handler or an
# event handler, which is several workers at once.
#
# Unguarded and growing, that is three distinct failures, and only the last of
# them is loud:
#
#  * **A misdirected registration.** `add` then `toCookie(len - 1)` is a
#    check-then-act. Two threads registering at once both `add`, then both read
#    `len - 1` and both get the *second* index: `/a` is served by `/b`'s handler
#    and `/a`'s handler is unreachable for the session. No crash, no log line, a
#    wrong answer.
#  * **A lost registration.** Two `add`s to one `seq` interleaved lose an
#    element outright, and `gPatches`/`gPatchTargets` are two sequences that are
#    only meaningful in step -- a patch firing then reports the *wrong target
#    name* to its handler.
#  * **A read of freed memory.** A `seq` that grows *moves*. A detour indexing
#    the old buffer while another thread has moved it reads a closure -- a code
#    pointer and an environment pointer, two words that have to come from the
#    same version of the buffer -- out of memory that has been handed back.
#
# **Why not a lock on the read side.** Because it is the one path in this file
# that cannot afford one. The typed patch prefix is 21.8 ns and the postfix
# 23.4 ns end to end (`perfbench`), and an uncontended `EnterCriticalSection`
# /`LeaveCriticalSection` pair is 25-27 ns on this machine -- so guarding the
# firing would cost *more than the whole path*, which is exactly what
# `patchTyped` exists to avoid. The host reached the same conclusion about the
# same number and solved it the same way.
#
# **Why not "register during `on_load` only", enforced.** It is cheap and it is
# wrong: see `clientprobe` and `lesson` above. Refusing a late registration
# would break the client side of this repository, and a rule that the shipped
# examples cannot follow is not a rule.
#
# **What is done instead.** Each table is filled to its capacity once, under
# the same lock the scheduler uses, at the first registration of its kind. From
# then on:
#
#  * the backing buffer never moves, so a reader can never index a freed one;
#  * an index is reserved *and* its slot written inside one critical section,
#    so `len - 1` is never read as an approximation of "the slot I just took";
#  * every unused slot holds a filler handler rather than uninitialised memory,
#    so a cookie that somehow arrives early returns an empty answer instead of
#    calling through a null;
#  * and the read path is unchanged -- a bounds check and an index, no atomics,
#    no barriers, no lock. The measured 21.8/23.4 ns stand.
#
# The publication edge is the lock release at the end of the reserving critical
# section, followed by the call into the host that hands the cookie over. A
# firing cannot observe a slot before the host has been given the cookie for
# it, and the host takes a lock of its own to record that -- so the store to
# the slot is ordered before any load of it by construction, without this file
# needing a barrier of its own.
#
# **The bound is the cost.** It is stated rather than hidden: see
# `RouteCapacity` and friends. The largest mod here registers 95 routes and the
# busiest example arms 22 handlers of all kinds, so the numbers below are an
# order of magnitude of headroom rather than a limit anybody is near -- and a
# registration past the bound is *refused with `ErrGeneric`*, which a mod can
# see, rather than silently corrupting the table, which it cannot.

const
  RouteCapacity* = 1024
    ## The most routes one mod may register. `mods/tarkov` registers 95, which
    ## is the high-water mark in this repository.
  EventCapacity* = 1024
    ## The most event subscriptions one mod may hold.
  PatchCapacity* = 1024
    ## The most JSON patches one mod may install.
  TypedPatchCapacity* = 1024
    ## The most typed patches one mod may install.
    ##
    ## The same number for all four, and generous: `examples/lesson` is the
    ## busiest thing here and arms 22 handlers of every kind put together. Each
    ## table is two pointers a slot, so the whole reservation is under 64 KB of
    ## a mod's own address space -- less than the cost of being wrong about it.

var
  gHost: ptr HostApi = cast[ptr HostApi](0)
  gRoutes: seq[RouteHandler] = @[]
  gRoutesN = 0
    ## How many route slots have been handed out. Everything from here to
    ## `RouteCapacity` holds `noRoute`.
  gEvents: seq[EventHandler] = @[]
  gEventsN = 0
  gTickFree: seq[int] = @[]
    ## Tick slots that have fired and will never be used again, ready to be
    ## handed out. See `claimTick`.
  gTickFreeN = 0
    ## How many entries at the front of `gTickFree` are valid. A count rather
    ## than a shortened sequence because nimony's `seq` has `add` and `len` and
    ## no way to drop the last element.
  gPatches: seq[PatchHandler] = @[]
  gPatchTargets: seq[string] = @[]
    ## The name each patch was registered under, kept so the firing path does
    ## not have to build it again. See `patchTrampoline`.
    ##
    ## Parallel to `gPatches` and only meaningful in step with it, which is why
    ## both are written inside the one critical section that reserved the index
    ## rather than `add`ed one after the other.
  gPatchesN = 0
  gTicks: seq[TickHandler] = @[]
  ## Milliseconds between firings for each entry in `gTicks`, or zero for a
  ## one-shot. Parallel to `gTicks` rather than a field on it because a cookie
  ## is an index and the two must stay in step.
  gTickRepeat: seq[int] = @[]

proc host*(): ptr HostApi {.inline.} = gHost
proc hostReady*(): bool {.inline.} = not isNilPtr(cast[pointer](gHost))

# A registry index travels through the ABI's `user` cookie, biased by one so a
# null cookie is unmistakably "not one of ours" rather than slot zero.
func toCookie(idx: int): pointer {.inline.} = cast[pointer](uint(idx) + 1'u)
func fromCookie(user: pointer): int {.inline.} = int(cast[uint](user)) - 1

# ---------------------------------------------------------------------------
# Slices and buffers
# ---------------------------------------------------------------------------

proc toString*(s: AowlSlice): string =
  ## Copy a borrowed slice into a string.
  result = ""
  if isNilBytes(s.data) or s.len <= 0'i32: return
  let n = int(s.len)
  # beginStore/endStore rather than `addr result[0]`: a nimony string keeps
  # short contents inline in the object, so there is no single "data pointer"
  # to take the address of.
  let dest = beginStore(result, n)
  copyMem(dest, s.data, n)
  endStore(result)

proc slice*(s {.byref.}: string): AowlSlice {.inline.} =
  ## Borrow a string as a slice.
  ##
  ## `{.byref.}` is not an optimisation here, it is correctness: a short string
  ## stores its bytes inline, so a by-value parameter would hand out a pointer
  ## into a copy that dies when this proc returns.
  if s.len == 0: emptySlice()
  else: AowlSlice(data: cast[Bytes](readRawData(s)), len: int32(s.len))

proc allocBuffer*(s {.byref.}: string): AowlBuffer =
  ## Copy `s` into a host-allocated buffer. The host frees it.
  if not hostReady() or s.len == 0: return emptyBuffer()
  let n = int32(s.len)
  let p = gHost.alloc(gHost.ctx, n)
  if isNilPtr(p): return emptyBuffer()
  copyMem(p, readRawData(s), int(n))
  AowlBuffer(data: cast[Bytes](p), len: n)

proc takeBuffer*(b: var AowlBuffer): string =
  ## Copy a host-allocated buffer into a string and free the original. Every
  ## helper that receives an out-buffer routes through here, so a mod cannot
  ## leak host memory by forgetting a free.
  result = ""
  if isNilBytes(b.data) or b.len <= 0'i32: return
  let n = int(b.len)
  let dest = beginStore(result, n)
  copyMem(dest, b.data, n)
  endStore(result)
  if hostReady(): gHost.free(gHost.ctx, cast[pointer](b.data))
  b = emptyBuffer()

proc lastError*(): string =
  ## The host's text for the most recent failure on this thread.
  result = ""
  if not hostReady():
    result = "host not initialised"
    return
  var s = emptySlice()
  gHost.lastError(gHost.ctx, addr s)
  result = s.toString()

# ---------------------------------------------------------------------------
# Host info
# ---------------------------------------------------------------------------

proc infoReady(): bool {.inline.} =
  hostReady() and not isNilPtr(cast[pointer](gHost.info))

proc side*(): Side =
  if not infoReady(): sideSim else: Side(gHost.info.side)

proc hostName*(): string =
  if not infoReady(): "" else: gHost.info.hostName.toString()

proc hostVersion*(): string =
  if not infoReady(): "" else: gHost.info.hostVersion.toString()

proc sptVersion*(): string =
  if not infoReady(): "" else: gHost.info.sptVersion.toString()

proc gameVersion*(): string =
  if not infoReady(): "" else: gHost.info.gameVersion.toString()

proc modDir*(): string =
  if not infoReady(): "" else: gHost.info.modDir.toString()

proc dataDir*(): string =
  if not infoReady(): "" else: gHost.info.dataDir.toString()

proc nowMs*(): int64 =
  if not hostReady(): 0'i64 else: gHost.nowMs(gHost.ctx)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

proc log*(level: LogLevel; message {.byref.}: string) =
  if not hostReady(): return
  gHost.log(gHost.ctx, int32(ord(level)), slice(message))

proc trace*(m {.byref.}: string) = log(llTrace, m)
proc debug*(m {.byref.}: string) = log(llDebug, m)
proc info*(m {.byref.}: string) = log(llInfo, m)
proc success*(m {.byref.}: string) = log(llSuccess, m)
proc warn*(m {.byref.}: string) = log(llWarn, m)
proc error*(m {.byref.}: string) = log(llError, m)

# ---------------------------------------------------------------------------
# Trampolines — the C-facing side of each handler kind
# ---------------------------------------------------------------------------

# A `{.cdecl.}` proc cannot carry a closure environment, so the handler lives in
# a registry and only its index crosses the boundary.

proc routeTrampoline(user: pointer; url, body, session: AowlSlice;
                     outBuf: ptr AowlBuffer): Status {.cdecl.} =
  let idx = fromCookie(user)
  if idx < 0 or idx >= gRoutes.len: return ErrNotFound
  let res = gRoutes[idx](url.toString(), body.toString(), session.toString())
  if not isNilPtr(cast[pointer](outBuf)):
    outBuf[] = allocBuffer(res)
  Ok

proc eventTrampoline(user: pointer; payload: AowlSlice;
                     outBuf: ptr AowlBuffer): Status {.cdecl.} =
  let idx = fromCookie(user)
  if idx < 0 or idx >= gEvents.len: return ErrNotFound
  let res = gEvents[idx](payload.toString())
  if not isNilPtr(cast[pointer](outBuf)) and res.len > 0:
    outBuf[] = allocBuffer(res)
  Ok

proc patchTrampoline(user: pointer; target, args: AowlSlice;
                     outBuf: ptr AowlBuffer): Status {.cdecl.} =
  let idx = fromCookie(user)
  if idx < 0 or idx >= gPatches.len: return ErrNotFound
  # The target name comes from the registration, not from the slice the host
  # hands back. They say the same thing, and this path does not: a detour on a
  # per-frame method fires every frame, and `toString` on that slice built a
  # string per firing for a value that has not changed since the mod asked for
  # it. A `hook` -- the no-arguments form, which discards both -- was paying
  # for two allocations a frame to be told something happened.
  #
  # `args` is still converted, because it genuinely differs per call. For a
  # no-arguments patch the host sends an empty slice and `toString` returns
  # without allocating, so that form is now free.
  let name = (if idx < gPatchTargets.len: gPatchTargets[idx] else: target.toString())
  let res = gPatches[idx](name, args.toString())
  if not isNilPtr(cast[pointer](outBuf)) and res.resultJson.len > 0:
    outBuf[] = allocBuffer(res.resultJson)
  if res.skipOriginal: PatchSkip else: Ok

proc releaseTickLocked(idx: int) =
  ## Gives a fired one-shot's slot back. **The scheduler lock must be held.**
  ##
  ## Without this, `after` and `onMainThread` grew `gTicks` by one entry per
  ## call and never shrank: a mod that queues work onto the main thread every
  ## frame -- which is the documented way to touch Unity from a worker -- leaked
  ## a slot per frame for the length of the session. The cookie is consumed by
  ## the firing, so nothing can arrive on this index again until it is handed
  ## out afresh.
  ##
  ## Split from `releaseTick` so the firing path can decide *and* release in
  ## one critical section: the lock is not reentrant, so a proc that takes it
  ## may not be called from inside a section that already holds it.
  if idx < 0 or idx >= gTicks.len: return
  if idx < gTickRepeat.len:
    gTickRepeat[idx] = 0
  if gTickFreeN < gTickFree.len:
    gTickFree[gTickFreeN] = idx
  else:
    gTickFree.add idx
  inc gTickFreeN

proc releaseTick(idx: int) =
  ## `releaseTickLocked` for a caller that does not already hold the lock.
  withTickLock:
    releaseTickLocked(idx)

proc claimTick(handler: TickHandler; repeatMs: int): int =
  ## A slot for one scheduled callback: a reused one if any has come free.
  ##
  ## **Under the scheduler lock, and not out of an abundance of caution.** A
  ## mod's callbacks arrive on several threads by design -- the backend answers
  ## on a pool of workers, so two route handlers in the same mod run at once;
  ## the client host calls `on_update` on its own thread while a detour fires on
  ## the game's -- and `after`, `every`, `everyMain` and `onMainThread` are
  ## exactly what those handlers call. Unguarded, two of them meeting here is
  ## not a tolerable approximation of a scheduler:
  ##
  ##  * both see `gTickFreeN > 0`, both `dec` it, and both are handed the *same*
  ##    slot. One mod callback then runs twice and another never runs at all --
  ##    a timer that silently stopped, found days later, not a crash.
  ##  * `gTickFreeN` decremented twice past zero indexes `gTickFree` out of
  ##    bounds.
  ##  * two `add`s to one `seq` reallocate underneath each other, so `gTicks`
  ##    and `gTickRepeat` -- parallel, and only meaningful in step -- can end at
  ##    different lengths, and a firing reads a closure out of a buffer that has
  ##    just been freed.
  ##
  ## One scheduling thread against one draining thread was enough to take the
  ## process down. `tests/tickrace.nim` is the reproducer, and it asserts on
  ## which callback ran rather than on whether the process survived.
  result = 0
  withTickLock:
    if gTickFreeN > 0:
      dec gTickFreeN
      result = gTickFree[gTickFreeN]
      gTicks[result] = handler
      gTickRepeat[result] = repeatMs
    else:
      gTicks.add handler
      gTickRepeat.add repeatMs
      result = gTicks.len - 1

proc noTick(payload: string): string =
  ## What a firing holds when it turns out there is nothing in the slot: a
  ## local of a proc type has to be initialised with something.
  result = ""

proc tickTrampoline(user: pointer; payload: AowlSlice;
                    outBuf: ptr AowlBuffer): Status {.cdecl.} =
  let idx = fromCookie(user)

  # The handler is *copied out* under the lock and called outside it, and both
  # halves of that matter. Reading `gTicks[idx]` unguarded races a `claimTick`
  # on another thread reallocating the sequence, and what is read is a closure
  # -- a code pointer and an environment pointer, two words that have to come
  # from the same version of the buffer. Holding the lock across the call
  # instead would be worse: the handler is the mod's own code, it may perfectly
  # well call `after` or `onMainThread`, and this lock is not reentrant.
  var handler: TickHandler = noTick
  var have = false
  withTickLock:
    if idx >= 0 and idx < gTicks.len:
      handler = gTicks[idx]
      have = true
  if not have: return ErrNotFound
  discard handler(payload.toString())
  # A repeating timer re-arms itself with the *same* cookie. Calling `after`
  # again from inside the handler would work and would also add one entry to
  # `gTicks` per firing -- a leak that only shows up in a server left running
  # for a week, which is the worst place to find one.
  #
  # A negative interval is `everyMain`: re-arm onto the *main thread* rather
  # than onto the host's timer, with the same cookie and the same slot. See
  # `everyMain` for why re-arming from inside the firing is safe and why it is
  # a repeat rather than a spin.
  #
  # The marker is read *after* the handler has run, because the handler may
  # have stopped its own chain; the decision and the release are taken in one
  # critical section, because as two a `stopMainRepeats` landing between them
  # frees a slot this firing is about to re-arm onto.
  #
  # The host calls are made outside the lock. A mod holding this across a call
  # into the host is allowed, but the host's queue has a lock of its own and
  # there is no reason to hold two.
  var repeat = 0
  withTickLock:
    if idx >= 0 and idx < gTickRepeat.len:
      repeat = gTickRepeat[idx]
    if repeat == 0 or not hostReady():
      releaseTickLocked(idx)
      repeat = 0
  if repeat == -1:
    if gHost.invokeMain(gHost.ctx, tickTrampoline, user) != Ok:
      # The host refused to queue. Give the slot back rather than leaving a
      # repeat marked live that nothing will ever fire again -- a chain that
      # has silently stopped is worse than one that stopped and freed itself,
      # because `scheduledSlots()` is how a mod notices.
      releaseTick(idx)
  elif repeat == -2:
    # `everyRender`: re-arm onto the render-phase queue. If the host refuses --
    # which it does the moment a raid ends and the render callback goes away --
    # release the slot rather than leave a dead chain marked live.
    if gHost.size < HostApiSizeRev6 or gHost.invokeRender == nil or
       gHost.invokeRender(gHost.ctx, tickTrampoline, user) != Ok:
      releaseTick(idx)
  elif repeat > 0:
    discard gHost.schedule(gHost.ctx, int32(repeat), tickTrampoline, user)
  Ok

# ---------------------------------------------------------------------------
# Reserving a registry slot
# ---------------------------------------------------------------------------
#
# Three of these, one per table, rather than one generic one: nimony has no
# generic over "a `seq` of some proc type" that would let the filler and the
# element type be supplied, and three eight-line procs are cheaper to read than
# the machinery that would remove them.
#
# Each does the same three things in one critical section — fill the table to
# capacity if this is the first registration, take the next index, write the
# slot — and that is the whole fix. See the block above `RouteCapacity` for why
# the alternative (a lock on the firing path) was rejected on a measurement.

proc noRoute(url, body, session: string): string =
  ## What an unclaimed route slot holds. Never reached in a correct host: a
  ## cookie exists only for a slot that has been written. It is here so that
  ## the reserved-but-unused part of the table is *initialised memory holding a
  ## harmless answer* rather than whatever a `seq` grows into.
  result = ""

proc noEvent(payload: string): string =
  result = ""

proc noPatch(target, args: string): PatchResult =
  patchContinue()

proc claimRoute(handler: RouteHandler; outIdx: var int): bool =
  ## Reserves one never-moving route slot and writes the handler into it.
  ## False when the table is full.
  result = false
  outIdx = -1
  withTickLock:
    while gRoutes.len < RouteCapacity: gRoutes.add noRoute
    if gRoutesN < RouteCapacity:
      outIdx = gRoutesN
      gRoutes[gRoutesN] = handler
      inc gRoutesN
      result = true

proc claimEvent(handler: EventHandler; outIdx: var int): bool =
  result = false
  outIdx = -1
  withTickLock:
    while gEvents.len < EventCapacity: gEvents.add noEvent
    if gEventsN < EventCapacity:
      outIdx = gEventsN
      gEvents[gEventsN] = handler
      inc gEventsN
      result = true

proc claimPatch(handler: PatchHandler; target {.byref.}: string;
                outIdx: var int): bool =
  ## The two-table one. `gPatches` and `gPatchTargets` are written under the
  ## same take of the lock, because a firing that read a handler from one and a
  ## name from the other would report the wrong method to the right handler --
  ## which is the failure that looks least like a bug and costs the most to
  ## find.
  result = false
  outIdx = -1
  withTickLock:
    while gPatches.len < PatchCapacity: gPatches.add noPatch
    while gPatchTargets.len < PatchCapacity: gPatchTargets.add ""
    if gPatchesN < PatchCapacity:
      outIdx = gPatchesN
      gPatches[gPatchesN] = handler
      gPatchTargets[gPatchesN] = target
      inc gPatchesN
      result = true

proc parkRoute(idx: int) =
  ## Puts the filler back into a slot whose registration the host refused.
  ##
  ## The index is **not** recycled, here or in the patch cases. A refused
  ## registration is rare, one slot in a thousand is nothing, and recycling
  ## would mean handing a live cookie's index to a second handler if the host
  ## turned out to have recorded the registration after all. Refilling with the
  ## filler is the part worth doing: it makes a stale firing an empty answer
  ## rather than a call into a handler its owner believes was never installed.
  withTickLock:
    if idx >= 0 and idx < gRoutes.len: gRoutes[idx] = noRoute

proc parkEvent(idx: int) =
  withTickLock:
    if idx >= 0 and idx < gEvents.len: gEvents[idx] = noEvent

proc parkPatch(idx: int) =
  withTickLock:
    if idx >= 0 and idx < gPatches.len: gPatches[idx] = noPatch

proc registeredRoutes*(): int =
  ## How many route slots have been handed out, of `RouteCapacity`. A
  ## diagnostic, and the way a mod near the bound finds out before it is.
  withTickLock:
    result = gRoutesN

proc registeredEvents*(): int =
  withTickLock:
    result = gEventsN

proc registeredPatches*(): int =
  withTickLock:
    result = gPatchesN

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc route*(url {.byref.}: string; kind: RouteKind; handler: RouteHandler): Status =
  ## Serve an HTTP route. Server side only; other hosts answer ErrUnsupported.
  ##
  ## Callable from any thread and at any time -- from `on_load`, from
  ## `on_update`, from inside another route's handler or an event's. The table
  ## behind it is reserved once and never moves; see the block above
  ## `RouteCapacity`. `ErrGeneric` means the mod has used all `RouteCapacity`
  ## slots.
  if not hostReady(): return ErrBadArg
  var idx = -1
  if not claimRoute(handler, idx): return ErrGeneric
  result = gHost.routeRegister(gHost.ctx, slice(url), int32(ord(kind)),
                               routeTrampoline, toCookie(idx))
  if result != Ok: parkRoute(idx)

proc on*(event {.byref.}: string; handler: EventHandler): Status =
  ## Subscribe to a host or mod event. Events cross mods, so this is how two
  ## native mods cooperate without either knowing the other exists.
  ##
  ## Callable from any thread and at any time, on the same terms as `route`.
  ## `ErrGeneric` means all `EventCapacity` slots are in use.
  if not hostReady(): return ErrBadArg
  var idx = -1
  if not claimEvent(handler, idx): return ErrGeneric
  result = gHost.eventSubscribe(gHost.ctx, slice(event), eventTrampoline,
                                toCookie(idx))
  if result != Ok: parkEvent(idx)

proc emit*(event {.byref.}: string; payload {.byref.}: string = ""): Status =
  if not hostReady(): return ErrBadArg
  gHost.eventEmit(gHost.ctx, slice(event), slice(payload))

const PatchArgsFlag* = 0x10'i32
  ## OR'd into `kind` to ask the host for the original arguments.
  ##
  ## Opt-in, because decoding them costs a JSON build inside a method the game
  ## may call thousands of times a frame. A patch that only wants to know *that*
  ## something happened should not pay for what it was called with.

proc patch*(target {.byref.}: string; kind: PatchKind; handler: PatchHandler;
            withArgs = false): Status =
  ## Patch a host method named "Namespace.Type::Method".
  ##
  ## With `withArgs`, the handler receives the arguments as a JSON array in the
  ## same shape `call` accepts, and may return `patchReplace(...)` to suppress
  ## the original and hand back a result of the method's declared return type.
  ## Without it, the handler is told the method fired and nothing more, and a
  ## `patchReplace` it returns is refused rather than honoured -- a mod that
  ## believes it is suppressing when it is not would be debugging the game
  ## instead of its own registration.
  ##
  ## With `pkPostfix` the handler runs **after** the original and is given what
  ## it returned, as a `result` member alongside `this` and `args`; a
  ## `patchReplace` there changes the value the caller receives. A postfix
  ## always gets `result`, whether or not it asked for arguments -- it is one
  ## number and the reason the patch exists -- and may replace it in either
  ## case, because unlike a prefix skip there is nothing ambiguous about a
  ## handler that returned a replacement after seeing the original's answer.
  ## Not every method can carry one; see `hookReturn` in `aowlspt/game` and
  ## docs/IL2CPP.md for the two shapes the host refuses.
  ##
  ## Callable from any thread and at any time -- and on the client that is the
  ## normal case rather than the exotic one, because a type that only exists
  ## once the world does cannot be patched from `on_load`. `clientprobe` waits
  ## three seconds and patches from `on_update`; `lesson` arms nine hooks on
  ## the first tick its types resolve. `ErrGeneric` means all `PatchCapacity`
  ## slots are in use.
  if not hostReady(): return ErrBadArg
  var idx = -1
  if not claimPatch(handler, target, idx): return ErrGeneric
  var k = int32(ord(kind))
  if withArgs: k = k or PatchArgsFlag
  result = gHost.patch(gHost.ctx, slice(target), k,
                       patchTrampoline, toCookie(idx))
  if result != Ok: parkPatch(idx)

proc after*(delayMs: int; handler: TickHandler): Status =
  ## Run `handler` once on the host's main thread, `delayMs` from now.
  ##
  ## Callable from any thread, as are `every`, `onMainThread`, `everyMain`,
  ## `scheduledSlots` and `stopMainRepeats`: the table they share is guarded.
  ## That is worth stating because it is the normal case rather than the exotic
  ## one -- a route handler on one of the backend's workers, a detour on the
  ## game's thread and `on_update` on the client host's are three threads a mod
  ## schedules from without choosing to.
  if not hostReady(): return ErrBadArg
  let slot = claimTick(handler, 0)
  gHost.schedule(gHost.ctx, int32(delayMs), tickTrampoline, toCookie(slot))

proc every*(intervalMs: int; handler: TickHandler): Status =
  ## Run `handler` every `intervalMs`, starting one interval from now.
  ##
  ## The interval is between *firings*, not between starts: the next one is
  ## armed after the handler returns, so a handler that takes longer than its
  ## interval falls behind rather than overlapping itself. That is almost always
  ## what a periodic sweep wants, and it is never what a handler that assumes it
  ## runs alone can survive without.
  if not hostReady(): return ErrBadArg
  if intervalMs <= 0: return ErrBadArg
  let slot = claimTick(handler, intervalMs)
  gHost.schedule(gHost.ctx, int32(intervalMs), tickTrampoline,
                 toCookie(slot))

proc scheduledSlots*(): int =
  ## How many callback slots the scheduler is holding, live plus free.
  ##
  ## A diagnostic, and the only way from inside a mod to see the leak this
  ## number exists to disprove: `after` and `onMainThread` used to take a slot
  ## per call and never give it back, so a mod queueing work every frame grew
  ## this without bound. It should settle at roughly the number of callbacks
  ## outstanding at once, not at the number ever scheduled.
  ##
  ## Under the lock: an unguarded `len` can be read while another thread is
  ## midway through growing the sequence, and this number's whole job is to be
  ## trusted by a mod checking for a leak.
  result = 0
  withTickLock:
    result = gTicks.len

proc onMainThread*(handler: TickHandler): Status =
  ## Run `handler` on the host's main thread as soon as possible. Safe from a
  ## worker thread — this is how a mod touches Unity objects.
  if not hostReady(): return ErrBadArg
  let slot = claimTick(handler, 0)
  gHost.invokeMain(gHost.ctx, tickTrampoline, toCookie(slot))

proc everyMain*(handler: TickHandler): Status =
  ## Run `handler` on the **game's** thread, once per drain — which on a host
  ## whose drain is per-frame is once per frame.
  ##
  ## `every` repeats against a **deadline**; `onMainThread` reaches the thread
  ## the host drains on and does not repeat. Per-frame work on the game's
  ## thread needed both, and until now every mod that wanted it wrote the same
  ## chain by hand: a one-shot that queues itself again before it returns.
  ## `mods/perf` has one, with fifty lines of commentary establishing that it
  ## is safe.
  ##
  ## **Not the same as `every(16, ...)`, on two counts.** The IL2CPP client
  ## host happens to drain its timer queue and its main-thread queue together,
  ## so a short `every` does currently land on the game's thread there -- but
  ## the ABI only ever promised the main thread for `invoke_main`, and a host
  ## is free to keep its timers on its own thread; `every` on the backend does.
  ## And a deadline is not a frame: at 144 fps a 16 ms timer fires every third
  ## frame, at 30 fps it fires once per frame and drifts, and neither is "once
  ## per frame" -- which is what a mod sampling frame times or writing a value
  ## the game reads each frame actually needs. This fires once per drain.
  ##
  ## **Why the chain does not spin inside one frame.** The host's `drainDue`
  ## takes the due callbacks out of its queue under a lock and runs them
  ## *outside* it, so a callback queued from inside a firing lands after the
  ## snapshot the current drain is walking. It is therefore picked up by the
  ## next drain and not by this one. That is a property of the host, one line
  ## of it, and it is what makes this a per-frame callback rather than an
  ## infinite loop inside a single frame. Nothing here can enforce it; what this
  ## can do is be the single place that depends on it, instead of every mod
  ## that wants a frame.
  ##
  ## **Why it holds one slot rather than one per frame.** The re-arm reuses the
  ## same cookie and the same `gTicks` slot, exactly as `every` does. The
  ## hand-written chain calls `onMainThread` again per firing, which claims a
  ## slot per firing and gives it back at the end of the same firing — correct,
  ## but it churns the pool and makes `scheduledSlots()` unable to tell a
  ## working chain from a leaking one.
  ##
  ## Refuses on a host with no main thread to reach: the status is the host's
  ## own answer to the first queue attempt, so a server-side mod is told
  ## `ErrUnsupported` rather than left with a handler that never fires.
  ##
  ## Stop it with `stopMainRepeats`.
  if not hostReady(): return ErrBadArg
  let slot = claimTick(handler, -1)
  result = gHost.invokeMain(gHost.ctx, tickTrampoline, toCookie(slot))
  if result != Ok:
    # Nothing will ever fire on this slot, so nothing will ever release it.
    releaseTick(slot)

proc stopMainRepeats*(): int =
  ## Stops every `everyMain` chain this mod started, and says how many.
  ##
  ## The stop takes effect at the next firing: the marker is cleared, so the
  ## firing that is already queued runs one more time and then releases its slot
  ## instead of re-arming. That is deliberate rather than a limitation — the
  ## chain is queued on the game's thread and this is usually called from
  ## another one, so yanking the slot out from under a callback that is about to
  ## run is the one thing that could turn a stop into a crash.
  ##
  ## The walk is under the lock, and not only so the count comes out right: it
  ## reads `gTickRepeat.len` and then indexes it, and another thread inside
  ## `every` can reallocate that sequence between the two.
  result = 0
  withTickLock:
    for i in 0 ..< gTickRepeat.len:
      if gTickRepeat[i] == -1:
        gTickRepeat[i] = 0
        inc result

proc renderReady*(): bool =
  ## Whether this host offers `invokeRender` -- a render-phase main-thread queue
  ## where immediate-mode `UnityEngine.GL` drawing lands. True only on a host
  ## whose `HostApi` reaches revision 6 AND that has actually bound a render
  ## point; a mod should still gate on `call("aowlspt.host::render_thread")` ->
  ## `bound:true` before drawing, because the render callback the host rides is
  ## typically raid-time and is not up in the menu.
  if not hostReady(): return false
  result = gHost.size >= HostApiSizeRev6 and gHost.invokeRender != nil

proc onRenderThread*(handler: TickHandler): Status =
  ## Run `handler` once on Unity's thread DURING rendering -- the point in the
  ## frame where `GL.*` rasterizes. Safe from any thread. `ErrUnsupported` if the
  ## host has no render-phase drain bound.
  if not hostReady(): return ErrBadArg
  if not renderReady(): return ErrUnsupported
  let slot = claimTick(handler, 0)
  result = gHost.invokeRender(gHost.ctx, tickTrampoline, toCookie(slot))
  if result != Ok:
    releaseTick(slot)

proc everyRender*(handler: TickHandler): Status =
  ## Run `handler` on Unity's render-phase thread once per render, re-arming
  ## itself each time -- the `everyMain` of the render phase, for a native ESP
  ## box or a GL HUD that has to be drawn every frame where GL actually paints.
  ##
  ## Same slot-reuse and same next-drain re-arm as `everyMain`; the only
  ## difference is the queue. Refuses with `ErrUnsupported` on a host with no
  ## render drain, and stops itself (releasing its slot) the moment the host
  ## starts refusing the re-arm -- which is what happens when a raid ends and the
  ## render callback goes away. Stop it deliberately with `stopRenderRepeats`.
  if not hostReady(): return ErrBadArg
  if not renderReady(): return ErrUnsupported
  let slot = claimTick(handler, -2)
  result = gHost.invokeRender(gHost.ctx, tickTrampoline, toCookie(slot))
  if result != Ok:
    releaseTick(slot)

proc stopRenderRepeats*(): int =
  ## Stops every `everyRender` chain this mod started, and says how many. Same
  ## next-firing semantics as `stopMainRepeats`, on the render marker.
  result = 0
  withTickLock:
    for i in 0 ..< gTickRepeat.len:
      if gTickRepeat[i] == -2:
        gTickRepeat[i] = 0
        inc result

# ---------------------------------------------------------------------------
# Host services
# ---------------------------------------------------------------------------

proc call*(target {.byref.}: string; argsJson {.byref.}: string;
           outText: var string): Status =
  ## The escape hatch: invoke a host member by name through reflection.
  ## `target` is "Namespace.Type::Member", or "#<handle>::Member" to call on a
  ## handle from `resolve`. Deliberately the slow path — when a call turns out
  ## to be hot, promote it into the ABI rather than looping on reflection.
  outText = ""
  if not hostReady(): return ErrBadArg
  var buf = emptyBuffer()
  result = gHost.call(gHost.ctx, slice(target), slice(argsJson), addr buf)
  if result == Ok: outText = takeBuffer(buf)

proc resolve*(typeName {.byref.}: string; outHandle: var Handle): Status =
  outHandle = 0'u64
  if not hostReady(): return ErrBadArg
  gHost.resolve(gHost.ctx, slice(typeName), addr outHandle)

proc release*(h: Handle) =
  if not hostReady() or h == 0'u64: return
  gHost.handleRelease(gHost.ctx, h)

proc dbGet*(path {.byref.}: string; outText: var string): Status =
  ## Read the loaded SPT database at a dotted path. Server side only.
  outText = ""
  if not hostReady(): return ErrBadArg
  var buf = emptyBuffer()
  result = gHost.dbGet(gHost.ctx, slice(path), addr buf)
  if result == Ok: outText = takeBuffer(buf)

proc dbPatch*(path {.byref.}: string; patchJson {.byref.}: string): Status =
  ## Merge a JSON patch into the database. Merging rather than replacing is what
  ## lets two mods edit sibling fields of the same item without clobbering.
  if not hostReady(): return ErrBadArg
  gHost.dbPatch(gHost.ctx, slice(path), slice(patchJson))

proc configGet*(key {.byref.}: string; outText: var string): Status =
  ## This mod's config. An empty key returns the whole document.
  ##
  ## Three answers, and the third is the one to write code for:
  ##
  ##  * `Ok` -- `outText` holds the value.
  ##  * `ErrNotFound` -- no config file, or it parses and has no such key.
  ##    Ordinary. Use your default.
  ##  * `ErrConfigParse` -- the file is there and is **not readable JSON**, so
  ##    no key in it can be answered and every setting you think you read is a
  ##    default. `lastError()` names the file and the fault.
  ##
  ## Those last two used to be one status, which is how a BOM'd `config.json`
  ## put the mod manager into a session where `activeLists` read as empty, it
  ## resolved nothing, and it wrote a selection naming only itself. Falling back
  ## to defaults is a fine answer to the second; it is the wrong answer to the
  ## third, and it is the *silence* that was the bug -- so on `ErrConfigParse`,
  ## say something at `llError` or refuse to load, but do not carry on quietly.
  outText = ""
  if not hostReady(): return ErrBadArg
  var buf = emptyBuffer()
  result = gHost.configGet(gHost.ctx, slice(key), addr buf)
  # Taken on `ErrConfigParse` too. An empty key on a broken file comes back
  # with the document's bytes beside the status -- so a mod can parse what is
  # actually on disk and say what is wrong with it -- and a buffer the host
  # allocated and nobody took would be a leak on every such call.
  if result == Ok or result == ErrConfigParse: outText = takeBuffer(buf)

proc configSet*(key {.byref.}: string; valueJson {.byref.}: string): Status =
  if not hostReady(): return ErrBadArg
  gHost.configSet(gHost.ctx, slice(key), slice(valueJson))

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------
#
# Revision 2 of the host API, so every one of these checks `size` first. A mod
# built against a newer ABI than the host it lands in must find out here, with
# `ErrUnsupported`, rather than by calling through a null function pointer.

proc hostApiSize*(): int =
  ## What the host says its API struct is. Reported rather than inferred when a
  ## capability is missing, because "unsupported" and "your host is older than
  ## this mod" want different actions from whoever reads the log.
  if not hostReady(): return 0
  result = int(gHost.size)

proc expectedApiSize*(): int = sizeof(HostApi)

proc storeReady*(): bool =
  ## Whether this host implements the revision-2 persistence calls.
  ##
  ## `size` is the only usable test: nimony will not `cast` a proc field to a
  ## pointer to compare it against null, and a host that reports a size has
  ## filled everything up to it -- that is what the size means.
  ##
  ## Tested against the **revision-2 boundary**, not `sizeof(HostApi)`. It used
  ## to be the latter, which was right until the struct grew: revision 3 makes
  ## `sizeof(HostApi)` 208, and this would then have answered false on every
  ## revision-2 host -- turning "your host is older than this mod" into "your
  ## host has no store", on a host that does.
  if not hostReady(): return false
  result = gHost.size >= HostApiSizeRev2

proc storeGet*(key {.byref.}: string; outText: var string): Status =
  ## Read this mod's private stored value. `ErrNotFound` if it was never set.
  outText = ""
  if not storeReady(): return ErrUnsupported
  var buf = emptyBuffer()
  result = gHost.storeGet(gHost.ctx, slice(key), addr buf)
  if result == Ok: outText = takeBuffer(buf)

proc storeSet*(key {.byref.}: string; value {.byref.}: string): Status =
  ## Write this mod's private stored value, durably.
  if not storeReady(): return ErrUnsupported
  gHost.storeSet(gHost.ctx, slice(key), slice(value))

proc storeList*(prefix {.byref.}: string; outJson: var string): Status =
  ## A JSON array of this mod's keys beginning with `prefix`.
  outJson = ""
  if not storeReady(): return ErrUnsupported
  var buf = emptyBuffer()
  result = gHost.storeList(gHost.ctx, slice(prefix), addr buf)
  if result == Ok: outJson = takeBuffer(buf)

# ---------------------------------------------------------------------------
# Live object addresses (revision 3)
# ---------------------------------------------------------------------------
#
# A `Handle` is the safe way to hold a managed object across frames, and it is
# the wrong thing to hold *within* one: everything reached through a handle goes
# via `call`, which is a name lookup, a JSON build, a boxed invoke and a JSON
# parse -- around a microsecond, against ten nanoseconds for a bound call
# (docs/PERF.md). On a hook that fires per entity per frame that difference is
# the whole feature.
#
# `pointerOf` is the bridge. It hands back the address the handle names right
# now, which is what `aowlspt/fast`'s `bindOnObject`, `callFloat` and
# `readFloat` take.

proc livePointersReady*(): bool =
  ## Whether this host can turn a handle into an address.
  ##
  ## False on the server and the backend, and that is not a version gap: they
  ## hand out handles over their own objects and there is no managed address
  ## behind one. The IL2CPP client host reports revision 3 here; a host built
  ## from the same header without a managed heap still reports revision 2,
  ## because `size` says how much of the struct was filled rather than which
  ## header it saw.
  ## Tested against the **revision-3 boundary**, not `sizeof(HostApi)`, for the
  ## reason `storeReady` gives: revision 4 grows `sizeof` to 216, and this would
  ## then answer false on every revision-3 host -- turning "your host is older
  ## than this mod" into "your host has no addresses", on a host that does.
  if not hostReady(): return false
  result = gHost.size >= HostApiSizeRev3

proc pointerOf*(h: Handle; outAddress: var uint64): Status =
  ## The address of the object behind a handle, **right now**.
  ##
  ## Three things about the value, and all three are why this is a call rather
  ## than a field on a handle:
  ##
  ## * It is an address; nothing keeps it alive and nothing keeps it still. Use
  ##   it in the call you got it in. The collector moves objects between frames,
  ##   and a saved address then names whatever moved into that space -- which
  ##   reads as a plausible object rather than as a crash.
  ## * Inside a hook, `this` and every reference argument stop being valid the
  ##   moment the handler returns, because the host reclaims them there. Asking
  ##   afterwards is refused with `ErrDisposed` rather than answered with the
  ##   address it used to have.
  ## * A handle from `resolve` names a type, not an object, and is refused with
  ##   `ErrBadArg`.
  ##
  ## `pinHandle` is the way to keep one, and says what that costs.
  outAddress = 0'u64
  if not livePointersReady(): return ErrUnsupported
  var v = 0'u64
  result = gHost.handlePointer(gHost.ctx, h, addr v)
  if result == Ok: outAddress = v

proc pinHandle*(h: Handle; outPinned: var Handle): Status =
  ## A **pinned** handle over the same object, whose address does not move.
  ##
  ## The one honest way to keep an address across frames: pin the object, take
  ## `pointerOf` on the pinned handle, and use it until you `release` the pin.
  ##
  ## The cost is exactly what it sounds like. The collector may not move that
  ## object, and may not move it **for the rest of the session** unless the mod
  ## releases the pinned handle -- a pinned object in the middle of a generation
  ## is a hole every later collection has to compact around. So: pin the two or
  ## three long-lived things a mod really tracks, the local player or the world,
  ## and nothing that arrives in a hook. For a hook, take the address, use it,
  ## and let it go.
  outPinned = 0'u64
  if not livePointersReady(): return ErrUnsupported
  var v: Handle = 0'u64
  result = gHost.handlePin(gHost.ctx, h, addr v)
  if result == Ok: outPinned = v

# ---------------------------------------------------------------------------
# Typed patch frames (revision 4)
# ---------------------------------------------------------------------------
#
# `patch` describes a firing as JSON. That is the right shape for a hook that
# fires when something happens and the wrong one for a hook that fires per
# entity per frame: measured against the stand-in runtime, an unpatched bound
# call is 3 ns, a postfix that only watches is 418 ns, and a postfix that reads
# the arguments and replaces the result is 2245 ns. The thunk is single-digit
# nanoseconds of that. The rest is the payload -- a host-side string, a GC
# handle per reference argument, a copy into this heap, and a parse.
#
# `patchTyped` is the same detour with none of it. The handler is given a
# borrowed view of the registers the thunk already saved, plus the declared kind
# of every slot, worked out once when the patch was registered. Reading an
# argument is a bounds check, a kind check and a load.
#
# It does not replace `patch`, and a mod should not reach for it by default:
# JSON is self-describing, it survives an argument the host cannot classify, and
# 2 us is nothing on a hook that fires ten times a second. This is for the hook
# that fires forty times a frame.

{.emit: """#include "aowlspt_frame.h" """.}

proc cFrameLive(f: pointer): int32 {.importc: "aowl_frame_live", nodecl.}
proc cFrameSize(f: pointer): int32 {.importc: "aowl_frame_size", nodecl.}
proc cFrameArgc(f: pointer): int32 {.importc: "aowl_frame_argc", nodecl.}
proc cFrameSerial(f: pointer): uint32 {.importc: "aowl_frame_serial", nodecl.}
proc cFrameIsPostfix(f: pointer): int32 {.importc: "aowl_frame_is_postfix", nodecl.}
proc cFrameIsStatic(f: pointer): int32 {.importc: "aowl_frame_is_static", nodecl.}
proc cFrameKind(f: pointer; i: int32): int32 {.importc: "aowl_frame_kind", nodecl.}
proc cFrameRetKind(f: pointer): int32 {.importc: "aowl_frame_ret_kind", nodecl.}
proc cFrameSelf(f: pointer): uint64 {.importc: "aowl_frame_self", nodecl.}
proc cFrameInt(f: pointer; i: int32; ok: pointer): int64 {.
  importc: "aowl_frame_int", nodecl.}
proc cFrameFlt(f: pointer; i: int32; ok: pointer): float {.
  importc: "aowl_frame_flt", nodecl.}
proc cFramePtr(f: pointer; i: int32; ok: pointer): uint64 {.
  importc: "aowl_frame_ptr", nodecl.}
proc cFrameRetInt(f: pointer; ok: pointer): int64 {.
  importc: "aowl_frame_ret_int", nodecl.}
proc cFrameRetFlt(f: pointer; ok: pointer): float {.
  importc: "aowl_frame_ret_flt", nodecl.}
proc cFrameRetPtr(f: pointer; ok: pointer): uint64 {.
  importc: "aowl_frame_ret_ptr", nodecl.}
proc cFrameSetRetInt(f: pointer; v: int64): int32 {.
  importc: "aowl_frame_set_ret_int", nodecl.}
proc cFrameSetRetFlt(f: pointer; v: float): int32 {.
  importc: "aowl_frame_set_ret_flt", nodecl.}
proc cFrameSetRetPtr(f: pointer; v: uint64): int32 {.
  importc: "aowl_frame_set_ret_ptr", nodecl.}
proc cFrameSetRetVoid(f: pointer): int32 {.
  importc: "aowl_frame_set_ret_void", nodecl.}
proc cFrameWhy(): int32 {.importc: "aowl_frame_why", nodecl.}
proc cFrameWhyText(why: int32): cstring {.importc: "aowl_frame_why_text", nodecl.}
proc cFrameSizeof(): int32 {.importc: "aowl_frame_sizeof", nodecl.}

# None of the accessors below is `{.inline.}`, and that is not an oversight.
#
# `{.emit.}` is scoped to this module's translation unit, so an inline body is
# copied into the *importing* module's C file -- where the header is not, and
# where every `aowl_frame_*` call is then an implicit declaration the C compiler
# refuses. `aowlspt/fast` hit exactly this with `perfCounter` and solved it the
# same way: the wrapper lives in the module that has the header, and an importer
# calls the wrapper. The cost is one ordinary call per read, which is a couple of
# nanoseconds against the 600-plus this path exists to remove.

type
  PatchFrame* = object
    ## A borrowed view of one firing. **Do not store it.**
    ##
    ## An object wrapping the pointer rather than a bare `pointer`, so that a
    ## frame cannot be passed where some other pointer was wanted. It is one
    ## machine word either way.
    ##
    ## The lifetime is enforced, not requested. The host clears the frame the
    ## moment the handler returns, and every accessor below then refuses and
    ## records why. A mod that stored one and read it next frame gets zeroes and
    ## `frameWhyText()` naming exactly that mistake, rather than the previous
    ## firing's registers -- which is what a stack-allocated frame would have
    ## handed it, plausibly and silently.
    p*: pointer

  TypedResult* = object
    ## What a typed handler decided. One field, because it is one decision:
    ## what the caller ends up with. `replace` means "suppress the original" on
    ## a prefix and "hand back what I wrote" on a postfix.
    replace*: bool

  TypedPatchHandler* = proc (frame: PatchFrame): TypedResult

func frameContinue*(): TypedResult = TypedResult(replace: false)

func frameReplace*(): TypedResult = TypedResult(replace: true)
  ## Say this only after a `setResult*` returned true. A `replace` with nothing
  ## written suppresses the original and hands the caller whatever was left in
  ## the return register, which is the worst outcome available here -- so the
  ## setters answer whether they wrote, and this is the second half of that
  ## sentence rather than a substitute for it.

proc frameLive*(f: PatchFrame): bool = cFrameLive(f.p) != 0'i32
  ## Whether this frame's handler is still running. False afterwards, which is
  ## the whole point: see `PatchFrame`.

proc frameSize*(f: PatchFrame): int = int(cFrameSize(f.p))
  ## What the host says the frame struct is, for a mod built against a newer
  ## revision than the host it landed in. Same rule as `HostApi.size`.

proc expectedFrameSize*(): int = int(cFrameSizeof())

proc argCount*(f: PatchFrame): int = int(cFrameArgc(f.p))
  ## Declared parameters. Every one has an entry in `kindOf`, including the
  ## ones past the fourth register position -- those report `akStack`, so that
  ## argument *n* is always declared parameter *n* whatever the method's shape.

proc frameSerial*(f: PatchFrame): uint32 = cFrameSerial(f.p)
  ## Which firing this is. Only useful for a log line; it is not a lifetime
  ## check, because a stored frame reads the *current* serial rather than the
  ## one it was armed with.

proc framePostfix*(f: PatchFrame): bool = cFrameIsPostfix(f.p) != 0'i32
proc frameStatic*(f: PatchFrame): bool = cFrameIsStatic(f.p) != 0'i32

proc kindOf*(f: PatchFrame; i: int): ArgKind =
  ## The declared kind of argument `i`, computed once at registration.
  ##
  ## `akNone` for an index the method does not have -- and for a dead frame,
  ## so a handler that branches on the kind is safe without a separate liveness
  ## test. `frameWhy()` tells the two apart.
  ArgKind(cFrameKind(f.p, int32(i)))

proc retKindOf*(f: PatchFrame): ArgKind =
  ArgKind(cFrameRetKind(f.p))

proc selfPointer*(f: PatchFrame): uint64 = cFrameSelf(f.p)
  ## `this`, as an address, or 0 for a static method.
  ##
  ## This is what `thisPointer(payload)` costs a JSON build, a GC handle and a
  ## `handle_pointer` round trip to produce. Here it is the register the method
  ## was entered with. Same rule as always: it is an address, the collector
  ## moves objects, use it inside the handler.

proc argInt*(f: PatchFrame; i: int; ok: var bool): int64 =
  ## An integer, bool, char or enum argument. `ok` is false when the index or
  ## the declared kind does not match, rather than the value being zero --
  ## because zero is a perfectly good argument.
  var flag = 0'i32
  result = cFrameInt(f.p, int32(i), addr flag)
  ok = flag != 0'i32

proc argFloat*(f: PatchFrame; i: int; ok: var bool): float =
  ## A `System.Single` or `System.Double` argument, as a float.
  ##
  ## Which of the two it is comes from the declared kind, not from the caller:
  ## a `Single` occupies the low 32 bits of its register and the rest is
  ## whatever was there, so reading one as a `Double` gives a number unrelated
  ## to the argument. That is exactly the failure the kind table removes.
  var flag = 0'i32
  result = cFrameFlt(f.p, int32(i), addr flag)
  ok = flag != 0'i32

proc argPointer*(f: PatchFrame; i: int; ok: var bool): uint64 =
  ## A reference argument, as an address -- ready for `bindOnObject`,
  ## `readFloat` and the rest of `aowlspt/fast`.
  ##
  ## No GC handle is taken out for it, which is the largest single saving on
  ## this path: the JSON form registers one per reference and reclaims it when
  ## the handler returns, so a hook on a per-bot method churns a GC handle per
  ## bot per frame. Nothing keeps this object alive; it is alive because the
  ## game is in the middle of calling a method on it.
  var flag = 0'i32
  result = cFramePtr(f.p, int32(i), addr flag)
  ok = flag != 0'i32

proc resultInt*(f: PatchFrame; ok: var bool): int64 =
  ## What the original returned, on a **postfix** frame. Refused on a prefix
  ## one: the original has not run, and scaling a number that does not exist
  ## yet is worse than not scaling one.
  var flag = 0'i32
  result = cFrameRetInt(f.p, addr flag)
  ok = flag != 0'i32

proc resultFloat*(f: PatchFrame; ok: var bool): float =
  var flag = 0'i32
  result = cFrameRetFlt(f.p, addr flag)
  ok = flag != 0'i32

proc resultPointer*(f: PatchFrame; ok: var bool): uint64 =
  var flag = 0'i32
  result = cFrameRetPtr(f.p, addr flag)
  ok = flag != 0'i32

proc setResultInt*(f: PatchFrame; v: int64): bool =
  ## Write the value the caller gets. True when it was written; false when the
  ## declared return type is not an integer one, or the frame has expired.
  cFrameSetRetInt(f.p, v) != 0'i32

proc setResultFloat*(f: PatchFrame; v: float): bool =
  cFrameSetRetFlt(f.p, v) != 0'i32

proc setResultPointer*(f: PatchFrame; v: uint64): bool =
  cFrameSetRetPtr(f.p, v) != 0'i32

proc setResultVoid*(f: PatchFrame): bool =
  ## Suppressing a method that returns nothing. There is no value to write, and
  ## saying so is what tells "I mean to suppress this" from "I forgot".
  cFrameSetRetVoid(f.p) != 0'i32

proc frameWhy*(): int = int(cFrameWhy())
  ## Why the last frame accessor refused, as one of the `AOWL_FRAME_*` codes.

proc frameWhyText*(): string =
  ## The same, as the sentence to put in a log. The text lives in
  ## `abi/aowlspt_frame.h` rather than being fetched from the host, because the
  ## host is what this path exists not to call -- and because the most important
  ## of these describes a mistake the host cannot see: a frame read after its
  ## handler returned.
  result = ""
  let p = cFrameWhyText(cFrameWhy())
  if isNilPtr(cast[pointer](p)): return
  var i = 0
  while p[i] != '\0':
    result.add p[i]
    inc i

var gTypedPatches: seq[TypedPatchHandler] = @[]
var gTypedPatchesN = 0

proc noTypedPatch(frame: PatchFrame): TypedResult =
  ## What an unclaimed typed slot holds. See `noRoute`.
  frameContinue()

proc claimTypedPatch(handler: TypedPatchHandler; outIdx: var int): bool =
  ## The same reservation as `claimRoute`, and the one that matters most: this
  ## table is indexed by `typedPatchTrampoline` on the **game's** thread, which
  ## is the 21.8 ns path. Reserved once, never grown, read with no lock.
  result = false
  outIdx = -1
  withTickLock:
    while gTypedPatches.len < TypedPatchCapacity:
      gTypedPatches.add noTypedPatch
    if gTypedPatchesN < TypedPatchCapacity:
      outIdx = gTypedPatchesN
      gTypedPatches[gTypedPatchesN] = handler
      inc gTypedPatchesN
      result = true

proc parkTypedPatch(idx: int) =
  withTickLock:
    if idx >= 0 and idx < gTypedPatches.len:
      gTypedPatches[idx] = noTypedPatch

proc registeredTypedPatches*(): int =
  withTickLock:
    result = gTypedPatchesN

proc typedPatchTrampoline(user: pointer; frame: pointer): Status {.cdecl.} =
  ## The whole mod-side firing path.
  ##
  ## Nothing here builds a string, copies a slice or touches the allocator. The
  ## JSON trampoline above cannot say that -- it converts `args`, which is one
  ## allocation per firing -- and that difference is most of what this ABI
  ## revision is for.
  let idx = fromCookie(user)
  if idx < 0 or idx >= gTypedPatches.len: return ErrNotFound
  let res = gTypedPatches[idx](PatchFrame(p: frame))
  if res.replace: PatchSkip else: Ok

proc typedPatchesReady*(): bool =
  ## Whether this host implements the revision-4 typed patch.
  ##
  ## False on the server and the backend, which have no detour engine, and
  ## false on a client host whose engine came up refusing -- `size` says how
  ## much of the struct was filled, not which header the host was built from.
  if not hostReady(): return false
  result = gHost.size >= HostApiSizeRev4

proc patchTyped*(target {.byref.}: string; kind: PatchKind;
                 handler: TypedPatchHandler): Status =
  ## Patch a host method and be handed its registers rather than a description
  ## of them.
  ##
  ## The handler gets a `PatchFrame`: `argCount`, `kindOf(i)`, `argInt`,
  ## `argFloat`, `argPointer`, `selfPointer`, and on a postfix `resultFloat`
  ## and friends. Return `frameReplace()` after a `setResult*` to suppress the
  ## original (a prefix) or to change what the caller receives (a postfix);
  ## `frameContinue()` otherwise.
  ##
  ## There is no `withArgs`. The arguments are in the frame either way, because
  ## pointing at a register costs nothing and the flag on `patch` exists only to
  ## avoid a cost that does not arise here. For the same reason a typed prefix
  ## may always suppress: `patch`'s rule that a prefix which never asked for
  ## arguments may not skip is there to catch a misregistration, and there is no
  ## such misregistration to make.
  ##
  ## The same two method shapes are refused for a postfix as on `patch` -- a
  ## value-type return wider than a register, and a compiled call needing more
  ## than four register slots. Check the status and read `lastError()`.
  ##
  ## Callable from any thread and at any time, on the same terms as `patch`.
  ## `ErrGeneric` means all `TypedPatchCapacity` slots are in use.
  if not typedPatchesReady(): return ErrUnsupported
  var idx = -1
  if not claimTypedPatch(handler, idx): return ErrGeneric
  result = gHost.patchTyped(gHost.ctx, slice(target), int32(ord(kind)),
                            typedPatchTrampoline, toCookie(idx))
  # Parked, **not** shrunk. `shrink(gTypedPatches, len - 1)` used to run here,
  # and it removed whichever entry happened to be last -- which under two
  # threads registering at once is the *other* thread's freshly installed
  # handler, silently unregistered a moment after it was told it was armed.
  if result != Ok: parkTypedPatch(idx)

# ---------------------------------------------------------------------------
# Server-pushed notifications (revision 5)
# ---------------------------------------------------------------------------

proc notifyReady*(): bool =
  ## Whether this host can push a notification to a session.
  ##
  ## True on `aowlspt-backend`, which holds the game's notifier websocket, and
  ## false everywhere else -- there is no such connection inside the game
  ## process and none in the simulator. Tested against the **revision-5
  ## boundary** for the reason `storeReady` gives about every boundary here.
  if not hostReady(): return false
  result = gHost.size >= HostApiSizeRev5

proc notifyPush*(session {.byref.}: string;
                 payload {.byref.}: string): Status =
  ## Push one notification to one session, over whatever the host has that
  ## reaches that player.
  ##
  ## `payload` is the JSON event the client dispatches on -- the same shape the
  ## poll would have handed back. A mod does not learn anything about sockets
  ## from this call, which is the point of it being this small.
  ##
  ## **`ErrNotFound` is a normal answer**, not a failure: it means that session
  ## has no connection open, which is true of a client that has not upgraded,
  ## has not logged in, or has just lost its socket. Fall back to whatever you
  ## did before a push existed. A host that answered `Ok` for a notification it
  ## dropped would be telling you the player has been informed.
  if not notifyReady(): return ErrUnsupported
  if session.len == 0 or payload.len == 0: return ErrBadArg
  result = gHost.notifyPush(gHost.ctx, slice(session), slice(payload))

# ---------------------------------------------------------------------------
# The exported entry points
# ---------------------------------------------------------------------------

# Lifecycle hooks a mod may leave unset. `exportMod` wires whichever were named
# and leaves the rest pointing here, so the host never sees a null it has to
# special-case.

proc noopLoad(): Status = Ok
proc noopUpdate(elapsedMs: int64): Status = Ok
proc noopUnload(): Status = Ok
proc noopStateSave(): string = ""
proc noopStateLoad(state: string): Status = Ok

# Declared one per statement rather than in a single `var` block: nimony does
# not accept a proc-typed entry with an initialiser inside a grouped block, and
# a block that fails to parse takes every later declaration in it down too.
var gOnLoad: proc (): Status = noopLoad
var gOnUpdate: proc (elapsedMs: int64): Status = noopUpdate
var gOnUnload: proc (): Status = noopUnload
var gStateSave: proc (): string = noopStateSave
var gStateLoad: proc (state: string): Status = noopStateLoad

# Kept alive for the library's lifetime: the ModInfo handed to the host points
# into these strings, and the host reads them after `describe` returns.
var gGuid: string = ""
var gName: string = ""
var gAuthor: string = ""
var gVersion: string = ""
var gSptRange: string = ""
var gSides: uint32 = 0'u32
var gFlags: uint32 = 0'u32

proc modGuid*(): string =
  ## This mod's own GUID, as passed to `exportMod`. Set by `registerMod`
  ## before `onLoad` runs (the host calls `describe` first), so it is safe
  ## to call from `onLoad` onward. Empty before that.
  gGuid

proc modName*(): string =
  ## This mod's own display name, as passed to `exportMod`.
  gName

proc modVersion*(): string =
  ## This mod's own version string, as passed to `exportMod`. Same lifetime
  ## rule as `modGuid`/`modName`: filled in by `registerMod` before `onLoad`,
  ## empty before that.
  ##
  ## Added for the settings index (`aowlspt/settings`'s `SettingsIndexAnnounce`
  ## carries it), which had no way to say WHICH version of a mod a page belongs
  ## to -- `mods/manager` knows, but a settings consumer would have had to
  ## correlate two unrelated routes by guid to find out.
  gVersion

var gLoadHooks: seq[proc()] = @[]

proc addLoadHook*(h: proc()) =
  ## Register something to run just BEFORE the mod's `onLoad`.
  ##
  ## `aowlspt/reactive` uses this to perform the FIRST read of every binding.
  ## That read cannot happen in the binding constructor: the ergonomic the
  ## module is for is declaring bindings at module scope (`let x =
  ## reactiveFloat(...)`), and module init runs before the host API is wired --
  ## calling `setting()` there is an ACCESS VIOLATION, measured, with the
  ## backend dying on load.
  ##
  ## Running the fill here instead means a module-scope binding is safe AND its
  ## `.value` is already correct by the time the mod's own `onLoad` body runs.
  gLoadHooks.add h

proc modOnLoad(self: pointer): Status {.cdecl.} =
  for h in gLoadHooks:
    h()
  gOnLoad()
var gUpdateHooks: seq[proc(elapsedMs: int64)] = @[]

proc addUpdateHook*(h: proc(elapsedMs: int64)) =
  ## Register something to run on every update tick, BEFORE the mod's own
  ## `onUpdate`.
  ##
  ## This exists so a library layer can be automatic without the mod wiring it
  ## up. `aowlspt/reactive` registers its settings pump here at module init, so
  ## merely importing it makes bindings self-refreshing -- there is no "call the
  ## tick" step to forget, which is the entire point of that module.
  ##
  ## The library cannot simply import `reactive` and call it directly:
  ## `aowlspt/server` (where `setting` lives, and which `reactive` needs)
  ## imports THIS module, so a direct call would be an import cycle. Inverting
  ## it -- the dependent registers itself here -- is what breaks that.
  ##
  ## Hooks run FIRST, so a mod's `onUpdate` always sees values that are already
  ## current for this tick rather than one tick stale.
  gUpdateHooks.add h

proc modOnUpdate(self: pointer; elapsedMs: int64): Status {.cdecl.} =
  for h in gUpdateHooks:
    h(elapsedMs)
  gOnUpdate(elapsedMs)
proc modOnUnload(self: pointer): Status {.cdecl.} = gOnUnload()

proc modStateSave(self: pointer; outBuf: ptr AowlBuffer): Status {.cdecl.} =
  let s = gStateSave()
  if not isNilPtr(cast[pointer](outBuf)) and s.len > 0:
    outBuf[] = allocBuffer(s)
  Ok

proc modStateLoad(self: pointer; state: AowlSlice): Status {.cdecl.} =
  gStateLoad(state.toString())

proc registerMod*(guid, name, author, version, sptRange: string;
                  sides: set[Side]; flags: ModFlags) =
  ## Called by `exportMod`; not usually called directly.
  gGuid = guid
  gName = name
  gAuthor = author
  gVersion = version
  gSptRange = sptRange
  gSides = 0'u32
  for s in sides:
    gSides = gSides or sideBit(s)
  gFlags = flagBits(flags)

proc fillModInfo*(outInfo: ptr ModInfo): Status =
  if isNilPtr(cast[pointer](outInfo)): return ErrBadArg
  outInfo.size = int32(sizeof(ModInfo))
  outInfo.abiVersion = AbiVersion
  outInfo.abiRevision = AbiRevision
  outInfo.guid = slice(gGuid)
  outInfo.name = slice(gName)
  outInfo.author = slice(gAuthor)
  outInfo.version = slice(gVersion)
  outInfo.sptRange = slice(gSptRange)
  outInfo.sides = gSides
  outInfo.flags = gFlags
  Ok

proc bindHost*(hostApi: ptr HostApi; outApi: ptr ModApi): Status =
  if isNilPtr(cast[pointer](hostApi)) or isNilPtr(cast[pointer](outApi)):
    return ErrBadArg
  if isNilPtr(cast[pointer](hostApi.info)) or hostApi.info.abiVersion != AbiVersion:
    return ErrAbi
  gHost = hostApi
  outApi.size = int32(sizeof(ModApi))
  outApi.self = cast[pointer](0)   # module-level state; no per-instance pointer
  outApi.onLoad = modOnLoad
  outApi.onUpdate = modOnUpdate
  outApi.onUnload = modOnUnload
  outApi.stateSave = modStateSave
  outApi.stateLoad = modStateLoad
  Ok

proc setOnLoad*(p: proc (): Status) = gOnLoad = p
proc setOnUpdate*(p: proc (elapsedMs: int64): Status) = gOnUpdate = p
proc setOnUnload*(p: proc (): Status) = gOnUnload = p
proc setStateSave*(p: proc (): string) = gStateSave = p
proc setStateLoad*(p: proc (state: string): Status) = gStateLoad = p

template exportMod*(guid, name, author, version, sptRange: string;
                    sides: set[Side];
                    onLoad: proc (): Status = noopLoad;
                    onUpdate: proc (elapsedMs: int64): Status = noopUpdate;
                    onUnload: proc (): Status = noopUnload;
                    stateSave: proc (): string = noopStateSave;
                    stateLoad: proc (state: string): Status = noopStateLoad;
                    flags: ModFlags = {}) =
  ## Emit the three symbols the host looks up. Put this last in your module —
  ## the handlers have to be declared before they are named here.
  ##
  ## Unsupplied hooks default to no-ops rather than to nil, so the host never
  ## has a null function pointer to guard against.
  ##
  ## A mod that supplies `stateSave`/`stateLoad` should also pass
  ## `flags = {mfHotReloadable}`: the host only attempts a live reload for mods
  ## that claim it, and silently losing state on reload is worse than being told
  ## to restart.

  proc aowlspt_abi_version(): uint32 {.exportc, cdecl.} =
    AbiVersion

  proc aowlspt_describe(outInfo: ptr ModInfo): Status {.exportc, cdecl.} =
    registerMod(guid, name, author, version, sptRange, sides, flags)
    fillModInfo(outInfo)

  proc aowlspt_init(hostApi: ptr HostApi; outApi: ptr ModApi): Status {.exportc, cdecl.} =
    # `describe` always runs first in a well-behaved host, but a test harness
    # may skip it; registering again is cheap and keeps the metadata right.
    registerMod(guid, name, author, version, sptRange, sides, flags)
    setOnLoad(onLoad)
    setOnUpdate(onUpdate)
    setOnUnload(onUnload)
    setStateSave(stateSave)
    setStateLoad(stateLoad)
    bindHost(hostApi, outApi)
