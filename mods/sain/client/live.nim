## Live objects: the IL2CPP runtime, held directly, and every binding SAIN
## reads a bot through.
##
## ## Why this file talks to the runtime rather than to the host
##
## The mod could reach the game through `aowlspt/game`: `resolve` a type,
## `call` a member, get `{"handle":n}` back and call on that. That works, and
## `docs/PERF.md` measures it at 950-1235 ns per call. SAIN reads a dozen
## things per bot per decision, and the user's stated reason for this rewrite
## is that bot AI was the expensive part, so a dozen microseconds per bot is
## the wrong budget by two orders of magnitude.
##
## A mod DLL is in the same process as `GameAssembly.dll`, so `openIl2Cpp()`
## binds the runtime's own C API directly and the host is simply not on the
## path. That is what `aowlspt/fast` is for, and it is what this file uses.
##
## **The two worlds now meet, in one direction.** A host `Handle` -- what
## `game.nim` and a `hookArgs` reference argument hand back -- is an index into
## the host's table, and until ABI revision 3 there was no entry point that
## turned one into the raw pointer the fast path needs. `pointerOf` is that
## entry point, at 9 ns against the ~1068 the boxed read of the same object
## costs, and `sain.nim`'s spawn and death hooks are built on it.
##
## What it does not do is make a host handle storable: the host reclaims it
## when the handler returns, so an address taken inside a hook is good for that
## handler and no longer. The rule this file follows is therefore unchanged --
## anything kept across frames is an IL2CPP GC handle this file took itself --
## and what changed is only that the pointer can now *arrive* from a hook
## instead of having to be re-found by scanning the world.
##
## The host path is still used for the things it is better at: the capability
## probe, and a spawning bot's profile id and spawn type, both of which happen
## once per bot rather than once per frame.
##
## ## Why almost everything here is bound lazily, against the object's own class
##
## `fast.bindMethod(rt, "EFT.Player", "get_Position", 0)` binds the method
## declared on `EFT.Player`. A bound call is a direct call to a compiled
## function -- it is **non-virtual by construction**. If the object in hand is a
## subclass that overrides the member, a binding taken against the base class
## silently calls the base implementation. On this game that is not a corner
## case: bots, the human player and the observed-player proxies are different
## `Player` subclasses.
##
## So `LazyCall` binds on the first object it is used with, against
## `il2cpp_object_get_class(obj)` -- the object's *actual* class -- and rebinds
## if it is later handed an object of a different class. The cost is one pointer
## comparison per call. What it buys is that the call is the one the game would
## have made.
##
## It also solves what `findClass` cannot. A `List<Player>`, a bot's memory
## class, a steering component: most of the graph SAIN walks has either a
## generic-instantiated name that `findClass` will not resolve or a name that
## moves between client versions. Binding from an instance needs neither.
##
## ## What is asserted and what is asked
##
## One thing in this file is asserted rather than asked: the native slot shape
## of a call that passes or returns a `Vector3`. `aowlspt/fast` classifies
## register classes and correctly refuses a 12-byte aggregate, which Win64 moves
## into memory and passes by hidden pointer instead. `tryShaped` states that
## shape through `fast.bindRaw`, guarded three ways, and falls back to
## `il2cpp_runtime_invoke` whenever a guard does not hold. It is the sharpest
## thing here and it is commented as such at the point where it happens.
##
## Nothing in this file has been run against Tarkov. Every member name below is
## a name from the pre-1.0 C# surface, and post-1.0 is a different build; a name
## that is wrong produces a refused binding with a `why` line in the log and a
## defaulted value, never a wrong number. `report()` prints every one of them
## once. That is the design: this file fails loudly and partially, and the
## decision core keeps running on defaults for whatever it could not read.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import ".." / core / vec
import ".." / core / sig
import rvatable

# ---------------------------------------------------------------------------
# The runtime
# ---------------------------------------------------------------------------

## Assigned from `openLive()`, never at its declaration: in a nimony
## `--app:lib` build a global initialised by a *call* is silently left zeroed,
## so `var gRt = openIl2Cpp()` would produce a runtime that is never loaded and
## a mod that quietly does nothing.
var gRt: Il2Cpp
var gLive = false

proc liveReady*(): bool = gLive

proc openLiveAt*(path: string; domainName: string): bool =
  ## The same as `openLive`, against a runtime loaded from a path rather than
  ## found in the process.
  ##
  ## Only the self-test uses this, and it is the whole of how the binding half
  ## of this mod is exercised without Tarkov: `aowl test` builds
  ## `tests/mockil2cpp` into a `GameAssembly.dll` implementing the same C API,
  ## and `config.json`'s `selfTestRuntime` points at it. Out of process the
  ## runtime is loaded but not *started*, so `il2cpp_init` is called too; on a
  ## real client that will very likely refuse, because the metadata is
  ## decrypted during the game's own startup. A refusal is a real answer and
  ## the caller reports it as one. This is `mods/morebots`' pattern.
  if gLive:
    return true
  gRt = openIl2Cpp(path)
  if not gRt.loaded:
    return false
  if gRt.has(eInit):
    discard gRt.init(domainName)
  gLive = true
  result = true

proc openLive*(): bool =
  ## Binds `GameAssembly.dll` if it is in the process. Cheap to call again once
  ## it has succeeded; retried while it has not, because "the game has not got
  ## that far yet" and "this is not the game" look the same from here and only
  ## one of them is final.
  ##
  ## The three sub-steps announce themselves, for the reason `mods/fov`'s
  ## `openRuntime` does: a crash inside `openIl2Cpp` and a crash inside
  ## `missingEssential` are different bugs and "somewhere in openLive" cannot
  ## tell them apart.
  if gLive:
    return true
  info "sain: openLive step 1/3 -- opening GameAssembly.dll from the mod"
  gRt = openIl2Cpp()
  info "sain: openLive step 2/3 -- GameAssembly.dll bound, loaded=" &
       $gRt.loaded
  if not gRt.loaded:
    return false
  let missing = missingEssential(gRt)
  info "sain: openLive step 3/3 -- essential entry points checked, " &
       $missing.len & " missing"
  if missing.len > 0:
    # Refusing here rather than at the first call: a runtime missing
    # `il2cpp_object_get_class` cannot do lazy binding at all, and finding that
    # out per bot per frame would be a log full of the same line.
    warn "sain: the IL2CPP runtime is missing " & $missing.len &
         " essential entry points; the fast path is unavailable"
    return false
  gLive = true
  result = true

# ---------------------------------------------------------------------------
# THE LIVE GameWorld, BORROWED FROM THE HOST
# ---------------------------------------------------------------------------
#
# THE GENERAL RULE THIS BUILD ESTABLISHES, and everything below is one instance
# of it: **a by-name bind that "succeeds" proves nothing.** Resolving is
# harmless; CALLING is what kills. Only a byte-verified static RVA, a measured
# static field offset, or a host export is callable.
#
# `EFT.GameWorld::get_Instance` DOES NOT EXIST on this build. MEASURED:
# `tools/il2cpp_resolve.py <GameAssembly.dll> <metadata.dec> type 6172
# --shared` dumps all 409 members of `EFT.GameWorld` and there is not one
# case-insensitive match for "instance". `mods/fov` measured the same thing
# independently (fact #136).
#
# What used to happen here is the whole bug, in three steps:
#   1. `bindAll` resolved `get_Instance` BY NAME and reported success.
#   2. Fact #35 -- by-name resolution returns NON-NIL handles into UNMAPPED
#      memory -- so that "success" was a garbage pointer that passed a nil
#      check and was reported in the log as a working binding.
#   3. `probe` step 5/7 CALLED through it: a jump into unmapped memory, and the
#      client died instantly, with no dump and no event-log entry.
#
# `Comfort.Common.Singleton<GameWorld>._instance` is closed too: it is a static
# on a GENERIC INSTANTIATION, whose storage is allocated at runtime and has no
# static address at all (measured by the admin work; see `abi/aowlspt_admin.h`).
#
# So the world is BORROWED. The host caches it from its own read-only detour on
# `EFT.GameWorld::RegisterPlayer` (RCX = the GameWorld) and exports it
# read-only. We ride that detour rather than binding a second one, because a
# second detour on one function overwrites the first's trampoline and silently
# kills the first feature (CLAUDE.md 5). This installs nothing, patches
# nothing and writes nothing.
#
# Resolved lazily through `GetProcAddress`, so an older host is a clean
# "unavailable" rather than a load failure. Same route `mods/admin` takes in
# `abi/aowlspt_admin.h`; written in nimony here rather than through that header
# because that header is admin's and this needs two symbols, not a C shim.
#
# NULL IS THREE ANSWERS AND MUST NOT BE FLATTENED. `gwState` keeps them apart,
# and CLAUDE.md 9b is why: "I could not look" is not "no raid".

