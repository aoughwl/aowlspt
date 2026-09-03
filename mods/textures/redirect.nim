## redirect.nim — BUNDLE FILE REDIRECT. The mechanism that can actually work on
## this build, replacing the name-keyed Texture2D substitution in `swap.nim`.
##
## ---------------------------------------------------------------------------
## WHY THE OLD DESIGN IS RETIRED
## ---------------------------------------------------------------------------
##
## `swap.nim` hooked `EasyBundle::Load` and swapped `Texture2D` objects BY NAME.
## Three independent measurements kill that (facts #64, #65, #82):
##
##  1. **Nothing ever asks for a texture by name.** The chain is
##     `ObjectsFactory.LoadBundlesAndCreatePools -> EasyAssets.RetainSeparateTask
##     -> EasyBundle.Load() -> LoadingCoroutine() -> AssetBundle.LoadFromFileAsync
##     + LoadAllAssetsAsync -> Assets = op.allAssets`. A BULK ARRAY, never a name
##     lookup. A name-keyed substitution has no hook to attach to at any point.
##  2. **In-place decode is a false premise.** `Texture2D.LoadImage` returns
##     FALSE on a non-readable texture and RE-CREATES rather than mutating, so
##     "decode into the returned Texture2D so every material updates" was never
##     true. `Graphics.CopyTexture` is the only real in-place path and demands
##     identical format + size + mips.
##  3. **VRAM.** RGBA32 replacements are 4-8x the BC originals; 512 x 2K RGBA32
##     is about 5.6 GB.
##
## And fact #77: `EasyBundle::Load` does not populate `<Assets>` at all -- it is
## async, and the real write happens in `MoveNext`, which nulls `<>4__this` on
## completion. The old hook was aimed at something that could not have worked
## twice over.
##
## ---------------------------------------------------------------------------
## WHAT THIS DOES INSTEAD: REDIRECT THE BUNDLE FILE
## ---------------------------------------------------------------------------
##
## Exactly what SPT's `spt-custom.dll` does on 4.1.2: make a vanilla bundle key
## resolve to OUR patched file on disk, by rewriting `EasyBundle._path` before
## anything reads it. The game then loads a whole patched bundle through its own
## unmodified pipeline -- correct compression, correct mips, correct colour
## space, no VRAM blow-up, and no per-asset work of any kind.
##
## ---------------------------------------------------------------------------
## WHY THE HOOK IS `Load()` AND NOT THE CONSTRUCTOR
## ---------------------------------------------------------------------------
##
## THE BRIEF ASKED FOR A PREFIX ON `.ctor`. That is not implementable from mod
## code on this host, and both halves of the reason were measured, not guessed:
##
##  * `Diz.Resources.EasyBundle::.ctor` is rid=41 @ 0x2772940, arity **5**:
##    `void .ctor(string key, string rootPath, CompatibilityAssetBundleManifest
##    manifest, IBundleLock bundleLock, Func<string,Task> bundleCheck)`
##    (`il2cpp_resolve.py ... type 30933 --shared`; no `[SHARED]` annotation, so
##    the RVA is genuinely its own).
##  * A **postfix** on it is refused by the host twice over -- `rvaPostfixRefusal`
##    rejects any declared argument that lands on the stack (arguments 3 and 4
##    do), and separately rejects a compiled call using more than
##    `PostfixMaxSlots` register slots (this one uses 7: five arguments, `this`,
##    and IL2CPP's trailing `MethodInfo*`).
##  * A **prefix** installs fine, but could not do the job: the frame ABI in
##    `abi/aowlspt_frame.h` exposes `aowl_frame_set_ret_*` and **no**
##    `aowl_frame_set_arg_*`. A prefix therefore cannot rewrite the `rootPath`
##    argument, and it cannot write `_path` either -- at prefix time the ctor has
##    not run, so anything stored there is about to be overwritten by the ctor
##    itself.
##
## So the redirect moves to the next point where `_path` is populated and still
## unread: a **PREFIX on `Diz.Resources.EasyBundle::Load`**, rid=42 @ 0x2772CC0,
## arity 0, instance, void -> shape `i>x`. This is strictly better here:
##
##  * `_path` (+0x20) is fully populated -- the ctor wrote it.
##  * A prefix runs BEFORE any of `Load`'s body, so whatever `Load` and the
##    `LoadingCoroutine` it starts do with `_path`, they see OUR value. That is
##    airtight regardless of where inside the chain the read happens.
##  * `this` is in RCX and comes off the frame via `selfPointer` -- no argument
##    write is needed at all, which is the capability the host does not have.
##  * The RVA is not shared (`get_Assets` @0x6864D0 is shared by 200 methods and
##    `get_LoadState` @0x690D20 by 136 -- this family has real traps in it, and
##    `Load` is not one of them).
##  * It is the same RVA the old postfix used, whose prologue was already
##    verified live, and it fired 99 times AT THE MENU alone (fact #55/#74), so
##    exercising this needs no raid.
##
## The cost, stated rather than hidden: a bundle constructed but never `Load`ed
## is never redirected. That is not a behaviour change -- an unloaded bundle
## reads no file either way.
##
## ---------------------------------------------------------------------------
## THE VERBATIM-NAME RULE
## ---------------------------------------------------------------------------
##
## The on-disk file MUST be named EXACTLY like the key. Fact #73, measured on
## 4.1.2: 214 of 292 in-scope keys have **no `.bundle` extension**, and appending
## one made those bundles silently unfindable -- the first build had 214 of 278
## dead with no error at all. So this module NEVER normalises a key, never
## lowercases one, and never appends or strips an extension. `path = bundleRoot
## & "/" & key`, and nothing else.
##
## ---------------------------------------------------------------------------
## THE LADDER (kept from `swap.nim`, repointed at bundle KEYS)
## ---------------------------------------------------------------------------
##
##   off    install nothing at all. The default.
##   probe  install the verified prefix and COUNT firings only. Proves the
##          install and the firing are safe with zero per-bundle work.
##   match  also read `<Key>` and look it up in the table. Counts hits and
##          samples misses. Still writes nothing.
##   full   also rewrite `_path`. This is the only rung that changes the game.
##
## Escalate one rung at a time. The unmatched-key sampler is the whole point of
## `match`: it is how we learn what the game ACTUALLY asks for, rather than what
## an offline pipeline guessed it would.

