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
  ## PATCH BY VERIFIED STATIC RVA, not by name.
  ##
  ## By-name resolution is dead on build 1.1.0.1.46777: `findClass` and
  ## `findMethod` return NON-NIL handles into unmapped memory, so
  ## `methodPointer` reads null and there is no fallback that needs a
  ## MethodInfo. Measured live on both the host thread and the Unity main
  ## thread in one boot -- 6 probed, 6 with an unreadable MethodInfo, 0
  ## comparable -- so it is not a threading artefact.
  ##
  ## The spec therefore names the address and DECLARES the frame shape, which
  ## with no MethodInfo the host cannot derive and refuses to guess:
  ##
  ##   Type::Method@0xRVA/<shape>!<hex prologue>
  ##
  ## `io>o` = instance, one object argument (`System.String` is an object on
  ## this ABI), returns an object. `LoadAsset(string)` is rid=6 at RVA
  ## 0x5250100 (rid=7 @0x5250340 is the `(string, Type)` overload), resolved
  ## offline with `tools/il2cpp_resolve.py ... type 30974`.
  ##
  ## The trailing bytes are the same 16 as `LoadAssetProlog` below, handed to
  ## the host so it can compare them against its STARTUP SNAPSHOT of the
  ## original bytes rather than against live memory -- the only compare that
  ## still gives the right answer if another feature detours this function
  ## first.
  ## THE REAL ASSET LOAD PATH ON THIS BUILD.
  ##
  ## Unity's `AssetBundle` API is NOT how Tarkov loads assets. Facts #55/#74:
  ## across a full raid and a menu session every Unity target -- and the `ab6`
  ## control -- counted ZERO. BSG loads through its own layer, and the entry
  ## point is `Diz.Resources.EasyBundle::Load`, which fired 99 times AT THE
  ## MENU alone. That matters for iteration: exercising this needs no raid.
  ##
  ## rid=42 of type 30933 (image Diz.Resources.dll), RVA 0x2772CC0, arity 0,
  ## instance, returns void -> shape `i>x`. Resolved with
  ## `tools/il2cpp_resolve.py ... type 30933 --shared`, which reports NO
  ## `[SHARED: ...]` annotation for it: this RVA belongs to exactly one method.
  ##
  ## THAT IS THE WHOLE POINT OF PICKING IT. The intuitive swap point,
  ## `Object[] get_Assets()` @0x6864D0, literally returns the loaded assets --
  ## and the same command reports `[SHARED: 200 methods resolve here]`, because
  ## the IL2CPP backend FOLDS identical one-instruction getters: it is the
  ## build's universal `mov rax,[rcx+0x48]; ret`, reached by
  ## `AICoreAgentBase::get_PrevNode`, `AIExfiltrationPoint::get_ExfiltrationPoint`
  ## and 198 others. `get_LoadState` @0x690D20 is shared by 136. CALLING a
  ## shared accessor is fine -- it is correct code for the receiver you pass.
  ## DETOURING one fires for every one of those methods. So this reads the
  ## backing field directly instead, and never hooks an accessor.
  ##
  ## Prologue `48 89 5C 24 10 57 48 81 EC 90 00 00 00 48 8B D9` =
  ## `mov [rsp+0x10],rbx ; push rdi ; sub rsp,0x90 ; mov rbx,rcx` -- ordinary
  ## non-RIP-relative frame setup, which is what makes the detour engine's
  ## steal-and-relocate safe. Handed to the host so it compares against its
  ## STARTUP SNAPSHOT rather than live memory.
  TgtEbLoad* = "Diz.Resources.EasyBundle::Load@0x2772CC0/i>x" &
               "!48895C2410574881EC90000000488BD9"
  TgtEbLoadRva* = 0x2772CC0'u32
  EbLoadProlog: array[16, uint8] = [
    0x48'u8, 0x89, 0x5C, 0x24, 0x10, 0x57, 0x48, 0x81,
    0xEC,    0x90, 0x00, 0x00, 0x00, 0x48, 0x8B, 0xD9]

  ## `Diz.Resources.EasyBundle` instance field offsets, from
  ## `Il2CppMetadataRegistration.fieldOffsets` via
  ## `tools/il2cpp_resolve.py ... fields Diz.Resources.EasyBundle`. Not one of
  ## these is guessed.
  ##
  ##   0x10 _keyWithoutExtension  string
  ##   0x30 <Key>k__BackingField  string
  ##   0x38 _bundle               AssetBundle
  ##   0x48 <Assets>k__BackingField   Object[]   <- the swap surface
  ##   0x60 <LoadState>k__BackingField
  ##   0x68 _loadingJob           Task
  EbAssetsOff = 0x48'u
  EbKeyOff    = 0x30'u

  ## `Il2CppArray` layout, 64-bit: `Il2CppObject{klass,monitor}` 16, `bounds`
  ## at 0x10, `max_length` at 0x18, elements from 0x20.
  ##
  ## MEASURED, not assumed -- and measured from BSG's own compiled code rather
  ## than from a header. `<LoadingCoroutine>d__34::MoveNext` walks this very
  ## array at 0x27742A7 (`cmp r8d, dword ptr [rcx+0x18]`) and indexes it at
  ## 0x27742BD (`mov rcx, qword ptr [rcx+rax*8+0x20]`).
  ArrLenOff  = 0x18'u
  ArrDataOff = 0x20'u

  ## Hard cap on how many elements of one bundle's asset array are visited. A
  ## corrupt `max_length` must be a short walk, not an unbounded loop inside a
  ## frame on the Unity thread.
  MaxAssetsPerBundle = 512

  TgtLoadAsset* = "UnityEngine.AssetBundle::LoadAsset@0x5250100/io>o" &
                  "!48895C24084889742410574883EC2080"
  TgtLoadAssetRva* = 0x5250100'u32
  ## `AssetBundleRequest::get_asset` is rid-resolved to a tail-jump
  ## virtual-dispatch thunk on this build, and is off unless asked for.
  ## rid=23 @ RVA 0xB196C0 (type 30977), prologue
  ## `48 8B 11 48 8B 82 78 01 00 00 48 8B 92 80 01 00` -- a tail-jump
  ## virtual-dispatch thunk, which is why it stays off unless asked for.
  TgtReqAsset*  = "UnityEngine.AssetBundleRequest::get_asset@0xB196C0/i>o" &
                  "!488B11488B8278010000488B92800100"
  TgtReqAssetRva* = 0xB196C0'u32

  ## `UnityEngine.Object::get_name`, rid=2874 of type 23130, RVA 0x52AD4B0.
  ##
  ## THE NAME SOURCE. `match` mode exists to compare what the game loads
  ## against the curated manifest, and the manifest is a NAME table -- so
  ## without a name the whole rung, and with it the unmatched-name sampler
  ## that is the only evidence we would ever get of a namespace mismatch, is
  ## dead. It used to come from `GameObj.invoke("get_name")`, which resolves by
  ## name, which returns non-nil handles into unmapped memory on this build.
  ##
  ## So it is CALLED AT ITS STATIC RVA instead -- one of the three things that
  ## still works here. Instance convention: RCX = the object, RDX = the hidden
  ## trailing `const MethodInfo*`, which may be NULL because `get_name` is not
  ## a shared generic. Prologue `40 53 48 83 EC 20 80 3D ...` is
  ## `push rbx ; sub rsp,0x20 ; cmp byte[rip+..],0 ; mov rbx,rcx`, IL2CPP's
  ## ordinary class-init preamble; bytes 8..11 are a RIP-relative displacement,
  ## which is exactly what pins this signature to this build.
  GetNameRva* = 0x52AD4B0'u32
  GetNameProlog: array[16, uint8] = [
    0x40'u8, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x80, 0x3D,
    0x36,    0x72, 0xE2, 0x01, 0x00, 0x48, 0x8B, 0xD9]

  ## The longest asset name this will read out of a managed string. A cap, not
  ## an expectation: `length` is read from the object and a corrupt one would
  ## otherwise be an unbounded loop inside a frame.
  MaxNameChars = 256

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
/* The direct call at a static RVA. IL2CPP instance convention: `this` in RCX,
 * then the hidden trailing `const MethodInfo*` in RDX -- NULL is fine here
 * because `get_name` is not a shared generic. Returns the `System.String*`.
 *
 * No fault guard around it, deliberately: `aowl_p_p_seh` is NOT re-entrant and
 * this runs inside the host's typed-fire path, so a guard here could disarm an
 * outer one. Safety comes from the checks the caller makes FIRST -- the
 * prologue is byte-verified against the bytes this build compiled, and the
 * object pointer is VirtualQuery'd -- plus the caller's fault-budget
 * self-disable. */