# `GetModuleHandleA`, not the W form `aowlspt/il2cpp` uses internally: the
# module name is pure ASCII and the wide path would need `WideCString`, which
# that module does not re-export. One less type crossing a module boundary for
# no gain.
# `GetModuleHandleA`, not the W form `aowlspt/il2cpp` uses internally: the
# module name is pure ASCII and the wide path would need `WideCString`, which
# that module does not re-export.
proc gwGetModuleHandleA(name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetModuleHandleA", sideEffect.}
proc gwGetProcAddress(module: Il2CppPtr; name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetProcAddress", sideEffect.}

# TWO ONE-LINE THUNKS, and they are here rather than in `abi/aowlspt_shim.h`
# on purpose. nimony refuses `cast[proc(...)](pointer)` outright, so a raw
# address has to be called through C. The shim header has `aowl_p_v` already
# but no zero-argument int32 form, and adding one to a shared ABI header drops
# every build cache and forces a full 18-minute rebuild (CLAUDE.md 3) for two
# lines used by one file. Local is cheaper and changes nothing anyone else
# compiles.
#
# The int32 form is a REAL int32 thunk rather than reading the low half of
# `aowl_p_v`'s pointer: an int32 return leaves the upper 32 bits of RAX
# undefined, so a pointer-shaped read of it would be a plausible non-zero
# answer for a function that returned 0. That is the kind of check that cannot
# fail, and this is a three-way state where the difference decides whether a
# human is told "no raid" or "nothing is watching".
{.emit: """
#include <stdint.h>
#include <windows.h>
static void*   sain_gw_p_v  (void* f) { return ((void*  (*)(void))f)(); }
static int32_t sain_gw_i32_v(void* f) { return ((int32_t(*)(void))f)(); }

/* A VirtualQuery, restated locally -- the same body as `aowl_is_readable` in
 * abi/aowlspt_shim.h, which is not in this mod's translation unit.
 *
 * WHY THIS FILE NEEDED ONE. `il2cpp_object_get_class` is literally
 * `mov rax,[rcx]; ret`: it validates NOTHING, so a bad receiver yields a
 * plausible non-nil number rather than a nil, and `resolveOn`'s very next
 * statement takes that number to `il2cpp_class_get_name` -- one of the 38
 * TOKEN-GATED exports, which answers a uniform random NON-ZERO uint64 on gate
 * mismatch. Every nil check on that chain PASSES and the first dereference is
 * 0xC0000005. That is fact #198, and it is exactly how `fov.dll` killed the
 * client. A nil check is not a check here; this is. */
static int32_t sain_is_readable(void* p, int32_t size) {
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

/* The two primitives the RVA table needs and nothing else in this file did.
 *
 * `sain_rva_exec_readable` is DELIBERATELY stricter than `sain_is_readable`: a
 * call target must be COMMITTED EXECUTABLE memory, not merely readable. A
 * static RVA that has gone stale across a Tarkov update can land in a data
 * section that reads back perfectly well, and calling into one is a crash with
 * no diagnostic. Insisting on an executable protection is what makes a stale
 * RVA a refusal instead. */
static uint8_t sain_byte_at(void* p, uint64_t off) {
    return ((const uint8_t*)p)[off];
}
static void* sain_ptr_add(void* p, int64_t d) {
    return (void*)((uintptr_t)p + (uintptr_t)d);
}
/* The two primitives the FIELD path reads through. Neither validates anything:
 * `sain_is_readable` is called on `(base + off)` for the exact width first, at
 * every hop, by the Nim caller. They are separate from `sain_byte_at` only
 * because a field read is a different operation from a prologue compare and
 * conflating them would let a prologue check silently accept a data page. */
static void* sain_fld_ptr(void* p, int64_t off) {
    return *(void* const*)((uintptr_t)p + (uintptr_t)off);
}
static int32_t sain_fld_u8(void* p, int64_t off) {
    return (int32_t)(*(const uint8_t*)((uintptr_t)p + (uintptr_t)off));
}
static int32_t sain_rva_exec_readable(void* p, int32_t size) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || size <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY))) return 0;
    {   uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)p + (uintptr_t)size;
        if (need < (uintptr_t)p) return 0;   /* overflow */
        return need <= end ? 1 : 0;
    }
}

/* THE ONLY WAY THIS MOD MAY REACH A TOKEN-GATED IL2CPP EXPORT.
 *
 * `aowl_host_gate_call` is a single `__declspec(dllexport)` symbol on
 * aowlspt-host-il2cpp.dll. The host arms and CONSUMES the nonce in the same
 * breath, so nothing here ever sees a TLS slot -- which matters, because an
 * armed-but-unconsumed slot removes the early-out that is the only reason this
 * mod's ~20 stock-signature by-name calls returned garbage instead of faulting
 * inside the gate's own memcmp.
 *
 * The host owns the fault guard. Nothing here wraps one: `aowl_p_p_seh` is not
 * re-entrant and an outer guard would be DISARMED by an inner one. */
typedef int (*sain_gate_fn_t)(const char*, void**, int, void**, int*,
                              const char**, int*);
static const char* sain_gate_last_why_s = "the host gate export was never called";
static int sain_gate_call(void* f, const char* name, int argc,
                          void* a0, void* a1, void* a2,
                          void** out_ret, int* out_why, int* out_outstanding) {
    void* argv[3];
    const char* wt = 0;
    int r;
    if (out_ret) *out_ret = 0;
    if (out_why) *out_why = -1;
    if (out_outstanding) *out_outstanding = -1;
    if (!f || !name || argc < 0 || argc > 3) return 0;
    argv[0] = a0; argv[1] = a1; argv[2] = a2;
    r = ((sain_gate_fn_t)f)(name, argv, argc, out_ret, out_why, &wt,
                            out_outstanding);
    if (wt) sain_gate_last_why_s = wt;
    return r;
}
static const char* sain_gate_last_why(void) { return sain_gate_last_why_s; }
""".}

proc sainGwPV(f: Il2CppPtr): Il2CppPtr {.importc: "sain_gw_p_v", nodecl.}
proc sainGwI32V(f: Il2CppPtr): int32 {.importc: "sain_gw_i32_v", nodecl.}
proc sainIsReadable(p: Il2CppPtr; size: int32): int32 {.
  importc: "sain_is_readable", nodecl.}
proc sainByteAt(p: Il2CppPtr; off: uint64): uint8 {.
  importc: "sain_byte_at", nodecl.}
proc sainPtrAdd(p: Il2CppPtr; d: int64): Il2CppPtr {.
  importc: "sain_ptr_add", nodecl.}
proc sainExecReadable(p: Il2CppPtr; size: int32): int32 {.
  importc: "sain_rva_exec_readable", nodecl.}

proc sainFldPtr(p: Il2CppPtr; off: int64): Il2CppPtr {.
  importc: "sain_fld_ptr", nodecl.}
proc sainFldU8(p: Il2CppPtr; off: int64): int32 {.
  importc: "sain_fld_u8", nodecl.}

proc sainReadable(p: Il2CppPtr; size: int): bool =
  result = p != nil and sainIsReadable(p, int32(size)) != 0'i32

const UnityCachedPtrOff = 0x10
  ## `UnityEngine.Object.m_CachedPtr`, the pointer to the native half.
  ##
  ## NOT measured here and deliberately not re-derived: this is the same
  ## constant `host/Aowlspt.Host.Il2Cpp/aowlscene.nim` and `inspect.nim` already
  ## use across the whole inspector, on this same build, and the host exports it
  ## as `aowl_nav_off_cachedptr`. It is BORROWED, and saying so is the point.
  ##
  ## Why it matters here: **readability is not liveness on this build.** A
  ## destroyed `MonoBehaviour` keeps a perfectly readable managed shell whose
  ## `m_CachedPtr` is zero, and any engine-side call on it faults inside Unity
  ## rather than in our code. So a receiver that is about to feed a bound
  ## INTERNAL CALL is checked for a non-null native half first; a receiver we
  ## only read a managed field off does not need it, and rows say which they are.

proc sainUnityAlive(p: Il2CppPtr): bool =
  ## True when `p` is readable through `m_CachedPtr` AND that pointer is
  ## non-null. Three outcomes collapse to two here on purpose: unreadable and
  ## dead are both "do not proceed", and the caller states which it saw.
  if not sainReadable(p, UnityCachedPtrOff + 8):
    return false
  result = sainFldPtr(p, int64(UnityCachedPtrOff)) != nil

var gGwFn: Il2CppPtr = cast[Il2CppPtr](0)
var gGwArmedFn: Il2CppPtr = cast[Il2CppPtr](0)
var gGwTried = false

proc gwResolve() =
  if gGwTried:
    return
  gGwTried = true
  var hostName = "aowlspt-host-il2cpp.dll"
  let h = gwGetModuleHandleA(toCString(hostName))
  if h == nil:
    return
  var n1 = "aowl_host_gameworld"
  var n2 = "aowl_host_gameworld_armed"
  gGwFn = gwGetProcAddress(h, toCString(n1))
  gGwArmedFn = gwGetProcAddress(h, toCString(n2))

proc sainGateCall(f: Il2CppPtr; name: cstring; argc: int32;
                  a0, a1, a2: Il2CppPtr; outRet: ptr Il2CppPtr;
                  outWhy: ptr int32; outOutstanding: ptr int32): int32 {.
  importc: "sain_gate_call", nodecl.}
proc sainGateLastWhy(): cstring {.importc: "sain_gate_last_why", nodecl.}

var gGateFn: Il2CppPtr = cast[Il2CppPtr](0)
var gGateTried = false
var gGateNoted = false

proc gateResolve() =
  ## Resolve the host's ONE gate export, exactly as `gwResolve` resolves the
  ## GameWorld one. Absence is a real, expected state -- an older host, or this
  ## code running outside the client -- and it must produce a REFUSAL, never a
  ## fallback to the un-tokened call, which is the fatal path.
  if gGateTried:
    return
  gGateTried = true
  var hostName = "aowlspt-host-il2cpp.dll"
  let h = gwGetModuleHandleA(toCString(hostName))
  if h == nil:
    return
  var n = "aowl_host_gate_call"
  gGateFn = gwGetProcAddress(h, toCString(n))

proc gateAvailable*(): bool =
  ## Only that the SYMBOL is present. It says nothing about the `il2cppGates`
  ## flag, which is default OFF -- with the flag off every call still refuses,
  ## with `why` = "the il2cppGates flag is off". Structural is not behavioural.
  gateResolve()
  result = gGateFn != nil

proc gateWhyText*(): string =
  ## The host's own explanation of the last refusal, not one this mod invented.
  readCString(cast[Il2CppPtr](sainGateLastWhy()))

proc gateClassFromName*(rt: Il2Cpp; image: Il2CppImage;
                        ns, name: string): Il2CppClass =
  ## `il2cpp_class_from_name` THROUGH the token gate. Three outcomes, and the
  ## caller can tell them apart: a class, or nil with `gateWhyText()` saying
  ## either "no host export" or the host's own refusal code.
  ##
  ## What a working gate does NOT buy: resolution by name becomes POSSIBLE, not
  ## SAFE. 28.3% of by-name METHOD lookups land on a SHARED RVA, and this build
  ## has a universal empty-body stub at 0x628110 shared by 6,438 methods, so a
  ## resolved and signature-checked address can still be a no-op. Calling a
  ## shared address is fine; DETOURING one fires for every other owner.
  result = nullPtr()
  if not gateAvailable():
    if not gGateNoted:
      gGateNoted = true
      warn "sain: no host export aowl_host_gate_call -- this host predates " &
           "the token-gate export layer. By-name resolution stays REFUSED; " &
           "there is deliberately no un-tokened fallback, because that call " &
           "returns a plausible random handle and kills the client."
    return
  if image == nil:
    return
  var n1 = ns
  var n2 = name
  var ret: Il2CppPtr = cast[Il2CppPtr](0)
  var why: int32 = -1'i32
  var outstanding: int32 = -1'i32
  # `toCString` takes its string by `var`, so the export name needs a local.
  var exportName = "il2cpp_class_from_name"
  let ok = sainGateCall(gGateFn, toCString(exportName), 3'i32,
                        image, cast[Il2CppPtr](toCString(n1)),
                        cast[Il2CppPtr](toCString(n2)),
                        addr ret, addr why, addr outstanding)
  if ok == 0'i32:
    debug "sain: gated il2cpp_class_from_name(" & ns & "." & name &
          ") refused: " & gateWhyText()
    return
  # ASSERT THE NEGATIVE, per CLAUDE.md 9b: nothing may be left ARMED on this
  # thread. A leaked arm is not a slow leak -- it removes the zero-slot
  # early-out for the NEXT stock-signature caller anywhere in the process, and
  # that faults inside GameAssembly+0x6206E0.
  if outstanding != 0'i32:
    warn "sain: gated call left " & $outstanding & " nonce arm(s) OUTSTANDING " &
         "-- treating the result as INCONCLUSIVE and refusing it."
    return
  # `ret != nil` proves NOTHING on its own: the trap never returns NULL. The
  # gate's own verdict (`ok`) is the check; this is only a readability hop.
  if not sainReadable(ret, 8):
    return
  result = ret

proc gateFindClass*(rt: Il2Cpp; qualified: string): Il2CppClass =
  ## `findClass`, but every `classFromName` hop goes through the gate. Same
  ## all-images search as `aowl/src/aowlspt/il2cpp.nim`, because a type moves
  ## between assemblies across Tarkov releases.
  result = nullPtr()
  if not rt.loaded:
    return
  if not gateAvailable():
    discard gateClassFromName(rt, cast[Il2CppImage](0), "", "")  # logs once
    return
  var ns = ""
  var name = ""
  splitTypeName(qualified, ns, name)
  let domain = rt.domainGet()
  if domain == nil:
    return
  var count = 0
  let assemblies = rt.domainGetAssemblies(domain, count)
  if assemblies == nil:
    return
  # rule 4: capped. 512 assemblies is far past any real domain.
  var lim = count
  if lim > 512:
    lim = 512
  for i in 0 ..< lim:
    let image = rt.assemblyGetImage(assemblyAt(assemblies, i))
    if image == nil:
      continue
    let c = gateClassFromName(rt, image, ns, name)
    if c != nil:
      return c

proc gwState*(): int =
  ## 0 no host export (host too old, or this is not the client)
  ## 1 export present but NO detour armed -- INCONCLUSIVE, not "no raid"
  ## 2 armed, cache empty -- genuinely not in a raid
  ## 3 world live
  gwResolve()
  if gGwFn == nil:
    return 0
  if gGwArmedFn != nil and sainGwI32V(gGwArmedFn) == 0'i32:
    return 1
  if sainGwPV(gGwFn) == nil:
    return 2
  result = 3

proc gwStateText*(): string =
  case gwState()
  of 0: "no host export aowl_host_gameworld -- this host predates it, or " &
        "this mod is not running in the client. There is no fallback: " &
        "EFT.GameWorld::get_Instance does not exist on this build (measured, " &
        "409 members, no match for 'instance') and none is invented"
  of 1: "the host exports the world but NO detour is armed to populate it -- " &
        "set the host flag debugEsp or botDiag. INCONCLUSIVE, not 'no raid'"
  of 2: "armed; no GameWorld cached yet, which is what a menu looks like"
  else: "GameWorld live, borrowed from the host's RegisterPlayer cache"

# ---------------------------------------------------------------------------
# Asking the runtime what a method is
# ---------------------------------------------------------------------------
#
# AND WHY IT NO LONGER ASKS.
#
# The three procs below -- `signatureOf`, `staticMethodOf`, `payloadSizeOf` --
# are the ONLY places this mod resolves anything by NAME through the IL2CPP C
# API. Every one of them is `findClass` + `findMethod` (or `findClass` +
# `classInstanceSize`) followed by a DEREFERENCE of the handle that comes back.
#
# On this build that is fatal. Fact #35, measured by a two-thread controlled
# experiment: `il2cpp_class_from_name` and
# `il2cpp_class_get_method_from_name` return NON-NIL pointers into UNMAPPED
# memory -- on Unity's own main thread as much as anywhere else. So the `if
# cls == nil` guards below are checks that CANNOT FAIL (CLAUDE.md 9b), the
# resolution reads as a success, and the process dies at the first field read
# through the handle.
#
# MEASURED, in this client, by the breadcrumb run this gate was written for:
# the last line the mod ever logged was `bindProbe 1/2 --
# UnityEngine.Physics::Raycast`, and `bindRaycast`'s first statement is
# `signatureOf`. `armAimHook` and `armDamageHook` call it too and would have
# reached the identical fault about a tenth of a second later.
#
# The other ~70 bindings survive because they never do this: `lazy` builds a
# record and resolves against the class of a receiver at CALL time, and
# `bindMethodAs` goes through the HOST's name index rather than the runtime's.
#
# So: refused, once, loudly, unless `allowIl2cppReflection` is set in
# `config.json`. A feature that declines and says so beats one that kills the
# client. What each caller loses is written at the call site, not here.
var gAllowReflection = false
var gReflectionNoted = false

proc setAllowReflection*(v: bool) =
  ## From `onLoad`, out of the preset. Default false.
  gAllowReflection = v

proc reflectionAllowed*(): bool = gAllowReflection

# --- the RVA table gate. Default OFF, like every new live path in this repo.
#
# ON, a member carrying an `rvaKey` is resolved from `client/rvatable.nim` --
# a static RVA, byte-verified, called directly, with the token-gated export ABI
# never touched. OFF, the whole mod behaves exactly as it did before this file
# existed: `ensure` refuses at `reflectionRefused()` and every sensor declines.
#
# There is deliberately NO state in between and no fallback FROM the table TO
# the by-name path. A key that the table refuses is refused, permanently, by
# name, in the log. Falling back would reinstate precisely the fatal call this
# whole change removes.
var gRvaTable = false
var gRvaRows: seq[SainRvaRow] = @[]
var gRvaFieldRows: seq[SainRvaFieldRow] = @[]
var gRvaRefusals: seq[SainRvaRefusal] = @[]
var gRvaLoaded = false
var gRvaVerified = 0
var gRvaFieldBound = 0
var gRvaRejected = 0
var gRvaRefused = 0
var gRvaFaults = 0
var gRvaFieldFaults = 0

const FieldFaultCap = 16
  ## Self-disable for the FIELD path, counted separately from `RvaFaultCap`.
  ##
  ## Separate because the two failures mean different things. A prologue
  ## mismatch is "the image moved"; a field hop that will not validate is "this
  ## receiver was not what the chain promised", which in a raid can happen a few
  ## times legitimately (an object collected between two hops) and then must
  ## stop happening. Sixteen is a budget, not a threshold: past it the field
  ## path turns itself off for the session rather than re-guessing every frame.

const RvaFaultCap = 8
  ## Self-disable. A bind that cannot verify its prologue is not retried
  ## forever: after this many the table turns itself off for the session and
  ## says so once, rather than producing the same refusal every frame.

proc setRvaTable*(v: bool) =
  ## From `onLoad`, out of the preset. Default false.
  gRvaTable = v

proc rvaTableOn*(): bool = gRvaTable

var gRvaDriveLevel = 0
var gRvaLevelRefused = 0

const RvaLevelObserver* = 0
const RvaLevelReads* = 1
const RvaLevelAim* = 2
const RvaLevelDrive* = 3

proc setRvaDriveLevel*(v: int) =
  ## `sainRvaTableDriveLevel`, clamped, from `onLoad`.
  ##
  ## FOUR NOTCHES, and they exist because "the table is on" used to mean
  ## "everything the table can do is on". That put `stLookTo` -- a call that
  ## turns a live bot's head -- and `rlTryReload` -- a call that makes it
  ## reload -- behind the same switch as reading a stamina float. A coordinator
  ## raising one raid's worth of risk at a time could not do it, and the only
  ## available granularity was all or nothing.
  ##
  ##   0 OBSERVER -- rows load, the table reports itself, NOTHING binds. Every
  ##                 `ensure` on a keyed member refuses and says why. This is
  ##                 what `sainRvaTable = false` does, except that the report
  ##                 still runs, so a raid at level 0 is a dry run of the
  ##                 refusals with no calls at all.
  ##   1 READS    -- every getter and every field row binds. No call at this
  ##                 level takes an argument or returns void, and the field
  ##                 mechanism has no invoke path, so nothing here can change
  ##                 the game's state.
  ##   2 AIM      -- level 1, plus the two aim-route hops and the postfix on
  ##                 `Aiming::get_IsReady`. Still read-only: the postfix
  ##                 watches (`frameContinue`), and the gate it feeds can only
  ##                 WITHHOLD a shot the decision ladder already ordered.
  ##   3 DRIVE    -- level 2, plus the calls that make a bot do something:
  ##                 `stLookTo` and `rlTryReload`. Every other drive member
  ##                 SAIN asks for is a stated refusal, so level 3 is TWO
  ##                 calls and not a combat brain. Saying that here rather
  ##                 than letting the name imply otherwise.
  if v < RvaLevelObserver:
    gRvaDriveLevel = RvaLevelObserver
  elif v > RvaLevelDrive:
    gRvaDriveLevel = RvaLevelDrive
  else:
    gRvaDriveLevel = v

proc rvaDriveLevel*(): int = gRvaDriveLevel

proc rvaLevelName*(v: int): string =
  case v
  of RvaLevelObserver: "0 OBSERVER (nothing binds)"
  of RvaLevelReads:    "1 READS"
  of RvaLevelAim:      "2 AIM"
  else:                "3 DRIVE"

proc rvaLevelRefusals*(): int = gRvaLevelRefused

proc rvaLoad() =
  if gRvaLoaded:
    return
  gRvaLoaded = true
  gRvaRows = sainRvaRows()
  gRvaFieldRows = sainRvaFieldRows()
  gRvaRefusals = sainRvaRefusals()

const ReflectionRefusal* =
  # THIS SENTENCE WAS WRONG ABOUT THE MECHANISM AND USERS READ IT.
  # "Handles into unmapped memory" was the SYMPTOM. Measured offline
  # (docs/IL2CPP_EXPORTS.md): this is stock IL2CPP behind a TOKEN-GATED export
  # ABI. 40 of the 241 exports take an undocumented trailing pointer to 32
  # bytes and memcmp it; on a mismatch -- every call we make, since we never
  # pass a token -- they return a UNIFORM RANDOM NON-ZERO uint64 from a
  # per-thread MT19937-64. Nothing faults at the call. The distinction matters
  # because "it is broken" invites hunting for a working variant, while "it
  # answers a random number that passes every check you can write" says why no
  # run-time check can save it -- and why the fix is to resolve OFFLINE
  # (abi/aowlspt_symbols.txt -> client/drivecalls.nim) rather than check harder.
  "IL2CPP by-name resolution is refused on this build. " &
  "il2cpp_class_from_name and il2cpp_class_get_method_from_name are " &
  "TOKEN-GATED: they take a trailing 32-byte token the stock signature does " &
  "not have, and on a mismatch they do not fail -- they return a uniform " &
  "random non-zero uint64 (measured offline, docs/IL2CPP_EXPORTS.md). So a " &
  "nil check passes, every signature check runs happily on a random number, " &
  "and the first real dereference kills the client with a log identical to a " &
  "healthy run. There is no run-time check that can catch this, which is why " &
  "the fix is to resolve OFFLINE (abi/aowlspt_symbols.txt -> " &
  "client/drivecalls.nim) rather than to check harder. Set " &
  "allowIl2cppReflection in config.json only to re-measure on a future build."

proc reflectionRefused*(where: string = ""): bool =
  ## True when the caller must not resolve by name. Says so once per session:
  ## three callers times a retry loop would otherwise be a log full of one
  ## sentence. Callers that write their own refusal into a `why` string pass
  ## no `where` and say the rest themselves.
  if gAllowReflection:
    return false
  if not gReflectionNoted:
    gReflectionNoted = true
    warn "sain: " & ReflectionRefusal
  if where.len > 0:
    debug "sain: by-name resolution refused for " & where
  result = true


proc signatureOf*(owner, member: string; argc: int;
                  params: var seq[string]; ret: var string): bool =
  ## The declared parameter types and return type of a method, from the
  ## runtime's own metadata. `argc` of -1 matches any arity, exactly as the
  ## host's `patch` does.
  ##
  ## This exists for the two typed hooks in `sain.nim`, and it exists because
  ## a typed hook reads registers by declared *kind*. A JSON payload is
  ## self-describing and a mod can look at what turned up; a register frame is
  ## not, and the mod has to know the signature before it installs the patch or
  ## it is reading whatever the game left in RCX. So every hook here checks the
  ## shape against the runtime first and refuses by name when it does not
  ## match -- the same discipline `LazyCall` applies to a binding, applied to a
  ## detour.
  params = @[]
  ret = ""
  if not gLive:
    return false
  if reflectionRefused(owner & "::" & member):
    return false
  let cls = gateFindClass(gRt, owner)
  if cls == nil:
    return false
  let m = findMethod(gRt, cls, member, argc)
  if m == nil:
    return false
  let n = methodParamCount(gRt, m)
  for i in 0 ..< n:
    params.add typeName(gRt, methodParam(gRt, m, i))
  ret = typeName(gRt, methodReturnType(gRt, m))
  result = true

proc describeSig*(params: seq[string]; ret: string): string =
  result = "("
  for i in 0 ..< params.len:
    if i > 0: result.add ", "
    result.add params[i]
  result.add ") -> " & ret

# ---------------------------------------------------------------------------
# Reading a struct return
# ---------------------------------------------------------------------------
#
# `il2cpp_runtime_invoke` hands a value-type return back *boxed*.
# `il2cpp_object_unbox` gives the address of the payload, and for a
# `UnityEngine.Vector3` the payload is three consecutive 32-bit floats. That
# layout is Unity's public API surface rather than an internal detail, so
# reading it by offset is safe in a way that reading an EFT class by offset
# would not be.
#
# The reader is a `fast.FieldBinding` built by hand at offsets 0, 4 and 8.
# `bindField` would refuse those -- offset 0 is the object header on a
# *reference* type -- and it is right to. These are offsets into an unboxed
# value rather than into an object, so the guard does not apply, and the read
# is the same single load it would be otherwise.

var gF0: FieldBinding
var gF4: FieldBinding
var gF8: FieldBinding
var gI0: FieldBinding
var gB0: FieldBinding

proc initFloatReaders() =
  gF0 = FieldBinding(ok: true, why: "", target: "unboxed+0", offset: 0'i32,
                     kind: fkF32, bindNs: 0'i64)
  gF4 = FieldBinding(ok: true, why: "", target: "unboxed+4", offset: 4'i32,
                     kind: fkF32, bindNs: 0'i64)
  gF8 = FieldBinding(ok: true, why: "", target: "unboxed+8", offset: 8'i32,
                     kind: fkF32, bindNs: 0'i64)
  gI0 = FieldBinding(ok: true, why: "", target: "unboxed+0", offset: 0'i32,
                     kind: fkI32, bindNs: 0'i64)
  # A boxed `System.Boolean` is one byte. Reading four would run past the
  # payload of the smallest box the runtime allocates, which is the kind of
  # read that is right until the day it is not.
  gB0 = FieldBinding(ok: true, why: "", target: "unboxed+0", offset: 0'i32,
                     kind: fkBool, bindNs: 0'i64)

proc unboxVec3(boxed: Il2CppPtr): Vec3 =
  result = zeroVec()
  if boxed == nil:
    return
  let p = objectUnbox(gRt, boxed)
  if p == nil:
    return
  result = vec3(readFloat(gF0, p), readFloat(gF4, p), readFloat(gF8, p))

proc unboxFloat(boxed: Il2CppPtr): float =
  result = 0.0
  if boxed == nil:
    return
  let p = objectUnbox(gRt, boxed)
  if p == nil:
    return
  result = readFloat(gF0, p)

proc unboxInt(boxed: Il2CppPtr): int =
  result = 0
  if boxed == nil:
    return
  let p = objectUnbox(gRt, boxed)
  if p == nil:
    return
  result = int(readInt32(gI0, p))

# ---------------------------------------------------------------------------
# LazyCall
# ---------------------------------------------------------------------------

type
  CallShape* = enum
    ## How a bound `Binding` is to be called.
    ##
    ## `csPlain` is `fast`'s own convention: the call site hands over the
    ## declared arguments and the binding supplies `this`. The two shaped forms
    ## are calls whose *native* slot count differs from their declared argument
    ## count, because Win64 moves a struct wider than eight bytes into memory
    ## and passes its address -- see `shapedWhy` below for the whole argument.
    csNone                 ## not on the fast path at all; use `m` reflectively
    csPlain
    csStructReturn         ## slot 0 is a hidden return pointer, slot 1 is `this`
    csVectorArg            ## slot 0 is `this`, slot 1 is a pointer to the value

  SlotFill* = enum
    ## What goes in one declared argument's native slot on a shaped call.
    ##
    ## Decided at bind time from the runtime's own declared parameter types, so
    ## nothing here is a guess about the *signature*; the guess is only about
    ## the convention, and it is the same one guess in every case.
    sfValuePtr             ## the caller's Vector3, by address
    sfFlagBool             ## the one bool the caller cares about
    sfZero                 ## an int, an enum, or a null reference
    sfNegFloat             ## a float: -1, EFT's own "no preference"

  LazyCall* = object
    ## One member, resolved against the class of the object it is first used
    ## with, and re-resolved if that class changes.
    ##
    ## `b.ok` says a fast path took it, and `shape` says which: `csPlain` is
    ## `fast`'s own convention, and the two shaped forms are the ones this mod
    ## asserts a calling convention for -- see `tryShaped`.
    ##
    ## `m` is the `MethodInfo*` either way, so a member no fast path will take
    ## -- an enum argument, a value-type return that is not a plain aggregate --
    ## is still reachable through `il2cpp_runtime_invoke`, which is a boxing
    ## call rather than a register call but is still nowhere near the host's
    ## 1235 ns. That is the split `docs/PERF.md` describes, made per member
    ## instead of per module.
    member*: string
    argc*: int32
    argcAlts*: seq[int32]   ## other arities to try; EFT overloads by arity
    kinds*: seq[FastKind]   ## empty => infer from the runtime's metadata
    ret*: FastKind          ## fkNone => infer
    cls*: Il2CppClass       ## the class this is currently bound against
    m*: Il2CppMethod
    b*: Binding
    shape*: CallShape       ## how `b` is to be called, when it is shaped
    fills*: seq[SlotFill]   ## how each declared argument's slot is filled
    ## The declared-signature gate. `gated` says this member is one of the
    ## driving calls and its declared parameter types are to be checked against
    ## `core/sig` before anything is bound; `shapeWanted` says against which of
    ## the three shapes. A member with `gated` false is unaffected -- every
    ## *read* in this file is a getter whose arity is its whole signature, and
    ## a getter that resolved to the wrong overload would have to be an
    ## overloaded no-argument method, which does not exist.
    gated*: bool
    shapeWanted*: DriveShape
    ## True when the gate above is what refused. Separated from an ordinary
    ## miss because the two mean different things to a person reading the log:
    ## `MISSING` is "this build does not have that name", and `REFUSED` is
    ## "this build has that name and it is not the method this mod means".
    gateRefused*: bool
    tried*: bool
    why*: string
    ## The row this member takes from `client/rvatable.nim`, or "" for a member
    ## the table does not cover at all. Non-empty is what routes `ensure` away
    ## from `il2cpp_object_get_class` and the two token-gated name lookups
    ## behind it; empty leaves the old, refused, by-name path exactly as it was.
    rvaKey*: string
    ## True once the table has been consulted for `rvaKey`, whichever way it
    ## answered. Separate from `tried`, which means the by-name path ran.
    rvaTried*: bool
    ## --- THE FIELD PATH. `fldOk` is a THIRD callable state, alongside `b.ok`
    ## (a bound RVA call) and `m != nil` (a reflective call). It means: there is
    ## no function to call at all; the value is a field at `fldOff` on the
    ## receiver, and reading it is the whole operation.
    ##
    ## It is kept as its own state rather than folded into `b` because a
    ## `Binding` is a call and this is not one. Nothing here can be invoked,
    ## which is why "no drive call is expressible through the field path" is a
    ## structural fact and not a review promise.
    fldOk*: bool
    fldOff*: int
    fldKind*: FastKind
    fldNeedsPlayer*: bool
    fldUnityObj*: bool   ## check m_CachedPtr on the receiver before reading
    levelSaid*: bool
    ## Whether the drive-level refusal has already been logged for this member.
    ## One line per member per session, not one per frame -- and deliberately
    ## NOT `rvaTried`, which would freeze the refusal in place; see `ensure`.

proc emptyBinding(): Binding =
  Binding(ok: false, why: "", target: "", fn: cast[Il2CppPtr](0),
          info: cast[Il2CppPtr](0), argc: 0'i32, slots: 0'i32, mask: 0'u32,
          ret: fkNone, isStatic: false, bindNs: 0'i64)

proc lazy*(member: string; argc: int32 = 0'i32): LazyCall =
  ## A member whose signature the runtime is asked for.
  LazyCall(member: member, argc: argc, argcAlts: @[], kinds: @[],
           ret: fkNone, cls: cast[Il2CppClass](0), m: cast[Il2CppMethod](0),
           b: emptyBinding(), shape: csNone, fills: @[],
           gated: false, shapeWanted: dsNoArgs, gateRefused: false,
           tried: false, why: "", rvaKey: "", rvaTried: false,
           fldOk: false, fldOff: 0, fldKind: fkNone, fldNeedsPlayer: false,
           fldUnityObj: false, levelSaid: false)

proc keyed*(l: LazyCall; key: string): LazyCall =
  ## Point a member at its row -- or its refusal -- in `client/rvatable.nim`.
  ##
  ## The key is the `SainBindings` FIELD name, not the member name, because two
  ## different fields legitimately ask for the same member on different classes
  ## (`faHave` and `stimHave` are both `get_HaveSmth2Use`) and they resolve
  ## differently. `tools/idxbind.py` checks that every key handed to this proc
  ## in `bindAll` names a row or a refusal that actually exists, so a typo is a
  ## BUILD failure rather than a member that silently falls back to nothing.
  result = l
  result.rvaKey = key

proc lazyAs*(member: string; kinds: openArray[FastKind];
             ret: FastKind): LazyCall =
  ## A member whose signature is *stated*, for the cases `classifyType`
  ## refuses: an enum parameter is an `Int32` in a register and the C API does
  ## not say which, and a generic instantiation has no name `findClass` accepts.
  result = lazy(member, int32(kinds.len))
  var k: seq[FastKind] = @[]
  for i in 0 ..< kinds.len:
    k.add kinds[i]
  result.kinds = k
  result.ret = ret

proc withGate*(l: LazyCall; shape: DriveShape): LazyCall =
  ## Mark a member as a **driving** call, whose declared parameter types are
  ## checked against `core/sig` before it is bound at all.
  ##
  ## Only the five driving calls and the three self-actions carry this, and the
  ## asymmetry is the point rather than an oversight. Every other member in the
  ## table is a property getter: its arity *is* its signature, there is nothing
  ## for `il2cpp_class_get_method_from_name` to pick wrongly between, and a
  ## name this build does not have refuses on its own. The driving calls are
  ## the opposite -- `GoToPoint` has six arities and this mod walks them, and a
  ## wrong pick does not fail, it drives the bot somewhere.
  result = l
  result.gated = true
  result.shapeWanted = shape

# ---------------------------------------------------------------------------
# Shaped calls: getting Vector3 off the reflective path
# ---------------------------------------------------------------------------
#
# `aowlspt/fast` classifies a signature into register classes and refuses
# anything it cannot. A `Vector3` is refused, and the refusal is right at the
# level it works: 12 bytes is not a register class at all.
#
# But the Win64 convention says what happens instead, and it says it in one
# sentence. **An aggregate whose size is not 1, 2, 4 or 8 bytes is passed by a
# hidden pointer, and returned by one too** -- the caller allocates the space
# and hands over its address, and for a return the callee writes through it and
# gives the address back. So:
#
#     Vector3 Player::get_Position()          is really
#     void*   get_Position(void* sret, void* this, MethodInfo*)
#
#     void Mover::GoToPoint(Vector3 p)        is really
#     void GoToPoint(void* this, void* p, MethodInfo*)
#
# Every slot in both is a plain pointer, which the trampolines already pass.
# `fast.bindRaw` is the way to say so: it takes the *native slot count* rather
# than inferring one from the signature.
#
# **This is an assertion about a calling convention and it is the sharpest
# thing in this mod.** Getting the slot count wrong does not crash -- it reads
# an uninitialised register as an argument and hands the game a plausible
# number. Three guards keep it honest, and every one of them refuses rather
# than assumes:
#
#  1. The shape is only attempted when the runtime *itself* says the type is a
#     value type (`il2cpp_class_is_valuetype`) whose payload size is not one of
#     the four register-sized cases. Nothing is keyed off the name `Vector3`.
#  2. Every other declared parameter is classified from the runtime's declared
#     types too, and a second by-pointer struct, a `double`, or a shape needing
#     more than five native slots refuses the whole thing.
#  3. A refusal is not a failure: `l.m` is still the `MethodInfo`, so the call
#     falls back to `il2cpp_runtime_invoke` exactly as it did before.

const ObjectHeaderFallback = 16
  ## `sizeof(Il2CppObject)` on x64: a class pointer and a monitor pointer.

var gHeaderBytes = -1

proc headerBytes(): int =
  ## How much of a value type's reported instance size is object header --
  ## **asked of the runtime**, not assumed.
  ##
  ## This was the constant 16, which is right for `GameAssembly.dll` and wrong
  ## for a runtime that reports the payload alone. Both conventions are
  ## self-consistent, so neither can be recognised from a single number; the
  ## *difference* between two known types can. `System.Int32` has four bytes of
  ## payload and `System.Double` eight, so whichever convention holds, their
  ## reported sizes differ by four and the header is `size(Int32) - 4`.
  ##
  ## Getting this wrong the other way was harmless but expensive: subtracting a
  ## header that was not there produced a negative payload, every shaped
  ## binding was refused by the sanity range below, and the mod ran the slow
  ## path while its log said it had checked the shape.
  if gHeaderBytes >= 0:
    return gHeaderBytes
  gHeaderBytes = ObjectHeaderFallback
  # GATED, like every other `findClass` in this file. This one was NOT, and
  # that was a hole rather than a decision: `findClass` is
  # `il2cpp_class_from_name`, and `classInstanceSize` two lines below
  # DEREFERENCES what it hands back. The `!= nil` guard cannot fire on a
  # token-gate mismatch, because the trap returns a random NON-ZERO uint64.
  # Refusing costs nothing here -- `ObjectHeaderFallback` is already assigned,
  # and the range check in `byPointerSize` is what makes holding it safe.
  if reflectionRefused("System.Int32 / System.Double"):
    return gHeaderBytes
  let i32 = gateFindClass(gRt, "System.Int32")
  let f64 = gateFindClass(gRt, "System.Double")
  if i32 != nil and f64 != nil:
    let a = classInstanceSize(gRt, i32)
    let b = classInstanceSize(gRt, f64)
    if b - a == 4 and a >= 4:
      gHeaderBytes = a - 4
  result = gHeaderBytes

proc byPointerSize(tn: string): int =
  ## The payload size of a value type Win64 passes by hidden pointer, or 0 when
  ## the type goes in a register (or is a reference, or is unknown).
  ##
  ## The rule is the ABI's, not this mod's: 1, 2, 4 and 8 byte aggregates go in
  ## a general-purpose register; everything else goes to memory.
  result = 0
  if tn.len == 0:
    return
  # GATED, for the same reason as `headerBytes` above: this was the second of
  # the two ungated `findClass` sites in this file, and `classIsValueType` /
  # `classInstanceSize` below both dereference the handle. Returning 0 is the
  # answer every caller already handles as "not a size this understands".
  if reflectionRefused(tn):
    return
  let c = gateFindClass(gRt, tn)
  if c == nil:
    return
  if not classIsValueType(gRt, c):
    return
  let sz = classInstanceSize(gRt, c) - headerBytes()
  if sz <= 0 or sz > 64:
    # Not a size this understands. Refusing here is what makes the header
    # constant above safe to hold.
    return
  if sz == 1 or sz == 2 or sz == 4 or sz == 8:
    return
  result = sz

proc tryShaped(l: var LazyCall; cls: Il2CppClass; owner: string): bool =
  ## Try to express this member as a native slot shape. False leaves the
  ## reflective path in place.
  result = false
  if l.m == nil or cls == nil:
    return
  if methodIsStatic(gRt, l.m):
    # Both shapes below put `this` in a fixed slot. A static method returning a
    # struct has a different shape again, and nothing SAIN reads is one.
    return
  let rtn = typeName(gRt, methodReturnType(gRt, l.m))
  let retSize = byPointerSize(rtn)

  # --- shape one: a struct return with no declared arguments. `get_Position`.
  if retSize > 0:
    if l.argc != 0'i32:
      return                     # a struct return *and* arguments: not needed
    if retSize > 16:
      return                     # wider than the buffer `readVec` provides
    l.b = bindRaw(gRt, cls, owner, l.member, 0, 2, 0'u32, fkPtr)
    if not l.b.ok:
      return
    l.shape = csStructReturn
    l.why = l.b.why & " [hidden return pointer + this; " & rtn & " is " &
            $retSize & " bytes]"
    return true

  # --- shape two: a by-pointer value type as the first argument.
  if l.argc < 1'i32:
    return
  let t0 = typeName(gRt, methodParam(gRt, l.m, 0))
  let argSize = byPointerSize(t0)
  if argSize <= 0 or argSize > 16:
    return
  let slots = 1 + int(l.argc)    # `this`, then every declared argument
  if slots > MaxSlots:
    return
  var mask = 0'u32
  var fills: seq[SlotFill] = @[]
  fills.add sfValuePtr
  var ok = true
  var i = 1
  while i < int(l.argc):
    let tn = typeName(gRt, methodParam(gRt, l.m, i))
    if tn == "System.Double":
      # An XMM slot of a width the trampolines do not carry.
      ok = false
      break
    elif tn == "System.Single":
      # The native slot index is one higher than the declared one, because
      # `this` is slot zero.
      mask = mask or (1'u32 shl uint32(1 + i))
      fills.add sfNegFloat
    elif tn == "System.Boolean":
      fills.add sfFlagBool
    else:
      if byPointerSize(tn) > 0:
        # A second struct by pointer, with no buffer planned for it.
        ok = false
        break
      fills.add sfZero
    inc i
  if not ok:
    return
  l.b = bindRaw(gRt, cls, owner, l.member, int(l.argc), slots, mask, fkVoid)
  if not l.b.ok:
    return
  l.shape = csVectorArg
  l.fills = fills
  l.why = l.b.why & " [this + " & t0 & " by pointer, " & $argSize & " bytes]"
  result = true

# ---------------------------------------------------------------------------
# Resolving
# ---------------------------------------------------------------------------

proc findOn(cls: Il2CppClass; member: string; argc: int32;
            alts: seq[int32]; usedArgc: var int32;
            declaring: var Il2CppClass): Il2CppMethod =
  ## Look a member up on a class, then on each of its ancestors, reporting
  ## which class actually declares it.
  ##
  ## `fast.bindOnObject` does the same walk and would replace this outright but
  ## for one thing: when the fast bind is *refused* it hands back a failed
  ## `Binding` with no `MethodInfo` in it, and this mod's whole fallback story
  ## is that a refused member is still callable reflectively. So the walk is
  ## done once here, for the method, and `bindInClass` is then given the class
  ## it was found on -- which is the class `bindOnObject` would have stopped at.
  ##
  ## `il2cpp_class_get_method_from_name` does not walk the base chain on its
  ## own, and half of what SAIN reads on a bot is declared on `Player` and
  ## reached through a subclass instance. Stopping at the *most derived* class
  ## that declares the member is also what keeps an override reachable: a bound
  ## call is non-virtual, so binding one class too far up calls the base body.
  usedArgc = argc
  declaring = cast[Il2CppClass](0)
  var c = cls
  while c != nil:
    var m = findMethod(gRt, c, member, int(argc))
    if m != nil:
      declaring = c
      return m
    var i = 0
    while i < alts.len:
      m = findMethod(gRt, c, member, int(alts[i]))
      if m != nil:
        usedArgc = alts[i]
        declaring = c
        return m
      inc i
    c = classParent(gRt, c)
  result = cast[Il2CppMethod](0)

proc resolveOn(l: var LazyCall; cls: Il2CppClass) =
  ## Find the member on this class and put it on the best path it will take.
  ##
  ## Three, in order: the ordinary fast path, the shaped fast path for the
  ## by-hidden-pointer cases, and `il2cpp_runtime_invoke` for the rest.
  l.cls = cls
  l.tried = true
  l.m = cast[Il2CppMethod](0)
  l.b = emptyBinding()
  l.shape = csNone
  l.fills = @[]
  l.gateRefused = false
  # `fullName` reaches `il2cpp_class_get_name`, which is TOKEN-GATED: on
  # mismatch it does not return NULL, it returns a uniform random NON-ZERO
  # uint64, and `readCString` then walks it. An EMPTY name is how that now
  # announces itself -- `readCString` VirtualQueries its pointer, re-checks at
  # every page boundary and refuses a byte outside printable ASCII, returning
  # "" rather than faulting. So an empty owner is treated as a REFUSAL here
  # rather than being concatenated into a log line and carried on from.
  let owner = fullName(gRt, cls)
  if owner.len == 0:
    l.why = "::" & l.member & ": the declaring class name came back EMPTY. " &
            "il2cpp_class_get_name is token-gated on this build and answers a " &
            "random non-zero value on mismatch, which readCString refused. " &
            "Nothing was dereferenced and nothing was bound."
    return

  var usedArgc = l.argc
  var declaring: Il2CppClass = cast[Il2CppClass](0)
  let found = findOn(cls, l.member, l.argc, l.argcAlts, usedArgc, declaring)
  if found == nil:
    l.why = owner & "::" & l.member & ": no such member on this class or any " &
            "of its ancestors"
    return
  l.m = found
  l.argc = usedArgc
  # Same empty-name refusal as on `owner` above, and for the same reason: this
  # is a SECOND `il2cpp_class_get_name`, on the base class the member was
  # actually found on, and it is gated identically. A `""` here would be
  # concatenated straight into `bindInClass`'s key.
  let ownerName = fullName(gRt, declaring)
  if ownerName.len == 0:
    l.m = cast[Il2CppMethod](0)
    l.why = owner & "::" & l.member & ": the member was found, but the name " &
            "of the class DECLARING it came back EMPTY -- readCString refused " &
            "what il2cpp_class_get_name answered. Refusing to bind against a " &
            "class this cannot name."
    return

  # --- the declared-signature gate, before anything is bound.
  #
  # `findOn` matched a name and an arity and nothing else. For a driving call
  # that is not enough, and the reason is in `core/sig.nim`: the wrong
  # overload of `GoToPoint` does not fail, it takes the address of this mod's
  # Vector3 as a float and walks the bot at 1.4e-45 metres a second. So the
  # runtime's own declared parameter types are read back and compared, and a
  # mismatch refuses **by name, with the signature the runtime reported** --
  # the same discipline `client/coverprobe.nim` applies to the two Unity
  # statics, applied to the calls that drive.
  #
  # A refusal clears `l.m`, so `ensure` answers false and every call site
  # no-ops. That is deliberate and it is the safe direction: a channel that
  # cannot be driven correctly is not driven at all, and `consequenceOf` says
  # in the log what the bot does instead.
  if l.gated:
    var declared: seq[string] = @[]
    let n = methodParamCount(gRt, found)
    for i in 0 ..< n:
      declared.add typeName(gRt, methodParam(gRt, found, i))
    let rtn = typeName(gRt, methodReturnType(gRt, found))
    var reason = ""
    # The half of the rule `core/sig.nim` cannot decide from a name: whether a
    # trailing parameter is a value type Win64 moves into memory. `checkDrive`
    # refuses the Unity types anybody would meet; this refuses the rest, by
    # measuring, which is the only complete answer. Both paths need it -- the
    # shaped one has no buffer planned for a second struct and the reflective
    # one writes an eight-byte zero slot the callee reads as twelve.
    if l.shapeWanted == dsVectorFirst:
      var i = 1
      while i < declared.len:
        let bp = byPointerSize(declared[i])
        if bp > 0:
          reason = "argument " & $(i + 1) & " is " & declared[i] &
                   ", which the runtime reports as a " & $bp &
                   "-byte value type -- Win64 passes that by hidden pointer " &
                   "and this mod plans one buffer per call, so the slot " &
                   "handed over would be eight zero bytes where the callee " &
                   "reads " & $bp
          break
        inc i
    if reason.len > 0 or not checkDrive(l.shapeWanted, declared, rtn, reason):
      l.m = cast[Il2CppMethod](0)
      l.gateRefused = true
      l.why = "refused: " & ownerName & "::" & l.member & " " &
              describe(declared, rtn) & " -- " & reason & ". Consequence: " &
              consequenceOf(l.shapeWanted)
      return

  # --- the ordinary fast path. Signature stated if the caller stated it,
  # inferred from the runtime's own metadata otherwise.
  var kinds: seq[FastKind] = @[]
  var rk = l.ret
  var classified = true
  if l.kinds.len > 0:
    for i in 0 ..< l.kinds.len:
      kinds.add l.kinds[i]
  else:
    for i in 0 ..< int(usedArgc):
      let tn = typeName(gRt, methodParam(gRt, found, i))
      let k = classifyType(gRt, tn)
      if k == fkNone:
        classified = false
        break
      kinds.add k
  if classified and rk == fkNone:
    rk = classifyType(gRt, typeName(gRt, methodReturnType(gRt, found)))
  if classified and rk != fkNone:
    l.b = bindInClass(gRt, declaring, ownerName, l.member, kinds, rk)
    l.why = l.b.why
    if l.b.ok:
      l.shape = csPlain
      return

  # --- the shaped fast path, for what Win64 moves into memory.
  if tryShaped(l, declaring, ownerName):
    return

  # --- reflective. `l.m` is set, so the member still works; it just costs.
  l.b = emptyBinding()
  l.shape = csNone
  l.why = ownerName & "::" & l.member &
          ": a type the fast path will not classify and a shape it cannot " &
          "express; using il2cpp_runtime_invoke"

# ---------------------------------------------------------------------------
# Resolving from the RVA table instead
# ---------------------------------------------------------------------------

proc rvaHexDigit(v: int): char =
  const D = "0123456789ABCDEF"
  result = D[v and 15]

proc rvaHex2(v: int): string =
  result = ""
  result.add rvaHexDigit(v shr 4)
  result.add rvaHexDigit(v)

proc rvaHexs(v: int): string =
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

proc rvaPrologueMatches(p: Il2CppPtr; expect: string; got: var string): bool =
  ## An exact 16-byte compare against the bytes `il2cpp_resolve.py bytes` read
  ## out of `GameAssembly.dll` on disk, with the LIVE bytes printed on a
  ## mismatch so the refusal carries its own evidence.
  ##
  ## **Compared against live memory, and that is the considered choice rather
  ## than the trap CLAUDE.md warns about.** The startup-snapshot rule exists for
  ## DETOUR targets, where an earlier feature's trampoline makes a correct RVA
  ## self-reject. Nothing in this mod detours any of these 23 -- they are only
  ## ever CALLED -- and `abi/aowlspt_prologue.h`'s table is `static`, i.e. one
  ## per translation unit, so a mod that included it would get its OWN empty
  ## table and lazily capture whatever is there NOW. That is strictly worse
  ## than reading the bytes: it would record a trampoline and then "verify"
  ## against it, which is a check that cannot fail. Reading directly means a
  ## mismatch has exactly two causes -- a stale RVA (a Tarkov update) or
  ## somebody else's hook -- and declining to call is right for both.
  got = ""
  result = false
  if p == nil:
    got = "(null)"
    return
  if sainExecReadable(p, 16) == 0'i32:
    got = "(not committed EXECUTABLE memory -- VirtualQuery refused it)"
    return
  var i = 0
  var ok = true
  while i < 16:
    let b = int(sainByteAt(p, uint64(i)))
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
    got = got & rvaHex2(b)
    inc i
  result = ok

proc resolveFromRva(l: var LazyCall) =
  ## Fill `l` from `client/rvatable.nim`, or refuse out loud. Runs at most once
  ## per member per session; `rvaTried` is what makes that true, so a refusal
  ## is one log line rather than one per frame.
  ##
  ## NOTHING here touches `il2cpp_object_get_class`, `il2cpp_class_from_name`,
  ## `il2cpp_class_get_method_from_name` or `il2cpp_class_get_name`. That is the
  ## entire deliverable: the address comes from a constant, so the token-gated
  ## export ABI is not on the path and no gate can hand back a random non-zero
  ## pointer for a nil check to pass.
  l.rvaTried = true
  l.tried = true
  l.m = cast[Il2CppMethod](0)
  l.b = emptyBinding()
  # (the drive-level gate is in `ensure`, BEFORE this runs -- see there. It is
  # not repeated here, because a member refused by level must not be counted
  # as resolved, and reaching this proc at all sets `rvaTried`.)
  l.shape = csNone
  l.fills = @[]
  l.gateRefused = false
  l.fldOk = false
  l.fldOff = 0
  l.fldKind = fkNone
  rvaLoad()

  # --- a stated refusal comes first, so a key that is BOTH (which would be a
  # table bug) refuses rather than binds.
  var ref0 = emptyRvaRefusal()
  if findRvaRefusal(gRvaRefusals, l.rvaKey, ref0):
    gRvaRefused = gRvaRefused + 1
    l.gateRefused = true
    l.why = "RVA TABLE REFUSES " & l.rvaKey & " (" & ref0.symbol & "): " &
            whyText(ref0.why) & " -- " & ref0.detail &
            ". Measured offline against " & SainRvaScope &
            ". NOT retried by name: the by-name lookup is the fatal path this " &
            "table exists to remove."
    return

  # --- THE FIELD PATH, consulted before the call rows.
  #
  # A field row has no function, so there is no prologue to compare and the
  # 16-byte verify has nothing to verify. Saying that plainly matters more than
  # inventing a substitute: what a field row rests on instead is (a) an offset
  # taken verbatim from `Il2CppMetadataRegistration.fieldOffsets`, (b) a
  # `VirtualQuery` for the exact width at `receiver + off` on EVERY read, at
  # EVERY hop, and (c) the receiver argument written into `row.why`, which is
  # the only thing standing between a correct read and a foreign one. There is
  # no fourth thing and this comment does not pretend there is.
  #
  # It is also, structurally, read-only: nothing below produces a `Binding`, so
  # no call site can invoke a field row even by mistake.
  var frow = emptyRvaFieldRow()
  if findRvaFieldRow(gRvaFieldRows, l.rvaKey, frow):
    if frow.off <= 0 or frow.off > 0x10000:
      gRvaRejected = gRvaRejected + 1
      l.gateRefused = true
      l.why = frow.label & ": field offset 0x" & rvaHexs(frow.off) &
              " is outside the sane range for an instance field (0x1..0x10000)" &
              ". REFUSED; an offset of 0 would read the object header and a " &
              "huge one would read off the end of the object."
      return
    l.fldOk = true
    l.fldOff = frow.off
    l.fldKind = frow.kind
    l.fldNeedsPlayer = frow.needsPlayer
    l.fldUnityObj = frow.unityObj
    gRvaFieldBound = gRvaFieldBound + 1
    l.why = frow.label & ": FIELD READ, offset from fieldOffsets in " &
            SainRvaScope & ". There is NO prologue to verify because there is " &
            "no function; the receiver is bounds-checked with VirtualQuery for " &
            "the exact width on every single read. RECEIVER MUST BE a " &
            frow.recv & " -- a field read off the wrong object does not fault, " &
            "it answers. " & frow.why &
            (if frow.needsPlayer:
               " Marked needsPlayer: these are EFT.Player's own offsets and " &
               "are meaningless on an ObservedPlayerView."
             else: "") &
            (if frow.unityObj:
               " Receiver is a UnityEngine.Object: m_CachedPtr is checked " &
               "non-null before the chain continues, because readability is " &
               "NOT liveness on this build."
             else: "")
    return

  var row = emptyRvaRow()
  if not findRvaRow(gRvaRows, l.rvaKey, row):
    # Neither a row nor a refusal. `tools/idxbind.py` makes this a build
    # failure, so reaching it live means the checker was bypassed.
    gRvaRejected = gRvaRejected + 1
    l.why = "RVA TABLE HAS NO ENTRY for key '" & l.rvaKey & "' (member " &
            l.member & ") -- neither a bound row nor a stated refusal. This " &
            "is a TABLE BUG, not a client fact. Nothing was bound and nothing " &
            "was called."
    return

  if not gLive or gRt.handle == nil:
    l.rvaTried = false          # retry once the runtime is up
    l.tried = false
    l.why = row.label & ": GameAssembly.dll is not bound yet, so there is no " &
            "imagebase to add an RVA to"
    return

  # Runtime address = module base + (VA - 0x180000000); the table's RVAs are
  # already VA-minus-imagebase.
  let fn = sainPtrAdd(gRt.handle, int64(row.rva))
  var got = ""
  if not rvaPrologueMatches(fn, row.prologue, got):
    gRvaRejected = gRvaRejected + 1
    gRvaFaults = gRvaFaults + 1
    l.gateRefused = true
    l.why = row.label & " @0x" & rvaHexs(row.rva) & ": PROLOGUE MISMATCH -- " &
            "expected " & row.prologue & ", found " & got & ". REFUSED; " &
            "nothing was called. Either this RVA is stale for the installed " &
            "GameAssembly.dll (the table was derived against " & SainRvaScope &
            "), or another feature has detoured it."
    if gRvaFaults >= RvaFaultCap:
      gRvaTable = false
      warn "sain: the RVA table has SELF-DISABLED after " & $gRvaFaults &
           " prologue mismatches. Every row was derived against " &
           SainRvaScope & "; if the installed GameAssembly.dll is a different " &
           "build, every RVA in the table is stale and must be re-derived " &
           "with tools/il2cpp_resolve.py. No further binding will be attempted."
    return

  var b = emptyBinding()
  b.target = row.label
  b.fn = fn
  # The hidden trailing `const MethodInfo*` is left NULL. Legal for everything
  # except a SHARED GENERIC, and none of the 23 is one: every row is a concrete
  # member of a concrete class, and the four generic ones (`List<T>`
  # count/item) are in the refusal list precisely because they are not.
  b.info = cast[Il2CppMethod](0)
  b.argc = row.argc
  b.ret = row.ret
  b.isStatic = false
  b.mask = 0'u32

  case row.shape
  of srPlain:
    b.slots = row.argc + 1'i32   # `this`, then each declared argument
    l.shape = csPlain
  of srStructReturn:
    # Slot 0 is the caller's return buffer, slot 1 is `this`. Only ever used
    # with `argc == 0`, which the table's three such rows all are.
    if row.argc != 0'i32:
      gRvaRejected = gRvaRejected + 1
      l.why = row.label & ": a struct return declared with arguments; this " &
              "mod plans one buffer per call and cannot express that. REFUSED."
      return
    b.slots = 2'i32
    b.ret = fkPtr
    l.shape = csStructReturn
  of srVectorArg:
    # Slot 0 is `this`, slot 1 is the address of the caller's Vector3.
    if row.argc != 1'i32:
      gRvaRejected = gRvaRejected + 1
      l.why = row.label & ": a by-pointer value argument at arity " &
              $row.argc & "; the table only expresses arity 1. REFUSED."
      return
    b.slots = 2'i32
    l.fills = @[sfValuePtr]
    l.shape = csVectorArg
  b.ok = true
  l.b = b
  l.argc = row.argc
  gRvaVerified = gRvaVerified + 1
  l.why = row.label & " @0x" & rvaHexs(row.rva) &
          ": prologue verified 16/16 against " & SainRvaScope & ", instance, " &
          $row.argc & " arg(s), " & $row.owners & " owner(s) of this RVA " &
          "(CALLING a folded address is correct; NEVER detour it). " &
          "Dispatch: " & row.virt &
          (if row.needsPlayer:
             ". RECEIVER MUST BE an EFT.Player -- this is EFT.Player's own " &
             "body and its field offsets are meaningless on a look-alike."
           else: "")

proc ensure*(l: var LazyCall; obj: Il2CppPtr): bool =
  ## True when the member is callable on this object, by one path or the other.
  ##
  ## The class comparison is the whole per-call overhead of binding lazily: one
  ## `il2cpp_object_get_class` and one pointer compare.
  if obj == nil or not gLive:
    return false
  # --- THE RVA PATH, taken before anything reflective is even considered.
  #
  # A member carrying an `rvaKey` never reaches `il2cpp_object_get_class` at
  # all: its address is a constant, so there is no class to ask for and no
  # token-gated export on the path. The receiver is still validated -- the
  # bound body is going to dereference it -- but nothing about its TYPE is
  # asked, because asking is the fatal call.
  #
  # `l.m` stays nil on this path on purpose, so every `reflect` fallback below
  # is a guarded no-op rather than an `il2cpp_runtime_invoke` on a null
  # MethodInfo. What makes the call happen is `l.b.ok`, which is the only thing
  # this returns true on.
  if l.rvaKey.len > 0:
    if not gRvaTable:
      return false
    # --- THE DRIVE-LEVEL GATE, before the receiver check and before any
    # resolution, so that a member above the level is not merely uncalled but
    # UNBOUND -- nothing is verified, nothing is counted as ready, and the
    # binding report cannot show it as available.
    #
    # `rvaTried` is deliberately NOT set on this path. A level refusal is a
    # configuration state, not a measurement, and it must become a binding the
    # moment the level is raised; setting `rvaTried` here would make the first
    # tick at level 1 decide the whole session.
    let need = sainRvaLevelFor(l.rvaKey)
    if need > gRvaDriveLevel:
      if not l.levelSaid:
        l.levelSaid = true
        gRvaLevelRefused = gRvaLevelRefused + 1
        l.why = l.rvaKey & ": ABOVE THE DRIVE LEVEL. This member needs " &
                rvaLevelName(need) & " and sainRvaTableDriveLevel is " &
                rvaLevelName(gRvaDriveLevel) & ". Nothing was bound, nothing " &
                "was verified and nothing was called -- this is a refusal by " &
                "configuration, not a measurement, and raising the level " &
                "makes it bind on the next tick without a restart."
        warn "sain:   LEVEL   " & l.why
      return false
    if not sainReadable(obj, 8):
      return false
    if not l.rvaTried:
      resolveFromRva(l)
    return l.b.ok or l.fldOk
  # AND THE SAME REFUSAL, at the root of the whole lazy table.
  #
  # This is the widest consequence of fact #35 and it is worth stating plainly:
  # every one of the ~70 members in `bindAll` is a `LazyCall`, and EVERY
  # `LazyCall` becomes callable only by coming through here -- one
  # `il2cpp_object_get_class` on the receiver, then a class-based method
  # lookup. `il2cpp_object_get_class` is on CLAUDE.md 5's list of reflection
  # entry points that FAULT on this build, and the lookup after it is the same
  # unmapped-handle path that killed the client at `get_Instance`.
  #
  # So the mod's whole read path is blocked by construction here, not merely
  # its two entry points. Refusing at this one choke point is what makes that
  # a degraded mod rather than a dead client: `ensure` answers "not callable",
  # every sensor and every driving call declines, and each one already has a
  # `why` string that says so.
  if reflectionRefused():
    return false
  # The gate above is the policy check; these two are the ones that can fire
  # when the gate has been opened deliberately. `il2cpp_object_get_class` is
  # `mov rax,[rcx]; ret` -- it reads the receiver's first word and validates
  # nothing -- so the receiver must be readable BEFORE the call, and the class
  # it answers with must be readable before `resolveOn` takes it to
  # `fullName`. A `!= nil` check between the two is not a check (fact #198).
  if not sainReadable(obj, 8):
    return false
  let c = objectClass(gRt, obj)
  if c == nil:
    return false
  if not sainReadable(cast[Il2CppPtr](c), 8):
    return false
  if (not l.tried) or l.cls != c:
    resolveOn(l, c)
  result = l.m != nil

# ---------------------------------------------------------------------------
# Calling
# ---------------------------------------------------------------------------

proc reflect(m: Il2CppMethod; obj: Il2CppPtr; argv: Il2CppPtr): Il2CppPtr =
  ## One `il2cpp_runtime_invoke`, with the exception out-parameter actually
  ## read. A managed throw does not unwind through a C caller: it comes back as
  ## a written pointer, and ignoring it means using a null return as data.
  result = cast[Il2CppPtr](0)
  # A NULL MethodInfo is now REACHABLE and must be a no-op, not a call.
  #
  # Every caller below is shaped `if l.b.ok: <fast>; else: reflect(l.m, ...)`,
  # and an RVA-bound member satisfies `l.b.ok` with `l.m` deliberately nil. Any
  # caller whose fast-path predicate is narrower than `b.ok` -- an argc that
  # does not match, a shape that does not -- would otherwise fall through to
  # `il2cpp_runtime_invoke(NULL, ...)`. Refusing here is one check that closes
  # all of them at once.
  if m == nil:
    return cast[Il2CppPtr](0)
  var exc: Il2CppException = cast[Il2CppException](0)
  let r = invoke(gRt, m, obj, argv, exc)
  if exc != nil:
    return cast[Il2CppPtr](0)
  result = r

proc fldFault(l: var LazyCall; what: string) =
  ## One field hop refused. Counted against a session budget, and past it the
  ## whole table turns itself off rather than answering wrongly every frame.
  gRvaFieldFaults = gRvaFieldFaults + 1
  if gRvaFieldFaults == FieldFaultCap:
    gRvaTable = false
    warn "sain: the FIELD path has SELF-DISABLED after " & $gRvaFieldFaults &
         " refused hops (last: " & l.rvaKey & " -- " & what & "). Every offset " &
         "was derived against " & SainRvaScope & ". A hop that will not " &
         "validate means the receiver was not the type the chain promised, " &
         "and a field read off the wrong object ANSWERS rather than faults, " &
         "so nothing further will be read."
  elif gRvaFieldFaults < FieldFaultCap:
    debug "sain: field hop refused for " & l.rvaKey & " -- " & what

proc fldRecvOk(l: var LazyCall; obj: Il2CppPtr; width: int): bool =
  ## The whole receiver gate for one field read, in the order that matters.
  ##
  ## `obj + off` is bounds-checked for the EXACT width being read rather than
  ## for a nominal 8: reading a bool at 0xD9 touches one byte, and asking for
  ## eight there could refuse a legitimate read at the tail of a page.
  result = false
  if obj == nil:
    return
  if not sainReadable(obj, 8):
    fldFault(l, "receiver is not readable")
    return
  if l.fldUnityObj and not sainUnityAlive(obj):
    # NOT a mere nil check. The managed shell of a destroyed MonoBehaviour
    # reads back perfectly; its native half is what is gone.
    fldFault(l, "receiver's native half (m_CachedPtr) is null -- destroyed")
    return
  if not sainReadable(sainPtrAdd(obj, int64(l.fldOff)), width):
    fldFault(l, "receiver+0x" & rvaHexs(l.fldOff) & " is not readable for " &
                $width & " byte(s)")
    return
  result = true

proc callObj*(l: var LazyCall; obj: Il2CppPtr): Il2CppPtr =
  ## A member returning a reference: the next step along the graph.
  result = cast[Il2CppPtr](0)
  if not ensure(l, obj):
    return
  # --- the field path. Read, validate what came back, and only then hand it on
  # -- the value is about to become the RECEIVER of the next hop, so returning
  # an unreadable pointer here would just move the fault one line down.
  if l.fldOk:
    if l.fldKind != fkPtr:
      return
    if not fldRecvOk(l, obj, 8):
      return
    let v = sainFldPtr(obj, int64(l.fldOff))
    if v == nil:
      return
    if not sainReadable(v, 8):
      fldFault(l, "the value read back is not a readable object")
      return
    return v
  if l.b.ok and l.b.ret == fkPtr and l.b.argc == 0'i32:
    var a = noArgs()
    return callPtr(l.b, obj, a)
  result = reflect(l.m, obj, cast[Il2CppPtr](0))

proc callBoolOn*(l: var LazyCall; obj: Il2CppPtr; default: bool): bool =
  result = default
  if not ensure(l, obj):
    return
  if l.fldOk:
    # A managed `bool` is ONE byte. Anything non-zero is true, which is what
    # IL2CPP itself emits; there is no need to insist on exactly 1 and doing so
    # would turn a legitimate `true` into the default.
    if l.fldKind != fkBool:
      return
    if not fldRecvOk(l, obj, 1):
      return
    return sainFldU8(obj, int64(l.fldOff)) != 0'i32
  if l.b.ok and l.b.argc == 0'i32:
    var a = noArgs()
    return callBool(l.b, obj, a)
  let r = reflect(l.m, obj, cast[Il2CppPtr](0))
  if r == nil:
    return default
  let p = objectUnbox(gRt, r)
  if p == nil:
    return default
  result = readBool(gB0, p)

proc callIntOn*(l: var LazyCall; obj: Il2CppPtr; default: int): int =
  result = default
  if not ensure(l, obj):
    return
  if l.b.ok and l.b.argc == 0'i32:
    var a = noArgs()
    return int(callInt32(l.b, obj, a))
  let r = reflect(l.m, obj, cast[Il2CppPtr](0))
  if r == nil:
    return default
  result = unboxInt(r)

proc callFloatOn*(l: var LazyCall; obj: Il2CppPtr; default: float): float =
  result = default
  if not ensure(l, obj):
    return
  if l.b.ok and l.b.argc == 0'i32:
    var a = noArgs()
    return callFloat(l.b, obj, a)
  let r = reflect(l.m, obj, cast[Il2CppPtr](0))
  if r == nil:
    return default
  result = unboxFloat(r)

proc callVoidOn*(l: var LazyCall; obj: Il2CppPtr): bool =
  ## Returns whether the call was made, which is what the driver counts.
  if not ensure(l, obj):
    return false
  # A field row is a READ. There is no function behind it, so there is nothing
  # to invoke -- and reporting `true` here would tell the driver a drive call
  # happened when nothing did. This is the structural reason no drive call can
  # be wired through the field table even by accident.
  if l.fldOk:
    return false
  if l.b.ok and l.b.argc == 0'i32:
    var a = noArgs()
    callVoid(l.b, obj, a)
    return true
  discard reflect(l.m, obj, cast[Il2CppPtr](0))
  result = true

proc callBoolArg*(l: var LazyCall; obj: Il2CppPtr; v: bool): bool =
  ## A one-`bool` setter -- `Mover.Sprint(true)`. This is the shape the fast
  ## path is best at: one general-purpose register, no allocation anywhere,
  ## measured at 6-10 ns.
  if not ensure(l, obj):
    return false
  if l.fldOk:                       # see callVoidOn: a field row is a read
    return false
  if l.b.ok and l.b.argc == 1'i32:
    var a = noArgs()
    addBool(a, v)
    callVoid(l.b, obj, a)
    return true
  var slot = 0'i32
  if v: slot = 1'i32
  var argv: array[1, Il2CppPtr] = [cast[Il2CppPtr](addr slot)]
  discard reflect(l.m, obj, cast[Il2CppPtr](addr argv[0]))
  result = true

proc callIntArg*(l: var LazyCall; obj: Il2CppPtr; v: int32): Il2CppPtr =
  ## One integer (or enum) argument, returning whatever came back boxed.
  ## `HealthController.GetBodyPartHealth(EBodyPart)` is this shape, and because
  ## its return is a value struct it never reaches the fast path.
  result = cast[Il2CppPtr](0)
  if not ensure(l, obj):
    return
  var slot = v
  var argv: array[1, Il2CppPtr] = [cast[Il2CppPtr](addr slot)]
  result = reflect(l.m, obj, cast[Il2CppPtr](addr argv[0]))

proc readVec*(l: var LazyCall; obj: Il2CppPtr): Vec3 =
  ## A `Vector3` property.
  ##
  ## **On the fast path**, through `fast.bindRaw`. This used to be
  ## `il2cpp_runtime_invoke` -- the one thing `docs/PERF.md` said the fast path
  ## refused -- and it was ~80% of what reading a bot cost, plus a managed
  ## allocation per read for the box.
  ##
  ## The shape is asserted at bind time and the assertion is stated here as
  ## well, because it is the kind of thing a reader has to be able to check
  ## without leaving the call site: Win64 returns an aggregate wider than eight
  ## bytes through a hidden pointer the *caller* supplies, so the compiled
  ## function is `void* get_Position(void* sret, void* this, MethodInfo*)` --
  ## two pointer slots, in that order. `buf` is that space. The callee writes
  ## three floats into it and hands the same address back, which is why the
  ## return value is discarded: it is `buf`.
  ##
  ## `buf` is four floats rather than three so that a value type of up to 16
  ## bytes -- which `tryShaped` permits and a `Quaternion` would be -- cannot
  ## write past it. `tryShaped` refuses anything wider.
  result = zeroVec()
  if not ensure(l, obj):
    return
  if l.shape == csStructReturn and l.b.ok:
    var buf: array[4, float32] = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]
    var a = shaped()
    a.addSlotPtr(cast[Il2CppPtr](addr buf[0]))
    a.addSlotPtr(obj)
    discard callShapedPtr(l.b, a)
    return vec3(float(buf[0]), float(buf[1]), float(buf[2]))
  # The fallback, unchanged: a boxed return read through `il2cpp_object_unbox`.
  # Reached when `tryShaped` refused -- a build where the payload size does not
  # come out sane, or a member that turned out to be static.
  let r = reflect(l.m, obj, cast[Il2CppPtr](0))
  result = unboxVec3(r)

proc callVec*(l: var LazyCall; obj: Il2CppPtr; p: Vec3; flag: bool): bool =
  ## A method whose first argument is a `Vector3` -- `Mover.GoToPoint`,
  ## `Steering.LookToPoint`.
  ##
  ## **Also on the fast path now**, by the other half of the same convention: a
  ## 12-byte argument is passed by hidden pointer, so `void GoToPoint(Vector3)`
  ## compiles to `void GoToPoint(void* this, void* p, MethodInfo*)` -- `this` in
  ## slot 0 and the address of the value in slot 1. `xyz` is a local and stays
  ## alive across the call, which is the whole requirement for handing its
  ## address over.
  ##
  ## Arguments past the first are filled from a plan `tryShaped` worked out from
  ## the runtime's own declared parameter types: `-1` for a float (EFT's own
  ## "no preference" for a reach distance), the caller's flag for the first
  ## bool, zero for an integer, an enum or a reference. Guessing a *meaningful*
  ## default would be worse than this -- these are the values that make a long
  ## overload behave like its shortest form, and `bindAll` asks for the shortest
  ## overload first anyway.
  if not ensure(l, obj):
    return false
  var xyz: array[4, float32] = [float32(p.x), float32(p.y), float32(p.z),
                                0.0'f32]

  if l.shape == csVectorArg and l.b.ok:
    var a = shaped()
    a.addSlotPtr(obj)
    var flagUsed = false
    var k = 0
    while k < l.fills.len:
      case l.fills[k]
      of sfValuePtr:
        a.addSlotPtr(cast[Il2CppPtr](addr xyz[0]))
      of sfNegFloat:
        a.addSlotFloat(-1.0)
      of sfFlagBool:
        if flagUsed:
          a.addSlotInt(0'i64)
        else:
          flagUsed = true
          a.addSlotInt(if flag: 1'i64 else: 0'i64)
      of sfZero:
        a.addSlotInt(0'i64)
      inc k
    callShapedVoid(l.b, a)
    return true

  # The fallback: `il2cpp_runtime_invoke` with the argument array built by
  # hand. The marshalling is the convention IL2CPP shares with Mono -- a
  # `void**` in which a value-type slot points at the raw value and a reference
  # slot *is* the pointer -- which is, not by accident, the same rule the
  # shaped call above is exploiting one layer down.
  var scratch: array[8, int64] = [0'i64, 0'i64, 0'i64, 0'i64,
                                  0'i64, 0'i64, 0'i64, 0'i64]
  var argv: array[8, Il2CppPtr] = [cast[Il2CppPtr](0), cast[Il2CppPtr](0),
                                   cast[Il2CppPtr](0), cast[Il2CppPtr](0),
                                   cast[Il2CppPtr](0), cast[Il2CppPtr](0),
                                   cast[Il2CppPtr](0), cast[Il2CppPtr](0)]
  let n = int(l.argc)
  if n < 1 or n > 8:
    return false
  # `methodParam(gRt, l.m, i)` below is a reflective read off the MethodInfo,
  # and an RVA-bound member has none. Reached only if the shaped branch above
  # declined, which for a table row cannot happen -- but "cannot happen" is not
  # a check, and this is.
  if l.m == nil:
    return false
  argv[0] = cast[Il2CppPtr](addr xyz[0])
  var i = 1
  while i < n:
    let tn = typeName(gRt, methodParam(gRt, l.m, i))
    # THE STACK-ADDRESS-AS-A-REFERENCE DEFECT, and the refusal that replaces it
    # (docs/WRITE-AUDIT-2026-09-02.md section 4, candidate #1).
    #
    # IL2CPP's `runtime_invoke` marshalling -- restated four lines above and
    # again in `abi/aowlspt_shim.h` -- is that a VALUE-TYPE slot POINTS AT the
    # value while a REFERENCE slot *IS* the pointer. The `else:` branch used to
    # zero `scratch[i]` and hand the callee `&scratch[i]` regardless, so for
    # every parameter that was not Single or Boolean -- and this function's own
    # doc comment says that branch covers "an integer, an enum OR A REFERENCE"
    # -- the callee received A HOST STACK ADDRESS as a managed object. A callee
    # that stores it into a field makes the next liveness walk
    # (`il2cpp_unity_liveness_calculation_from_root`, `test byte ptr [rcx],1`)
    # follow host stack memory, arbitrarily far from here.
    #
    # There is no safe way to synthesise a managed object for an unknown
    # reference parameter from native code, so this REFUSES rather than
    # guessing. The value-type list is explicit; anything not on it is not
    # marshalled. A drive call that declines is a bot that keeps its previous
    # order. A corrupt reference is a client kill minutes later.
    if tn == "System.Single":
      writeFloat(gF0, cast[Il2CppPtr](addr scratch[i]), -1.0)
      argv[i] = cast[Il2CppPtr](addr scratch[i])
    elif tn == "System.Boolean":
      if i == 1 and flag:
        scratch[i] = 1'i64
      argv[i] = cast[Il2CppPtr](addr scratch[i])
    elif tn == "System.Int32" or tn == "System.UInt32" or
         tn == "System.Int64" or tn == "System.UInt64" or
         tn == "System.Int16" or tn == "System.UInt16" or
         tn == "System.SByte" or tn == "System.Byte" or
         tn == "System.Char" or tn == "System.Double" or
         tn == "System.IntPtr" or tn == "System.UIntPtr":
      scratch[i] = 0'i64
      argv[i] = cast[Il2CppPtr](addr scratch[i])
    else:
      warn "sain: runtime_invoke REFUSED -- parameter " & $i & " of this " &
           "drive call is declared '" & tn & "', which is not a value type " &
           "this marshaller can build. Passing &scratch[i] for it would hand " &
           "the callee A HOST STACK ADDRESS as a managed reference " &
           "(WRITE-AUDIT candidate #1); the call was not made."
      return false
    inc i
  discard reflect(l.m, obj, cast[Il2CppPtr](addr argv[0]))
  result = true

# ---------------------------------------------------------------------------
# Reading a field out of a boxed value struct
# ---------------------------------------------------------------------------

type
  LazyField* = object
    ## A field on whatever class the object turns out to be, cached the same
    ## way `LazyCall` caches a method.
    ##
    ## This is for the value structs EFT returns from health queries, where the
    ## *struct* has a name that moves between versions but the fields inside it
    ## (`Current`, `Maximum`) do not. `il2cpp_field_get_value` is used rather
    ## than an offset load because it is the runtime's own answer to where a
    ## field lives inside a boxed value -- the header offset question that
    ## `bindField` refuses to guess at.
    name*: string
    cls*: Il2CppClass
    f*: Il2CppField
    tried*: bool

proc lazyField*(name: string): LazyField =
  LazyField(name: name, cls: cast[Il2CppClass](0), f: cast[Il2CppField](0),
            tried: false)

proc readStructFloat*(l: var LazyField; boxed: Il2CppPtr;
                      default: float): float =
  result = default
  if boxed == nil or not gLive:
    return
  # GATED + GUARDED. This was the one `objectClass` site in the file that
  # `ensure`'s `reflectionRefused()` choke point did NOT cover, so the mod's
  # "blocked by construction" claim had an exception nobody had noticed.
  # `findField` and `fieldGetValue` below both dereference the class handle.
  if reflectionRefused("a boxed value type's field"):
    return
  if not sainReadable(boxed, 8):
    return
  let c = objectClass(gRt, boxed)
  if c == nil:
    return
  if not sainReadable(cast[Il2CppPtr](c), 8):
    # `il2cpp_object_get_class` is `mov rax,[rcx]; ret` and validates nothing,
    # so a non-nil answer is not evidence of a class. This is.
    return
  if (not l.tried) or l.cls != c:
    l.cls = c
    l.tried = true
    l.f = findField(gRt, c, l.name)
  if l.f == nil:
    return
  var v: float32 = 0.0
  fieldGetValue(gRt, boxed, l.f, cast[Il2CppPtr](addr v))
  result = float(v)

proc readManagedString*(p: Il2CppPtr): string =
  ## A `System.String` the game handed back.
  if p == nil:
    return ""
  result = readString(gRt, p)

# ---------------------------------------------------------------------------
# The binding set
# ---------------------------------------------------------------------------
#
# Every member SAIN reads or drives, in one place, so that the one thing which
# needs checking against a real client -- the names -- can be checked by reading
# a single table rather than the whole mod.
#
# The `EFT.` names are the pre-1.0 C# surface. Post-1.0 is an IL2CPP build of a
# later game and some of them will be wrong. A wrong one is a refused binding
# and a `why` line, and the value it would have produced falls back to the
# default in `SelfView` -- so a bot with an unreadable magazine count decides as
# though its magazine were full rather than deciding from a zero it invented.

type
  SainBindings* = object
    ready*: bool
    reported*: bool

    # World -> players. Bound by *name*, because there is no instance to bind
    # from until after the first of these calls has returned one.
    worldInstance*: Binding
    worldAlive*: Binding
    worldMethod*: Il2CppMethod   ## the reflective form, when the fast one refuses
    aliveMethod*: Il2CppMethod
    worldWhy*: string
    aliveWhy*: string

    # The alive-players list. Generic-instantiated, so it can only be bound
    # from an instance -- which is the case `LazyCall` exists for.
    listCount*: LazyCall
    listItem*: LazyCall

    # Player
    pIsAI*: LazyCall
    pProfileId*: LazyCall
    pAIData*: LazyCall
    pHealth*: LazyCall
    pMovement*: LazyCall
    pPhysical*: LazyCall
    pPosition*: LazyCall         ## Vector3 -> shaped fast call
    pLookDir*: LazyCall          ## Vector3 -> shaped fast call

    # AIData -> BotOwner
    aiBotOwner*: LazyCall

    # MovementContext
    mcSprint*: LazyCall

    # Physical -> Stamina
    phStamina*: LazyCall
    stNormal*: LazyCall

    # HealthController
    hcAlive*: LazyCall
    hcBodyPart*: LazyCall        ## enum arg, value-struct return -> reflective
    vsCurrent*: LazyField
    vsMaximum*: LazyField

    # The bot's group, as an *identity only*.
    #
    # This is the cheapest useful binding in the file and it is worth saying
    # why it is shaped the way it is. SAIN's squad layer enumerates
    # `BotsGroup` -- members, leader, who is in combat -- which is a handful of
    # member names on a class whose post-1.0 shape nobody here has seen, and
    # guessing five names to reach data this mod already has about every bot in
    # the raid is the wrong trade.
    #
    # So the getter is bound and the *pointer* is used, never dereferenced. Two
    # bots whose group pointer is equal are in the same BSG group, which is the
    # entire question `core/squad.nim` needs answered. One name, no layout
    # assumption, and a refusal costs only the fallback (same faction, within
    # `squadCohesionRadius`) rather than the whole squad layer.
    boBotsGroup*: LazyCall

    # Grenades in flight, read off the world rather than off any bot.
    #
    # `cdAvoidGrenade` is the highest-urgency decision in the ladder and it was
    # unreachable, because nothing ever set `GrenadeThreat.active`. This is the
    # sensor. It is three guessed names rather than one and it is listed in
    # `README.md` as such; what makes it worth the guess is that the whole cost
    # is one bound `get_Count` per tick for the overwhelmingly common case of
    # an empty list, and there is no way to derive a grenade's existence from
    # anything else this mod can read.
    #
    # The list getters are separate `LazyCall`s from `listCount` / `listItem`
    # on purpose: a `List<Throwable>` is a different class from a
    # `List<IPlayer>`, and sharing one binding between two classes makes it
    # rebind on every alternation -- the one way to make lazy binding cost
    # something.
    wGrenades*: LazyCall
    glCount*: LazyCall
    glItem*: LazyCall
    grPosition*: LazyCall

    # BotOwner components
    boMemory*: LazyCall
    boWeapon*: LazyCall
    boMover*: LazyCall
    boSteering*: LazyCall
    boShoot*: LazyCall
    boMedecine*: LazyCall
    ## `BotOwner.AimingData`, as an **identity**, exactly the way
    ## `boBotsGroup` is used: the pointer is compared, never dereferenced.
    ##
    ## The typed postfix in `sain.nim` fires on the aim component and is handed
    ## that component's address as `this`. Attributing the reading to a bot
    ## therefore means knowing which component belongs to which bot, and this
    ## is the one call that answers it. It is not on the per-decision path: the
    ## driver caches the answer per bot and re-derives it only when the reading
    ## it is keyed on has gone stale, which in a working raid is never.
    boAiming*: LazyCall
    amCurrent*: LazyCall
    ## Hop 2 of the aim route: `AimingManager::get_CurrentAiming`.
    ##
    ## Its value is USED AS AN ADDRESS AND NOTHING ELSE. The declared return is
    ## the interface `IBotAiming`, so what comes back may be any implementor --
    ## and the one implementor that is not an `Aiming` subclass
    ## (UnderbarrelLauncherBotAiming) is exactly the case where the postfix in
    ## `sain.nim` never fires, so no reading is ever stored under that address
    ## and the gate withholds nothing. Nothing is ever called ON this pointer;
    ## if that changes, the interface return becomes a hazard again.

    # The bot's memory
    memUnderFire*: LazyCall
    memGoalEnemy*: LazyCall

    # The enemy record the game keeps
    enPerson*: LazyCall
    enVisible*: LazyCall
    enCanShoot*: LazyCall
    enPosition*: LazyCall        ## Vector3 -> shaped fast call

    # Weapon
    wmHaveBullets*: LazyCall
    wmReady*: LazyCall
    wmReload*: LazyCall
    rlTryReload*: LazyCall
    rlBullets*: LazyCall
    rlMaxBullets*: LazyCall

    # Medicine. Three separate `LazyCall`s for what is the same member name on
    # three different component classes: one shared binding would rebind on
    # every call as the class under it alternated, which is the one way to
    # make lazy binding cost something.
    medFirstAid*: LazyCall
    medStims*: LazyCall
    medSurgery*: LazyCall
    faHave*: LazyCall
    stimHave*: LazyCall
    surgHave*: LazyCall
    faShall*: LazyCall           ## BotFirstAid::ShallStartUse -- a READ
    surgShall*: LazyCall         ## BotSurgicalKit::ShallStartUse -- a READ
    faApply*: LazyCall
    stimApply*: LazyCall
    surgApply*: LazyCall

    # Driving
    mvGoTo*: LazyCall            ## Vector3 argument -> shaped fast call
    mvSprint*: LazyCall          ## one bool -> fast
    mvStop*: LazyCall
    stLookTo*: LazyCall          ## Vector3 argument -> shaped fast call
    sdShoot*: LazyCall

var gB*: SainBindings

proc bindAll*() =
  ## Fill the table. Called once, from the first tick on which the runtime is
  ## up -- never from `onLoad`, where the game's assemblies do not exist and
  ## every binding would correctly refuse.
  ##
  ## Phase-by-phase in the log, and only ever once (`gB.ready` guards the whole
  ## proc). Two of these phases call the runtime's own name lookups and two of
  ## them only fill a record; a crash that stops mid-table has to say which,
  ## because `bindAll` is 70-odd bindings and "somewhere in bindAll" is not an
  ## answer.
  if gB.ready:
    return
  info "sain: bindAll phase 1/5 -- float readers"
  initFloatReaders()

  # The two static entry points. `EFT.GameWorld::get_Instance` is the shape
  # every EFT manager uses. On a build where the singleton lives on
  # `Comfort.Common.Singleton<GameWorld>` instead, this refuses and says so:
  # that type is a generic instantiation and `findClass` cannot name it, which
  # is a real gap rather than something to paper over. The reflective fallback
  # below covers the case where the method exists but its signature does not
  # classify.
  # PHASE 2 IS NOW A REFUSAL, and it is the fix for the crash this file's own
  # header block describes. `EFT.GameWorld::get_Instance` does not exist on
  # this build -- measured, 409 members, no match for "instance" -- so it is
  # not resolved, not bound and not called. The world comes from `gwState` /
  # the host export instead.
  #
  # The `findClass` + `findMethod` fallback that used to sit here was the
  # worst part: it ran precisely WHEN the bind had failed, and handed back a
  # non-nil pointer into unmapped memory for a method that does not exist.
  info "sain: bindAll phase 2/5 -- EFT.GameWorld::get_Instance is NOT bound: " &
       "it does not exist on this build (measured offline, 409 members of " &
       "EFT.GameWorld, no match for \"instance\"). The live world is " &
       "borrowed from the host export instead"
  gB.worldInstance = emptyBinding()
  gB.worldMethod = cast[Il2CppMethod](0)
  gB.worldWhy = "EFT.GameWorld::get_Instance does not exist on this build; " &
                "the world is borrowed from the host -- " & gwStateText()

  # PHASE 3 IS THE SAME LANDMINE, one step further along, and it had never
  # executed because the process died at phase 2's call. MEASURED in the same
  # 409-member dump: `EFT.GameWorld` has NO `get_AllAlivePlayersList` either.
  # There is no getter at all.
  #
  # What there IS, from `il2cpp_resolve.py fields EFT.GameWorld`, is the plain
  # instance field:
  #
  #     0x1c8   inst   AllAlivePlayersList   List<Player>   EFT.GameWorld
  #
  # That is a real, measured, static offset on a NON-generic type, which is
  # exactly the toolkit CLAUDE.md 5 says still works. It is recorded here and
  # read in `alivePlayers` below, off a world pointer the host validated --
  # never off an offset that could read null.
  info "sain: bindAll phase 3/5 -- EFT.GameWorld::get_AllAlivePlayersList is " &
       "NOT bound: no such getter exists on this build. The list is read as " &
       "the measured instance field AllAlivePlayersList @0x1c8 instead"
  gB.worldAlive = emptyBinding()
  gB.aliveMethod = cast[Il2CppMethod](0)
  gB.aliveWhy = "no get_AllAlivePlayersList on this build; reading the " &
                "measured field AllAlivePlayersList @0x1c8 off the borrowed " &
                "world"

  info "sain: bindAll phase 4/5 -- the lazy member table (~70 names)"
  # Every member below now carries its `client/rvatable.nim` key. A key that
  # names a ROW binds from a byte-verified static RVA; a key that names a
  # REFUSAL declines by name in the log and is never retried reflectively.
  # `tools/idxbind.py sain-rva` fails the build on a key that is neither.
  gB.listCount = keyed(lazy("get_Count"), "listCount")
  gB.listItem = keyed(lazyAs("get_Item", [fkI32], fkPtr), "listItem")

  gB.pIsAI = keyed(lazy("get_IsAI"), "pIsAI")
  gB.pProfileId = keyed(lazy("get_ProfileId"), "pProfileId")
  gB.pAIData = keyed(lazy("get_AIData"), "pAIData")
  gB.pHealth = keyed(lazy("get_HealthController"), "pHealth")
  gB.pMovement = keyed(lazy("get_MovementContext"), "pMovement")
  gB.pPhysical = keyed(lazy("get_Physical"), "pPhysical")
  gB.pPosition = keyed(lazy("get_Position"), "pPosition")
  gB.pLookDir = keyed(lazy("get_LookDirection"), "pLookDir")

  gB.aiBotOwner = keyed(lazy("get_BotOwner"), "aiBotOwner")
  gB.mcSprint = keyed(lazy("get_IsSprintEnabled"), "mcSprint")

  gB.phStamina = keyed(lazy("get_Stamina"), "phStamina")
  gB.stNormal = keyed(lazy("get_NormalValue"), "stNormal")

  gB.hcAlive = keyed(lazy("get_IsAlive"), "hcAlive")
  gB.hcBodyPart = keyed(lazyAs("GetBodyPartHealth", [fkI32], fkNone),
                        "hcBodyPart")
  gB.vsCurrent = lazyField("Current")
  gB.vsMaximum = lazyField("Maximum")

  gB.boBotsGroup = keyed(lazy("get_BotsGroup"), "boBotsGroup")

  gB.wGrenades = keyed(lazy("get_Grenades"), "wGrenades")
  gB.glCount = keyed(lazy("get_Count"), "glCount")
  gB.glItem = keyed(lazyAs("get_Item", [fkI32], fkPtr), "glItem")
  gB.grPosition = keyed(lazy("get_Position"), "grPosition")

  gB.boMemory = keyed(lazy("get_Memory"), "boMemory")
  gB.boWeapon = keyed(lazy("get_WeaponManager"), "boWeapon")
  gB.boMover = keyed(lazy("get_Mover"), "boMover")
  gB.boSteering = keyed(lazy("get_Steering"), "boSteering")
  gB.boShoot = keyed(lazy("get_ShootData"), "boShoot")
  gB.boMedecine = keyed(lazy("get_Medecine"), "boMedecine")
  # The aim route, hop 1 and hop 2. `lazy`'s member string is now dead weight
  # on a keyed member -- the address comes from the row, never from a name --
  # but it is kept truthful rather than emptied, because it is what the
  # `unused` branch of `reportOne` prints and a lie there is worse than noise.
  gB.boAiming = keyed(lazy("get_AimingManager"), "boAiming")
  gB.amCurrent = keyed(lazy("get_CurrentAiming"), "amCurrent")

  gB.memUnderFire = keyed(lazy("get_IsUnderFire"), "memUnderFire")
  gB.memGoalEnemy = keyed(lazy("get_GoalEnemy"), "memGoalEnemy")

  gB.enPerson = keyed(lazy("get_Person"), "enPerson")
  gB.enVisible = keyed(lazy("get_IsVisible"), "enVisible")
  gB.enCanShoot = keyed(lazy("get_CanShoot"), "enCanShoot")
  gB.enPosition = keyed(lazy("get_CurrPosition"), "enPosition")

  gB.wmHaveBullets = keyed(lazy("get_HaveBullets"), "wmHaveBullets")
  gB.wmReady = keyed(lazy("get_IsReady"), "wmReady")
  gB.wmReload = keyed(lazy("get_Reload"), "wmReload")
  gB.rlTryReload = keyed(withGate(lazy("TryReload"), dsNoArgs), "rlTryReload")
  gB.rlBullets = keyed(lazy("get_BulletCount"), "rlBullets")
  gB.rlMaxBullets = keyed(lazy("get_MaxBulletCount"), "rlMaxBullets")

  gB.medFirstAid = keyed(lazy("get_FirstAid"), "medFirstAid")
  gB.medStims = keyed(lazy("get_Stimulators"), "medStims")
  gB.medSurgery = keyed(lazy("get_SurgicalKit"), "medSurgery")
  gB.faHave = keyed(lazy("get_HaveSmth2Use"), "faHave")
  gB.stimHave = keyed(lazy("get_HaveSmth2Use"), "stimHave")
  gB.surgHave = keyed(lazy("get_HaveWork"), "surgHave")
  gB.faShall = keyed(lazy("ShallStartUse"), "faShall")
  gB.surgShall = keyed(lazy("ShallStartUse"), "surgShall")
  # The three self-actions are gated too, and for a smaller reason than the
  # movers: `TryApply` on a stimulator component takes no arguments here, and
  # a build where it takes an item or a body part would resolve at arity zero
  # only if such an overload also existed -- but `callVoidOn` hands over a null
  # argument array either way, so the gate is what makes "found at arity zero"
  # mean "declares no parameters".
  gB.faApply = keyed(withGate(lazy("TryApplyToCurrentPart"), dsNoArgs),
                     "faApply")
  gB.stimApply = keyed(withGate(lazy("TryApply"), dsNoArgs), "stimApply")
  gB.surgApply = keyed(withGate(lazy("TryApplyToCurrentPart"), dsNoArgs),
                       "surgApply")

  # `GoToPoint` is overloaded by arity across client versions -- one argument in
  # the shortest form, five or six in the fullest. Trying arities in order of
  # preference is cheaper and more durable than pinning one, and it happens
  # once per class rather than per call.
  #
  # **And every one of them is gated.** Walking arities is what makes this
  # binding durable across client versions and it is also what makes it the
  # one place in the table where the runtime can hand back a method that is
  # not the method meant. `core/sig.checkDrive` reads the declared parameter
  # types back and refuses when the first is not a `Vector3` -- so a build
  # whose one-argument `GoToPoint` takes something else gets no movement and
  # says so, rather than a bot walking to an address reinterpreted as a float.
  info "sain: bindAll phase 5/5 -- the gated driving calls, whose gates read " &
       "declared parameter types back out of the runtime"
  gB.mvGoTo = keyed(withGate(lazy("GoToPoint", 1'i32), dsVectorFirst), "mvGoTo")
  gB.mvGoTo.argcAlts = @[2'i32, 3'i32, 4'i32, 5'i32, 6'i32]
  # `Sprint` was `lazyAs([fkBool])`, which *stated* the signature rather than
  # asking for it: `resolveOn` skips the runtime's declared types entirely when
  # the caller supplied kinds, so a build where `Sprint` takes a float would
  # have had a bool put in a general-purpose register and the speed read out of
  # XMM. The stated kinds are kept -- they are still what the fast path binds
  # with -- and the gate is what now checks they are true.
  gB.mvSprint = keyed(withGate(lazyAs("Sprint", [fkBool], fkVoid), dsOneBool),
                      "mvSprint")
  gB.mvStop = keyed(withGate(lazy("Stop"), dsNoArgs), "mvStop")
  gB.stLookTo = keyed(withGate(lazy("LookToPoint", 1'i32), dsVectorFirst),
                      "stLookTo")
  gB.stLookTo.argcAlts = @[2'i32]
  gB.sdShoot = keyed(withGate(lazy("Shoot"), dsNoArgs), "sdShoot")

  info "sain: bindAll complete -- all five phases returned"
  gB.ready = true

proc reportOne(name: string; l: LazyCall) =
  ## The shape is named separately from "fast", and deliberately so. A shaped
  ## binding is the one kind here that rests on an asserted calling convention
  ## rather than on the runtime's own answer, so anyone reading a log after a
  ## client update needs to be able to see at a glance which calls those are.
  if l.fldOk:
    # Named separately from `fast` for the same reason `shaped` is: a field row
    # rests on an offset and a receiver argument rather than on a verified
    # prologue, and a reader after a client update has to be able to see which
    # bindings those are without leaving the log.
    info "sain:   field   " & name & " -- " & l.why
  elif l.b.ok and l.shape == csStructReturn:
    info "sain:   shaped  " & name & " -- " & l.why
  elif l.b.ok and l.shape == csVectorArg:
    info "sain:   shaped  " & name & " -- " & l.why
  elif l.b.ok:
    info "sain:   fast    " & name & " -- " & l.b.why
  elif l.m != nil:
    info "sain:   boxed   " & name & " -- " & l.why
  elif l.gateRefused:
    # Not `MISSING`. This build *has* the name; what it does not have is the
    # signature this mod calls it with, and the two want different reactions
    # from whoever reads the log.
    warn "sain:   REFUSED " & name & " -- " & l.why
  elif l.tried:
    warn "sain:   MISSING " & name & " -- " & l.why
  else:
    debug "sain:   unused  " & name & " (" & l.member & ")"

var gRvaReported = false

proc rvaReport*() =
  ## The RVA table's own account of itself, EAGERLY and once -- before any
  ## member has been used.
  ##
  ## `report()` cannot do this job. It walks `LazyCall`s, and a `LazyCall`
  ## resolves on FIRST USE, so a refusal for a member no bot ever reached
  ## prints as `unused` rather than as a refusal. That is a check that cannot
  ## fail (CLAUDE.md 9b): the loudest refusals in this table are exactly the
  ## ones on paths that never run, `mvSprint` above all -- the row whose whole
  ## value is that a by-name lookup WOULD have wrongly taken
  ## `EFT.Player::Sprint(EPlayerState)` and started a coroutine.
  ##
  ## So this walks the TABLE, not the bindings, and prints every refusal
  ## whether or not anything asked for it.
  ##
  ## The self-report is deliberately NOT "0 by-name bindings remain". It is
  ## "0 remain AMONG THE ROWS THE TABLE COVERS", plus the count that does not
  ## -- which is falsifiable and cannot be misread as "SAIN works".
  if gRvaReported:
    return
  gRvaReported = true
  rvaLoad()
  if not gRvaTable:
    warn "sain: the RVA table is OFF (sainRvaTable false). Every member is " &
         "refused at `ensure` and the mod reads nothing. " & $gRvaRows.len &
         " call row(s), " & $gRvaFieldRows.len & " field row(s) and " &
         $gRvaRefusals.len & " stated refusal(s) are loaded but unused."
    return
  info "sain: RVA table -- " & $gRvaRows.len & " row(s) bindable by static " &
       "RVA, " & $gRvaFieldRows.len & " row(s) bindable by FIELD READ, " &
       $gRvaRefusals.len & " member(s) REFUSED. Derived against " &
       SainRvaScope & "."
  # THE LEVEL, said before the rows, because it decides how much of what
  # follows can bind at all. At level 0 every line below describes something
  # that is loaded and will not be used, and a reader must not have to infer
  # that from a later absence of calls.
  info "sain: RVA drive level -- sainRvaTableDriveLevel = " &
       rvaLevelName(gRvaDriveLevel) &
       (if gRvaDriveLevel == RvaLevelObserver:
          ". NOTHING WILL BIND. Every keyed member refuses at `ensure` with a " &
          "LEVEL line naming what it would have needed. Raise it one notch " &
          "per raid: 1 reads, 2 adds the aim route, 3 adds the two calls that " &
          "make a bot act (stLookTo, rlTryReload)."
        elif gRvaDriveLevel == RvaLevelReads:
          ". Reads only: every bound member is an arity-0 getter or a field " &
          "read, so nothing at this level can change the game's state. The " &
          "aim route and the two drive calls are refused by level."
        elif gRvaDriveLevel == RvaLevelAim:
          ". Reads plus the aim route. The postfix on Aiming::get_IsReady " &
          "WATCHES -- it returns frameContinue and never rewrites the " &
          "readiness -- and the gate it feeds can only WITHHOLD a shot the " &
          "decision ladder already ordered. The two drive calls are still " &
          "refused by level."
        else:
          ". DRIVE. Two calls can now make a bot act: BotSteering::" &
          "LookToPoint and BotReload::TryReload. Every OTHER drive member " &
          "SAIN asks for -- GoToPoint, Sprint, Stop, Shoot and all three " &
          "medical applies -- is a stated refusal below, so this level is two " &
          "calls, not a combat brain.")
  # The audit for the level table itself, run before anything binds, and
  # written as a NEGATIVE: it looks for a row that mutates and is reachable
  # below level 3, so it can actually fail. A positive assertion that
  # `stLookTo` is level 3 would pass forever however many drive rows were
  # added after it.
  let driveBugs = sainRvaDriveAudit(gRvaRows)
  if driveBugs.len == 0:
    info "sain: RVA drive-level audit PASS -- no row with the shape of a " &
         "drive call (arguments, or a void return) is reachable below level " &
         "3, across all " & $gRvaRows.len & " row(s). NOTE the one case this " &
         "audit CANNOT see: BotReload::TryReload is `bool TryReload()`, the " &
         "exact shape of a getter, and it drives. It is classified level 3 by " &
         "hand, which is why a human still has to read a new row."
  else:
    var d = 0
    while d < driveBugs.len:
      warn "sain: RVA drive-level audit FAIL -- " & driveBugs[d]
      inc d
  var f = 0
  while f < gRvaFieldRows.len:
    let fr = gRvaFieldRows[f]
    info "sain:   field   " & fr.key & " (" & fr.label & ") -- receiver must " &
         "be a " & fr.recv & ". " & fr.why
    inc f
  var i = 0
  while i < gRvaRefusals.len:
    let r = gRvaRefusals[i]
    warn "sain:   REFUSED " & r.key & " (" & r.symbol & ") -- " &
         whyText(r.why) & ": " & r.detail
    inc i
  info "sain: RVA table scope statement -- of the " &
       $(gRvaRows.len + gRvaFieldRows.len) &
       " members THIS TABLE COVERS, zero are resolved by name: " &
       $gRvaRows.len & " are static RVAs whose 16 prologue bytes are compared " &
       "before they are called, and " & $gRvaFieldRows.len & " are FIELD " &
       "READS at offsets from fieldOffsets, which have no prologue to compare " &
       "and rest instead on a VirtualQuery per hop and on the receiver " &
       "argument printed above. The other " & $gRvaRefusals.len & " members " &
       "SAIN asks for are refused by name above and are NOT retried " &
       "reflectively. This does NOT make SAIN's combat brain work: the " &
       "movement call, the sprint call, the stop call, the shoot call and the " &
       "whole alive-players list are all in the refused set, so no bot is " &
       "driven by this mod. EVERY FIELD ROW IS A READ -- the field mechanism " &
       "has no invoke path at all, so nothing added here can drive a bot. " &
       "What the field rows buy is that stamina, suppression, the goal enemy, " &
       "weapon readiness, sprint state and the three medical components are " &
       "READABLE for the first time, which also makes the already-bound " &
       "memUnderFire, surgHave and stNormal rows reachable at last."

proc rvaTally*(): (int, int, int, int) =
  ## (rows, refusals, verified, rejected) -- numbers for a self-test to assert
  ## on, so a refusal cannot degrade into a silent zero unnoticed.
  rvaLoad()
  result = (gRvaRows.len, gRvaRefusals.len, gRvaVerified, gRvaRejected)

proc rvaFieldTally*(): (int, int, int) =
  ## (field rows, field rows bound, field hops refused). A separate tuple
  ## rather than a wider one, so an existing assertion on `rvaTally` keeps
  ## meaning exactly what it meant.
  rvaLoad()
  result = (gRvaFieldRows.len, gRvaFieldBound, gRvaFieldFaults)

type
  MemberRow* = object
    ## One entry of the binding table, as data.
    ##
    ## THE POINT OF THIS TYPE IS THAT THERE IS ONE LIST. `report()` and
    ## `levelCensus()` ask different questions of the same 45 members, and
    ## before this existed the only way to ask a second question was to paste
    ## the list again -- at which point the two drift and the census silently
    ## stops covering a member somebody added. The copy is 45 objects, built
    ## twice a raid on the reporting path, and never in a tick.
    name*: string
    call*: LazyCall

proc memberRows*(): seq[MemberRow] =
  ## Every member `bindAll` covers, in the order a human reads them.
  result = @[]
  result.add MemberRow(name: "List.Count", call: gB.listCount)
  result.add MemberRow(name: "List.Item", call: gB.listItem)
  result.add MemberRow(name: "Player.IsAI", call: gB.pIsAI)
  result.add MemberRow(name: "Player.ProfileId", call: gB.pProfileId)
  result.add MemberRow(name: "Player.AIData", call: gB.pAIData)
  result.add MemberRow(name: "Player.HealthController", call: gB.pHealth)
  result.add MemberRow(name: "Player.MovementContext", call: gB.pMovement)
  result.add MemberRow(name: "Player.Position", call: gB.pPosition)
  result.add MemberRow(name: "Player.LookDirection", call: gB.pLookDir)
  result.add MemberRow(name: "AIData.BotOwner", call: gB.aiBotOwner)
  result.add MemberRow(name: "MovementContext.IsSprintEnabled", call: gB.mcSprint)
  result.add MemberRow(name: "HealthController.IsAlive", call: gB.hcAlive)
  result.add MemberRow(name: "HealthController.GetBodyPartHealth", call: gB.hcBodyPart)
  result.add MemberRow(name: "BotOwner.Memory", call: gB.boMemory)
  result.add MemberRow(name: "BotOwner.WeaponManager", call: gB.boWeapon)
  result.add MemberRow(name: "BotOwner.Mover", call: gB.boMover)
  result.add MemberRow(name: "BotOwner.Steering", call: gB.boSteering)
  result.add MemberRow(name: "BotOwner.ShootData", call: gB.boShoot)
  result.add MemberRow(name: "BotOwner.AimingManager (identity only)", call: gB.boAiming)
  result.add MemberRow(name: "AimingManager.CurrentAiming (identity only)", call: gB.amCurrent)
  result.add MemberRow(name: "BotOwner.BotsGroup (identity only)", call: gB.boBotsGroup)
  result.add MemberRow(name: "GameWorld.Grenades", call: gB.wGrenades)
  result.add MemberRow(name: "Grenade.Position", call: gB.grPosition)
  result.add MemberRow(name: "BotMemory.IsUnderFire", call: gB.memUnderFire)
  result.add MemberRow(name: "BotMemory.GoalEnemy", call: gB.memGoalEnemy)
  result.add MemberRow(name: "Enemy.Person", call: gB.enPerson)
  result.add MemberRow(name: "Enemy.IsVisible", call: gB.enVisible)
  result.add MemberRow(name: "Enemy.CanShoot", call: gB.enCanShoot)
  result.add MemberRow(name: "Enemy.CurrPosition", call: gB.enPosition)
  result.add MemberRow(name: "Weapon.HaveBullets", call: gB.wmHaveBullets)
  result.add MemberRow(name: "Reload.TryReload", call: gB.rlTryReload)
  result.add MemberRow(name: "Mover.GoToPoint", call: gB.mvGoTo)
  result.add MemberRow(name: "Mover.Sprint", call: gB.mvSprint)
  result.add MemberRow(name: "Steering.LookToPoint", call: gB.stLookTo)
  result.add MemberRow(name: "ShootData.Shoot", call: gB.sdShoot)
  result.add MemberRow(name: "Mover.Stop", call: gB.mvStop)
  result.add MemberRow(name: "FirstAid.ShallStartUse", call: gB.faShall)
  result.add MemberRow(name: "SurgicalKit.ShallStartUse", call: gB.surgShall)
  result.add MemberRow(name: "FirstAid.TryApplyToCurrentPart", call: gB.faApply)
  result.add MemberRow(name: "Stimulators.TryApply", call: gB.stimApply)
  result.add MemberRow(name: "SurgicalKit.TryApplyToCurrentPart", call: gB.surgApply)

proc report*() =
  ## Every binding's own account of itself, once.
  ##
  ## `docs/PERF.md` asks for exactly this: read the binding's `why` into the log
  ## once, because "a refused binding is a mod that will quietly do nothing
  ## otherwise". A bot standing still is indistinguishable from a bot deciding
  ## to stand still, and this is the only thing that tells them apart.
  if gB.reported or not gB.ready:
    return
  gB.reported = true
  info "sain: IL2CPP bindings --"
  info "sain:   " & gB.worldWhy
  info "sain:   " & gB.aliveWhy
  let rows = memberRows()
  var ri = 0
  while ri < rows.len:
    reportOne(rows[ri].name, rows[ri].call)
    inc ri

type
  BindTally* = object
    ## How the binding table came out, as numbers rather than as log lines.
    ##
    ## `report()` is for a human reading a log after a client update. This is
    ## for the self-test, which needs to assert that a refusal *is* a refusal
    ## -- carrying a reason, on no path -- rather than a silent zero. Against
    ## `tests/mockil2cpp`, whose `EFT.Player` has almost none of these members,
    ## the correct answer is a large `missing` and an empty `silent`.
    fast*: int
    shaped*: int
    boxed*: int
    missing*: int
    ## Attempted, unresolved, and with no `why` to show for it. Must always be
    ## zero: a binding that refuses without saying why is the failure mode this
    ## whole file is written against.
    silent*: int
    ## Refused by the declared-signature gate: the name exists on this build
    ## and its signature is not the one this mod calls it with. Counted apart
    ## from `missing` because it is a different fact about the client and a
    ## different thing to go and check.
    refused*: int

proc tallyOne(t: var BindTally; l: LazyCall) =
  if l.b.ok and (l.shape == csStructReturn or l.shape == csVectorArg):
    t.shaped = t.shaped + 1
  elif l.b.ok:
    t.fast = t.fast + 1
  elif l.m != nil:
    t.boxed = t.boxed + 1
  elif l.gateRefused:
    t.refused = t.refused + 1
    if l.why.len == 0:
      t.silent = t.silent + 1
  elif l.tried:
    t.missing = t.missing + 1
    if l.why.len == 0:
      t.silent = t.silent + 1

proc tally*(): BindTally =
  ## Every member in the table, counted by the path it took. Only the members
  ## that have actually been *attempted* are counted -- a `LazyCall` resolves
  ## on first use, so one that was never used is neither bound nor refused, and
  ## counting it either way would be a lie.
  result = BindTally(fast: 0, shaped: 0, boxed: 0, missing: 0, silent: 0,
                     refused: 0)
  tallyOne(result, gB.listCount)
  tallyOne(result, gB.listItem)
  tallyOne(result, gB.pIsAI)
  tallyOne(result, gB.pProfileId)
  tallyOne(result, gB.pAIData)
  tallyOne(result, gB.pHealth)
  tallyOne(result, gB.pMovement)
  tallyOne(result, gB.pPhysical)
  tallyOne(result, gB.pPosition)
  tallyOne(result, gB.pLookDir)
  tallyOne(result, gB.aiBotOwner)
  tallyOne(result, gB.mcSprint)
  tallyOne(result, gB.phStamina)
  tallyOne(result, gB.stNormal)
  tallyOne(result, gB.hcAlive)
  tallyOne(result, gB.hcBodyPart)
  tallyOne(result, gB.boMemory)
  tallyOne(result, gB.boWeapon)
  tallyOne(result, gB.boMover)
  tallyOne(result, gB.boSteering)
  tallyOne(result, gB.boShoot)
  tallyOne(result, gB.boMedecine)
  tallyOne(result, gB.boAiming)
  tallyOne(result, gB.amCurrent)
  tallyOne(result, gB.boBotsGroup)
  tallyOne(result, gB.wGrenades)
  tallyOne(result, gB.glCount)
  tallyOne(result, gB.glItem)
  tallyOne(result, gB.grPosition)
  tallyOne(result, gB.memUnderFire)
  tallyOne(result, gB.memGoalEnemy)
  tallyOne(result, gB.enPerson)
  tallyOne(result, gB.enVisible)
  tallyOne(result, gB.enCanShoot)
  tallyOne(result, gB.enPosition)
  tallyOne(result, gB.wmHaveBullets)
  tallyOne(result, gB.wmReady)
  tallyOne(result, gB.wmReload)
  tallyOne(result, gB.rlTryReload)
  tallyOne(result, gB.rlBullets)
  tallyOne(result, gB.rlMaxBullets)
  tallyOne(result, gB.mvGoTo)
  tallyOne(result, gB.mvSprint)
  tallyOne(result, gB.stLookTo)
  tallyOne(result, gB.sdShoot)
  tallyOne(result, gB.mvStop)
  tallyOne(result, gB.medFirstAid)
  tallyOne(result, gB.medStims)
  tallyOne(result, gB.medSurgery)
  tallyOne(result, gB.faShall)
  tallyOne(result, gB.surgShall)
  tallyOne(result, gB.faApply)
  tallyOne(result, gB.stimApply)
  tallyOne(result, gB.surgApply)

proc headerCalibration*(): int =
  ## What the value-type size convention came out as. Exposed so the self-test
  ## can show that the calibration ran at all: a wrong answer here silently
  ## refuses every shaped binding, and the log then says the shape was checked
  ## when it was never reachable.
  headerBytes()

proc payloadSizeOf*(tn: string): int =
  ## The payload size of a value type, header removed, or 0 when the runtime
  ## will not name the type at all.
  ##
  ## `byPointerSize` answers the *convention* question and returns zero for a
  ## register-sized type, which is the right answer there and the wrong one
  ## here. `client/coverprobe.nim` needs a buffer to hand the engine as an
  ## `out NavMeshHit`, and the only honest way to size one is to ask the
  ## runtime how big the struct is -- guessing would be a layout assumption,
  ## which is the thing this mod does not make.
  result = 0
  if tn.len == 0 or not gLive:
    return
  if reflectionRefused(tn):
    return
  let c = gateFindClass(gRt, tn)
  if c == nil:
    return
  if not classIsValueType(gRt, c):
    return
  let sz = classInstanceSize(gRt, c) - headerBytes()
  if sz <= 0 or sz > 256:
    return
  result = sz

proc staticMethodOf*(owner, member: string; argc: int): Il2CppMethod =
  ## A static method, as a `MethodInfo`, or nil.
  ##
  ## Deliberately *not* a `LazyCall`: everything in that type binds against the
  ## class of an object it is handed, and a static has no object. The two
  ## engine entry points this mod wants -- `Physics::Raycast` and
  ## `NavMesh::SamplePosition` -- are static, take value types by pointer and
  ## return a bool, which no fast path here expresses, so they go through
  ## `il2cpp_runtime_invoke` and the caller is told as much in the log.
  result = cast[Il2CppMethod](0)
  if not gLive:
    return
  if reflectionRefused(owner & "::" & member):
    return
  let cls = gateFindClass(gRt, owner)
  if cls == nil:
    return
  let m = findMethod(gRt, cls, member, argc)
  if m == nil:
    return
  if not methodIsStatic(gRt, m):
    # A member of the right name and arity that is not static is not the method
    # this mod meant, and calling it with a null instance would be reading
    # whatever the register held. Refused rather than attempted.
    return
  result = m

proc invokeStatic*(m: Il2CppMethod; argv: Il2CppPtr): Il2CppPtr =
  ## `il2cpp_runtime_invoke` on a static, with the exception out-parameter
  ## actually read -- a managed throw does not unwind through a C caller, and
  ## ignoring it means using a null return as data.
  result = cast[Il2CppPtr](0)
  if m == nil or not gLive:
    return
  result = reflect(m, cast[Il2CppPtr](0), argv)

proc unboxBool*(boxed: Il2CppPtr): bool =
  ## A boxed `System.Boolean` the runtime handed back. One byte: reading four
  ## would run past the payload of the smallest box the runtime allocates.
  result = false
  if boxed == nil:
    return
  let p = objectUnbox(gRt, boxed)
  if p == nil:
    return
  result = readBool(gB0, p)

proc shapedSizeAccepted*(sz: int): bool =
  ## The Win64 rule, as a pure predicate, so both of its branches can be
  ## exercised offline. Anything that is not 1, 2, 4 or 8 bytes goes to memory;
  ## `tryShaped` additionally refuses past 16 because the buffer `readVec`
  ## provides is that wide.
  if sz <= 0 or sz > 16: return false
  result = sz != 1 and sz != 2 and sz != 4 and sz != 8

# ---------------------------------------------------------------------------
# The world
# ---------------------------------------------------------------------------

proc worldObject*(): Il2CppPtr =
  ## The live `EFT.GameWorld`, borrowed from the host. Null is an ORDINARY
  ## answer between raids and an INCONCLUSIVE one when no detour is armed --
  ## `gwStateText()` is what tells the two apart and every caller that reports
  ## this to a human must use it.
  ##
  ## This makes NO call into game code. That is the entire point: the call it
  ## used to make was into a method that does not exist, through a handle into
  ## unmapped memory, and it killed the client.
  result = cast[Il2CppPtr](0)
  if gwState() == 3:
    gwResolve()
    if gGwFn != nil:
      result = sainGwPV(gGwFn)

const AliveListOffset* = 0x1c8'i32
  ## `EFT.GameWorld.AllAlivePlayersList`, a `List<Player>` instance field.
  ## MEASURED: `tools/il2cpp_resolve.py fields EFT.GameWorld`, which reads
  ## `Il2CppMetadataRegistration.fieldOffsets` and self-checks against
  ## `System.String._stringLength@0x10`. NOT guessed, and there is no getter to
  ## use instead -- see `bindAll` phase 3.

proc alivePlayers*(world: Il2CppPtr): Il2CppPtr =
  ## The alive-players list, as a raw field read off a world the HOST validated
  ## and handed us. One hop, one measured offset, no call into game code.
  result = cast[Il2CppPtr](0)
  if world == nil:
    return
  var f = FieldBinding(ok: true, why: "AllAlivePlayersList@0x1c8 (measured)",
                       target: "EFT.GameWorld.AllAlivePlayersList",
                       offset: AliveListOffset, kind: fkPtr, bindNs: 0'i64)
  result = readPtr(f, world)

# The measured `List<Player>` layout (fact #226, MEASURED LIVE via the read-only
# inspector in a raid with 40 players). These are the standard il2cpp
# `List<T>`-of-reference offsets and are consistent with fact #78
# (`Il2CppArray.max_length@0x18`, element data from `+0x20`), stable across T.
#
#   List + 0x10 (ptr) -> Il2CppArray*  (_items)
#   List + 0x18 (i32) -> _size          (= 40 live: 39 bots + local player)
#   Array + 0x18 (i32)-> max_length     (= 64, backing capacity)
#   Array + 0x20 + i*8 (ptr) -> Player[i]
#
# Every hop was confirmed readable live. The read below still VirtualQueries
# every hop, because a between-raid or dying-bot list can hold a stale entry --
# so this is a self-validating read (CLAUDE.md 9b), not a guessed offset trusted
# blind: an unreadable `_items`, an absurd `_size`, or an unreadable element is
# each handled without a dereference.
const ListItemsOffset*   = 0x10'i32   ## `List<T>._items` (Il2CppArray*)
const ListSizeOffset*    = 0x18'i32   ## `List<T>._size`  (int)
const ArrayMaxLenOffset* = 0x18'i32   ## `Il2CppArray.max_length` (int)
const ArrayDataOffset*   = 0x20'i32   ## first element of the backing array
const ListWalkHardCap*   = 512        ## absolute run-away guard, above any raid

proc arrayOf(list: Il2CppPtr): Il2CppPtr =
  ## The backing `Il2CppArray*` of a `List<T>`, or null if the list or its
  ## `_items` slot is not safely readable. One guarded hop.
  result = cast[Il2CppPtr](0)
  if not sainReadable(list, ListItemsOffset + 8):
    return
  var f = FieldBinding(ok: true, why: "List._items@0x10 (measured, fact #226)",
                       target: "List`1._items", offset: ListItemsOffset,
                       kind: fkPtr, bindNs: 0'i64)
  let arr = readPtr(f, list)
  if arr == nil:
    return
  if not sainReadable(arr, ArrayDataOffset):
    return
  result = arr

proc listBound(list, arr: Il2CppPtr): int =
  ## The number of live elements to walk: `_size`, clamped to the array's own
  ## `max_length` (a corrupt `_size` cannot run past the backing store) and to
  ## a hard cap. Negative or zero returns 0.
  result = 0
  if list == nil or arr == nil:
    return
  var fs = FieldBinding(ok: true, why: "List._size@0x18 (measured, fact #226)",
                        target: "List`1._size", offset: ListSizeOffset,
                        kind: fkI32, bindNs: 0'i64)
  var fm = FieldBinding(ok: true, why: "Array.max_length@0x18 (fact #78)",
                        target: "Il2CppArray.max_length", offset: ArrayMaxLenOffset,
                        kind: fkI32, bindNs: 0'i64)
  let size = int(readInt32(fs, list))
  let cap = int(readInt32(fm, arr))
  if size <= 0 or cap <= 0:
    return
  var n = size
  if n > cap: n = cap
  if n > ListWalkHardCap: n = ListWalkHardCap
  result = n

proc listLen*(list: Il2CppPtr): int =
  ## `List<Player>.Count`, read as `_size` off the measured field layout
  ## (fact #226) rather than through the shared-generic `get_Count` -- which
  ## needs a real `MethodInfo*` a NULL one cannot substitute for, the fatal
  ## by-name path. Every hop is VirtualQueried; an unreadable list or array
  ## returns 0, which is an ordinary answer between raids.
  result = 0
  if list == nil:
    return
  let arr = arrayOf(list)
  if arr == nil:
    return
  result = listBound(list, arr)

proc listAt*(list: Il2CppPtr; index: int): Il2CppPtr =
  ## `List<Player>.get_Item(int)`, read as `Array[index]` off the measured
  ## layout (fact #226). No call into game code: the element pointer is a
  ## guarded field read at `Array + 0x20 + index*8`. An out-of-range index, an
  ## unreadable element slot, or a stale null entry returns null and the caller
  ## skips it -- never a dereference, never a fault.
  result = cast[Il2CppPtr](0)
  if list == nil or index < 0:
    return
  let arr = arrayOf(list)
  if arr == nil:
    return
  let n = listBound(list, arr)
  if index >= n:
    return
  let elemOff = ArrayDataOffset + int32(index) * 8'i32
  if not sainReadable(arr, elemOff + 8):
    return
  var f = FieldBinding(ok: true, why: "Array[i]@0x20+i*8 (measured, fact #226)",
                       target: "Il2CppArray element", offset: elemOff,
                       kind: fkPtr, bindNs: 0'i64)
  let p = readPtr(f, arr)
  if p == nil:
    return
  # The element must itself be a readable managed object before it reaches the
  # driver, which will call `get_IsAI`/`get_ProfileId` on it. A stale slot from
  # a list being rebuilt is skipped here rather than faulting there.
  if not sainReadable(p, 8):
    return
  result = p

proc grenadeList*(world: Il2CppPtr): Il2CppPtr =
  ## The world's in-flight grenades, or null on a build that does not carry
  ## this member under this name -- which is an ordinary answer, and leaves
  ## `cdAvoidGrenade` unreachable exactly as it was before the sensor existed.
  result = cast[Il2CppPtr](0)
  if world == nil:
    return
  result = callObj(gB.wGrenades, world)

proc grenadeCount*(list: Il2CppPtr): int =
  result = 0
  if list == nil:
    return
  result = callIntOn(gB.glCount, list, 0)

proc grenadeAt*(list: Il2CppPtr; index: int): Il2CppPtr =
  result = cast[Il2CppPtr](0)
  if list == nil:
    return
  if not ensure(gB.glItem, list):
    return
  if gB.glItem.b.ok:
    var a = noArgs()
    addInt(a, int64(index))
    return callPtr(gB.glItem.b, list, a)
  var slot = int32(index)
  var argv: array[1, Il2CppPtr] = [cast[Il2CppPtr](addr slot)]
  result = reflect(gB.glItem.m, list, cast[Il2CppPtr](addr argv[0]))

proc grenadePosition*(g: Il2CppPtr): Vec3 =
  ## Bound lazily against the grenade's own class, which is the only way to
  ## reach it: a thrown item is a `Throwable` subclass whose name this mod does
  ## not know and does not need to.
  result = zeroVec()
  if g == nil:
    return
  result = readVec(gB.grPosition, g)

# ---------------------------------------------------------------------------
# Holding an object across frames
# ---------------------------------------------------------------------------

proc hold*(obj: Il2CppPtr): uint32 =
  ## Take a GC handle. **The only legal way to keep an object past this frame**:
  ## the collector moves objects, and a raw pointer held across two frames is a
  ## use-after-free waiting for its moment.
  if obj == nil or not gLive:
    return 0'u32
  result = gcHandleNew(gRt, obj, false)

proc target*(h: uint32): Il2CppPtr =
  ## This frame's pointer for a handle, or null if the object is gone. One
  ## indirect call, once per bot per tick; every read the bot then does runs
  ## off the pointer with no further indirection.
  if h == 0'u32 or not gLive:
    return cast[Il2CppPtr](0)
  result = gcHandleTarget(gRt, h)

proc drop*(h: uint32) =
  ## Let go. A handle held for the session pins the object for the session,
  ## which over a raid's worth of dead bots is a real leak.
  if h == 0'u32 or not gLive:
    return
  gcHandleFree(gRt, h)

# ---------------------------------------------------------------------------
# The shooter, out of a DamageInfo the game handed us
# ---------------------------------------------------------------------------
#
# MEASURED 2026-09-04, offline, against GameAssembly.dll 1.1.0.1.46777 with
# `tools/il2cpp_resolve.py ... fields EFT.Ballistics.DamageInfo`:
#
#   EFT.Ballistics.DamageInfo.Player   @0x60  IObserverToPlayerBridge
#   EFT.PlayerBridge._player           @0x18  EFT.Player
#
# BOTH numbers as `fieldOffsets` prints them, i.e. INCLUDING the 0x10 object
# header. `DamageInfo` is a value type wider than a register, so the host hands
# a typed frame's `argPointer` a pointer to an UNBOXED COPY -- no header -- and
# the offset to use there is 0x60 - 0x10 = 0x50. `EFT.PlayerBridge` is a
# reference type and keeps its header, so 0x18 is used as printed. Getting that
# subtraction backwards is the whole hazard on this path, so it is spelled out
# rather than folded into a literal.
#
# THE ONE THING THIS WALK CANNOT PROVE, stated plainly: `DamageInfo.Player` is
# declared as the INTERFACE `IObserverToPlayerBridge`, and this build gives no
# way to ask a live object its type. If the shooter's bridge is some other
# implementor, `+0x18` reads a foreign field and ANSWERS rather than faults --
# the exact failure mode a field row has. So this proc DOES NOT decide who shot;
# it produces a CANDIDATE address, and `driver.drainDamage` credits it only when
# it equals a player the bot table already holds. A foreign read yields an
# address that matches nothing and is counted as unmatched, which is a check
# that can fail. Never widen that.
const DamageInfoPlayerUnboxedOff* = 0x50
  ## `DamageInfo.Player` at 0x60 boxed, minus the 0x10 object header.
const PlayerBridgePlayerOff* = 0x18
  ## `EFT.PlayerBridge._player`, a reference type, as fieldOffsets prints it.

var gShooterAsked = 0
var gShooterWalked = 0
var gShooterRefused = 0

proc shooterCounters*(asked, walked, refused: var int) =
  asked = gShooterAsked
  walked = gShooterWalked
  refused = gShooterRefused

proc shooterFromDamageInfo*(di: uint64): uint64 =
  ## A candidate `EFT.Player` address for whoever produced this `DamageInfo`,
  ## or 0. Every hop VirtualQueried; nothing is called; nothing is written.
  result = 0'u64
  if di == 0'u64 or not gLive:
    return
  gShooterAsked = gShooterAsked + 1
  let base = cast[Il2CppPtr](di)
  if not sainReadable(base, DamageInfoPlayerUnboxedOff + 8):
    gShooterRefused = gShooterRefused + 1
    return
  let bridge = sainFldPtr(base, int64(DamageInfoPlayerUnboxedOff))
  if bridge == nil or not sainReadable(bridge, PlayerBridgePlayerOff + 8):
    gShooterRefused = gShooterRefused + 1
    return
  let who = sainFldPtr(bridge, int64(PlayerBridgePlayerOff))
  if who == nil or not sainReadable(who, 8):
    gShooterRefused = gShooterRefused + 1
    return
  gShooterWalked = gShooterWalked + 1
  result = cast[uint64](who)

# ---------------------------------------------------------------------------
# The per-raid LEVEL census
# ---------------------------------------------------------------------------
#
# `report()` says what each member did; `rvaReport()` says what the TABLE
# claims. Neither answers the question a coordinator raising one notch per raid
# actually has, which is: *at this level, how many of the members that were
# ALLOWED to bind did, and what did the rest say?*
#
# That question has to be asked against the finished state and it has to be
# askable of a member NOTHING EVER USED -- a `LazyCall` resolves on first use,
# so a member no bot reached reports `unused`, and counting `unused` as bound
# would be a census that cannot fail (CLAUDE.md 9b). So `unused` is its own
# bucket here and is reported as such; it is neither bound nor refused.

type
  LevelCensus* = object
    level*: int
    eligible*: int    ## members whose level requirement this level satisfies
    bound*: int       ## bound by static RVA or by field read
    refused*: int     ## attempted and refused, with a reason
    unused*: int      ## never reached by any bot, so never resolved
    aboveLevel*: int  ## eligible only at a higher level
    detail*: string   ## "name: reason; ..." for every refusal, capped

const CensusDetailCap = 12
  ## How many refusal reasons go into the one line. Past this the line names
  ## the count it withheld rather than growing without bound -- the host log is
  ## read by a tool, and a 40-refusal line is a line nobody reads.

proc levelCensusOf*(kind: string): LevelCensus =
  ## `kind` is "reads", "aim" or "drive" -- which SLICE of the table this
  ## census is about. The slice is decided by `sainRvaLevelFor`, the same
  ## function the gate in `ensure` uses, so a census and a gate cannot disagree.
  let want = (if kind == "drive": RvaLevelDrive
              elif kind == "aim": RvaLevelAim
              else: RvaLevelReads)
  result = LevelCensus(level: gRvaDriveLevel, eligible: 0, bound: 0,
                       refused: 0, unused: 0, aboveLevel: 0, detail: "")
  var shown = 0
  var hidden = 0
  let rows = memberRows()
  var i = 0
  while i < rows.len:
    let r = rows[i]
    inc i
    if r.call.rvaKey.len == 0:
      continue
    let need = sainRvaLevelFor(r.call.rvaKey)
    if need != want:
      continue
    result.eligible = result.eligible + 1
    if need > gRvaDriveLevel:
      result.aboveLevel = result.aboveLevel + 1
      continue
    if r.call.b.ok or r.call.fldOk:
      result.bound = result.bound + 1
    elif r.call.rvaTried or r.call.tried:
      result.refused = result.refused + 1
      if shown < CensusDetailCap:
        shown = shown + 1
        if result.detail.len > 0: result.detail.add "; "
        result.detail.add r.name & " (" & r.call.rvaKey & "): " &
          (if r.call.why.len > 0: r.call.why
           else: "REFUSED WITH NO REASON -- that is a bug in this file, not " &
                 "a fact about the client")
      else:
        hidden = hidden + 1
    else:
      result.unused = result.unused + 1
  if hidden > 0:
    result.detail.add "; (+" & $hidden & " more refusal(s) withheld from this line)"
  if result.detail.len == 0:
    result.detail = "none"

proc levelCensusLine*(kind: string): string =
  ## The one line a coordinator greps for after a raid.
  let c = levelCensusOf(kind)
  let label = (if kind == "drive": "LEVEL 3"
               elif kind == "aim": "LEVEL 2"
               else: "LEVEL 1")
  result = "sain " & label & ": " & $c.bound & " of " & $c.eligible &
           " " & kind & " bound, " & $c.refused & " refused: " & c.detail
  # The two buckets that are NEITHER, always, because a reader who sees
  # "3 of 27 bound, 0 refused" and no third number will conclude the other 24
  # failed silently. They did not; they were never asked.
  # THE CENSUS'S OWN INVARIANT, checked rather than assumed: every eligible
  # member lands in exactly one bucket. A member that fell through the
  # classification would otherwise vanish from the line and make "3 of 3 bound"
  # true of a table where three members were quietly unaccounted for.
  if c.bound + c.refused + c.unused + c.aboveLevel != c.eligible:
    result = result & " -- CENSUS BUG: the buckets sum to " &
             $(c.bound + c.refused + c.unused + c.aboveLevel) &
             " but " & $c.eligible & " member(s) were eligible, so at least " &
             "one member is unaccounted for and these numbers must not be " &
             "used as a verdict"
  result = result & " -- also " & $c.unused &
           " never reached by any bot (a LazyCall resolves on FIRST USE, so " &
           "this is 'not asked', not 'failed'), and " & $c.aboveLevel &
           " eligible only above sainRvaTableDriveLevel = " &
           rvaLevelName(gRvaDriveLevel)
