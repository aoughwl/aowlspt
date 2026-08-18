## Loading and running aowlspt mods — shared by every nimony host.
##
## The client host (inside the game) and the backend server have almost nothing
## in common: one drives IL2CPP, the other serves HTTP. But a *mod* must load
## and behave identically on both, and that is the part this module owns —
## discovery, the ABI version probe, `describe`/`init`/`on_load`, ticking, and
## unloading.
##
## What stays with each host is the `aowlspt_nim_*` surface: the functions
## `aowlspt_shim.h` calls back into to implement `AowlHostApi`. Those genuinely
## differ per side, and each binary must define its own set because the shim's
## vtable is built from them.

import std/[strutils, syncio]
import aowlsptinstall/winfs

{.emit: """#include "aowlspt_shim.h" """.}

type HostPtr* = nil pointer

proc cSysNowMs*(): uint64 {.importc: "aowl_sys_now_ms", nodecl.}
proc cSysSleep*(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}
proc cSysThreadId*(): uint32 {.importc: "aowl_sys_thread_id", nodecl.}
proc cSysModulePath*(buf: HostPtr; cap: int32): int32 {.
  importc: "aowl_sys_module_path", nodecl.}
proc cLoadLibrary*(path: cstring): HostPtr {.
  importc: "aowl_sys_load_library", nodecl.}
proc cFreeLibrary*(h: HostPtr) {.importc: "aowl_sys_free_library", nodecl.}
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

var gLogPath = ""
var gStartMs = 0'u64
var gMods*: seq[LoadedMod] = @[]

proc startClock*() =
  gStartMs = cSysNowMs()

proc elapsedMs*(): int64 =
  result = int64(cSysNowMs() - gStartMs)

proc openLog*(path, banner: string) =
  ## A fresh log each run: the interesting failure is always this one.
  gLogPath = path
  discard writeTextFile(gLogPath, banner)

proc logLine*(level, msg: string) =
  ## Opened, written and closed per line, never buffered. A host that takes the
  ## process down with it is a host whose log has to survive that.
  if gLogPath.len == 0:
    return
  let text = "[" & $int(elapsedMs()) & "ms] " & level & "  " & msg & "\n"
  var f: File
  if open(f, gLogPath, fmAppend):
    try:
      write(f, text)
    finally:
      close(f)

proc info*(msg: string) = logLine("info ", msg)
proc warn*(msg: string) = logLine("warn ", msg)
proc fail*(msg: string) = logLine("error", msg)
proc okLog*(msg: string) = logLine("ok   ", msg)

proc readBytes*(p: HostPtr; len: int32): string =
  result = ""
  if p == nil or len <= 0'i32:
    return
  for i in 0 ..< int(len):
    result.add char(cByteAt(p, uint64(i)))

proc ownDirectory*(): string =
  var buf = newSeq[byte](32768)
  let n = cSysModulePath(cast[HostPtr](addr buf[0]), 32767'i32)
  if n <= 0'i32:
    return ""
  var path = ""
  for i in 0 ..< int(n):
    path.add char(buf[i])
  result = parentOf(path)

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

proc loadMod*(path: string; side: int32; hostName, hostVersion: string;
              sptVersion = ""; gameVersion = ""): bool =
  ## Brings one mod up: version probe, describe, init, on_load. A step that
  ## fails leaves the mod unloaded rather than half-loaded, and says which step.
  var m = LoadedMod(path: path, dir: parentOf(path),
                    module: cast[HostPtr](0), info: cast[HostPtr](0),
                    api: cast[HostPtr](0), hostBlock: cast[HostPtr](0),
                    guid: "", name: "", author: "", version: "",
                    hasUpdate: false, live: false)

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

  # A mod that does not claim this side is skipped rather than run. The same
  # binary ships to every host, and running its client half in a server would
  # be worse than not loading it.
  let sides = cModInfoSides(m.info)
  if (sides and (1'u32 shl uint32(side))) == 0'u32:
    info m.name & " does not support this side; skipping"
    cModInfoFree(m.info)
    cFreeLibrary(m.module)
    return false

  let index = gMods.len
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

proc loadAll*(modsDir: string; side: int32; hostName, hostVersion: string;
              sptVersion = ""; gameVersion = ""): int =
  let found = discoverMods(modsDir)
  info $found.len & " candidate libraries under " & modsDir
  for path in found:
    discard loadMod(path, side, hostName, hostVersion, sptVersion, gameVersion)
  result = gMods.len

proc tickMods*(elapsed: int64) =
  for i in 0 ..< gMods.len:
    if gMods[i].live and gMods[i].hasUpdate:
      discard cModApiOnUpdate(gMods[i].api, elapsed)

proc unloadMods*() =
  for i in 0 ..< gMods.len:
    if not gMods[i].live:
      continue
    discard cModApiOnUnload(gMods[i].api)
    cModApiFree(gMods[i].api)
    cHostApiFree(gMods[i].hostBlock)
    cModInfoFree(gMods[i].info)
    cFreeLibrary(gMods[i].module)
    gMods[i].live = false

proc modDirOf*(index: int): string =
  if index < 0 or index >= gMods.len:
    return ""
  result = gMods[index].dir

proc modGuidOf*(index: int): string =
  if index < 0 or index >= gMods.len:
    return ""
  result = gMods[index].guid