static void* aowl_tex_getname(void* fn, void* obj) {
  typedef void* (*getname_t)(void*, void*);
  if (!fn || !obj) return 0;
  return ((getname_t)fn)(obj, 0);
}

/* GameAssembly.dll's ACTUAL base, asked for at runtime. 0x180000000 is the PE
 * PREFERRED base -- the space tools/il2cpp_resolve.py reports RVAs in -- and
 * the module is ASLR-relocated in the live process. Never hardcode it. */
static void* aowl_tex_rva(unsigned int rva) {
  HMODULE ga = GetModuleHandleA("GameAssembly.dll");
  if (!ga) return NULL;
  return (void*)((unsigned char*)ga + rva);
}
static int aowl_tex_readcode(const void* p, unsigned char* out, int n) {
  if (!aowl_tex_readable(p, n)) return 0;
  memcpy(out, p, (size_t)n);
  return n;
}
/* A guarded single pointer hop. Every dereference on the EasyBundle path goes
 * through this: `this` -> `<Assets>k__BackingField` -> element[i] is THREE
 * hops and therefore three VirtualQuery checks, not one. Returns NULL for an
 * uncommitted source, which every caller treats as "no answer", never as
 * "the field is null". */
static void* aowl_tex_readptr(const void* p) {
  if (!aowl_tex_readable(p, 8)) return 0;
  return *(void* const*)p;
}
/* The same for the Il2CppArray `max_length` at +0x18. Separated from the
 * pointer read so a corrupt length is a REFUSAL (returns 0) rather than a
 * length of whatever happened to be in the register. */
