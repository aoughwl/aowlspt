## swap.nim — the runtime texture swap, made crash-proof for the real client.
##
## The original was a BepInEx Harmony postfix on `AssetBundle.LoadAsset` and
## `AssetBundleRequest.asset`; this is the IL2CPP port through the host's
## `hookReturn` postfix detour. The first live test of the naive version booted
## the mod fine and then crashed the game before the menu — so this file is
## built around *not doing that*, in layers:
##
## 1. **Nothing during boot.** Arming is deferred: no hook is installed until the
##    game is well past the boot bundle-load storm (`maybeArm`, driven from
##    `onUpdate` after a delay and once the IL2CPP runtime's metadata is
##    queryable). The gate is drain-independent — on this build the host's
##    per-frame drain binds nothing, and a native `hookReturn` on `LoadAsset`
##    does not need it: the game calls `LoadAsset` on the Unity thread, so the
##    postfix (and its `il2cpp_array_new` + `LoadImage`) runs there for free.
##
## 2. **Verify the target before patching.** A wrong code pointer is the worst
##    failure: the detour engine would relocate whatever bytes are there and the
##    game would run corruption on the next bundle load. So before `hookReturn`,
##    the method is resolved exactly as the host will (`findClass` + `findMethod`
##    + `methodPointer`) and its prologue is byte-compared against the known-good
##    bytes for this build. A mismatch aborts the install — no patch, no crash.
##    The bytes were resolved offline from `D:/Games/Tarkov/GameAssembly.dll`
##    (build 1.1.0.1.46777) with `tools/il2cpp_resolve.py`.
##
## 3. **LoadAsset only, by default.** On this build
##    `AssetBundleRequest::get_asset` resolves to a **tail-jump virtual-dispatch
##    thunk** (`48 8B 11 … 48 FF E0`), not a real method body; postfix-detouring a
##    thunk is unsafe, so the async path is off unless explicitly asked for.
##    `AssetBundle::LoadAsset` is a normal, cleanly-relocatable prologue.
##
## 4. **Staged modes.** `off` (default) installs nothing. `probe` installs the
##    verified LoadAsset hook with a postfix that only counts firings — it proves
##    the install and the firing are safe with zero per-asset work. `match` adds
##    the name lookup (no pixels). `full` adds the upload. Escalate one rung at a
##    time from `config.json`.
##
## 5. **Guard every pointer.** The postfix verifies each address is committed and
##    readable (`VirtualQuery`) before touching it, and the upload runs only in
##    `full` mode, only after arming (so never during boot), only within the VRAM
##    budget. Any failure degrades to keeping the stock texture.

import std/strutils
import std/syncio
import aowlspt
import aowlspt/game
import aowlspt/il2cpp
import aowlspt/fast
import manifest

const
  TgtLoadAsset* = "UnityEngine.AssetBundle::LoadAsset"
  TgtReqAsset*  = "UnityEngine.AssetBundleRequest::get_asset"

  ## The first 16 bytes of `UnityEngine.AssetBundle::LoadAsset` on build
  ## 1.1.0.1.46777, shared by both the `(string)` and `(string, Type)` overloads
  ## (RVA 0x5250100 / 0x5250340, imagebase 0x180000000). All non-RIP-relative
  ## `mov`/`push`/`sub`, which is what makes the detour engine's steal-and-
  ## relocate safe. Resolved offline with tools/il2cpp_resolve.py.
  LoadAssetProlog: array[16, uint8] = [
    0x48'u8, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74,
    0x24,    0x10, 0x57, 0x48, 0x83, 0xEC, 0x20, 0x80]

  ModeOff = 0
  ModeProbe = 1
  ModeMatch = 2
  ModeFull = 3

