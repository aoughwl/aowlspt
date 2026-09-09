## The client half: counting the bots that actually arrived.
##
## ---------------------------------------------------------------------------
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------------
##
## Until this file, MoreBots' client half was one `info` line saying that
## nothing could run on the client, and then nothing ran. That line was true
## about the *original* client half -- the prepatcher that appended members to
## `EFT.WildSpawnType` and the nine Harmony patches -- and it was being used as
## a reason to do nothing at all, which is a different claim and a false one.
## It was not even wholly true about the nine: one of them is ported now, as
## `bots/deaths.nim`, once it turned out that the sentence blocking eight of
## them -- that a hook is not told which instance it fired on -- had never been
## true. See `bots/instance.nim`.
##
## The question MoreBots exists to answer is "did the bots I asked for actually
## show up?", and on this side of the ABI that question is answerable. The
## server writes spawn tables and bot caps; whether the client honoured them is
## a fact about a live raid, and the only place it can be observed is in the
## client's process. So that is what this does: once every few seconds it walks
## the world's alive-player list, counts the AI, reads each one's spawn type and
## distance from the player, and reports.
##
## It is a **read-only** census. It moves no bot, changes no hostility and
## writes nothing into the game. Everything MoreBots would want to *change* on
## the client still needs the enum extension that post-1.0 has no mechanism for,
## and that is still stated plainly. What has changed is that the mod now tells
## you what happened instead of telling you that it cannot.
##
## Three things it settles that nothing else can:
##
##  * **The cap.** A server that raised `maxBotCap` to 40 and a client that
##    holds 22 alive is the single most common MoreBots complaint, and the two
##    numbers have never been in the same log line before.
##  * **The spawn distance.** A squad that spawns 600 m from the player is a
##    squad the player will never meet; that reads as "the mod does nothing".
##  * **Not the turnover.** An interval scan cannot see a bot that spawned and
##    died between two of them, so a raid churning sixty bots and one holding a
##    steady twenty-two look identical from here. That is the one question this
##    file structurally cannot answer, and it is why `bots/deaths.nim` is a
##    hook rather than a longer scan.
##  * **Whether a custom spawn type reached the client at all.** It cannot --
##    see the module comment in `morebots.nim` -- and this is the observation
##    rather than the assertion. If a role id outside BSG's own range is ever
##    seen here, that claim is wrong and this is where it would show.
##
## ---------------------------------------------------------------------------
## HOW IT REACHES THE GAME
## ---------------------------------------------------------------------------
##
## Through raw field offsets, not through the host and not through a name. A
## census of forty bots is forty `IsAI` reads, forty spawn-type reads and forty
## positions, and on the boxed path that would be 120 microseconds of
## marshalling for a diagnostic. As field reads it is a few hundred nanoseconds
## and 39 of the 120 are not calls at all. `docs/PERF.md` is the argument for
## binding; this file went one step past it.
##
## THE PARAGRAPHS THAT USED TO BE HERE WERE THE BUG, so what they said is kept.
## They said everything except the world's static `get_Instance` is bound
## **against the object it is reached on**, because the chain is nothing but
## subclasses and generics that `findClass` cannot name. The reasoning was
## sound and the mechanism was fatal: binding against an object is
## `il2cpp_object_get_class` -> `il2cpp_class_get_name`, and on this build the
## first validates nothing (`mov rax,[rcx]; ret`) while the second is
## TOKEN-GATED and answers a uniform random NON-ZERO uint64 on mismatch. Every
## nil check passes; the first dereference is 0xC0000005. That is fact #198 and
## it is how `fov.dll` killed the client 0.6s after a Woods spawn. This file ran
## the same chain PER BOT PER SCAN.
##
## It also could not have worked: `EFT.GameWorld::get_Instance` does not exist
## on this build, so the one binding made before the raid always refused and
## `runCensus` returned at its first guard every time.
##
## Both are gone. The world comes from the host's `RegisterPlayer` cache
## (`aowl_host_gameworld`), and everything reached from it is a validated field
## read at an offset derived with `tools/fldoff.py` and cross-checked against
## the compiled accessor's own bytes. The two things this file used to ASSERT
## by asking the runtime are now ANSWERED OFFLINE, which is strictly better
## than a guarded assertion:
##
##  * The position was a hidden-return-pointer call to `get_Position` whose
##    shape was confirmed at runtime. It is now three `float32` reads from
##    `EFT.MovementContext.PreviousPosition` @+0x370 -- a `Vector3` already
##    sitting in a field does not need to be returned at all.
##  * `WildSpawnType`'s integer width was asked of the runtime because the C API
##    does not state it. Metadata states it: `EFT.ProfileSettings` places `Role`
##    at +0x10 and `BotDifficulty` at +0x14, so the field IS four bytes. Nothing
##    is asserted.
##
## ONE call survives, because it is not a field: `EFT.Player::get_IsAI`, at the
## byte-verified static RVA 0x726890. Its body proves `AIData == null` means
## not-AI but makes an interface call when it is non-null, so substituting the
## null test for the call would have been a plausible wrong answer.
##
## Every refusal keeps the census running on what it could read. A bot whose
## spawn type will not read is counted as a bot with an unknown type, not
## dropped and not invented.
##
## **Nothing in this file has ever run against BSG's game.** Every `EFT.` name
## below is from the pre-1.0 C# surface, and post-1.0 is a different build. A
## wrong one is a refused binding with a `why` line in the log and a census that
## reports fewer facts, never a wrong number. `censusReport()` prints every one
## of them once.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast

# ---------------------------------------------------------------------------
# The runtime
# ---------------------------------------------------------------------------

## Assigned from `openCensus()`, never at its declaration: in a nimony
## `--app:lib` build a global initialised by a *call* is silently left zeroed,
## so `var gRt = openIl2Cpp()` would produce a runtime that is never loaded and
## a census that quietly counts nothing.
var gRt: Il2Cpp
var gLive = false

proc censusLive*(): bool = gLive

proc censusRuntime*(): Il2Cpp =
  ## The runtime this file opened, for anything else in the client half that
  ## needs to ask the metadata a question.
  ##
  ## Exported rather than each module opening its own, because `openIl2Cpp`
  ## twice in one process is two handles onto one library and two answers to
  ## "is it loaded" that can disagree while the game is starting. `bots/
  ## deaths.nim` is the caller; it checks `censusLive()` first, because a
  ## zeroed `Il2Cpp` here is what "not yet" looks like.
  result = gRt

