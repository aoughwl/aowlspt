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
## `schedule`, events, and the escape hatch -- `resolve` and `call` -- which on
## this side means reaching any type and any method in the game by name.
##
## What it does not get: `db_get`/`db_patch` and `route_register`, which are
## server-side and return `ErrUnsupported`; and `patch`, which needs a detour
## engine this host does not have yet and which also returns `ErrUnsupported`
## rather than installing a hook that half works.

import std/[strutils, syncio]
import aowlspt/il2cpp
import aowlsptinstall/winfs
import modstore
import jsonpath
import invoke

{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_hostboot.h" """.}
{.emit: """#include "aowlspt_detour.h" """.}

# --------------------------------------------------------------- C surface

proc cModulePath(buf: Il2CppPtr; cap: int32): int32 {.
  importc: "aowl_sys_module_path", nodecl.}
proc cNowMs(): uint64 {.importc: "aowl_sys_now_ms", nodecl.}
proc cSleep(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}
proc cThreadId(): uint32 {.importc: "aowl_sys_thread_id", nodecl.}
proc cLoadLibrary(path: cstring): Il2CppPtr {.
  importc: "aowl_sys_load_library", nodecl.}
proc cFreeLibrary(h: Il2CppPtr) {.importc: "aowl_sys_free_library", nodecl.}
proc cGetProc(h: Il2CppPtr; name: cstring): Il2CppPtr {.
  importc: "aowl_sys_get_proc", nodecl.}
proc cLastError(): uint32 {.importc: "aowl_sys_last_error", nodecl.}
proc cIsCodePointer(p: Il2CppPtr): int32 {.
  importc: "aowl_is_code_pointer", nodecl.}

proc cModInfoNew(): Il2CppPtr {.importc: "aowl_modinfo_new", nodecl.}
proc cModInfoFree(p: Il2CppPtr) {.importc: "aowl_modinfo_free", nodecl.}
proc cModInfoAbiVersion(p: Il2CppPtr): uint32 {.
  importc: "aowl_modinfo_abi_version", nodecl.}