# The raw byte copy into a freshly-allocated IL2CPP byte[], plus VirtualQuery
# guards, kept local so the whole path adds nothing to the shared shim the host
# and other worktrees are editing. `arr` is an `Il2CppArray*`; on 64-bit its
# element data begins 32 bytes in (header: `Il2CppObject{klass, monitor}` 16 +
# `bounds` 8 + `max_length` 8); the array was allocated with `n` elements, so
# writing `n` bytes from that offset stays inside the allocation.
{.emit: """
#include <windows.h>
#include <string.h>
static void aowl_tex_fill(void* arr, const void* src, unsigned long long n) {
  if (arr && src && n) memcpy((char*)arr + 32, src, (size_t)n);
}
static int aowl_tex_readable(const void* p, int n) {
  MEMORY_BASIC_INFORMATION mbi;
  if (!p || n <= 0) return 0;
  if (!VirtualQuery(p, &mbi, sizeof(mbi))) return 0;
  if (mbi.State != MEM_COMMIT) return 0;
  if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
  {
    unsigned long long end = (unsigned long long)mbi.BaseAddress + mbi.RegionSize;
    return ((unsigned long long)p + (unsigned long long)n <= end) ? 1 : 0;
  }
}
static int aowl_tex_readcode(const void* p, unsigned char* out, int n) {
  if (!aowl_tex_readable(p, n)) return 0;
  memcpy(out, p, (size_t)n);
  return n;
}
""".}
proc texFill(arr, src: Il2CppPtr; n: uint64) {.importc: "aowl_tex_fill", nodecl.}
proc texReadable(p: Il2CppPtr; n: int32): int32 {.importc: "aowl_tex_readable", nodecl.}
proc texReadCode(p, outp: Il2CppPtr; n: int32): int32 {.
  importc: "aowl_tex_readcode", nodecl.}

# --------------------------------------------------------------------------
# VRAM budgeting
# --------------------------------------------------------------------------
#
# A 2K texture decoded to RGBA32 with a mip chain is ~22 MiB of VRAM. The
# curated manifest holds ~500 candidates; swapping all uncompressed would be
# ~11 GiB. So the resident set is bounded by a hard VRAM budget: arm textures
# until the projected budget is spent, then stop. The manifest is the soft bound
# (which textures may be swapped), the budget is the hard one (how many become
# resident). Block compression (BC7/BC1) is the real per-texture fix — a future
# pipeline step; until then the budget keeps the count sane.

proc tierBytes(tier: string): int64 =
  if tier == "4K":
    return 4'i64 * 4096'i64 * 4096'i64 * 4'i64 div 3'i64
  result = 2048'i64 * 2048'i64 * 4'i64 * 4'i64 div 3'i64

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

var gMode = ModeOff
var gHookAsync = false        ## hook get_asset too (off: it is a thunk on this build)
var gArmed = false
var gArmTried = false
var gCanUpload = false
var gBudgetBytes: int64 = 0
var gResidentBytes: int64 = 0
var gTier = "2K"
var gArmDelayMs = 15000'i64   ## how long after load before arming (past boot)
var gLoadedAtMs = 0'i64

var gMinConf = 0.0
var gCatFilter = ""

var gFires: int64 = 0
var gTexReturns: int64 = 0
var gMatches: int64 = 0
var gSwapped: int64 = 0
var gWithinBudget: int64 = 0
var gRefusedBudget: int64 = 0
var gLastMatchName = ""
var gUploadFailReported = false

# Runtime + bindings, all resolved at arm time (post-boot), never at load.
var gRt = Il2Cpp(handle: cast[Il2CppPtr](0), loaded: false, lastError: 0'i32,
                 missing: @[])
var gByteClass: Il2CppPtr = cast[Il2CppPtr](0)
var gLoadImage: Binding
var gLoadImageTex: Binding

proc swapArmed*(): bool = gArmed
proc canUpload*(): bool = gCanUpload
proc swapModeInt*(): int = gMode

proc setFilter*(minConf: float; enabledCats: string) =
  gMinConf = minConf
  gCatFilter = enabledCats

proc modeFromText(s: string): int =
  case s
  of "probe": ModeProbe
  of "match": ModeMatch
  of "full":  ModeFull
  else:       ModeOff

proc configureSwap*(mode: string; budgetMB: int; tier: string;
                    hookAsync: bool; armDelayMs: int) =
  ## Records what the mod will do, without doing any of it. Called from onLoad;
  ## the actual install is deferred to `maybeArm` on a later frame.
  gMode = modeFromText(mode)
  gTier = tier
  gBudgetBytes = int64(budgetMB) * 1024'i64 * 1024'i64
  gResidentBytes = 0
  gHookAsync = hookAsync
  gArmDelayMs = int64(armDelayMs)
  gLoadedAtMs = nowMs()

