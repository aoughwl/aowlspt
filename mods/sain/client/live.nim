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

proc sainReadable(p: Il2CppPtr; size: int): bool =
  result = p != nil and sainIsReadable(p, int32(size)) != 0'i32

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

proc gateClassInstanceSize*(rt: Il2Cpp; cls: Il2CppClass): int =
  ## `il2cpp_class_instance_size` THROUGH the token gate. On this build that
  ## export is STATIC-gated (`abi/aowlspt_il2cpp_gates_data.h`): called in the
  ## stock shape it does NOT fail, it returns a random uint from the trap. So a
  ## RAW `classInstanceSize` two hops after a `gateFindClass` was a hole the
  ## comments here already named -- it dereferences nothing, but it feeds a size
  ## into `headerBytes` / `byPointerSize` as though it were real. Routed here it
  ## is real or REFUSED; 0 means refused-or-unknown, which every caller already
  ## treats as "not a size this understands", so the refusal costs nothing.
  ##
  ## This closes only what CAN be closed the same way `findClass` was. It does
  ## NOT and cannot bring `il2cpp_class_get_method_from_name` along:
  ## that export's third argument is an `int argc`, and the gate VirtualQuerys
  ## EVERY argument as a pointer (host thunk + `aowl_gate_call`), so a non-zero
  ## argc reads as an unreadable address and the gate refuses it. Instance size
  ## takes one pointer and no integer, which is why it passes and method lookup
  ## does not. The driver's per-tick bind path (`resolveOn`/`findOn`) therefore
  ## remains un-gated and is NOT unblocked by this or by the merged gateFindClass.
  result = 0
  if cls == nil:
    return
  if not gateAvailable():
    discard gateClassFromName(rt, cast[Il2CppImage](0), "", "")  # logs once
    return
  var ret: Il2CppPtr = cast[Il2CppPtr](0)
  var why: int32 = -1'i32
  var outstanding: int32 = -1'i32
  var exportName = "il2cpp_class_instance_size"
  let ok = sainGateCall(gGateFn, toCString(exportName), 1'i32,
                        cls, cast[Il2CppPtr](0), cast[Il2CppPtr](0),
                        addr ret, addr why, addr outstanding)
  if ok == 0'i32:
    debug "sain: gated il2cpp_class_instance_size refused: " & gateWhyText()
    return
  # A STATIC row arms no nonce, so nothing should be left outstanding. If the
  # host says otherwise, treat the whole answer as INCONCLUSIVE (CLAUDE.md 9b)
  # rather than trusting a number that came back beside a hazard.
  if outstanding != 0'i32:
    warn "sain: gated il2cpp_class_instance_size left " & $outstanding &
         " nonce arm(s) OUTSTANDING -- refusing the result as INCONCLUSIVE."
    return
  # The size is in RAX, zero-extended into `ret`. It is small and positive; a
  # wild value is read as unknown, which is the same 0 a refusal returns.
  let sz = cast[int](ret)
  if sz <= 0 or sz > 0x100000:
    return
  result = sz

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

const ReflectionRefusal* =
  "IL2CPP by-name resolution is refused on this build: " &
  "il2cpp_class_from_name and il2cpp_class_get_method_from_name return " &
  "NON-NIL handles into unmapped memory (fact #35), so a nil check passes " &
  "and the first dereference kills the client -- measured, this mod died " &
  "inside exactly that call. Set allowIl2cppReflection in config.json to " &
  "re-measure it on a future build."

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
           tried: false, why: "")

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
    let a = gateClassInstanceSize(gRt, i32)
    let b = gateClassInstanceSize(gRt, f64)
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
  let sz = gateClassInstanceSize(gRt, c) - headerBytes()
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

proc ensure*(l: var LazyCall; obj: Il2CppPtr): bool =
  ## True when the member is callable on this object, by one path or the other.
  ##
  ## The class comparison is the whole per-call overhead of binding lazily: one
  ## `il2cpp_object_get_class` and one pointer compare.
  if obj == nil or not gLive:
    return false
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
  var exc: Il2CppException = cast[Il2CppException](0)
  let r = invoke(gRt, m, obj, argv, exc)
  if exc != nil:
    return cast[Il2CppPtr](0)
  result = r

proc callObj*(l: var LazyCall; obj: Il2CppPtr): Il2CppPtr =
  ## A member returning a reference: the next step along the graph.
  result = cast[Il2CppPtr](0)
  if not ensure(l, obj):
    return
  if l.b.ok and l.b.ret == fkPtr and l.b.argc == 0'i32:
    var a = noArgs()
    return callPtr(l.b, obj, a)
  result = reflect(l.m, obj, cast[Il2CppPtr](0))