proc openCensus*(): bool =
  ## Binds `GameAssembly.dll` if it is in the process. Cheap to call again once
  ## it has succeeded; retried while it has not, because "the game has not got
  ## that far yet" and "this is not the game" look the same from here and only
  ## one of them is final.
  if gLive:
    return true
  gRt = openIl2Cpp()
  if not gRt.loaded:
    return false
  let missing = missingEssential(gRt)
  if missing.len > 0:
    warn "morebots: the IL2CPP runtime is missing " & $missing.len &
         " essential entry points; the census is unavailable"
    return false
  gLive = true
  result = true

proc openCensusAt*(path: string; domainName: string): bool =
  ## The same, against a runtime loaded from a path rather than found in the
  ## process. Only the self-test uses this: out of process the runtime is
  ## loaded but not *started*, so `il2cpp_init` is called too, and on a real
  ## client that will very likely refuse because the metadata is decrypted
  ## during the game's own startup. A refusal is a real answer and the caller
  ## prints it as one.
  if gLive:
    return true
  gRt = openIl2Cpp(path)
  if not gRt.loaded:
    return false
  if gRt.has(eInit):
    discard gRt.init(domainName)
  gLive = true
  result = true

# ---------------------------------------------------------------------------
# Reaching the world WITHOUT asking the runtime a question by name
# ---------------------------------------------------------------------------
#
# WHAT USED TO BE HERE, AND WHY IT IS GONE.
#
# This block used to be `ObjBind` / `changedClass` / `ensureCall`: bind a
# member against the CLASS OF A LIVE OBJECT, cache the attempt per class, and
# re-ask when a scav turned up where the last one was a PMC. It read as the
# careful option, and on this build it is the one that kills the process.
#
# MEASURED (fact #198, `docs/IL2CPP_EXPORTS.md`). `bindOnObject` is
# `il2cpp_object_get_class` -> `il2cpp_class_get_name` -> `readCString`.
# `il2cpp_object_get_class` is literally `mov rax,[rcx]; ret` -- it validates
# nothing, so a bad receiver yields a plausible NON-NIL number rather than a
# nil. `il2cpp_class_get_name` is one of the 38 TOKEN-GATED exports: it takes
# a trailing 32-byte token this code has never passed, `memcmp`s it, and on
# mismatch tail-calls a trap that seeds a per-thread MT19937-64 and returns a
# **uniform random non-zero uint64**. Every nil check on that chain therefore
# PASSES, and the first dereference is 0xC0000005. That is exactly how
# `fov.dll` killed the client 0.6s after a Woods spawn.
#
# `census.nim` ran the same chain **per bot per scan**, walking a whole base
# chain with `fullName` on every hop. It was the widest instance of the bug in
# the tree.
#
# WHAT REPLACES IT: raw static field offsets, and ONE byte-verified static
# RVA. A field read cannot be gated -- there is no export in the path at all.
# Every offset below was derived with `tools/fldoff.py` against the installed
# `GameAssembly.dll` and then CROSS-CHECKED against the compiled accessor's
# own bytes, which is the standard `mods/fov` set:
#
#   EFT.GameWorld     +0x1C8  AllAlivePlayersList : List<Player>
#                     +0x230  MainPlayer          : Player
#     (no accessor exists for either -- they are plain public fields, and
#      `EFT.GameWorld::get_Instance` DOES NOT EXIST on this build at all,
#      which is why the world comes from the host export below and not from a
#      static getter. The old `bindMethod(rt,"EFT.GameWorld","get_Instance")`
#      could only ever refuse, so `runCensus` returned at its first `if` on
#      every call and this whole file has never produced a number.)
#
#   System.Collections.Generic.List<T>
#                     +0x10   _items -> T[]   +0x18  _size : int32
#     T[] elements start at +0x20.
#     NOT from `fldoff.py`: a generic type DEFINITION has no laid-out field
#     offsets and the tool honestly prints 0x0 for all of them, which is the
#     single most dangerous number this file could have used. The layout used
#     here is the one `abi/aowlspt_botdiag.h` already reads in the shipped
#     host, against this same `GameWorld+0x1C8` list. It is stated as a
#     BORROWED constant, not a derived one, and the bounds check below is what
#     makes a wrong one a refusal instead of a fault.
#
#   EFT.Player        +0x60   <MovementContext>k__BackingField
#                       cross-check: Player::get_MovementContext @0x690D20 is
#                       `48 8B 41 60 C3` = mov rax,[rcx+0x60]; ret
#                     +0x9C0  <Profile>k__BackingField
#                       cross-check: Player::get_Profile @0x726390 is
#                       `48 8B 81 C0 09 00 00 C3` = mov rax,[rcx+0x9C0]; ret
#   EFT.MovementContext
#                     +0x370  PreviousPosition : Vector3 (3 x float32)
#   EFT.Profile       +0x48   Info : ProfileInfo   (a plain public field)
#   EFT.ProfileInfo   +0x78   <Settings>k__BackingField
#                       cross-check: ProfileInfo::get_Settings @0x690E60 is
#                       `48 8B 41 78 C3` = mov rax,[rcx+0x78]; ret
#   EFT.ProfileSettings
#                     +0x10   Role : WildSpawnType
#                       The enum-width question the old `enumRetOk` asked the
#                       runtime is ANSWERED offline instead: metadata reports
#                       `Role` at +0x10 and `BotDifficulty` at +0x14, so the
#                       field is exactly four bytes wide. Nothing is asserted.
#
# The ONE thing that stays a call is `EFT.Player::get_IsAI` @0x726890, because
# it is not a field. Its compiled body, read with `il2cpp_resolve.py bytes`, is
#
#     cmp qword [rbx+0xA00], 0     ; <AIData>k__BackingField
#     jne  .have
#     xor  al, al                  ; -> false
#     ret
#   .have:
#     mov  r8,[rbx+0xA00] ; mov ecx,3 ; jmp <interface dispatch>
#
# so `AIData == null` PROVES not-AI, but a non-null `AIData` does NOT prove
# AI -- there is an interface call after it. Substituting `AIData != null` for
# the call would have been a plausible wrong answer, so it was not done. The
# RVA is `('unique', 1)` per `Resolver.sharedness`, and `EFT.Player` is the
# most derived declarer of `get_IsAI` reachable from a `List<Player>` element
# (15 types declare that name; none of them is a subclass of `EFT.Player`), so
# a non-virtual call at this address is what a virtual dispatch would reach.