import std/syncio
import aowlspt
import aowlspt/game
import aowlspt/il2cpp

const
  ## `Diz.Resources.EasyBundle::Load`, rid=42 of type 30933 (image
  ## Diz.Resources.dll), arity 0, instance, returns void -> shape `i>x`.
  ##
  ## Resolved with `tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll
  ## .cache/global-metadata.dec.dat type 30933 --shared`, which reports NO
  ## `[SHARED: ...]` annotation for it: this RVA belongs to exactly one method.
  ##
  ## Prologue `48 89 5C 24 10 57 48 81 EC 90 00 00 00 48 8B D9` =
  ## `mov [rsp+0x10],rbx ; push rdi ; sub rsp,0x90 ; mov rbx,rcx` -- ordinary,
  ## non-RIP-relative frame setup, which is what makes the detour engine's
  ## steal-and-relocate safe. Cross-checked byte-for-byte with
  ## `il2cpp_resolve.py ... bytes 0x2772cc0 16`. Handed to the host in the spec
  ## so it compares against its STARTUP SNAPSHOT of the original bytes rather
  ## than against live memory -- the only compare that still gives the right
  ## answer if another feature detoured this function first.
  ##
  ## The shape is DECLARED even though this is a prefix: `parseRvaSpec` refuses
  ## an empty shape unconditionally (fact #54), prefix or not.
  TgtEbLoad* = "Diz.Resources.EasyBundle::Load@0x2772CC0/i>x" &
               "!48895C2410574881EC90000000488BD9"
  TgtEbLoadRva* = 0x2772CC0'u32
  EbLoadProlog*: array[16, uint8] = [
    0x48'u8, 0x89, 0x5C, 0x24, 0x10, 0x57, 0x48, 0x81,
    0xEC,    0x90, 0x00, 0x00, 0x00, 0x48, 0x8B, 0xD9]

  ## `Diz.Resources.EasyBundle` instance field offsets, from
  ## `Il2CppMetadataRegistration.fieldOffsets` (@0x186B61E70) via
  ## `tools/il2cpp_resolve.py ... fields Diz.Resources.EasyBundle`. Fact #82.
  ## Not one of these is guessed.
  ##
  ##   0x10 _keyWithoutExtension  string
  ##   0x18 _bundleLock           IBundleLock
  ##   0x20 _path                 string     <-- REWRITTEN
  ##   0x28 <DependencyKeys>      IEnumerable<string>
  ##   0x30 <Key>                 string     <-- READ (the lookup key)
  ##   0x38 _bundle               AssetBundle
  ##   0x48 <Assets>              Object[]
  EbPathOff = 0x20'u
  EbKeyOff  = 0x30'u

  ## `System.String`, 64-bit: `Il2CppObject{klass, monitor}` is 16 bytes, then
  ## `length` (int32) at 0x10 and the UTF-16 characters at 0x14. A raw
  ## static-offset read, which is one of the three things that still works here.
  StrLenOff  = 0x10'u
  StrCharOff = 0x14'u

  ## A cap, not an expectation. `length` is read out of the object, and a
  ## corrupt one must be a short key rather than a walk off the end of the heap.
  MaxKeyChars = 256

  ## How many distinct keys the lazy prober will ever remember. A bound on both
  ## the table and, with it, on how many `open()` probes one session can do.
  MaxLazyKeys = 4096

  ## Hard cap on the index file, so a wrong `bundleRoot` pointed at something
  ## enormous is a refusal rather than a session-ending read.
  MaxIndexLines = 8192

  MaxUnmatchedLogged = 40

  ## Self-disable, rule 6. A hop that has come back unreadable this many times
  ## is not a transient, and repeating it for every bundle load for the rest of
  ## the session is exactly the failure mode the rule exists to stop.
  MaxFaults = 16

  ModeOff* = 0
  ModeProbe* = 1
  ModeMatch* = 2
  ModeFull* = 3