proc callBoolOn*(l: var LazyCall; obj: Il2CppPtr; default: bool): bool =
  result = default
  if not ensure(l, obj):
    return
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
  argv[0] = cast[Il2CppPtr](addr xyz[0])
  var i = 1
  while i < n:
    let tn = typeName(gRt, methodParam(gRt, l.m, i))
    if tn == "System.Single":
      writeFloat(gF0, cast[Il2CppPtr](addr scratch[i]), -1.0)
    elif tn == "System.Boolean":
      if i == 1 and flag:
        scratch[i] = 1'i64
    else:
      scratch[i] = 0'i64
    argv[i] = cast[Il2CppPtr](addr scratch[i])
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
  gB.listCount = lazy("get_Count")
  gB.listItem = lazyAs("get_Item", [fkI32], fkPtr)

  gB.pIsAI = lazy("get_IsAI")
  gB.pProfileId = lazy("get_ProfileId")
  gB.pAIData = lazy("get_AIData")
  gB.pHealth = lazy("get_HealthController")
  gB.pMovement = lazy("get_MovementContext")
  gB.pPhysical = lazy("get_Physical")
  gB.pPosition = lazy("get_Position")
  gB.pLookDir = lazy("get_LookDirection")

  gB.aiBotOwner = lazy("get_BotOwner")
  gB.mcSprint = lazy("get_IsSprintEnabled")

  gB.phStamina = lazy("get_Stamina")
  gB.stNormal = lazy("get_NormalValue")

  gB.hcAlive = lazy("get_IsAlive")
  gB.hcBodyPart = lazyAs("GetBodyPartHealth", [fkI32], fkNone)
  gB.vsCurrent = lazyField("Current")
  gB.vsMaximum = lazyField("Maximum")

  gB.boBotsGroup = lazy("get_BotsGroup")

  gB.wGrenades = lazy("get_Grenades")
  gB.glCount = lazy("get_Count")
  gB.glItem = lazyAs("get_Item", [fkI32], fkPtr)
  gB.grPosition = lazy("get_Position")

  gB.boMemory = lazy("get_Memory")
  gB.boWeapon = lazy("get_WeaponManager")
  gB.boMover = lazy("get_Mover")
  gB.boSteering = lazy("get_Steering")
  gB.boShoot = lazy("get_ShootData")
  gB.boMedecine = lazy("get_Medecine")
  gB.boAiming = lazy("get_AimingData")

  gB.memUnderFire = lazy("get_IsUnderFire")
  gB.memGoalEnemy = lazy("get_GoalEnemy")

  gB.enPerson = lazy("get_Person")
  gB.enVisible = lazy("get_IsVisible")
  gB.enCanShoot = lazy("get_CanShoot")
  gB.enPosition = lazy("get_CurrPosition")

  gB.wmHaveBullets = lazy("get_HaveBullets")
  gB.wmReady = lazy("get_IsReady")
  gB.wmReload = lazy("get_Reload")
  gB.rlTryReload = withGate(lazy("TryReload"), dsNoArgs)
  gB.rlBullets = lazy("get_BulletCount")
  gB.rlMaxBullets = lazy("get_MaxBulletCount")

  gB.medFirstAid = lazy("get_FirstAid")
  gB.medStims = lazy("get_Stimulators")
  gB.medSurgery = lazy("get_SurgicalKit")
  gB.faHave = lazy("get_HaveSmth2Use")
  gB.stimHave = lazy("get_HaveSmth2Use")
  gB.surgHave = lazy("get_HaveWork")
  # The three self-actions are gated too, and for a smaller reason than the
  # movers: `TryApply` on a stimulator component takes no arguments here, and
  # a build where it takes an item or a body part would resolve at arity zero
  # only if such an overload also existed -- but `callVoidOn` hands over a null
  # argument array either way, so the gate is what makes "found at arity zero"
  # mean "declares no parameters".
  gB.faApply = withGate(lazy("TryApplyToCurrentPart"), dsNoArgs)
  gB.stimApply = withGate(lazy("TryApply"), dsNoArgs)
  gB.surgApply = withGate(lazy("TryApplyToCurrentPart"), dsNoArgs)

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
  gB.mvGoTo = withGate(lazy("GoToPoint", 1'i32), dsVectorFirst)
  gB.mvGoTo.argcAlts = @[2'i32, 3'i32, 4'i32, 5'i32, 6'i32]
  # `Sprint` was `lazyAs([fkBool])`, which *stated* the signature rather than
  # asking for it: `resolveOn` skips the runtime's declared types entirely when
  # the caller supplied kinds, so a build where `Sprint` takes a float would
  # have had a bool put in a general-purpose register and the speed read out of
  # XMM. The stated kinds are kept -- they are still what the fast path binds
  # with -- and the gate is what now checks they are true.
  gB.mvSprint = withGate(lazyAs("Sprint", [fkBool], fkVoid), dsOneBool)
  gB.mvStop = withGate(lazy("Stop"), dsNoArgs)
  gB.stLookTo = withGate(lazy("LookToPoint", 1'i32), dsVectorFirst)
  gB.stLookTo.argcAlts = @[2'i32]
  gB.sdShoot = withGate(lazy("Shoot"), dsNoArgs)

  info "sain: bindAll complete -- all five phases returned"
  gB.ready = true

proc reportOne(name: string; l: LazyCall) =
  ## The shape is named separately from "fast", and deliberately so. A shaped
  ## binding is the one kind here that rests on an asserted calling convention
  ## rather than on the runtime'''s own answer, so anyone reading a log after a
  ## client update needs to be able to see at a glance which calls those are.
  if l.b.ok and l.shape == csStructReturn:
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
  reportOne("List.Count", gB.listCount)
  reportOne("List.Item", gB.listItem)
  reportOne("Player.IsAI", gB.pIsAI)
  reportOne("Player.ProfileId", gB.pProfileId)
  reportOne("Player.AIData", gB.pAIData)
  reportOne("Player.HealthController", gB.pHealth)
  reportOne("Player.MovementContext", gB.pMovement)
  reportOne("Player.Position", gB.pPosition)
  reportOne("Player.LookDirection", gB.pLookDir)
  reportOne("AIData.BotOwner", gB.aiBotOwner)
  reportOne("MovementContext.IsSprintEnabled", gB.mcSprint)
  reportOne("HealthController.IsAlive", gB.hcAlive)
  reportOne("HealthController.GetBodyPartHealth", gB.hcBodyPart)
  reportOne("BotOwner.Memory", gB.boMemory)
  reportOne("BotOwner.WeaponManager", gB.boWeapon)
  reportOne("BotOwner.Mover", gB.boMover)
  reportOne("BotOwner.Steering", gB.boSteering)
  reportOne("BotOwner.ShootData", gB.boShoot)
  reportOne("BotOwner.AimingData (identity only)", gB.boAiming)
  reportOne("BotOwner.BotsGroup (identity only)", gB.boBotsGroup)
  reportOne("GameWorld.Grenades", gB.wGrenades)
  reportOne("Grenade.Position", gB.grPosition)
  reportOne("BotMemory.IsUnderFire", gB.memUnderFire)
  reportOne("BotMemory.GoalEnemy", gB.memGoalEnemy)
  reportOne("Enemy.Person", gB.enPerson)
  reportOne("Enemy.IsVisible", gB.enVisible)
  reportOne("Enemy.CanShoot", gB.enCanShoot)
  reportOne("Enemy.CurrPosition", gB.enPosition)
  reportOne("Weapon.HaveBullets", gB.wmHaveBullets)
  reportOne("Reload.TryReload", gB.rlTryReload)
  reportOne("Mover.GoToPoint", gB.mvGoTo)
  reportOne("Mover.Sprint", gB.mvSprint)
  reportOne("Steering.LookToPoint", gB.stLookTo)
  reportOne("ShootData.Shoot", gB.sdShoot)
  reportOne("Mover.Stop", gB.mvStop)
  reportOne("FirstAid.TryApplyToCurrentPart", gB.faApply)
  reportOne("Stimulators.TryApply", gB.stimApply)
  reportOne("SurgicalKit.TryApplyToCurrentPart", gB.surgApply)

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
  let sz = gateClassInstanceSize(gRt, c) - headerBytes()
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

proc listLenWhy*(): string =
  ## Why there is no count. Read into the log rather than asserted, because a
  ## count of 0 and "I cannot count" are different answers and reporting the
  ## second as the first is the silent decline CLAUDE.md 6 forbids.
  result = "List<Player> cannot be counted on this build. `get_Count` is a " &
           "SHARED GENERIC, so it needs a real MethodInfo* -- a NULL one is " &
           "only safe for non-generics -- and the only route to one here is " &
           "by-name resolution, which returns a handle into unmapped memory " &
           "(fact #35). The field route is closed too: `List`1._size` has " &
           "offset 0 in the metadata table because a generic instantiation's " &
           "field offsets are allocated at RUNTIME, so there is no static " &
           "number to read and this mod will not guess one. Settling it needs " &
           "a LIVE measurement -- `dump`/`scan` on a real list pointer inside " &
           "a raid through the inspector -- not another offline pass"

proc listLen*(list: Il2CppPtr): int =
  ## Always 0, and `listLenWhy()` says why. It used to call `get_Count` through
  ## a by-name binding; on this build that is the same unmapped-memory jump
  ## that killed the client at `get_Instance`, and it had simply never been
  ## reached.
  result = 0

proc listAt*(list: Il2CppPtr; index: int): Il2CppPtr =
  ## `List<T>.get_Item(int)`.
  ##
  ## `classifyType` refuses the *declaring* type, because a generic
  ## instantiation has no name `findClass` accepts. The signature itself is one
  ## integer in and one reference out, which is a shape the fast path covers --
  ## so it is stated with `lazyAs` rather than inferred, and walking a
  ## thirty-player list is thirty bound calls rather than thirty reflective
  ## ones.
  result = cast[Il2CppPtr](0)
  if list == nil:
    return
  if not ensure(gB.listItem, list):
    return
  if gB.listItem.b.ok:
    var a = noArgs()
    addInt(a, int64(index))
    return callPtr(gB.listItem.b, list, a)
  var slot = int32(index)
  var argv: array[1, Il2CppPtr] = [cast[Il2CppPtr](addr slot)]
  result = reflect(gB.listItem.m, list, cast[Il2CppPtr](addr argv[0]))

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