# --------------------------------------------------------------------------
# Small hex helper for the logs
# --------------------------------------------------------------------------

proc hex2(b: uint8): string =
  const digits = "0123456789ABCDEF"
  result = ""
  result.add digits[int(b shr 4)]
  result.add digits[int(b and 0x0F'u8)]

proc bytesHex(b: openArray[uint8]): string =
  result = ""
  for i in 0 ..< b.len:
    if i > 0: result.add " "
    result.add hex2(b[i])

# --------------------------------------------------------------------------
# The upload path (full mode only, post-boot only)
# --------------------------------------------------------------------------

proc readFileBinary(path: string; into: var string): bool =
  var f: File
  if not open(f, path, fmRead):
    return false
  into = ""
  var chunk = newString(65536)
  let dst = cast[pointer](slice(chunk).data)
  while true:
    let n = readBuffer(f, dst, 65536)
    if n <= 0:
      break
    if n == 65536:
      into.add chunk
    else:
      into.add substr(chunk, 0, n - 1)
  close(f)
  result = into.len > 0

proc buildAndSwap(idx: int; obj: GameObj): bool =
  ## Decodes the replacement image into the returned texture in place. Every
  ## pointer is checked committed-and-readable before use; any failure is a clean
  ## false and the game keeps its texture.
  var address: uint64 = 0
  if pointerOf(obj.handle, address) != Ok or address == 0'u64:
    return false
  let texPtr = cast[Il2CppPtr](address)
  if texReadable(texPtr, 8) == 0'i32:      # the object header must be readable
    return false

  var bytes = ""
  if not readFileBinary(resolvedPath(idx), bytes) or bytes.len == 0:
    return false

  let arr = arrayNew(gRt, gByteClass, bytes.len)
  if cast[uint](arr) == 0'u:
    return false
  let sl = slice(bytes)
  if cast[uint](sl.data) == 0'u:
    return false
  texFill(arr, cast[Il2CppPtr](sl.data), uint64(bytes.len))

  if gLoadImage.ok:
    var a = noArgs()
    addPtr(a, texPtr)
    addPtr(a, arr)
    result = callBool(gLoadImage, nullPtr(), a)
  elif gLoadImageTex.ok:
    var a = noArgs()
    addPtr(a, arr)
    result = callBool(gLoadImageTex, texPtr, a)
  else:
    result = false

# --------------------------------------------------------------------------
# The postfix — one body, branches on the mode
# --------------------------------------------------------------------------

proc onTextureReturn(target, args: string): HookResult =
  ## Fires after `LoadAsset` returns, on the Unity thread. In `probe` mode it
  ## does nothing but count — the cheapest possible proof the hook is safe.
  inc gFires
  if gMode <= ModeProbe:
    return keepResult()

  let r = hookResult(args)
  if r.isNull:
    return keepResult()
  let obj = asObject(r)
  if not obj.ok:
    return keepResult()
  let nmeR = obj.invoke("get_name")
  let name = nmeR.asText()
  if name.len == 0:
    return keepResult()
  inc gTexReturns
  let idx = lookup(name)
  if idx < 0:
    return keepResult()
  if entryConf(idx) < gMinConf:
    return keepResult()
  if gCatFilter.len > 0 and find(gCatFilter, "," & entryCat(idx) & ",") < 0:
    return keepResult()
  inc gMatches
  gLastMatchName = name
  let cost = tierBytes(entryTier(idx))
  if gResidentBytes + cost > gBudgetBytes:
    inc gRefusedBudget
    return keepResult()
  inc gWithinBudget

  if gMode < ModeFull or not gCanUpload:
    # Matched and within budget, but not uploading (match mode, or upload not
    # available). The game keeps its stock texture; this is observable proof the
    # match half works ahead of enabling pixels.
    return keepResult()

  if buildAndSwap(idx, obj):
    gResidentBytes = gResidentBytes + cost
    inc gSwapped
    if gSwapped <= 5'i64 or (gSwapped mod 25'i64) == 0'i64:
      info "textures  swapped " & name & " (" & entryCat(idx) & ", " &
           entryMap(idx) & "); resident " &
           $(gResidentBytes div (1024'i64 * 1024'i64)) & " MB of " &
           $(gBudgetBytes div (1024'i64 * 1024'i64)) & " MB"
  elif not gUploadFailReported:
    gUploadFailReported = true
    warn "textures  the first upload of " & name & " did not take (LoadImage " &
         "returned false or the file was unreadable); further failures are " &
         "silent — the game keeps its stock texture"
  result = keepResult()

# --------------------------------------------------------------------------
# Target verification
# --------------------------------------------------------------------------

proc verifyTarget(spec: string; expect: array[16, uint8];
                  outFn: var Il2CppPtr): string =
  ## Resolves `spec` the way the host will and byte-verifies its prologue.
  ## Returns "" on success (with `outFn` set to the code pointer), else the
  ## reason the install must be refused. Nothing here patches anything — it only
  ## reads metadata and 16 bytes of code.
  outFn = cast[Il2CppPtr](0)
  let sep = find(spec, "::")
  if sep < 0:
    return "not a Type::Method spec"
  let typ = substr(spec, 0, sep - 1)
  let meth = substr(spec, sep + 2)
  let cls = findClass(gRt, typ)
  if cls == nil:
    return "type not found: " & typ
  let m = findMethod(gRt, cls, meth, -1)   # any arity, exactly as the host does
  if cast[uint](m) == 0'u:
    return "method not found: " & meth
  let fn = methodPointer(gRt, m)
  if cast[uint](fn) == 0'u:
    return "methodPointer is null — the host would refuse this too, no patch"
  var buf: array[16, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0]
  if texReadCode(fn, cast[Il2CppPtr](addr buf[0]), 16'i32) != 16'i32:
    return "code at the resolved pointer is not readable"
  for i in 0 ..< 16:
    if buf[i] != expect[i]:
      return "prologue MISMATCH — refusing to patch. got [" & bytesHex(buf) &
             "] expected [" & bytesHex(expect) & "]. The resolved pointer is " &
             "not the method this build expects; patching it would corrupt code."
  outFn = fn
  result = ""

# --------------------------------------------------------------------------
# Arming — deferred, verified, guarded
# --------------------------------------------------------------------------

proc probeUpload() =
  ## Decides `gCanUpload`, at arm time (post-boot). Checks every prerequisite;
  ## any missing leaves it false and the mod runs match-only.
  gCanUpload = false
  if not gRt.loaded:
    return
  if not gRt.has(eArrayNew):
    warn "textures  runtime has no il2cpp_array_new; upload off (match-only)"
    return
  gByteClass = findClass(gRt, "System.Byte")
  if gByteClass == nil:
    warn "textures  System.Byte did not resolve; upload off (match-only)"
    return
  gLoadImage = bindMethod(gRt, "UnityEngine.ImageConversion", "LoadImage", 2)
  if not gLoadImage.ok:
    gLoadImageTex = bindMethod(gRt, "UnityEngine.Texture2D", "LoadImage", 1)
  if not gLoadImage.ok and not gLoadImageTex.ok:
    warn "textures  no LoadImage binding; upload off (match-only)"
    return
  if not livePointersReady():
    warn "textures  host has no live object pointers (rev 3); upload off"
    return
  gCanUpload = true

proc installVerified(spec: string; expect: array[16, uint8]): bool =
  ## Verify then install one postfix. Never installs on a failed verification.
  var fn: Il2CppPtr = cast[Il2CppPtr](0)
  let why = verifyTarget(spec, expect, fn)
  if why.len > 0:
    warn "textures  NOT hooking " & spec & ": " & why
    return false
  var pro: array[16, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0]
  discard texReadCode(fn, cast[Il2CppPtr](addr pro[0]), 16'i32)
  info "textures  verified " & spec & " prologue [" & bytesHex(pro) &
       "] — installing postfix"
  let st = hookReturn(spec, onTextureReturn, withArgs = false)
  if st == Ok:
    info "textures  hooked " & spec
    return true
  warn "textures  hookReturn refused " & spec & ": " & lastError()
  result = false

proc runtimeReady(): bool =
  ## Drain-INDEPENDENT readiness: the IL2CPP runtime is up and its metadata is
  ## queryable. This is the correct "are we past boot enough to install" signal
  ## on this build, where the host's per-frame drain never binds a method — so
  ## the drain is NOT usable as a liveness gate. `hookReturn` does not need the
  ## drain anyway: it is a native inline detour on `LoadAsset`'s own code, and
  ## the game calls `LoadAsset` on the Unity thread, so the postfix runs there
  ## for free. A well-known Unity type resolving means the assemblies are loaded
  ## and metadata queries are safe — which is all the install and the postfix
  ## require.
  if not gRt.loaded:
    gRt = openIl2Cpp()
  if not gRt.loaded:
    return false
  result = findClass(gRt, "UnityEngine.AssetBundle") != nil

proc readyToArm(): bool =
  ## True once the arm delay has elapsed (clearing the boot bundle-load storm)
  ## and the runtime's metadata is queryable. No drain dependency.
  if gMode == ModeOff:
    return false
  if nowMs() - gLoadedAtMs < gArmDelayMs:
    return false
  result = runtimeReady()

proc maybeArm*(): bool =
  ## Called every tick from onUpdate. Installs the verified hook(s) exactly once,
  ## and only when it is safe to. Returns true on the tick it arms. If
  ## verification refuses, it does NOT retry — one honest refusal, not a per-tick
  ## log storm.
  if gArmed or gArmTried:
    return false
  if not readyToArm():
    return false
  # readyToArm() only returns true once runtimeReady() has opened the runtime and
  # a well-known type resolved, so gRt is loaded here.
  gArmTried = true

  if gMode >= ModeFull:
    probeUpload()

  var bound = 0
  if installVerified(TgtLoadAsset, LoadAssetProlog):
    inc bound
  if gHookAsync:
    warn "textures  hookAsync is on: AssetBundleRequest::get_asset is a " &
         "tail-jump thunk on this build (48 8B 11 … 48 FF E0). Verifying its " &
         "own prologue before install."
    # Its prologue is a thunk, not the LoadAsset shape; verify against the thunk
    # bytes so a wrong pointer is still refused, but only the caller opting in
    # gets here.
    const ThunkProlog: array[16, uint8] = [
      0x48'u8, 0x8B, 0x11, 0x48, 0x8B, 0x82, 0x78, 0x01,
      0x00,    0x00, 0x48, 0x8B, 0x92, 0x80, 0x01, 0x00]
    if installVerified(TgtReqAsset, ThunkProlog):
      inc bound

  gArmed = bound > 0
  if not gArmed:
    warn "textures  nothing hooked; the mod is a no-op (stock textures)"
    return false

  let modeName = (case gMode
                  of ModeProbe: "probe (count only)"
                  of ModeMatch: "match (name-match, no upload)"
                  of ModeFull:  (if gCanUpload: "full (upload)"
                                 else: "full requested but upload unavailable — match-only")
                  else: "off")
  success "textures  ARMED post-boot in mode " & modeName & "; VRAM budget " &
          $(gBudgetBytes div (1024'i64 * 1024'i64)) & " MB"
  result = true

proc swapStats*(): string =
  result = "{\"mode\":" & $gMode &
           ",\"armed\":" & (if gArmed: "true" else: "false") &
           ",\"canUpload\":" & (if gCanUpload: "true" else: "false") &
           ",\"tier\":\"" & gTier & "\"" &
           ",\"budgetBytes\":" & $gBudgetBytes &
           ",\"residentBytes\":" & $gResidentBytes &
           ",\"fires\":" & $gFires &
           ",\"textureReturns\":" & $gTexReturns &
           ",\"matches\":" & $gMatches &
           ",\"withinBudget\":" & $gWithinBudget &
           ",\"refusedBudget\":" & $gRefusedBudget &
           ",\"swapped\":" & $gSwapped &
           ",\"lastMatch\":\"" & gLastMatchName & "\"}"

proc residentTextureBudget*(budgetMB: int; tier: string): int =
  let per = tierBytes(tier)
  if per <= 0:
    return 0
  result = int((int64(budgetMB) * 1024'i64 * 1024'i64) div per)