# ---------------------------------------------------------------------------
# Native shims
# ---------------------------------------------------------------------------
#
# Named `aowl_bre_*` (Bundle REdirect) so they cannot collide with `swap.nim`'s
# `aowl_tex_*` shims when both modules land in the same compilation unit.
{.emit: """
#include <windows.h>
#include <string.h>
/* THE TYPED STORE PATH (docs/INTERACTION-LAYER-MAP.md M3/M6). `aowlspt_hostwrite.h`
 * pulls in the GENERATED `aowlspt_fieldrefs.h`, which carries
 * Diz.Resources.EasyBundle._path's offset, WIDTH and IS_REFERENCE straight out
 * of Il2CppMetadataRegistration.fieldOffsets. Everything it declares is static,
 * so including it here costs this module nothing it does not call. */
#include "aowlspt_hostwrite.h"

/* Committed-and-readable, out to `n` bytes, without leaving the region the
 * query answered for. Every dereference on this path goes through it: `this`
 * -> `<Key>` -> the character run is THREE hops and therefore three checks,
 * not one. */
static int aowl_bre_readable(const void* p, int n) {
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

/* The same, but the region must also be WRITABLE. Separate from the read check
 * on purpose: `_path` is the one address this module stores to, and rule 8 says
 * read-validate-then-write or do not write. A managed object field is in a
 * read/write GC region; if this ever answers 0 the store is refused rather than
 * attempted. */
static int aowl_bre_writable(const void* p, int n) {
  MEMORY_BASIC_INFORMATION mbi;
  const DWORD rw = PAGE_READWRITE | PAGE_WRITECOPY |
                   PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
  if (!p || n <= 0) return 0;
  if (!VirtualQuery(p, &mbi, sizeof(mbi))) return 0;
  if (mbi.State != MEM_COMMIT) return 0;
  if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
  if (!(mbi.Protect & rw)) return 0;
  {
    unsigned long long end = (unsigned long long)mbi.BaseAddress + mbi.RegionSize;
    return ((unsigned long long)p + (unsigned long long)n <= end) ? 1 : 0;
  }
}

static int aowl_bre_readmem(const void* p, unsigned char* out, int n) {
  if (!aowl_bre_readable(p, n)) return 0;
  memcpy(out, p, (size_t)n);
  return n;
}

static void* aowl_bre_readptr(const void* p) {
  if (!aowl_bre_readable(p, 8)) return 0;
  return *(void* const*)p;
}

static int aowl_bre_readi32(const void* p, int* out) {
  if (!aowl_bre_readable(p, 4)) return 0;
  *out = *(const int*)p;
  return 1;
}

/* THE ONLY WRITE THIS MODULE MAKES. A single aligned 8-byte reference store
 * into a managed object field.
 *
 * No GC write barrier is issued and none is needed: IL2CPP on this build uses
 * the Boehm collector, which is non-moving and fully conservative, so an
 * ordinary store of a reference into a heap object is exactly what the runtime
 * itself compiles for `this->_path = v`. The same conservatism is what makes
 * the newly-allocated string safe between `il2cpp_string_new` and this store --
 * it is live in a register/stack slot Boehm scans. */
static int aowl_bre_writeptr(void* p, void* v) {
  if (!aowl_bre_writable(p, 8)) return 0;
  *(void**)p = v;
  return 1;
}

/* GameAssembly.dll's ACTUAL base, asked for at runtime. 0x180000000 is the PE
 * PREFERRED base -- the space il2cpp_resolve.py reports RVAs in -- and the
 * module is ASLR-relocated in the live process. Never hardcode it. */
static void* aowl_bre_rva(unsigned int rva) {
  HMODULE ga = GetModuleHandleA("GameAssembly.dll");
  if (!ga) return NULL;
  return (void*)((unsigned char*)ga + rva);
}
""".}