static int aowl_tex_readi32(const void* p, int* out) {
  if (!aowl_tex_readable(p, 4)) return 0;
  *out = *(const int*)p;
  return 1;
}
""".}
proc texFill(arr, src: Il2CppPtr; n: uint64) {.importc: "aowl_tex_fill", nodecl.}
proc texReadable(p: Il2CppPtr; n: int32): int32 {.importc: "aowl_tex_readable", nodecl.}
proc texReadCode(p, outp: Il2CppPtr; n: int32): int32 {.
  importc: "aowl_tex_readcode", nodecl.}
proc texRva(rva: uint32): Il2CppPtr {.importc: "aowl_tex_rva", nodecl.}
proc texGetName(fn, obj: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_tex_getname", nodecl.}
proc texReadPtr(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_tex_readptr", nodecl.}
proc texReadI32(p: Il2CppPtr; outv: ptr int32): int32 {.
  importc: "aowl_tex_readi32", nodecl.}

proc at(p: Il2CppPtr; off: uint): Il2CppPtr =
  ## `p + off` as a pointer. Never dereferences; the caller's guarded read does.
  result = cast[Il2CppPtr](cast[uint](p) + off)

proc rvaHex(v: uint32): string =
  ## An RVA as bare hex, the way every address in this project is written.
  ## Local because Nimony's strutils has no `toHex`.
  const D = "0123456789ABCDEF"
  var x = v
  if x == 0'u32:
    return "0"
  result = ""
  var buf = ""
  while x != 0'u32:
    buf = buf & $D[int(x and 0xF'u32)]
    x = x shr 4
  for i in countdown(buf.len - 1, 0):
    result = result & $buf[i]

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

const MaxUnmatchedLogged = 40
var gUnmatchedLogged = 0

## THE MEASUREMENT THIS HOOK EXISTS TO MAKE FIRST.
##
## `Load()` is void, so a postfix has no return value to replace: the assets
## have to come off `this`. Whether they are THERE yet is a question that must
## be answered, not assumed -- `LoadingCoroutine()` returns a `Task`, so `Load`
## may well have started the work and returned. These four counters answer it
## from one live menu session, and they are reported in `swapStats` whatever
## the answer is. A zero in `assetsPopulated` is a RESULT, not a failure, and
## the first firing of each outcome says so in the log.
var gEbFires: int64 = 0
var gNoSelf: int64 = 0
var gEbUnreadable: int64 = 0
var gAssetsNull: int64 = 0
var gAssetsEmpty: int64 = 0
var gAssetsPopulated: int64 = 0
var gAssetsWalked: int64 = 0
var gSaidNull = false
var gSaidEmpty = false
var gSaidPopulated = false

## Self-disable for the EasyBundle path. `gNameFaults` already retires the
## `get_name` call; these retire the WALK itself. A hop that has come back
## unreadable this many times is not a transient, and repeating it every bundle
## load for the rest of the session is exactly the failure mode rule 6 exists
## to stop. Retiring says so once, out loud, and then goes quiet.
var gEbFaults = 0
const MaxEbFaults = 16
var gEbRetired = false

## Non-albedo maps counted and REFUSED by default -- see `gAlbedoOnly`.
var gRefusedNonAlbedo: int64 = 0
var gAlbedoOnly = true

## The name source, resolved and prologue-verified once at arm time. Nil means
## `match`/`full` cannot run and SAY SO -- never that they run and match zero.
var gGetNameFn: Il2CppPtr = cast[Il2CppPtr](0)
## Fault budget. `get_name` is a real call into game code, so a path that has
## gone wrong N times turns itself off rather than doing it every frame for the
## rest of the session. Counted on unusable ANSWERS (an unreadable string, an
## absurd length), which is the only failure this can observe without a guard.
var gNameFaults = 0
const MaxNameFaults = 8

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

proc setAlbedoOnly*(v: bool) =
  ## ONLY ALBEDO IS COLOUR (fact #36). normal / roughness / ao / height /
  ## metalness are DATA and must not be gamma-decoded as sRGB.
  ##
  ## The upload path here is `ImageConversion.LoadImage`, which decodes into
  ## the texture the game already created and does NOT take a colour-space
  ## argument -- and this mod has no way, offline, to establish what sRGB flag
  ## each destination texture was created with. So rather than ship normals
  ## that may be gamma-decoded and look wrong, the default is to swap ONLY
  ## entries whose `map` is albedo, count the rest, and say so. Turning this
  ## off is an explicit statement that you have verified the colour space on
  ## your build; it is not a quality setting.
  gAlbedoOnly = v

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

proc nameOfObject(obj: Il2CppPtr): string =
  ## The managed `name` of a live `UnityEngine.Object`, by direct call at a
  ## verified static RVA, then a raw read of the returned `System.String`.
  ##
  ## Layout, 64-bit: `Il2CppObject{ klass, monitor }` is 16 bytes, then
  ## `length` (int32) at 0x10 and the UTF-16 characters at 0x14. That is a raw
  ## static-offset read, which is one of the three things that still works on
  ## this build.
  ##
  ## Every hop is VirtualQuery'd before it is touched and the character loop is
  ## capped, so a corrupt length is a short name rather than a walk off the end
  ## of the heap. Returns "" for every failure; the caller treats "" as "no
  ## name available" and never as "the name is empty".
  result = ""
  if cast[uint](gGetNameFn) == 0'u or cast[uint](obj) == 0'u:
    return
  if gNameFaults >= MaxNameFaults:
    return
  if texReadable(obj, 16'i32) == 0'i32:
    inc gNameFaults
    return
  let sp = texGetName(gGetNameFn, obj)
  if cast[uint](sp) == 0'u:
    return                      # a genuinely unnamed object is not a fault
  if texReadable(sp, 20'i32) == 0'i32:
    inc gNameFaults
    return
  var lenBuf: array[4, uint8] = [0'u8, 0, 0, 0]
  if texReadCode(cast[Il2CppPtr](cast[uint](sp) + 0x10'u),
                 cast[Il2CppPtr](addr lenBuf[0]), 4'i32) != 4'i32:
    inc gNameFaults
    return
  var n = int(lenBuf[0]) or (int(lenBuf[1]) shl 8) or
          (int(lenBuf[2]) shl 16) or (int(lenBuf[3]) shl 24)
  if n <= 0:
    return
  if n > MaxNameChars:
    n = MaxNameChars
  # The whole character run has to be committed before ANY of it is read.
  if texReadable(cast[Il2CppPtr](cast[uint](sp) + 0x14'u), int32(n * 2)) == 0'i32:
    inc gNameFaults
    return
  var chars = newSeq[uint8](n * 2)
  if texReadCode(cast[Il2CppPtr](cast[uint](sp) + 0x14'u),
                 cast[Il2CppPtr](addr chars[0]), int32(n * 2)) != int32(n * 2):
    inc gNameFaults
    return
  # Asset names are ASCII in practice; anything above 0x7F becomes '?' rather
  # than being dropped, so a name that does not match still LOOKS like the name
  # it is in the unmatched sample.
  for k in 0 ..< n:
    let w = int(chars[k * 2]) or (int(chars[k * 2 + 1]) shl 8)
    if w >= 0x20 and w < 0x7F:
      result = result & $char(w)
    elif w == 0:
      break
    else:
      result = result & "?"

proc resolveNameSource() =
  ## Verify `UnityEngine.Object::get_name` before it is ever called. A wrong
  ## code pointer here is a call into arbitrary bytes, so this refuses loudly
  ## rather than leaving a maybe.
  gGetNameFn = cast[Il2CppPtr](0)
  var fn: Il2CppPtr = cast[Il2CppPtr](0)
  let why = verifyTarget(GetNameRva, "UnityEngine.Object::get_name",
                         GetNameProlog, fn)
  if why.len > 0:
    warn "textures  NO name source: " & why & " — match/full cannot run, " &
         "because the manifest is a NAME table. The mod will count firings " &
         "only. This is a refusal, not a zero-match result."
    return
  gGetNameFn = fn
  info "textures  name source verified: UnityEngine.Object::get_name at " &
       "GameAssembly+0x" & rvaHex(GetNameRva) & " (direct call at a static " &
       "RVA; by-name resolution is dead on this build)"

proc buildAndSwap(idx: int; texPtr: Il2CppPtr): bool =
  ## Decodes the replacement image into the returned texture in place. Every
  ## pointer is checked committed-and-readable before use; any failure is a clean
  ## false and the game keeps its texture.
  # The raw `Texture2D*` straight from the typed frame's return register.
  # It used to come back through `pointerOf(obj.handle, ...)`, but a typed
  # postfix has no GC handle to round-trip through -- and it does not need one:
  # the postfix runs on the Unity thread inside the call that produced this
  # pointer, so the collector cannot have moved it underneath us.
  if cast[uint](texPtr) == 0'u:
    return false
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

proc considerAsset(obj: Il2CppPtr) =
  ## One loaded asset, run down the ladder: name it, match it, budget it, swap
  ## it. Shared by both hooks so there is exactly one copy of the policy.
  ##
  ## Returns nothing on purpose. Fact #19: a caught fault unwinds the ENTIRE
  ## guarded body silently, so no caller may keep "did it work" bookkeeping
  ## after this -- every counter it wants incremented is incremented HERE,
  ## before the call that could fault, or not at all.
  let name = nameOfObject(obj)
  if name.len == 0:
    return
  inc gTexReturns
  let idx = lookup(name)
  if idx < 0:
    # The single most useful thing one live run can tell us: what BSG actually
    # names the textures it loads. The curated manifest is a NAME table, so if
    # the namespaces disagree there will be zero matches and no other evidence
    # of why. Log a hard-capped SAMPLE (never a storm) of the names that came
    # back and missed, so the pipeline can be re-aimed from one run instead of
    # guessing. Capped at MaxUnmatchedLogged for the whole session.
    if gUnmatchedLogged < MaxUnmatchedLogged:
      inc gUnmatchedLogged
      info "textures  unmatched sample " & $gUnmatchedLogged & "/" &
           $MaxUnmatchedLogged & ": \"" & name & "\""
      if gUnmatchedLogged == MaxUnmatchedLogged:
        info "textures  unmatched sampling stopped at " &
             $MaxUnmatchedLogged & " names (the cap); counts keep running"
    return
  if entryConf(idx) < gMinConf:
    return
  if gCatFilter.len > 0 and find(gCatFilter, "," & entryCat(idx) & ",") < 0:
    return
  inc gMatches
  gLastMatchName = name
  if gAlbedoOnly and entryMap(idx) != "albedo":
    # Counted, never swapped. See `setAlbedoOnly`: this refusal is about
    # colour space, not quality, and it announces itself in swapStats.
    inc gRefusedNonAlbedo
    return
  let cost = tierBytes(entryTier(idx))
  if gResidentBytes + cost > gBudgetBytes:
    inc gRefusedBudget
    return
  inc gWithinBudget

  if gMode < ModeFull or not gCanUpload:
    # Matched and within budget, but not uploading (match mode, or upload not
    # available). The game keeps its stock texture; this is observable proof
    # the match half works ahead of enabling pixels.
    return

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
         "silent - the game keeps its stock texture"

proc bundleKey(eb: Il2CppPtr): string =
  ## `<Key>k__BackingField` off the EasyBundle, for the log line only. Read as
  ## a raw `System.String` the same guarded way `nameOfObject` reads one, but
  ## with NO call into game code at all - it is a field, not an accessor, and
  ## `get_Key` @0x6F1680 is shared by 280 methods anyway.
  result = ""
  let sp = texReadPtr(at(eb, EbKeyOff))
  if cast[uint](sp) == 0'u or texReadable(sp, 20'i32) == 0'i32:
    return
  var lenB: int32 = 0
  if texReadI32(at(sp, 0x10'u), addr lenB) == 0'i32:
    return
  var n = int(lenB)
  if n <= 0:
    return
  if n > MaxNameChars:
    n = MaxNameChars
  if texReadable(at(sp, 0x14'u), int32(n * 2)) == 0'i32:
    return
  var chars = newSeq[uint8](n * 2)
  if texReadCode(at(sp, 0x14'u), cast[Il2CppPtr](addr chars[0]),
                 int32(n * 2)) != int32(n * 2):
    return
  for k in 0 ..< n:
    let w = int(chars[k * 2]) or (int(chars[k * 2 + 1]) shl 8)
    if w >= 0x20 and w < 0x7F:
      result = result & $char(w)
    elif w == 0:
      break
    else:
      result = result & "?"

proc ebFault(): bool =
  ## Count one unreadable hop; return true once the path has retired itself.
  inc gEbFaults
  if gEbFaults >= MaxEbFaults and not gEbRetired:
    gEbRetired = true
    warn "textures  EasyBundle asset walk RETIRED after " & $MaxEbFaults &
         " unreadable hops (self-disable, rule 6). The hook stays installed " &
         "and keeps counting firings; it will not dereference again this " &
         "session. See ebUnreadable/noSelf in swapStats."
  result = gEbRetired

proc onBundleLoad(frame: PatchFrame): TypedResult =
  ## Fires after `Diz.Resources.EasyBundle::Load` returns, on the Unity thread.
  ##
  ## `Load` is void (`i>x`), so there is no result to read: the instance comes
  ## out of the frame's own `this` register via `selfPointer`, and the assets
  ## come from `<Assets>k__BackingField` at +0x48 - the BACKING FIELD, by raw
  ## static-offset read, NOT `get_Assets()`, whose RVA 200 unrelated methods
  ## share.
  ##
  ## Before it walks anything it RECORDS WHAT IT FOUND: null array, empty
  ## array, or populated. That is the honest answer to "is `Assets` ready when
  ## `Load` returns", and it is deliberately a measurement rather than a retry
  ## loop - if the answer is "never populated", papering over it would hide the
  ## one thing this run is worth.
  inc gFires
  inc gEbFires
  if gMode <= ModeProbe or gEbRetired:
    return frameContinue()

  let self = selfPointer(frame)
  if self == 0'u64:
    inc gNoSelf
    discard ebFault()
    return frameContinue()
  let eb = cast[Il2CppPtr](self)
  # Hop 1: the instance itself, committed out to past the field.
  if texReadable(eb, int32(EbAssetsOff + 8'u)) == 0'i32:
    inc gEbUnreadable
    discard ebFault()
    return frameContinue()
  # Hop 2: the field -> the array object.
  let arr = texReadPtr(at(eb, EbAssetsOff))
  if cast[uint](arr) == 0'u:
    inc gAssetsNull
    if not gSaidNull:
      gSaidNull = true
      info "textures  MEASURED: EasyBundle::Load returned with <Assets> NULL " &
           "(bundle \"" & bundleKey(eb) & "\"). Load starts LoadingCoroutine() " &
           "as a Task and returns, so the assets are not ready at postfix " &
           "time. Counting, NOT retrying - see assetsNull in swapStats."
    return frameContinue()
  # Hop 3: the array header -> max_length at +0x18.
  var lenB: int32 = 0
  if texReadable(arr, int32(ArrDataOff)) == 0'i32 or
     texReadI32(at(arr, ArrLenOff), addr lenB) == 0'i32:
    inc gEbUnreadable
    discard ebFault()
    return frameContinue()
  var n = int(lenB)
  if n <= 0:
    inc gAssetsEmpty
    if not gSaidEmpty:
      gSaidEmpty = true
      info "textures  MEASURED: EasyBundle::Load returned with <Assets> a " &
           "ZERO-LENGTH array (bundle \"" & bundleKey(eb) & "\")."
    return frameContinue()
  inc gAssetsPopulated
  if not gSaidPopulated:
    gSaidPopulated = true
    info "textures  MEASURED: EasyBundle::Load returned with <Assets> " &
         "POPULATED, " & $n & " element(s) (bundle \"" & bundleKey(eb) &
         "\"). The postfix IS the swap point."
  if n > MaxAssetsPerBundle:
    n = MaxAssetsPerBundle
  for i in 0 ..< n:
    if gNameFaults >= MaxNameFaults:
      break
    # Hop 4, once per element: the slot, then the object it holds.
    let obj = texReadPtr(at(arr, ArrDataOff + uint(i) * 8'u))
    if cast[uint](obj) == 0'u:
      continue
    if texReadable(obj, 16'i32) == 0'i32:
      continue
    inc gAssetsWalked
    considerAsset(obj)
  result = frameContinue()

proc onTextureReturn(frame: PatchFrame): TypedResult =
  ## Fires after `AssetBundle::LoadAsset` returns. RETAINED, NOT INSTALLED by
  ## default: fact #55 measured this at ZERO calls across a full raid, which is
  ## why the primary target moved to `EasyBundle::Load`. It stays reachable via
  ## `hookAsync` for anyone re-testing Unity's path on another build.
  inc gFires
  if gMode <= ModeProbe:
    return frameContinue()
  var okPtr = false
  let raw = resultPointer(frame, okPtr)
  if not okPtr or raw == 0'u64:
    return frameContinue()
  considerAsset(cast[Il2CppPtr](raw))
  result = frameContinue()

# --------------------------------------------------------------------------
# Target verification
# --------------------------------------------------------------------------

proc verifyTarget(rva: uint32; label: string; expect: array[16, uint8];
                  outFn: var Il2CppPtr): string =
  ## Belt-and-braces: resolve the RVA against the LIVE module base and
  ## byte-compare its prologue here, before asking the host to patch it.
  ##
  ## This is deliberately duplicated work -- the host re-verifies the same 16
  ## bytes against its own startup SNAPSHOT of the original code, which is the
  ## authoritative compare -- but this one is what stops the mod from ever
  ## handing `hookReturnTyped` an address it has not itself looked at.
  ##
  ## Resolution is by RVA and NOT by name. `findClass`/`findMethod` return
  ## non-nil handles into unmapped memory on this build, so `methodPointer`
  ## reads null and there is nothing to verify; the RVA came from
  ## `tools/il2cpp_resolve.py` offline and is checked here against the bytes
  ## that build actually compiled.
  ##
  ## One caveat stated rather than hidden: this reads LIVE memory, so it is
  ## only correct because nothing else in this host detours `LoadAsset`, and
  ## because a target's first verify necessarily precedes its first patch. If
  ## that ever stops being true this compare will read a trampoline and refuse
  ## a correct RVA -- which the mismatch message below says out loud.
  outFn = cast[Il2CppPtr](0)
  let fn = texRva(rva)
  if cast[uint](fn) == 0'u:
    return "GameAssembly.dll is not mapped (GetModuleHandleA returned NULL), " &
           "so there is no base to add 0x" & rvaHex(rva) & " to"
  var buf: array[16, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0]
  if texReadCode(fn, cast[Il2CppPtr](addr buf[0]), 16'i32) != 16'i32:
    return "the 16 bytes at GameAssembly+0x" & rvaHex(rva) &
           " are not committed and readable"
  for i in 0 ..< 16:
    if buf[i] != expect[i]:
      return "prologue MISMATCH at GameAssembly+0x" & rvaHex(rva) &
             " — refusing to patch. got [" & bytesHex(buf) & "] expected [" &
             bytesHex(expect) & "]. Either this is a different game build, " &
             "or something detoured " & label & " before this ran and these " &
             "are its trampoline bytes. Patching anyway would corrupt code."
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
  # NOT `findClass(...) != nil`. That gate was bogus for the same reason
  # `runtimeReady`'s was: on this build `findClass` hands back a NON-NIL handle
  # into UNMAPPED memory, so a nil test passes unconditionally. Here that was
  # worse than useless — the handle goes straight to `il2cpp_array_new` as the
  # element class, and allocating an array with a garbage klass is a crash, not
  # a declined feature. So the handle is PROBED: its first 8 bytes must be
  # readable, and so must the pointer they hold.
  gByteClass = findClass(gRt, "System.Byte")
  if gByteClass == nil:
    warn "textures  System.Byte did not resolve; upload off (match-only)"
    return
  if texReadable(cast[Il2CppPtr](gByteClass), 8'i32) == 0'i32:
    warn "textures  System.Byte resolved to a NON-NIL but UNREADABLE handle " &
         "— by-name class resolution does not work on this build, so the " &
         "handle is not a klass. Upload off (match-only); nothing allocated."
    gByteClass = cast[Il2CppClass](0)
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

proc installVerifiedTyped(spec: string; rva: uint32;
                          expect: array[16, uint8];
                          handler: proc (f: PatchFrame): TypedResult): bool =
  ## Verify then install one postfix. Never installs on a failed verification.
  ##
  ## `hookReturnTyped`, not `hookReturn`: an RVA patch has no MethodInfo, and
  ## every JSON firing path needs one to read the declared types from. The host
  ## refuses that combination outright rather than handing a handler an empty
  ## payload. The typed frame needs only the shape, which `spec` declares.
  var fn: Il2CppPtr = cast[Il2CppPtr](0)
  let why = verifyTarget(rva, spec, expect, fn)
  if why.len > 0:
    warn "textures  NOT hooking " & spec & ": " & why
    return false
  var pro: array[16, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0]
  discard texReadCode(fn, cast[Il2CppPtr](addr pro[0]), 16'i32)
  info "textures  verified GameAssembly+0x" & rvaHex(rva) &
       " prologue [" & bytesHex(pro) & "] — installing typed postfix"
  let st = hookReturnTyped(spec, handler)
  if st == Ok:
    info "textures  hooked " & spec
    return true
  warn "textures  hookReturnTyped refused " & spec & ": " & lastError()
  result = false

proc runtimeReady(): bool =
  ## THE OLD GATE WAS A LIE, and this is what replaced it.
  ##
  ## It was `findClass(gRt, "UnityEngine.AssetBundle") != nil`, read as "the
  ## metadata is queryable". On build 1.1.0.1.46777 `findClass` returns a
  ## NON-NIL handle into UNMAPPED memory, so that test passed unconditionally
  ## and proved exactly nothing — it could never have been false, whatever the
  ## runtime was doing.
  ##
  ## What is asserted now is only what this mod actually needs, and each part
  ## is something that can genuinely be false:
  ##   * GameAssembly.dll is mapped, and
  ##   * the 16 bytes at the target RVA are committed, readable, and the ones
  ##     this build compiled.
  ##
  ## That is the whole precondition for an RVA patch. Note it says nothing
  ## about metadata: the install no longer needs any. The post-boot quiet
  ## period is enforced separately by the arm delay in `readyToArm`, which is
  ## what actually keeps this off the boot bundle-load storm.
  if not gRt.loaded:
    gRt = openIl2Cpp()
  var fn: Il2CppPtr = cast[Il2CppPtr](0)
  result = verifyTarget(TgtEbLoadRva, TgtEbLoad, EbLoadProlog, fn).len == 0

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

  # The name source, before anything that needs it. `match` and `full` both
  # compare against a NAME table, so a mod that armed without one would match
  # zero and look like a bad manifest. `resolveNameSource` refuses out loud.
  if gMode >= ModeMatch:
    resolveNameSource()

  if gMode >= ModeFull:
    probeUpload()

  var bound = 0
  # THE REAL PATH. `EasyBundle::Load` fired 99 times at the menu alone, where
  # every Unity `AssetBundle` target counted zero across a whole raid, so this
  # is the only target installed by default. Its RVA is unique - the resolver
  # reports no `[SHARED]` annotation - which is what makes it legal to detour
  # at all; `get_Assets` and `get_LoadState`, the intuitive swap points, are
  # shared by 200 and 136 methods respectively and are only ever CALLED, never
  # hooked. Here not even called: the backing field is read directly.
  if installVerifiedTyped(TgtEbLoad, TgtEbLoadRva, EbLoadProlog,
                          onBundleLoad):
    inc bound
  if gHookAsync:
    # Unity's own path, retained behind the opt-in that already existed. Fact
    # #55: zero calls across a full raid on this build. Installing it costs a
    # second detour for no measured benefit, which is why it is off.
    warn "textures  hookAsync is on: also installing the UNITY path " &
         "(AssetBundle::LoadAsset), measured at ZERO calls on this build."
    if installVerifiedTyped(TgtLoadAsset, TgtLoadAssetRva, LoadAssetProlog,
                            onTextureReturn):
      inc bound
    warn "textures  hookAsync is on: AssetBundleRequest::get_asset is a " &
         "tail-jump thunk on this build (48 8B 11 … 48 FF E0). Verifying its " &
         "own prologue before install."
    # Its prologue is a thunk, not the LoadAsset shape; verify against the thunk
    # bytes so a wrong pointer is still refused, but only the caller opting in
    # gets here.
    const ThunkProlog: array[16, uint8] = [
      0x48'u8, 0x8B, 0x11, 0x48, 0x8B, 0x82, 0x78, 0x01,
      0x00,    0x00, 0x48, 0x8B, 0x92, 0x80, 0x01, 0x00]
    if installVerifiedTyped(TgtReqAsset, TgtReqAssetRva, ThunkProlog,
                            onTextureReturn):
      inc bound

  gArmed = bound > 0
  if not gArmed:
    warn "textures  nothing hooked; the mod is a no-op (stock textures)"
    return false

  let haveName = cast[uint](gGetNameFn) != 0'u
  let modeName = (case gMode
                  of ModeProbe: "probe (count only)"
                  of ModeMatch: (if haveName: "match (name-match, no upload)"
                                 else: "match requested but there is NO name source — counting only")
                  of ModeFull:  (if gCanUpload: "full (upload)"
                                 elif haveName: "full requested but upload unavailable — match-only"
                                 else: "full requested but neither upload NOR a name source is available — counting only")
                  else: "off")
  success "textures  ARMED post-boot in mode " & modeName & "; VRAM budget " &
          $(gBudgetBytes div (1024'i64 * 1024'i64)) & " MB"
  result = true

proc swapStats*(): string =
  result = "{\"mode\":" & $gMode &
           ",\"armed\":" & (if gArmed: "true" else: "false") &
           ",\"canUpload\":" & (if gCanUpload: "true" else: "false") &
           ",\"nameSource\":" & (if cast[uint](gGetNameFn) != 0'u: "true" else: "false") &
           ",\"nameFaults\":" & $gNameFaults &
           ",\"tier\":\"" & gTier & "\"" &
           ",\"budgetBytes\":" & $gBudgetBytes &
           ",\"residentBytes\":" & $gResidentBytes &
           ",\"fires\":" & $gFires &
           ",\"ebFires\":" & $gEbFires &
           ",\"noSelf\":" & $gNoSelf &
           ",\"ebUnreadable\":" & $gEbUnreadable &
           ",\"ebFaults\":" & $gEbFaults &
           ",\"ebRetired\":" & (if gEbRetired: "true" else: "false") &
           ",\"assetsNull\":" & $gAssetsNull &
           ",\"assetsEmpty\":" & $gAssetsEmpty &
           ",\"assetsPopulated\":" & $gAssetsPopulated &
           ",\"assetsWalked\":" & $gAssetsWalked &
           ",\"albedoOnly\":" & (if gAlbedoOnly: "true" else: "false") &
           ",\"refusedNonAlbedo\":" & $gRefusedNonAlbedo &
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
