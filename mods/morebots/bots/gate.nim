## The two gates that have to be true before the client half touches IL2CPP.
##
## ---------------------------------------------------------------------------
## WHY THIS FILE EXISTS: the mechanism that quarantined this mod
## ---------------------------------------------------------------------------
##
## `mods/morebots` shipped as `morebots.dll.off`. Measured today: deploying
## `morebots.dll` killed the client ~30 ms after "HOST RUNNING", before Unity's
## main thread existed, and it was the only mod of twelve that did it.
##
## The old client gate was `whenReady("EFT.GameWorld")` in `onUpdate`, and it
## is A CHECK THAT CANNOT FAIL (CLAUDE.md 9b). It tests whether the TYPE
## RESOLVES, not whether a world exists. `EFT.GameWorld` is an ordinary type in
## `Assembly-CSharp.dll`, so it goes true the instant the IL2CPP runtime is up
## -- measured at ~47 ms after HOST RUNNING, at no screen, with no raid. The
## line it printed, "the game world is up; the census starts", was false every
## single time.
##
## What ran behind that gate, on the host's own thread, at 47 ms:
##
##   * `openCensus()` -> `openIl2Cpp()`;
##   * `censusBind()` -> `findClass` walking **every loaded assembly** while the
##     game's own loader is still adding to that list on another thread;
##   * `armDeaths()` -> `hookArgs("EFT.BaseStatisticsManager::OnDeath", ...)`,
##     which is a **by-name host detour: a WRITE into game code**. `mods/fov`
##     refuses by-name detours in the client outright for exactly this reason
##     (facts #143-145: resolving a name is harmless, USING it is fatal).
##
## So the mod armed a code-patching path against a name from the pre-1.0 C#
## surface, off the Unity thread, before the assemblies it was searching had
## finished loading. That is fact #136's shape -- the same one that quarantined
## `mods/fov` and was fixed there by holding all arming until the host confirms
## its main-thread drain has FIRED.
##
## This file supplies both halves of the replacement, and neither can silently
## say yes:
##
##  1. `mainThreadLive()` -- `call("aowlspt.host::main_thread")`, `bound` only
##     once the drain has actually fired on Unity's thread. In a surviving FOV
##     run that was 14.469 s, not 47 ms.
##  2. `worldState()` -- the host's `RegisterPlayer` cache, read through two
##     exports. THREE-way, never two: "I could not look" is INCONCLUSIVE and is
##     not "no raid", and is certainly not "there is a world".
##
## Nothing here calls into IL2CPP. It is `GetModuleHandleA` plus two
## `GetProcAddress` calls into a module that is already in the process, one
## `VirtualQuery`, and one host round trip -- all legal on any thread at any
## point in the boot.

import aowlspt
import aowlspt/game
import aowlspt/il2cpp
import aowlspt/json

{.emit: """
#include <stdint.h>
#include <windows.h>

/* Calling a raw address needs C: nimony refuses `cast[proc(...)](pointer)`.
 * The int32 form is a REAL int32 thunk rather than the low half of a pointer
 * return -- an int32 return leaves the upper 32 bits of RAX undefined, so a
 * pointer-shaped read of a function that returned 0 is a plausible non-zero
 * answer, i.e. a check that cannot fail. Same reasoning, same shape, as
 * `fov_gw_i32_v` in mods/fov/fov.nim. */
static void*   mb_gw_p_v  (void* f) { return ((void*  (*)(void))f)(); }
static int32_t mb_gw_i32_v(void* f) { return ((int32_t(*)(void))f)(); }

/* Every pointer hop this file makes. Kept byte-equivalent to
 * `aowl_is_readable` in abi/aowlspt_shim.h, restated locally because pulling a
 * shared ABI header into this translation unit would drop the build cache. */
static int32_t mb_is_readable(void* p, int32_t size) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || size <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    return 1;
}
""".}

proc mbGwPV(f: Il2CppPtr): Il2CppPtr {.importc: "mb_gw_p_v", nodecl.}
proc mbGwI32V(f: Il2CppPtr): int32 {.importc: "mb_gw_i32_v", nodecl.}
proc mbIsReadable(p: Il2CppPtr; size: int32): int32 {.
  importc: "mb_is_readable", nodecl.}

proc mbGetModuleHandleA(name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetModuleHandleA", sideEffect.}
proc mbGetProcAddress(m: Il2CppPtr; name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetProcAddress", sideEffect.}

# ---------------------------------------------------------------------------
# Gate 1 -- Unity's main thread, asked of the HOST
# ---------------------------------------------------------------------------

type
  MainThread* = object
    ok*: bool          ## the host answered at all
    bound*: bool       ## the drain is on Unity's thread and has FIRED
    methodName*: string
    frames*: int64

proc askMainThread*(): MainThread =
  ## The host answers this before it checks whether the runtime is up, so it is
  ## meaningful with no game -- which is what makes it usable as a boot gate.
  result = MainThread(ok: false, bound: false, methodName: "", frames: 0'i64)
  var raw = ""
  let empty = "[]"
  if call("aowlspt.host::main_thread", empty, raw) != Ok:
    return
  if raw.len == 0:
    return
  result.ok = true
  result.bound = asBool(field(raw, "bound"), false)
  result.methodName = asText(field(raw, "method"), "")
  result.frames = int64(asInt(field(raw, "frames"), 0))

# ---------------------------------------------------------------------------
# Gate 2 -- a world that actually exists
# ---------------------------------------------------------------------------

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

const
  GwNoExport* = 0
    ## No `aowl_host_gameworld` -- an older host, or not the client. INCONCLUSIVE.
  GwNotArmed* = 1
    ## The export is there but no detour populates it (host flag `debugEsp` or
    ## `botDiag` is off). INCONCLUSIVE -- this is NOT "no raid".
  GwNoWorld* = 2
    ## Armed, cache empty. That is what a menu looks like, and it is a real no.
  GwLive* = 3
    ## A GameWorld the host's `RegisterPlayer` detour actually saw.

proc worldState*(): int =
  ## Three-way on purpose. "I could not look" is not "no world" and is not a
  ## world either; a caller that flattens this back to a bool has rebuilt the
  ## check that cannot fail.
  gwResolve()
  if gGwFn == nil:
    return GwNoExport
  if gGwArmedFn != nil and mbGwI32V(gGwArmedFn) == 0'i32:
    return GwNotArmed
  let w = mbGwPV(gGwFn)
  if w == nil:
    return GwNoWorld
  # Every hop is checked, including this one: the cache holds whatever the
  # detour last stored, and a stale entry from a finished raid is exactly the
  # pointer that reads plausible and faults on first use.
  if mbIsReadable(w, 8'i32) == 0'i32:
    return GwNoWorld
  result = GwLive

proc worldStateText*(): string =
  case worldState()
  of GwNoExport:
    "no host export `aowl_host_gameworld` -- this host predates it, or this " &
    "is not the client. INCONCLUSIVE, and the census stays off"
  of GwNotArmed:
    "the host exports the world but NO detour is armed to populate it (host " &
    "flag debugEsp or botDiag). INCONCLUSIVE -- not 'no raid'; the census " &
    "stays off rather than guess"
  of GwNoWorld:
    "armed; no GameWorld cached, which is exactly what a menu looks like"
  else:
    "GameWorld LIVE, borrowed from the host's RegisterPlayer cache"
