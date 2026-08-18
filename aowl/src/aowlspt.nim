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
## Build with `tools/aowlspt-build.ps1`, which drives nimony
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

type
  RouteHandler* = proc (url, body, session: string): string
  EventHandler* = proc (payload: string): string
  TickHandler* = proc (payload: string): string
  PatchHandler* = proc (target, args: string): PatchResult

  PatchResult* = object
    ## `skipOriginal` is only meaningful for a prefix patch.
    skipOriginal*: bool
    resultJson*: string

func patchContinue*(): PatchResult =
  PatchResult(skipOriginal: false, resultJson: "")

func patchReplace*(json: string): PatchResult =
  PatchResult(skipOriginal: true, resultJson: json)

# ---------------------------------------------------------------------------
# Host handle and handler registries
# ---------------------------------------------------------------------------

var
  gHost: ptr HostApi = cast[ptr HostApi](0)
  gRoutes: seq[RouteHandler] = @[]
  gEvents: seq[EventHandler] = @[]
  gPatches: seq[PatchHandler] = @[]
  gTicks: seq[TickHandler] = @[]

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
  let res = gPatches[idx](target.toString(), args.toString())
  if not isNilPtr(cast[pointer](outBuf)) and res.resultJson.len > 0:
    outBuf[] = allocBuffer(res.resultJson)
  if res.skipOriginal: PatchSkip else: Ok

proc tickTrampoline(user: pointer; payload: AowlSlice;
                    outBuf: ptr AowlBuffer): Status {.cdecl.} =
  let idx = fromCookie(user)
  if idx < 0 or idx >= gTicks.len: return ErrNotFound
  discard gTicks[idx](payload.toString())
  Ok

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc route*(url {.byref.}: string; kind: RouteKind; handler: RouteHandler): Status =
  ## Serve an HTTP route. Server side only; other hosts answer ErrUnsupported.
  if not hostReady(): return ErrBadArg
  gRoutes.add handler
  gHost.routeRegister(gHost.ctx, slice(url), int32(ord(kind)),
                      routeTrampoline, toCookie(gRoutes.len - 1))

proc on*(event {.byref.}: string; handler: EventHandler): Status =
  ## Subscribe to a host or mod event. Events cross mods, so this is how two
  ## native mods cooperate without either knowing the other exists.
  if not hostReady(): return ErrBadArg
  gEvents.add handler
  gHost.eventSubscribe(gHost.ctx, slice(event), eventTrampoline,
                       toCookie(gEvents.len - 1))

proc emit*(event {.byref.}: string; payload {.byref.}: string = ""): Status =
  if not hostReady(): return ErrBadArg
  gHost.eventEmit(gHost.ctx, slice(event), slice(payload))

proc patch*(target {.byref.}: string; kind: PatchKind; handler: PatchHandler): Status =
  ## Harmony-patch a host method named "Namespace.Type::Method".
  if not hostReady(): return ErrBadArg
  gPatches.add handler
  gHost.patch(gHost.ctx, slice(target), int32(ord(kind)),
              patchTrampoline, toCookie(gPatches.len - 1))

proc after*(delayMs: int; handler: TickHandler): Status =
  ## Run `handler` once on the host's main thread, `delayMs` from now.
  if not hostReady(): return ErrBadArg
  gTicks.add handler
  gHost.schedule(gHost.ctx, int32(delayMs), tickTrampoline, toCookie(gTicks.len - 1))

proc onMainThread*(handler: TickHandler): Status =
  ## Run `handler` on the host's main thread as soon as possible. Safe from a
  ## worker thread — this is how a mod touches Unity objects.
  if not hostReady(): return ErrBadArg
  gTicks.add handler
  gHost.invokeMain(gHost.ctx, tickTrampoline, toCookie(gTicks.len - 1))

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
  outText = ""
  if not hostReady(): return ErrBadArg
  var buf = emptyBuffer()
  result = gHost.configGet(gHost.ctx, slice(key), addr buf)
  if result == Ok: outText = takeBuffer(buf)

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
  ## `size` is the only usable test: nimony will not `cast` a proc field to a
  ## pointer to compare it against null, and a host that reports the full struct
  ## size has filled every field in it -- that is what the size means.
  if not hostReady(): return false
  result = gHost.size >= int32(sizeof(HostApi))

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

proc modOnLoad(self: pointer): Status {.cdecl.} = gOnLoad()
proc modOnUpdate(self: pointer; elapsedMs: int64): Status {.cdecl.} = gOnUpdate(elapsedMs)
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