proc cModInfoSides(p: Il2CppPtr): uint32 {.importc: "aowl_modinfo_sides", nodecl.}
proc cModInfoFlags(p: Il2CppPtr): uint32 {.importc: "aowl_modinfo_flags", nodecl.}
proc cModInfoGuidPtr(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_modinfo_guid_ptr", nodecl.}
proc cModInfoGuidLen(p: Il2CppPtr): int32 {.importc: "aowl_modinfo_guid_len", nodecl.}
proc cModInfoNamePtr(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_modinfo_name_ptr", nodecl.}
proc cModInfoNameLen(p: Il2CppPtr): int32 {.importc: "aowl_modinfo_name_len", nodecl.}
proc cModInfoAuthorPtr(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_modinfo_author_ptr", nodecl.}
proc cModInfoAuthorLen(p: Il2CppPtr): int32 {.importc: "aowl_modinfo_author_len", nodecl.}
proc cModInfoVersionPtr(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_modinfo_version_ptr", nodecl.}
proc cModInfoVersionLen(p: Il2CppPtr): int32 {.importc: "aowl_modinfo_version_len", nodecl.}

proc cModAbiVersion(fn: Il2CppPtr): uint32 {.importc: "aowl_mod_abi_version", nodecl.}
proc cModDescribe(fn, info: Il2CppPtr): int32 {.importc: "aowl_mod_describe", nodecl.}
proc cModInit(fn, host, outApi: Il2CppPtr): int32 {.importc: "aowl_mod_init", nodecl.}

proc cModApiNew(): Il2CppPtr {.importc: "aowl_modapi_new", nodecl.}
proc cModApiFree(p: Il2CppPtr) {.importc: "aowl_modapi_free", nodecl.}
proc cModApiHasUpdate(p: Il2CppPtr): int32 {.importc: "aowl_modapi_has_update", nodecl.}
proc cModApiOnLoad(p: Il2CppPtr): int32 {.importc: "aowl_modapi_on_load", nodecl.}
proc cModApiOnUpdate(p: Il2CppPtr; elapsed: int64): int32 {.
  importc: "aowl_modapi_on_update", nodecl.}
proc cModApiOnUnload(p: Il2CppPtr): int32 {.importc: "aowl_modapi_on_unload", nodecl.}

proc cHostApiNew(ctx: Il2CppPtr; side: int32;
                 hostName, hostVersion, sptVersion, gameVersion,
                 modDir, dataDir: cstring): Il2CppPtr {.
  importc: "aowl_hostapi_new", nodecl.}
proc cHostApiFree(p: Il2CppPtr) {.importc: "aowl_hostapi_free", nodecl.}
proc cHostApiPtr(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_hostapi_ptr", nodecl.}
proc cAbiVersionExpected(): uint32 {.importc: "aowl_abi_version_expected", nodecl.}
proc cOutCopy(outPtr: Il2CppPtr; outLen: Il2CppPtr; src: Il2CppPtr;
              len: int32): int32 {.importc: "aowl_out_copy", nodecl.}
proc cInvokeCallback(cb, user, payload: Il2CppPtr; len: int32): int32 {.
  importc: "aowl_invoke_callback", nodecl.}
proc cInvokePatch(cb, user, target: Il2CppPtr; tlen: int32): int32 {.
  importc: "aowl_invoke_patch", nodecl.}
proc cByteAt(p: Il2CppPtr; i: uint64): uint8 {.importc: "aowl_byte_at", nodecl.}

proc cHookNew(): Il2CppPtr {.importc: "aowl_hook_new", nodecl.}
proc cHookFree(p: Il2CppPtr) {.importc: "aowl_hook_free", nodecl.}
proc cHookAttach(p, target: Il2CppPtr): int32 {.importc: "aowl_hook_attach", nodecl.}
proc cHookRemove(p: Il2CppPtr): int32 {.importc: "aowl_hook_remove", nodecl.}
proc cHookStolen(p: Il2CppPtr): int32 {.importc: "aowl_hook_stolen", nodecl.}
proc cHookCapacity(): int32 {.importc: "aowl_hook_capacity", nodecl.}

const
  SideClient = 2'i32
  HostName = "aowlspt-host-il2cpp"
  HostVersion = "0.1.0"

  StatusOk = 0'i32
  ErrGeneric = -1'i32
  ErrNotFound = -3'i32
  ErrBadArg = -4'i32
  ErrDecode = -5'i32
  ErrUnsupported = -6'i32
  ErrDisposed = -8'i32

# --------------------------------------------------------------- state

type
  LoadedMod = object
    path: string
    dir: string
    module: Il2CppPtr
    info: Il2CppPtr
    api: Il2CppPtr
    hostBlock: Il2CppPtr
    guid: string
    name: string
    author: string
    version: string
    hasUpdate: bool
    live: bool

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

var gDir = ""
var gLogPath = ""
var gRt = Il2Cpp(handle: cast[Il2CppPtr](0), loaded: false, lastError: 0'i32,
                 missing: @[])
var gDomain: Il2CppPtr = cast[Il2CppPtr](0)
var gReady = false
var gMods: seq[LoadedMod] = @[]
var gPending: seq[Pending] = @[]
var gLastError = ""
var gStartMs = 0'u64
var gHandles: seq[Il2CppPtr] = @[]
var gHandleIsObject: seq[bool] = @[]
## For an object handle, the IL2CPP GC handle keeping it alive; zero for a type
## handle. Parallel to `gHandles` because a mod-facing handle is an index and
## the three must stay in step.
var gHandleGc: seq[uint32] = @[]
var gPatches: seq[Patch] = @[]
var gSubs: seq[Sub] = @[]

# --------------------------------------------------------------- logging

proc logLine(level, msg: string) =
  ## Appended, never buffered. A host that crashes the game is a host whose log
  ## must survive the crash, so each line is opened, written and closed.
  let stamp = $int(cNowMs() - gStartMs)
  let text = "[" & stamp & "ms] " & level & "  " & msg & "\n"
  var f: File
  if open(f, gLogPath, fmAppend):
    try:
      write(f, text)
    finally:
      close(f)

proc info(msg: string) = logLine("info ", msg)
proc warn(msg: string) = logLine("warn ", msg)
proc fail(msg: string) = logLine("error", msg)
proc okLog(msg: string) = logLine("ok   ", msg)

# --------------------------------------------------------------- helpers

proc readBytes(p: Il2CppPtr; len: int32): string =
  result = ""
  if p == nil or len <= 0'i32:
    return
  for i in 0 ..< int(len):
    result.add char(cByteAt(p, uint64(i)))

proc ownDirectory(): string =
  var buf = newSeq[byte](32768)
  let n = cModulePath(cast[Il2CppPtr](addr buf[0]), 32767'i32)
  if n <= 0'i32:
    return ""
  var path = ""
  for i in 0 ..< int(n):
    path.add char(buf[i])
  result = parentOf(path)

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
  if idx < 0 or idx >= gMods.len:
    gLastError = "no such mod context"
    return ErrBadArg
  var text = ""
  if not readTextFile(joinPath(gMods[idx].dir, "config.json"), text):
    gLastError = "no config.json for " & gMods[idx].guid
    return ErrNotFound
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
  result = int64(cNowMs() - gStartMs)

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
  result = @[]
  for i in 0 ..< gHandles.len:
    result.add handleTarget(i)

proc hostHandleRelease(ctx: Il2CppPtr; handle: uint64) {.
    exportc: "aowlspt_nim_handle_release", cdecl.} =
  let idx = int(handle) - 1
  if idx >= 0 and idx < gHandles.len:
    if gHandleIsObject[idx] and gHandleGc[idx] != 0'u32:
      gcHandleFree(gRt, gHandleGc[idx])
      gHandleGc[idx] = 0'u32
    gHandles[idx] = cast[Il2CppPtr](0)
    gHandleIsObject[idx] = false

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
  gHandles.add c
  gHandleIsObject.add false
  gHandleGc.add 0'u32
  let h = uint64(gHandles.len)
  # The out-parameter is a uint64*; write it as eight bytes.
  discard cOutCopy(cast[Il2CppPtr](0), cast[Il2CppPtr](0),
                   cast[Il2CppPtr](0), 0'i32)
  var tmp = h
  copyMem(outHandle, cast[Il2CppPtr](addr tmp), 8)
  result = StatusOk

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
    if idx <= 0 or idx > gHandles.len:
      gLastError = "no such handle: " & typePart
      return ErrNotFound
    # A handle is either a type (from `resolve`) or a live object (from a call
    # that returned one). Both are reachable, and which one it is decides
    # whether the invoke gets an instance.
    let h = handleTarget(idx - 1)
    if gHandleIsObject[idx - 1]:
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
      let text = readField(gRt, cls, instance, fieldName, gHandles,
                           gHandleIsObject, gHandleGc, fieldError)
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

  let text = describeResult(gRt, m, res, gHandles, gHandleIsObject, gHandleGc)
  if text.len == 0:
    return StatusOk
  var t = text
  result = cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(t)),
                    int32(t.len))

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
  var delivered = 0
  for i in 0 ..< gSubs.len:
    if gSubs[i].name != n or gSubs[i].modIndex == from1:
      continue
    var b = body
    let st = cInvokeCallback(gSubs[i].cb, gSubs[i].user,
                             cast[Il2CppPtr](toCString(b)), int32(body.len))
    if st != StatusOk:
      warn "a subscriber to " & n & " returned " & $int(st)
    inc delivered
  if delivered == 0:
    info "event " & n & " (no subscribers)"
  result = StatusOk

proc patchFired(slot: int32) {.exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## Called from the detour thunk, on the game thread, inside the patched
  ## method. Everything here is on that path, so it does the minimum: find the
  ## callback and call it. No logging, no allocation.
  let i = int(slot)
  if i < 0 or i >= gPatches.len:
    return
  if not gPatches[i].live:
    return
  discard cInvokePatch(gPatches[i].cb, gPatches[i].user,
                       cast[Il2CppPtr](addr gPatches[i].targetC[0]),
                       int32(gPatches[i].targetC.len - 1))

proc hostPatch(ctx: Il2CppPtr; target: Il2CppPtr; targetLen: int32;
               kind: int32; cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch", cdecl.} =
  ## Detours a compiled method, which is this side's answer to a Harmony patch.
  ##
  ## The limits are worth stating where a caller will meet them: the callback
  ## takes no arguments and cannot suppress the original. Reading the original
  ## arguments correctly needs a thunk per signature, and a patch that reports
  ## the wrong arguments would be worse than one that reports none.
  let spec = readBytes(target, targetLen)
  if cb == nil:
    gLastError = "patch needs a handler"
    return ErrBadArg
  if not gReady:
    gLastError = "the IL2CPP runtime is not up yet"
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

  if gPatches.len >= int(cHookCapacity()):
    gLastError = "no free patch slots (" & $int(cHookCapacity()) & " in use)"
    return ErrUnsupported

  let hook = cHookNew()
  if hook == nil:
    gLastError = "out of memory"
    return ErrGeneric

  # The slot is claimed before attaching: the thunk can fire the instant the
  # hook lands, and it indexes `gPatches` by that slot.
  var targetBytes = newSeq[byte](spec.len + 1)
  for k in 0 ..< spec.len:
    targetBytes[k] = byte(spec[k])
  targetBytes[spec.len] = 0'u8
  gPatches.add Patch(hook: hook, cb: cb, user: user, target: spec,
                     targetC: targetBytes, live: false)
  let slot = cHookAttach(hook, fn)
  if slot < 0'i32:
    shrink(gPatches, gPatches.len - 1)
    cHookFree(hook)
    case slot
    of -2'i32:
      gLastError = "the prologue of " & spec & " could not be relocated " &
                   "(it holds a relative branch, or an instruction this " &
                   "decoder does not know)"
    of -3'i32:
      gLastError = "no executable memory within reach of " & spec
    of -5'i32:
      gLastError = "no free patch slots"
    else:
      gLastError = "could not patch " & spec & " (code " & $int(slot) & ")"
    return ErrGeneric

  if int(slot) != gPatches.len - 1:
    # The engine hands out slots in order and so does this; if they ever
    # disagree the firing path would call the wrong mod.
    warn "patch slot " & $int(slot) & " does not match index " &
         $(gPatches.len - 1) & "; refusing to arm it"
    discard cHookRemove(hook)
    shrink(gPatches, gPatches.len - 1)
    cHookFree(hook)
    gLastError = "internal patch slot mismatch"
    return ErrGeneric

  gPatches[int(slot)].live = true
  okLog "patched " & spec & " (" & $int(cHookStolen(hook)) & " bytes)"
  result = StatusOk

proc hostEventSubscribe(ctx: Il2CppPtr; name: Il2CppPtr; nameLen: int32;
                        cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_event_subscribe", cdecl.} =
  let n = readBytes(name, nameLen)
  if n.len == 0 or cb == nil:
    gLastError = "a subscription needs a name and a handler"
    return ErrBadArg
  gSubs.add Sub(name: n, cb: cb, user: user, modIndex: int(cast[uint](ctx)))
  okLog "subscribed to " & n
  result = StatusOk

# --------------------------------------------------------------- store

proc guidOf(idx: int): string =
  if idx < 0 or idx >= gMods.len: return ""
  result = gMods[idx].guid

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
  ## Queued for the tick loop rather than run here. The tick loop is the host's
  ## own attached thread, which is not literally Unity's main thread -- that
  ## distinction is documented rather than papered over, because a mod touching
  ## a Unity object still has to be on the real main thread and this host
  ## cannot yet put it there.
  if cb == nil:
    return ErrBadArg
  gPending.add Pending(cb: cb, user: user, dueMs: cNowMs())
  result = StatusOk

proc hostSchedule(ctx: Il2CppPtr; delayMs: int32; cb: Il2CppPtr;
                  user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_schedule", cdecl.} =
  if cb == nil:
    return ErrBadArg
  var d = delayMs
  if d < 0'i32: d = 0'i32
  gPending.add Pending(cb: cb, user: user, dueMs: cNowMs() + uint64(d))
  result = StatusOk

# --------------------------------------------------------------- mods

proc loadMod(path: string): bool =
  ## Loads one mod library and brings it up: version probe, describe, init,
  ## on_load. Each step that fails leaves the mod unloaded rather than
  ## half-loaded, and says which step it was.
  var m = LoadedMod(path: path, dir: parentOf(path),
                    module: cast[Il2CppPtr](0), info: cast[Il2CppPtr](0),
                    api: cast[Il2CppPtr](0), hostBlock: cast[Il2CppPtr](0),
                    guid: "", name: "", author: "", version: "",
                    hasUpdate: false, live: false)

  var p = path
  m.module = cLoadLibrary(toCString(p))
  if m.module == nil:
    fail "could not load " & path & " (error " & $int(cLastError()) & ")"
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

  # A mod that does not claim the client side is skipped rather than run. The
  # same binary ships to the server and the simulator, and running its server
  # half in the game would be worse than not loading it.
  let sides = cModInfoSides(m.info)
  if (sides and (1'u32 shl 2'u32)) == 0'u32:
    info m.name & " does not support the client side; skipping"
    cModInfoFree(m.info)
    cFreeLibrary(m.module)
    return false

  let index = gMods.len
  var modDir = m.dir
  var dataDir = joinPath(m.dir, "data")
  var hostName = HostName
  var hostVersion = HostVersion
  var sptVersion = ""
  var gameVersion = ""
  m.hostBlock = cHostApiNew(cast[Il2CppPtr](uint(index)), SideClient,
                            toCString(hostName), toCString(hostVersion),
                            toCString(sptVersion), toCString(gameVersion),
                            toCString(modDir), toCString(dataDir))
  if m.hostBlock == nil:
    cModInfoFree(m.info)
    cFreeLibrary(m.module)
    return false

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
  gMods.add m

  if cModApiOnLoad(m.api) != StatusOk:
    warn m.name & ": on_load returned an error; it stays loaded but may not work"

  okLog "loaded " & m.name & " (" & m.guid & ") v" & m.version &
        (if m.author.len > 0: " by " & m.author else: "")
  result = true

proc discoverMods(root: string): seq[string] =
  ## `mods/<name>/<name>.dll`, plus any dll directly under `mods/`. Directory
  ## per mod is the layout the deploy path produces and the one that lets a mod
  ## carry its own config and data.
  result = @[]
  if not isDirectory(root):
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(root, files, dirs)
  for f in files:
    if not endsWith(toLowerAscii(f), ".dll"):
      continue
    # Only one level deep: a mod's own dependencies sit beside it and must not
    # be probed as mods.
    var depth = 0
    for ch in f:
      if ch == '\\':
        inc depth
    if depth > 1:
      continue
    result.add joinPath(root, f)

proc removePatches() =
  ## Every detour comes out before the host stops. Leaving one installed means
  ## the game jumps into a DLL that may be gone.
  for i in 0 ..< gPatches.len:
    if gPatches[i].live:
      gPatches[i].live = false
      discard cHookRemove(gPatches[i].hook)
      cHookFree(gPatches[i].hook)

proc unloadMods() =
  for i in 0 ..< gMods.len:
    if not gMods[i].live:
      continue
    discard cModApiOnUnload(gMods[i].api)
    cModApiFree(gMods[i].api)
    cHostApiFree(gMods[i].hostBlock)
    cModInfoFree(gMods[i].info)
    cFreeLibrary(gMods[i].module)
    gMods[i].live = false

# --------------------------------------------------------------- runtime

proc waitForIl2Cpp(timeoutMs: int): bool =
  ## The host is injected before the game has built its runtime, so this polls
  ## rather than assuming. Two things have to be true: the module is present,
  ## and `il2cpp_domain_get` returns a domain -- the module appears well before
  ## the domain does, so checking only for the module would attach to nothing.
  var waited = 0
  var nextNote = 10000
  while waited < timeoutMs:
    if not gRt.loaded:
      gRt = openIl2Cpp("")
    if gRt.loaded:
      let d = domainGet(gRt)
      if d != nil:
        gDomain = d
        return true
    cSleep(100'i32)
    waited = waited + 100
    if waited >= nextNote:
      # Otherwise a slow launch is indistinguishable from a hung host.
      info "still waiting for the runtime (" & $(waited div 1000) & "s)"
      nextNote = nextNote + 10000
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

proc reportRuntime() =
  let gaps = missingEssential(gRt)
  if gaps.len > 0:
    for g in gaps:
      fail "essential IL2CPP entry point missing: " & g
    return
  okLog "IL2CPP runtime bound, all essential entry points present"

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

proc runPending() =
  if gPending.len == 0:
    return
  let now = cNowMs()
  var keep: seq[Pending] = @[]
  for p in gPending:
    if p.dueMs <= now:
      discard cInvokeCallback(p.cb, p.user, cast[Il2CppPtr](0), 0'i32)
    else:
      keep.add p
  gPending = keep

proc hostMain() {.exportc: "aowlspt_nim_host_main", cdecl.} =
  gStartMs = cNowMs()
  gDir = ownDirectory()
  if gDir.len == 0:
    return
  gLogPath = joinPath(gDir, "aowlspt-host.log")

  # A fresh log each launch. The interesting failure is always this run's.
  discard writeTextFile(gLogPath,
    "aowlspt-host-il2cpp " & HostVersion & "\n" &
    "directory " & gDir & "\n" &
    "thread " & $int(cThreadId()) & "\n\n")

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

  let modsDir = joinPath(gDir, "mods")
  let found = discoverMods(modsDir)
  info $found.len & " candidate libraries under " & modsDir
  for path in found:
    discard loadMod(path)

  if gMods.len == 0:
    info "no mods loaded; the host will idle"

  okLog "host running"

  var lastTick = cNowMs()
  while true:
    cSleep(16'i32)
    let now = cNowMs()
    let elapsed = int64(now - lastTick)
    lastTick = now
    runPending()
    for i in 0 ..< gMods.len:
      if gMods[i].live and gMods[i].hasUpdate:
        discard cModApiOnUpdate(gMods[i].api, elapsed)