{.emit: """
#include <stdint.h>
#include <string.h>
#include <windows.h>

/* THE WHOLE OF THIS FILE'S MEMORY SAFETY. Same body as `aowl_is_readable` in
 * abi/aowlspt_shim.h, restated locally because that header is not in this
 * mod's translation unit. Committed, not a guard page, carrying a readable
 * protection, and the WHOLE range inside ONE region. */
static int32_t mb_is_readable(void* p, int32_t size) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || size <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY))) return 0;
    {   uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)p + (uintptr_t)size;
        if (need < (uintptr_t)p) return 0;   /* overflow */
        return need <= end ? 1 : 0;
    }
}

/* None of these four is ever reached without `mb_is_readable` having said yes
 * for the exact span they touch -- see `mbField` / `mbI32` / `mbF32`. */
static void* mb_read_ptr(void* p, int32_t off) {
    void* v = 0; if (!p) return 0;
    memcpy(&v, (const char*)p + off, sizeof(void*)); return v;
}
static int32_t mb_read_i32(void* p, int32_t off) {
    int32_t v = 0; if (!p) return 0;
    memcpy(&v, (const char*)p + off, 4); return v;
}
static float mb_read_f32(void* p, int32_t off) {
    float v = 0.0f; if (!p) return 0.0f;
    memcpy(&v, (const char*)p + off, 4); return v;
}
static uint8_t mb_byte_at(void* p, uint64_t i) { return ((const uint8_t*)p)[i]; }
static void*   mb_ptr_add(void* p, int64_t d) { return (void*)((char*)p + d); }

/* Calling a raw address needs C: nimony refuses `cast[proc(...)](pointer)`.
 * The int32 form is a REAL int32 thunk rather than the low half of a pointer
 * return -- an int32 return leaves the upper 32 bits of RAX undefined, so a
 * pointer-shaped read of it is a plausible non-zero answer for a function
 * that returned 0, which is a check that cannot fail. */
static void*   mb_call_p_v  (void* f) { return ((void*  (*)(void))f)(); }
static int32_t mb_call_i32_v(void* f) { return ((int32_t(*)(void))f)(); }
""".}

proc mbIsReadable(p: Il2CppPtr; size: int32): int32 {.
  importc: "mb_is_readable", nodecl.}
proc mbReadPtr(p: Il2CppPtr; off: int32): Il2CppPtr {.
  importc: "mb_read_ptr", nodecl.}
proc mbReadI32(p: Il2CppPtr; off: int32): int32 {.
  importc: "mb_read_i32", nodecl.}
proc mbReadF32(p: Il2CppPtr; off: int32): float32 {.
  importc: "mb_read_f32", nodecl.}
proc mbByteAt(p: Il2CppPtr; i: uint64): uint8 {.importc: "mb_byte_at", nodecl.}
proc mbPtrAdd(p: Il2CppPtr; d: int64): Il2CppPtr {.
  importc: "mb_ptr_add", nodecl.}
proc mbCallPV(f: Il2CppPtr): Il2CppPtr {.importc: "mb_call_p_v", nodecl.}
proc mbCallI32V(f: Il2CppPtr): int32 {.importc: "mb_call_i32_v", nodecl.}