proc breReadable(p: Il2CppPtr; n: int32): int32 {.importc: "aowl_bre_readable", nodecl.}
proc breReadMem(p, outp: Il2CppPtr; n: int32): int32 {.importc: "aowl_bre_readmem", nodecl.}
proc breReadPtr(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_bre_readptr", nodecl.}
proc breReadI32(p: Il2CppPtr; outv: ptr int32): int32 {.importc: "aowl_bre_readi32", nodecl.}
proc breWritePtr(p, v: Il2CppPtr): int32 {.importc: "aowl_bre_writeptr", nodecl.}
# The typed path. `breWritePtr` above is now used ONLY by this module's own
# host-owned scratch, never on the managed heap -- `tools/storelint.py` fails
# the build if a raw store into game memory reappears outside these helpers.
# Bound through the GENERATED per-row accessor, never as `(&AOWL_FR_EB_PATH)`:
# `importc` on a proc emits a CALL, so that spelling compiles to
# `(&AOWL_FR_EB_PATH)()` and gcc refuses it (measured 2026-09-03).
type FieldRefPtr = Il2CppPtr
proc frEbPath(): FieldRefPtr {.importc: "aowl_fr_eb_path", nodecl.}
proc frAdmit(fr, recv: FieldRefPtr): int32 {.importc: "aowl_fr_admit", nodecl.}
proc frStorePtr(fr, recv: FieldRefPtr; sub: int32; v: Il2CppPtr;
                why: var int32): int32 {.importc: "aowl_fr_store_ptr", nodecl.}
proc frOff(fr: FieldRefPtr): int32 {.importc: "aowl_fr_off", nodecl.}
proc breRva(rva: uint32): Il2CppPtr {.importc: "aowl_bre_rva", nodecl.}

proc at(p: Il2CppPtr; off: uint): Il2CppPtr =
  ## `p + off` as a pointer. Never dereferences; the caller's guarded read does.
  result = cast[Il2CppPtr](cast[uint](p) + off)

proc chStr(c: char): string =
  ## One `char` as a `string`. Nimony's `system` has no `$` for `char` -- it
  ## resolves to the generic `$`, which rejects it against every constraint --
  ## so this is the local one-character constructor every string build below
  ## goes through.
  result = newString(1)
  result[0] = c

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

proc rvaHex(v: uint32): string =
  ## An RVA as bare hex. Local because Nimony's strutils has no `toHex`.
  const D = "0123456789ABCDEF"
  var x = v
  if x == 0'u32:
    return "0"
  var buf = ""
  while x != 0'u32:
    buf = buf & chStr(D[int(x and 0xF'u32)])
    x = x shr 4
  result = ""
  for i in countdown(buf.len - 1, 0):
    result = result & chStr(buf[i])

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var gMode = ModeOff
var gArmed = false
var gArmTried = false
var gArmDelayMs = 15000'i64
var gLoadedAtMs = 0'i64
var gBundleRoot = ""

var gRt = Il2Cpp(handle: cast[Il2CppPtr](0), loaded: false, lastError: 0'i32,
                 missing: @[])
var gCanAllocString = false

## THE KEY -> PATH TABLE.
##
## Two ways to populate it, because the pack pipeline is another agent's and its
## exact output contract is not settled:
##
##  1. **An index**, `<bundleRoot>/index.txt`: one bundle key per line, VERBATIM,
##     read once at arm time. Preferred -- after arming there is no filesystem
##     I/O on the hook path at all, which is what "no per-frame work" actually
##     requires. Blank lines and `#` comments are skipped; nothing else about a
##     line is interpreted, so a key containing spaces or dots survives intact.
##  2. **Lazy probe with a cache**, when there is no index: the first time a key
##     is seen, ONE `open()` decides whether `<bundleRoot>/<key>` exists, and the
##     answer -- hit OR miss -- is remembered forever. Capped at `MaxLazyKeys`
##     distinct keys, which also caps how many probes a session can ever do.
##
## Either way the steady state is a pure in-memory lookup, and a MISS is the
## overwhelmingly common answer: this fires for every bundle the game loads and
## everything we have no replacement for must pass through untouched.
var gKeys: seq[string] = @[]
var gHit: seq[bool] = @[]
var gFromIndex = false

var gFires: int64 = 0
var gNoSelf: int64 = 0
var gUnreadable: int64 = 0
var gNoKey: int64 = 0
var gLookups: int64 = 0
var gHits: int64 = 0
var gMisses: int64 = 0
var gRedirected: int64 = 0
var gAllocFailed: int64 = 0
var gWriteRefused: int64 = 0
var gLastRedirect = ""

var gFaults = 0
var gRetired = false
var gUnmatchedLogged = 0
var gSaidFirstRedirect = false

proc redirectArmed*(): bool = gArmed
proc redirectModeInt*(): int = gMode
proc redirectTableSize*(): int = gKeys.len
proc bundleRoot*(): string = gBundleRoot

proc modeFromText(s: string): int =
  case s
  of "probe": ModeProbe
  of "match": ModeMatch
  of "full":  ModeFull
  else:       ModeOff

# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------

proc findKey(k: string): int =
  ## Linear scan. Deliberately not a hash: the table is a few hundred entries at
  ## most, the comparison fails on the first character for almost all of them,
  ## and a linear scan over a `seq` has no failure mode a hand-rolled hash over
  ## game-supplied keys would have. Bounded by `gKeys.len`, which is bounded by
  ## `MaxLazyKeys` / `MaxIndexLines`.
  result = -1
  for i in 0 ..< gKeys.len:
    if gKeys[i] == k:
      return i

proc fileReadable(path: string): bool =
  ## Existence, by the one filesystem primitive this codebase already uses
  ## (`std/syncio`). No `std/os` dependency is added for a question `open()`
  ## already answers.
  var f: File
  if not open(f, path, fmRead):
    return false
  close(f)
  result = true

proc pathFor*(key: string): string =
  ## `<bundleRoot>/<key>`, VERBATIM. No lowercasing, no normalisation, no
  ## extension appended or stripped -- see the verbatim-name rule at the top of
  ## this file. Fact #73: appending `.bundle` silently killed 214 of 278.
  result = gBundleRoot & "/" & key

proc loadIndex(): bool =
  ## Read `<bundleRoot>/index.txt` into the table. Returns false when there is
  ## no index, which is not an error -- it selects the lazy prober instead.
  gKeys = @[]
  gHit = @[]
  let idx = gBundleRoot & "/index.txt"
  var f: File
  if not open(f, idx, fmRead):
    return false
  var n = 0
  var line = ""
  while n < MaxIndexLines and readLine(f, line):
    inc n
    # Trim only ASCII whitespace and a stray CR -- never anything else, because
    # a key may legitimately contain dots and spaces.
    var a = 0
    var b = line.len - 1
    while a <= b and (line[a] == ' ' or line[a] == '\t'):
      inc a
    while b >= a and (line[b] == ' ' or line[b] == '\t' or
                      line[b] == '\r' or line[b] == '\n'):
      dec b
    if b < a:
      continue
    let key = substr(line, a, b)
    if key.len == 0 or key[0] == '#':
      continue
    if findKey(key) >= 0:
      continue
    gKeys.add key
    gHit.add true
  close(f)
  if n >= MaxIndexLines:
    warn "textures  bundleRoot index.txt stopped at the " & $MaxIndexLines &
         "-line cap; keys past it are NOT in the table"
  gFromIndex = true
  result = true

proc tableAnswer(key: string): int =
  ## -1 for "no replacement, pass through untouched"; otherwise the table index.
  ##
  ## With an index this never touches the filesystem. Without one it probes at
  ## most once per distinct key, ever, and caches the miss as hard as the hit --
  ## a miss that is not cached is a file open on every single bundle load.
  let i = findKey(key)
  if i >= 0:
    return (if gHit[i]: i else: -1)
  if gFromIndex:
    return -1                 # the index is authoritative; no probing
  if gKeys.len >= MaxLazyKeys:
    return -1                 # the cap is a refusal, not a silent re-probe
  let ok = fileReadable(pathFor(key))
  gKeys.add key
  gHit.add ok
  result = (if ok: gKeys.len - 1 else: -1)

# ---------------------------------------------------------------------------
# Reading the key
# ---------------------------------------------------------------------------

proc readManagedString(sp: Il2CppPtr): string =
  ## A `System.String` read raw, with every hop guarded and the character loop
  ## capped. NO call into game code: `get_Key` @0x6F1680 is shared by 280
  ## methods, so it is never hooked and here not even called -- the backing
  ## field is read directly.
  ##
  ## Returns "" for every failure. The caller treats "" as "no key available"
  ## and NEVER as "the key is empty".
  result = ""
  if cast[uint](sp) == 0'u:
    return
  if breReadable(sp, 20'i32) == 0'i32:
    return
  var lenB: int32 = 0
  if breReadI32(at(sp, StrLenOff), addr lenB) == 0'i32:
    return
  var n = int(lenB)
  if n <= 0:
    return
  if n > MaxKeyChars:
    n = MaxKeyChars
  # The WHOLE character run must be committed before ANY of it is read.
  if breReadable(at(sp, StrCharOff), int32(n * 2)) == 0'i32:
    return
  var chars = newSeq[uint8](n * 2)
  if breReadMem(at(sp, StrCharOff), cast[Il2CppPtr](addr chars[0]),
                int32(n * 2)) != int32(n * 2):
    return
  # Bundle keys are ASCII in practice. Anything above 0x7F becomes '?' rather
  # than being dropped, so a key that does not match still LOOKS like the key it
  # is in the unmatched sample -- which is the entire value of that sample.
  for k in 0 ..< n:
    let w = int(chars[k * 2]) or (int(chars[k * 2 + 1]) shl 8)
    if w >= 0x20 and w < 0x7F:
      result = result & chStr(char(w))
    elif w == 0:
      break
    else:
      result = result & "?"

proc fault(): bool =
  ## Count one unreadable hop; return true once the path has retired itself.
  inc gFaults
  if gFaults >= MaxFaults and not gRetired:
    gRetired = true
    warn "textures  bundle redirect RETIRED after " & $MaxFaults &
         " unreadable hops (self-disable, rule 6). The hook stays installed " &
         "and keeps counting firings; it will not dereference or write again " &
         "this session. See unreadable/noSelf in redirectStats."
  result = gRetired

# ---------------------------------------------------------------------------
# The prefix
# ---------------------------------------------------------------------------

proc onBundleLoad(frame: PatchFrame): TypedResult =
  ## Fires BEFORE `Diz.Resources.EasyBundle::Load` runs, on the Unity thread.
  ##
  ## `Load` is void and arity 0 (`i>x`), so there is nothing to read but `this`,
  ## which comes out of the frame's own RCX via `selfPointer` -- no GC handle,
  ## no call, no allocation.
  ##
  ## Fact #19: a caught fault unwinds the ENTIRE guarded body silently, so every
  ## counter this wants incremented is incremented BEFORE the step that could
  ## fault, or not at all. There is exactly ONE guarded body -- the host's --
  ## and this adds no `aowl_p_p_seh` of its own, because that guard is NOT
  ## re-entrant and a nested one would DISARM the outer.
  ##
  ## It always returns `frameContinue()`. This hook never suppresses the
  ## original; it only changes one field the original is about to read.
  inc gFires
  if gMode <= ModeProbe or gRetired:
    return frameContinue()

  let self = selfPointer(frame)
  if self == 0'u64:
    inc gNoSelf
    discard fault()
    return frameContinue()
  let eb = cast[Il2CppPtr](self)

  # Hop 1: the instance, committed out to past the furthest field touched.
  if breReadable(eb, int32(EbKeyOff + 8'u)) == 0'i32:
    inc gUnreadable
    discard fault()
    return frameContinue()

  # Hop 2: `<Key>k__BackingField` -> the string object. Hop 3 is inside
  # `readManagedString`, which guards the header and the character run
  # separately.
  let key = readManagedString(breReadPtr(at(eb, EbKeyOff)))
  if key.len == 0:
    inc gNoKey
    return frameContinue()

  inc gLookups
  let idx = tableAnswer(key)
  if idx < 0:
    # PASS THROUGH UNTOUCHED. This is the overwhelmingly common path -- the hook
    # runs for every bundle the game loads and we have a replacement for very
    # few of them.
    inc gMisses
    # The single most useful thing one live run can tell us: what BSG actually
    # NAMES the bundles it loads. Hard-capped sample, never a storm.
    if gUnmatchedLogged < MaxUnmatchedLogged:
      inc gUnmatchedLogged
      info "textures  unmatched sample " & $gUnmatchedLogged & "/" &
           $MaxUnmatchedLogged & ": \"" & key & "\""
      if gUnmatchedLogged == MaxUnmatchedLogged:
        info "textures  unmatched sampling stopped at " &
             $MaxUnmatchedLogged & " keys (the cap); counts keep running"
    return frameContinue()

  inc gHits
  if gMode < ModeFull:
    # `match`: the table hit is proven and counted, and nothing is written. This
    # is observable evidence the lookup half works ahead of changing the game.
    return frameContinue()
  if not gCanAllocString:
    inc gAllocFailed
    return frameContinue()

  # RULE 8, NEVER BLIND-WRITE. Read the existing `_path` and require it to be a
  # plausible live `System.String` before replacing it. If this object does not
  # already hold a readable string there, our model of the layout is wrong and
  # the right move is to write nothing.
  let oldPath = breReadPtr(at(eb, EbPathOff))
  if cast[uint](oldPath) == 0'u or breReadable(oldPath, 20'i32) == 0'i32:
    inc gWriteRefused
    discard fault()
    return frameContinue()

  # The allocation. This is NOT per-frame: it happens only on a genuine
  # redirect, which is bounded by the size of the table and by how many bundles
  # the game loads. Every pass-through -- the common case -- allocates nothing
  # at all.
  #
  # A fresh string each time rather than a cached pointer, deliberately: a raw
  # `Il2CppString*` cached across frames is a bare address the mod would be
  # asserting stays valid, and "it is probably fine because Boehm does not move"
  # is not a guarantee worth building on. Between this call and the store the
  # string is live in a stack slot, which the conservative collector scans.
  let sp = newString(gRt, pathFor(key))
  if cast[uint](sp) == 0'u:
    inc gAllocFailed
    return frameContinue()
  # THE TYPED STORE. Reading the old slot back and requiring a readable string
  # (above) was the best guard in the tree at the time of the write audit, and
  # it is still not sufficient: it tests the CONTENTS, not the declared type,
  # and on the IL2CPP GC heap a stale pointer into recycled memory can hold a
  # readable string belonging to something else entirely.
  #
  # `AOWL_FR_EB_PATH` is generated from the metadata and says `_path` is an
  # 8-byte managed REFERENCE, so R1 refuses any narrower store into it -- the
  # producer of the 0x00000000FFFFFFFF that killed the liveness walk. `eb` is
  # RCX of the EasyBundle method this drain rides, so its type is a fact and
  # admitting its klass here is legitimate rather than circular.
  discard frAdmit(frEbPath(), eb)
  var frWhy = 0'i32
  if frStorePtr(frEbPath(), eb, 0'i32, sp, frWhy) == 0'i32:
    inc gWriteRefused
    # Capped so a per-bundle path cannot flood the log. The REFUSAL is never
    # capped -- only the sentence about it.
    if gWriteRefused <= 4'i64:
      warn "textures  REFUSED: the typed store into Diz.Resources.EasyBundle." &
           "_path (+0x" & $frOff(frEbPath()) & ") was refused with rule code " &
           $frWhy & " (1=narrow-into-reference 2=too-wide 3=klass-not-admitted " &
           "4=receiver 5=bound 6=unusable FieldRef). Nothing was written; the " &
           "bundle loads from its stock path."
    discard fault()
    return frameContinue()

  inc gRedirected
  gLastRedirect = key
  if not gSaidFirstRedirect:
    gSaidFirstRedirect = true
    info "textures  REDIRECT: first bundle redirected — key \"" & key &
         "\" now loads from \"" & pathFor(key) & "\" (EasyBundle._path " &
         "rewritten at +0x20 before Load read it). Further redirects are " &
         "counted, not logged."
  elif (gRedirected mod 25'i64) == 0'i64:
    info "textures  REDIRECT: " & $gRedirected & " bundles redirected so far " &
         "(last \"" & key & "\")"
  result = frameContinue()

# ---------------------------------------------------------------------------
# Target verification
# ---------------------------------------------------------------------------

proc verifyTarget(rva: uint32; label: string; expect: array[16, uint8];
                  outFn: var Il2CppPtr): string =
  ## Resolve the RVA against the LIVE module base and byte-compare its prologue
  ## HERE, before asking the host to patch it.
  ##
  ## Deliberately duplicated work -- the host re-verifies the same 16 bytes
  ## against its own startup SNAPSHOT of the original code, which is the
  ## authoritative compare -- but this one is what stops the mod from ever
  ## handing `hookTyped` an address it has not itself looked at.
  ##
  ## Resolution is by RVA and NOT by name: `findClass`/`findMethod` return
  ## non-nil handles into unmapped memory on this build, so `methodPointer`
  ## reads null and there is nothing to verify.
  ##
  ## One caveat stated rather than hidden: this reads LIVE memory, so it is only
  ## correct because nothing else detours `EasyBundle::Load` -- and the legacy
  ## `swap.nim` postfix on the SAME RVA is exactly that hazard, which is why
  ## `textures.nim` refuses to arm both.  If that is ever violated this compare
  ## reads a trampoline and refuses a correct RVA.
  outFn = cast[Il2CppPtr](0)
  let fn = breRva(rva)
  if cast[uint](fn) == 0'u:
    return "GameAssembly.dll is not mapped (GetModuleHandleA returned NULL), " &
           "so there is no base to add 0x" & rvaHex(rva) & " to"
  var buf: array[16, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0]
  if breReadMem(fn, cast[Il2CppPtr](addr buf[0]), 16'i32) != 16'i32:
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

# ---------------------------------------------------------------------------
# Configuration and arming
# ---------------------------------------------------------------------------

proc configureRedirect*(mode: string; root: string; armDelayMs: int) =
  ## Records what the mod will do, without doing any of it. Called from onLoad;
  ## the install is deferred to `maybeArmRedirect` on a later frame, well past
  ## the boot bundle-load storm.
  ##
  ## `bundleRoot` empty means the feature is OFF whatever `mode` says. There is
  ## no default directory: a redirect with nowhere to redirect TO would probe
  ## every key against a path that cannot exist, which is a slow no-op that
  ## looks like a working feature.
  gBundleRoot = root
  gArmDelayMs = int64(armDelayMs)
  gLoadedAtMs = nowMs()
  if root.len == 0:
    gMode = ModeOff
    return
  gMode = modeFromText(mode)

proc redirectEnabled*(): bool = gMode != ModeOff

proc readyToArm(): bool =
  if gMode == ModeOff:
    return false
  if nowMs() - gLoadedAtMs < gArmDelayMs:
    return false
  if not gRt.loaded:
    gRt = openIl2Cpp()
  var fn: Il2CppPtr = cast[Il2CppPtr](0)
  # The whole precondition for an RVA patch, and every part of it can genuinely
  # be false: GameAssembly.dll is mapped, and the 16 bytes at the target are
  # committed, readable, and the ones this build compiled. Nothing about
  # metadata is asserted, because the install needs none.
  result = verifyTarget(TgtEbLoadRva, TgtEbLoad, EbLoadProlog, fn).len == 0

proc maybeArmRedirect*(): bool =
  ## Called every tick from onUpdate. Installs the verified prefix exactly once,
  ## and only when it is safe to. If verification refuses it does NOT retry --
  ## one honest refusal, not a per-tick log storm.
  if gArmed or gArmTried:
    return false
  if not readyToArm():
    return false
  gArmTried = true

  # The table, built ONCE here rather than on the hook path.
  if loadIndex():
    info "textures  bundleRoot index: " & $gKeys.len & " key(s) from " &
         gBundleRoot & "/index.txt — no filesystem I/O on the hook path"
    if gKeys.len == 0:
      warn "textures  the index is EMPTY, so every key misses and the " &
           "redirect is a NO-OP. That is a refusal, not a zero-hit result."
  else:
    info "textures  bundleRoot has no index.txt; falling back to LAZY " &
         "probing of " & gBundleRoot & "/<key> (one open() per distinct key, " &
         "cached hit AND miss, capped at " & $MaxLazyKeys & " keys)"

  # `il2cpp_string_new` is the only runtime entry point this needs, and only on
  # the `full` rung. Its absence is a refusal that SAYS SO, never a silent
  # degradation to counting.
  gCanAllocString = gRt.loaded and gRt.has(eStringNew)
  if gMode >= ModeFull and not gCanAllocString:
    warn "textures  the runtime has no il2cpp_string_new, so `full` cannot " &
         "write a path — running MATCH-ONLY (counting hits, writing nothing)."

  var fn: Il2CppPtr = cast[Il2CppPtr](0)
  let why = verifyTarget(TgtEbLoadRva, TgtEbLoad, EbLoadProlog, fn)
  if why.len > 0:
    warn "textures  NOT hooking " & TgtEbLoad & ": " & why
    return false
  var pro: array[16, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0]
  discard breReadMem(fn, cast[Il2CppPtr](addr pro[0]), 16'i32)
  info "textures  verified GameAssembly+0x" & rvaHex(TgtEbLoadRva) &
       " prologue [" & bytesHex(pro) & "] — installing typed PREFIX"

  # `hookTyped`, not `hookReturnTyped`: a PREFIX runs before any of `Load`'s
  # body, so the rewritten `_path` is what `Load` and the `LoadingCoroutine` it
  # starts will read. A postfix would be too late and, on the ctor, refused
  # outright (see the header).
  let st = hookTyped(TgtEbLoad, onBundleLoad)
  if st != Ok:
    warn "textures  hookTyped refused " & TgtEbLoad & ": " & lastError()
    return false
  info "textures  hooked " & TgtEbLoad

  gArmed = true
  let modeName = (case gMode
                  of ModeProbe: "probe (count bundle loads only)"
                  of ModeMatch: "match (key lookup, NOTHING written)"
                  of ModeFull:  (if gCanAllocString:
                                   "full (rewriting EasyBundle._path)"
                                 else:
                                   "full requested but il2cpp_string_new is " &
                                   "unavailable — match-only")
                  else: "off")
  success "textures  ARMED post-boot in mode " & modeName & "; bundle redirect " &
          "table has " & $gKeys.len & " key(s), root " & gBundleRoot
  result = true

proc redirectStats*(): string =
  result = "{\"kind\":\"bundleRedirect\"" &
           ",\"mode\":" & $gMode &
           ",\"armed\":" & (if gArmed: "true" else: "false") &
           ",\"root\":\"" & gBundleRoot & "\"" &
           ",\"fromIndex\":" & (if gFromIndex: "true" else: "false") &
           ",\"tableKeys\":" & $gKeys.len &
           ",\"canAllocString\":" & (if gCanAllocString: "true" else: "false") &
           ",\"fires\":" & $gFires &
           ",\"noSelf\":" & $gNoSelf &
           ",\"unreadable\":" & $gUnreadable &
           ",\"noKey\":" & $gNoKey &
           ",\"faults\":" & $gFaults &
           ",\"retired\":" & (if gRetired: "true" else: "false") &
           ",\"lookups\":" & $gLookups &
           ",\"hits\":" & $gHits &
           ",\"misses\":" & $gMisses &
           ",\"redirected\":" & $gRedirected &
           ",\"allocFailed\":" & $gAllocFailed &
           ",\"writeRefused\":" & $gWriteRefused &
           ",\"lastRedirect\":\"" & gLastRedirect & "\"}"