proc mbGetModuleHandleA(name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetModuleHandleA", sideEffect.}
proc mbGetProcAddress(m: Il2CppPtr; name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetProcAddress", sideEffect.}

proc mbReadable(p: Il2CppPtr; size: int): bool =
  result = p != nil and mbIsReadable(p, int32(size)) != 0'i32

proc mbField(obj: Il2CppPtr; off: int): Il2CppPtr =
  ## One hop along a reference-field chain, with the hop validated.
  ##
  ## Every hop is checked, not just the first: `a->b->c` is three checks. The
  ## object must be readable for `off+8` bytes before the load, and the result
  ## must itself be readable before anyone treats it as an object. Returns nil
  ## -- which every caller already handles -- rather than faulting.
  result = cast[Il2CppPtr](0)
  if obj == nil:
    return
  if not mbReadable(obj, off + 8):
    return
  let p = mbReadPtr(obj, int32(off))
  if p == nil:
    return
  if not mbReadable(p, 16):
    return
  result = p

proc mbI32(obj: Il2CppPtr; off: int; ok: var bool): int32 =
  ## A four-byte read, with the read itself reported. `0` is a legitimate
  ## count and a legitimate `WildSpawnType`, so "could not read" MUST NOT be
  ## expressed as zero -- that would be a third check that cannot fail.
  ok = false
  result = 0'i32
  if obj == nil or not mbReadable(obj, off + 4):
    return
  ok = true
  result = mbReadI32(obj, int32(off))

# ---------------------------------------------------------------------------
# The offsets, named once
# ---------------------------------------------------------------------------

const
  OffGwAliveList  = 0x1C8   ## EFT.GameWorld.AllAlivePlayersList : List<Player>
  OffGwMainPlayer = 0x230   ## EFT.GameWorld.MainPlayer          : Player
  OffListItems    = 0x010   ## List<T>._items -> T[]      (borrowed, see above)
  OffListSize     = 0x018   ## List<T>._size  : int32     (borrowed, see above)
  OffArrElems     = 0x020   ## T[] element zero           (borrowed, see above)
  OffPlProfile    = 0x9C0   ## EFT.Player.<Profile>k__BackingField
  OffPlMoveCtx    = 0x060   ## EFT.Player.<MovementContext>k__BackingField
  OffMcPrevPos    = 0x370   ## EFT.MovementContext.PreviousPosition : Vector3
  OffProfInfo     = 0x048   ## EFT.Profile.Info : ProfileInfo
  OffInfoSettings = 0x078   ## EFT.ProfileInfo.<Settings>k__BackingField
  OffSetRole      = 0x010   ## EFT.ProfileSettings.Role : WildSpawnType (4 B)

  RvaPlayerIsAI = 0x726890
    ## `EFT.Player::get_IsAI()` -> bool. arity 0, INSTANCE, section `il2cpp`,
    ## `('unique', 1)` per `Resolver.sharedness` -- no other method folds onto
    ## this address, so even the sharedness hazard that makes 28.3% of by-name
    ## lookups unsafe to reason about does not apply.
  ProPlayerIsAI = "40 53 48 83 EC 20 80 3D AA 18 99 06 00 48 8B D9"
    ## The first sixteen bytes as `il2cpp_resolve.py bytes 0x726890` read them
    ## out of the installed `GameAssembly.dll`:
    ##   40 53              push rbx
    ##   48 83 EC 20        sub  rsp,0x20
    ##   80 3D AA189906 00  cmp  byte [rip+0x69918AA],0   ; cctor-ran flag
    ##   48 8B D9           mov  rbx,rcx
    ## The `cmp`'s disp32 is included only to PIN THE BUILD; nothing is stolen
    ## and nothing is detoured -- this address is only ever CALLED.

  MaxPlayers = 4096
    ## Capped iteration. A corrupt `_size` must be a refused scan, never an
    ## unbounded loop inside a frame.

var gRvaVerified = 0
var gRvaRejected = 0
var gFaults = 0

const MaxFaults = 8
  ## Self-disable. After this many hops came back unreadable in one session the
  ## census stops trying: a path that faults every scan forever is an outage of
  ## its own, and a mod that will not work is better off saying so once.

proc censusFaults*(): int = gFaults

proc hexDigit(v: int): char =
  const D = "0123456789ABCDEF"
  result = D[v and 15]

proc hex2(v: int): string =
  result = ""
  result.add hexDigit(v shr 4)
  result.add hexDigit(v)

proc hexs(v: int): string =
  const D = "0123456789abcdef"
  if v == 0:
    return "0"
  var n = v
  var buf = ""
  while n > 0:
    buf.add D[n and 15]
    n = n shr 4
  result = ""
  var i = buf.len - 1
  while i >= 0:
    result.add buf[i]
    dec i

proc prologueMatches(p: Il2CppPtr; expect: string; got: var string): bool =
  ## An exact 16-byte compare against the bytes `il2cpp_resolve.py` read out of
  ## `GameAssembly.dll` ON DISK, with the LIVE bytes printed on a mismatch so
  ## the refusal carries its own evidence.
  ##
  ## Compared against live memory on purpose, and that is the same considered
  ## choice `mods/fov` documents. The startup-snapshot rule exists for DETOUR
  ## targets, where an earlier feature's trampoline makes a perfectly correct
  ## RVA self-reject. Nothing here detours anything -- `get_IsAI` is only ever
  ## CALLED -- and `abi/aowlspt_prologue.h`'s table is `static`, i.e.
  ## host-internal, so a mod that included it would get its own EMPTY table and
  ## lazily capture whatever is in memory NOW, which is strictly worse than
  ## comparing against the bytes on disk. A mismatch here means a stale RVA or
  ## somebody else's hook, and declining to call is right in both cases.
  got = ""
  result = false
  if p == nil:
    got = "(null)"
    return
  if not mbReadable(p, 16):
    got = "(not readable -- VirtualQuery says this is not committed memory)"
    return
  var i = 0
  var ok = true
  while i < 16:
    let b = int(mbByteAt(p, uint64(i)))
    var hi = 0
    var lo = 0
    let ch = expect[i * 3]
    let cl = expect[i * 3 + 1]
    if ch >= '0' and ch <= '9': hi = int(ch) - int('0')
    else: hi = 10 + int(ch) - int('A')
    if cl >= '0' and cl <= '9': lo = int(cl) - int('0')
    else: lo = 10 + int(cl) - int('A')
    if b != hi * 16 + lo:
      ok = false
    if i > 0:
      got.add ' '
    got = got & hex2(b)
    inc i
  result = ok

proc bindAtRva*(label: string; rva: int; expect: string;
                argKinds: openArray[FastKind]; ret: FastKind;
                isStatic: bool): Binding =
  ## A `Binding` built from a static RVA instead of from a NAME.
  ##
  ## This is the whole point of the file's rewrite: a direct call at a
  ## byte-verified static RVA bypasses the export ABI outright and is
  ## unaffected by any token gate. `info` -- the hidden trailing
  ## `const MethodInfo*` -- is left NULL, which is legal for everything except
  ## a shared generic; `get_IsAI` has no type parameters and no generic
  ## container.
  result = Binding(ok: false, why: "", target: label,
                   fn: nullPtr(), info: nullPtr(),
                   argc: 0'i32, slots: 0'i32, mask: 0'u32, ret: ret,
                   isStatic: isStatic, bindNs: 0'i64)
  if not gLive or gRt.handle == nil:
    result.why = label & ": GameAssembly.dll is not bound, so there is no " &
                 "imagebase to add an RVA to"
    gRvaRejected = gRvaRejected + 1
    return
  if ret == fkNone:
    result.why = label & ": the return shape was not stated"
    gRvaRejected = gRvaRejected + 1
    return
  # Runtime address = module base + (VA - 0x180000000), and the RVA above is
  # already VA-minus-imagebase.
  let fn = mbPtrAdd(gRt.handle, int64(rva))
  var got = ""
  if not prologueMatches(fn, expect, got):
    result.why = label & " @0x" & hexs(rva) & ": PROLOGUE MISMATCH -- " &
                 "expected " & expect & ", found " & got & ". REFUSED; " &
                 "nothing was called. Either this RVA is stale for the " &
                 "installed GameAssembly.dll (a Tarkov update), or another " &
                 "feature has already detoured it."
    gRvaRejected = gRvaRejected + 1
    return
  let base = (if isStatic: 0'i32 else: 1'i32)
  var mask = 0'u32
  var i = 0
  while i < argKinds.len:
    let k = argKinds[i]
    if k == fkNone or k == fkVoid or k == fkF64:
      result.why = label & ": argument " & $i & " is a kind the fast path " &
                   "does not pass"
      gRvaRejected = gRvaRejected + 1
      return
    if k == fkF32:
      mask = mask or (1'u32 shl uint32(int32(i) + base))
    inc i
  result.fn = fn
  result.argc = int32(argKinds.len)
  result.slots = int32(argKinds.len) + base
  result.mask = mask
  result.ok = true
  gRvaVerified = gRvaVerified + 1
  result.why = label & " @0x" & hexs(rva) & ": prologue verified 16/16, " &
               (if isStatic: "static" else: "instance") & ", " &
               $argKinds.len & " arg(s)"

proc rvaVerifiedCount*(): int = gRvaVerified
proc rvaRejectedCount*(): int = gRvaRejected

# ---------------------------------------------------------------------------
# The live GameWorld, borrowed from the host
# ---------------------------------------------------------------------------
#
# `EFT.GameWorld::get_Instance` DOES NOT EXIST on this build -- measured, and
# independently of `mods/fov`'s identical finding: `il2cpp_resolve.py type
# 6172` lists every member of `EFT.GameWorld` and none of them is named
# `get_Instance`. So the old `bindMethod(gRt, "EFT.GameWorld", "get_Instance")`
# was a binding that could only ever refuse, and `runCensus`'s very first
# guard (`not gB.world.ok`) returned on every call. This file has never once
# counted a bot; the by-name apparatus above it was dangerous AND inert.
#
# The only honest source is the host's own cache, populated by its
# `RegisterPlayer` detour and published as two exports -- the same route
# `mods/fov` and `mods/sain` take.

var gGwFn: Il2CppPtr = cast[Il2CppPtr](0)
var gGwArmedFn: Il2CppPtr = cast[Il2CppPtr](0)
var gGwTried = false

proc gwResolve() =
  if gGwTried:
    return
  gGwTried = true
  var hostDll = "aowlspt-host-il2cpp.dll"
  let h = mbGetModuleHandleA(toCString(hostDll))
  if h == nil:
    return
  var n1 = "aowl_host_gameworld"
  var n2 = "aowl_host_gameworld_armed"
  gGwFn = mbGetProcAddress(h, toCString(n1))
  gGwArmedFn = mbGetProcAddress(h, toCString(n2))

proc gwState*(): int =
  ## 0 no host export -- host too old, or this is not the client
  ## 1 export present but NO detour armed -- INCONCLUSIVE, not "no raid"
  ## 2 armed, cache empty -- genuinely not in a raid
  ## 3 world live
  ##
  ## Three-way on purpose (CLAUDE.md 9b): "I could not look" is not "no bots".
  ## The armed flag is read through a REAL int32 thunk, because an int32
  ## return leaves the upper 32 bits of RAX undefined and a pointer-shaped
  ## read of it would be a plausible non-zero answer for a function that
  ## returned 0.
  gwResolve()
  if gGwFn == nil:
    return 0
  if gGwArmedFn != nil and mbCallI32V(gGwArmedFn) == 0'i32:
    return 1
  if mbCallPV(gGwFn) == nil:
    return 2
  result = 3

proc gwStateText*(): string =
  case gwState()
  of 0: "no host export aowl_host_gameworld -- this host predates it, or " &
        "this mod is not running in the client. INCONCLUSIVE."
  of 1: "the host exports the world but NO detour is armed to populate it " &
        "(host flag debugEsp or botDiag). INCONCLUSIVE -- not 'no raid'."
  of 2: "armed; no GameWorld cached, which is exactly what a menu looks like"
  else: "GameWorld LIVE, borrowed from the host's RegisterPlayer cache"

proc gwWorld(): Il2CppPtr =
  ## The live world object, or nil. Never a type handle.
  if gwState() != 3:
    return cast[Il2CppPtr](0)
  let w = mbCallPV(gGwFn)
  if not mbReadable(w, 0x238):
    # The largest offset this file reads off a world is MainPlayer at +0x230.
    return cast[Il2CppPtr](0)
  result = w

# ---------------------------------------------------------------------------
# The two assertions, and the guards that earn them
# ---------------------------------------------------------------------------

# How this runtime reports a value type's size, asked rather than assumed.
#
# `il2cpp_class_get_instance_size` on a *value* type reports the payload plus
# the object header on the real runtime -- the same convention
# `il2cpp_object_unbox` implies, since unboxing is that header being stepped
# over. A hard-coded 16 for the header (a class pointer and a monitor pointer on
# x64) is the number that is right today, and it is exactly the kind of layout
# constant this repo does not let a mod assert: `tests/mockil2cpp` reports the
# payload with no header at all, and a mod that subtracted 16 there computed a
# negative size and refused every shaped call while looking like it had checked.
#
# So it is calibrated. `System.Int32` is four bytes of payload and
# `System.Double` is eight, on every build there has ever been; whatever this
# runtime adds to both is its header. Two knowns and a difference, and the
# header falls out. If the two do not differ by four, the convention is one this
# will not reason about and **every** shaped or asserted binding refuses -- which
# is the failure this whole apparatus exists to produce instead of a plausible
# number.

var gHeaderBytes = -1
  ## -1: not yet asked. -2: asked, and the answer made no sense.

var gAllowReflection = false
  ## `findClass` is `il2cpp_class_from_name`, which is TOKEN-GATED on this
  ## build: on mismatch it answers a uniform random NON-ZERO uint64, so
  ## `if c == nil` PASSES and `classInstanceSize(gRt, c)` dereferences a random
  ## address (fact #198). Nothing below is on the scan path any more -- the
  ## census is field reads now -- so the only caller left is `morebots.nim`'s
  ## SELF-TEST, which runs out of process against a stand-in runtime where
  ## there is no gate and no client to kill.
  ##
  ## Default OFF, therefore, and the self-test opts in explicitly. In the
  ## injected client this stays off and every proc below returns its existing
  ## "unknown" answer, which every caller already handles.

proc censusAllowReflection*(v: bool) =
  ## Only `morebots.nim`'s self-test may turn this on, and only because it is
  ## not the client. See `gAllowReflection`.
  gAllowReflection = v

var gReflectionNoted = false

proc reflectionRefused(what: string): bool =
  result = not gAllowReflection
  if result and not gReflectionNoted:
    gReflectionNoted = true
    warn "morebots: refusing to resolve '" & what & "' by NAME. " &
         "il2cpp_class_from_name is token-gated on this build and answers a " &
         "random non-zero value on mismatch, so the nil check below it cannot " &
         "fire and the first dereference is 0xC0000005. The census does not " &
         "need it -- it reads fields -- so this is a degraded self-test, not " &
         "a degraded census."

proc calibrateHeader*() =
  if gHeaderBytes != -1:
    return
  if reflectionRefused("System.Int32 / System.Double"):
    gHeaderBytes = -2
    return
  let i32 = findClass(gRt, "System.Int32")
  let f64 = findClass(gRt, "System.Double")
  if i32 == nil or f64 == nil:
    # Leave it at -1: the assemblies may simply not be up yet, and this is
    # retried. Until then every guarded binding refuses.
    return
  let a = classInstanceSize(gRt, i32)
  let b = classInstanceSize(gRt, f64)
  if a <= 0 or b <= 0 or b - a != 4:
    gHeaderBytes = -2
    warn "morebots: this runtime reports System.Int32 as " & $a &
         " bytes and System.Double as " & $b &
         ", which is not payload-plus-a-constant-header. No shaped call and " &
         "no enum width will be asserted against it."
    return
  gHeaderBytes = a - 4
  debug "morebots: value-type instance sizes include a " & $gHeaderBytes &
        "-byte header on this runtime (System.Int32 reports " & $a & ")"

proc headerBytes*(): int = gHeaderBytes

proc payloadSize*(tn: string): int =
  ## The payload size of a value type, or 0 when the type is a reference, is
  ## unknown, is not resolvable by name on this build, or comes back at a size
  ## this will not reason about.
  result = 0
  if tn.len == 0:
    return
  if reflectionRefused(tn):
    return
  calibrateHeader()
  if gHeaderBytes < 0:
    return
  let c = findClass(gRt, tn)
  if c == nil:
    return
  if not classIsValueType(gRt, c):
    return
  let sz = classInstanceSize(gRt, c) - gHeaderBytes
  if sz <= 0 or sz > 64:
    return
  result = sz

proc shapedSizeAccepted*(sz: int): bool =
  ## **The Win64 rule itself**, as a function of a size and nothing else.
  ##
  ## An aggregate of 1, 2, 4 or 8 bytes is passed and returned in a general
  ## register; everything else goes through memory the caller supplies. The
  ## upper bound of 16 is this mod's, not the ABI's: it is the size of the
  ## buffer `readPosition` hands over, and refusing beats writing past it.
  ##
  ## Split out as a pure function on purpose. A guard that is only reachable
  ## through a live runtime is a guard whose accepting branch may never have run
  ## -- and "refused correctly" and "never reachable" look identical from
  ## outside. This one can be, and is, exercised exhaustively over every size it
  ## will ever see, with no game and no stand-in runtime involved.
  if sz <= 0: return false
  if sz == 1 or sz == 2 or sz == 4 or sz == 8: return false
  result = sz <= 16

proc shapedRetSizeOk*(tn: string): bool =
  ## The same rule applied to a *type*, which is the half that needs the
  ## runtime: is it a value type, and how big is its payload.
  result = shapedSizeAccepted(payloadSize(tn))

proc enumSizeOk*(tn: string): bool =
  ## Whether a type is a four-byte value type -- the only case in which
  ## asserting `fkI32` for an enum is safe. Same split, same reason.
  result = payloadSize(tn) == 4

# ---------------------------------------------------------------------------
# The bindings
# ---------------------------------------------------------------------------

type
  CensusBindings = object
    ready: bool
    isAI: Binding           ## EFT.Player::get_IsAI, byte-verified static RVA
    isAIWhy: string

var gB: CensusBindings

proc censusBind*() =
  ## Verify the ONE address this file calls. Everything else it needs is a
  ## field read, which has nothing to bind.
  ##
  ## Safe to call before a raid and safe to call from `onLoad`: the old warning
  ## on this proc ("never from `onLoad`: `findClass` walks every loaded
  ## assembly") described the by-name apparatus that is gone. A prologue
  ## compare is sixteen byte loads behind a `VirtualQuery`.
  if gB.ready:
    return
  var none: seq[FastKind] = @[]
  gB.isAI = bindAtRva("EFT.Player::get_IsAI", RvaPlayerIsAI, ProPlayerIsAI,
                      none, fkBool, false)
  gB.isAIWhy = gB.isAI.why
  gB.ready = true

proc readPosition(player: Il2CppPtr; x, y, z: var float): bool =
  ## The player's world position, as THREE RAW FLOAT READS.
  ##
  ## WHAT THIS REPLACES. The old version bound `get_Position` by walking the
  ## receiver's base chain with `fullName` on every hop, then asked the runtime
  ## whether the return was a value type of a non-register size, then made a
  ## shaped call with a hidden return pointer. Every one of those steps went
  ## through a token-gated export, and the base-chain walk ran PER BOT PER
  ## SCAN. The shape reasoning was correct and completely beside the point: a
  ## `Vector3` that is already sitting in a field does not need to be returned
  ## at all.
  ##
  ## `EFT.MovementContext.PreviousPosition` @+0x370 is that field.
  ## `BifacialTransform.position` is a delegate rather than a field, so this
  ## cached `Vector3` is the reflection-free source -- the same one the shipped
  ## host reads in `abi/aowlspt_botdiag.h`.
  ##
  ## Two validated hops, and a THIRD check on the twelve bytes themselves, so a
  ## `MovementContext` that is readable but whose tail is not cannot be read
  ## past.
  x = 0.0
  y = 0.0
  z = 0.0
  result = false
  let mc = mbField(player, OffPlMoveCtx)
  if mc == nil:
    return
  if not mbReadable(mc, OffMcPrevPos + 12):
    return
  x = float(mbReadF32(mc, int32(OffMcPrevPos)))
  y = float(mbReadF32(mc, int32(OffMcPrevPos + 4)))
  z = float(mbReadF32(mc, int32(OffMcPrevPos + 8)))
  result = true

proc readRole(player: Il2CppPtr; role: var int): bool =
  ## Player -> Profile -> Info -> Settings -> Role, four validated hops and a
  ## reported four-byte read.
  ##
  ## The old version bound `get_Profile` / `get_Info` / `get_Settings` against
  ## the class of each object it met, then bound `get_Role` after asking the
  ## runtime to confirm the return was a four-byte value type. The confirmation
  ## is now offline and stronger: metadata places `Role` at +0x10 and
  ## `BotDifficulty` at +0x14 on `EFT.ProfileSettings`, so the field IS four
  ## bytes wide. Nothing is asserted and nothing is asked at runtime.
  ##
  ## `-1` is never written on failure -- `ok` carries that -- because `0` is a
  ## real `WildSpawnType` and a failure expressed as a value is a check that
  ## cannot fail.
  role = 0
  result = false
  let prof = mbField(player, OffPlProfile)
  if prof == nil:
    return
  let info = mbField(prof, OffProfInfo)
  if info == nil:
    return
  let settings = mbField(info, OffInfoSettings)
  if settings == nil:
    return
  var ok = false
  let v = mbI32(settings, OffSetRole, ok)
  if not ok:
    return
  role = int(v)
  result = true

# ---------------------------------------------------------------------------
# The census
# ---------------------------------------------------------------------------

const
  MaxRoles = 24
    ## How many distinct spawn types are tallied separately. Past that a role
    ## lands in the overflow count rather than growing a table on the scan path.

type
  Census* = object
    ok*: bool             ## a world existed and the list was walked
    total*: int           ## every alive player, human included
    ai*: int              ## how many of them the game calls AI
    withRole*: int        ## how many had a readable spawn type
    customRoles*: int     ## spawn types outside BSG's own range
    unreadable*: int      ## AI whose spawn type would not bind
    roleIds*: seq[int]
    roleCounts*: seq[int]
    overflowRoles*: int
    haveDistance*: bool
    nearest*: float
    farthest*: float
    scanNs*: int64

proc emptyCensus*(): Census =
  Census(ok: false, total: 0, ai: 0, withRole: 0, customRoles: 0,
         unreadable: 0, roleIds: @[], roleCounts: @[], overflowRoles: 0,
         haveDistance: false, nearest: 0.0, farthest: 0.0, scanNs: 0'i64)

proc tally(c: var Census; role: int) =
  for i in 0 ..< c.roleIds.len:
    if c.roleIds[i] == role:
      c.roleCounts[i] = c.roleCounts[i] + 1
      return
  if c.roleIds.len >= MaxRoles:
    c.overflowRoles = c.overflowRoles + 1
    return
  c.roleIds.add role
  c.roleCounts.add 1

const VanillaRoleCeiling = 100
  ## Every `WildSpawnType` BSG ships is a small ordinal; MoreBotsAPI's own
  ## convention puts custom ids far above it (Black Division's start at
  ## 848420). A role at or past this is therefore a *custom* type that reached
  ## the client -- which the module comment in `morebots.nim` says cannot
  ## happen post-1.0. Counting them is how that claim gets tested rather than
  ## repeated.

var gWhy = "not attempted"

proc censusWhy*(): string = gWhy
  ## Why the last scan produced what it produced. THREE outcomes, not two: a
  ## census that walked the list and found no bots, and a census that could not
  ## reach the list at all, are different facts, and `ok == false` alone cannot
  ## tell them apart.

proc runCensus*(): Census =
  ## One pass over the world's alive players. Called at whatever interval the
  ## caller chooses; nothing here is per-frame, and nothing here writes.
  ##
  ## NOT ONE NAME IS RESOLVED AT RUNTIME. The whole body is validated field
  ## reads plus, per AI candidate, one call at a prologue-verified static RVA.
  ## There is no `il2cpp_object_get_class`, no `il2cpp_class_get_name`, no
  ## `il2cpp_class_from_name` and no `readCString` anywhere on this path, which
  ## is what makes it safe to run per tick.
  ##
  ## No managed allocation happens here either: `roleIds`/`roleCounts` grow to
  ## at most `MaxRoles` entries and are the caller's, not the runtime's.
  result = emptyCensus()
  if not gLive:
    gWhy = "GameAssembly.dll is not bound in this process"
    return
  if not gB.ready:
    gWhy = "censusBind() has not run"
    return
  if gFaults >= MaxFaults:
    gWhy = "SELF-DISABLED after " & $gFaults & " unreadable hops -- a path " &
           "that faults every scan is an outage of its own"
    return
  let t0 = perfCounter()

  let world = gwWorld()
  if world == nil:
    gWhy = gwStateText()
    return

  let list = mbField(world, OffGwAliveList)
  if list == nil:
    gWhy = "GameWorld+0x1C8 (AllAlivePlayersList) did not read back as a " &
           "readable object. The world pointer was live, so this is a LAYOUT " &
           "answer, not a 'no raid' answer."
    gFaults = gFaults + 1
    return

  var sizeOk = false
  let rawN = mbI32(list, OffListSize, sizeOk)
  if not sizeOk:
    gWhy = "the alive-players List was readable but its _size at +0x18 was not"
    gFaults = gFaults + 1
    return
  let n = int(rawN)
  if n < 0 or n > MaxPlayers:
    gWhy = "the alive-players List reports _size = " & $n &
           ", which is outside 0.." & $MaxPlayers &
           ". REFUSED rather than iterated -- a corrupt count must not become " &
           "an unbounded loop inside a frame."
    gFaults = gFaults + 1
    return

  let items = mbField(list, OffListItems)
  if items == nil:
    if n == 0:
      # An empty List legitimately holds the shared empty array, and a menu
      # looks exactly like this. Not a fault.
      result.ok = true
      gWhy = "the alive-players List is empty (a menu, or a raid that has " &
             "registered nobody yet)"
      result.scanNs = nanosBetween(t0, perfCounter())
      return
    gWhy = "the alive-players List reports " & $n & " entries but its " &
           "_items array at +0x10 did not read back"
    gFaults = gFaults + 1
    return
  # The whole element span, checked ONCE and up front rather than per index:
  # the array header is 0x20 and each element is a pointer.
  if not mbReadable(items, OffArrElems + n * 8):
    gWhy = "the alive-players array is not readable for all " & $n &
           " elements; refusing to walk part of it"
    gFaults = gFaults + 1
    return

  # The local player, for the distances. Its absence is not a failure: a census
  # without distances is still a census, and it says so.
  var px = 0.0
  var py = 0.0
  var pz = 0.0
  var havePlayer = false
  let me = mbField(world, OffGwMainPlayer)
  if me != nil:
    havePlayer = readPosition(me, px, py, pz)

  result.ok = true
  gWhy = "walked " & $n & " alive players from the host's cached GameWorld " &
         "by field offset; " &
         (if gB.isAI.ok: "get_IsAI is bound at a verified RVA"
          else: "get_IsAI is REFUSED (" & gB.isAIWhy & "), so no player " &
                "can be classified as AI and every one is counted unreadable")
  var a = noArgs()
  var i = 0
  while i < n:
    let p = mbField(items, OffArrElems + i * 8)
    inc i
    if p == nil:
      continue
    result.total = result.total + 1

    # The one call. Refused bindings are handled by not calling: a census that
    # cannot classify says so in `unreadable` rather than guessing.
    if not gB.isAI.ok:
      result.unreadable = result.unreadable + 1
      continue
    # `get_IsAI` dereferences [this+0xA00]; the receiver must cover it.
    if not mbReadable(p, 0xA08):
      result.unreadable = result.unreadable + 1
      gFaults = gFaults + 1
      continue
    a.reset()
    if not callBool(gB.isAI, p, a):
      continue
    result.ai = result.ai + 1

    var role = 0
    if not readRole(p, role):
      result.unreadable = result.unreadable + 1
    else:
      result.withRole = result.withRole + 1
      tally(result, role)
      if role >= VanillaRoleCeiling:
        result.customRoles = result.customRoles + 1

    if havePlayer:
      var bx = 0.0
      var by = 0.0
      var bz = 0.0
      if readPosition(p, bx, by, bz):
        let dx = bx - px
        let dy = by - py
        let dz = bz - pz
        var d2 = dx * dx + dy * dy + dz * dz
        if d2 < 0.0:
          d2 = 0.0
        # No `sqrt` import for one number: twenty Newton steps from a sane seed
        # converge well past the precision a distance report needs, and pulling
        # in the maths module for this would be the tail wagging the dog.
        var d = d2
        if d2 > 0.0:
          var k = 0
          while k < 20:
            d = 0.5 * (d + d2 / d)
            inc k
        else:
          d = 0.0
        if not result.haveDistance:
          result.haveDistance = true
          result.nearest = d
          result.farthest = d
        else:
          if d < result.nearest: result.nearest = d
          if d > result.farthest: result.farthest = d
  result.scanNs = nanosBetween(t0, perfCounter())

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

proc censusReport*() =
  ## Everything this file depends on, and its own account of itself.
  ##
  ## docs/PERF.md asks for exactly this: read the reason into the log once,
  ## because "a refused binding is a mod that will quietly do nothing
  ## otherwise". A census that reports zero bots and a census that could not
  ## read the list are different facts and this is what tells them apart.
  ##
  ## There is no per-member binding table any more, because there are no
  ## per-member bindings. What is listed instead is the ONE verified call and
  ## the field offsets everything else is, so a Tarkov update that moves a
  ## field shows up here as a refusal with the offset printed rather than as a
  ## census that quietly counts nothing.
  info "morebots: census --"
  info "morebots:   world    " & gwStateText()
  if gB.isAI.ok:
    info "morebots:   RVA      " & gB.isAIWhy
  else:
    warn "morebots:   REFUSED  " & gB.isAIWhy
  info "morebots:   offsets  GameWorld.AllAlivePlayersList@0x" &
       hexs(OffGwAliveList) & " MainPlayer@0x" & hexs(OffGwMainPlayer) &
       "; List _items@0x" & hexs(OffListItems) & " _size@0x" &
       hexs(OffListSize) & " elems@0x" & hexs(OffArrElems)
  info "morebots:   offsets  Player.Profile@0x" & hexs(OffPlProfile) &
       " .MovementContext@0x" & hexs(OffPlMoveCtx) &
       "; MovementContext.PreviousPosition@0x" & hexs(OffMcPrevPos)
  info "morebots:   offsets  Profile.Info@0x" & hexs(OffProfInfo) &
       "; ProfileInfo.Settings@0x" & hexs(OffInfoSettings) &
       "; ProfileSettings.Role@0x" & hexs(OffSetRole)
  info "morebots:   verified " & $rvaVerifiedCount() & " RVA(s), rejected " &
       $rvaRejectedCount() & "; " & $censusFaults() & " unreadable hop(s) so " &
       "far (self-disables at " & $MaxFaults & ")"
  info "morebots:   last     " & censusWhy()
  info "morebots:   NO NAME IS RESOLVED AT RUNTIME on the scan path -- no " &
       "il2cpp_object_get_class, no il2cpp_class_get_name, no " &
       "il2cpp_class_from_name. That is deliberate: those exports are " &
       "token-gated and answer a random NON-ZERO uint64 on mismatch, so a " &
       "nil check passes and the first dereference kills the client (fact " &
       "#198). A field read has no export in the path at all."

proc describe*(c: Census; cap: int): string =
  ## One line, and the one line somebody actually reads.
  if not c.ok:
    return "no world (the census binds in a raid and reports nothing outside " &
           "one)"
  result = $c.ai & " AI alive of " & $c.total & " players"
  if cap > 0:
    result = result & ", against a configured cap of " & $cap
    if c.ai > cap:
      result = result & " -- OVER"
  if c.haveDistance:
    result = result & "; nearest " & $int(c.nearest) & " m, farthest " &
             $int(c.farthest) & " m"
  if c.unreadable > 0:
    result = result & "; " & $c.unreadable & " with an unreadable spawn type"
  result = result & "; scanned in " & $c.scanNs & " ns"

proc reportRoles*(c: Census) =
  if not c.ok:
    return
  if c.roleIds.len == 0:
    info "morebots:   no spawn type was readable on any alive bot"
    return
  var line = "morebots:   spawn types alive:"
  for i in 0 ..< c.roleIds.len:
    line = line & " " & $c.roleIds[i] & "x" & $c.roleCounts[i]
  if c.overflowRoles > 0:
    line = line & " (+" & $c.overflowRoles & " past the " & $MaxRoles &
           " tallied)"
  info line
  if c.customRoles > 0:
    success "morebots:   " & $c.customRoles & " bot(s) carry a spawn type at " &
            "or above " & $VanillaRoleCeiling & " -- a CUSTOM type reached " &
            "the client. That contradicts what this mod's module comment " &
            "says is possible post-1.0 and is worth reporting upstream."
  else:
    info "morebots:   no custom spawn type reached the client, which is what " &
         "the module comment predicts: WildSpawnType is native constants with " &
         "its switch tables already compiled, and nothing can append to it"
