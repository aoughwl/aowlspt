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
## `schedule`, events, `patch` -- an x64 inline detour on the compiled method --
## and the escape hatch, `resolve` and `call`, which on this side means reaching
## any type and any method in the game by name.
##
## `invoke_main` means Unity's main thread when it can. The host detours a
## method the engine calls once per frame on that thread and drains the queue
## from inside it; `bindMainDrain` holds the candidate list and the honest
## account of which of them exist. When none can be detoured the queue runs on
## the host's own thread, exactly as it used to, and the log says so in those
## words rather than letting the name imply otherwise. A mod can ask:
## `call("aowlspt.host::main_thread")`.
##
## Mods can also come and go while the game runs. `modcontrol` answers the mod
## manager's control protocol, and -- because the manager lives in the *backend*
## process and an event cannot cross a process boundary -- this host also asks
## the backend directly, over the overlay's existing HTTP worker, which
## client-side mods should be running. See `takeModSet` and
## `host/common/modcontrol.nim`. It is a poll and never a push: no
## `backendPort`, no answer, or an answer that does not parse whole, and this
## host runs exactly what it loaded at boot.
##
## A patch may be a *prefix* or a *postfix*. A postfix takes a second thunk
## path: it calls the original rather than tail-jumping into it, so it regains
## control and can hand the handler what the method returned -- and may replace
## it. That costs two refusals, both checked at registration rather than found
## at run time: a value-type return wider than a register, which comes back
## through a buffer this host cannot read the layout of, and a compiled call
## with stack arguments, which a *called* original would look for in the thunk's
## frame. `postfixRefusal` in `invoke.nim` is both of them.
##
## `handle_pointer` turns a handle into the address of the object behind it, so
## a mod can reach `this` on its own fast path rather than through `call`. The
## address is good for the call it was got in and no longer; `handle_pin` is the
## way to keep one, and pins the object until the mod releases it.
##
## What it does not get: `db_get`/`db_patch` and `route_register`, which are
## server-side and return `ErrUnsupported`; and a *finalizer* patch, whose whole
## contract is the exception in flight, which does not cross this ABI.

import std/[strutils, syncio]
import aowlspt/il2cpp
import aowlspt/fast
import aowlsptinstall/winfs
import modstore
import modhost
import modcontrol
import jsonpath
import aowloverlay
import aowlgraphics
import invoke

{.emit: """#include "aowlspt_shim.h" """.}
## THE EVENT-DISPATCH GUARD. Straight after the shim because it takes exactly
## ONE `aowl_p_p_seh` and reads that guard's own thread-local to decide whether
## it may. A mod's event handler faulting used to take the process down from
## `deliverEvent` -- measured, Crash_2026-09-02_030042716. See
## `abi/aowlspt_evguard.h`.
{.emit: """#include "aowlspt_evguard.h" """.}
## THE READABILITY CACHE, in front of the shim's VirtualQuery syscall, for the
## per-frame GAME-DATA read paths ONLY. It must come straight after the shim,
## because it replicates the shim's predicate and audits itself against it.
## Detour binding, prologue verification and `aowl_is_code_pointer` deliberately
## keep calling the UNCACHED shim -- see the scope note in the header.
{.emit: """#include "aowlspt_rdcache.h" """.}
## The revision-3 live-object entry points. A separate header, and only this
## host includes it: `handle_pointer` and `handle_pin` mean nothing without a
## managed heap, and naming them in the shared shim would make every nimony
## binary that includes it have to define them. See `aowlspt_live.h`.
{.emit: """#include "aowlspt_live.h" """.}
{.emit: """#include "aowlspt_hostboot.h" """.}
{.emit: """#include "aowlspt_beclient.h" """.}
## The Unity-main-thread bridge: statically-resolved per-frame detour targets
## for this build, verified byte-for-byte before use, so `invoke_main` can be
## drained on Unity's own thread even when the runtime hands back no usable
## `MethodInfo.methodPointer`. See `aowlspt_bridge.h`.
{.emit: """#include "aowlspt_bridge.h" """.}
## Runtime resolution of a compiled method address out of IL2CPP's OWN
## per-assembly `Il2CppCodeGenModule.methodPointers` table, for the many methods
## on build 1.1.0.1.46777 whose `MethodInfo.methodPointer` reads NULL even
## though `findClass`/`findMethod` both succeed. Cross-checked offline against
## `tools/il2cpp_resolve.py` on seven methods across four different assemblies,
## including a BE RVA known independently from `aowlspt_beclient.h`. See
## `aowlspt_codegen.h` for the chain and for the safety argument.
{.emit: """#include "aowlspt_codegen.h" """.}
## NAME -> RVA, from an index generated OFFLINE. The codeGenModule table above
## is sound, but it is indexed by a method's token RID, and getting a RID needs
## a readable `MethodInfo` -- which this build does not give us: 6/6 probed
## MethodInfos were unreadable on the host thread AND 6/6 on the Unity main
## thread, so it is not thread affinity, it is simply unavailable. Every input
## to that resolution IS available offline, so `tools/il2cpp_nameindex.py` does
## the whole walk on the build machine (importing `tools/il2cpp_resolve.py`
## rather than reimplementing it) and freezes it into a sorted binary index that
## `aowlspt_nameindex.h` binary-searches. It calls nothing in IL2CPP at all.
{.emit: """#include "aowlspt_nameindex.h" """.}
## ORIGINAL PROLOGUE BYTES, snapshotted once before any detour is installed.
## Included FIRST of the target-owning headers, because every one of them
## verifies through it. Two features that share a target used to be unable to
## both verify it -- the first one's jump landed in the very bytes the second
## compared, so the second rejected a target that was never wrong. Every
## prologue check now compares against the snapshot instead of live memory; the
## check itself is unchanged and just as strict. See `aowlspt_prologue.h`.
{.emit: """#include "aowlspt_prologue.h" """.}

## THE TOKEN-GATED IL2CPP EXPORT LAYER (`aowlspt_il2cpp_gates.h`) and its
## live self-test (`aowlspt_il2cpp_gatetest.h`).
##
## 40 of the 241 `il2cpp_*` exports take an extra trailing 32-byte token
## that stock IL2CPP does not have, and `memcmp` it before doing any work.
## On a mismatch they do NOT return NULL: they tail-call a trap that
## returns MT19937-64 output. That is why a nil check passed and the first
## dereference killed the client. Included AFTER `aowlspt_prologue.h`
## because the layer follows the same startup-snapshot discipline, and it
## needs `aowlspt_shim.h` (guard + VirtualQuery), which is already above.
##
## Nothing here runs unless `il2cppGates` is set. It ships DEFAULT OFF.
{.emit: """#include "aowlspt_il2cpp_gates.h" """.}
{.emit: """#include "aowlspt_il2cpp_gatetest.h" """.}

## THE ONE SYMBOL MOD DLLs MAY USE TO REACH THE GATE LAYER.
##
## Every function in `aowlspt_il2cpp_gates.h` is `static` -- internal linkage,
## this translation unit only -- so a mod DLL could not reach any of it, and
## `mods/sain`'s `findClass` still called `il2cpp_class_from_name` with NO
## token. That call does not fail: it returns MT19937-64 output, and the first
## dereference kills the client.
##
## `{.exportc.}` alone would NOT fix this. It gives the generated C function an
## unmangled name; it does NOT put it in the PE export table (no .def file in
## this build), so `GetProcAddress` returns NULL and the mod logs "host too
## old" against a host that has the code. That measured defect silently
## disabled four mods once already -- hence the explicit `__declspec(dllexport)`
## thunk below, and the `exports` assertion in `tools/deploy.json`.
##
## WHAT IS DELIBERATELY *NOT* EXPORTED, and must never be:
##   * `aowl_gate_token` / `il2cpp_nonce` -- arming a nonce TLS slot without
##     consuming it in the same breath leaves a loaded gun on the thread. The
##     slot being zero is the ONLY reason SAIN's ~20 stock-signature by-name
##     calls have returned garbage rather than faulting inside the gate's own
##     memcmp at GameAssembly+0x6206E0. Killed the client three times.
##   * `aowl_gate_can_arm` -- a survey verb whose result reads like permission.
## `aowl_gate_call` arms and consumes atomically, so a caller never sees a slot.
##
## AND WHAT A WORKING GATE STILL DOES NOT BUY YOU: resolution by name becomes
## POSSIBLE, not SAFE. 28.3% of by-name lookups land on a SHARED RVA (property
## accessors funnel through `0x692A50` get_* / `0x692A60` set_*): CALLING one is
## fine, DETOURING one fires for hundreds of unrelated properties. And this
## build has a universal empty-body stub at `0x628110` shared by 6,438 methods,
## so a resolved, signature-checked address can still be a no-op that passes
## every check you wrote.
##
## Contract (all out-params optional, each VirtualQuery-checked before write):
##   int aowl_host_gate_call(const char* name, void** argv, int argc,
##                           void** out_ret, int* out_why,
##                           const char** out_whytext, int* out_outstanding)
## Returns 1 ONLY when the gate was satisfied AND the call completed. A non-zero
## `*out_ret` proves nothing on its own -- the trap never returns NULL -- so a
## caller must branch on the return value, never on the payload. With the
## `il2cppGates` flag off (the default) it refuses cleanly with
## `*out_why == AOWL_GATE_DISABLED`; a caller must then take its own refusal
## path and NEVER fall back to an un-tokened call.
##
## No `aowl_p_p_seh` is taken here: `aowl_gate_call` takes exactly one, and that
## guard is NOT re-entrant -- a guard around this thunk would DISARM it.
{.emit: """
__declspec(dllexport) int aowl_host_gate_call(
        const char* name, void** argv, int argc,
        void** out_ret, int* out_why, const char** out_whytext,
        int* out_outstanding) {
    aowl_gate_call_t c;
    int ok = 0, i;
    int why = AOWL_GATE_UNKNOWN;
    memset(&c, 0, sizeof(c));
    /* rule 2: VirtualQuery every pointer that crossed the module boundary,
     * including the ones we only WRITE. A mod passing a stack address that has
     * already unwound would otherwise be a blind write (rule 8). */
    if (out_why         && !aowl_is_readable((void*)out_why, sizeof(int)))    return 0;
    if (out_ret         && !aowl_is_readable((void*)out_ret, sizeof(void*)))  return 0;
    if (out_whytext     && !aowl_is_readable((void*)out_whytext, sizeof(void*))) return 0;
    if (out_outstanding && !aowl_is_readable((void*)out_outstanding, sizeof(int))) return 0;
    if (!name || !aowl_is_readable((void*)name, 1)) why = AOWL_GATE_BAD_ARG;
    else if (argc < 0 || argc > 3)                  why = AOWL_GATE_ARITY;
    else if (argc > 0 && (!argv || !aowl_is_readable((void*)argv, (int)(sizeof(void*) * (size_t)argc))))
                                                    why = AOWL_GATE_BAD_ARG;
    else {
        /* rule 4: bounded -- argc is already capped at 3 above. */
        for (i = 0; i < argc; i++) {
            if (argv[i] && !aowl_is_readable(argv[i], 1)) { why = AOWL_GATE_BAD_ARG; break; }
        }
        if (why != AOWL_GATE_BAD_ARG) {
            ok  = aowl_gate_call(name, argv, argc, &c);
            why = c.why;
        }
    }
    if (out_ret)         *out_ret         = ok ? c.ret : (void*)0;
    if (out_why)         *out_why         = why;
    if (out_whytext)     *out_whytext     = aowl_gate_why(why);
    /* The leaked-arm counter, handed out so a consumer can assert the negative:
     * after a completed call NOTHING may be left armed on this thread. */
    if (out_outstanding) *out_outstanding = aowl_gate_nonce_outstanding_count();
    return (ok && aowl_gate_call_ok(&c)) ? 1 : 0;
}
""".}
## PATCH BY VERIFIED STATIC RVA -- the address side of it, in C because it is
## three Win32 calls and no Nim.
##
## The base is asked for AT RUNTIME, every time. `0x180000000` is only
## GameAssembly.dll's PE *preferred* base -- the address space
## `tools/il2cpp_resolve.py` works in -- and the module is ASLR-relocated in the
## live process (observed at 0x7FFDB73F0000). Hardcoding the preferred base
## would land a detour on whatever happens to be mapped there. Every RVA in
## this project, `aowl_il2cpp_rva_of`'s included, is module-relative, so they
## are all directly comparable to the resolver's.
{.emit: """
static void* aowl_rva_code_at(unsigned int rva) {
  HMODULE ga = GetModuleHandleA("GameAssembly.dll");
  if (!ga) return NULL;
  return (void*)((unsigned char*)ga + rva);
}
static unsigned long long aowl_ga_base(void) {
  HMODULE ga = GetModuleHandleA("GameAssembly.dll");
  return (unsigned long long)(uintptr_t)ga;
}
/* Committed, EXECUTABLE, and with 16 whole bytes inside the same region --
 * one call, because a patch-by-RVA has to answer all three before it reads a
 * prologue, and three separate answers is three chances to check only two. */
static int aowl_rva_is_code(unsigned int rva) {
  MEMORY_BASIC_INFORMATION mbi;
  void* p = aowl_rva_code_at(rva);
  unsigned long long end;
  if (!p) return 0;
  if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
  if (mbi.State != MEM_COMMIT) return 0;
  if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                       PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
    return 0;
  end = (unsigned long long)(uintptr_t)mbi.BaseAddress
      + (unsigned long long)mbi.RegionSize;
  return ((unsigned long long)(uintptr_t)p + 16ULL <= end) ? 1 : 0;
}
""".}
## Two small client-side UX fixes: the Exit-hang byte patch (static .text, like
## the BE neuter) and the version-label brand target (a verified PreloaderUI.Awake
## code pointer the host postfix-detours to rewrite the label on the Unity
## thread). See `aowlspt_uxpatch.h`.
{.emit: """#include "aowlspt_uxpatch.h" """.}
## READ-ONLY GameWorld bot/player census: static field offsets + the verified
## `EFT.GameWorld::RegisterPlayer` detour target. Offsets/target only; the walk
## is in `botdiag.nim` (included below). See `aowlspt_botdiag.h`.
{.emit: """#include "aowlspt_botdiag.h" """.}
## THE TRUE DEPLOY SIGNAL: the two byte-verified, UNIQUE `AfterGameStarted`
## subscriber targets that run inside `EFT.GameWorld::OnGameStarted` (which is
## itself unhookable -- relative branch at prologue offset 10). Targets only; the
## latch is in `raidphase.nim`. See `aowlspt_raidstart.h`.
{.emit: """#include "aowlspt_raidstart.h" """.}
## OFFLINE SCAV-CAP LIFT: the MaxBots (+0xC0) offset + the verified
## `EFT.BotSpawner::AddPlayer` detour target + the guarded int32 read/write. The
## one field poke is in `botcap.nim` (included below). See `aowlspt_botcap.h`.
{.emit: """#include "aowlspt_botcap.h" """.}

## CATCH THE IN-GAME ERROR DIALOG: the three offline-verified (and offline
## UNIQUE-checked) `EFT.UI.PreloaderUI` error-screen entry points, the
## System.Exception field offsets, and the guarded System.String readers. The
## read-only detour bodies are in `errdlg.nim` (included below). This closes the
## one failure mode neither harness.py nor crashwatch.py could see: a modal error
## window is a crash with a button on it, and from outside it is identical to a
## healthy idle client. See `aowlspt_errdlg.h`. Must come AFTER
## `aowlspt_prologue.h` (line ~112) -- it verifies against the snapshot.
{.emit: """#include "aowlspt_errdlg.h" """.}

## BOT AI ACTIVATION RESCUE: the guarded static target + field offsets for the one
## bool poke that releases `BotWeaponManager.IsReady`, the gate `BotOwner::
## UpdateManual` checks before it will ever call `BotOwner::Activate`. The detour
## body is in `botai.nim` (included below). See `aowlspt_botai.h`.
{.emit: """#include "aowlspt_botai.h" """.}
## NATIVE BOT NAVIGATION API: the offsets, the byte-verified
## `EFT.BotOwner::UpdateManual` target, the guarded raw readers and the three
## direct-call thunks (GoToPoint, StopMove, SetTargetMoveSpeed). The registry
## and the service tick are in `botnav.nim` (included below). See
## `aowlspt_botnav.h`, and `docs/BOTNAV.md` for the recon behind every number.
{.emit: """#include "aowlspt_botnav.h" """.}
## Phase 1 native-settings probe: static field offsets for walking the live
## SettingsScreen control tree read-only. Offsets only; the walk is in
## `settingsui.nim` (included below). See `aowlspt_settingsui.h`.
{.emit: """#include "aowlspt_settingsui.h" """.}
## Phase 2/3 native-settings WRITE side: the four widget value-field offsets, the
## per-session klass anchors, and the guarded byte reader that the read header's
## siblings do not provide. Offsets and one primitive only; the writes themselves
## are in `settingswrite.nim` (included below). See `aowlspt_settingswrite.h`.
{.emit: """#include "aowlspt_settingswrite.h" """.}
## DIRECT managed invocation by static RVA: the build-pinned target table, the
## IL2CPP calling convention (documented there with disassembled evidence from
## the game's own call sites), the typed call thunks, and the runtime's
## allocation exports. Table and thunks only; the proof ladder that drives them
## is in `invoke2.nim` (included below). See `aowlspt_invoke2.h`.
{.emit: """#include "aowlspt_invoke2.h" """.}
## THE NATIVE UNITY UI CONSTRUCTION LAYER: the reusable API mods build real UI
## on. Byte-verified layout setters (the `_Injected` variants, so no by-value
## struct ABI is involved in either direction), the generalised
## `AddComponent<T>` MethodInfo cache-slot registry with its runtime klass
## check, interned managed strings (no per-frame allocation), and owned-object
## teardown. Table, thunks and pure arithmetic only; the guarded operations and
## the visual self-proof are in `nativeui.nim` (included below).
## MUST follow `aowlspt_prologue.h` -- every verify goes through the STARTUP
## SNAPSHOT, never live memory. See `aowlspt_nativeui.h`.
{.emit: """#include "aowlspt_nativeui.h" """.}
## The unified backend-agnostic widget core. This TU is the ONE that defines
## AOWL_UI_HOST, so `g_ui` (the retained widget table + binding table) is
## instantiated here exactly once. See `aowlui.nim` and `aowlspt_ui.h`.
{.emit: """#define AOWL_UI_HOST
#include "aowlspt_ui.h" """.}
## The main menu's bottom-right GAME MODE label: the verified `PreloaderUI`
## targets (`Update`, `SetGameModeText`, `RefreshCornerLabel`) and the one call
## thunk that drives it. The implementation is in `modetext.nim` (included
## below). See `aowlspt_modetext.h`.
{.emit: """#include "aowlspt_modetext.h" """.}
## SKIP THE MODE SCREEN. The three byte-verified selection-screen targets and
## the profile-data field offsets. See `aowlspt_modeskip.h`.
{.emit: """#include "aowlspt_modeskip.h" """.}
## AUTORAID'S PRE-MENU DISMISSAL. One byte-verified target,
## `EFT.UI.Settings.SettingsScreen::Close` @0x1720B10 (UNIQUE, arity 0), CALLED
## and never detoured, so that an overlaying Settings screen can be cleared by
## the screen's OWN close path instead of by hunting a Back button across every
## scene root. MUST follow `aowlspt_prologue.h`. See `aowlspt_premenu.h`.
{.emit: """#include "aowlspt_premenu.h" """.}
## FREE THE MOUSE WHILE AN OVERLAY PANEL IS OPEN. The four byte-verified
## `UnityEngine.Cursor` targets, the pure ref-count/save-restore decision (which
## `tests/overlayhost/cursortest.c` compiles standalone and asserts against
## OFFLINE) and the guarded tick body. The implementation is in `cursorfree.nim`
## (included below). MUST follow `aowlspt_prologue.h`. See `aowlspt_cursor.h`.
{.emit: """#include "aowlspt_cursor.h" """.}
## The mod-facing "which blocking UI surface is open" mask export
## (`aowl_ui_overlay_mask`) and the byte-verified getters behind its game-Settings
## bit. MUST follow `aowlspt_prologue.h` and `aowlspt_cursor.h`. See
## `aowlspt_uistate.h`.
{.emit: """#include "aowlspt_uistate.h" """.}
## The managed-write gate: klass verification, bounded stores, and the
## per-site trace. See `aowlspt_hostwrite.h`.
{.emit: """#include "aowlspt_hostwrite.h" """.}
## The in-game, Unity-native debug overlay: the F3 info panel and the
## in-world AI markers. Target table, call thunks, guarded scalar stores,
## the toggle key and the frame-rate estimate. See `aowlspt_debugui.h`.
{.emit: """#include "aowlspt_debugui.h" """.}
## THE PURE ARITHMETIC BEHIND "is it actually on screen" -- the CanvasGroup
## alpha fold, the on-screen classification, the degenerate-rect and collapsed-
## scale tests the inspector's `visible`/`screenrect` verbs consume. Free
## functions over doubles with no pointer to anything, so
## `tests/overlayhost/vistest.c` compiles the header standalone and asserts
## against it OFFLINE -- the client-side verbs then contain no arithmetic of
## their own to get wrong.
{.emit: """#include "aowlspt_visible.h" """.}
## NATIVE RAID ENTRY -- no UI clicking. The three byte-verified commit-path
## targets (`get_CurrentRaidSettings`, `get_MatchmakerOperation`,
## `OnReadyPressed`), their call thunks, and the guarded scalar read/write
## primitives. It DETOURS NOTHING; the implementation is in `natraid.nim`
## (included below) and rides the existing TarkovApplication::Update drain.
## MUST follow `aowlspt_prologue.h`. See `aowlspt_natraid.h`.
{.emit: """#include "aowlspt_natraid.h" """.}

## THE NATIVE uGUI ESP's pure-C half -- the single SEH shim, the fixed caps,
## the faction colour table, the fault budget and the three-outcome verdict
## vocabulary. No il2cpp; nothing in it can fault.
{.emit: """#include "aowlspt_natesp.h" """.}
## THE FRAME METER's pure-C half -- a QPC frame-interval histogram that depends
## on NOTHING under test. It is here, beside natesp, only because both are pure
## C over their own statics; it shares no state with it and no flag with it.
## Nothing in it dereferences a game pointer, so nothing in it can fault, and it
## arms no SEH guard on purpose. See `abi/aowlspt_frametime.h`.
{.emit: """#include "aowlspt_frametime.h" """.}
## THE DRAIN PROFILER's pure-C half -- a per-rider QPC bracket over every rider
## on the two per-frame drains, plus the positive control. Same shape as the
## frame meter and for the same reasons: pure C over its own statics, no il2cpp,
## nothing in it can fault, and it arms NO SEH guard on purpose -- every bracket
## it defines sits OUTSIDE the bracketed rider's own `aowl_p_p_seh`, which is
## not re-entrant. See `abi/aowlspt_drainprof.h`.
{.emit: """#include "aowlspt_drainprof.h" """.}
## RAYTRACED AUDIO's pure-C half -- the Vercidium Audio FFI, the bounded pump
## and the occlusion export. Emitted after `aowlspt_shim.h` because it uses
## `aowl_is_readable` and `aowl_p_p_seh`, and it takes exactly ONE of that guard,
## at its own two entry points; nothing inside it opens a second. It resolves no
## il2cpp name, installs no detour and dereferences no game pointer -- vaudio is
## an ordinary KERNEL32-only native DLL. See `abi/aowlspt_audioray.h`.
{.emit: """#include "aowlspt_audioray.h" """.}
## THE PHASE METER for the ONE rider the drain profiler priced at
## `splRebrandDrain = 1152.2us/frame, max 194373.3us` -- a disjoint, exhaustive
## decomposition of that single row, with its own positive control and an
## explicit UNEXPLAINED remainder. Same non-hooking, non-guarding contract as
## the drain profiler above, and gated by the SAME flag: with `drainProfiler`
## off every entry point is one predicted compare. See `abi/aowlspt_splprof.h`.
{.emit: """#include "aowlspt_splprof.h" """.}
## THE ONE WildSpawnType numeric table, shared verbatim with mods/maps so the
## minimap and the ESP boxes cannot disagree about who is a Rogue. Pure integer
## classification over a value the caller already read -- it dereferences
## nothing, which is why it is safe to share across the host/mod boundary.
{.emit: """#include "aowlspt_wildspawn.h" """.}
## THE NATIVE POSTFX CALL TABLE -- the twelve targets the POSTFX subtab's
## native rows CALL to drive the game's own post-processing and shading
## (CameraManager::SetSharpen / SetSSAO, PostFxSettingsController::TryUpdate*,
## ChangedShadowQuality, QualitySettings::get_shadowCascades). Nothing here is
## detoured; every row is a direct call at a byte-verified prologue.
##
## Included BEFORE `aowl_pro_prime_all` below so that table can name
## `aowl_npf_prime_all` directly rather than through a forward declaration.
{.emit: """#include "aowlspt_nativepostfx.h" """.}
## THE EAGER PROLOGUE SNAPSHOT. Defined here because it needs every target
## table above it, and CALLED from `hostReady` before any feature binds -- that
## ordering is the whole guarantee. Once this has run, no later verify can be
## fooled by a detour another feature installed first, whatever order the
## features happen to arm in.
##
## It walks the two tables whose targets are known to collide (the debug
## overlay's and the mode-text feature's, which share `PreloaderUI::Update`)
## plus that shared target itself. A table whose entries nothing else patches
## loses nothing by being absent here: the lazy capture inside `aowl_pro_verify`
## still records its original bytes on first verify, which for an uncontended
## target is necessarily before any patch of it exists.
{.emit: """
/* Defined further down, after `aowlspt_navui.h` is included by inspect.nim --
 * that table cannot be named from here, but it CAN be called from here, and a
 * forward declaration inside one translation unit is all that takes.
 *
 * It has to be primed eagerly, and the reason is a measured one. The nav
 * table's comment used to say the lazy capture was correct for it because
 * "nothing detours either of these at all". That was false: `settingsui.nim`
 * installs a postfix detour on `SettingsScreen::ShowScreen` (0x720DE0), which
 * is nav target #1. So the inspector's FIRST verify of ShowScreen happened
 * after the settings feature had already patched it, the lazy capture recorded
 * the TRAMPOLINE as if it were the original, and `open` then rejected a
 * perfectly correct target with
 *
 *     ShowScreen @0x720de0 did not verify -- the prologue does not match
 *     actual   ff 25 00 00 00 00 ...        <- a JMP: our own detour
 *     expected 48 89 5c 24 08 ...
 *
 * which is precisely the self-rejection this whole file was written to end.
 * The lazy path's assumption -- "a target's first verify precedes its first
 * patch" -- only holds for targets patched THROUGH a verify. A feature that
 * patches by another route breaks it, so a contended target must be primed
 * here whether or not the contention is obvious. */
static void aowl_pro_prime_navui(void);
/* The raid-load timeline's 33 targets (loadperf.nim). Defined further down
 * for the same reason `aowl_pro_prime_navui` is: that table cannot be NAMED
 * from here, but it CAN be called from here, and one forward declaration
 * inside one translation unit is all that takes. Primed eagerly and
 * unconditionally -- 33 rows of a 512-row table -- so no verify ever has to
 * depend on "nothing else patches that". */
static void aowl_lp_prime_all(void);
/* natesp's deploy-order breadcrumb (nedeploy.nim): four EFT.LocalGame rows,
 * same shape and same reason as the loadperf table above. Primed eagerly and
 * unconditionally even though nothing else patches them today -- the eager
 * pass exists precisely so that no verify has to depend on that. */
static void aowl_ndp_prime_all(void);

static void aowl_pro_prime_all(void) {
    int32_t i;
    for (i = 0; i < aowl_du_target_count(); i++)  aowl_pro_prime(aowl_du_rva(i));
    for (i = 0; i < aowl_mtx_target_count(); i++) aowl_pro_prime(aowl_mtx_rva(i));
    /* The shared one, explicitly: it lives in its own single-entry table and
     * is therefore in neither loop above, and it is the exact target the live
     * bug fired on. */
    aowl_pro_prime(aowl_du_preloader_update_rva());
    aowl_ndp_prime_all();
    /* The bot-nav API's detour target and its three call targets. Uncontended
     * as of today, primed anyway: this table is cheap and the whole point of
     * the eager pass is not to depend on "nothing else patches that". */
    for (i = 0; i < aowl_botnav_target_count(); i++)
        aowl_pro_prime(aowl_botnav_targets[i].rva);
    aowl_pro_prime(AOWL_BN_GOTOPOINT_RVA);
    aowl_pro_prime(AOWL_BN_STOPMOVE_RVA);
    aowl_pro_prime(AOWL_BN_SETSPEED_RVA);
    /* The inspector's UI-navigation targets. ShowScreen among them IS
     * contended -- see the note on the forward declaration above. */
    aowl_pro_prime_navui();
    /* The native-UI layer's 25 call targets. Two of them -- TMP_Text::set_text
     * and LocalizedText::SetLabelText -- are exactly the functions other UI
     * features reach for, so this is not a precaution, it is the case the
     * snapshot exists for. */
    aowl_nu_prime_all();
    /* The native-raid commit path. Uncontended by anything in this host today
     * -- primed anyway, because the eager pass exists precisely so no verify
     * ever depends on "nothing else patches that". */
    aowl_nr_prime_all();
    aowl_lp_prime_all();
    /* autoraid's PRE-MENU close target. Uncontended by anything in this host
     * today -- primed anyway, because the eager pass exists precisely so that
     * no verify ever depends on "nothing else patches that". */
    aowl_pmn_prime_all();
    /* The native POSTFX row set's twelve call targets. Uncontended by anything
     * in this host today -- none of them is detoured anywhere -- and primed
     * anyway, because the eager pass exists precisely so that no verify has to
     * depend on "nothing else patches that". */
    aowl_npf_prime_all();
}
""".}
{.emit: """#include "aowlspt_detour.h" """.}
## The typed patch frame. Included here as well as through `aowlspt_abi.h`
## because this file names its pool directly; the include guard makes the second
## one free.
{.emit: """#include "aowlspt_frame.h" """.}

## A C thunk that runs the Nim `settingsMetaProbe` (exported as
## `aowl_settings_meta_probe`) under the VEH+setjmp guard, once per STEP so each
## risky op is guarded independently -- a fault in one does not hide the others.
## The step is stashed in a global the Nim probe reads, because `aowl_p_p_seh`
## passes a single argument. Taking a Nim proc's address as a plain pointer is
## not expressible in nimony, but in C the exported proc's address is ordinary.
{.emit: """
extern void* aowl_settings_meta_probe(void* a);
static int g_aowl_probe_step = 0;
static void* aowl_settings_meta_probe_guarded(void* a, int step) {
    g_aowl_probe_step = step;
    return aowl_p_p_seh((void*)aowl_settings_meta_probe, a);
}
static int aowl_probe_step_get(void) { return g_aowl_probe_step; }

/* Guarded wrapper for the version brand's il2cpp_string_new allocation: the Nim
 * `brandNewStringImpl` (exported as `aowl_brand_newstring`) allocates the branded
 * String from a global the Nim side set; this runs it under the VEH guard so even
 * that runtime alloc cannot take the client down. */
extern void* aowl_brand_newstring(void* a);
static void* aowl_brand_newstring_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_brand_newstring, a);
}
""".}

# ------------------------------------------------- image CDN redirect
#
# SUPERSEDED, AND KEPT ONLY AS A PROBE. `docs/timbuktu/IMAGE-LOADING-RE2.md`
# settles this: against THIS emulator the client resolves nothing, because our
# `backend.Static` is the IP literal `https://127.0.0.1` and there is no name to
# look up. The CDN host below is what the *real* BSG server hands out in the raid
# capture, not what this client dials here. The images fail one layer lower --
# `DownloadTexture2D` builds a bare `UnityWebRequest` with no `certificateHandler`
# and Unity rejects our self-signed cert in the TLS handshake, so the request
# never becomes HTTP. The fix is `tools/imagecache.py`, which fills the client's
# own `Application.temporaryCachePath` cache that `LoadTextureWithCache` checks
# before it touches the network at all. Leave this hook off.
#
# Post-1.0 fetches trader avatars / handbook & quest icons from `/files/*`
# resolved against `backend.Static`.
#
# This installs an inline hook on the `getaddrinfo` family (via the same detour
# engine the il2cpp method patches use, `aowl_hook_install` -> a trampoline that
# still calls the original) and, for the asset-CDN hostname only, resolves it to
# `127.0.0.1` -- where the emulator backend answers `/regular/files/*`. Every
# other host resolves normally.
#
# It also RECORDS every hostname the client resolves, first sight only, which
# the host tick loop logs. One live run has now answered that: it logged ZERO
# hostnames, for images and for the working `/client/*` traffic alike, which is
# the proof that this configuration never uses the resolver.
#
# Flag-gated (`imageCdnRedirect`, default off) and fail-safe: a missing export
# or a failed install leaves DNS untouched; a non-target host is never rewritten.
{.emit: """
typedef int (__stdcall *AowlGaiW_t)(const wchar_t*, const wchar_t*, const void*, void**);
typedef int (__stdcall *AowlGaiA_t)(const char*, const char*, const void*, void**);

static int        g_cdn_enabled   = 0;
static AowlGaiW_t g_cdn_gaiw_orig = 0;
static AowlGaiA_t g_cdn_gaia_orig = 0;

#define AOWL_CDN_MAX_SEEN 64
static CRITICAL_SECTION g_cdn_lock;
static int  g_cdn_lock_init = 0;
static char g_cdn_seen[AOWL_CDN_MAX_SEEN][256];
static int  g_cdn_seen_redir[AOWL_CDN_MAX_SEEN];
static int  g_cdn_seen_count = 0;   /* distinct hosts recorded          */
static int  g_cdn_drained    = 0;   /* how many the host has logged     */

static void aowl_cdn_lock_ensure(void){
    if(!g_cdn_lock_init){ InitializeCriticalSection(&g_cdn_lock); g_cdn_lock_init=1; }
}
static char aowl_cdn_lc(char c){ return (c>='A'&&c<='Z') ? (char)(c+32) : c; }
static int aowl_cdn_ends_with(const char* s, const char* suf){
    int ls=0, lf=0; while(s[ls]) ls++; while(suf[lf]) lf++;
    if(lf>ls) return 0;
    for(int i=0;i<lf;i++){ if(aowl_cdn_lc(s[ls-lf+i])!=aowl_cdn_lc(suf[i])) return 0; }
    return 1;
}
static int aowl_cdn_starts_with(const char* s, const char* pre){
    for(int i=0;pre[i];i++){ if(aowl_cdn_lc(s[i])!=aowl_cdn_lc(pre[i])) return 0; }
    return 1;
}
/* The S3 asset-CDN family under escapefromtarkov.com (s3-prod and any regional
 * s3-* variant). Narrow on purpose: gw-pvp, lobby and the wsn-* notifier hosts
 * are NOT redirected. The seen-log below catches anything this misses. */
static int aowl_cdn_is_target(const char* host){
    if(!host || !host[0]) return 0;
    if(!aowl_cdn_ends_with(host, "escapefromtarkov.com")) return 0;
    return aowl_cdn_starts_with(host, "s3");
}
static void aowl_cdn_w2u(const wchar_t* w, char* out, int cap){
    int i=0; if(!w){ out[0]=0; return; }
    for(; w[i] && i<cap-1; i++) out[i]=(w[i]<128)?(char)w[i]:'?';
    out[i]=0;
}
static void aowl_cdn_record(const char* host, int redirected){
    if(!host || !host[0]) return;
    aowl_cdn_lock_ensure();
    EnterCriticalSection(&g_cdn_lock);
    int found=0;
    for(int i=0;i<g_cdn_seen_count;i++){
        int eq=1, k=0; const char* a=g_cdn_seen[i];
        for(;a[k]||host[k];k++){ if(aowl_cdn_lc(a[k])!=aowl_cdn_lc(host[k])){eq=0;break;} }
        if(eq){ found=1; break; }
    }
    if(!found && g_cdn_seen_count < AOWL_CDN_MAX_SEEN){
        int k=0; for(; host[k] && k<255; k++) g_cdn_seen[g_cdn_seen_count][k]=host[k];
        g_cdn_seen[g_cdn_seen_count][k]=0;
        g_cdn_seen_redir[g_cdn_seen_count]=redirected;
        g_cdn_seen_count++;
    }
    LeaveCriticalSection(&g_cdn_lock);
}
static int __stdcall aowl_cdn_gaiw(const wchar_t* node, const wchar_t* svc,
                                   const void* hints, void** res){
    char host[256]; aowl_cdn_w2u(node, host, (int)sizeof(host));
    int redir = (g_cdn_enabled && aowl_cdn_is_target(host));
    aowl_cdn_record(host, redir);
    if(redir && g_cdn_gaiw_orig) return g_cdn_gaiw_orig(L"127.0.0.1", svc, hints, res);
    if(g_cdn_gaiw_orig)          return g_cdn_gaiw_orig(node, svc, hints, res);
    return -1;
}
static int __stdcall aowl_cdn_gaia(const char* node, const char* svc,
                                   const void* hints, void** res){
    char host[256]; int i=0; if(node){ for(; node[i] && i<255; i++) host[i]=node[i]; } host[i]=0;
    int redir = (g_cdn_enabled && aowl_cdn_is_target(host));
    aowl_cdn_record(host, redir);
    if(redir && g_cdn_gaia_orig) return g_cdn_gaia_orig("127.0.0.1", svc, hints, res);
    if(g_cdn_gaia_orig)          return g_cdn_gaia_orig(node, svc, hints, res);
    return -1;
}
static void aowl_cdn_set_enabled(int on){ g_cdn_enabled = on ? 1 : 0; }
/* Install inline hooks. Returns a bitmask: 1=GetAddrInfoW, 2=getaddrinfo. */
static int aowl_cdn_install(void){
    aowl_cdn_lock_ensure();
    int mask=0;
    HMODULE ws = GetModuleHandleW(L"ws2_32.dll");
    if(!ws) ws = LoadLibraryW(L"ws2_32.dll");
    if(!ws) return 0;
    void* fw = (void*)GetProcAddress(ws, "GetAddrInfoW");
    if(fw){ void* h=aowl_hook_new();
        if(h){ if(aowl_hook_install(h, fw, (void*)aowl_cdn_gaiw)==0){
                    g_cdn_gaiw_orig=(AowlGaiW_t)((AowlHook*)h)->trampoline; mask|=1;
               } else aowl_hook_free(h); } }
    void* fa = (void*)GetProcAddress(ws, "getaddrinfo");
    if(fa){ void* h=aowl_hook_new();
        if(h){ if(aowl_hook_install(h, fa, (void*)aowl_cdn_gaia)==0){
                    g_cdn_gaia_orig=(AowlGaiA_t)((AowlHook*)h)->trampoline; mask|=2;
               } else aowl_hook_free(h); } }
    return mask;
}
/* Pop one not-yet-logged host for the tick loop. 1 + fills out/redir, else 0. */
static int aowl_cdn_take_new(char* out, int cap, int* redir){
    int got=0;
    aowl_cdn_lock_ensure();
    EnterCriticalSection(&g_cdn_lock);
    if(g_cdn_drained < g_cdn_seen_count){
        int idx=g_cdn_drained, k=0;
        for(; g_cdn_seen[idx][k] && k<cap-1; k++) out[k]=g_cdn_seen[idx][k];
        out[k]=0; *redir=g_cdn_seen_redir[idx];
        g_cdn_drained++; got=1;
    }
    LeaveCriticalSection(&g_cdn_lock);
    return got;
}
/* Same pop, but returning a pointer to a private static buffer instead of
 * filling a caller buffer -- the Nim tick loop is the only caller and it is one
 * thread, so a static is safe here and it keeps the Nim side free of a
 * stack array nimony cannot prove initialised. NULL when nothing is pending. */
static char g_cdn_take_buf[256];
static const char* aowl_cdn_take_new_str(int* redir){
    if(aowl_cdn_take_new(g_cdn_take_buf, (int)sizeof(g_cdn_take_buf), redir))
        return g_cdn_take_buf;
    return 0;
}
""".}

proc cCdnInstall(): int32 {.importc: "aowl_cdn_install", nodecl.}
proc cCdnSetEnabled(on: int32) {.importc: "aowl_cdn_set_enabled", nodecl.}
proc cCdnTakeNewStr(redir: ptr int32): cstring {.
  importc: "aowl_cdn_take_new_str", nodecl.}

var gImageCdnRedirect = false

# --------------------------------------------------- the main-thread handoff
#
# `invoke_main` used to mean "the host's own attached thread", which is not the
# thread Unity runs its player loop on, so a callback that touched a Unity
# object was a crash waiting for a frame. The fix is to detour a method Unity
# calls once per frame on that thread and drain the queue from inside it -- see
# `bindMainDrain` for which methods, and why the host cannot know at compile
# time which of them exists.
#
# This block is the part nimony cannot express: a lock, and counters read
# without one. The lock itself now comes from `abi/aowlspt_lock.h` -- it used
# to be a byte-for-byte copy of the one in `abi/aowlspt_net.h`, kept separate
# only because that header also pulls in winsock2 and zlib, neither of which
# belongs in a DLL injected into the game. The split header has the lock and
# nothing else, so this host can share it and still import nothing but
# kernel32.
{.emit: """#include "aowlspt_lock.h" """.}
{.emit: """#include "aowlspt_mqpolicy.h" """.}
{.emit: """
/* `aowl_lock` guards `gPending`. A mod calls `invoke_main` from a worker
 * thread; the drain runs on the game thread. That is a real handoff between two
 * threads neither of which the other knows about, so it needs a lock rather
 * than an argument about how unlikely the interleaving is.
 *
 * It is the process-wide lock from `aowlspt_lock.h` rather than one of this
 * host's own: this queue is the only thing in the client host that is contended
 * at all, and a second lock would be a second ordering to get wrong for no
 * measured gain. */

/* Read without the lock, on every frame, by the drain. A plain LONG rather
 * than a queue walk: the empty case is the only case most frames, and it has to
 * cost a load and a branch. It is written only under the lock, so the worst a
 * racing reader can see is the value from a moment ago -- which delays a
 * callback by one frame and cannot corrupt anything. */
static volatile LONG aowl_mq_count = 0;

/* The thread the drain hook fires on, claimed by the first frame that reaches
 * it. Claimed with an interlocked exchange rather than a plain store because
 * nothing guarantees the hooked method is called from one thread only -- and if
 * it is not, two threads draining the same queue would run one mod's callbacks
 * concurrently. Whoever gets there first is the main thread; anyone else is
 * counted and sent away. */
static volatile LONG aowl_mq_tid = 0;
static volatile LONG aowl_mq_alien = 0;
static LONG aowl_mq_fires = 0;   /* main thread only, so no interlock needed */

static void aowl_mq_set_count(int32_t n) { aowl_mq_count = (LONG)n; }
static int32_t aowl_mq_get_count(void) { return (int32_t)aowl_mq_count; }
static uint32_t aowl_mq_thread(void) { return (uint32_t)aowl_mq_tid; }
static int32_t aowl_mq_alien_fires(void) { return (int32_t)aowl_mq_alien; }
static int32_t aowl_mq_fire_count(void) { return (int32_t)aowl_mq_fires; }

/* The whole per-frame cost of an empty queue: two loads, two branches, one
 * increment. No allocation, no lock, no logging, and no call into the runtime.
 * Returns 1 only when this thread owns the drain *and* there is something to
 * run -- so the caller's slow path is entered on the frames that need it and no
 * others.
 *
 * The interlocked claim runs once, on the first frame, and never again: the
 * common path reads `aowl_mq_tid` plainly and compares. */
static int32_t aowl_mq_enter(void) {
    LONG me = (LONG)GetCurrentThreadId();
    LONG owner = aowl_mq_tid;
    if (owner == 0) {
        InterlockedCompareExchange(&aowl_mq_tid, me, 0);
        owner = aowl_mq_tid;
    }
    if (owner != me) { InterlockedIncrement(&aowl_mq_alien); return 0; }
    aowl_mq_fires++;
    return aowl_mq_count != 0;
}

/* The callback the per-frame bench runs, and the counter that proves it ran.
 *
 * A benchmark of the drain has to go all the way through `aowl_invoke_callback`
 * -- the trampoline, the slice build, the indirect call -- because that is what
 * a mod's callback costs to reach. A loop that stopped short of it would time
 * the queue and report it as the price of a callback.
 *
 * It is a real `AowlCallbackFn`, registered nowhere and owned by no mod, so
 * nothing about it can outlive the bench or be reached by a mod. The hit
 * counter is what the harness reads to know the loop actually dispatched:
 * a drain that dropped every entry on the floor would otherwise time as
 * wonderfully fast. */
static volatile LONG aowl_bench_hits = 0;
static AowlStatus AOWLSPT_CALL aowl_bench_cb(void* user, AowlSlice payload,
                                             AowlBuffer* out) {
    (void)user; (void)payload; (void)out;
    aowl_bench_hits++;
    return AOWLSPT_OK;
}
static void* aowl_bench_cb_ptr(void) { return (void*)aowl_bench_cb; }
static int32_t aowl_bench_hit_count(void) { return (int32_t)aowl_bench_hits; }

/* The render-phase queue. A second, independent queue drained from inside a
 * RENDER-phase Unity callback rather than the update-phase one -- because
 * immediate-mode `GL` drawing only rasterizes during render, so an ESP box or a
 * GL HUD has to be issued there, not from `TarkovApplication.Update`. Same shape
 * as the queue above, its own counter/owner/fire count so the two drains never
 * touch each other's state; it shares the one process lock (`aowl_lock`), which
 * is uncontended and already guards the update queue's `gPending`. */
static volatile LONG aowl_rq_count = 0;
static volatile LONG aowl_rq_tid = 0;
static volatile LONG aowl_rq_alien = 0;
static LONG aowl_rq_fires = 0;

static void aowl_rq_set_count(int32_t n) { aowl_rq_count = (LONG)n; }
static int32_t aowl_rq_get_count(void) { return (int32_t)aowl_rq_count; }
static uint32_t aowl_rq_thread(void) { return (uint32_t)aowl_rq_tid; }
static int32_t aowl_rq_fire_count(void) { return (int32_t)aowl_rq_fires; }

static int32_t aowl_rq_enter(void) {
    LONG me = (LONG)GetCurrentThreadId();
    LONG owner = aowl_rq_tid;
    if (owner == 0) {
        InterlockedCompareExchange(&aowl_rq_tid, me, 0);
        owner = aowl_rq_tid;
    }
    if (owner != me) { InterlockedIncrement(&aowl_rq_alien); return 0; }
    aowl_rq_fires++;
    return aowl_rq_count != 0;
}
""".}

proc cMqLock() {.importc: "aowl_lock", nodecl.}
proc cMqUnlock() {.importc: "aowl_unlock", nodecl.}
proc cRqSetCount(n: int32) {.importc: "aowl_rq_set_count", nodecl.}
proc cRqCount(): int32 {.importc: "aowl_rq_get_count", nodecl.}
proc cRqThread(): uint32 {.importc: "aowl_rq_thread", nodecl.}
proc cRqFireCount(): int32 {.importc: "aowl_rq_fire_count", nodecl.}
proc cRqEnter(): int32 {.importc: "aowl_rq_enter", nodecl.}

# ------------------------------------------------------- the host's tables
#
# `cMqLock` was named for the main-thread queue because that is all it used to
# guard. It guards the rest of this host's mutable state now, and the rename
# would cost more than it explains, so this block is the explanation instead.
#
# **Three threads touch these tables.** The host's own tick loop loads and
# unloads mods and drops what they registered. The game's thread runs every
# patch firing and the per-frame drain. And *any* thread a mod cares to create
# calls `resolve`, `call`, `handle_release`, `event_subscribe` and `patch` --
# the ABI never said a mod may not, and a mod that polls the game from a worker
# is doing the thing this host exists to allow.
#
# Until now none of it was guarded. The symptom was an occasional failed shrink
# of the handle table under churn, which is the mild end of the same fault: a
# `seq` that grows reallocates, and a thread indexing the old buffer while
# another has moved it is a read of freed memory rather than a wrong number.
#
# **What is guarded**: the handle table and its free queue (`gHandles`,
# `gHandleIsObject`, `gHandleGc`, `gHandleFree`), the subscription list
# (`gSubs`), and the *rows* of the patch table (`gPatches`) as they are written
# and torn down. `gPending` always was.
#
# **What is deliberately not guarded, and why:**
#
#  * **The firing path.** `patchFired` -> `typedFire` runs on the game's thread
#    inside a patched method, thousands of times a second, and a lock there is
#    frame time. It is measured rather than argued about: the typed prefix path
#    is 23 ns end to end (`perfbench`), and an uncontended `EnterCriticalSection`
#    /`LeaveCriticalSection` pair is of the same order -- so guarding it would
#    cost most of what the typed path was built to save. It stays off the lock,
#    and is made safe another way: `gPatches` is grown to the detour engine's
#    full slot capacity **once, at startup** (`reservePatchRows`), so the
#    backing array never moves under a firing. A row is written before its hook
#    is attached and cleared after its hook is removed, and `live` is the flag
#    that gates the read.
#
#  * **The typed path's handles.** It takes none. That is what makes the
#    above possible: `typedFire` hands the mod a borrowed view of the saved
#    registers and touches no host table at all. The **JSON** firing path does
#    take handles, and it *is* locked -- around the describe and around the
#    reclaim, never around the call into the mod.
#
#  * **`cMqEnter`,** the drain's per-frame "is this my thread and is there
#    anything to do". It is two loads and a branch by design and is already
#    correct without a lock; see its own comment.
#
#  * **`modhost.gMods`.** A mod row is added on the host's tick thread and read
#    from mod threads (`config_get`, the store). It only ever grows and is
#    never compacted, so the failure mode is a reallocation under a reader, the
#    same as the handle table's -- but the lock for it belongs in `modhost`,
#    which the backend shares, and this host cannot add it alone. It is left as
#    it is and said out loud rather than half-fixed here.
#
# One lock and not several, for the reason `aowlspt_lock.h` gives: everything
# under it is touched at human rates or on paths that already cost hundreds of
# nanoseconds, and one lock nobody has to reason about the ordering of is worth
# more than a set of finer ones somebody eventually takes in two orders. It is
# a Windows critical section, so a mod handler that calls back into the host on
# the same thread re-enters rather than deadlocking -- but no host call holds it
# across a call into a mod, which is the rule that actually matters.
proc tablesLock() {.inline.} = cMqLock()
proc tablesUnlock() {.inline.} = cMqUnlock()
proc cMqSetCount(n: int32) {.importc: "aowl_mq_set_count", nodecl.}
proc cMqCount(): int32 {.importc: "aowl_mq_get_count", nodecl.}
proc cMqThread(): uint32 {.importc: "aowl_mq_thread", nodecl.}
proc cMqAlienFires(): int32 {.importc: "aowl_mq_alien_fires", nodecl.}
proc cMqFireCount(): int32 {.importc: "aowl_mq_fire_count", nodecl.}
proc cMqEnter(): int32 {.importc: "aowl_mq_enter", nodecl.}

# THE ONE RULE about which thread may run queued main-thread work, and the
# four-state health of the drain. Both live in `abi/aowlspt_mqpolicy.h` rather
# than here so that `tools/test_mqpolicy.py` can COMPILE and RUN them offline
# against a fake stalled drain -- see the header for the two boot crashes of
# 2026-09-02 that the old "run it on the host thread" fallback caused.
proc cMqMayRunHere(callerTid, ownerTid: uint32; hostSafe: int32): int32 {.
  importc: "aowl_mq_may_run_here", nodecl.}
proc cMqHealth(slot, fires: int32; sinceMs, stallMs: uint64): int32 {.
  importc: "aowl_mq_health", nodecl.}
proc cMqHealthText(h: int32): cstring {.
  importc: "aowl_mq_health_text", nodecl.}

const
  DrainUnbound = 0
  DrainNeverFired = 1
  DrainStalled = 2
  DrainLive = 3
  DrainStallMs = 2000'u64
    ## How long a drain that HAS fired may go quiet before the host calls it
    ## stalled. It applies only from the first firing onwards: before that the
    ## state is `DrainNeverFired` and no clock is consulted at all. The old code
    ## started this clock at host boot, which meant it always expired -- the
    ## first `TarkovApplication::Update` of a boot is ~15 s after the detour
    ## binds, because the behaviour the player loop ticks does not exist until
    ## the preloader has built it. That is the game's schedule, not ours; there
    ## is nothing to fix on our side except the wrong expectation.
proc cBenchCb(): Il2CppPtr {.importc: "aowl_bench_cb_ptr", nodecl.}
proc cBenchHits(): int32 {.importc: "aowl_bench_hit_count", nodecl.}

# --------------------------------------------------------------- C surface

proc cModulePath(buf: Il2CppPtr; cap: int32): int32 {.
  importc: "aowl_sys_module_path", nodecl.}
proc cNowMs(): uint64 {.importc: "aowl_sys_now_ms", nodecl.}
proc cSleep(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}
proc cThreadId(): uint32 {.importc: "aowl_sys_thread_id", nodecl.}
proc cIsCodePointer(p: Il2CppPtr): int32 {.
  importc: "aowl_is_code_pointer", nodecl.}

## Fills `handle_pointer`/`handle_pin` and only then grows the struct's reported
## `size`. `aowl_hostapi_new` leaves both null and reports the revision-2 size,
## because a mod is told it may trust `size` before calling an appended pointer
## and that has to stay true of a host without a managed heap.
proc cHostApiArmLive(p: Il2CppPtr) {.importc: "aowl_hostapi_arm_live", nodecl.}
## Revision 4's `patch_typed`, armed separately from the live pair because they
## are separate capabilities -- see `aowlspt_live.h`. Called right after it, so
## `size` only ever grows.
proc cHostApiArmTyped(p: Il2CppPtr) {.importc: "aowl_hostapi_arm_typed", nodecl.}
## Revision 6's `invoke_render`, armed after the pair above so `size` only grows.
## The entry is always real; it answers `ErrUnsupported` until a render-phase
## drain binds. See `aowl_hostapi_arm_render` in `aowlspt_live.h`.
proc cHostApiArmRender(p: Il2CppPtr) {.importc: "aowl_hostapi_arm_render", nodecl.}

## The typed patch frame: a pooled, borrowed view of the thunk's saved
## registers, handed to a mod instead of a JSON payload. `aowlspt_frame.h` has
## the mechanism and the lifetime rule.
proc cFrameSlot(depth: int32): Il2CppPtr {.importc: "aowl_frame_slot", nodecl.}
proc cFrameArm(f, regs, kinds: Il2CppPtr; argc, retKind: int32;
               flags: uint32; self: uint64) {.importc: "aowl_frame_arm", nodecl.}
proc cFrameDisarm(f: Il2CppPtr) {.importc: "aowl_frame_disarm", nodecl.}
proc cFrameDepthMax(): int32 {.importc: "aowl_frame_depth_max", nodecl.}
proc cInvokeTypedPatch(cb, user, frame: Il2CppPtr): int32 {.
  importc: "aowl_invoke_typed_patch", nodecl.}
proc cFreeBuf(p: Il2CppPtr) {.importc: "aowl_host_release", nodecl.}

const
  FrameFlagPostfix = 0x1'u32
  FrameFlagStatic = 0x2'u32

proc cInvokePatchArgs(cb, user, target: Il2CppPtr; tlen: int32;
                      args: Il2CppPtr; alen: int32;
                      outPtr, outLen: Il2CppPtr): int32 {.
  importc: "aowl_invoke_patch_args", nodecl.}


proc cHookNew(): Il2CppPtr {.importc: "aowl_hook_new", nodecl.}
proc cHookFree(p: Il2CppPtr) {.importc: "aowl_hook_free", nodecl.}
proc cHookAttach(p, target: Il2CppPtr): int32 {.importc: "aowl_hook_attach", nodecl.}
proc cHookRemove(p: Il2CppPtr): int32 {.importc: "aowl_hook_remove", nodecl.}
proc cHookStolen(p: Il2CppPtr): int32 {.importc: "aowl_hook_stolen", nodecl.}
proc cHookCapacity(): int32 {.importc: "aowl_hook_capacity", nodecl.}

# The BattlEye service guard, armed in the C constructor before this file's
# `hostMain` exists as a running thread. `aowlspt_beguard.h` says why it cannot
# wait for the boot thread and why it patches an import table rather than a
# function. All this side does is read what it did, once there is a log.
proc cBecNeuter(): int32 {.importc: "aowl_beclient_neuter", nodecl.}
var cBecBaseFound {.importc: "aowl_bec_base_found", nodecl.}: int32
var cBecIsInstSeen {.importc: "aowl_bec_isinst_seen", nodecl.}: int32
var cBecRestartSeen {.importc: "aowl_bec_restart_seen", nodecl.}: int32
proc cBeArmed(): int32 {.importc: "aowl_be_guard_armed", nodecl.}
proc cBeModule(): int32 {.importc: "aowl_be_guard_module", nodecl.}
proc cBeAnswered(): int32 {.importc: "aowl_be_guard_answered", nodecl.}

# The two UX fixes. `aowl_uxpatch_exit_neuter` is a static .text byte patch that
# redirects EFT.TarkovApplication.ExitApplication to ExitProcess(0), so the menu
# Exit closes the game instead of hanging on the absent-launcher handshake.
# `aowl_uxpatch_version_target` hands back the verified PreloaderUI.Awake code
# pointer for the host to postfix-detour (the label rewrite is on the Unity
# thread). See `aowlspt_uxpatch.h`.
proc cUxExitNeuter(): int32 {.importc: "aowl_uxpatch_exit_neuter", nodecl.}
var cUxBaseFound {.importc: "aowl_ux_base_found", nodecl.}: int32
var cUxExitSeen {.importc: "aowl_ux_exit_seen", nodecl.}: int32
# Fix 1b: subclass the game's top window so an OS-driven close (X button,
# taskbar Close, Alt+F4) terminates cleanly instead of entering the same hanging
# async shutdown the Exit-button fix bypasses. See `aowlspt_uxpatch.h`.
proc cUxCloseHook(): int32 {.importc: "aowl_uxpatch_close_hook", nodecl.}
proc cUxCloseArm(rearmed: ptr int32): int32 {.
  importc: "aowl_uxpatch_close_arm", nodecl.}
proc cUxCloseHwnd(): uint64 {.importc: "aowl_uxpatch_close_hwnd", nodecl.}
proc cUxCloseTid(): uint64 {.importc: "aowl_uxpatch_close_tid", nodecl.}
proc cUxCloseCtrlArm(): int32 {.importc: "aowl_uxpatch_close_ctrl_arm", nodecl.}
var cUxCloseSeen {.importc: "aowl_ux_close_seen", nodecl.}: int32
# The OS-close fix is checked from the host tick loop, not armed once: the game
# window does not exist at il2cpp-init time, so a boot-only attempt installs
# nothing at all.
#
# It is NOT a WndProc subclass any more. Re-subclassing from this thread to
# survive the raid's window re-creation crashed the client -- swapping another
# thread's WndProc is unsupported and races its pump. The hooks are thread-scoped
# SetWindowsHookEx (WH_GETMESSAGE + WH_CALLWNDPROC) on the game's UI thread, so
# a re-created window on the same thread is covered with nothing re-armed and
# NOTHING WRITTEN per tick. See `aowlspt_uxpatch.h`.
#
# `osCloseFix` gates the whole thing so a bad interaction can be turned off
# without a rebuild. Default OFF while this is being re-proven live.
var gOsCloseFix = false
var gCloseEverArmed = false
var gCloseWarned = false
proc cUxVersionTarget(): Il2CppPtr {.
  importc: "aowl_uxpatch_version_target", nodecl.}
proc cUxVersionLabelOffset(): int32 {.
  importc: "aowl_uxpatch_version_label_offset", nodecl.}
proc cUxWritePtr(p: Il2CppPtr; off: int32; value: Il2CppPtr): int32 {.
  importc: "aowl_uxpatch_write_ptr", nodecl.}

# The Unity-main-thread bridge's statically-resolved per-frame targets. Each
# returns a verified code pointer into GameAssembly.dll or nil (wrong build,
# module not mapped, or prologue mismatch), so `bindMainDrain` can fall through
# to its by-name candidates. See `aowlspt_bridge.h`.
proc cBridgeTargetCount(): int32 {.importc: "aowl_bridge_target_count", nodecl.}
proc cBridgeTargetAt(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_target_at", nodecl.}
proc cBridgeTargetPerFrame(i: int32): int32 {.
  importc: "aowl_bridge_target_perframe", nodecl.}
proc cBridgeTargetName(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_target_name", nodecl.}
# The render-phase equivalents, for `bindRenderDrain`.
proc cBridgeRenderTargetCount(): int32 {.
  importc: "aowl_bridge_render_target_count", nodecl.}
proc cBridgeRenderTargetAt(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_render_target_at", nodecl.}
proc cBridgeRenderTargetName(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_render_target_name", nodecl.}
proc cBridgeSettingsTargetCount(): int32 {.
  importc: "aowl_bridge_settings_target_count", nodecl.}
proc cBridgeSettingsTargetAt(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_settings_target_at", nodecl.}
proc cBridgeSettingsTargetName(i: int32): Il2CppPtr {.
  importc: "aowl_bridge_settings_target_name", nodecl.}
# Probing a live MethodInfo for where (if anywhere) an executable code pointer
# sits on this build, when offset 0 (`methodPointer`) reads null.
proc cReadPtrAt(p: Il2CppPtr; off: int32): Il2CppPtr {.
  importc: "aowl_read_ptr", nodecl.}
proc cIsReadable(p: Il2CppPtr; size: int32): int32 {.
  importc: "aowl_is_readable", nodecl.}
# THE CACHED FORM. Same contract, same predicate, one VirtualQuery per 64KB
# chunk per TTL instead of one per call. Use it ONLY for reading game data in a
# per-frame path; anything that binds a detour, verifies a prologue or decides
# to write keeps `cIsReadable` above. See abi/aowlspt_rdcache.h.
proc cIsReadableC(p: Il2CppPtr; size: int32): int32 {.
  importc: "aowl_rdc_readable", nodecl.}
proc cRdcHits(): int64 {.importc: "aowl_rdc_hits", nodecl.}
proc cRdcMisses(): int64 {.importc: "aowl_rdc_misses", nodecl.}
proc cRdcUncacheable(): int64 {.importc: "aowl_rdc_uncacheable", nodecl.}
proc cRdcEvictLive(): int64 {.importc: "aowl_rdc_evict_live", nodecl.}
proc cRdcExpired(): int64 {.importc: "aowl_rdc_expired", nodecl.}
proc cRdcAudits(): int64 {.importc: "aowl_rdc_audits", nodecl.}
proc cRdcDisagree(): int64 {.importc: "aowl_rdc_disagree", nodecl.}
proc cRdcFlush() {.importc: "aowl_rdc_flush", nodecl.}
# THE ORIGINAL-PROLOGUE SNAPSHOT (`aowlspt_prologue.h`). `cProPrimeAll` is
# called once from `hostReady`, before the first detour is installed; the rest
# are diagnostics so the boot log can state the snapshot's health. `aowl_pro_
# verify` itself is called only from the C verifiers, so it is not bound here.
proc cProPrimeAll() {.importc: "aowl_pro_prime_all", nodecl.}
proc cProRowsUsed(): int32 {.importc: "aowl_pro_rows_used", nodecl.}
proc cProPrimedCount(): int32 {.importc: "aowl_pro_primed_count", nodecl.}
proc cProLazyCount(): int32 {.importc: "aowl_pro_lazy_count", nodecl.}
# The token-gate layer. `cGateSetEnabled` is the ONLY thing that arms it;
# with the flag off every `aowl_gate_call` returns AOWL_GATE_DISABLED and
# no gated export is called at all.
proc cGateBind(): int32 {.importc: "aowl_gate_bind_module", nodecl.}
proc cGateSnapshot() {.importc: "aowl_gate_snapshot", nodecl.}
proc cGateSetEnabled(on: int32) {.importc: "aowl_gate_set_enabled", nodecl.}
proc cGateIsGated(name: cstring): int32 {.importc: "aowl_gate_is_gated", nodecl.}
proc cGateWhy(w: int32): cstring {.importc: "aowl_gate_why", nodecl.}
# The live self-test. Its verdict is PASS / FAIL / INCONCLUSIVE -- never a
# boolean, because "the gate never armed" is not a pass.
proc cGtRun() {.importc: "aowl_gt_run", nodecl.}
proc cGtCaseCount(): int32 {.importc: "aowl_gt_case_count", nodecl.}
proc cGtVerdict(i: int32): int32 {.importc: "aowl_gt_verdict", nodecl.}
proc cGtPassCount(): int32 {.importc: "aowl_gt_pass_count", nodecl.}
proc cGtFailCount(): int32 {.importc: "aowl_gt_fail_count", nodecl.}
proc cGtInconcCount(): int32 {.importc: "aowl_gt_inconc_count", nodecl.}
proc cGtStaticArmed(): int32 {.importc: "aowl_gt_static_armed", nodecl.}
proc cGtNonceArmable(): int32 {.importc: "aowl_gt_nonce_armable", nodecl.}
proc cGtLeakedArms(): int32 {.importc: "aowl_gt_leaked_arms", nodecl.}
proc cGtRefused(): int32 {.importc: "aowl_gt_refused_count", nodecl.}
proc cGtPrologueBad(): int32 {.importc: "aowl_gt_prologue_bad_count", nodecl.}
proc cGtFaults(): int32 {.importc: "aowl_gt_fault_count", nodecl.}
proc cGtFirstRefusal(): cstring {.importc: "aowl_gt_first_refusal", nodecl.}
proc cGtLine(i: int32): cstring {.importc: "aowl_gt_line", nodecl.}
var gGatesOn = false
proc cProBadCount(): int32 {.importc: "aowl_pro_bad_count", nodecl.}
proc cProHave(rva: uint32): int32 {.importc: "aowl_pro_have", nodecl.}
proc cProCopy(rva: uint32; outp: Il2CppPtr; n: int32): int32 {.importc: "aowl_pro_copy", nodecl.}
## THE OVERFLOW REPORT. `aowl_pro_full` was incremented on every refused row and
## read by NOTHING, so a table that had run out of rows was invisible: the
## affected features' verifies failed closed and each of them reported the
## refusal as a prologue MISMATCH, i.e. as a claim about the game build. These
## exist so the boot log states the snapshot's capacity health outright.
proc cProCapacity(): int32 {.importc: "aowl_pro_capacity", nodecl.}
proc cProFullCount(): int32 {.importc: "aowl_pro_full_count", nodecl.}
proc cProHealthLine(): cstring {.importc: "aowl_pro_health_line", nodecl.}
## THE prologue verify, bound here because patch-by-RVA is its first caller on
## the Nim side. It compares against the STARTUP SNAPSHOT, never live memory --
## which is the whole reason a second feature can verify a function a first
## feature already detoured. `siglen <= 0` returns 1 WITHOUT comparing
## anything, so a caller must never report a match it did not ask for.
proc cProVerify(rva: uint32; sig: ptr uint8; siglen: int32): int32 {.
  importc: "aowl_pro_verify", nodecl.}
proc cRvaCodeAt(rva: uint32): Il2CppPtr {.importc: "aowl_rva_code_at", nodecl.}
proc cGaBase(): uint64 {.importc: "aowl_ga_base", nodecl.}
proc cRvaIsCode(rva: uint32): int32 {.importc: "aowl_rva_is_code", nodecl.}
proc cInIl2cpp(p: Il2CppPtr): int32 {.
  importc: "aowl_in_il2cpp_section", nodecl.}
proc cIl2cppRvaOf(p: Il2CppPtr): int64 {.
  importc: "aowl_il2cpp_rva_of", nodecl.}
## VEH+setjmp fault guard: calls `f(a)` with a vectored exception handler armed,
## and returns whatever `f` returned -- or NULL if `f` faulted with an access
## violation, the game surviving instead of dying. `f` therefore returns a
## non-nil sentinel on success so the caller can tell "faulted" from "returned
## nil". Used to probe which managed operation faults on this protected build
## without taking the client down. See `aowl_p_p_seh` in `aowlspt_shim.h`.
proc cSehCall(f, a: Il2CppPtr): Il2CppPtr {.importc: "aowl_p_p_seh", nodecl.}
## Runs one STEP of `settingsMetaProbe(a)` under the VEH guard (see the emit
## thunk near the includes). Returns the probe's non-nil sentinel on completion,
## or nil if that step faulted -- the game surviving either way.
proc cMetaProbeGuarded(a: Il2CppPtr; step: int32): Il2CppPtr {.
  importc: "aowl_settings_meta_probe_guarded", nodecl.}
proc cProbeStep(): int32 {.importc: "aowl_probe_step_get", nodecl.}
proc cReadI32At(p: Il2CppPtr): int32 {.importc: "aowl_read_i32", nodecl.}
proc cWordAt(p: Il2CppPtr; i: uint64): uint16 {.importc: "aowl_word_at", nodecl.}
## Runs `brandNewStringImpl` (which allocates the branded `System.String` via
## `il2cpp_string_new`) under the VEH guard, so even that runtime alloc cannot
## crash the client: nil on a fault, and the caller leaves the stock version.
proc cBrandNewStringGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_brand_newstring_guarded", nodecl.}
proc cBeOpened(): int32 {.importc: "aowl_be_guard_opened", nodecl.}

# The IL2CPP readiness flag, armed in the same constructor and set on the
# game's own thread when `il2cpp_init` returns. `aowlspt_il2cppready.h` has
# why this is watched rather than polled for.
proc cIl2Ready(): int32 {.importc: "aowl_il2_is_ready", nodecl.}
proc cIl2Armed(): int32 {.importc: "aowl_il2_guard_armed", nodecl.}
proc cIl2Seen(): int32 {.importc: "aowl_il2_guard_seen", nodecl.}
proc cIl2Rc(): int32 {.importc: "aowl_il2_guard_rc", nodecl.}
proc cIl2Calls(): int32 {.importc: "aowl_il2_guard_calls", nodecl.}
## How many slots the engine has live, and how many it has back on its free
## list. Both are read only by `aowlspt.host::table_stats`; they exist because
## "the slot was reclaimed" is otherwise unobservable from outside the engine,
## and a reclaim that silently did not happen is exactly the failure that ends
## a session twenty minutes in.
proc cHookUsed(): int32 {.importc: "aowl_hook_used", nodecl.}

proc cHookFreeCount(): int32 {.importc: "aowl_hook_free_count", nodecl.}
## Firings the engine dropped because the slot they belonged to had been
## released and re-claimed while they were in flight. Reported in
## `table_stats` because a race that is being caught and a race that is not
## happening are the same number from outside -- and this is the number.
proc cHookStaleFires(): int32 {.importc: "aowl_hook_stale_fires", nodecl.}
## Hands a slot back to the engine, after its hook has been removed and freed.
## Without this the pool was one-way: sixteen patches into a session -- which a
## player switching a mod off and on again reaches quickly -- every further
## `patch()` was refused with fifteen slots holding nothing.
proc cHookRelease(slot: int32) {.importc: "aowl_hook_release", nodecl.}
## Reserves the next free slot without installing anything, so this file can
## fill `gPatches[slot]` **before** the jump lands. The thunk can fire on the
## instruction after the install and it indexes `gPatches` by slot, so the row
## has to exist first -- which means the slot number has to.
proc cHookClaim(): int32 {.importc: "aowl_hook_claim", nodecl.}
proc cHookAttachAt(p, target: Il2CppPtr; slot: int32): int32 {.
  importc: "aowl_hook_attach_at", nodecl.}
## Arms a slot's postfix path. Called *before* `cHookAttach`, never after: the
## thunk reads this table on every firing and can fire the instant the jump
## lands, so a slot armed a moment late would spend its first firings behaving
## like a prefix -- which for a mod scaling a return value is a wrong number
## rather than a missing one.
proc cHookSetPostfix(slot: int32; on: int32) {.
  importc: "aowl_hook_set_postfix", nodecl.}
## The engine's own text for an install code. Kept there rather than mirrored
## here: the codes were split apart once already -- "could not be relocated"
## used to mean four different things -- and a copy of that table in this file
## would have gone on printing the old sentence for the new code.
proc cHookErrorText(rc: int32): Il2CppPtr {.
  importc: "aowl_hook_error_text", nodecl.}

const
  HostName = "aowlspt-host-il2cpp"
  HostVersion = "0.1.0"

  # `SideClient` and the shared status codes (`StatusOk`, `ErrBadArg`, and the
  # rest) come from `modhost`. Only the two this host answers on its own are
  # declared here.
  PatchSkipStatus = 1'i32
  ErrDisposed = -8'i32

# --------------------------------------------------------------- state

## What this host keeps *per mod* -- detour slots, GC handles, queued
## main-thread callbacks -- is below, keyed by the mod's index in
## `modhost.gMods`. The mod itself (`LoadedMod`, the table, the loader) is
## `host/common/modhost.nim`, shared with the backend.

type
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
    ## The method itself, kept so the firing path can decode the arguments
    ## against its declared signature without looking anything up.
    meth: Il2CppMethod
    ## Whether this patch asked for arguments. Decoding them builds a JSON
    ## array inside a method the game may call thousands of times a frame, so
    ## it is opt-in: a patch that only counts calls does not pay for it.
    wantArgs: bool
    ## Whether the patch may suppress the original. A patch that returns
    ## `PatchSkip` without having asked is a mistake, not an instruction.
    canSkip: bool
    ## Which mod installed it. Needed to take a mod's detours out when the mod
    ## goes: a detour whose handler lives in a freed library is a jump into
    ## unmapped memory the next time the game calls that method.
    ##
    ## -1 for the host's own drain hook, which no mod owns and no mod unload
    ## may remove.
    modIndex: int
    ## The host's own per-frame drain hook rather than a mod's patch. It goes
    ## through the same engine and occupies a real slot, because the engine
    ## hands slots out in order and this file indexes `gPatches` by slot -- a
    ## hook the host installed outside that table would shift every mod's slot
    ## by one and fire the wrong handler.
    isDrain: bool
    ## A postfix: the thunk calls the original and comes back, and the handler
    ## runs then, with what it returned. Mirrored into the engine's
    ## `aowl_post_table` before the hook is attached, because the thunk reads
    ## that table and can fire the instant the jump lands.
    isPostfix: bool
    ## A **typed** patch (ABI revision 4): the handler is given a borrowed view
    ## of the saved registers rather than a JSON description of them, and `cb`
    ## is an `AowlTypedPatchFn` rather than an `AowlPatchFn`. The two shapes take
    ## different numbers of parameters, so calling one through the other is a
    ## crash rather than a type error -- which is why this is a field the firing
    ## path branches on rather than something inferred.
    typed: bool
    ## The declared kind of each parameter and of the return, worked out **once**
    ## here rather than per firing. This is where the JSON path's cost actually
    ## goes: it asks the runtime what everything is on every call, and the answer
    ## cannot change between calls.
    kinds: seq[uint8]
    retKind: uint8
    ## `AOWL_FRAME_F_STATIC` for a static method, pre-computed for the same
    ## reason: it is a property of the signature, not of the firing.
    frameFlags: uint32

  Sub = object
    ## An event subscription. Client-side events are how one mod tells another
    ## something happened without either knowing the other exists.
    name: string
    cb: Il2CppPtr
    user: Il2CppPtr
    modIndex: int
    faults: int
      ## How many times THIS handler has faulted and been caught by
      ## `aowl_ev_invoke`. At `EvFaultLimit` the row is dropped: a handler that
      ## has been longjmp'd out of twice has left its own mod's state
      ## unknowable, and catching for ever would keep pretending otherwise.

  Pending = object
    ## A callback a mod asked to have run on the game's main thread, or after a
    ## delay. Held as raw pointers because nimony cannot hold a `proc` it did
    ## not declare; it goes back out through the C trampoline.
    cb: Il2CppPtr
    user: Il2CppPtr
    dueMs: uint64
    modIndex: int
    ## The host's own proof-of-thread entry rather than a mod's callback. It
    ## carries no function pointer: it is queued from the host thread and its
    ## only effect is that the drain records which thread ran it, which is the
    ## one fact this whole path exists to establish.
    selfTest: bool
    ## THE ONLY ENTRY THAT MAY RUN OFF THE DRAIN'S THREAD, and it is the host's
    ## own, never a mod's. Set exclusively by `enqueueHostSafe`; `invoke_main`
    ## and `schedule` cannot reach it. An entry with this set carries no mod
    ## function pointer and makes no managed call, so the thread it lands on
    ## does not change what it does -- which is the only reason it is allowed
    ## to land anywhere. See `abi/aowlspt_mqpolicy.h`.
    hostSafe: bool

proc deadPatch(): Patch =
  ## An empty row. Used for two things and they are the same thing: filling the
  ## gap when the engine hands back a slot above the end of this table, and
  ## clearing a row whose detour has been removed so that the slot can be
  ## claimed again. Every pointer in it is null, so a firing that somehow
  ## reaches it finds `live` false and returns.
  result = Patch(hook: cast[Il2CppPtr](0), cb: cast[Il2CppPtr](0),
                 user: cast[Il2CppPtr](0), target: "", targetC: @[0'u8],
                 live: false, meth: cast[Il2CppMethod](0), wantArgs: false,
                 canSkip: false, modIndex: -2, isDrain: false,
                 isPostfix: false, typed: false, kinds: @[], retKind: 0'u8,
                 frameFlags: 0'u32)

var gDir = ""
var gRt = Il2Cpp(handle: cast[Il2CppPtr](0), loaded: false, lastError: 0'i32,
                 missing: @[])
var gDomain: Il2CppPtr = cast[Il2CppPtr](0)
var gReady = false
var gPending: seq[Pending] = @[]

const MqQueueCap = 4096
  ## The most entries `gPending` may hold. It exists because deferring is now
  ## the answer when the drain is not firing: before 2026-09-02 the host's own
  ## thread emptied the queue whatever state the drain was in, so the queue
  ## could not grow without bound and no cap was needed. Now it can, so there is
  ## one, and `gMqRefused` counts what it cost rather than letting a refusal be
  ## invisible.
var gMqDeferred = 0
  ## How many times `runDue` refused an entry because the thread it was reached
  ## on is not the drain's and the entry is not host-safe, and put it back. In a
  ## healthy session this is 0 for the whole run; a number that climbs is the
  ## host declining to do the thing that used to crash the client, and it is
  ## reported rather than counted quietly.
var gMqRefused = 0
var gMqRefusedSaid = 0
  ## Callbacks refused for want of room, and how many of those the log has
  ## already reported. Two numbers because the tick loop reports on CHANGE: a
  ## line per refused callback at 60 fps would bury the first one.

## The drain's own snapshot buffer, reused frame after frame.
##
## `takeDue` used to build a fresh `seq` for what was due and a second one for
## what was not, and hand the second back to `gPending`. Two allocations and a
## free every frame a per-frame chain is armed -- which is every frame, since
## the whole point of `everyMain` is that something is always queued. Measured
## on the stand-in that was 1148 ns a frame; reusing this buffer and compacting
## `gPending` in place is 300, and the host's cumulative allocation count stops
## moving at all while a chain runs.
##
## Only the thread that won `aowl_mq_tid` ever touches it, which is what makes
## a shared buffer safe: `cMqEnter` lets exactly one thread past. The two paths
## that are *not* that thread -- `runPending` on the host's tick thread, and a
## drain re-entered from inside a callback -- take `drainDue`, which brings its
## own. `gDraining` is what tells the second case apart.
var gDue: seq[Pending] = @[]
var gDraining = false

## The render-phase queue and its own drain buffer, mirroring the update queue
## above. Separate storage so the two phases never share an entry; the same lock
## (`cMqLock`) guards both, as it guards every other table here. `invoke_render`
## fills this one, and the render-phase detour drains it during rendering.
var gRenderPending: seq[Pending] = @[]
var gRenderDue: seq[Pending] = @[]
var gRenderDraining = false

# --------------------------------------------------------- the frame bench
#
# What a mod pays per frame, measured on the thread that actually pays it.
#
# Everything else in this host that is timed is timed by `perfbench`, which
# links the fast path and the runtime into one binary and never loads the host
# at all. That is the right shape for the *call* costs and the wrong shape for
# these: the drain runs on whichever thread won `aowl_mq_tid`, inside a method
# the detour engine rewrote, with the host's own allocator and the host's own
# lock. A loop in another binary would be measuring a copy.
#
# So the bench runs *here*, from inside `mainDrain`, armed by a `call` target
# and read back through another. `gBenchIters` is the arm: non-zero means the
# next frame runs the loops instead of the drain, and `runFrameBench` clears it
# before it starts so that the `mainDrain` calls it makes do not recurse.
var gBenchIters = 0
var gBenchReport = ""
  ## Filled on the drain thread, read from a mod's thread through
  ## `aowlspt.host::frame_bench`. A plain string rather than anything guarded:
  ## it is written once by one thread and read after, and the worst a racing
  ## reader sees is the empty string it started with, which reads as "not
  ## ready" and is exactly right.
var gBenchRuns = 0
## THREAD-LOCAL, and this pragma is the whole fix for a measured heap
## corruption. MEASURED 2026-09-03 09:21:51 (WER dump
## `EscapeFromTarkov.exe.636.dmp`, cdb): the HOST's mimalloc hit
## `"corrupted thread-free list."` (vendor/mimalloc/src/page.c:205) inside
## `mi_malloc`, stack `mi_malloc <- three host frames <- sain!resolve_0 <-
## sain!resolveNow_0 <- sain!ready_0 <- sain!onUpdate_0 <- sain!modOnUpdate <-
## host tick`.
##
## It was NOT a cross-module free -- the ABI's "borrowed in, owned out" rule is
## honoured everywhere (`allocBuffer`/`takeBuffer` route through `gHost.alloc`/
## `gHost.free`, and `modapi_new`/`modapi_free`, `hostapi_new`/`hostapi_free`
## are each called from one side only). It was THIS variable.
##
## As a plain global it was assigned from ~40 sites across every mod-callable
## ABI entry point -- `hostResolve`, `hostCall`, `hostConfigGet/Set`,
## `hostDbGet/Patch`, `hostRouteRegister`, `hostHandlePointer`, `hostHandlePin`
## -- which run on the mod OPS thread, and also from `installPatch` and patch
## callbacks, which run on the UNITY MAIN THREAD. With no lock. Under ARC, an
## assignment to a global string FREES the previous buffer, so:
##
##   * a string allocated on the main thread was freed by an assignment on the
##     ops thread -- a cross-thread free into the page's thread-free list; and
##   * two threads assigning concurrently freed the SAME old buffer twice,
##     which is precisely what corrupts that list.
##
## `hostLastError` also handed out `toCString(gLastError)` -- a raw interior
## pointer into that global -- so a mod reading it raced a free on another
## thread as well.
##
## `{.threadvar.}` fixes all three at once: every allocation and every free of
## this string now happens on one thread, and the pointer `hostLastError`
## returns is thread-local, valid until the next host call ON THAT THREAD --
## which is exactly what `abi/aowlspt.nim`'s `lastError()` has always
## documented ("the host's text for the most recent failure on this thread")
## and what this global did not implement.
##
## `backend/aowlbackend.nim:1960` already declared its identically-named
## `gLastError` as a threadvar; this host and `Aowlspt.Sim` did not. The
## divergence, not the design, was the defect. No initialiser: threadvars are
## zero-initialised per thread, which for a string is a valid empty string, and
## an initialiser is not permitted here.
var gLastError {.threadvar.}: string
var gHandles: seq[Il2CppPtr] = @[]
var gHandleIsObject: seq[bool] = @[]
## For an object handle, the IL2CPP GC handle keeping it alive; zero for a type
## handle. Parallel to `gHandles` because a mod-facing handle is an index and
## the three must stay in step.
var gHandleGc: seq[uint32] = @[]

## WHO OWNS EACH HANDLE. A fourth array parallel to the three above, holding the
## mod index that took the slot, or `HandleHost` for one the host took for
## itself.
##
## This is the structural blocker for client-side hot reload, and it is the one
## hazard `dropModRegistrations` could not close. Everything else a mod leaves
## behind is a function pointer INTO its library -- a detour, a subscriber, a
## queued callback -- and the teardown drops all of those, so freeing the library
## is safe. A strong GC handle is the opposite shape: it points from us INTO the
## game, it does not become invalid when the library goes, and nothing crashes.
## It PINS a game object for the life of the process. Unload a mod sixteen times
## across a session and the collector is holding sixteen sets of corpses it may
## not move or free.
##
## `sain` does the right thing by hand -- its `onUnload` calls `releaseAll()` --
## and that keeps working and is now unnecessary, which is the point. Depending
## on every mod author remembering is not a contract, it is a hope, and the
## hazard is invisible until a raid is long enough to notice the memory.
##
## `HandleHost` is deliberately NOT `-1`-by-omission: `claimNewHandles` pads this
## array explicitly so it is always exactly `gHandles.len` long. An array that
## can be short is an array whose missing entries read as some mod's index.
const HandleHost = -1
var gHandleMod: seq[int] = @[]

## Released handle slots, waiting to be handed out again.
##
## The table used to be append-only: `handle_release` emptied a slot and
## nothing ever took it back, so a mod that resolved and released once a frame
## grew this by one entry a frame for the length of a raid. `fireHandler` hid
## the worst of it -- a patch argument's handles are usually at the top and the
## table is shrunk back -- which is why it went unnoticed: the leak is on the
## paths a *mod* drives, not the one the host drives.
##
## A queue rather than a stack, and the reason is the diagnostic rather than the
## memory. A handle number handed straight back out means a mod using a released
## handle gets somebody else's object instead of "handle 7 has already been
## released"; recycling oldest-first puts every other freed slot in between, so
## the sentence survives for as long as there is anything else to hand out. It
## is a delay and not a guarantee, and the guarantee -- a generation in the high
## bits of the handle -- would change every handle number a mod ever prints.
##
## `gHandleFreeHead` is where the queue starts; the seq in front of it is
## compacted rather than shifted, because a shift is a copy per release.
var gHandleFree: seq[int32] = @[]
var gHandleFreeHead = 0

var gPatches: seq[Patch] = @[]

## What the patch paths have cost, cumulatively, so that "allocation-free" is a
## measurement rather than a claim.
##
## `gPatchPayloadBytes` is every byte of JSON this host has built to describe a
## firing, and `gPatchHandlesTaken` every GC handle it has registered for one.
## Both are exactly the work the typed path removes, and both are readable from
## a mod through `call("aowlspt.host::patch_stats")` -- so a test can fire a
## typed hook twenty thousand times and assert that neither moved by one. The
## same test against the JSON hook moves them by twenty thousand.
##
## Counters rather than a flag, and cumulative rather than per-firing, because
## the interesting assertion is "this number did not change", which needs a
## number.
var gPatchPayloadBytes = 0'i64
var gPatchHandlesTaken = 0'i64
var gPatchFires = 0'i64
var gTypedFires = 0'i64
## Firings that arrived deeper than the frame pool and fell back to letting the
## original run. Reported because a non-zero value here means a mod is not being
## called, which is exactly the kind of silence that should be visible.
var gTypedTooDeep = 0'i64
var gSubs: seq[Sub] = @[]

## How deep the stack is inside a patch handler, and which handle indices that
## firing created. `handle_pointer` uses them to tell "the object a hook is
## looking at right now" from "a handle number a hook wrote down last frame".
##
## A count rather than a flag because a handler may itself call something the
## host has patched -- reentering `patchFired` -- and a flag would have the
## inner firing's return clear the outer one's scope.
var gPatchDepth = 0
var gPatchHandleMark = 0
var gPatchHandleTop = 0

proc reservePatchRows() =
  ## Every row the detour engine can ever hand out, present before the first
  ## one is used.
  ##
  ## This is what lets the firing path stay off the lock. `gPatches` used to be
  ## grown on demand -- `while gPatches.len <= claimed: add` -- and a `seq` that
  ## grows *moves*, so a patch installed from a mod's worker thread could
  ## reallocate the array while the game's thread was indexing it inside a
  ## patched method. Filling it to the engine's capacity once means the array
  ## never moves again: a row is only ever written, and `live` says whether the
  ## firing path should read it.
  ##
  ## Sixteen rows of nulls. The `while` loops at the two install sites are kept
  ## as they were -- they are now no-ops, and a capacity that grows one day
  ## should not depend on this having been called.
  let cap = int(cHookCapacity())
  while gPatches.len < cap:
    gPatches.add deadPatch()


## The slot the drain hook took, or -1 when nothing bound. Checked first in the
## firing path, so it must be a value no real slot can have.
var gDrainSlot = -1
## Which method it bound to, for the log and for `aowlspt.host::main_thread`.
var gDrainMethod = ""
## Whether the bound method runs **once** per frame.
##
## Three of the four candidates do; `UnityEngine.Time::get_deltaTime` is the
## last resort precisely because it does not -- it is called many times a frame
## by whatever the game is doing. A mod dividing the firing count by wall-clock
## time and calling the answer a frame rate is right for three of them and
## wrong for the fourth, and it has no way to tell which it got.
##
## So the host says. This is a fact about the method the host chose, and a mod
## guessing at it from a name list is a mod that has to be edited every time
## this list is.
var gDrainPerFrame = false
## The host's own thread, recorded at boot. NOTHING a mod queued through
## `invoke_main` ever runs here -- see `runPending` and `abi/aowlspt_mqpolicy.h`
## -- and the difference between this and the drain thread is the proof that the
## drain is somewhere else.
var gHostThreadId = 0'u32
## Whether the host has already written the "this is the main thread" line. The
## drain never logs -- it runs inside the game's update path -- so the host
## thread notices and reports it instead.
var gDrainProven = false
var gAlienReported = false
## The drain's liveness, watched from the tick loop. `gLastFire` is the fire
## count last seen and `gLastFireMs` when it last changed.
##
## `gLastFireMs` means "when the fire count last moved" only once the count has
## moved at all. Before the first firing it is the host's boot time, and reading
## it as a stall clock then is the bug of 2026-09-02: it made every boot report
## a stall at 2 s against a first firing that arrives at ~15 s. `cMqHealth`
## consults it only when `fires > 0`, which is why the state before that is
## `DrainNeverFired` and not `DrainStalled`.
var gLastFire = 0
var gLastFireMs = 0'u64
var gDrainStalled = false
## The last health the tick loop reported, so the report is on CHANGE. -1 is
## "nothing said yet", which no `AowlDrainHealth` value is.
var gLastHealth = -1

## `opsQuiesce`'s own view of the same counter, kept apart from `gLastFire`
## above on purpose. `gLastFire` is the stall detector's and is written from the
## tick loop; sharing it would make each reader's sample depend on whether the
## other had already run this tick, and the answer to "is the game running" would
## quietly become "did the other branch get here first".
var gQuietLastFire = -1
var gQuietRun = 0

## The last reload ledger printed, so the line is written on change and not per
## frame. Starts at a tuple no real reading can equal, so the FIRST reading is
## always printed -- an all-zero start would make "nothing has been attempted"
## silent, and a run with zero reloads must say so rather than look like a run
## whose log line was lost. Zero attempts is INCONCLUSIVE and has to be visible.
var gRlLast = (-1, -1, -1, -1, -1, -1)

## The render-phase drain's slot, method and proof, mirroring the update drain's
## fields above. `-1` until a render-phase target binds. Kept entirely separate
## from `gDrainSlot`: the two detours are two rows in the same engine slot table,
## and the firing path checks each by identity.
var gRenderDrainSlot = -1
var gRenderMethod = ""
var gRenderProven = false

## Experiment A: a read-only detour on `SettingsScreen::Show`, its slot and the
## host thread it must NOT run on. Default-off (`bridgeSettingsProbe`); when it
## fires it logs the thread so the coordinator can confirm a detour reaches the
## Unity thread on a user action -- the decisive test for native settings
## injection. `gSettingsProbe` is the opt-in.
var gSettingsSlot = -1
var gSettingsProbe = false
## The heavier probe work (managed box proof + field walk) runs once, not every
## time the user reopens settings.
var gSettingsProbeDone = false

## The version-label brand: a POSTFIX detour on `EFT.UI.PreloaderUI::Awake`, its
## slot, the opt-in flag, and a once-only guard. When armed and the detour fires
## on the Unity thread (Awake is a MonoBehaviour callback), the handler rewrites
## the bottom-left version label to "aowlspt <U+2014> <version>" after the
## original set it. Opt-in (`uxVersionBrand`) because it is the first managed
## write from a host detour; default-off keeps the shared host safe, and the
## static Exit fix ships on regardless.
var gVersionSlot = -1
var gVersionBrand = false
var gVersionWrite = false
var gVersionBranded = false

## READ-ONLY GameWorld bot/player census (kind=5 detour on
## `EFT.GameWorld::RegisterPlayer`): its slot, opt-in flag (`botDiag`), and a
## fire counter used to throttle the full-list enumerate. Declared here beside
## the other detour slots; the walk itself lives in `botdiag.nim` (included
## below), which reuses this file's guarded raw-read primitives. NEVER writes.
var gBotDiagSlot = -1
## THE TRUE DEPLOY SIGNAL (kind=20/21 read-only detours on the two UNIQUE
## `AfterGameStarted` subscribers, which run inside `EFT.GameWorld::OnGameStarted`
## -- that method cannot be hooked directly, see `abi/aowlspt_raidstart.h`).
## Declared here beside the other detour slots because `attachDrain`, the
## dispatch in `patchFired` and `raidphase.nim` all name them and the include
## comes later. Read-only: the handler sets one bool and one timestamp.
var gRpStartSlotA = -1
var gRpStartSlotB = -1
var gBotDiag = false
var gBotDiagFires = 0
## THE VANILLA RAID-LOAD TIMELINE (`loadperf.nim`, kind=27). One kind for
## ALL 33 rows, exactly as uihooks does with kind 26: which row a bind is
## for is parked in loadperf's own `gLpArming` around the call, because
## `attachDrain` knows the kind but not the row. Read-only postfix drains
## that touch NO game memory; flag `loadPerf`, default OFF. Declared here
## because `attachDrain` and the config reader both name it and the include
## comes later.
var gLpOn = false
## PLAYER ACTUATION (`pact.nim`): the slot of its ONE detour, a READ-ONLY
## capture on `EFT.GamePlayerOwner::LateUpdate` @0xB29130 (UNIQUE, owners=1)
## that records the `this` register and does nothing else. Declared here beside
## the other detour slots because `attachDrain` above must be able to assign it.
## Nothing else in this repo detours that RVA, so the double-detour trampoline
## hazard does not apply; if that ever changes, pact must ride the existing
## detour as a drain rather than bind a second one.
var gPactOwnerSlot = -1
## One-shot guard for the full-list census. The per-registration detour now does
## only minimal single-hop work; the whole-list walk (the expensive, most
## fault-prone read) runs exactly once, after the list has had a few
## registrations to stabilise, and never again.
var gBotDiagCensusDone = false
## OFFLINE SCAV-CAP LIFT (kind=6 detour on `EFT.BotSpawner::AddPlayer`): its slot,
## opt-in flag (`unlimitedBots`), and a one-shot guard so the field poke fires at
## most once per raid. Declared here beside the other detour slots; the single
## int32 field write itself lives in `botcap.nim` (included below), which reuses
## this file's guarded primitives + the VEH/SEH guard.
var gBotCapSlot = -1
var gBotCap = false
var gBotCapDone = false
## NATIVE TABS (kind=28 read-only postfix on `UnityEngine.UI.Toggle::Set`):
## its slot and opt-in flag. The body lives in `nativetabs.nim` (included
## below). `Set` and not `set_isOn`, because that one is an eleven-byte
## tail-jump thunk -- see the block comment in `abi/aowlspt_nativeui.h`.
var gNtToggleSlot = -1
## THE VALUE BINDING's two slots and its two firing procs. Declared here, above
## `patchFired`, for the same reason every other feature's are: `include` is
## textual, `patchFired` sits above the include point, and a rider whose proc is
## not visible there cannot be dispatched. Implemented in `settingsbind.nim`.
var gSbdSlotSlider = -1
var gSbdSlotSave = -1
proc sbdSliderSetFired(regs: Il2CppPtr)
proc sbdSaveFired()
var gNtFlagOn = false
## Declared HERE, not in `nativetabs.nim`: `modstab.nim`'s rider gate tests
## `gNtOn`, and modstab is included first. Procs forward-resolve across an
## include boundary; variables do not.
var gNtOn = false                ## `nativeTabs`, after the bind succeeded
var gNtOff = false               ## self-disabled after the fault ceiling
## THE CLOSE PAIR (kinds 30 and 31). A PREFIX on `SettingsScreen::Close`
## @0x1720B10 and a POSTFIX on `SettingsScreen::CloseAll` @0x17207A0 -- two
## detours on two DIFFERENT functions. Both MEASURED UNIQUE, and nothing else
## in this host patches either. "Close entered" without "CloseAll returned" is
## a throw or fault unwound through the close, which is the shape all three of
## 2026-09-02's deaths had and which nothing could see.
var gNtCloseSlot = -1
var gNtCloseAllSlot = -1
const KindMaxFeature = 35
  ## The highest `kind` that `attachDrain` treats as a FEATURE detour rather than
  ## as the main-thread update drain. Bump this when a new kind is added, and
  ## nothing else in `attachDrain` needs touching: the two places that used to
  ## enumerate every feature kind by hand now test `2 .. KindMaxFeature`. A kind
  ## added without updating both of those hand-written chains fell through to the
  ## drain branch and silently overwrote `gDrainMethod` with a feature's name.
## CATCH THE IN-GAME ERROR DIALOG (kind=20/21/22 read-only postfix detours on the
## three `EFT.UI.PreloaderUI` error-screen entry points): one slot per overload,
## the opt-in flag (`catchErrorDialogs`), a session count, the FIRST dialog's text
## (kept rather than the latest -- a cascade's first error is the cause and the
## rest are consequences), and the target identity the dispatcher sets just before
## it calls the shared guarded body, since the regs block carries no identity of
## its own. Declared here beside the other detour slots; the read-only bodies live
## in `errdlg.nim` (included below).
var gErrDlgMsgSlot = -1
var gErrDlgExcSlot = -1
var gErrDlgCritSlot = -1
var gErrDlg = false
var gErrDlgCount = 0
var gErrDlgFirst = ""
var gErrDlgCritical = false
var gErrDlgFiring = 0
## THE IN-GAME MOD LOADING SCREEN. No detour of its own -- it rides the existing
## per-frame drain and renders `aowlspt-modload.txt`, which `tools/modbuild.py
## --screen` rewrites as it compiles the mods folder. The NuElem handles live
## beside `modload.nim`'s include, because `NuElem` is not in scope up here.
var gModLoad = false
var gModLoadScreenPath = ""
var gModLoadText = ""
var gModLoadBuilt = false
var gModLoadDone = false
var gModLoadDonorWarned = false
var gModLoadWhy = ""   ## the last refusal reason printed, so each prints once
var gModLoadDeferMods = false
var gModsDirDeferred = ""
var gModLoadDeferredAt = 0'u64
var gModsReleased = false
var gModLoadPolledAt = 0'u64
var gModLoadReadyAt = 0'u64
## ---- THE RELEASE GATE (modload.nim). See `modLoadGateDrain` for the whole
## argument; these are its only state, and every one of them is a plain
## integer or string, so the gate costs one compare per frame when idle.
var gModLoadGateOn = false
  ## Is the release actually gated on the menu-show event? False means the old
  ## behaviour -- release the instant READY is on disk -- and something in the
  ## log SAYS SO, loudly, whenever it is false while `deferModLoad` is on.
var gModLoadGateHold = false
  ## FALSIFICATION SWITCH (`modLoadGateHold`, default OFF). When on, the show
  ## event is ignored and the gate can never open, so a run can demonstrate the
  ## gate HOLDING (READY present, mods NOT released) instead of only ever
  ## demonstrating it opening. A gate that has never been seen to hold has not
  ## been shown to be a gate at all -- CLAUDE.md 9b.
var gModLoadGateSaid = false
var gModLoadMenuShownAt = 0'u64
  ## When the tick FIRST OBSERVED `uihEpoch(UihSiteMenuShow)` go non-zero. This
  ## is the frame after the detour fired, not the detour's own instant -- said
  ## here rather than letting the log's number be read as exact.
var gModLoadPendingWhy = ""
  ## A release that was WANTED while the gate was shut. Non-empty means "the
  ## moment the gate opens, release, and say what asked for it".
var gModLoadPendingAt = 0'u64
var gModLoadReleaseApproved = false
  ## THE RELEASE IS APPROVED AND HAS NOT BEEN PERFORMED YET.
  ##
  ## The gate is evaluated on the UNITY MAIN THREAD (`modLoadTick` rides the
  ## `TarkovApplication::Update` drain), but the LOAD must not happen there.
  ## MEASURED 2026-09-02 13:18: a boot that released the deferred mods from
  ## the Unity thread at 0:00:44.4 and then ticked them from the ops thread
  ## died with 0xc0000409 FAST_FAIL_FATAL_APP_EXIT inside admin.dll's mimalloc
  ## (`heap->thread_id == 0 || heap->thread_id == tid`); the previous boot,
  ## which loaded the same mods on the ops thread, survived. So the Unity
  ## thread only ever sets this flag, and `modLoadReleaseDrain` -- called from
  ## the ops loop immediately before `modhost.tickMods` -- does the work, on
  ## the same thread that will tick them.
var gModLoadReleaseWhy = ""
  ## The reason the approved release carries, so the line the ops thread
  ## writes says what asked for it rather than merely that something did.
var gModLoadReleaseTid = 0'u32
  ## The thread that OPENED the gate (Unity). Printed beside the thread that
  ## performed the release, because the whole point of this split is that the
  ## two are different and the difference is what killed a boot.
var gModLoadReleaseDone = false
var gModLoadDonor: Il2CppPtr = nil
var gModLoadCanvasTr: Il2CppPtr = nil
  ## The canvas transform the loading step built under, kept so the teardown
  ## check has a root to sweep from AFTER every handle is gone.
var gModLoadStyled = false
  ## Did we match the game's own loading caption and lay out in its frame? The
  ## match is RETRIED on later frames because that caption is transient, so
  ## this can go true long after the text was built.
var gModLoadFailed = false
  ## The build reported FAILED. Changes the linger, not whether we dismiss.
var gModLoadTries = 0
var gModLoadParentTr: Il2CppPtr = nil
  ## The container we reparented the lines into, if we did. Remembered so the
  ## teardown sweep looks THERE too: a sweep rooted only where we originally
  ## built would report ZERO survivors simply by not looking, which is a pass
  ## that cannot fail.
var gModLoadSweepAt = 0'u64
  ## When the DEFERRED survivor sweep is due. `Object::Destroy` is deferred to
  ## the end of the frame, so sweeping in the same frame as the teardown finds
  ## every node still parented and reports a leak that is not one -- measured
  ## live on 2026-09-01 as "teardown FAILED: 3 node(s) STILL under the canvas".
var gModLoadSweeping = false
  ## The survivor sweep is RESUMABLE and runs one slice per frame while this is
  ## true. It replaced a single-frame budget that, measured live with the
  ## Settings screen open, could not finish and so could only ever report
  ## INCONCLUSIVE -- a check that cannot complete is not a check.
var gModLoadSweepFrontier: seq[Il2CppPtr] = @[]
var gModLoadSweepFound = 0
var gModLoadSweepNodes = 0
var gModLoadSweepSlices = 0
var gModLoadSweepDropped = 0
  ## Children discarded at the stack ceiling. Non-zero forces INCONCLUSIVE:
  ## an unvisited subtree cannot be reported as "nothing left there".
var gModLoadSweepWhy = ""
  ## Why we tore down, held across the sweep delay so the verdict can name it.
  ## Polls spent without reaching a finished state; the self-disable counter.
var gErrDlgRow: array[3, int] = [-1, -1, -1]
  ## kind-20/21/22 slot  ->  the TARGET-TABLE ROW it actually bound, recorded at
  ## bind time by `bindErrDlg`. The dispatcher looks the row up here instead of
  ## assuming `row == kind - 20`. That assumption holds today and would keep
  ## holding right up until somebody inserts a row in `aowl_ed_targets`, at which
  ## point the exception overload would be read with the string shape -- walking
  ## an object header as if it were a UTF-16 length. This is fact #187 in its
  ## most dangerous form, so the mapping is measured rather than assumed.
## BOT AI ACTIVATION RESCUE (kind=12 detour on `EFT.BotOwner::PreActivate`): its
## slot, opt-in flag (`botAiActivate`), a fire counter (how many bots reached
## PreActivate at all) and a poke counter (how many needed the gate released).
## Declared here beside the other detour slots; the single guarded byte write
## itself lives in `botai.nim` (included below), which reuses this file's guarded
## primitives + the VEH/SEH guard.
var gBotAiSlot = -1
var gBotAi = false
var gBotAiFires = 0
var gBotAiPokes = 0
## NATIVE BOT NAVIGATION API (kind=15 detour on `EFT.BotOwner::UpdateManual`):
## its slot, opt-in flag (`botNav`), a fire counter and a fault counter used to
## self-disable. UpdateManual runs once per live bot per frame on the Unity
## thread with RCX = the BotOwner, which makes ONE hook serve as both the live
## bot census and the per-bot nav-command service tick -- so this feature needs
## no enumeration, no GameWorld walk, and contends with no other detour.
## Declared here beside the other detour slots; the registry, the command apply
## and the direct call to `EFT.BotOwner::GoToPoint` live in `botnav.nim`
## (included below), which reuses this file's guarded primitives + SEH guard.
var gBotNavSlot = -1
var gBotNav = false
var gBotNavFires = 0
var gBotNavFaults = 0
var gBotNavOff = false
var gReportBotNav = ""
  ## The census as last put on the report path. Compared rather than assumed
  ## because the path is only rebuilt when something changed, and a census that
  ## has not changed is not news.
## Phase 1 native-settings probe (kind=4 detour on `SettingsScreen::Show`): its
## slot, opt-in flag (`settingsUiProbe`), and once-per-open guard. Declared here
## beside the other detour slots; the walk itself lives in `settingsui.nim`
## (included below), which reuses this file's guarded raw-read primitives.
var gSettingsUiSlot = -1
var gSettingsUiProbe = false
var gSettingsUiDone = false
## Phase 1.5 native-settings CONTROL probe (kind=7 POSTFIX detour on
## `SettingsScreen::EnsureTabInitialized`): its slot. Phase 1 showed the tabs'
## `_createdControls` lists do not exist yet at `Show`; they are built lazily by
## this method, so the walk that actually reads controls hangs off its POSTFIX.
## Shares the `settingsUiProbe` flag with the Phase-1 hook. The walk lives in
## `settingsui.nim` (included below) and NEVER writes.
var gSettingsTabSlot = -1
## Phase 1.7 native-settings CONTROL poll (kind=8 PREFIX tick on
## `GameSettingsTab::Update`): its slot. The Phase-1.6 hook on
## `SettingsTab::OnTabSelected` never fired -- that method has zero callers in
## this build -- so the probe stopped chasing the trigger and takes a
## Unity-thread heartbeat instead, re-reading each registered tab's control list
## on a throttle. Shares the `settingsUiProbe` flag. The poll lives in
## `settingsui.nim` and NEVER writes.
var gSettingsSelSlot = -1

## DIRECT-INVOCATION proof ladder (kind=8 POSTFIX detour on
## `SettingsScreen::EnsureTabInitialized`): its slot and opt-in flag
## (`managedInvokeProbe`). It shares that target with the Phase-1.5 control probe
## (kind=7), so the two are mutually exclusive -- this one arms first when its
## flag is set and the control probe then skips itself, because two detours on
## one function would have the second overwrite the first's trampoline. The
## ladder itself lives in `invoke2.nim` (included below) and calls managed
## methods DIRECTLY at their RVA, with no reflection anywhere.
var gMi2Slot = -1
var gMi2Probe = false

## THE IN-GAME DEBUG OVERLAY (kind=10 PREFIX detour on `EFT.UI.PreloaderUI::
## Update`): its slot and its two opt-in flags. `debugUi` is the F3 info panel,
## `debugEsp` the in-world AI markers; either one arms the detour, because both
## are drawn from the same per-frame Unity-thread body. Default OFF.
##
## `gDebugEspSlot` is a SECOND, read-only kind=11 detour whose only job is to
## cache the live `EFT.GameWorld` pointer from `RegisterPlayer`. It shares that
## target with botdiag (kind=5), so it is armed only when botdiag did not take
## it -- two detours on one function would have the second overwrite the first's
## trampoline. When botdiag owns the target it feeds the cache itself.
##
## The overlay itself lives in `debugui.nim` (included below), which reuses this
## file's guarded raw primitives, botdiag's GameWorld offsets and readers, and
## invoke2's verified managed-call thunks.
var gDebugUiSlot = -1
var gDebugEspSlot = -1
var gDebugUi = false
var gDebugEsp = false

## THE ESP PROVIDER ARBITRATION.
##
## There are TWO ESPs in this host and they draw the same contacts by two
## completely different routes: `natEsp` builds real uGUI boxes on a canvas it
## owns, and `debugEsp` publishes in-world markers that the D3D11 overlay
## rasterises in `Present`. With both flags on the player sees every contact
## twice, which is exactly what was reported live.
##
## `espProvider` is the SETTING, so this is a choice rather than a flag
## collision the user has to know about:
##
##   "native"   natEsp draws; the debugEsp MARKERS are suppressed
##   "overlay"  debugEsp draws; natEsp is not armed
##   "both"     the old behaviour, explicitly asked for
##   "auto"     (default) natEsp wins if it is armed, else debugEsp
##
## SUPPRESSION IS OF THE DRAWING ONLY. `debugEsp` also arms the read-only
## detour that CACHES the live GameWorld pointer, and the admin mod's F6 ESP,
## botdiag and raidphase all read that cache -- switching the flag itself off
## would silently break three other features. So the flag stays on, the detour
## stays armed, and only `gDuEspVisible` is held down.
var gEspProvider = "auto"
var gDuEspSuppressed = false
  ## Read by debugui.nim: when true the in-world markers are never made
  ## visible, whatever the toggle key or the layout file says.

## THE MENU'S BOTTOM-RIGHT GAME-MODE LABEL (stock: "PVE ZONE").
##
## The slot and the flag live HERE rather than in `modetext.nim`, because
## `attachDrain` and `patchReturned` are both defined ABOVE that file's include
## point and both need to name the slot. Procs resolve across the whole module
## regardless of order; module-level `var`s do not, which is exactly what the
## first build of this feature failed on. Everything else about the feature --
## the state machine, the guarded body and the bind -- is in `modetext.nim`.
##
## SHARES ITS DETOUR WITH `gDebugUiSlot` ABOVE. Both features want
## `EFT.UI.PreloaderUI::Update`, and two detours on one function have the second
## overwrite the first's trampoline -- so there is exactly ONE detour on it.
## Whichever feature arms first claims a slot; the other sets ITS slot global to
## the SAME number and rides on the one firing. `gDebugUiSlot == gModeTextSlot`
## is therefore the normal, correct state when both are enabled, and the two
## dispatch points in `patchFired`/`patchReturned` call every rider whose slot
## matches rather than picking one. Neither feature excludes the other any more.
var gModeTextSlot = -1
var gModeTextOn = false

## SKIP THE MODE SCREEN (`modeskip.nim`). Declared here for the same reason
## `gModeTextSlot` is: `attachDrain` and the two dispatch points all name
## them and all sit above the include point, and while procs resolve across
## the whole module regardless of order, module-level `var`s do not.
##
## These are two detours on two functions NOTHING ELSE IN THIS HOST TOUCHES
## (both unshared RVAs), so unlike the PreloaderUI::Update multiplex above
## there is no rider alias to take and no double-detour hazard.
var gModeSkipCtorSlot = -1
var gModeSkipShowSlot = -1
var gModeSkipOn = false
var gModeSkipWantId = ""

## FEATURE F2 -- the NO-FRAME skip, on
## `EFT.TarkovApplication::TryCreateInRaidCharacterSelection` @0x97BBF0. A
## THIRD detour for `modeskip.nim`, and the only one of the three that ever
## suppresses its original. Declared here for the same reason the two above
## are: `patchFired` and `attachDrain` are defined before `modeskip.nim` is
## included, and while procs resolve across the whole module, module-level
## `var`s do not.
##
## 0x97BBF0 is UNSHARED and nothing else in this host names it, so there is no
## double-detour hazard here either.
var gModeSkipTryCreateSlot = -1
var gModeSkipProbeOn = false      ## `modeSkipProbe`, READ ONLY, default OFF
var gModeSkipNativeOn = false     ## `uxSkipModeScreenNative`, default OFF

## THE LIVE INSPECTOR'S slot -- the THIRD rider on `EFT.UI.PreloaderUI::Update`,
## declared here for the same reason `gModeTextSlot` is: `attachDrain` and
## `patchFired` both need to name it and both are above the include point.
##
## It rides whichever of the two features above claimed the function, and
## claims it itself only when neither did. It NEVER re-verifies that function's
## prologue: by the time it arms, the other riders may have written a JUMP
## there, and a prologue check against a TRAMPOLINE fails -- which is the exact
## live trap currently self-rejecting `uxMenuModeText`. See `bindInspect`.
var gInspSlot = -1

## THE MODS TAB -- the FIFTH rider on `EFT.UI.PreloaderUI::Update`. Slot, flag
## and the published live-tab pointer all live here rather than in
## `modstab.nim`, because nimony forward-resolves procs across an `include`
## boundary but NOT variables, and `patchFired`, the flag block and
## `settingsui.nim` all sit above that include point.
var gModsSlot = -1
var gModsOn = false
var gModsNativeLifecycle = false
## The live `SettingsTab` the ShowScreen postfix last handed us, and its group
## name. The mods tab is built by WALKING UP from this -- never from an offset
## that can read null.
var gModsLastTabPtr: Il2CppPtr = nil
var gModsLastTabName = ""
## The POLLING version brand and the seasons-banner hider. Both live in
## `modstab.nim` and ride the same detour; both default OFF.
var gVerOn = false
## THE VERSION BRAND'S OWN PRELOADER ANCHOR, and it exists because the brand
## used to borrow `gInspPreloader` -- which is written ONLY by `inspectFired`,
## the LIVE INSPECTOR's rider. MEASURED in a real boot: the brand hunted from
## 14.797 s, the client reached the main menu, and it never once resolved --
## it logged "no live PreloaderUI anchor yet" throughout, because the
## inspector's rider had never written that global. A feature must not depend
## on another feature's flag to find its own target. RCX at
## `EFT.UI.PreloaderUI::Update` IS the live PreloaderUI in BOTH dispatch
## halves (the argument registers are saved on entry either way), so the brand
## captures it itself now, from the very rider call it already receives.
var gVerPreloader: Il2CppPtr = nil
## THE SINGLEPLAYER-REBRAND'S DURABLE ANCHOR into the DontDestroyOnLoad menu
## scene, and it exists because `gVerPreloader` DOES NOT LAND THERE. Measured
## live with the inspector: `gVerPreloader` (the `PreloaderUI::Awake` `this`,
## above) resolves through `GameObject::get_scene_Injected` to a game/environment
## scene enumerating 197-274 roots, NOT the 22-root DontDestroyOnLoad scene
## (handle -12) that actually holds "Menu UI" -> ... -> "Matchmaker Offline Raid
## Screen". The `PreloaderUI::Update` `this` DOES land in scene -12 -- it is the
## same object `gInspPreloader` captures -- but that global has exactly ONE
## writer, the live inspector's rider, so with liveInspector off (every beta
## user) `splFindScreen` had no correct anchor and reported "NOT found across
## 197 roots". Captured here UNCONDITIONALLY from the shared PreloaderUI::Update
## rider block (which modetext/debugui/inspector/region all drive), so the
## rebrand no longer depends on any other feature's flag being on.
var gSplUpdatePreloader: Il2CppPtr = nil
var gSeasonsOn = false
## THE BETA NOTICE IN THE SEASONS BANNER SLOT. A SEPARATE KEY from
## `uxHideSeasons` on purpose: a player may well want the KORD BREACH banner
## gone and no notice in its place, and overloading one key would take that
## choice away. Default OFF, and a brand new name, because a default in source
## is not a value -- a flag whose default was flipped in source was still
## `true` in a deployed config.json for two launch cycles.
var gBetaNoticeOn = false
## POSTFX folded into Graphics as a subtab. Default OFF, and it is the one
## feature in `modstab.nim` that drives the GAME's own panels rather than
## clones of them.
var gGfxOn = false

var gCodeGenProbeSlot = -1
  ## THE FOURTH RIDER on `EFT.UI.PreloaderUI::Update`, armed only by
  ## `codeGenAudit`. It exists to run the codeGen self-test ON THE UNITY MAIN
  ## THREAD, because that is the one variable in this investigation that was
  ## never controlled -- see `codeGenAuditSelfTest`.
## THE SHARED PER-FRAME REGION -- the LAST rider on `EFT.UI.PreloaderUI::
## Update` that will ever need to be added by hand. Every future per-frame
## draw or tick registers WITH it (`abi/aowlspt_region.h`) instead of editing
## this file for a slot of its own. Declared here for the same reason every
## slot above it is: `patchFired` names it and sits above `region.nim`'s
## include point. Flag `sharedRegion`, default OFF.
var gRegionSlot = -1
var gRegionOn = false
var gUnityPostProbeOn = false
  ## THE UNITY POST-PROCESSING SURVEY (`abi/aowlspt_unitypp.h`). Flag
  ## `unityPostProbe`, default OFF. Declared here for the same reason
  ## `gRegionOn` is: `region.nim` is included below this point and reads it.
  ##
  ## MEASURED OFFLINE, before any code was written: this build ships
  ## `Unity.Postprocessing.Runtime.dll` UNSTRIPPED -- 118 types in
  ## `UnityEngine.Rendering.PostProcessing`, including PostProcessLayer,
  ## PostProcessVolume, PostProcessProfile, ColorGrading, Bloom, Vignette,
  ## Grain, ChromaticAberration, AmbientOcclusion and the whole
  ## ParameterOverride family. So driving the game's OWN grading is possible
  ## in principle, and the D3D11 back-buffer-copy path in `aowlspt_graphics.h`
  ## can eventually be retired rather than merely wrapped.
  ##
  ## What is NOT possible offline is `ParameterOverride<T>.value`'s offset:
  ## `tools/fldoff.py` reports it GENERIC-NO-LAYOUT, because IL2CPP writes an
  ## all-zero fieldOffsets array for uninstantiated generic definitions and
  ## every `Il2CppGenericClass.cached_class` in the file is null. A guessed
  ## offset there does not fault -- it reads a plausible float, and a WRITE
  ## corrupts a live managed object. So this probe is READ-ONLY and dumps the
  ## raw bytes instead, to settle the offset from one run's log.
  ##
  ## GRADING PROVIDER: still D3D11. Nothing here suppresses it, and the survey
  ## says so in its own verdict line so the change cannot look bigger than it is.
var gRegionProjectorOn = false
  ## THE PROJECTOR SEAT in the shared region (`abi/aowlspt_regproj.h`). Flag
  ## `regionProjector`, default OFF, and it is a SEPARATE flag from
  ## `sharedRegion` on purpose: arming the region is a pure book-keeping change,
  ## whereas this one calls three il2cpp methods on the Unity thread every frame
  ## to sample the camera. With it off the seat stays empty, `aowl_region_project`
  ## keeps refusing with REFUSE_NOPROJ, and every consumer keeps its bearing-ring
  ## fallback -- so a broken projector degrades the display rather than blanking
  ## it. Declared here for the same reason `gRegionOn` is: `region.nim` is
  ## included below this point.

var gSplPreloaderSlot = -1
  ## THE SINGLEPLAYER-REBRAND / forceOfflinePractice rider on
  ## `EFT.UI.PreloaderUI::Update`. It carries NO feature handler -- its ONLY job
  ## is to make the shared per-frame block capture `gSplUpdatePreloader` (the
  ## live PreloaderUI `this`, which belongs to the DontDestroyOnLoad menu scene
  ## -12 where the offline-raid screen lives). Without it that capture only ran
  ## when some OTHER PreloaderUI rider (the live inspector, mode-text, mods,
  ## region, ...) happened to be on -- so with liveInspector OFF (the shipped
  ## beta) the durable anchor was never populated and splFindScreen enumerated no
  ## roots (fact #234, second bug). Aliases onto an existing slot if one is held,
  ## else attaches its own (kind 19); either way NO second detour.

var gInspSlot2 = -1
  ## The inspector's SECOND anchor: the main drain's slot, aliased so the
  ## instrument keeps ticking inside a raid where `PreloaderUI::Update` does
  ## not. -1 when the bridge never bound a main drain, in which case the
  ## inspector is menu-only and says so.

## Whether the fragile static-RVA drain path may be used at all. OFF by default:
## it bound a real-but-wrong function on the live client and crashed the game, so
## the by-name runtime path is the only one used unless `aowlspt-host.json` sets
## `bridgeStaticRva` to a non-zero value. Read once at boot.
var gAllowStaticBridge = false

## The master kill-switch: when `aowlspt-host.json` sets `bridgeDisableDrain`,
## NO drain of any kind is installed -- not by name, not by RVA. `invoke_main`
## and `invoke_render` then run/refuse on the host thread exactly as they did
## before any bridge existed, and the game runs entirely detour-free. This is the
## escape hatch for a build where even the by-name detour proves unsafe: a bridge
## that crashes the game is worse than no bridge, so one flag turns it all off.
var gDisableDrain = false

## Default-off diagnostic: when `aowlspt-host.json` sets `bridgeUiProbe`, the
## update-drain self-test also instantiates two Unity UI GameObjects on the Unity
## thread and parents one under the other -- the foundation capability for native
## settings-screen injection. Off by default so it never runs unless asked; when
## on it runs once, on the drain thread, and only after the managed-call proof
## has shown that thread is really Unity's.
var gUiProbe = false

## Default-off aggressive resolution: when `aowlspt-host.json` sets
## `bridgeDeepScan`, and offset 0 of a candidate's live `MethodInfo` reads null,
## the host scans the rest of the struct for an executable pointer INTO the
## il2cpp section and, if it finds one, hooks it. This is the decisive attempt at
## the one build where `methodPointer` is null: the code pointer may be stored at
## a different offset (`virtualMethodPointer`, an invoker) that hardening left
## populated. It can crash if the found pointer is a wrong-but-real function, so
## it is opt-in; the always-on diagnostic below logs the layout either way.
var gDeepScan = false
var gCodeGenResolve = false
  ## `codeGenResolve` in `aowlspt-host.json`. When `MethodInfo.methodPointer`
  ## reads null, resolve the compiled address from IL2CPP's own per-assembly
  ## `methodPointers` table instead of refusing. Default OFF -- see the caveat
  ## in `aowlspt_codegen.h`.
var gCodeGenAudit = false
  ## `codeGenAudit`. Read-only: whenever BOTH `methodPointer` and the
  ## codeGenModule walk produce an address for the same method, log whether they
  ## agree. Costs nothing, patches nothing, and is the only instrument that can
  ## settle on the LIVE client whether this build's table holds the pointer the
  ## game actually calls.
## How many live-MethodInfo layout dumps have been written. Capped so the first
## bind pass dumps every candidate (there are only a handful) and the five-second
## retry loop does not repeat them forever.
var gMethodInfoDumps = 0
const MethodInfoDumpCap = 8

# ------------------------------------------------------- logging, helpers
#
# `info`/`warn`/`fail`/`okLog`, the clock they stamp with, `readBytes` and
# `ownDirectory` all come from `modhost` now. One log file, one line format,
# one `openLog`, opened by `hostMain` with this host's banner.
#
# `modhost.readBytes` is a single `copyMem` where this file's copy walked the
# buffer through `aowl_byte_at` one byte at a time. That is how every string
# argument crosses the ABI on this side, patch arguments included, so the
# cheaper one is the one worth keeping.

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
  if idx < 0 or idx >= modhost.modCount():
    gLastError = "no such mod context"
    return ErrBadArg
  # Through `modhost.configRead`, which is where the backend and the simulator
  # now read it too. This host answered `ErrNotFound` for a `config.json` that
  # did not parse -- the same status as "no such setting" -- so a client mod
  # with a BOM'd or half-written config was told its settings were absent and
  # ran the raid on defaults. `ErrConfigParse` is the answer now, and the
  # message names the file and the fault rather than the key.
  var text = ""
  var cfgErr = ""
  let cfgSt = modhost.configRead(idx, text, cfgErr)
  if cfgSt != StatusOk:
    gLastError = cfgErr
    # The whole document comes back even unparsed -- see the backend's copy of
    # this for why. A mod must be able to tell "broken" from "absent", and the
    # bytes are half of how it does that.
    if cfgSt == ErrConfigParse and k.len == 0 and text.len > 0:
      var raw = text
      discard cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(raw)),
                       int32(raw.len))
    return cfgSt
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
  ## Persist one edit into the calling mod's own `config.json`.
  ##
  ## This answered `ErrUnsupported` unconditionally, which the settings bridge
  ## surfaced as "THIS HOST DOES NOT SUPPORT WRITING CONFIG" -- so no
  ## client-side mod setting could ever be changed from the F12 panel, no
  ## matter how correctly the panel and the schema behaved. Nothing about the
  ## client made writing impossible; the entry point was simply never
  ## implemented, and an honest-sounding refusal made it look deliberate.
  ##
  ## The work is `modhost.configWrite`, shared with the other hosts on purpose:
  ## the backend already had a merge, and its merge INSERTS a flat member for a
  ## dotted path it cannot find, which on a nested client config
  ## (`mods/sain/config.json`) writes a key the mod will never read while
  ## answering `Ok`. `configWrite` refuses that case by status instead.
  let idx = int(cast[uint](ctx))
  if idx < 0 or idx >= modhost.modCount():
    gLastError = "no such mod context"
    return ErrBadArg
  let k = readBytes(key, keyLen)
  let v = readBytes(val, valLen)
  var err = ""
  result = modhost.configWrite(idx, k, v, err)
  if result != StatusOk:
    gLastError = err
    # Said out loud, once per failed edit. A refused write that travels back
    # only as a status code is invisible to whoever is reading the host log
    # while a player reports "the setting does not stick".
    warn "config set " & k & " on " & modhost.modGuidOf(idx) &
         " did not persist: " & err

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
  result = modhost.elapsedMs()

proc freeHandleCount(): int = gHandleFree.len - gHandleFreeHead

# The handle table's internals -- `pushFreeHandle`, `takeHandleSlot`,
# `trimHandles`, `newHandle`, `handleTarget` -- assume the lock is already
# held, and the entry points below take it. Nothing here takes it twice on
# purpose; a critical section is re-entrant on the same thread, so a nesting
# that slips through is harmless rather than a hang, but the discipline is
# "lock at the door".

proc pushFreeHandle(idx: int) =
  ## A slot that has just been emptied. Compacted here rather than on the way
  ## out: a run that releases millions of handles would otherwise grow this
  ## queue by one entry per release even though it never holds more than a
  ## handful at a time.
  if gHandleFreeHead >= 64:
    var kept: seq[int32] = @[]
    for i in gHandleFreeHead ..< gHandleFree.len:
      kept.add gHandleFree[i]
    gHandleFree = kept
    gHandleFreeHead = 0
  gHandleFree.add int32(idx)

proc takeHandleSlot(): int =
  ## The oldest freed slot that is still empty, or -1 to append.
  ##
  ## Nothing is handed out while a patch handler is running. `fireHandler`
  ## reclaims everything between the marks it took on the way in, so a slot
  ## handed to the handler from inside that range would be freed underneath the
  ## mod that had just been given it. Appending there is free anyway: those
  ## handles are given back when the handler returns.
  result = -1
  if gPatchDepth > 0:
    return
  while gHandleFreeHead < gHandleFree.len:
    let i = int(gHandleFree[gHandleFreeHead])
    inc gHandleFreeHead
    # Stale entries: `fireHandler` shrinks the table, so a queued index may be
    # off the end of it, and a slot may have been refilled by the append path.
    if i >= 0 and i < gHandles.len and not gHandleIsObject[i] and
       gHandles[i] == nil and gHandleGc[i] == 0'u32:
      return i

proc trimHandles() =
  ## Drops empty slots off the end of the table.
  ##
  ## The free list keeps the table from growing when a slot is released and
  ## another is taken, but it cannot answer the other half: `describeResult`,
  ## `describeArgs` and `readField` in `invoke.nim` **append**, because they are
  ## handed the three sequences and not this file's bookkeeping. Every call that
  ## returns an object and every firing that describes one therefore extends the
  ## table by a slot that the free list can only fill later, and a run that does
  ## nothing but call and release grew it by one per call for the session.
  ##
  ## So the tail is trimmed instead, which costs a loop over trailing empties
  ## and leaves the table the size of the most handles held at once rather than
  ## the number ever taken. Only at depth zero: inside a patch handler the
  ## firing's own handles sit at the top and `fireHandler` is about to reclaim
  ## them by index.
  if gPatchDepth > 0:
    return
  var n = gHandles.len
  while n > 0 and not gHandleIsObject[n - 1] and gHandles[n - 1] == nil and
        gHandleGc[n - 1] == 0'u32:
    dec n
  if n < gHandles.len:
    shrink(gHandles, n)
    shrink(gHandleIsObject, n)
    shrink(gHandleGc, n)
    # The owner array is shrunk with them or it is no longer parallel, and a
    # stale tail here would hand a reused slot its predecessor's owner.
    if n < gHandleMod.len:
      shrink(gHandleMod, n)

proc claimNewHandles(mark: int; owner: int) =
  ## Tag every slot appended since `mark` as belonging to `owner`.
  ##
  ## `readField` and `describeResult` in `invoke.nim` **append** to the three
  ## sequences directly -- they are handed the sequences, not this file's
  ## bookkeeping -- so there is no single door to add an owner argument to.
  ## Rather than thread one through the invoke path (which would also touch the
  ## patch-firing sites, where handles are reclaimed by index on return and an
  ## owner is meaningless), the caller records `gHandles.len` first and calls
  ## this after: anything that appeared during a mod's call is that mod's.
  ##
  ## Called with the table lock ALREADY HELD. It does not take it: the appends
  ## it is describing happen under the same lock and a second acquisition here
  ## would either deadlock or, worse, open a window between the append and the
  ## tag in which the slot has no owner.
  ##
  ## Padding is unconditional and runs to `gHandles.len`, so this array is never
  ## shorter than the table it describes.
  while gHandleMod.len < mark and gHandleMod.len < gHandles.len:
    gHandleMod.add HandleHost
  while gHandleMod.len < gHandles.len:
    gHandleMod.add owner
  var i = mark
  while i < gHandles.len and i < gHandleMod.len:
    if i >= 0:
      gHandleMod[i] = owner
    inc i

proc releaseModHandles(index: int): int =
  ## Free every GC handle the mod at `index` still holds, and say how many.
  ##
  ## Called from `dropModRegistrations`, so: after the mod's own `on_unload` has
  ## had its chance to release them itself, and before `FreeLibrary`. A mod that
  ## released its own handles costs nothing here and returns zero, which is the
  ## number `sain` should produce and is worth logging for exactly that reason --
  ## a non-zero count from a mod that believes it cleans up is a bug report.
  ##
  ## The slot is emptied but NOT pushed onto the free queue. The mod is going
  ## away and its slot numbers are dead; re-issuing them to another mod while a
  ## late call from the departing one could still name them is a class of bug
  ## this unload path has already been bitten by once, and a handful of slots is
  ## not worth it. `trimHandles` still reclaims the tail.
  ##
  ## Under the caller's lock, for the same reason as `claimNewHandles`.
  result = 0
  var i = 0
  while i < gHandles.len and i < gHandleMod.len:
    if gHandleMod[i] == index:
      if gHandleIsObject[i] and gHandleGc[i] != 0'u32:
        gcHandleFree(gRt, gHandleGc[i])
        gHandleGc[i] = 0'u32
        result = result + 1
      gHandles[i] = cast[Il2CppPtr](0)
      gHandleIsObject[i] = false
      gHandleMod[i] = HandleHost
    inc i

proc newHandle(target: Il2CppPtr; isObject: bool; gc: uint32;
               owner: int = HandleHost): uint64 =
  ## One handle, into a reclaimed slot where there is one. The number a mod
  ## sees is the index plus one, exactly as it always was.
  ##
  ## The door for every *append*, and therefore the one that has to hold the
  ## lock: `resolve` on a mod's worker thread and a release on another are the
  ## pair that reallocates this table under a reader.
  tablesLock()
  let slot = takeHandleSlot()
  if slot >= 0:
    gHandles[slot] = target
    gHandleIsObject[slot] = isObject
    gHandleGc[slot] = gc
    while gHandleMod.len <= slot:
      gHandleMod.add HandleHost
    gHandleMod[slot] = owner
    result = uint64(slot + 1)
  else:
    gHandles.add target
    gHandleIsObject.add isObject
    gHandleGc.add gc
    # Pad first, then append, so a table that had grown behind this array's back
    # (the invoke.nim append paths) does not shift this handle's owner onto an
    # earlier slot.
    while gHandleMod.len < gHandles.len - 1:
      gHandleMod.add HandleHost
    gHandleMod.add owner
    result = uint64(gHandles.len)
  tablesUnlock()

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
  ##
  ## Under the lock, and a *copy* rather than a view, which is what makes the
  ## caller safe: `bindArgs` runs outside the lock and would otherwise be
  ## indexing a table another thread can reallocate underneath it.
  result = @[]
  tablesLock()
  for i in 0 ..< gHandles.len:
    result.add handleTarget(i)
  tablesUnlock()

proc hostHandleRelease(ctx: Il2CppPtr; handle: uint64) {.
    exportc: "aowlspt_nim_handle_release", cdecl.} =
  ## Called from whichever thread the mod is on, which is the whole reason this
  ## takes the lock: releasing a handle empties a slot and queues it, and a
  ## release racing a `resolve` on another thread is two writers on one table.
  tablesLock()
  let idx = int(handle) - 1
  if idx >= 0 and idx < gHandles.len:
    let wasHeld = gHandleIsObject[idx] or gHandles[idx] != nil
    if gHandleIsObject[idx] and gHandleGc[idx] != 0'u32:
      gcHandleFree(gRt, gHandleGc[idx])
      gHandleGc[idx] = 0'u32
    gHandles[idx] = cast[Il2CppPtr](0)
    gHandleIsObject[idx] = false
    if idx < gHandleMod.len:
      gHandleMod[idx] = HandleHost
    # The slot goes back on the queue, so the table stays the size of what is
    # actually held rather than the number of handles ever taken. Only when it
    # held something: releasing the same handle twice must not queue it twice,
    # which would hand the same slot out to two callers.
    if wasHeld:
      pushFreeHandle(idx)
      trimHandles()
  tablesUnlock()

proc hostHandlePointer(ctx: Il2CppPtr; handle: uint64;
                       outAddress: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_handle_pointer", cdecl.} =
  ## The address of the object a handle names, for a mod's own fast path.
  ##
  ## This is the whole of the bridge, and almost all of it is refusals -- which
  ## is the point. A handle is safe *because* the host asks the GC handle every
  ## time; an address is the thing that is not safe, and the only useful
  ## guarantee to add is that a bad one is never produced in the first place.
  ##
  ## So: the address is read afresh from the GC handle on every call (never
  ## cached -- the collector moves objects and a cache would be exactly the bug
  ## this exists to avoid), a type handle is refused rather than answered with a
  ## class pointer, a released or collected handle is refused, and a handle
  ## belonging to a patch firing that has already returned is refused. The last
  ## one is the one a mod will actually hit: `this` is reclaimed by `patchFired`
  ## when the handler returns, so asking afterwards answers `ErrDisposed`
  ## instead of the address the object used to be at.
  var zero = 0'u64
  copyMem(outAddress, cast[Il2CppPtr](addr zero), 8)
  if not gReady:
    gLastError = "the IL2CPP runtime is not up yet"
    return ErrUnsupported
  let idx = int(handle) - 1
  if idx < 0:
    gLastError = "no such handle: " & $int(handle)
    return ErrNotFound

  # Every fact about the table is taken in one go, under the lock, and the
  # refusals below are decided from the copies. Reading the table a field at a
  # time across six branches would be six chances for another thread to move it
  # -- and the answer this returns is an *address*, which is the one thing here
  # it is not acceptable to be wrong about.
  tablesLock()
  let tableLen = gHandles.len
  let inRange = idx < tableLen
  let isObject = inRange and gHandleIsObject[idx]
  let raw = (if inRange: gHandles[idx] else: cast[Il2CppPtr](0))
  let target = (if isObject: handleTarget(idx) else: cast[Il2CppPtr](0))
  let patchMark = gPatchHandleMark
  let patchTop = gPatchHandleTop
  tablesUnlock()
  # The refusal a mod will actually meet, and it comes first because it is the
  # only one whose right answer is a sentence rather than a code. A handle that
  # a patch firing took out and no longer holds is either off the end of the
  # table (the usual case -- the firing shrank it back) or an emptied slot; both
  # mean the same thing, and "no such handle" would send the reader looking for
  # a bug in their bookkeeping instead of at the lifetime.
  if idx >= patchMark and idx < patchTop and not isObject:
    gLastError = "handle " & $int(handle) &
                 " was a patch argument and its handler has returned; the " &
                 "host reclaimed it there. An address taken in a hook is good " &
                 "for the length of that hook -- read what you need inside it, " &
                 "or `pinHandle` the object if you must keep it."
    return ErrDisposed
  if not inRange:
    gLastError = "no such handle: " & $int(handle)
    return ErrNotFound
  if not isObject:
    # A slot holding a class pointer is a handle from `resolve`; an empty one is
    # a handle that has been released. Different mistakes, different sentences.
    if raw != nil:
      gLastError = "handle " & $int(handle) &
                   " names a type, not a live object; there is no instance " &
                   "address for it. A handle from `resolve` is for `call` and " &
                   "for naming a class, not for the fast path."
      return ErrBadArg
    gLastError = "handle " & $int(handle) & " has already been released"
    return ErrDisposed
  let p = target
  if p == nil:
    gLastError = "handle " & $int(handle) &
                 " refers to an object the game has collected or that has " &
                 "already been released"
    return ErrDisposed
  var v = uint64(cast[uint](p))
  copyMem(outAddress, cast[Il2CppPtr](addr v), 8)
  result = StatusOk

proc hostHandlePin(ctx: Il2CppPtr; handle: uint64;
                   outHandle: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_handle_pin", cdecl.} =
  ## A second handle over the same object, this one **pinned**.
  ##
  ## A pinned object does not move, so the address behind a pinned handle stays
  ## correct across frames -- which is the only way a mod can honestly keep one.
  ## It is a separate handle rather than a mode on the existing one because the
  ## lifetimes differ: the original may be a patch argument the host reclaims in
  ## a moment, and the pin is the mod's, released when the mod says so.
  ##
  ## The cost is real and it is why this is not the default. The collector must
  ## work around that address for as long as the pin lives, and a mod that pins
  ## per hook rather than per session would pin at frame rate. `handle_release`
  ## on the pinned handle is what ends it.
  var zero = 0'u64
  copyMem(outHandle, cast[Il2CppPtr](addr zero), 8)
  if not gReady:
    gLastError = "the IL2CPP runtime is not up yet"
    return ErrUnsupported
  let idx = int(handle) - 1
  # As in `handle_pointer`: one look at the table, and the branches decided
  # from the copies.
  tablesLock()
  let inRange = idx >= 0 and idx < gHandles.len
  let isObject = inRange and gHandleIsObject[idx]
  let p = (if isObject: handleTarget(idx) else: cast[Il2CppPtr](0))
  tablesUnlock()
  if not inRange:
    gLastError = "no such handle: " & $int(handle)
    return ErrNotFound
  if not isObject:
    gLastError = "handle " & $int(handle) & " names a type, not a live object"
    return ErrBadArg
  if p == nil:
    gLastError = "handle " & $int(handle) &
                 " refers to an object the game has collected"
    return ErrDisposed
  let gc = gcHandleNew(gRt, p, true)
  if gc == 0'u32:
    gLastError = "the runtime would not give a pinned handle for handle " &
                 $int(handle)
    return ErrGeneric
  # THE PINNED HANDLE, and the one that matters most for an unload: this is the
  # `hold` behind `sain`'s `bridge.attach`. Owned by the calling mod, so the
  # teardown can give it back even if the mod does not.
  var v = newHandle(cast[Il2CppPtr](0), true, gc, int(cast[uint](ctx)))
  copyMem(outHandle, cast[Il2CppPtr](addr v), 8)
  result = StatusOk

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
  # A TYPE handle: no GC handle behind it, so `releaseModHandles` frees nothing
  # for it. Owned anyway, so the slot is cleared with the rest of the mod's when
  # it goes -- a table where some of a departed mod's rows are cleared and others
  # are not is one nobody can audit.
  let h = newHandle(c, false, 0'u32, int(cast[uint](ctx)))
  # The out-parameter is a uint64*; write it as eight bytes.
  discard cOutCopy(cast[Il2CppPtr](0), cast[Il2CppPtr](0),
                   cast[Il2CppPtr](0), 0'i32)
  var tmp = h
  copyMem(outHandle, cast[Il2CppPtr](addr tmp), 8)
  result = StatusOk

## MOD-REGISTERED COMMAND-LINE ARGUMENTS. Included HERE, and not down with the
## other includes at 4900+, for one reason: `hostCall` below is the only door a
## mod has and it is defined at ~2820 -- far above every other include -- so the
## parser has to be in scope by then. It installs no detour, touches no game
## memory and reads the process command line exactly once.
include "cmdargs.nim"

## THE TWO GENERIC TRANSPORT VERBS -- `aowlspt.host::http` / `http_poll` and
## `aowlspt.host::play_wav`. Included HERE for exactly the reason `cmdargs.nim`
## above is: `hostCall` is the only door a mod has and it is defined at ~2830,
## far above the other includes, so anything it dispatches to must already be
## in scope. Like `cmdargs.nim` it installs no detour, resolves no il2cpp name
## and touches no game memory; the whole of its blocking work happens on its
## own worker threads, and its completions are emitted from the host's tick.
include "hostnet.nim"

proc mainThreadReport(): string =
  ## What `call("aowlspt.host::main_thread")` answers.
  ##
  ## A mod has to be able to ask, because the answer decides what it may do: a
  ## callback that touches a Unity object is correct when `bound` is true and a
  ## crash when it is false, and nothing else in the ABI tells those apart.
  ## `bound` is only true once the hook has actually fired -- a hook that is
  ## installed but has never been reached has proved nothing.
  let bound = gDrainSlot >= 0 and cMqFireCount() > 0
  result = "{\"bound\":" & (if bound: "true" else: "false") &
           ",\"method\":\"" & gDrainMethod & "\"" &
           ",\"mainThreadId\":" & $int(cMqThread()) &
           ",\"hostThreadId\":" & $int(gHostThreadId) &
           ",\"frames\":" & $int(cMqFireCount()) &
           ",\"perFrame\":" & (if gDrainPerFrame: "true" else: "false") &
           ",\"otherThreadFires\":" & $int(cMqAlienFires()) &
           ",\"stalled\":" & (if gDrainStalled: "true" else: "false") &
           # ADDITIVE, 2026-09-02. Existing readers (`mods/fov/fov.nim` reads
           # `bound`, `method`, `frames`, `mainThreadId`, `stalled`) are
           # untouched -- this is a JSON object, so a field a reader does not
           # know about costs it nothing and no version needed bumping.
           #
           # `health` is the field that says what `stalled` cannot: `stalled` is
           # a bool and therefore folds "bound but the game has not called it
           # yet" -- the ordinary first ~15 s of a boot -- into the same answer
           # as "the game stopped calling it". A mod deciding whether to wait or
           # to give up needs those apart. `queued` and `deferred` are the two
           # numbers a mod cannot see from its side at all: how much of its own
           # work is waiting, and how much the host has declined to run on the
           # wrong thread.
           ",\"health\":\"" &
             (if gDrainSlot < 0: "unbound"
              elif cMqFireCount() <= 0'i32: "never-fired"
              elif gDrainStalled: "stalled"
              else: "live") & "\"" &
           ",\"queued\":" & $int(cMqCount()) &
           ",\"deferred\":" & $gMqDeferred &
           ",\"refused\":" & $gMqRefused & "}"

proc renderThreadReport(): string =
  ## What `call("aowlspt.host::render_thread")` answers -- the render-phase
  ## drain's mirror of `main_thread`. A GL/ESP mod gates on `bound` here before
  ## it queues render work with `invoke_render`: true only once a render-phase
  ## target has bound *and* fired, so a mod never draws into a drain that has
  ## proved nothing. `renderThreadId` is the thread the render callback runs on;
  ## it equals `mainThreadId` on the built-in pipeline (update and render share
  ## Unity's main thread) and the mod does not need to care that it does.
  let bound = gRenderDrainSlot >= 0 and cRqFireCount() > 0
  result = "{\"bound\":" & (if bound: "true" else: "false") &
           ",\"method\":\"" & gRenderMethod & "\"" &
           ",\"renderThreadId\":" & $int(cRqThread()) &
           ",\"hostThreadId\":" & $int(gHostThreadId) &
           ",\"renderFrames\":" & $int(cRqFireCount()) & "}"

proc tableStatsReport(): string =
  ## Every table this host keeps, by size, in one reply.
  ##
  ## `patch_stats` answers what the patch paths have *cost*; this answers what
  ## the host is still *holding*. The two questions are different and only the
  ## second one finds a leak: a counter that grows is the point of a counter,
  ## whereas a table that grows with the number of cycles rather than with the
  ## number of live things is a bug wherever it is.
  ##
  ## Read by `hostharness --churn`, which samples it every few hundred cycles
  ## and fits a line through each figure. So every number here is a *size*, not
  ## an event count, and each one has a shape it is supposed to have:
  ##
  ##   `patches`   bounded by the slot pool; `patchesLive` is how many are armed
  ##   `hookUsed`  the engine's own live-slot count, which must agree
  ##   `handles`   grows with handles a mod holds and must come back down
  ##   `subs`, `pending`, `mods` -- `mods` is the one that grows by design, and
  ##   the reason is `modIndexOf`: a context pointer is an index, so a dead slot
  ##   is kept rather than compacted.
  ##
  ## `allocCount` is this binary's mimalloc block count -- cumulative, so
  ## nothing lowers it. It is here rather than in `aowlspt/fast` on the mod side
  ## because the allocator is per binary and the host's own is the one a mod
  ## cannot see.
  # Under the lock: this walks three tables that other threads write, and it is
  # asked for by a mod -- so it is exactly the reader that used to see a table
  # mid-move. It is also read by `hostharness --churn` between cycles, where a
  # count that was off by one would be reported as a slope.
  tablesLock()
  var patchesLive = 0
  for i in 0 ..< gPatches.len:
    if gPatches[i].live: inc patchesLive
  var handlesLive = 0
  for i in 0 ..< gHandles.len:
    if gHandleIsObject[i] or gHandles[i] != nil: inc handlesLive
  let handleCount = gHandles.len
  let patchCount = gPatches.len
  let subCount = gSubs.len
  let freeHandles = freeHandleCount()
  tablesUnlock()
  var modsLive = 0
  for i in 0 ..< modhost.modCount():
    if modhost.modIsLive(i): inc modsLive
  result = "{\"patches\":" & $patchCount &
           ",\"patchesLive\":" & $patchesLive &
           ",\"hookUsed\":" & $int(cHookUsed()) &
           ",\"hookFree\":" & $int(cHookFreeCount()) &
           ",\"hookCapacity\":" & $int(cHookCapacity()) &
           ",\"staleFires\":" & $int(cHookStaleFires()) &
           ",\"handles\":" & $handleCount &
           ",\"handlesLive\":" & $handlesLive &
           ",\"handlesFree\":" & $freeHandles &
           ",\"subs\":" & $subCount &
           ",\"pending\":" & $int(cMqCount()) &
           ",\"mods\":" & $modhost.modCount() &
           ",\"modsLive\":" & $modsLive &
           ",\"drainSlot\":" & $gDrainSlot &
           ",\"drainStalled\":" & (if gDrainStalled: "true" else: "false") &
           ",\"allocCount\":" & $allocationCount() &
           ",\"allocBytes\":" & $allocatedBytes() &
           ",\"allocLive\":" & $liveBytes() & "}"

proc obHexToU32(s: string; ok: var bool): uint32 =
  ## "0x55ba450", "55BA450" or a plain decimal -> uint32, by hand. The verb
  ## that uses this answers on any thread with no runtime, and a parse that
  ## throws is not an answer; a string it cannot read yields ok=false.
  ok = false
  var i = 0
  var hex = false
  if s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'):
    hex = true
    i = 2
  if i >= s.len: return 0'u32
  var v = 0'u64
  while i < s.len:
    let c = s[i]
    var d = -1
    if c >= '0' and c <= '9': d = ord(c) - ord('0')
    elif c >= 'a' and c <= 'f': d = ord(c) - ord('a') + 10
    elif c >= 'A' and c <= 'F': d = ord(c) - ord('A') + 10
    if d < 0 or (not hex and d >= 10): return 0'u32
    v = v * (if hex: 16'u64 else: 10'u64) + uint64(d)
    if v > 0xFFFFFFFF'u64: return 0'u32
    inc i
  ok = true
  result = uint32(v)

proc obHexU32(v: uint32): string =
  const digits = "0123456789abcdef"
  result = ""
  var started = false
  var shift = 28
  while shift >= 0:
    let nib = int((v shr uint32(shift)) and 0xF'u32)
    if nib != 0 or started or shift == 0:
      started = true
      result.add digits[nib]
    shift = shift - 4

proc obHexBytes(bs: openArray[uint8]; n: int): string =
  const digits = "0123456789abcdef"
  result = ""
  var i = 0
  while i < n and i < bs.len:
    result.add digits[int(bs[i] shr 4'u8)]
    result.add digits[int(bs[i] and 0x0F'u8)]
    inc i

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

  # One target that is not a game type: where `invoke_main` will actually run.
  # Answered before the runtime check, because the answer is meaningful -- "the
  # host thread, and no main thread was found" -- even with no runtime at all.
  # A dot in the type part keeps it clear of any real IL2CPP type, whose class
  # name never contains one.
  # What the two patch paths have cost. Here rather than in a log line because
  # the interesting assertion is a mod-side one -- fire a typed hook twenty
  # thousand times and check that `payloadBytes` and `handlesTaken` did not
  # move -- and a number a test can read is the only way to make
  # "allocation-free" a measurement instead of a promise.
  if spec == "aowlspt.host::patch_stats":
    var report = "{\"fires\":" & $gPatchFires &
                 ",\"typedFires\":" & $gTypedFires &
                 ",\"payloadBytes\":" & $gPatchPayloadBytes &
                 ",\"handlesTaken\":" & $gPatchHandlesTaken &
                 ",\"typedTooDeep\":" & $gTypedTooDeep &
                 ",\"frameDepth\":" & $int(cFrameDepthMax()) & "}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # Every table this host holds, by size. `patch_stats` above says what the
  # patch paths have cost; this says what is still held, which is the only one
  # of the two a leak shows up in.
  if spec == "aowlspt.host::table_stats":
    var report = tableStatsReport()
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # The per-frame path, timed on the thread that pays for it. Two targets and
  # not one: arming has to happen from here and the loops have to run over
  # there, so the caller arms, waits a frame or two, and asks again. A report
  # that is not ready yet says so rather than blocking a mod's thread on a
  # frame that may never come -- on a build where nothing bound, it will not.
  if spec == "aowlspt.host::frame_bench_arm":
    if gDrainSlot < 0:
      gLastError = "no per-frame method is bound, so there is no frame to " &
                   "measure; nothing drains the queue at all"
      return ErrUnsupported
    var iters = 20000
    if argText.len > 0:
      var v = 0
      var any = false
      for ci in 0 ..< argText.len:
        let ch = argText[ci]
        if ch >= '0' and ch <= '9':
          v = v * 10 + (ord(ch) - ord('0'))
          any = true
      if any and v > 0: iters = v
    # Capped, because the loops run *inside a frame* on the game's thread and
    # nothing about this target is privileged -- any mod can ask for it. At the
    # cap the frame it lands in is a few hundred milliseconds, which is a
    # visible hitch and not a hang; a mod that asks for a billion gets the cap
    # rather than a frozen client.
    if iters > 200000: iters = 200000
    gBenchReport = ""
    gBenchIters = iters
    var armed = "{\"armed\":true,\"iters\":" & $iters & "}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(armed)),
                    int32(armed.len))

  if spec == "aowlspt.host::frame_bench":
    var report = gBenchReport
    if report.len == 0:
      report = "{\"ready\":false,\"runs\":" & $gBenchRuns & "}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  if spec == "aowlspt.host::main_thread":
    var report = mainThreadReport()
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # The graphics mod pushes its grade here. The args are a compact JSON object
  # of post-process params; the host forwards them, verbatim, to the native
  # post-process module. Answered without the runtime because the renderer lives
  # entirely in D3D11 and has nothing to do with IL2CPP being up.
  if spec == "aowlspt.host::gfx_apply":
    graphicsApplyJson(argText)
    var ack = "{\"ok\":true,\"running\":" &
              (if graphicsRunning(): "true" else: "false") &
              ",\"frames\":" & $int(graphicsFrames()) & "}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(ack)),
                    int32(ack.len))

  if spec == "aowlspt.host::render_thread":
    var report = renderThreadReport()
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # ---- the four GENERIC services a mod needs before it can do anything -----
  #
  # All four are answered WITHOUT the runtime, above the `gReady` gate, and all
  # four are safe from any thread: each builds its answer out of scalars and
  # COPIES of host-owned strings, allocating the reply on the CALLING thread
  # and freeing nothing this side owns. None of them touches game memory.
  #
  # `cmdline` -- the whole parsed `-aowl.*` table plus the raw line. The table
  # is immutable after `caParseOnce` ran in `hostMain`, so this is a read of
  # frozen state, not a snapshot of a moving one.
  if spec == "aowlspt.host::cmdline":
    var report = caCmdlineJson()
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # `args_declare` -- the AUDIT. It does not gate reading; it is what lets the
  # boot log say which arguments this build understands and which were given,
  # and it is what makes an undeclared `-aowl.*` token a WARNING instead of
  # silence.
  if spec == "aowlspt.host::args_declare":
    var report = caDeclareJson(argText)
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # `ui_show_status` -- per-site state for the `ui.show` event bus, so a mod
  # that loaded after a screen was shown can ASK rather than wait forever for
  # an event that already happened.
  if spec == "aowlspt.host::ui_show_status":
    var report = uihShowStatusJson()
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # `raid_phase` -- raidphase.nim's verdict, verbatim. Generic: nothing about
  # it is autoraid's. UNKNOWN is a REFUSAL ("I could not look"), never "not in
  # a raid", and `why` carries the reason; a consumer that flattens the two has
  # written a check that cannot fail.
  if spec == "aowlspt.host::raid_phase":
    var report = "{\"phase\":\"" & rpPhaseName(rpPhase()) & "\"" &
                 ",\"gameWorld\":" & (if rpGameWorld(): "true" else: "false") &
                 ",\"deployed\":" & (if rpDeployed(): "true" else: "false") &
                 ",\"why\":\"" & caEsc(rpWhy()) & "\"}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # `original_bytes` -- the host's STARTUP snapshot of a function's first
  # bytes, so a mod's own verifier (`aowlspt/callrva`) can byte-verify a call
  # target the host has ALREADY detoured. MEASURED 2026-09-05: mods/autoraid
  # refused `Toggle::Set`, `SettingsScreen::Close` and `MenuScreen::ShowInRaid`
  # as "the first bytes are a JUMP" because the host hooks all three, and the
  # raid entry stopped at SIDE. The live bytes there ARE our trampoline's JMP;
  # the truth is the prologue table, primed before any detour. FIND only: an
  # RVA that was never primed answers have=false and the mod keeps its
  # refusal -- this never captures, because a capture now could record a
  # trampoline. Generic (nothing here is any one mod's), answered without the
  # runtime, touches no game memory.
  if spec == "aowlspt.host::original_bytes":
    let rvaText = caJsonStr(argText, "rva", 0, argText.len)
    var okRva = false
    let rva = obHexToU32(rvaText, okRva)
    var report = ""
    if not okRva:
      report = "{\"have\":false,\"why\":\"the args carry no parseable rva " &
               "(want {rva: 0x<hex>} as a JSON string); got: " &
               caEsc(rvaText) & "\"}"
    else:
      var buf = [0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8,
                 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8]
      let n = cProCopy(rva, cast[Il2CppPtr](addr buf[0]), 16'i32)
      if n <= 0'i32:
        report = "{\"rva\":\"0x" & obHexU32(rva) & "\",\"have\":false," &
                 "\"why\":\"no startup-snapshot row for this RVA: the host " &
                 "never primed or patched it, so it holds no authoritative " &
                 "original bytes (" & $cProRowsUsed() & " row(s) primed)\"}"
      else:
        report = "{\"rva\":\"0x" & obHexU32(rva) & "\",\"have\":true," &
                 "\"len\":" & $n & ",\"bytes\":\"" & obHexBytes(buf, int(n)) &
                 "\",\"source\":\"startup-snapshot\"}"
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # `http` / `http_poll` -- the host's ONLY outbound HTTP client, and the only
  # way a client-side mod can reach the backend at all (MEASURED 2026-09-06:
  # before this there was none). Generic: no route, no schema, no mod named
  # here. Answered without the runtime, touches no game memory, and returns
  # IMMEDIATELY on whatever thread called -- the request itself runs on a
  # worker thread and its completion is emitted from the host's own tick loop,
  # never from that worker. See the banner in `hostnet.nim` for why that split
  # is not optional.
  if spec == "aowlspt.host::http":
    var report = ""
    if argText.len == 0:
      report = hnStatusJson()      # no args = "what is the state of this?"
    else:
      report = hnHttpVerb(argText)
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  if spec == "aowlspt.host::http_poll":
    var report = hnHttpPollVerb(argText)
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

  # `play_wav` -- fire-and-forget, NON-SPATIAL winmm playback of a PCM .wav
  # under an allowlisted root. `volume` is accepted and IGNORED, and the answer
  # says so rather than leaving it to be discovered. Spatial playback needs a
  # Unity AudioSource driven at byte-verified RVAs; that is a separate step and
  # `docs/VOICE_RVA.md` is where its groundwork lives.
  if spec == "aowlspt.host::play_wav":
    var report = hnPlayWavVerb(argText)
    return cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(report)),
                    int32(report.len))

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
    # A handle is either a type (from `resolve`) or a live object (from a call
    # that returned one). Both are reachable, and which one it is decides
    # whether the invoke gets an instance. Both facts are taken together under
    # the lock, because this runs on whatever thread the mod called from.
    tablesLock()
    let known = idx > 0 and idx <= gHandles.len
    let h = (if known: handleTarget(idx - 1) else: cast[Il2CppPtr](0))
    let objectHandle = known and gHandleIsObject[idx - 1]
    tablesUnlock()
    if not known:
      gLastError = "no such handle: " & typePart
      return ErrNotFound
    if objectHandle:
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
      # `readField` may register a handle for a reference field, so it appends
      # to the table and has to do it under the lock.
      tablesLock()
      # The mark is taken INSIDE the lock and next to the append it describes.
      # Read outside it, another thread's append lands between the two and this
      # mod is credited with a handle that is not its.
      let markF = gHandles.len
      let text = readField(gRt, cls, instance, fieldName, gHandles,
                           gHandleIsObject, gHandleGc, fieldError)
      claimNewHandles(markF, int(cast[uint](ctx)))
      tablesUnlock()
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

  # And the same for the return: a method that returns an object costs a handle.
  tablesLock()
  let markR = gHandles.len
  let text = describeResult(gRt, m, res, gHandles, gHandleIsObject, gHandleGc)
  claimNewHandles(markR, int(cast[uint](ctx)))
  tablesUnlock()
  if text.len == 0:
    return StatusOk
  var t = text
  result = cOutCopy(outPtr, outLen, cast[Il2CppPtr](toCString(t)),
                    int32(t.len))

proc modGuarded(index: int): bool =
  ## Whether `index` names a row the unload counter can speak about at all.
  ##
  ## A context pointer *is* a mod index for a mod, and `loadMod` refuses past
  ## `ModSlotLimit`, so every real mod is in range. But not every registration
  ## in this host's tables comes from a mod: `hostharness` subscribes under
  ## `0x7FFF` on purpose -- a number no mod table reaches, so that its own
  ## subscriptions survive the mod churn it is there to measure -- and the
  ## overlay and the host itself register under indices of their own.
  ##
  ## `modEnter` answers `false` for those, because its bounds check and its
  ## draining check share one return value. Taken at face value that turns
  ## "there is no library here to protect" into "skip this subscriber", which
  ## is how the churn gate lost the reply to `aowlspt.host.mods.list`. So the
  ## two cases are separated here: out of range means *not a mod*, and a
  ## non-mod is delivered to without a reference because there is nothing that
  ## could be unloaded out from under it.
  ##
  ## A constant rather than `modCount()` deliberately. The count moves on the
  ## tick thread, and an index that tested in-range on the way in and out-of-
  ## range on the way out would drop a `modLeave` and wedge that mod's unload
  ## for good. `ModSlotLimit` cannot change, so the two ends always agree.
  result = index >= 0 and index < modhost.ModSlotLimit

## ---------------------------------------------------------------------------
## A MOD'S EVENT HANDLER FAULTING MUST NOT KILL THE CLIENT
## ---------------------------------------------------------------------------
##
## MEASURED, not inferred: Unity crash report `Crash_2026-09-02_030042716`,
## stack section only -- sain.dll `toJson <- schemaJson <- onPageQuery <-
## eventTrampoline`, under `aowlspt-host-il2cpp` frames and
## `KERNEL32!BaseThreadInitThunk`. That is the HOST'S OWN TICK THREAD inside an
## `aowlspt.settings.pageQuery` broadcast. The handler faulted and the process
## died, because this loop called it through the bare `aowl_invoke_callback`
## trampoline with no guard anywhere above it.
##
## The rationale for the guard, the nesting rule and the self-test live in
## `abi/aowlspt_evguard.h`; only the bookkeeping is here.
proc cEvInvoke(cb, user, payload: Il2CppPtr; len: int32;
               statusOut: Il2CppPtr): int32 {.
  importc: "aowl_ev_invoke", nodecl.}
proc cEvSelfTestCb(): Il2CppPtr {.importc: "aowl_ev_selftest_cb", nodecl.}
proc cEvInGuard(): int32 {.importc: "aowl_ev_in_guard", nodecl.}

const
  EvOk = 0'i32
  EvFaulted = 1'i32
  EvNested = 2'i32
  EvRefused = 3'i32
  EvFaultLimit = 2
    ## N. The first fault is caught and the handler kept -- a one-off bad
    ## payload is a real thing. The second says the handler is broken, not the
    ## input, and it is dropped: `aowl_p_p_seh` recovers by `longjmp`, so every
    ## catch abandons that mod's frames where they stood.

proc subscriberName(index: int): string =
  ## Who to name in the log. A subscription's index is a mod index for a mod and
  ## a sentinel for everything else (`hostharness` uses 0x7FFF, the self-test
  ## below uses its own), so a name that came back empty is reported as what it
  ## is rather than printed as a blank.
  if index < 0 or index >= modhost.ModSlotLimit:
    return "<host, index " & $index & ">"
  let nm = modhost.modNameOf(index)
  if nm.len > 0:
    return nm
  let g = modhost.modGuidOf(index)
  if g.len > 0:
    return g
  result = "<unnamed mod, index " & $index & ">"

proc noteEventFault(n: string; cb, user: Il2CppPtr; owner: int) =
  ## Count this handler's fault and, at `EvFaultLimit`, unsubscribe it.
  ##
  ## The row is found by (name, cb, user, owner) rather than by an index into
  ## the snapshot, because the snapshot was taken without the lock held for the
  ## duration of the call and `gSubs` may have moved underneath it. A row that
  ## is no longer there -- the mod unloaded mid-delivery -- is not an error:
  ## the fault is still reported, and the unsubscribe it would have done has
  ## already happened.
  var count = 0
  var dropped = false
  var found = false
  tablesLock()
  var kept: seq[Sub] = @[]
  for s in gSubs:
    if not found and s.name == n and s.cb == cb and s.user == user and
       s.modIndex == owner:
      found = true
      count = s.faults + 1
      if count >= EvFaultLimit:
        dropped = true
        continue
      var updated = s
      updated.faults = count
      kept.add updated
      continue
    kept.add s
  if found:
    gSubs = kept
  tablesUnlock()
  let who = subscriberName(owner)
  if not found:
    warn "mod event: " & who & " handler for " & n & " FAULTED (caught), and " &
         "its subscription was already gone from the table -- it unloaded " &
         "mid-delivery. Nothing to unsubscribe."
    return
  if dropped:
    warn "mod event: " & who & " handler for " & n & " FAULTED (" & $count &
         " of " & $EvFaultLimit & ") -- caught, unsubscribed"
  else:
    warn "mod event: " & who & " handler for " & n & " FAULTED (" & $count &
         " of " & $EvFaultLimit & ") -- caught, kept"

proc deliverEvent(n, body: string; fromIndex: int): int =
  ## One event to every subscriber but `fromIndex`. Factored out because the
  ## **host** emits as well now: the mod-control replies come from here and
  ## pass `-1`, which is not a mod index, so nobody is skipped.
  ## The matching subscribers are taken out under the lock and called outside
  ## it -- the same shape `drainDue` uses, and for the same reason: a subscriber
  ## is a mod's code, it may take as long as it likes and may subscribe again
  ## from inside itself, and holding the host's one lock across it would block
  ## every other thread behind whatever it does. Delivering from a snapshot also
  ## means a mod unloaded mid-delivery cannot shorten the list underneath this
  ## loop.
  ##
  ## The snapshot is exactly what makes a reference necessary. Not shortening
  ## the list is only half the problem: the other half is that these `cb`
  ## pointers point *into the subscriber's library*, and the list they came from
  ## is no longer the thing that keeps that library mapped. `dropModRegistrations`
  ## empties `gSubs` and then `FreeLibrary` runs, and this loop is still holding
  ## the copy. An emit reaches here on the game thread inside a patch while the
  ## host's tick thread is in `modcontrol.drain`, so the two genuinely overlap.
  ## `modhost.modEnter` is the count that unload can see; the ordering that makes
  ## the pair correct is written down where they are.
  ##
  ## A subscriber that is draining is skipped rather than refused loudly -- an
  ## event is a broadcast, and a mod on its way out is exactly a mod that no
  ## longer wants to hear anything. That is the backend's rule for the same loop.
  result = 0
  var cbs: seq[Il2CppPtr] = @[]
  var users: seq[Il2CppPtr] = @[]
  var owners: seq[int] = @[]
  tablesLock()
  for i in 0 ..< gSubs.len:
    if gSubs[i].name != n or gSubs[i].modIndex == fromIndex:
      continue
    cbs.add gSubs[i].cb
    users.add gSubs[i].user
    owners.add gSubs[i].modIndex
  tablesUnlock()
  for i in 0 ..< cbs.len:
    let guard = modGuarded(owners[i])
    if guard and not modhost.modEnter(owners[i]):
      continue
    var b = body
    var st = 0'i32
    # ONE `aowl_p_p_seh` per handler, opened inside `aowl_ev_invoke` and
    # nowhere else on this path -- `deliverEvent` itself opens none, and the
    # C side declines to open one when this thread is already guarded rather
    # than nesting (which would DISARM the outer). Three outcomes.
    let verdict = cEvInvoke(cbs[i], users[i],
                            cast[Il2CppPtr](toCString(b)), int32(body.len),
                            cast[Il2CppPtr](addr st))
    if guard:
      modhost.modLeave(owners[i])
    if verdict == EvFaulted:
      noteEventFault(n, cbs[i], users[i], owners[i])
    elif verdict == EvNested:
      # Delivered, but from inside somebody else's guard, so a fault here would
      # have unwound to THEIR catch and this loop would never have seen it. Say
      # so rather than counting it as a clean delivery.
      warn "mod event: " & subscriberName(owners[i]) & " handler for " & n &
           " ran UNATTRIBUTED -- this thread was already inside an " &
           "aowl_p_p_seh, and nesting a second guard would disarm the outer " &
           "one. A fault in it cannot be blamed on this handler."
      if st != StatusOk:
        warn "a subscriber to " & n & " returned " & $int(st)
    elif verdict == EvRefused:
      warn "mod event: " & subscriberName(owners[i]) & " handler for " & n &
           " NOT called -- the subscription holds a null callback."
    elif st != StatusOk:
      warn "a subscriber to " & n & " returned " & $int(st)
    inc result

proc hostEmit(name, payload: string) =
  discard deliverEvent(name, payload, -1)

# ---------------------------------------------------------------------------
# The client-settings bridge's ear on the event bus
# ---------------------------------------------------------------------------
#
# `settingsbridge.nim` (included further down, where the overlay's POST slot is
# in scope) broadcasts the settings queries into the mods loaded HERE and needs
# the replies. A mod replies by emitting, which lands in `hostEventEmit` below,
# so this is the only place that can see them. Collection is off unless a
# broadcast is actually in progress, so the ordinary event path costs three
# string compares against a false flag.

const
  SbIndexQuery* = "aowlspt.settings.indexQuery"
    ## The QUERY a mod subscribes to (`aowl/src/aowlspt/settings.nim` line 258,
    ## `discard on(SettingsIndexQuery, onIndexQuery)`). `sbCollect` used to
    ## broadcast `SbIndexAnnounce` -- the REPLY name -- which nothing is
    ## subscribed to, so every round collected zero mods and the bridge had
    ## nothing to push. Page/apply were already correct; only this one was
    ## swapped.
  SbIndexAnnounce* = "aowlspt.settings.indexAnnounce"
  SbPageQuery* = "aowlspt.settings.pageQuery"
  SbPageAnnounce* = "aowlspt.settings.pageAnnounce"
  SbApplyQuery* = "aowlspt.settings.applyQuery"
  SbApplyAnnounce* = "aowlspt.settings.applyAnnounce"

var gSbCollecting = false
var gSbIndex: seq[string] = @[]
var gSbPage = ""
var gSbApply = ""
var gSbYieldUntil = 0'u64
  ## Set by `modSetQueueWrite` when a NATIVE settings page write takes the
  ## single POST slot, so the bridge does not arm over an in-flight edit.

proc sbCapture(n, body: string): bool =
  ## Returns true when this direct hook CONSUMED the event -- i.e. it is one of
  ## the `Sb*Announce` replies and we were collecting, so it was stored here
  ## rather than delivered to a registered subscriber. The caller uses this to
  ## suppress the misleading "no subscribers" log for events that were in fact
  ## consumed, exactly as `control` already exempts mod-control requests. An
  ## announce that arrives while NOT collecting is deliberately NOT reported as
  ## consumed, so a genuinely-undelivered event still logs.
  if not gSbCollecting:
    return false
  if n == SbIndexAnnounce:
    if gSbIndex.len < 64:
      gSbIndex.add body
    return true
  elif n == SbPageAnnounce:
    gSbPage = body
    return true
  elif n == SbApplyAnnounce:
    gSbApply = body
    return true
  return false

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
  let captured = sbCapture(n, body)
  # A mod-control request is recorded and performed from the host's own loop.
  # Never from here: this stack is usually the game thread inside a patch, and
  # for an unload it can run through the very mod being unloaded.
  let control = modcontrol.submit(n, body)
  let delivered = deliverEvent(n, body, from1)
  if delivered == 0 and not control and not captured:
    info "event " & n & " (no subscribers)"
  result = StatusOk

proc enqueue(cb, user: Il2CppPtr; dueMs: uint64; modIndex: int;
             selfTest: bool) =
  ## The only way into `gPending`, from any thread.
  ##
  ## Under the lock because the caller may be a mod's worker thread while the
  ## drain is running on the game thread -- appending to a seq that another
  ## thread is rebuilding is a corrupted list, not a lost callback. The count
  ## is republished inside the lock so the drain's lock-free empty check can
  ## never see a queue that has entries.
  ##
  ## Everything queued here is MAIN-THREAD work by definition, so nothing here
  ## is `hostSafe`. The host's own thread-proof entries go through
  ## `enqueueHostSafe` below, which is a different, explicitly-named door for
  ## exactly the reason the 2026-09-02 crash exists: the old code downgraded the
  ## whole queue when the drain looked stalled, and a mod's `Input::GetKey` tick
  ## ran on the host thread. There is no way to reach `hostSafe` from
  ## `invoke_main` or `schedule`.
  cMqLock()
  if gPending.len >= MqQueueCap:
    # CAPPED, because a queue nobody can drain is a queue that grows for the
    # whole session. Refuse the newest rather than dropping the oldest: a
    # dropped head is a callback a mod already believes is scheduled, while a
    # refused tail is one it is about to re-queue anyway on its next tick.
    gMqRefused = gMqRefused + 1
    cMqUnlock()
    return
  gPending.add Pending(cb: cb, user: user, dueMs: dueMs, modIndex: modIndex,
                       selfTest: selfTest, hostSafe: false)
  cMqSetCount(int32(gPending.len))
  cMqUnlock()

proc enqueueHostSafe(dueMs: uint64) =
  ## THE NAMED PATH for host-internal work that is genuinely correct on any
  ## thread. Today that is exactly one thing: the thread-proof entry, which
  ## carries no callback pointer and whose only effect is that whatever runs it
  ## reports which thread it was on. `runDue` already refuses to make the
  ## managed half of that proof anywhere but the drain's own thread.
  ##
  ## It exists as its own proc, taking no callback, so that "may run on the host
  ## thread" cannot be passed in as an argument by a future caller who has not
  ## read this comment.
  cMqLock()
  if gPending.len < MqQueueCap:
    gPending.add Pending(cb: cast[Il2CppPtr](0), user: cast[Il2CppPtr](0),
                         dueMs: dueMs, modIndex: -1, selfTest: true,
                         hostSafe: true)
    cMqSetCount(int32(gPending.len))
  cMqUnlock()

proc enqueueRender(cb, user: Il2CppPtr; modIndex: int; selfTest: bool) =
  ## The only way into `gRenderPending`, from any thread. Same lock and count
  ## discipline as `enqueue`, on the render storage. No `dueMs`: render work is
  ## for the next render, not a wall-clock deadline, so it is queued due-now.
  cMqLock()
  gRenderPending.add Pending(cb: cb, user: user, dueMs: 0'u64,
                             modIndex: modIndex, selfTest: selfTest,
                             hostSafe: false)
  cRqSetCount(int32(gRenderPending.len))
  cMqUnlock()

proc takeDue(due: var seq[Pending]; hostSafeOnly: bool) =
  ## Moves everything due out of `gPending` into `due`, under the lock.
  ##
  ## `hostSafeOnly` is what the host's own tick thread passes. It lifts ONLY the
  ## entries queued through `enqueueHostSafe` and leaves every mod callback in
  ## the queue, however long it has been there. That is the fix for the two
  ## 2026-09-02 boot crashes: the host thread used to take the whole queue when
  ## the drain looked stalled, so a mod's `Input::GetKey` tick ran where Unity's
  ## input manager slot is null. Leaving work queued is a delay; running it here
  ## is an access violation.
  ##
  ## What is *not* due is compacted down in place rather than copied into a
  ## second seq that replaces `gPending`. The old shape allocated twice a frame
  ## -- once for `due` and once for the replacement -- and freed the buffer
  ## `gPending` already had, so the next frame allocated again. Compacting keeps
  ## that buffer, and `due` is the caller's to reuse, so a steady per-frame
  ## chain allocates nothing at all.
  ##
  ## The write to `gPending[w]` is only ever at an index the read has already
  ## passed (`w <= r` always), so the compaction cannot overwrite an entry it
  ## has not looked at.
  shrink(due, 0)
  cMqLock()
  if gPending.len > 0:
    let now = cNowMs()
    var w = 0
    for r in 0 ..< gPending.len:
      let p = gPending[r]
      if p.dueMs <= now and ((not hostSafeOnly) or p.hostSafe):
        due.add p
      else:
        if w != r:
          gPending[w] = p
        inc w
    if w != gPending.len:
      shrink(gPending, w)
      cMqSetCount(int32(w))
  cMqUnlock()

proc makeProbeGo(goCls: Il2CppClass; ctor: Il2CppMethod;
                 name: string): Il2CppObject =
  ## One named `UnityEngine.GameObject`, created and constructed on whatever
  ## thread the caller is on. `uiProbe` calls it only from the Unity drain
  ## thread. A top-level proc rather than a nested one so it captures nothing.
  let go = objectNew(gRt, goCls)
  if go == nil:
    return cast[Il2CppObject](0)
  let s = newString(gRt, name)
  let a = cArgsNew(1)
  cArgsSetRef(a, 0, s)
  var exc: Il2CppException = nullPtr()
  discard gRt.invoke(ctor, go, cArgsPtr(a), exc)
  cArgsFree(a)
  if exc != nil:
    return cast[Il2CppObject](0)
  return go

proc uiProbe(tid: int) =
  ## Default-off proof of the capability native settings-screen injection is
  ## built on: instantiating Unity UI objects on the Unity thread and parenting
  ## one under another. It runs only when `bridgeUiProbe` is set, and only from
  ## inside `bridgeProof`, which is already gated to the real drain thread -- so
  ## every runtime call here is on Unity's own thread, where object creation and
  ## `Transform.SetParent` are safe and off which they fault.
  ##
  ## It is self-contained: it makes two `UnityEngine.GameObject`s and parents the
  ## child under the parent's transform, so it proves both primitives without
  ## needing to find a live screen in the scene. A mod does the same two calls,
  ## parenting under a real screen's transform instead of a second probe object.
  ## The two objects are left in the scene (a one-shot diagnostic leaks nothing
  ## that matters); a mod destroys or keeps its own.
  let goCls = findClass(gRt, "UnityEngine.GameObject")
  let trCls = findClass(gRt, "UnityEngine.Transform")
  if goCls == nil or trCls == nil:
    okLog "il2cpp ui probe: UnityEngine.GameObject/Transform did not resolve"
    return
  runtimeClassInit(gRt, goCls)
  let ctor = findMethod(gRt, goCls, ".ctor", 1)
  let getTransform = findMethod(gRt, goCls, "get_transform", 0)
  let setParent = findMethod(gRt, trCls, "SetParent", 1)
  if ctor == nil or getTransform == nil or setParent == nil or
     methodPointer(gRt, ctor) == nil or methodPointer(gRt, getTransform) == nil or
     methodPointer(gRt, setParent) == nil:
    okLog "il2cpp ui probe: GameObject.ctor/get_transform/SetParent did not " &
          "resolve to callable code on this build"
    return

  let parent = makeProbeGo(goCls, ctor, "aowlspt_probe_parent")
  let child = makeProbeGo(goCls, ctor, "aowlspt_probe_child")
  if parent == nil or child == nil:
    okLog "il2cpp ui probe: GameObject instantiation returned nil on Unity " &
          "thread " & $tid
    return

  # get_transform on both (returns a Transform reference, not boxed).
  var e1: Il2CppException = nullPtr()
  let parentTr = gRt.invoke(getTransform, parent, cast[Il2CppPtr](0), e1)
  var e2: Il2CppException = nullPtr()
  let childTr = gRt.invoke(getTransform, child, cast[Il2CppPtr](0), e2)
  if e1 != nil or e2 != nil or parentTr == nil or childTr == nil:
    okLog "il2cpp ui probe: instantiated GameObjects on Unity thread " & $tid &
          " but get_transform failed"
    return

  # child.transform.SetParent(parent.transform).
  let a = cArgsNew(1)
  cArgsSetRef(a, 0, parentTr)
  var e3: Il2CppException = nullPtr()
  discard gRt.invoke(setParent, childTr, cArgsPtr(a), e3)
  cArgsFree(a)
  if e3 != nil:
    okLog "il2cpp ui probe: instantiated + got transforms on Unity thread " &
          $tid & " but SetParent threw"
    return
  okLog "il2cpp ui probe: instantiated two UnityEngine.GameObjects on Unity " &
        "thread " & $tid & " and parented one under the other's transform -- " &
        "native UI instantiation + parenting works on the Unity thread"

proc bridgeProof(tid: int) =
  ## The proof that the drain runs on Unity's own thread: from here, make a real
  ## managed IL2CPP call -- the kind that faults from any thread but Unity's.
  ##
  ## This runs only when a per-frame method was detoured, i.e. only on Unity's
  ## main thread. The same operations issued from the host's boot thread crash
  ## this client (the runtime's GC and managed heap are affine to the Unity
  ## thread), which is the whole reason the bridge exists; issued from here they
  ## return a value, and that value is the proof.
  ##
  ## Two calls, in order of how game-like they are and how likely they resolve:
  ##   1. `UnityEngine.Time::get_frameCount` -- a static getter that reads live
  ##      Unity state and boxes an int. Only invoked if it resolves to a real,
  ##      executable `methodPointer`, so a build that does not populate that
  ##      field skips it rather than faulting on a null call.
  ##   2. boxing a `System.Int32` -- a pure managed-heap allocation, the exact
  ##      operation that faults from a foreign thread, and one that needs no
  ##      method pointer at all. A successful round-trip is itself the proof.
  var reported = false

  # PROOF 0, and the only one that does not depend on a TOKEN-GATED export.
  #
  # `il2cpp_string_new` is NOT in the 40-row gate table
  # (`abi/aowlspt_il2cpp_gates_data.h`), so it is called with its real
  # signature and answers truthfully. It is also a MANAGED-HEAP ALLOCATION,
  # which is precisely the operation that faults from any thread but Unity's --
  # so a string that comes back and reads back correctly is the same proof the
  # boxing round-trip was reaching for, with nothing gated in the path.
  #
  # The readback is the check, not the non-nil: `System.String._stringLength`
  # is at 0x10 (the mandatory `tools/fldoff.py` self-check offset), and it must
  # equal the length we asked for. A pointer that is merely non-nil proves
  # nothing here; a pointer whose _stringLength is our own length cannot be a
  # coincidence, and this check FAILS if the allocation did not happen.
  const BridgeProbe = "aowlspt-bridge-probe"
  let probeStr = newString(gRt, BridgeProbe)
  if probeStr != nil and
     cIsReadable(cast[Il2CppPtr](probeStr), 0x18'i32) != 0'i32:
    let n = cReadI32At(cast[Il2CppPtr](cast[uint](probeStr) + 0x10'u))
    if n == int32(BridgeProbe.len):
      okLog "il2cpp bridge: allocated a managed System.String on Unity " &
            "thread " & $tid & " and read _stringLength back as " & $n &
            " -- the managed heap is reachable from this thread (this call " &
            "is ungated; it is the proof, and the by-name probes below are not)"
      reported = true
    else:
      warn "il2cpp bridge: il2cpp_string_new returned a readable pointer on " &
           "thread " & $tid & " whose _stringLength@0x10 reads " & $n &
           ", not " & $(BridgeProbe.len) & " -- NOT a proof; treating the " &
           "managed-heap probe as INCONCLUSIVE"
  else:
    warn "il2cpp bridge: il2cpp_string_new returned nothing readable on " &
         "thread " & $tid & " -- the managed-heap probe is INCONCLUSIVE, " &
         "not a failure of the drain"

  # The by-name probes below go through TOKEN-GATED exports
  # (`il2cpp_class_from_name`, `il2cpp_class_get_method_from_name`). With the
  # `il2cppGates` flag off -- the default -- those return MT19937-64 output,
  # and `findClass`/`findMethod` now REFUSE such a handle rather than hand it
  # on (see `gatedHandle` in `aowl/src/aowlspt/il2cpp.nim`). That refusal is
  # what makes the two blocks below take their "did not resolve" paths on this
  # build instead of boxing against a random Il2CppClass*, which is what
  # crashed the client at 0:00:09 on 2026-09-02.
  let timeCls = findClass(gRt, "UnityEngine.Time")
  if timeCls != nil:
    let m = findMethod(gRt, timeCls, "get_frameCount", 0)
    if m != nil and methodPointer(gRt, m) != nil:
      var exc: Il2CppException = nullPtr()
      let res = gRt.invoke(m, cast[Il2CppObject](0), cast[Il2CppPtr](0), exc)
      if exc == nil and res != nil:
        let boxed = gRt.objectUnbox(res)
        if boxed != nil:
          okLog "il2cpp bridge: ran managed call on Unity thread " & $tid &
                ", result=UnityEngine.Time.get_frameCount() = " &
                $cReadI32(boxed)
          reported = true
  if not reported:
    let i32 = findClass(gRt, "System.Int32")
    if i32 != nil:
      let cell = cCellNew()
      cCellSetI32(cell, 424242'i32)
      let boxed = gRt.valueBox(i32, cell)
      cCellFree(cell)
      if boxed != nil:
        let back = gRt.objectUnbox(boxed)
        okLog "il2cpp bridge: ran managed call on Unity thread " & $tid &
              ", result=boxed System.Int32 round-trip = " &
              $(if back != nil: cReadI32(back) else: 0'i32)
        reported = true
  if not reported:
    okLog "il2cpp bridge: on Unity thread " & $tid &
          ", but no managed call could be resolved to prove it"
  # The UI-instantiation proof, only when explicitly enabled. Runs here because
  # `bridgeProof` is already on the confirmed drain thread.
  if gUiProbe:
    uiProbe(tid)

proc renderProof(tid: int) =
  ## The render-phase proof: a self-test entry drained from inside the
  ## render-phase detour. It records the thread and fire count, and confirms the
  ## `UnityEngine.GL` immediate-mode API is reachable from here -- which is the
  ## capability this drain exists to give ESP and GL-HUD mods. `GL.PushMatrix`
  ## then `GL.PopMatrix` is a balanced no-op that draws nothing and leaves the
  ## matrix stack as it found it, so it is safe to run every time the proof
  ## fires; a build that will not resolve the pair logs that instead of calling
  ## a null pointer.
  var proven = false
  let glCls = findClass(gRt, "UnityEngine.GL")
  if glCls != nil:
    let push = findMethod(gRt, glCls, "PushMatrix", 0)
    let pop = findMethod(gRt, glCls, "PopMatrix", 0)
    if push != nil and pop != nil and
       methodPointer(gRt, push) != nil and methodPointer(gRt, pop) != nil:
      var exc: Il2CppException = nullPtr()
      discard gRt.invoke(push, cast[Il2CppObject](0), cast[Il2CppPtr](0), exc)
      if exc == nil:
        discard gRt.invoke(pop, cast[Il2CppObject](0), cast[Il2CppPtr](0), exc)
        okLog "il2cpp render bridge: ran UnityEngine.GL PushMatrix/PopMatrix " &
              "on the Unity render-phase thread " & $tid &
              " -- immediate-mode GL is reachable for ESP/HUD drawing"
        proven = true
  if not proven:
    okLog "il2cpp render bridge: drained on the Unity render-phase thread " &
          $tid & " (UnityEngine.GL did not resolve to prove the GL path)"

proc runDue(due: var seq[Pending]; isRender: bool) =
  ## Runs what `takeDue` lifted out, **outside** the lock.
  ##
  ## Outside it on purpose: a callback is a mod's code, it may take as long as
  ## it likes, and it may call `invoke_main` again. Running it with the lock
  ## held would block every other thread behind whatever it does. Taking the
  ## work out first is the same shape the backend's timer queue uses.
  ##
  ## `isRender` selects which queue's self-test proof this is: the render drain
  ## proves the GL path, the update drain proves the managed-call path. Only the
  ## proof differs; a mod's callback is dispatched identically either way.
  ##
  ## THE LAST GATE, and the one that actually holds. `takeDue(hostSafeOnly)`
  ## decides what to LIFT; this decides what to RUN, per entry, from the thread
  ## it is actually on. Both exist because a filter at the queue is a promise
  ## about callers and this is a property of the finished state -- a caller that
  ## lifts the wrong thing still cannot invoke it here.
  let tidNow = cThreadId()
  let ownerNow = (if isRender: cRqThread() else: cMqThread())
  for p in due:
    if cMqMayRunHere(tidNow, ownerNow, (if p.hostSafe: 1'i32 else: 0'i32)) == 0'i32:
      # Not this thread's work. Put it back rather than dropping it: a mod that
      # asked for a main-thread callback is entitled to get one late, and a
      # silently discarded callback is indistinguishable from one that ran.
      cMqLock()
      if isRender:
        if gRenderPending.len < MqQueueCap:
          gRenderPending.add p
          cRqSetCount(int32(gRenderPending.len))
      else:
        if gPending.len < MqQueueCap:
          gPending.add p
          cMqSetCount(int32(gPending.len))
      cMqUnlock()
      gMqDeferred = gMqDeferred + 1
      continue
    if p.selfTest:
      # The proof, and the reason it is an entry in the queue rather than a
      # log line at bind time: it went in from the host thread and comes out
      # here, so the thread it names is the thread a mod's callback would get.
      # Says where, and -- when nothing bound -- what that means. A mod author
      # reading this log should not have to know that thread 21728 is the
      # host's own to know the callback was not on Unity's.
      # The managed call in the proof is ONLY safe on the actual drain thread --
      # the one the detour fired on and claimed. A slot being bound is NOT enough:
      # when a drain is bound but never fires (a wrong-but-live target, or a
      # method the game does not call), the host's tick loop drains this very
      # queue on its OWN thread as a fallback, and a managed call there faults
      # exactly as the live client did. So the proof is gated on being on the
      # claimed drain thread, not on `slot >= 0`. `cMqThread`/`cRqThread` are the
      # thread the drain claimed, or 0 if it has never fired.
      let tid = int(cThreadId())
      let owner = (if isRender: int(cRqThread()) else: int(cMqThread()))
      if owner == 0 or owner != tid:
        warn (if isRender: "render " else: "invoke_main ") &
             "self-test ran on thread " & $tid &
             ", the host's own thread and not Unity's drain thread; no managed " &
             "call was made (the drain is bound but has not fired on its own " &
             "thread, or nothing is bound)"
      elif isRender:
        renderProof(tid)
      else:
        okLog "invoke_main self-test ran on thread " & $tid
        # Genuinely on the drain's own thread now, so a real managed call is
        # safe -- the same call from the host thread crashes the client. Proof.
        bridgeProof(tid)
    else:
      # A reference on the owning mod, held across the callback.
      #
      # This is the one dispatch in this host that genuinely races the unload,
      # and it is worth being exact about why. The queue is emptied under the
      # lock above and `dropModRegistrations` rebuilds it under the same lock,
      # so a callback still in `gPending` when a mod is torn down is dropped
      # correctly. What the lock cannot reach is the callback already lifted
      # into `due`: `p.cb` is a function pointer into the mod's library and
      # this loop runs on **Unity's main thread**, while `unloadOne` runs on the
      # host's tick thread a few lines below `modcontrol.drain`. Between the
      # `cMqUnlock` above and this call the tick thread is free to run the
      # teardown and `FreeLibrary`, and then this is a jump into unmapped
      # memory on the game's own thread.
      #
      # `runPending` reaches the same loop from the tick thread, where the
      # unload cannot be concurrent -- the guard is simply uncontended there.
      #
      # The pair costs about 11 ns uncontended. This runs once per due callback
      # rather than once per frame: `mainDrain` returns inside `cMqEnter` when
      # the queue is empty, so a frame with nothing due never reaches here, and
      # a frame with something due is already paying for a call into a mod.
      # A `selfTest` entry is the host's own and has no mod behind it, and
      # `modGuarded` covers the other non-mod queuers -- the harness queues
      # through `invoke_main` and `schedule` under `0x7FFF` exactly as it
      # subscribes under it, and dropping those callbacks would silently gut
      # the churn gate's timer arm rather than fail it.
      let guard = modGuarded(p.modIndex)
      if not guard or modhost.modEnter(p.modIndex):
        # THE PER-MOD BREAKDOWN of `mainDrain`. `mainDrain` dispatches every mod
        # callback -- the maps HUD included -- so if the frame is being spent in
        # a MOD rather than in the host, row 1 of the profiler is where it shows
        # up and this is the only place that can say which mod. Two QPC reads
        # per DUE callback, not per frame: a frame with nothing due returns
        # inside `cMqEnter` and never reaches here, and a frame that does reach
        # here is already paying for a call into a mod. These rows are NESTED
        # inside row 1 and the reporter never adds them to the top-level sum.
        let dpCb = cDpNow()
        discard cInvokeCallback(p.cb, p.user, cast[Il2CppPtr](0), 0'i32)
        cDpAdd(cDpModSlot(int32(p.modIndex)), dpCb)
        if guard:
          modhost.modLeave(p.modIndex)

proc drainDue(hostSafeOnly: bool) =
  ## The drain with a buffer of its own.
  ##
  ## Two callers, and neither is the drain thread in its ordinary frame:
  ## `runPending`, which is the host's tick thread and which passes
  ## `hostSafeOnly = true` -- it may run the host's own thread-proof entries and
  ## NOTHING else, ever; and `mainDrain` re-entered from inside a callback,
  ## which is on the drain's own thread and passes false. Both are rare and
  ## neither is per-frame, so both pay for their own seq rather than sharing one
  ## that would need a lock.
  var due: seq[Pending] = @[]
  takeDue(due, hostSafeOnly)
  runDue(due, false)

proc renderTakeDue(due: var seq[Pending]) =
  ## `takeDue` for the render queue: lifts everything due out of `gRenderPending`
  ## and compacts what is left, under the lock, republishing the render count so
  ## `cRqEnter`'s lock-free empty check stays honest. A carbon copy of `takeDue`
  ## on the render storage; the two queues are identical in shape and separate in
  ## state on purpose.
  shrink(due, 0)
  cMqLock()
  if gRenderPending.len > 0:
    let now = cNowMs()
    var w = 0
    for r in 0 ..< gRenderPending.len:
      let p = gRenderPending[r]
      if p.dueMs <= now:
        due.add p
      else:
        if w != r:
          gRenderPending[w] = p
        inc w
    if w != gRenderPending.len:
      shrink(gRenderPending, w)
      cRqSetCount(int32(w))
  cMqUnlock()

proc renderDrain() =
  ## The render-phase drain, called from inside a RENDER-phase Unity callback
  ## (see `bindRenderDrain`). Same shape as `mainDrain`: `cRqEnter` answers "is
  ## this my thread and is there anything to do" in a handful of instructions,
  ## and only a frame with render work queued reaches the drain. GL issued from a
  ## callback run here lands on the frame being drawn.
  if cRqEnter() == 0'i32:
    return
  if gRenderDraining:
    var due: seq[Pending] = @[]
    renderTakeDue(due)
    runDue(due, true)
    return
  gRenderDraining = true
  renderTakeDue(gRenderDue)
  runDue(gRenderDue, true)
  gRenderDraining = false

proc runFrameBench()

proc mainDrain() =
  ## The per-frame drain, called from inside a method Unity runs on its main
  ## thread. Everything expensive is behind `cMqEnter`, which answers "is this
  ## my thread, and is there anything to do" in a handful of instructions.
  ##
  ## The bench arm ahead of it is a load of a global and a not-taken branch --
  ## sub-nanosecond, and it is inside the loop the bench times, so the figure
  ## the bench reports includes it rather than excluding its own cost. It is
  ## here rather than in `patchFired` because this is the proc a mod's frame
  ## actually pays for, and a benchmark of the drain that did not run on the
  ## drain's own thread would be measuring a different function.
  if gBenchIters != 0:
    runFrameBench()
  if cMqEnter() == 0'i32:
    return
  if gDraining:
    # Re-entered from inside a callback: `gDue` is live further down this
    # stack, so this nesting takes its own. Without this the inner drain would
    # shrink the buffer the outer one is walking.
    drainDue(false)
    return
  gDraining = true
  takeDue(gDue, false)
  runDue(gDue, false)
  gDraining = false

const BenchModIndex = 0x7FFF0
  ## Past `ModSlotLimit`, so `modGuarded` answers false and the bench's own
  ## entries are dispatched without a `modEnter`/`modLeave` pair on a mod that
  ## does not own them. The pair is about 11 ns and a real mod's callback does
  ## pay it; that is said in the report rather than folded into a row, because
  ## a bench that took a reference on somebody else's library would be holding
  ## an unload open for as long as it ran.

proc benchRow(name: string; t0, t1: int64; iters: int): string =
  ## One row, in picoseconds as well as nanoseconds: the empty-queue drain is a
  ## handful of instructions, and an integer nanosecond figure would round it
  ## to 4 or 5 and hide every change worth making to it.
  let total = nanosBetween(t0, t1)
  result = "{\"op\":\"" & name & "\",\"ns\":" & $(total div int64(iters)) &
           ",\"ps\":" & $((total * 1000'i64) div int64(iters)) &
           ",\"iters\":" & $iters & ",\"totalNs\":" & $total & "}"

proc runFrameBench() =
  ## The per-frame path, timed on the per-frame thread.
  ##
  ## Runs inside one frame of the game (one firing of the detoured method), so
  ## the iteration counts are chosen to keep that frame in the tens of
  ## milliseconds: a stand-in does not care, and this never runs unless a
  ## harness asked for it.
  let base = gBenchIters
  # Cleared first, and that is not tidiness: every loop below calls `mainDrain`,
  # which checks this. Leaving it set is an infinite recursion on the game's
  # own thread.
  gBenchIters = 0
  if base <= 0: return

  let fast = base * 10
  let slow = base
  let cb = cBenchCb()
  let nothing = cast[Il2CppPtr](0)

  # The queue goes aside for the duration. A per-frame chain armed by a mod is
  # almost certainly in it right now, and the empty-queue row would otherwise
  # be timing that mod's callback a hundred thousand times.
  cMqLock()
  var saved = gPending
  gPending = @[]
  cMqSetCount(0'i32)
  cMqUnlock()

  let hits0 = int(cBenchHits())

  # A: nothing queued. This is what every frame costs when no mod has anything
  # pending, which is most frames of most raids.
  let a0 = perfCounter()
  for i in 0 ..< fast:
    mainDrain()
  let a1 = perfCounter()

  # B: something queued, not yet due -- a `schedule` waiting out its delay. The
  # gate lets this frame through and the walk finds nothing to run, so this is
  # the cost of *holding* a timer, per frame, per entry.
  enqueue(cb, nothing, 0xFFFFFFFFFFFF'u64, BenchModIndex, false)
  let b0 = perfCounter()
  for i in 0 ..< fast:
    mainDrain()
  let b1 = perfCounter()
  cMqLock()
  shrink(gPending, 0)
  cMqSetCount(0'i32)
  cMqUnlock()

  # C: the queue turned around once, with no dispatch. Subtracting this from D
  # is what the trampoline into a mod costs.
  var scratch: seq[Pending] = @[]
  let c0 = perfCounter()
  for i in 0 ..< slow:
    enqueue(cb, nothing, 0'u64, BenchModIndex, false)
    takeDue(scratch, false)
  let c1 = perfCounter()

  # D: one frame of an armed `everyMain` chain -- the mod re-queues itself and
  # the next frame's drain runs it. The allocation counter brackets exactly this
  # loop, because this is the loop that used to allocate two seqs a frame.
  let alloc0 = allocationCount()
  let d0 = perfCounter()
  for i in 0 ..< slow:
    enqueue(cb, nothing, 0'u64, BenchModIndex, false)
    mainDrain()
  let d1 = perfCounter()
  let alloc1 = allocationCount()

  # E and F: what row B is made of. A row that says "31 ns" and nothing else
  # invites a rewrite of the wrong half; these two say how much of it is the
  # gate and how much is the lock, and therefore whether there is anything left
  # to win.
  let e0 = perfCounter()
  for i in 0 ..< fast:
    discard cMqEnter()
  let e1 = perfCounter()

  let f0 = perfCounter()
  for i in 0 ..< fast:
    cMqLock()
    cMqUnlock()
  let f1 = perfCounter()

  let g0 = perfCounter()
  var nowSink = 0'u64
  for i in 0 ..< fast:
    nowSink = nowSink + cNowMs()
  let g1 = perfCounter()

  let hits1 = int(cBenchHits())

  # Whatever arrived from another thread while the bench ran goes back on the
  # end of what was taken aside, in the order it arrived.
  cMqLock()
  for i in 0 ..< gPending.len:
    saved.add gPending[i]
  gPending = saved
  cMqSetCount(int32(gPending.len))
  cMqUnlock()

  gBenchReport = "{\"rows\":[" &
    benchRow("mainDrain, queue empty", a0, a1, fast) & "," &
    benchRow("mainDrain, one entry queued not due", b0, b1, fast) & "," &
    benchRow("enqueue + takeDue, no dispatch", c0, c1, slow) & "," &
    benchRow("enqueue + mainDrain, one chain frame", d0, d1, slow) & "," &
    benchRow("cMqEnter alone, the gate", e0, e1, fast) & "," &
    benchRow("cMqLock plus cMqUnlock, uncontended", f0, f1, fast) & "," &
    benchRow("cNowMs", g0, g1, fast) &
    "],\"nowSink\":" & $(nowSink and 1'u64) &
    ",\"dispatches\":" & $(hits1 - hits0) &
    ",\"chainFrames\":" & $slow &
    ",\"allocDelta\":" & $(alloc1 - alloc0) & "}"
  inc gBenchRuns

proc fireHandler(i: int; payload: string; handleMark, handleTop: int;
                 replacement: var string): int32 =
  ## Hands one payload to a mod's patch handler and cleans up after it.
  ##
  ## Shared by the prefix and the postfix paths because everything except *when*
  ## it happens is the same: the same trampoline into the mod, the same
  ## owned-buffer rule for a replacement, and above all the same handle
  ## lifetime. Every reference in the payload cost a GC handle, and they are all
  ## given back here -- a handler on a per-frame method that was expected to
  ## release them itself would pin objects at frame rate, which is a trap rather
  ## than a contract.
  ##
  ## The table is only shortened when nothing else was added to it while the
  ## handler ran: a handler that called `resolve`, or a method that returned an
  ## object, got handles of its own with higher indices and those are its to
  ## keep. In that case the slots are emptied in place, so nothing is freed
  ## twice and no live handle is renumbered.
  replacement = ""

  # While the handler runs, these two say which handles it may take an address
  # for; afterwards they say which ones it may not. Saved and restored rather
  # than assigned, because a handler is free to call something the host has
  # patched, and an inner firing's cleanup must not close the outer one's scope.
  let prevMark = gPatchHandleMark
  let prevTop = gPatchHandleTop
  gPatchHandleMark = handleMark
  gPatchHandleTop = handleTop
  inc gPatchDepth

  var outPtr: Il2CppPtr = cast[Il2CppPtr](0)
  var outLen = 0'i32
  var a = payload
  let st = cInvokePatchArgs(gPatches[i].cb, gPatches[i].user,
                            cast[Il2CppPtr](addr gPatches[i].targetC[0]),
                            int32(gPatches[i].targetC.len - 1),
                            (if payload.len > 0: cast[Il2CppPtr](toCString(a))
                             else: cast[Il2CppPtr](0)),
                            int32(payload.len),
                            cast[Il2CppPtr](addr outPtr),
                            cast[Il2CppPtr](addr outLen))
  dec gPatchDepth

  if outPtr != nil and outLen > 0'i32:
    replacement = readBytes(outPtr, outLen)
  if outPtr != nil:
    cFreeBuf(outPtr)

  # The reclaim, under the lock and *after* the mod has returned -- never
  # around the call itself. A handler is a mod's code: it may take as long as
  # it likes, it may call `resolve` on this thread (which re-enters the lock
  # harmlessly) or start a thread that does (which would block behind it for
  # as long as the handler ran).
  if handleTop > handleMark:
    tablesLock()
    for k in handleMark ..< handleTop:
      if gHandleIsObject[k] and gHandleGc[k] != 0'u32:
        gcHandleFree(gRt, gHandleGc[k])
      gHandleGc[k] = 0'u32
      gHandles[k] = cast[Il2CppPtr](0)
      gHandleIsObject[k] = false
    if gHandles.len == handleTop:
      shrink(gHandles, handleMark)
      shrink(gHandleIsObject, handleMark)
      shrink(gHandleGc, handleMark)
    else:
      # The handler took handles of its own, so the table cannot be shortened
      # without renumbering them. The firing's own slots are emptied in place
      # above and queued here, which is what stops a handler that calls
      # `resolve` from leaving a hole per firing.
      for k in handleMark ..< handleTop:
        pushFreeHandle(k)
    if gPatchDepth == 0:
      trimHandles()
    tablesUnlock()

  if gPatchDepth > 0:
    # Nested: the outer firing's handles are live again and its scope is the
    # one `handle_pointer` should be judging against.
    gPatchHandleMark = prevMark
    gPatchHandleTop = prevTop
  # Otherwise the range stays as it is, dead, so that a mod asking for one of
  # these afterwards is told what it did rather than "no such handle".
  result = st

proc typedFire(i: int; regs: Il2CppPtr; postfix: bool): int32 =
  ## One firing of a typed patch: arm a pooled frame over the registers the
  ## thunk already saved, call the mod, disarm.
  ##
  ## Compare it with `fireHandler` above, which is the JSON path: that one builds
  ## a string describing the arguments, registers a GC handle for every reference
  ## in it, hands the string across the ABI where the mod copies it into its own
  ## heap and parses it, takes a host-allocated buffer back, and gives every
  ## handle up again. This one stores six words and calls.
  ##
  ## Nothing here touches `gPatchPayloadBytes` or `gPatchHandlesTaken`, and that
  ## is the point: `call("aowlspt.host::patch_stats")` reports both, so a test
  ## can fire a typed hook twenty thousand times and assert that neither moved.
  ##
  ## `gPatchDepth` is raised around the call for the same reason `fireHandler`
  ## raises it -- a handler may itself call something this host has patched --
  ## and it is also what picks the frame out of the pool, so a nested firing
  ## cannot overwrite the outer one's view of the registers.
  if gPatchDepth >= int(cFrameDepthMax()):
    # Deeper than the pool. Letting the original run is the only safe answer:
    # reusing a live frame would hand the inner handler the outer firing's
    # registers, which is a plausible set of arguments rather than an error.
    gTypedTooDeep = gTypedTooDeep + 1
    return 0'i32
  let f = cFrameSlot(int32(gPatchDepth))
  if f == nil:
    gTypedTooDeep = gTypedTooDeep + 1
    return 0'i32
  var flags = gPatches[i].frameFlags
  if postfix: flags = flags or FrameFlagPostfix
  var selfPtr = 0'u64
  if (flags and FrameFlagStatic) == 0'u32:
    selfPtr = cRegsInt(regs, 0'i32)
  # `addr` of element zero rather than the seq itself: the frame points at the
  # bytes, and the array was built at registration and is never rewritten.
  let kinds = (if gPatches[i].kinds.len > 0:
                 cast[Il2CppPtr](addr gPatches[i].kinds[0])
               else: cast[Il2CppPtr](0))
  cFrameArm(f, regs, kinds, int32(gPatches[i].kinds.len),
            int32(gPatches[i].retKind), flags, selfPtr)
  inc gPatchDepth
  gTypedFires = gTypedFires + 1
  let st = cInvokeTypedPatch(gPatches[i].cb, gPatches[i].user, f)
  dec gPatchDepth
  # Before anything else can return. A mod that stored the frame reads a cleared
  # one from here on, and every accessor in `aowlspt_frame.h` refuses it by name
  # rather than answering with the registers of whatever fired next.
  cFrameDisarm(f)
  # No `applyPatchReturn` and no `canSkip` gate. The mod wrote the replacement
  # itself, through a setter that checked it against the declared return kind
  # and answered whether it had written -- so by the time a skip reaches here the
  # value in the frame is of the right shape or the mod chose not to claim one.
  result = (if st == PatchSkipStatus: 1'i32 else: 0'i32)

var gSharedRidersLoggedPf = false
var gSharedRidersLoggedPr = false

proc logSharedRiders(half: string; i: int) =
  ## THE DISPATCH TABLE, OBSERVED RATHER THAN INFERRED.
  ##
  ## One line, once per half, the first time the shared `PreloaderUI::Update`
  ## detour fires through it. It prints the slot that actually fired next to
  ## the CURRENT value of all three rider slot globals, and then names exactly
  ## which riders that firing will dispatch.
  ##
  ## This exists because a rider that is armed, logs that it armed, and then is
  ## never dispatched is indistinguishable from a rider that is dispatched and
  ## does nothing -- and telling those apart cost two full deploy/launch cycles.
  ## With this line it is one glance: if `inspect:6` and `slot=6` then dispatch
  ## is fine and the fault is inside the rider; if `inspect:-1` the alias never
  ## landed. Costs one boolean test per frame after the first firing, and never
  ## allocates again.
  okLog half & ": slot=" & $i &
        " riders={debugui:" & $gDebugUiSlot &
        ", modetext:" & $gModeTextSlot &
        ", inspect:" & $gInspSlot & "}" &
        " -> dispatches" &
        (if i == gDebugUiSlot: " debugui" else: "") &
        (if i == gModeTextSlot: " modetext" else: "") &
        (if i == gInspSlot: " inspect" else: "") &
        (if i != gDebugUiSlot and i != gModeTextSlot and i != gInspSlot:
           " NOTHING (no rider slot matches this firing)" else: "")

{.emit: """#include "aowlspt_profile.h" """.}
# The header is `include`d again HERE, and not only in `modhost.nim`, because
# these are two translation units: the `nodecl` importc procs modhost exports
# are Nim-level names, and the C declarations behind them only exist in a file
# that included the header. Each TU therefore gets its own copy of the header's
# `static` functions and its own `g_prof` pointer -- which is correct and is the
# same arrangement `aowlspt_admin.h` already uses. What the two share is the
# named file mapping, not the variable.

# ---------------------------------------------------------------------------
# THE PROFILER'S RIDER SCOPES (abi/aowlspt_profile.h)
# ---------------------------------------------------------------------------
#
# One slot per rider on the SHARED `EFT.UI.PreloaderUI::Update` detour, plus the
# frame boundary. This installs NOTHING: there is no new detour, no new RVA, no
# by-name lookup (fact #145 -- every by-NAME IL2CPP route on this build is fatal
# the moment it is USED, and a QueryPerformanceCounter has no name to resolve).
# It rides the chain `patchFired`/`patchReturned` already dispatch, which is the
# whole reason a second detour is not needed and must not be added.
#
# DEFAULT OFF, and off costs one volatile load: `gProfOn` is refreshed once per
# frame from the shared region, and `cProfBegin`/`cProfEnd` each re-check the
# same flag, so enabling it mid-frame can never leave a begin without an end.
#
# NO ALLOCATION. The slot indices are five int32 globals registered ONCE, by a
# constant string, on the first frame after the profiler is switched on. A
# `-1` slot is legal and ignored, so a refused registration means "this rider is
# not profiled" and never a fault.
#
# NO NESTED GUARD. This runs inside the ONE `aowl_p_p_seh` the rider chain
# already holds; `abi/aowlspt_profile.h` deliberately arms no guard of its own,
# because that guard is not re-entrant and a nested one would disarm the outer.
var profSlotDebugUi  = -1'i32
var profSlotModeText = -1'i32
var profSlotInspect  = -1'i32
var profSlotCodeGen  = -1'i32
var profSlotModsTab  = -1'i32
var profSlotRegion   = -1'i32
var gProfRegistered = false

proc profFrameTick() =
  ## Close the frame and, every `windowFrames`, roll every slot's window. Called
  ## from the shared rider chain and nowhere else, so exactly once per frame.
  if cProfEnabled() == 0:
    return
  if not gProfRegistered:
    gProfRegistered = true
    cProfCalibrate()
    profSlotDebugUi  = cProfSlot(cstring"host:debugOverlay", 2'i32)
    profSlotModeText = cProfSlot(cstring"host:menuModeText", 2'i32)
    profSlotInspect  = cProfSlot(cstring"host:liveInspector", 2'i32)
    profSlotCodeGen  = cProfSlot(cstring"host:codeGenProbe", 2'i32)
    profSlotModsTab  = cProfSlot(cstring"host:modsTab", 2'i32)
    profSlotRegion   = cProfSlot(cstring"host:region", 2'i32)
  cProfFrame()

proc patchFired(slot: int32; regs: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## Called from the detour thunk, on the game thread, inside the patched
  ## method, with every argument register saved in `regs`.
  ##
  ## Returns 0 to let the original run and 1 to suppress it. Suppression is the
  ## sharpest thing this file does: the original never executes, and whatever is
  ## left in the return register is what the game gets. So it happens only when
  ## the patch asked for it *and* a return value of the declared type could
  ## actually be produced -- a skip with garbage in RAX is worse than no skip.
  ##
  ## The cheap path stays cheap. A patch that did not ask for arguments does no
  ## decoding, no allocation and no logging, exactly as before.
  let i = int(slot)
  # The host's own drain hook comes first, and by identity rather than by
  # scanning: it fires on every frame of the game and must not walk anything.
  if i == gDrainSlot:
    # THE FRAME METER, first and above everything, so the interval it measures
    # is the interval every rider below is charged against. It rides THIS drain
    # and nothing else: `gDrainSlot` is bound by the bridge, not by a feature
    # flag, and `TarkovApplication::Update` ticks for the whole session,
    # including raid. That independence is the entire point -- every other frame
    # counter in the host lives inside a feature (natEspDiag, the maps diag),
    # and the maps HUD only draws once the raid-phase latch reads DEPLOYED, a
    # latch driven from the ESP path. So frame instrumentation was transitively
    # gated on `natEsp`, and the one experiment that matters -- what is the
    # frame rate with the ESP OFF -- could not be run. This can run it.
    #
    # It opens NO guard: its whole working set is its own statics plus
    # QueryPerformanceCounter, it dereferences no game pointer and allocates
    # nothing on the per-frame path. Flag `frameMeter`, default OFF; idle cost
    # is one boolean compare.
    # THE DRAIN PROFILER's frame edge, taken BEFORE any rider so the interval it
    # divides by is the same interval the riders below are charged against. One
    # QPC read; no guard, no game pointer, no allocation. Flag `drainProfiler`,
    # default OFF; idle cost is one boolean compare inside `aowl_dp_frame`.
    cDpFrame()
    var dpT = cDpNow()
    ftTick()
    cDpAdd(DpFt, dpT)
    arTick()
    # Every bracket below is OUTSIDE the bracketed rider, never inside it:
    # several of these riders open their own single `aowl_p_p_seh`, and that
    # guard is not re-entrant, so a bracket that reached inside would be a
    # nested region rather than a measurement.
    dpT = cDpNow()
    mainDrain()
    cDpAdd(DpMain, dpT)
    # THE LIVE INSPECTOR'S IN-RAID TICK. `PreloaderUI::Update` only runs in the
    # menu, so an inspector anchored solely to it goes silent the moment a raid
    # starts -- which is precisely where the bot, nav and ESP questions are.
    # The main drain rides `EFT.TarkovApplication::Update`, which ticks for the
    # whole session including raid, so the inspector rides it as a SECOND
    # anchor. No new detour is installed: this is an alias onto a slot the
    # bridge already claimed, the same rule the PreloaderUI multiplex follows.
    #
    # This branch returns immediately, so the rider chain further down never
    # sees this slot -- the alias alone would do nothing, and the call has to
    # be here. `inspTick` is idempotent (it drains only when a batch is
    # pending), so being reachable from two anchors costs one interlocked load
    # per frame and never runs a batch twice.
    if i == gInspSlot2:
      dpT = cDpNow()
      inspectDrainFired()
      cDpAdd(DpInspect, dpT)
    # SKIP THE MODE SCREEN'S deferred Submit. It rides THIS drain, not
    # `PreloaderUI::Update`, for two reasons: `TarkovApplication::Update` ticks
    # for the whole session (the selection screen is up before the main menu
    # exists, where PreloaderUI's tick cannot be assumed), and riding an
    # existing drain means no second detour and no second trampoline. Idle cost
    # is two integer compares.
    dpT = cDpNow()
    modeSkipDrainTick()
    cDpAdd(DpModeSkip, dpT)
    # FREE THE MOUSE WHILE AN OVERLAY PANEL IS OPEN. It rides THIS drain, and
    # not `PreloaderUI::Update` like most of the UI features, for the reason the
    # inspector's `gInspSlot2` alias two branches up exists: PreloaderUI only
    # ticks in the MENU, and a raid is the whole point of this feature -- in a
    # raid the client locks the cursor to screen centre for mouselook and an
    # overlay panel cannot be clicked. Idle cost is a publish and two integer
    # compares; it makes NO call into the game on a frame where no panel is open
    # and no saved state is held.
    # Publish the mod-facing UI overlay mask FIRST, so cursorFreeDrainTick's
    # host-mask publication this frame sees this frame's game-Settings state.
    dpT = cDpNow()
    uiStateDrainTick()
    cDpAdd(DpUiState, dpT)
    dpT = cDpNow()
    cursorFreeDrainTick()
    cDpAdd(DpCursor, dpT)
    # SINGLEPLAYER REBRAND of the Matchmaker Offline Raid Screen. Rides THIS
    # drain (TarkovApplication::Update ticks the whole session, including the
    # matchmaker screens which are up before the main menu's PreloaderUI can be
    # assumed), not a second detour. Idle cost is two integer compares.
    dpT = cDpNow()
    splRebrandDrainTick()
    cDpAdd(DpSplRebr, dpT)
    # THE IN-GAME MOD LOADING SCREEN. Rides THIS drain too -- it installs no
    # detour of its own, because a second detour on one function overwrites the
    # first's trampoline. It must ride TarkovApplication::Update rather than
    # PreloaderUI's, for the same reason splRebrand does: the compile is running
    # while the matchmaker/profile screens are up, before the main menu's
    # PreloaderUI can be assumed. Idle cost is one clock compare; when the file
    # is unchanged it does not even allocate. Flag `modLoadScreen`, default ON.
    modLoadTick()
    # THE COMMAND-LINE AUDIT SWEEP. One integer compare per frame until it
    # fires, once, and nothing at all afterwards. It names every `-aowl.*`
    # token no loaded mod declared -- a misspelled argument announces itself
    # instead of doing nothing.
    caSweepTick()
    # HOST-NATIVE AUTO-RAID. Rides THIS drain (TarkovApplication::Update ticks
    # the whole session, including the matchmaker screens that are up before the
    # main menu's PreloaderUI can be assumed), not a second detour. Default OFF
    # (uxAutoRaid); idle cost is two integer compares and no call into the game.
    dpT = cDpNow()
    autoRaidDrainTick()
    cDpAdd(DpAutoRaid, dpT)
    # NATIVE RAID ENTRY. Rides THIS drain too, and takes `regs` because on this
    # anchor RCX IS the `TarkovApplication` -- the receiver its two getters
    # need. No GameObject is found and none is pressed. Both its flags default
    # OFF (`uxNativeRaid` probe, `uxNativeRaidDrive` write+press); idle cost is
    # two integer compares and no call into the game.
    dpT = cDpNow()
    nativeRaidDrainTick(regs)
    cDpAdd(DpNatRaid, dpT)
    # THE NATIVE uGUI ESP. Rides THIS drain as well -- it installs no detour of
    # its own, because a second detour on one function overwrites the first's
    # trampoline and silently kills it. Its whole body is inside ONE
    # `aowl_p_p_seh` opened by `aowl_ne_tick_guarded`, so this call site opens
    # none (the guard is not re-entrant). Flag `natEsp`, default OFF; idle cost
    # is one compare and no call into the game.
    # THE SHARED RAID PHASE. Must run BEFORE `natEspDrainTick`, which reads the
    # verdict it caches. Read-only, its own single `aowl_p_p_seh`, no detour.
    # Unconditional on purpose: every consumer gate depends on it, and a gate
    # that silently reads a stale phase because a flag was off is the failure
    # mode this whole change exists to remove. Idle cost when no world is
    # cached is one guarded pointer test plus one scene-name query per second.
    dpT = cDpNow()
    rpDrainTick()
    cDpAdd(DpRaidPhase, dpT)
    # THE RAID-LOAD TIMELINE. Rides THIS drain; installs no detour of its own
    # here (its 33 detours are on the load path, not on Update) and opens no
    # guard, because it reads no game memory. It exists on this drain only so
    # that every string it prints is built OUTSIDE a detour handler. Flag
    # `loadPerf`, default OFF; idle cost with the flag off is one bool test.
    lpDrainTick()
    # THE CAMERA API. Rides THIS drain; installs no detour of its own. Must run
    # AFTER `rpDrainTick`, because the free camera's end-of-raid exit reads the
    # phase that call just computed -- reading a one-frame-stale phase is
    # exactly how an overlay ends up on the results screen. Its whole body is
    # inside ONE `aowl_p_p_seh` opened by `aowl_cam_tick_guarded`, so this call
    # site opens none. Flags `cameraApi` / `cameraFreeCam`, both default OFF;
    # idle cost with both off is one integer compare and no call into the game.
    dpT = cDpNow()
    camDrainTick()
    cDpAdd(DpCam, dpT)
    # IN-RAID ACTUATION OF THE LOCAL PLAYER. Rides THIS drain; the only detour
    # it owns is the read-only GamePlayerOwner capture. Must run AFTER
    # `rpDrainTick`, whose DEPLOYED verdict it reads as a CACHED value -- it
    # never re-evaluates the phase, because its own body is already inside ONE
    # `aowl_p_p_seh` (`aowl_pact_tick_guarded`) and that guard is not
    # re-entrant. Flag `playerActuation`, default OFF; idle cost with it off is
    # one boolean compare and no call into the game.
    pactDrainTick()
    dpT = cDpNow()
    natEspDrainTick()
    cDpAdd(DpNatEsp, dpT)
    # THE NATIVE COLOUR WIDGET's pointer poll. Rides THIS drain for the same
    # reason everything above it does -- a second detour on
    # TarkovApplication::Update would overwrite the first's trampoline and
    # silently kill it. Its whole body is inside ONE `aowl_p_p_seh` opened by
    # `aowl_cw_tick_guarded`, so this call site opens none: the guard is not
    # re-entrant and a nested inner guard disarms the outer one.
    #
    # This is the ONLY pointer poll in the host. `nativeui.nim`'s INPUT section
    # has prescribed polling since it was written and had no pointer source at
    # all -- `nuHitTest` had zero call sites -- so this is the half that makes
    # a built control usable rather than merely visible.
    #
    # Flag `settingsColorWidget`, default OFF; idle cost is one boolean compare
    # and no call into the game.
    dpT = cDpNow()
    cwDrainTick()
    # THE NATIVE INVENTORY / ITEM-SPAWNER SCREEN. Rides THIS drain for exactly
    # the reason the colour widget above does, and its whole body is inside the
    # ONE `aowl_p_p_seh` that `aowl_iu_tick_guarded` opens -- so this call site
    # opens none. It shares the colour widget's profiler bucket rather than
    # claiming a new one: both are the same phase (native UI polled off the
    # Unity drain) and a bucket per feature would make the decomposition wider
    # without making it more informative.
    #
    # Flag `nativeInvUi`, default OFF; idle cost is one boolean compare and no
    # call into the game.
    iuDrainTick()
    cDpAdd(DpCw, dpT)
    # THE POSITIVE CONTROL and the throttled report, LAST, after every rider so
    # the report reads this frame's accumulation rather than the previous
    # frame's. The control is 512 integer adds through the same bracket on the
    # same clock: without it "the meter is lying" cannot be ruled out, and one
    # such control disproved a standing theory in the session that produced
    # this file. `dpReport` allocates a string, but only once every 5s and off
    # every frame in between -- the per-frame path here is two QPC reads.
    dpControl()
    dpReport()
    return 0'i32
  # The render-phase drain, likewise by identity: a second detour on a
  # render-phase method that drains the render queue where GL drawing lands.
  if i == gRenderDrainSlot:
    # The render drain's three riders are bracketed on the SAME accumulators as
    # the update drain's, so one line ranks all seventeen rows together. The
    # frame edge is NOT taken here -- `aowl_dp_frame` is called only from the
    # update drain, once per frame, so the denominator stays one interval per
    # frame even though this branch fires on the same frame.
    var dpR = cDpNow()
    renderDrain()
    cDpAdd(DpRDrain, dpR)
    # RE-CLOBBER THE CURSOR at end of frame, AFTER the game's Update-time re-lock.
    # The update-drain branch above frees/holds at the PREFIX of
    # TarkovApplication::Update, which in a raid runs BEFORE the game re-locks --
    # so it lost the per-frame race (reasserts climbed while current stayed
    # Locked/hidden). The render drain (OnRenderObject/OnPostRender) is the last
    # main-thread point in the frame, so a reassert here wins. It opens its own
    # single guard, exactly like cursorFreeDrainTick, and is inert unless a panel
    # is open and the update tick is already holding.
    dpR = cDpNow()
    cursorFreeRenderReassert()
    cDpAdd(DpRCursor, dpR)
    # RE-ASSERT THE FREE CAMERA POSE for the identical reason, and it is the
    # same race: the update drain is a PREFIX on TarkovApplication::Update, so
    # the game's own camera drive (a LateUpdate) runs after it and wins. This
    # is the last main-thread point in the frame. Its own single guard; inert
    # unless the free camera is actually active. Whether it is enough is NOT
    # assumed -- `camCheckHold` reads the position back next frame and reports
    # PASS/FAIL/INCONCLUSIVE in `camStatus`.
    dpR = cDpNow()
    camRenderTick()
    cDpAdd(DpRCam, dpR)
    return 0'i32
  # Experiment A: the read-only settings probe, likewise by identity.
  if i == gSettingsSlot:
    settingsProbeFired(regs)
    return 0'i32
  # SHOW-EVENT hooks (uihooks.nim) that were bound as a PREFIX rather than a
  # POSTFIX, by slot identity. Same handler, same contract, same `return 0`
  # (never suppress the original) as the postfix route in `patchReturned`.
  #
  # WHY BOTH ROUTES EXIST. A uihooks site is bound PREFIX when its compiled
  # call uses more than four register slots, because the postfix thunk calls
  # the original from inside its own frame and the original would then read
  # that frame where its STACK arguments belong -- measured 2026-09-02 on site
  # 2, `MenuScreen::Show(5-arg)`, whose fifth argument is the `Profile` that
  # `SeasonWidgetData::From` dereferences. See the banner in uihooks.nim.
  #
  # A prefix firing is EARLIER than a postfix one -- the body has not run yet.
  # `uihShowFired` reads only RCX (the receiver, which the thunk saves on both
  # paths) and the stack arguments, so it is correct on either route; a
  # subscriber that needs the body to have finished must say so itself.
  if uihIsSlot(i):
    uihShowFired(i, regs)
    return 0'i32
  # READ-ONLY GameWorld bot/player census, likewise by identity: it enumerates
  # the registered players and only logs -- it must never suppress the original.
  if i == gBotDiagSlot:
    botDiagRegisterFired(regs)
    return 0'i32
  # THE TRUE DEPLOY SIGNAL, by identity. These run INSIDE
  # `EFT.GameWorld::OnGameStarted`; the handler reads no register and touches no
  # game memory, so it needs no guard of its own, and it must never suppress the
  # original subscriber (which is real gameplay audio).
  if i == gRpStartSlotA:
    rpStartFired(regs, 0'i32)
    return 0'i32
  if i == gRpStartSlotB:
    rpStartFired(regs, 1'i32)
    return 0'i32
  # PLAYER ACTUATION's receiver capture, by identity. It stores ONE register
  # value and returns; it writes no game state and must never suppress the
  # original LateUpdate.
  if i == gPactOwnerSlot:
    pactOwnerFired(regs)
    return 0'i32
  # OFFLINE SCAV-CAP LIFT: the one-shot BotSpawner.MaxBots=0 poke, by identity. It
  # writes one int32 and must never suppress the original AddPlayer.
  if i == gBotCapSlot:
    botCapAddPlayerFired(regs)
    return 0'i32
  # IN-GAME ERROR DIALOG, by identity. Three overloads, one shared read-only
  # body; the slot is what tells them apart. Each returns 0 and MUST never
  # suppress the original -- the window still has to come up for the person at
  # the keyboard. We are only adding an observer.
  if i == gErrDlgMsgSlot:
    errDlgFired(regs, gErrDlgRow[0])
    return 0'i32
  if i == gErrDlgExcSlot:
    errDlgFired(regs, gErrDlgRow[1])
    return 0'i32
  if i == gErrDlgCritSlot:
    errDlgFired(regs, gErrDlgRow[2])
    return 0'i32
  # BOT AI ACTIVATION RESCUE: the per-bot WeaponManager.IsReady poke, by identity.
  # It writes one byte and must never suppress the original PreActivate.
  # NATIVE TABS: which of OUR tab toggles was pressed, by identity. Read-only,
  # O(<=4) pointer compares, silent for every foreign toggle -- and every
  # toggle in the game funnels through here, so that matters. Must never
  # suppress the original: the game's own toggle logic has to run.
  # THE VALUE-BINDING DRAINS (settingsbind.nim). Both read-only, both by slot
  # IDENTITY rather than by scanning, both returning 0 so the original always
  # runs. `Slider::Set` fires for EVERY slider in the game, so this branch must
  # stay a compare and a return: `sbdSliderSetFired` is one flag test and at
  # most SbdMaxRows pointer compares with no dereference.
  if i == gSbdSlotSlider:
    sbdSliderSetFired(regs)
    return 0'i32
  if i == gSbdSlotSave:
    sbdSaveFired()
    return 0'i32
  if i == gNtToggleSlot:
    ntToggleSetFired(regs)
    return 0'i32
  # THE SETTINGS CLOSE, PREFIX half, by identity. This is the LAST moment every
  # object of ours and every stock list that references one are both still
  # alive: `CloseAll` runs a few instructions later and Destroys the rows in
  # each tab's `_createdControls`. Read-only with respect to the game's own
  # state except for the unregister, which is the game's own
  # `Toggle::SetToggleGroup(null)`. Never suppresses the original.
  if i == gNtCloseSlot:
    ntSettingsCloseEntered(regs)
    return 0'i32
  # THE RAID-LOAD TIMELINE, PREFIX half. Mirrored from `patchReturned` because
  # loadperf's table is MIXED: three of its 33 rows use more than four register
  # slots (ProfileDataLoader::Apply 6, TarkovApplication::LoadMapAndData 7,
  # InGameMemoryManagement::Collect 6) and are therefore bound PREFIX -- a
  # postfix there would make the ORIGINAL read its stack arguments out of the
  # thunk's frame. `lpSlotFired` matches by SLOT identity and a slot is only
  # ever one edge or the other, so no row is stamped twice for one call. The
  # handler reads no register and touches no game memory, and returns 0 always.
  if lpSlotFired(int32(i)):
    return 0'i32
  # SKIP THE MODE SCREEN: the two READ-ONLY captures, by identity, both host
  # drains (meth == nil). Both return 0: neither ever changes what the caller
  # gets and neither suppresses its original. The selection screen is allowed
  # to build itself completely and is dismissed from a LATER frame by the drain
  # tick.
  #
  # THEY ARE PREFIXES, AND THAT IS NOT A PREFERENCE. MEASURED 2026-09-02 from
  # the metadata: `CharacterSelectionScreen::ShowSlot` @0x13EFAE0 takes 4
  # declared arguments, so its compiled call uses SIX register slots, and
  # `CharacterSelectionScreenController::.ctor` @0x13F0530 takes 6, so it uses
  # EIGHT. Past four, arguments arrive ON THE STACK, and the postfix thunk
  # `sub`s its own frame before `call`ing the original -- the original would
  # then read those arguments out of the thunk's frame. That is exactly the
  # crash that killed three boots through `EFT.UI.MenuScreen::Show(5-arg)`.
  # These two were bound POSTFIX for as long as this feature has existed;
  # `attachDrain`'s gate now refuses that shape outright, so they could not be
  # bound that way again even by accident.
  #
  # NOTHING EITHER HANDLER READS IS LOST BY FIRING AT ENTRY. The .ctor handler
  # compares `this` (RCX) by pointer identity and dereferences nothing, so it
  # does not care whether the fields are initialised yet -- it uses the pointer
  # as an identity token for "a NEW screen exists", which is true from the
  # first instruction. The ShowSlot handler takes RCX (screen), RDX (slot
  # view), R8 (gameMode) and R9 (profileData) -- all four are in registers on
  # both paths -- and the fields it then reads, `_gameMode`@0x160 and
  # `_profileData`@0x178, are read off the SLOT VIEW THE CALLER HANDED IN,
  # which the caller populated BEFORE the call. `ShowSlot` is that view's
  # consumer, not its producer.
  if i == gModeSkipCtorSlot:
    modeSkipCtorFired(regs)
    return 0'i32
  if i == gModeSkipShowSlot:
    modeSkipShowSlotFired(regs)
    return 0'i32
  # FEATURE F2, and the ONE place this host suppresses an original on the
  # boot path. `modeSkipTryCreateFired` returns 1 only after its guarded body
  # has actually WRITTEN a 24-byte CharacterSelectionResult built from the
  # game's own dictionary -- a fault, an unreadable dictionary, a failed
  # self-check or a non-writable out-param all return 0 and let the original
  # run, which shows the screen. Suppression with an unfilled result is
  # unreachable by construction: the write happens before the flag is set.
  #
  # PREFIX, and not by preference either: the whole point is to decide whether
  # the original runs at all. It is also STATIC with two declared arguments,
  # i.e. THREE register slots (data, &result, MethodInfo*), so nothing of it
  # ever lives on the caller's stack and `attachDrain`'s postfix gate is not
  # in question.
  if i == gModeSkipTryCreateSlot:
    return modeSkipTryCreateFired(regs)
  if i == gBotAiSlot:
    botAiPreActivateFired(regs)
    return 0'i32
  # NATIVE BOT NAVIGATION API: the per-bot registry refresh + nav-command service
  # tick, by identity. It records the bot, and issues at most one throttled
  # GoToPoint/StopMove/SetTargetMoveSpeed -- and must never suppress the original
  # UpdateManual, which is the bot's entire brain.
  if i == gBotNavSlot:
    botNavUpdateFired(regs)
    return 0'i32
  # Phase 1 native-settings probe: the read-only control-tree walk, by identity.
  if i == gSettingsUiSlot:
    settingsUiProbeFired(regs)
    return 0'i32
  # Phase 1.7 control poll: a throttled Unity-thread heartbeat, read-only.
  if i == gSettingsSelSlot:
    settingsTickFired(regs)
    return 0'i32
  # THE DEBUG OVERLAY, by identity and before anything generic: it fires once a
  # frame, so it must not walk the patch table to find itself. It draws into UI
  # objects it cloned and never suppresses PreloaderUI's own Update.
  #
  # THIS IS THE SHARED `EFT.UI.PreloaderUI::Update` HOOK. The debug overlay and
  # the menu mode-text feature both want that function, and two detours on one
  # function have the second overwrite the first's trampoline. So there is only
  # ever ONE detour on it: whichever feature arms first claims the slot, and the
  # other rides on it by ALIASING its own slot global to the same number (see
  # `bindDebugUi` / `bindModeText`). Dispatch is therefore "call every rider
  # whose slot matches", not "else if" -- when both are on, `gDebugUiSlot ==
  # gModeTextSlot` and both handlers run from this one firing. A slot global
  # that is still -1 can never match a claimed slot, so a feature that is off
  # costs one integer compare. Neither handler ever suppresses the original.
  #
  # THE LIVE INSPECTOR is the THIRD rider on that same function. It is listed
  # in the same `or` chain and dispatched by the same "every rider whose slot
  # matches" rule, so `debugUi`, `uxMenuModeText` and `liveInspector` can all
  # be on at once over ONE detour and ONE trampoline. Its per-frame cost when
  # no command is queued is a single interlocked load (`aowl_insp_have`).
  if i == gDebugUiSlot or i == gModeTextSlot or i == gInspSlot or
     i == gCodeGenProbeSlot or i == gModsSlot or i == gRegionSlot or
     i == gSplPreloaderSlot:
    if not gSharedRidersLoggedPf:
      gSharedRidersLoggedPf = true
      logSharedRiders("patchFired", i)
    # THE FRAME BOUNDARY for the profiler. This block is the shared
    # `EFT.UI.PreloaderUI::Update` rider chain -- exactly once per frame while
    # the preloader ticks -- so it is where a frame is closed and, every
    # `windowFrames`, every slot's window is rolled. `profFrameTick` costs one
    # volatile load when the profiler is off, which is the shipped default. It
    # installs NO detour: it rides the chain that already exists, per the
    # two-detours-one-trampoline rule.
    profFrameTick()
    # THE DURABLE PRELOADER ANCHOR for the singleplayer rebrand. RCX here is the
    # live `PreloaderUI` for every slot in this block (they all ride
    # `EFT.UI.PreloaderUI::Update`), and this `this` -- unlike the Awake `this`
    # in `gVerPreloader` -- belongs to the DontDestroyOnLoad menu scene the
    # offline-raid screen lives in. Captured every frame, ungated, so it holds
    # the CURRENT live object regardless of the liveInspector flag. One register
    # read and one store; no call into the game, no allocation.
    block:
      let splPre = cast[Il2CppPtr](cRegsInt(regs, 0'i32))
      if splPre != nil:
        gSplUpdatePreloader = splPre
    if i == gDebugUiSlot:
      cProfBegin(profSlotDebugUi)
      debugUiFired(regs)
      cProfEnd(profSlotDebugUi)
    if i == gModeTextSlot:
      cProfBegin(profSlotModeText)
      modeTextUpdateFired(regs)
      cProfEnd(profSlotModeText)
    if i == gInspSlot:
      cProfBegin(profSlotInspect)
      inspectFired(regs)
      cProfEnd(profSlotInspect)
    if i == gCodeGenProbeSlot:
      cProfBegin(profSlotCodeGen)
      codeGenProbeFired()
      cProfEnd(profSlotCodeGen)
    # THE MODS TAB, the fifth rider. Aliased onto whichever slot was claimed, so
    # it costs one integer compare when it is off and never a second detour.
    if i == gModsSlot:
      cProfBegin(profSlotModsTab)
      modsRidersTick(regs)
      cProfEnd(profSlotModsTab)
    # THE SHARED REGION, and the generic one: it dispatches every mod that
    # registered a draw or tick callback. LAST in the chain on purpose --
    # the hand-written riders above it predate it and keep their existing
    # ordering, so arming the region cannot reorder anything that already
    # works. It opens NO guard of its own here; see `region.nim`.
    if i == gRegionSlot:
      cProfBegin(profSlotRegion)
      regionFired(regs)
      cProfEnd(profSlotRegion)
    return 0'i32
  # The overlay's GameWorld cache: one register read, nothing walked, never a
  # suppression of RegisterPlayer.
  if i == gDebugEspSlot:
    debugEspRegisterFired(regs)
    return 0'i32
  if i < 0 or i >= gPatches.len:
    return 0'i32
  if not gPatches[i].live:
    return 0'i32
  if gPatches[i].isPostfix:
    # A postfix does its work in `patchReturned`, and the thunk branches on the
    # engine's own table before it gets here, so this is unreachable while the
    # two agree. It is checked anyway: if they ever disagreed, running a postfix
    # handler as a prefix would hand it a `result` from the previous call.
    return 0'i32
  gPatchFires = gPatchFires + 1
  if gPatches[i].typed:
    return typedFire(i, regs, false)

  var argsText = ""
  # Where the handle table stood before the arguments were described, so the
  # handles describing them can be given back afterwards. Every reference
  # argument costs a GC handle, and a handler that forgot to release one would
  # pin one object per call -- on a method the game runs per frame per bot,
  # that is a leak measured in objects per second. Expecting a mod to remember
  # on that path is not a contract, it is a trap.
  # The one place the firing path touches a shared table, and the one place it
  # takes the lock. `describeArgs` registers a GC handle per reference argument
  # and appends each to the table, which a mod's worker thread may be appending
  # to at the same moment. It is affordable *here* and nowhere else on this
  # path: the JSON hook already costs some 625 ns a firing, so a critical
  # section is a percent or two of it, where on the typed path -- 23 ns, and no
  # handles at all -- it would be most of the cost.
  tablesLock()
  let handleMark = gHandles.len
  if gPatches[i].wantArgs and gPatches[i].meth != nil:
    argsText = describeArgs(gRt, gPatches[i].meth, regs,
                            gHandles, gHandleIsObject, gHandleGc)
  let handleTop = gHandles.len
  tablesUnlock()
  gPatchPayloadBytes = gPatchPayloadBytes + int64(argsText.len)
  gPatchHandlesTaken = gPatchHandlesTaken + int64(handleTop - handleMark)

  var replacement = ""
  let st = fireHandler(i, argsText, handleMark, handleTop, replacement)

  if st != PatchSkipStatus:
    return 0'i32
  if not gPatches[i].canSkip:
    # Asked to skip without having registered for it. Refused rather than
    # honoured: the mod believes it is a prefix that suppresses, and finding out
    # here beats finding out from a game that behaves strangely.
    return 0'i32
  if gPatches[i].meth == nil:
    return 0'i32
  if not applyPatchReturn(gRt, gPatches[i].meth, regs,
                          (if replacement.len > 0: replacement else: "null")):
    return 0'i32
  result = 1'i32

proc patchReturned(slot: int32; regs: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch_returned", cdecl.} =
  ## The postfix half, called from the thunk **after** the original returned,
  ## still on the game thread and still inside the patched call.
  ##
  ## `regs` holds the argument registers saved on entry, plus what the original
  ## produced: RAX at `ret` and XMM0 at `retf`. Returns 0 to hand the caller
  ## what the original produced and 1 to hand it what the handler wrote instead.
  ##
  ## The payload is the prefix payload with one member added:
  ##
  ##     {"this":{...},"args":[...],"result":6.0}
  ##     {"result":6.0}                            -- no AOWLSPT_PATCH_ARGS
  ##
  ## `result` is always there, whether or not the patch asked for arguments: it
  ## is one value read out of a register, it costs no GC handle unless the
  ## method returns a reference, and it is the reason a postfix exists at all.
  ## The arguments stay opt-in for the reason they always were -- building that
  ## array inside a method the game runs thousands of times a frame is the
  ## expensive half.
  ##
  ## The arguments reported are the **entry** values, because that is where they
  ## still exist: the registers were saved on the way in and the original has
  ## since had its way with everything else. Harmony's postfix has the same
  ## property for by-value parameters and this host cannot do better.
  let i = int(slot)
  # The version-brand postfix, by identity, before the generic postfix path --
  # it is a host drain (meth == nil), so it must be handled here rather than
  # falling through to the meth-driven code below.
  if i == gVersionSlot:
    versionBrandFired(regs)
    return 0'i32
  # SKIP THE MODE SCREEN's two captures USED TO BE DISPATCHED HERE, as
  # POSTFIXES. They are PREFIXES now and live in `patchFired`; see the banner
  # there and `attachDrain`'s postfix gate for why (6 and 8 register slots).
  # THE RAID-LOAD TIMELINE, by slot identity and before anything else that
  # could allocate. Its handler reads NO register and touches NO game memory --
  # one timestamp and one interlocked counter -- so it needs no guard, and it
  # returns 0 always: a postfix drain that never changes what the caller gets.
  if lpSlotFired(int32(i)):
    return 0'i32
  # THE DEPLOY-ORDER BREADCRUMB, by slot identity and for the identical reason:
  # its handler reads NO register and touches NO game memory (one array
  # compare, one timestamp, two counters), so it needs no guard, and it returns
  # 0 always -- a postfix drain that never changes what the caller gets. With
  # `natespDeployProbe` off, `gNdpBound` is 0 and this costs one compare.
  if ndpSlotFired(int32(i)):
    return 0'i32
  # THE NATIVE MOD-LOAD STEP's read-only drains, by slot identity and for the
  # same reason: the handler reads at most ONE register and passes it to a
  # VirtualQuery-guarded C decoder, dereferences no game pointer itself, and
  # allocates nothing on the Nim heap -- so it needs no guard, and it returns
  # 0 always. With `modLoadNative` off `gMlnBound` is 0 and this is one
  # compare.
  if mlnSlotFired(int32(i), regs):
    return 0'i32
  # THE SETTINGS CLOSE, POSTFIX half, on the OTHER function: `CloseAll`
  # returned. Its handler reads no register and touches no game memory -- one
  # counter and one flag -- so it needs no guard, and it returns 0 always.
  if i == gNtCloseAllSlot:
    ntSettingsCloseAllReturned()
    return 0'i32
  # The menu mode-text postfix, by identity and for the same reason: a host
  # drain (meth == nil) on `PreloaderUI::Update`. Returns 0 -- it never changes
  # what the caller gets, it only calls a setter the game already has.
  #
  # The SHARED `PreloaderUI::Update` hook again, mirrored from `patchFired`. The
  # engine routes a given slot to exactly one of the two halves depending on the
  # postfix flag it was attached with, so at most one of these two dispatch
  # points ever fires for a given slot -- but which one depends on which feature
  # armed first (the overlay attaches prefix, mode-text attaches postfix), so
  # both riders must be dispatchable from both halves. `regs` carries the
  # argument registers saved on ENTRY in either half, so RCX is the PreloaderUI
  # `this` here exactly as it is in the prefix.
  #
  # THE LIVE INSPECTOR is the third rider and is listed here for exactly the
  # same reason. It attaches PREFIX when it claims the slot itself, but when it
  # ALIASES onto a slot the mode-text feature already claimed, that slot is a
  # POSTFIX slot -- so this is the only half that ever fires for it, and leaving
  # it out here would silently kill the inspector in precisely the arming order
  # (mode-text first, inspector second) that the multiplex exists to tolerate.
  if i == gModeTextSlot or i == gDebugUiSlot or i == gInspSlot or
     i == gModsSlot or i == gRegionSlot or i == gSplPreloaderSlot:
    if not gSharedRidersLoggedPr:
      gSharedRidersLoggedPr = true
      logSharedRiders("patchReturned", i)
    # The frame boundary again -- see the prefix half. Only ONE of the two
    # halves ever fires for a given slot (the engine routes on the postfix
    # flag), so this cannot double-count a frame.
    profFrameTick()
    # THE DURABLE PRELOADER ANCHOR for the singleplayer rebrand. RCX here is the
    # live `PreloaderUI` for every slot in this block (they all ride
    # `EFT.UI.PreloaderUI::Update`), and this `this` -- unlike the Awake `this`
    # in `gVerPreloader` -- belongs to the DontDestroyOnLoad menu scene the
    # offline-raid screen lives in. Captured every frame, ungated, so it holds
    # the CURRENT live object regardless of the liveInspector flag. One register
    # read and one store; no call into the game, no allocation.
    block:
      let splPre = cast[Il2CppPtr](cRegsInt(regs, 0'i32))
      if splPre != nil:
        gSplUpdatePreloader = splPre
    if i == gDebugUiSlot:
      cProfBegin(profSlotDebugUi)
      debugUiFired(regs)
      cProfEnd(profSlotDebugUi)
    if i == gModeTextSlot:
      cProfBegin(profSlotModeText)
      modeTextUpdateFired(regs)
      cProfEnd(profSlotModeText)
    if i == gInspSlot:
      cProfBegin(profSlotInspect)
      inspectFired(regs)
      cProfEnd(profSlotInspect)
    if i == gModsSlot:
      cProfBegin(profSlotModsTab)
      modsRidersTick(regs)
      cProfEnd(profSlotModsTab)
    if i == gRegionSlot:
      cProfBegin(profSlotRegion)
      regionFired(regs)
      cProfEnd(profSlotRegion)
    return 0'i32
  # Phase 1.5 native-settings control probe, by identity and for the same reason:
  # a host drain (meth == nil) whose whole point is to read AFTER the original
  # ran, because the original is what builds the tab's controls. Returns 0, so
  # the caller gets exactly what the game produced -- this never changes a result.
  if i == gSettingsTabSlot:
    settingsTabInitFired(regs)
    return 0'i32
  # SHOW-EVENT hooks (uihooks.nim), by slot identity and on the same terms: a
  # host drain (meth == nil) that must run AFTER the original, because the
  # original is what shows the screen. Returns 0 -- it never changes what the
  # game produced. `uihIsSlot` is a two-entry scan, not a table lookup, so an
  # unbound site cannot alias another feature's slot.
  if uihIsSlot(i):
    uihShowFired(i, regs)
    return 0'i32
  # Phase 1.6 control census, same reasoning: a host drain (meth == nil) that
  # must read AFTER the original ran, because the original is what creates the
  # controls. Returns 0 -- this never changes a result.
  # The direct-invocation proof ladder, by identity and on the same terms: a
  # host drain (meth == nil) that must run AFTER the original, because the
  # original is what builds the controls the ladder clones. Returns 0 -- it
  # never changes what the game produced.
  if i == gMi2Slot:
    mi2LadderFired(regs)
    return 0'i32
  if i < 0 or i >= gPatches.len:
    return 0'i32
  if not gPatches[i].live:
    return 0'i32
  gPatchFires = gPatchFires + 1
  if gPatches[i].typed:
    # BEFORE the MethodInfo gate below, deliberately. A patch installed by RVA
    # has no MethodInfo and never will -- and this gate used to sit above the
    # typed dispatch, so an RVA postfix would have been installed, reported
    # "patched", and then returned 0 on every single firing without a word.
    # That is the silent decline this host exists not to produce. The typed
    # path reads only `kinds`/`retKind`/`frameFlags`, all of which the RVA spec
    # declared at registration, so it is complete without one.
    return typedFire(i, regs, true)
  if gPatches[i].meth == nil:
    # The JSON path genuinely cannot run without one: `describeReturn` and
    # `applyPatchReturn` both ask the runtime for the declared types.
    # `installPatch` refuses that combination at registration, so reaching
    # here means a drain row, not a mod's patch.
    return 0'i32

  # As on the prefix path: the whole of the table-touching part under the lock,
  # and nothing else.
  tablesLock()
  let handleMark = gHandles.len
  var payload = ""
  # A reference return costs a GC handle exactly as a reference argument does,
  # so the result is described inside the same mark/top bracket and reclaimed by
  # the same cleanup.
  let resultText = describeReturn(gRt, gPatches[i].meth, regs,
                                  gHandles, gHandleIsObject, gHandleGc)
  if gPatches[i].wantArgs:
    let argsText = describeArgs(gRt, gPatches[i].meth, regs,
                                gHandles, gHandleIsObject, gHandleGc)
    # `describeArgs` ends in `}`; the result goes in beside `this` and `args`
    # rather than wrapping them, so a handler reads one object either way and
    # `"args"` still means the declared parameters and nothing else.
    payload = argsText.substr(0, argsText.len - 2) & ",\"result\":" &
              resultText & "}"
  else:
    payload = "{\"result\":" & resultText & "}"
  let handleTop = gHandles.len
  tablesUnlock()
  gPatchPayloadBytes = gPatchPayloadBytes + int64(payload.len)
  gPatchHandlesTaken = gPatchHandlesTaken + int64(handleTop - handleMark)

  var replacement = ""
  let st = fireHandler(i, payload, handleMark, handleTop, replacement)

  if st != PatchSkipStatus:
    return 0'i32
  # No `canSkip` gate here, and that asymmetry is deliberate. A prefix skip from
  # a patch that never asked for arguments is almost always a misregistration --
  # the mod thinks it is suppressing and is not. A postfix replacement cannot be
  # that mistake: the handler was handed the original's answer and returned a
  # different one, which is unambiguous whichever way it registered.
  if not applyPatchReturn(gRt, gPatches[i].meth, regs,
                          (if replacement.len > 0: replacement else: "null")):
    # The declared return type is one no value could be built for. The
    # original's answer stands, which is the only safe way to be wrong here.
    return 0'i32
  result = 1'i32

# ----------------------------------------------- codeGenModule code pointers

proc cCodeGenReady(): int32 {.importc: "aowl_codegen_ready", nodecl.}
proc cCodeGenLookup(imageName: Il2CppPtr; token: uint32): Il2CppPtr {.
  importc: "aowl_codegen_lookup", nodecl.}
proc cCodeGenReason(): int32 {.importc: "aowl_codegen_reason", nodecl.}
proc cCodeGenReasonStr(): Il2CppPtr {.importc: "aowl_codegen_reason_str", nodecl.}
proc cCodeGenModules(): int32 {.importc: "aowl_codegen_modules", nodecl.}
proc cCodeGenValidNames(): int32 {.importc: "aowl_codegen_valid_names", nodecl.}
proc cCodeGenNoteAgreement(live, resolved: Il2CppPtr): int32 {.
  importc: "aowl_codegen_note_agreement", nodecl.}
proc cCodeGenAgreeSame(): int32 {.importc: "aowl_codegen_agree_same", nodecl.}
proc cCodeGenAgreeDiff(): int32 {.importc: "aowl_codegen_agree_diff", nodecl.}
proc cCodeGenWaiting(): int32 {.importc: "aowl_codegen_waiting", nodecl.}
proc cCodeGenAttempts(): int32 {.importc: "aowl_codegen_attempts", nodecl.}
proc cCodeGenWaits(): int32 {.importc: "aowl_codegen_waits", nodecl.}

proc hexOf(v: uint64): string =
  ## Lowercase hex of a machine word, no `0x`. A local helper because a live
  ## MethodInfo dump wants pointer values and the codebase's other hex writers
  ## are fixed-width session ids. Defined here rather than beside the deep-probe
  ## because `resolveCodeGen`, above `installPatch`, logs RVAs with it.
  const digits = "0123456789abcdef"
  if v == 0'u64:
    return "0"
  var x = v
  var s = ""
  while x > 0'u64:
    s = $digits[int(x and 0xF'u64)] & s
    x = x shr 4
  return s

## THE TYPED STORE PATH. Included HERE, before every site that stores into
## game-owned memory, because Nim's `include` is textual and botcap/botai/
## nativeui all come below. It depends on nothing above except `Il2CppPtr`,
## `hexOf`, `okLog` and `warn`. Defines `frStore*`/`frRecvOk`/`frAdmit` over the
## GENERATED `abi/aowlspt_fieldrefs.h`. See INTERACTION-LAYER-MAP M3/M6.
include "hostfieldwrite.nim"

var gCodeGenRefusals = 0
const CodeGenRefusalCap = 24
  ## Self-limiting log, not self-disabling behaviour: the walk itself cannot
  ## fault (every hop is a VirtualQuery, nothing is called), so there is no
  ## fault count to disable on. What is capped is the NOISE, so a mod that
  ## registers many patches on a build without this table does not fill the log
  ## with one identical sentence per patch.

proc codeGenReason(): string =
  result = readCString(cCodeGenReasonStr())
  if result.len == 0:
    result = "reason " & $int(cCodeGenReason())

proc codeGenRefuse(msg: string) =
  ## One place for every decline, so none of them can be silent and none of them
  ## can flood. Rule 6 of the host discipline in one proc.
  if gCodeGenRefusals < CodeGenRefusalCap:
    inc gCodeGenRefusals
    warn msg
    if gCodeGenRefusals == CodeGenRefusalCap:
      warn "codeGen: further resolution refusals will not be logged (cap " &
           $CodeGenRefusalCap & " reached)"

proc probeMethodInfoSpans(m: Il2CppMethod): string =
  ## Which parts of a MethodInfo are readable, field-sized rather than
  ## blanket. DIAGNOSTIC ONLY -- it gates nothing.
  ##
  ## This exists to settle, from the client itself, why a blanket 0x48 check
  ## rejected six MethodInfos at 1.1s that were fine at 46s. If the small spans
  ## pass while the 0x48 span fails, the cause is region-boundary contiguity,
  ## not an invalid handle. If they all fail, the metadata really was not mapped
  ## yet. The log now carries the evidence either way instead of an assertion.
  if m == nil:
    return "handle=nil"
  result = ""
  var offs: seq[int32] = @[]
  offs.add 0'i32; offs.add 0x08'i32; offs.add 0x10'i32; offs.add 0x18'i32
  offs.add 0x20'i32; offs.add 0x28'i32; offs.add 0x40'i32
  for o in offs:
    let p = cast[Il2CppPtr](cast[uint](m) + uint(o))
    result.add "+" & hexOf(uint64(o)) & "="
    result.add (if cIsReadable(p, 8'i32) != 0'i32: "r" else: "-")
    result.add " "
  result.add "span0x48=" &
             (if cIsReadable(m, 0x48'i32) != 0'i32: "r" else: "-")

proc resolveCodeGen(m: Il2CppMethod; spec: string; verbose: bool): Il2CppPtr =
  ## The compiled address of `m` out of its OWN image's
  ## `Il2CppCodeGenModule.methodPointers`, or nil with a logged reason.
  ##
  ## The RID is derived from the `MethodInfo` the caller was ALREADY handed, via
  ## `il2cpp_method_get_token`. It is never re-derived from a name lookup, which
  ## is what keeps overload resolution self-consistent: `AssetBundle::LoadAsset`
  ## has two overloads at 0x5250100 and 0x5250340 and `findMethod(.., -1)` picks
  ## one of them; whichever it picked is the one whose token this reads.
  ##
  ## Every hop through the metadata is guarded inside `aowlspt_codegen.h` by
  ## `aowl_is_readable` (a VirtualQuery), so nothing here can fault and nothing
  ## here needs -- or takes -- an `aowl_p_p_seh`, which matters because that
  ## guard is not re-entrant and a caller may already be inside one.
  result = cast[Il2CppPtr](0)
  if m == nil:
    return
  # A blanket `cIsReadable(m, 0x48)` USED TO GATE THIS PATH. It was wrong twice
  # over and it produced a confidently wrong verdict on the live client: at
  # 1.125s it declared all six probe targets "MethodInfo is NOT READABLE",
  # including `AssetBundle::LoadAsset`, whose MethodInfo the textures mod then
  # read successfully at 46.156s in the same process.
  #
  # Wrong reason one: NOTHING ON THIS PATH DEREFERENCES THE MethodInfo. The
  # class and the token both come from exported runtime calls
  # (`il2cpp_method_get_class`, `il2cpp_method_get_token`). The only raw read is
  # `methodPointer`'s own 8 bytes at offset 0, and that guards itself. A 0x48
  # requirement gated a struct span this code never touches.
  #
  # Wrong reason two: `aowl_is_readable` requires the whole span inside ONE
  # committed region, so a MethodInfo sitting near a region boundary fails a
  # 0x48 check while every field this code uses is perfectly readable.
  #
  # So the guard is now sized to what is actually dereferenced -- 8 bytes, the
  # same span `methodPointer` requires -- and the "is this really a MethodInfo"
  # question is a SEPARATE, per-field, diagnostic-only probe that does not gate
  # anything. Classification never blocks resolution again.
  if cIsReadable(m, 8'i32) == 0'i32:
    codeGenRefuse("codeGen: cannot resolve " & spec &
                  " -- even the first 8 bytes of its MethodInfo are " &
                  "unreadable, so the handle is not a struct at all. Spans: " &
                  probeMethodInfoSpans(m))
    return
  if cCodeGenReady() == 0'i32:
    # Two very different states, and they used to print the same sentence.
    # `waiting` means GameAssembly.dll is not mapped yet -- the host calls in at
    # DLL-attach, ~1s before il2cpp comes up -- and the table will be retried on
    # the next call. Anything else means the module IS mapped and the table
    # really did not validate, which is a fact about the build.
    if cCodeGenWaiting() != 0'i32:
      if verbose:
        info "codeGen: " & spec & " not resolved yet -- GameAssembly.dll is " &
             "not mapped at this point in boot (attempt " &
             $int(cCodeGenAttempts()) & ", " & $int(cCodeGenWaits()) &
             " so far too early). This is NOT a verdict on the build; the " &
             "table is re-checked on every later call."
    else:
      codeGenRefuse("codeGen: cannot resolve " & spec &
                    " -- GameAssembly.dll IS mapped but its codeGenModules " &
                    "table did not validate: " & codeGenReason())
    return
  if not gRt.has(eClassGetImage) or not gRt.has(eMethodGetToken):
    codeGenRefuse("codeGen: cannot resolve " & spec &
                  " -- this runtime exports no il2cpp_class_get_image / " &
                  "il2cpp_method_get_token")
    return

  # method -> declaring class -> image -> image NAME. All three are exported
  # runtime calls, so no struct offset is assumed anywhere on this path.
  let cls = gRt.methodClass(m)
  if cls == nil:
    codeGenRefuse("codeGen: cannot resolve " & spec &
                  " -- il2cpp_method_get_class returned null")
    return
  let img = gRt.classGetImage(cls)
  if img == nil:
    codeGenRefuse("codeGen: cannot resolve " & spec &
                  " -- il2cpp_class_get_image returned null for its " &
                  "declaring type")
    return
  var imageName = gRt.imageGetName(img)
  if imageName.len == 0:
    codeGenRefuse("codeGen: cannot resolve " & spec & " -- its image has no name")
    return

  let token = gRt.methodToken(m)
  let rid = token and 0xFFFFFF'u32
  if rid == 0'u32:
    codeGenRefuse("codeGen: cannot resolve " & spec &
                  " -- its metadata token has a zero RID")
    return

  let fn = cCodeGenLookup(cast[Il2CppPtr](toCString(imageName)), token)
  if fn == nil:
    codeGenRefuse("codeGen: cannot resolve " & spec & " in " & imageName &
                  " (token rid " & $int(rid) & "): " & codeGenReason())
    return

  if verbose:
    okLog "codeGen: " & spec & " -> il2cpp+0x" &
          hexOf(uint64(cIl2cppRvaOf(fn))) & " via " & imageName &
          " methodPointers[" & $int(rid - 1'u32) & "]"
  return fn

var gCodeGenAuditNotes = 0
const CodeGenAuditNoteCap = 16

proc codeGenAuditNote(msg: string) =
  ## A capped channel for "the audit could not run", kept separate from
  ## `codeGenRefuse` so that a boot which is merely EARLY cannot exhaust the
  ## resolver's refusal budget and mask a later real refusal.
  if gCodeGenAuditNotes < CodeGenAuditNoteCap:
    inc gCodeGenAuditNotes
    info msg
    if gCodeGenAuditNotes == CodeGenAuditNoteCap:
      info "codeGen audit: further \"cannot compare\" notes suppressed (cap " &
           $CodeGenAuditNoteCap & ")"

proc auditCodeGen(m: Il2CppMethod; spec: string; live: Il2CppPtr) =
  ## READ-ONLY. With a live `methodPointer` in hand, resolve the same method the
  ## other way and say whether they agree. Nothing is patched either way.
  ##
  ## This exists because the tree contains two notes that contradict each other:
  ## `bindMainDrain` records that a static RVA out of this table bound "a real
  ## function that Unity never reached as Update" and crashed the client, while
  ## the static-RVA block below it says the address is "now KNOWN correct" and
  ## the crash "unexplained". Nobody has re-tested it. An agreement count from
  ## the live client settles it at zero risk, which is the cheapest honest
  ## answer available.
  if not gCodeGenAudit:
    return
  # Every early return below announces itself. The first version of this proc
  # returned silently whenever the table was not ready, and because the table
  # was latched-unavailable from DLL-attach that meant a full boot with
  # `codeGenAudit` on produced its banner and then NOTHING -- no AGREES, no
  # DISAGREES, no reason. A diagnostic that can produce zero output is not a
  # diagnostic, and this one is the instrument the codeGenResolve decision was
  # supposed to rest on.
  if m == nil or live == nil:
    codeGenAuditNote("codeGen audit: cannot compare " & spec &
                     " -- no MethodInfo or no live methodPointer to compare " &
                     "against (this target was bound by verified static RVA, " &
                     "not by name, so there is nothing on the runtime side)")
    return
  let resolved = resolveCodeGen(m, spec, false)
  if resolved == nil:
    codeGenAuditNote("codeGen audit: cannot compare " & spec &
                     " -- the codeGenModule side produced nothing: " &
                     (if cCodeGenWaiting() != 0'i32:
                        "GameAssembly.dll is not mapped yet (too early in " &
                        "boot; this will be retried)"
                      else: codeGenReason()))
    return
  if cCodeGenNoteAgreement(live, resolved) != 0'i32:
    okLog "codeGen audit: " & spec & " AGREES (methodPointer == " &
          "methodPointers[rid-1] == il2cpp+0x" &
          hexOf(uint64(cIl2cppRvaOf(live))) & "); running totals same=" &
          $int(cCodeGenAgreeSame()) & " diff=" & $int(cCodeGenAgreeDiff())
  else:
    warn "codeGen audit: " & spec & " DISAGREES -- methodPointer=il2cpp+0x" &
         hexOf(uint64(cIl2cppRvaOf(live))) & " but methodPointers[rid-1]=" &
         "il2cpp+0x" & hexOf(uint64(cIl2cppRvaOf(resolved))) &
         "; the table does NOT hold the live pointer on this build, so " &
         "codeGenResolve must stay OFF. Running totals same=" &
         $int(cCodeGenAgreeSame()) & " diff=" & $int(cCodeGenAgreeDiff())

# --------------------------------------------------------------------------
# PATCH BY VERIFIED STATIC RVA
# --------------------------------------------------------------------------
#
# WHY THIS EXISTS. On build 1.1.0.1.46777 by-name resolution is dead, and not
# in the "returns nil" way that a caller can branch on: `findClass` and
# `findMethod` both return NON-NIL handles into UNMAPPED memory. Measured in
# one boot by a two-thread controlled experiment -- host thread tid 25552 and
# the Unity main thread tid 24416, riding the debug overlay's real
# `PreloaderUI::Update` detour -- both reporting `6 probed, 6 with an
# unreadable MethodInfo, 0 comparable`. It is not thread-dependent. So
# `methodPointer(gRt, m)` can never work here, and neither can any fallback
# that needs a valid `MethodInfo`.
#
# What DOES work, measured live: a plain static RVA. So a caller may name the
# address outright, and this is the machinery that accepts one safely.
#
# THE SHAPE PROBLEM, AND WHY THE CALLER MUST DECLARE IT. `installPatch`
# normally derives `frameKinds`, `retKind`, `methodIsStatic` and
# `postfixRefusal` from the `MethodInfo`. With no `MethodInfo` those are simply
# unavailable, and a postfix that GUESSES the frame shape is a silently wrong
# hook -- worse than no hook, because it looks installed. So the shape is
# DECLARED in the spec, and an RVA patch whose shape was not declared is
# REFUSED. There is no default.

type
  RvaSpec = object
    ## The parse of an `@0xRVA` patch spec. `isRva` says the caller asked for
    ## one at all; `why` non-empty says the request was malformed and names
    ## how. The two are independent: a spec can be an RVA spec AND be wrong.
    isRva: bool
    why: string
    name: string          ## the `Type::Method` part, for logs only
    rva: uint32
    isStatic: bool
    kinds: seq[uint8]
    retKind: uint8
    retBig: bool          ## declared `V`: a value return wider than a register
    sig: array[16, uint8]
    siglen: int32

proc argLetterKind(c: char; ok: var bool): uint8 =
  ok = true
  case c
  of 'i': result = AkInt
  of 'f': result = AkFloat
  of 'd': result = AkDouble
  of 'o': result = AkObject
  of 'v': result = AkValue
  of 'V': result = AkBigValue
  of 'x': result = AkVoid
  else:
    ok = false
    result = AkUnknown

proc hexNibble(c: char; ok: var bool): int =
  ok = true
  if c >= '0' and c <= '9': return ord(c) - ord('0')
  if c >= 'a' and c <= 'f': return 10 + ord(c) - ord('a')
  if c >= 'A' and c <= 'F': return 10 + ord(c) - ord('A')
  ok = false
  result = 0

const RvaSpecGrammar =
  "Type::Method@0xRVA/<shape>[!<hex prologue>] where <shape> is 'i' or 's' " &
  "(instance or static), then one letter per DECLARED argument " &
  "(i=integer/bool/char, f=float, d=double, o=object/string/reference, " &
  "v=small value type, V=value type wider than a register), then '>' and one " &
  "return letter (the same set, plus x=void). Example: " &
  "UnityEngine.AssetBundle::LoadAsset@0x5250100/io>o"

proc parseRvaSpec(spec: string): RvaSpec =
  ## Splits an `@0xRVA` spec. Every rejection says which part was wrong and
  ## repeats the grammar, because a mod author reading a refusal in the log has
  ## nothing else to go on.
  result = RvaSpec(isRva: false, why: "", name: "", rva: 0'u32,
                   isStatic: false, kinds: @[], retKind: AkUnknown,
                   retBig: false,
                   sig: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                   siglen: 0'i32)
  let at = find(spec, "@0x")
  if at < 0:
    return
  result.isRva = true
  result.name = spec.substr(0, at - 1)
  if result.name.len == 0:
    result.why = "patch-by-RVA: nothing before the @0x in " & spec &
                 "; the Type::Method part is required (it is what the log " &
                 "calls the patch). Grammar: " & RvaSpecGrammar
    return
  var rest = spec.substr(at + 3)

  # Optional trailing signature: the prologue bytes the caller asserts. Taken
  # off FIRST, so a stray slash inside it could never be read as the shape
  # separator.
  let bang = find(rest, "!")
  if bang >= 0:
    let hx = rest.substr(bang + 1)
    rest = rest.substr(0, bang - 1)
    if hx.len == 0 or (hx.len and 1) == 1:
      result.why = "patch-by-RVA " & result.name & ": the prologue signature " &
                   "must be an EVEN number of hex digits, got " & $hx.len &
                   ". Grammar: " & RvaSpecGrammar
      return
    let nbytes = hx.len div 2
    if nbytes > 16:
      result.why = "patch-by-RVA " & result.name & ": the prologue signature " &
                   "is " & $nbytes & " bytes; the snapshot holds 16, so more " &
                   "than 16 cannot be verified and is refused rather than " &
                   "silently truncated."
      return
    for k in 0 ..< nbytes:
      var okHi = false
      var okLo = false
      let hi = hexNibble(hx[k * 2], okHi)
      let lo = hexNibble(hx[k * 2 + 1], okLo)
      if not okHi or not okLo:
        result.why = "patch-by-RVA " & result.name & ": the prologue " &
                     "signature contains a non-hex character at byte " & $k
        return
      result.sig[k] = uint8(hi * 16 + lo)
    result.siglen = int32(nbytes)

  # The shape.
  var shape = ""
  let slash = find(rest, "/")
  if slash >= 0:
    shape = rest.substr(slash + 1)
    rest = rest.substr(0, slash - 1)

  # The RVA itself.
  if rest.len == 0 or rest.len > 8:
    result.why = "patch-by-RVA " & result.name & ": " & rest &
                 " is not 1..8 hex digits of RVA. Grammar: " & RvaSpecGrammar
    return
  var v = 0'u32
  for k in 0 ..< rest.len:
    var okD = false
    let d = hexNibble(rest[k], okD)
    if not okD:
      result.why = "patch-by-RVA " & result.name & ": " & rest &
                   " is not hex. Grammar: " & RvaSpecGrammar
      return
    v = v * 16'u32 + uint32(d)
  if v == 0'u32:
    result.why = "patch-by-RVA " & result.name &
                 ": an RVA of 0 is the module header, not code."
    return
  result.rva = v

  # THE REFUSAL THAT MATTERS. No shape, no patch -- see the block above.
  if shape.len == 0:
    result.why = "patch-by-RVA " & result.name & " (il2cpp+0x" &
                 hexOf(uint64(v)) & "): REFUSED because no frame shape was " &
                 "declared. There is no MethodInfo behind an RVA on this " &
                 "build, so the host cannot derive whether the method is " &
                 "static, what its arguments are, or what it returns -- and " &
                 "guessing any of those installs a hook that is silently " &
                 "wrong rather than absent. Declare it: " & RvaSpecGrammar
    return
  if shape[0] == 's':
    result.isStatic = true
  elif shape[0] == 'i':
    result.isStatic = false
  else:
    result.why = "patch-by-RVA " & result.name & ": the shape must start " &
                 "with i (instance) or s (static), got " & $shape[0] &
                 ". Grammar: " & RvaSpecGrammar
    return
  let gt = find(shape, ">")
  if gt < 0 or gt != shape.len - 2:
    result.why = "patch-by-RVA " & result.name & ": the shape must end with " &
                 "> and exactly one return letter, got " & shape &
                 ". Grammar: " & RvaSpecGrammar
    return
  # Declared arguments. Capped at 16 -- far past the four register slots any
  # patched call can use, and a bound rather than an unbounded loop over a
  # caller-supplied string.
  let nargs = gt - 1
  if nargs > 16:
    result.why = "patch-by-RVA " & result.name & ": " & $nargs &
                 " declared arguments is past this host's cap of 16."
    return
  for k in 1 ..< gt:
    var okL = false
    let kd = argLetterKind(shape[k], okL)
    if not okL or kd == AkVoid:
      result.why = "patch-by-RVA " & result.name & ": " & $shape[k] &
                   " is not an argument letter. Grammar: " & RvaSpecGrammar
      return
    # Exactly `frameKinds`' rule, so argument n is declared parameter n
    # whatever the shape: past the fourth register position it is AkStack.
    let pos = (if result.isStatic: k - 1 else: k)
    if pos >= MaxRegArgs:
      result.kinds.add AkStack
    else:
      result.kinds.add kd
  var okR = false
  let rk = argLetterKind(shape[shape.len - 1], okR)
  if not okR:
    result.why = "patch-by-RVA " & result.name & ": " &
                 $shape[shape.len - 1] & " is not a return letter. " &
                 "Grammar: " & RvaSpecGrammar
    return
  result.retKind = rk
  result.retBig = rk == AkBigValue

proc rvaPostfixRefusal(rs: RvaSpec): string =
  ## The same two refusals `postfixRefusal` makes, decided from the DECLARED
  ## shape instead of from a `MethodInfo`. Same reasons, same consequences:
  ## both would install cleanly and be wrong at run time.
  if rs.retBig:
    return "a postfix on " & rs.name & " is refused: it was declared to " &
           "return a value type wider than a register (V), which Win64 " &
           "returns through a caller-allocated buffer. The host cannot read " &
           "that buffer's layout, so a postfix there could neither report " &
           "the result nor replace it. Use a prefix that suppresses."
  for k in 0 ..< rs.kinds.len:
    if rs.kinds[k] == AkStack:
      return "a postfix on " & rs.name & " is refused: declared argument " &
             $k & " lands on the stack, and a postfix has to CALL the " &
             "original from inside the thunk's own frame, where the " &
             "original would read the wrong address for it."
  let slots = rs.kinds.len + 1 + (if rs.isStatic: 0 else: 1)
  if slots > PostfixMaxSlots:
    return "a postfix on " & rs.name & " is refused: its compiled call uses " &
           $slots & " register slots (" & $rs.kinds.len &
           " declared argument(s)" &
           (if rs.isStatic: "" else: ", plus this") &
           ", plus IL2CPP's trailing MethodInfo*), and past " &
           $PostfixMaxSlots & " they arrive on the stack."
  result = ""

proc resolveByRva*(rva: uint32; sig: var array[16, uint8]; siglen: int32;
                   label: string; why: var string): Il2CppPtr =
  ## THE ADDRESS-SUBSTITUTION MECHANISM. Given a module-relative RVA, hand back
  ## a code pointer that has passed every check, or nil with `why` naming the
  ## check that failed.
  ##
  ## Deliberately takes an RVA and nothing else, so that any resolver which has
  ## one -- a spec's `@0x`, or a build-time name->RVA index -- goes through the
  ## same four gates rather than each growing its own.
  ##
  ## The checks, in order, and each one refuses out loud:
  ##   MODULE BASE    -- GameAssembly.dll mapped; base read at runtime (ASLR).
  ##   CODE PAGE      -- committed, executable, 16 whole bytes in one region.
  ##   IL2CPP SECTION -- inside the `il2cpp` PE section, where generated code
  ##                     lives. `.text` holds no managed method bodies.
  ##   PROLOGUE       -- the declared bytes against the STARTUP SNAPSHOT.
  ##
  ## The prologue check is against the snapshot, never live memory: verifying
  ## after another feature patched the same function reads that feature's
  ## trampoline and self-rejects a perfectly correct RVA.
  why = ""
  result = cast[Il2CppPtr](0)
  let base = cGaBase()
  if base == 0'u64:
    why = "patch-by-RVA " & label & ": check MODULE BASE failed -- " &
          "GetModuleHandleA(GameAssembly.dll) returned NULL, so there is " &
          "no base to add 0x" & hexOf(uint64(rva)) & " to. Nothing patched."
    return
  if cRvaIsCode(rva) == 0'i32:
    why = "patch-by-RVA " & label & ": check CODE PAGE failed -- " &
          "GameAssembly+0x" & hexOf(uint64(rva)) & " (base 0x" &
          hexOf(base) & ") is not committed executable memory with 16 whole " &
          "bytes in one region. Nothing patched."
    return
  let p = cRvaCodeAt(rva)
  if p == nil:
    why = "patch-by-RVA " & label & ": check CODE PAGE failed -- the address " &
          "could not be formed. Nothing patched."
    return
  if cInIl2cpp(p) == 0'i32:
    why = "patch-by-RVA " & label & ": check IL2CPP SECTION failed -- 0x" &
          hexOf(uint64(rva)) & " is outside GameAssembly.dll's il2cpp PE " &
          "section (0x628000, 0x510FA6C bytes), which is where every AOT " &
          "managed method body lives. An RVA in .text is a native runtime " &
          "function, not the method you named. Nothing patched."
    return
  if siglen > 0'i32:
    if cProVerify(rva, addr sig[0], siglen) == 0'i32:
      why = "patch-by-RVA " & label & ": check PROLOGUE failed -- the " &
            "ORIGINAL bytes at il2cpp+0x" & hexOf(uint64(rva)) &
            " (the startup SNAPSHOT, not live memory, so another feature's " &
            "trampoline cannot be what was read) do not match the " &
            $int(siglen) & "-byte signature the caller declared. This is " &
            "either the wrong RVA or a different game build. Nothing patched."
      return
    okLog "patch-by-RVA " & label & ": prologue VERIFIED, " & $int(siglen) &
          " byte(s), against the startup snapshot at il2cpp+0x" &
          hexOf(uint64(rva)) & " (base 0x" & hexOf(base) & ")"
  else:
    # Never a green light from a comparison that compared nothing.
    warn "patch-by-RVA " & label & ": NO prologue signature was declared, so " &
         "NOTHING was byte-compared. il2cpp+0x" & hexOf(uint64(rva)) &
         " passed the module, code-page and il2cpp-section checks only. " &
         "Append the !<hex> suffix to the spec to have its original bytes " &
         "verified."
  result = p
## ## The offline name index
##
## `aowlspt_nameindex.h` holds the argument; this is the Nim face of it. It
## answers exactly one question -- "what RVA does this name have" -- from a file
## generated on the build machine, and it touches nothing in IL2CPP.
##
## It is NOT a binder. Turning an RVA into something safe to patch means the
## prologue byte-verify against the startup snapshot, the `VirtualQuery` and the
## il2cpp-section check, and that mechanism is owned by the by-RVA path. There
## is no second copy of it here, on purpose.
proc cNameIdxInit(dir: cstring): int32 {.importc: "aowl_nameidx_init", nodecl.}
proc cNameIdxReady(): int32 {.importc: "aowl_nameidx_ready", nodecl.}
  ## NOT a plain getter: ready means the build stamp has been VERIFIED
  ## against the mapped GameAssembly.dll, and asking re-attempts that
  ## verification if the module was not mapped when the file was read.
proc cNameIdxStaged(): int32 {.importc: "aowl_nameidx_staged", nodecl.}
proc cNameIdxCount(): int32 {.importc: "aowl_nameidx_count", nodecl.}
proc cNameIdxReason(): cstring {.importc: "aowl_nameidx_reason", nodecl.}
proc cNameIdxImageKey(): uint64 {.importc: "aowl_nameidx_imagekey", nodecl.}
proc cNameIdxLookup(spec: cstring; arity: int32): uint32 {.
  importc: "aowl_nameidx_lookup", nodecl.}
proc cNameIdxLookupShared(spec: cstring; arity: int32;
                          shareOut: ptr uint32): uint32 {.
  importc: "aowl_nameidx_lookup_shared", nodecl.}
  ## Same search, and it also hands back the entry's SHARE COUNT.
  ##
  ## 0 is UNKNOWN and is what every failure path leaves behind -- it is never
  ## "unshared". 1 is "this method only". >= 2 is how many methods the IL2CPP
  ## backend folded onto this one address, and a detour there fires for all of
  ## them.

var gNameIndex = false
var gNameIdxMisses = 0
const NameIdxMissCap = 32

## Sharedness, in the three values the whole policy turns on.
const ShareUnknown = 0'u32

proc nameIndexRva(spec: string; arity: int32; share: var uint32): uint32 =
  ## The RVA for `spec`, or 0. `arity` is -1 for "the only overload", which
  ## answers ONLY where the generator found exactly one -- an overloaded name
  ## like `UnityEngine.AssetBundle::LoadAsset` (0x5250100 and 0x5250340) returns
  ## 0 here rather than picking one, and the caller must say which it means.
  ##
  ## Every refusal names the check that declined, and the misses are capped so a
  ## mod retrying a bad name cannot fill the log.
  ##
  ## `share` is written on EVERY path, and every failure path leaves it
  ## `ShareUnknown` -- so a caller that forgets to look cannot be handed a
  ## default that reads as "safe to detour".
  share = ShareUnknown
  if not gNameIndex:
    return 0'u32
  if cNameIdxReady() == 0'i32:
    if gNameIdxMisses < NameIdxMissCap:
      inc gNameIdxMisses
      warn "name index: cannot answer " & spec &
           " -- the index is not usable: " & $cNameIdxReason()
    return 0'u32
  # `toCString` wants a mutable string, and the C side only reads it.
  var key = spec
  var sh = ShareUnknown
  result = cNameIdxLookupShared(toCString(key), arity, addr sh)
  share = sh
  if result == 0'u32 and gNameIdxMisses < NameIdxMissCap:
    inc gNameIdxMisses
    warn "name index: no entry for " & spec & " at arity " &
         (if arity < 0: "any" else: $int(arity)) &
         ". Either it is absent from this build, or the name is OVERLOADED " &
         "(the any-arity form is only emitted where there is exactly one " &
         "overload) -- name the arity explicitly. Or it was DROPPED at " &
         "generation because two types gave the same name two different RVAs, " &
         "in which case there is no correct answer to give."

proc sharedRefusal(spec: string; rva: uint32; share: uint32): string =
  ## The sentence a refused PATCH target gets. Empty means "go ahead".
  ##
  ## Two refusals, and they are deliberately different sentences, because they
  ## are different facts and a reader must not have to guess which one happened.
  if share == ShareUnknown:
    return "name index: REFUSING to patch " & spec & " at il2cpp+0x" &
           hexOf(uint64(rva)) & " -- SHAREDNESS IS UNKNOWN for this entry. " &
           "That is NOT a statement that the address is unshared: absence of " &
           "evidence is not evidence of uniqueness, and 28.3% of exact keys " &
           "on this build land on an RVA that several methods share. A " &
           "detour installed here would fire for every one of them. Only a " &
           "share count of exactly 1 permits a patch; regenerate the index " &
           "with tools/il2cpp_nameindex.py gen if this entry has none."
  if share >= 2'u32:
    return "name index: REFUSING to patch " & spec & " at il2cpp+0x" &
           hexOf(uint64(rva)) & " -- SHARED RVA: " & $int(share) &
           " methods resolve to this one address, because the IL2CPP backend " &
           "folded their identical bodies together. A detour is a WRITE, and " &
           "its blast radius is all " & $int(share) & " of them; nothing at " &
           "run time can tell one caller from another. A direct CALL here is " &
           "still correct for the receiver you pass -- only patching is " &
           "refused. Append !shared to the spec to override this deliberately."
  return ""

proc nameIndexResolve(spec: string; arity: int32; forPatch: bool;
                      allowShared: bool; why: var string): Il2CppPtr =
  ## `spec` -> RVA -> a code pointer, by handing the RVA to the by-RVA binder,
  ## which owns prologue verification and the section checks.
  ##
  ## `forPatch` is the whole safety question. A DETOUR at an address several
  ## methods folded onto rewrites the first bytes of code that all of them run;
  ## a CALL at the same address is correct code for the receiver it is handed.
  ## So the refusal is attached to the purpose, not to the address, and callers
  ## must say which they are: there is no defaulted parameter here on purpose,
  ## so a new call site cannot inherit "patch is fine" by saying nothing.
  ##
  ## `when declared` rather than a call: the by-RVA binder is landing on a
  ## parallel branch. Until it is present ABOVE this point in the file, this
  ## compiles to the refusal below and says so with the RVA it found, so the
  ## index can be shown to be answering correctly before anything binds.
  result = cast[Il2CppPtr](0)
  why = ""
  var share = ShareUnknown
  let rva = nameIndexRva(spec, arity, share)
  if rva == 0'u32:
    return
  if forPatch:
    let refusal = sharedRefusal(spec, rva, share)
    if refusal.len > 0:
      if allowShared:
        warn "name index: OVERRIDE (!shared) on " & spec & " -- proceeding " &
             "with a patch the share check refused. " & refusal
      else:
        warn refusal
        why = refusal
        return cast[Il2CppPtr](0)
    else:
      info "name index: " & spec & " at il2cpp+0x" & hexOf(uint64(rva)) &
           " is reached by this method ONLY (share count 1), so a detour " &
           "here has no other callers to hit."
  # The seam. `resolveByRva` is defined ABOVE this proc in this same file, so
  # this branch is the live one -- the `else` arm exists only so a build that
  # somehow lacked the binder would REFUSE and say so rather than silently
  # resolving nothing. If you are ever unsure which arm compiled, the log line
  # names it: a live seam says "handing il2cpp+0x... to the by-RVA binder".
  when declared(resolveByRva):
    info "name index: " & spec & " -> il2cpp+0x" & hexOf(uint64(rva)) &
         "; handing it to the by-RVA binder for prologue/section verification"
    # No signature bytes: the index knows the address, not what the compiler
    # emitted there. `resolveByRva` therefore WARNS that nothing was
    # byte-compared, which is the honest state of a name-index resolution --
    # the module, code-page and il2cpp-section checks still all run.
    var sig: array[16, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                                 0, 0, 0, 0, 0, 0, 0, 0]
    var why = ""
    result = resolveByRva(rva, sig, 0'i32, spec, why)
    if result == nil:
      warn "name index: " & spec & " is at il2cpp+0x" & hexOf(uint64(rva)) &
           ", but the by-RVA binder REFUSED that address: " & why &
           " Nothing was patched."
  else:
    warn "name index: " & spec & " resolves to il2cpp+0x" & hexOf(uint64(rva)) &
         ", but this build of the host has no by-RVA binder linked in, so the " &
         "address is NOT being turned into a patch. This is a REFUSAL, not a " &
         "resolution failure: the index answered."

# The three gates a mod's patch-by-RVA passes after `resolveByRva` has answered
# everything about the ADDRESS and before anything is written: a declared
# prologue (so something was actually byte-compared), UNIQUE sharedness from the
# offline name index (shared and unknown are both refusals), and nobody already
# owning the function. Included HERE, not with the other feature modules at the
# bottom of this file, because `installPatch` below is its only caller and
# Nim resolves in order.
include "patchrva.nim"

proc installPatch(ctx: Il2CppPtr; target: Il2CppPtr; targetLen: int32;
                  kind: int32; cb: Il2CppPtr; user: Il2CppPtr;
                  typed: bool): int32 =
  ## Detours a compiled method, which is this side's answer to a Harmony patch.
  ##
  ## One body for both the JSON patch and the typed one, because everything
  ## about *installing* a detour is the same: the same name split, the same
  ## method lookup, the same code-pointer check, the same two postfix refusals,
  ## the same slot bookkeeping. Only what happens when it fires differs, and
  ## that is one field on `Patch`. Two copies of this would be two copies of the
  ## slot-ordering argument below, and one of them would eventually be wrong.
  ##
  ## `kind` carries two things: the patch kind in its low bits, and
  ## `AOWLSPT_PATCH_ARGS` (0x10) to ask for the original arguments. Arguments
  ## are opt-in because decoding them costs a JSON build inside a method the
  ## game may call thousands of times a frame, and a patch that only counts
  ## calls should not pay for that.
  ##
  ## A patch that asked for arguments may also return `PatchSkip` with a
  ## replacement result, and the original will not run.
  ##
  ## A **postfix** runs the other way round: the thunk calls the original,
  ## regains control, and hands the handler what it returned. Two method shapes
  ## cannot carry one and are refused here rather than installed and quietly
  ## useless -- see `postfixRefusal`.
  var spec = readBytes(target, targetLen)
  # THE SHARED-RVA OVERRIDE, taken off the spec before anything else parses it.
  #
  # `Ns.Type::Method!shared` says "I know this address is folded and I want the
  # detour anyway". It is a suffix on the SPEC rather than a host-wide flag
  # because the decision is per target: a config switch would arm every future
  # patch as well as the one the author was thinking about. It is only
  # meaningful on the by-name index path -- an @0x spec is already an explicit
  # address -- and it is logged loudly when it is used.
  var allowShared = false
  if spec.len > 7 and spec.substr(spec.len - 7) == "!shared":
    allowShared = true
    spec = spec.substr(0, spec.len - 8)
  if cb == nil:
    gLastError = "patch needs a handler"
    return ErrBadArg
  if not gReady:
    gLastError = "the IL2CPP runtime is not up yet"
    return ErrUnsupported

  # `kind` low bits are the patch kind.
  #
  # A prefix and a postfix are two different thunk paths rather than two
  # readings of one: a prefix tail-jumps into the trampoline, which is what
  # makes the original's return value, its stack arguments and its return
  # address correct by construction; a postfix has to *call* it and come back,
  # and pays for that with the two refusals below. Neither is ever silently
  # substituted for the other -- a postfix that behaved like a prefix would hand
  # a mod scaling a getter's result a value the original had not produced yet,
  # and the number it wrote would be wrong rather than absent.
  #
  # A finalizer is still refused, and not for want of machinery: its whole
  # contract is about the exception in flight, and an exception does not cross
  # this ABI in any form the other side could act on. An unwind out of the
  # original does not even reach the postfix path -- it skips the rest of the
  # thunk by definition -- so there is nothing here to build it out of.
  let patchKind = kind and 0x0F'i32
  let isPostfix = patchKind == 1'i32
  if patchKind != 0'i32 and not isPostfix:
    gLastError = "unsupported patch kind " & $int(patchKind) &
                 (if patchKind == 2'i32:
                    "; a finalizer patch is not bridged, because a managed " &
                    "exception cannot cross this ABI"
                  else: "")
    return ErrUnsupported

  # PATCH BY VERIFIED STATIC RVA -- decided BEFORE the name split.
  #
  # An `@0x` spec never needs a class or a method lookup, and on this build it
  # must not attempt one: `findClass` returns a NON-NIL handle into unmapped
  # memory, so "did the type resolve" has no honest answer here and a lookup
  # would only manufacture a confident wrong one.
  let rs = parseRvaSpec(spec)
  if rs.isRva and rs.why.len > 0:
    warn rs.why
    gLastError = rs.why
    return ErrBadArg

  var m: Il2CppMethod = cast[Il2CppMethod](0)
  var fn: Il2CppPtr = cast[Il2CppPtr](0)
  var kinds: seq[uint8] = @[]
  var retKind = 0'u8
  var frameFlags = 0'u32

  if rs.isRva:
    # An RVA patch has NO MethodInfo, and every JSON firing path needs one:
    # `describeArgs`, `describeReturn` and `applyPatchReturn` all ask the
    # runtime what the declared types are. So the JSON ABI is refused here
    # rather than installed and quietly handing a handler an empty payload --
    # which is exactly the silent decline this host must never produce. The
    # typed ABI needs only the declared shape, which the spec carries.
    if not typed:
      let whyJson = "patch-by-RVA " & rs.name & ": REFUSED on the JSON patch " &
                "ABI. Every JSON firing path (describeArgs, describeReturn, " &
                "applyPatchReturn) needs a MethodInfo to read the declared " &
                "types from, and an RVA has none -- installing anyway would " &
                "hand the handler an empty payload and call it a hook. Use " &
                "patch_typed / hookReturnTyped, which needs only the shape " &
                "the spec already declares."
      warn whyJson
      gLastError = whyJson
      return ErrUnsupported
    var sig = rs.sig
    var whyRva = ""
    fn = resolveByRva(rs.rva, sig, rs.siglen, rs.name, whyRva)
    if fn == nil:
      warn whyRva
      gLastError = whyRva
      return ErrUnsupported
    if isPostfix:
      let refusal = rvaPostfixRefusal(rs)
      if refusal.len > 0:
        warn refusal
        gLastError = refusal
        return ErrUnsupported
    # THE THREE GATES -- see patchrva.nim. After `resolveByRva`, because gate 3
    # relies on the snapshot row that the declared-prologue verify has just
    # captured and matched; before the slot claim, because a refusal must not
    # have consumed anything.
    let gate = rvaGateRefusal(rs, allowShared)
    if gate.len > 0:
      warn gate
      gLastError = gate
      return ErrUnsupported
    kinds = rs.kinds
    retKind = rs.retKind
    frameFlags = (if rs.isStatic: FrameFlagStatic else: 0'u32)
  else:
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
    m = findMethod(gRt, cls, member, -1)
    if m == nil:
      gLastError = "no method " & member & " on " & typePart
      return ErrNotFound

    # Resolution order, most-trusted first:
    #   1. `MethodInfo.methodPointer` -- the pointer the runtime itself holds and
    #      the game itself calls. Nothing beats it, so it is always tried first.
    #   2. the declaring image's `Il2CppCodeGenModule.methodPointers[rid-1]` --
    #      IL2CPP's own per-assembly code table, the same mechanism
    #      `tools/il2cpp_resolve.py` uses offline. Flag-gated, default OFF.
    #   3. refuse, naming which hop failed.
    #
    # There is deliberately no deep-scan step here: scanning a MethodInfo for
    # "some field that looks like code" is a guess, and `installPatch` is what
    # every mod's `patch`/`hookReturn` goes through. The drain binder keeps its
    # scan because it has a diagnostic purpose; a mod's patch does not.
    fn = methodPointer(gRt, m)
    if fn != nil:
      auditCodeGen(m, spec, fn)
    else:
      if gCodeGenResolve:
        fn = resolveCodeGen(m, spec, true)
      if fn == nil and gNameIndex:
        # Last, because it is the only source that does not consult the runtime
        # at all: an RVA frozen offline. It cannot be wrong about THIS build
        # without the build stamp having been wrong, and it is refused
        # wholesale if it is.
        #
        # A by-name PREFIX is complete from here -- it needs only the code
        # pointer. A by-name POSTFIX is NOT: `postfixRefusal`, `frameKinds`,
        # `methodReturnType` and `methodIsStatic` all still ask the runtime
        # about `m`, and `m` is exactly the unreadable handle that made the
        # index necessary. That is refused just below rather than guessed, and
        # the caller must declare the shape with an `@0xRVA/<shape>` spec.
        var whyShared = ""
        fn = nameIndexResolve(spec, -1'i32, true, allowShared, whyShared)
        if fn == nil and whyShared.len > 0:
          gLastError = whyShared
          return ErrUnsupported
        if fn != nil and isPostfix:
          let whyShape = "a POSTFIX on " & spec & " resolved through the name " &
                "index is refused: the index gives an address, not a frame " &
                "shape, and `postfixRefusal`/`frameKinds`/`methodReturnType`/" &
                "`methodIsStatic` all need the MethodInfo that does not read " &
                "on this build. Installing anyway would guess the frame shape, " &
                "which is a silently wrong hook rather than an absent one. " &
                "Declare it instead: " & spec & "@0x" & hexOf(uint64(cIl2cppRvaOf(fn))) &
                "/<shape> -- see the by-RVA grammar."
          warn whyShape
          gLastError = whyShape
          return ErrUnsupported
      if fn == nil:
        gLastError = "could not read a usable code pointer for " & spec &
                     " (methodPointer is null" &
                     (if gCodeGenResolve:
                        " and the codeGenModule fallback also declined: " &
                        codeGenReason()
                      else:
                        "; set codeGenResolve in aowlspt-host.json to try " &
                        "IL2CPP's own per-assembly methodPointers table") & ")"
        return ErrUnsupported

    # The two shapes a postfix cannot carry, checked against the method rather
    # than against the patch kind alone: a value-type return wider than a
    # register, which comes back through a buffer whose layout this host cannot
    # read, and a compiled call with stack arguments, which a called original
    # would look for in the thunk's frame. Both would install cleanly and be
    # wrong at run time. The RVA arm above makes the same two refusals from the
    # DECLARED shape instead.
    if isPostfix:
      let refusal = postfixRefusal(gRt, m, spec)
      if refusal.len > 0:
        gLastError = refusal
        return ErrUnsupported
    # The shapes, worked out once. This is the whole optimisation: `frameKinds`
    # asks the runtime what every parameter is, here, at registration -- and the
    # JSON path asks the same questions on every firing for an answer that
    # cannot have changed.
    kinds = frameKinds(gRt, m)
    retKind = argKindOf(gRt, methodReturnType(gRt, m))
    frameFlags = (if methodIsStatic(gRt, m): FrameFlagStatic else: 0'u32)

  # The slot comes from the engine, and it comes *first*.
  #
  # This used to be `gPatches.len` and a check afterwards that the engine had
  # agreed. It agreed because both counters only ever went up -- and that was
  # the bug rather than the invariant: removing a detour freed its trampoline
  # and put the method's bytes back, but neither the engine's slot nor this
  # table's row was ever spare again, so a mod switched off and on again spent
  # a slot each time and the sixteenth cycle was the end of patching for the
  # session. Now the engine hands out a reclaimed slot and this file writes the
  # row at that index, which makes the two agree by construction rather than by
  # a check that could only ever report the disagreement.
  # From here to the end of this proc, under the lock.
  #
  # A mod may call `patch` from any thread it likes, and the host's own tick
  # thread may be taking another mod's detours out at the same moment: the
  # engine's free list, its generation table and this file's row for the slot
  # are three structures that have to move together, and two threads claiming
  # slots at once would interleave through all three. It is not on the firing
  # path -- installing a detour happens at human rates -- so this is the cheap
  # half of the bargain the block at the top of this file describes.
  tablesLock()
  let claimed = cHookClaim()
  if claimed < 0'i32:
    tablesUnlock()
    gLastError = "no free patch slots (" & $int(cHookCapacity()) &
                 " in use); every one of them belongs to a live patch"
    return ErrUnsupported

  let hook = cHookNew()
  if hook == nil:
    cHookRelease(claimed)
    tablesUnlock()
    gLastError = "out of memory"
    return ErrGeneric

  var targetBytes = newSeq[byte](spec.len + 1)
  for k in 0 ..< spec.len:
    targetBytes[k] = byte(spec[k])
  targetBytes[spec.len] = 0'u8
  # `AOWLSPT_PATCH_ARGS` is not consulted for a typed patch, and a typed prefix
  # may always suppress. Both because the flag exists to avoid a cost that does
  # not arise here: the arguments are in the frame whether or not anybody reads
  # them, so there is no "registered without arguments" state for a suppression
  # to be a mistake about.
  let wantArgs = (not typed) and (kind and 0x10'i32) != 0'i32
  # The row is written before the hook lands, never after, and at the slot the
  # engine handed out. The table is grown with dead rows where it has to be:
  # the engine may hand back slot 3 while this table is two rows long, and a
  # row that is not there when the thunk fires is a firing that indexes past
  # the end.
  while gPatches.len <= int(claimed):
    gPatches.add deadPatch()
  gPatches[int(claimed)] = Patch(hook: hook, cb: cb, user: user, target: spec,
                     targetC: targetBytes, live: false, meth: m,
                     wantArgs: wantArgs, canSkip: wantArgs or typed,
                     modIndex: int(cast[uint](ctx)), isDrain: false,
                     isPostfix: isPostfix, typed: typed, kinds: kinds,
                     retKind: retKind, frameFlags: frameFlags)
  # Armed before the hook lands, never after. The thunk reads the engine's
  # table on entry and the game can reach the patched method on the very next
  # instruction, so a postfix armed a moment late would run its first firings as
  # a prefix -- and a prefix handler that was written as a postfix reads a
  # `result` that does not exist yet.
  cHookSetPostfix(claimed, (if isPostfix: 1'i32 else: 0'i32))
  let rc = cHookAttachAt(hook, fn, claimed)
  if rc != 0'i32:
    cHookSetPostfix(claimed, 0'i32)
    gPatches[int(claimed)] = deadPatch()
    cHookFree(hook)
    cHookRelease(claimed)
    tablesUnlock()
    gLastError = "could not patch " & spec & ": " &
                 readCString(cHookErrorText(rc))
    return ErrGeneric

  let slot = claimed
  gPatches[int(slot)].live = true
  tablesUnlock()
  okLog "patched " & spec & " (" & $int(cHookStolen(hook)) & " bytes" &
        (if isPostfix: ", postfix" else: "") &
        (if typed: ", typed" else: "") & ")"
  result = StatusOk

proc hostPatch(ctx: Il2CppPtr; target: Il2CppPtr; targetLen: int32;
               kind: int32; cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch", cdecl.} =
  ## `AowlHostApi.patch`: the handler is handed a JSON description of the
  ## firing.
  installPatch(ctx, target, targetLen, kind, cb, user, false)

proc hostPatchTyped(ctx: Il2CppPtr; target: Il2CppPtr; targetLen: int32;
                    kind: int32; cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch_typed", cdecl.} =
  ## `AowlHostApi.patch_typed` (ABI revision 4): the handler is handed a
  ## borrowed view of the registers instead.
  ##
  ## A separate export rather than a flag on `hostPatch`, because `cb` is a
  ## different function-pointer shape -- an `AowlTypedPatchFn` takes two
  ## parameters where an `AowlPatchFn` takes four -- and the two are both
  ## `void*` by the time they reach this file. Getting that wrong would be a
  ## handler reading its frame out of a register nobody set, so the distinction
  ## is made where the type still exists: in `aowlspt_live.h`, on the way in.
  installPatch(ctx, target, targetLen, kind, cb, user, true)

proc attachDrain(spec: string; fn: Il2CppPtr; meth: Il2CppMethod;
                 perFrame: bool; verbose: bool; kind: int32;
                 postfix: bool = false; slots: int32 = -1'i32): bool =
  ## Installs one of the host's own detours on the code pointer `fn`, through the
  ## same slot table and detour engine a mod's `patch` uses. Shared by the update
  ## drain, the render drain and the settings probe: the verified static targets
  ## from `aowlspt_bridge.h` (where `meth` is nil, since the firing path indexes
  ## by slot and never reads it) and the by-name candidates (where `meth` is the
  ## resolved `MethodInfo`).
  ##
  ## `slots` IS THE POSTFIX SAFETY ARGUMENT, and it is what makes a whole class
  ## of crash impossible here rather than by convention. It is how many REGISTER
  ## SLOTS the compiled call uses: `this` (none for a static), the declared
  ## arguments, and IL2CPP's trailing `MethodInfo*`. Past `PostfixMaxSlots` the
  ## remaining arguments arrive ON THE STACK, and the postfix thunk in
  ## `aowlspt_detour.h` `sub`s its own frame before `call`ing the original --
  ## so the original reads those arguments out of the THUNK'S frame.
  ##
  ## MEASURED 2026-09-02: a postfix on `EFT.UI.MenuScreen::Show(5-arg)` (7
  ## slots) made the original read its fifth argument, `profile`, from
  ## `[entry_rsp+0x28]`, which under the thunk's `sub rsp,0x98` is the slot the
  ## thunk parks RAX in -- value 1. Three consecutive boots died in
  ## `SeasonWidgetData::From` with `Rcx=1`, a Profile that was the integer 1.
  ##
  ## `invoke.nim`'s `postfixRefusal` has encoded this rule for a MOD's patch
  ## since it was written, but it was applied only in `hostPatch`; `attachDrain`
  ## trusted each caller's `postfix` flag, so the host bound the one detour its
  ## own engine documents as impossible. It is applied HERE now, at the single
  ## chokepoint every host detour passes through, which is the only place a
  ## caller cannot forget it.
  ##
  ## Three states, never two:
  ##   * `slots >= 1` and `<= PostfixMaxSlots` -- a postfix is bound.
  ##   * `slots > PostfixMaxSlots`             -- REFUSED, loudly.
  ##   * `slots < 1` with `postfix = true`     -- UNDECLARED, also REFUSED.
  ## "I could not look" is not a pass: a caller that does not know its target's
  ## shape has not established that a postfix is safe there, and silently
  ## downgrading it to a prefix would hand the feature an earlier firing than it
  ## asked for without saying so. A caller that wants a postfix and gets a
  ## refusal declines LOUDLY and stays declined.
  ##
  ## `slots` is ignored entirely when `postfix` is false: a PREFIX restores rsp
  ## exactly (`add rsp,0x98 ; jmp *tramp`), so every stack argument is where the
  ## original expects it, whatever the arity.
  ##
  ## `kind` chooses which detour this is -- 0 update drain, 1 render drain,
  ## 2 settings probe -- i.e. which slot/method globals it sets and which route
  ## the firing path takes. The mechanics are identical; only the bookkeeping
  ## differs.
  ##
  ## Same lock as `installPatch`: this claims a slot and writes its row, and a
  ## mod's `patch` on another thread does too. It is the host's own hook, and it
  ## is not exempt from the rule.
  let what = (if kind == 1: "render-phase" elif kind == 2: "settings-probe"
              elif kind == 3: "version-brand" elif kind == 5: "botdiag"
              elif kind == 4: "settings-ui-probe" elif kind == 6: "botcap"
              elif kind == 7: "settings-tab-probe"
              elif kind == 8: "settings-tick-probe"
              elif kind == 9: "managed-invoke-probe"
              elif kind == 10: "debug-overlay"
              elif kind == 11: "debug-overlay-world"
              elif kind == 12: "botai"
              elif kind == 13: "menu-mode-text"
              elif kind == 14: "live-inspector"
              elif kind == 15: "bot-nav"
              elif kind == 17: "skip-mode-screen-ctor"
              elif kind == 18: "skip-mode-screen-showslot"
              elif kind == 19: "spl-preloader-anchor"
              elif kind == 20: "true-deploy-signal-a"
              elif kind == 21: "true-deploy-signal-b"
              elif kind == 23: "errdlg-message"
              elif kind == 24: "errdlg-exception"
              elif kind == 25: "errdlg-critical"
              elif kind == 27: "loadperf"
              elif kind == 28: "native-tabs"
              elif kind == 32: "settings-bind-slider"
              elif kind == 33: "settings-bind-save"
              elif kind == 35: "modload-native"
              else: "main-thread")
  # THE POSTFIX SLOT GATE. Before the lock, before the slot claim, before any
  # byte of the target is touched: a postfix whose target uses more register
  # slots than Win64 has is refused outright. See the doc comment above for the
  # measured crash this makes impossible.
  if postfix:
    var eff = slots
    if eff < 1'i32 and meth != cast[Il2CppMethod](0):
      # The by-name path has the `MethodInfo`, so it can derive the count the
      # same way `postfixRefusal` does rather than make the caller state it.
      eff = int32(postfixSlots(gRt, meth))
    if eff < 1'i32:
      warn "REFUSING the " & what & " POSTFIX detour on " & spec &
           ": its register-slot count was NOT DECLARED (no `slots` argument " &
           "and no MethodInfo to derive one from), so nothing here has " &
           "established that its arguments all arrive in registers. A " &
           "postfix on a call with stack arguments makes the ORIGINAL read " &
           "the thunk's own frame where those arguments belong -- measured " &
           "2026-09-02 on EFT.UI.MenuScreen::Show(5-arg), three dead boots " &
           "in SeasonWidgetData::From. NOTHING WAS PATCHED, and this feature " &
           "is declining rather than being silently downgraded to a prefix. " &
           "Fix: pass `slots` from the target table's own column."
      return false
    if eff > int32(PostfixMaxSlots):
      warn "REFUSING the " & what & " POSTFIX detour on " & spec &
           ": its compiled call uses " & $eff & " register slots (`this` " &
           "where there is one, the declared arguments, and IL2CPP's " &
           "trailing MethodInfo*), and past " & $PostfixMaxSlots & " they " &
           "arrive ON THE STACK. The postfix thunk subtracts its own frame " &
           "and CALLS the original, so the original would read " &
           $(eff - int32(PostfixMaxSlots)) & " of its argument(s) out of " &
           "that thunk frame -- a plausible integer where a managed object " &
           "belongs. MEASURED 2026-09-02: exactly this killed three boots on " &
           "EFT.UI.MenuScreen::Show(5-arg). NOTHING WAS PATCHED. A PREFIX on " &
           "this method is unaffected and is the fix if entry-time is " &
           "acceptable; otherwise read the stack arguments at " &
           "[entry_rsp+0x28+8*(n-4)]."
      return false
  tablesLock()
  let claimed = cHookClaim()
  if claimed < 0'i32:
    tablesUnlock()
    warn "no free patch slots for the " & what & " drain"
    return false
  let hook = cHookNew()
  if hook == nil:
    cHookRelease(claimed)
    tablesUnlock()
    return false

  var targetBytes = newSeq[byte](spec.len + 1)
  for k in 0 ..< spec.len:
    targetBytes[k] = byte(spec[k])
  targetBytes[spec.len] = 0'u8
  while gPatches.len <= int(claimed):
    gPatches.add deadPatch()
  gPatches[int(claimed)] = Patch(hook: hook, cb: cast[Il2CppPtr](0),
                     user: cast[Il2CppPtr](0), target: spec,
                     targetC: targetBytes, live: true, meth: meth,
                     wantArgs: false, canSkip: false, modIndex: -1,
                     isDrain: true, isPostfix: postfix, typed: false,
                     kinds: @[], retKind: 0'u8, frameFlags: 0'u32)
  # A postfix drain (the version brand) must arm the engine's postfix path before
  # the jump lands, exactly as a mod's postfix patch does -- so the thunk routes
  # the firing to `patchReturned` (after the original) rather than `patchFired`.
  if postfix:
    cHookSetPostfix(claimed, 1'i32)
  let rc = cHookAttachAt(hook, fn, claimed)
  if rc != 0'i32:
    gPatches[int(claimed)] = deadPatch()
    cHookFree(hook)
    cHookRelease(claimed)
    tablesUnlock()
    if verbose:
      info "cannot drain from " & spec & ": " &
           readCString(cHookErrorText(rc))
    return false

  if kind == 1:
    gRenderDrainSlot = int(claimed)
  elif kind == 2:
    gSettingsSlot = int(claimed)
  elif kind == 3:
    gVersionSlot = int(claimed)
  elif kind == 5:
    gBotDiagSlot = int(claimed)
  elif kind == 4:
    gSettingsUiSlot = int(claimed)
  elif kind == 6:
    gBotCapSlot = int(claimed)
  elif kind == 7:
    gSettingsTabSlot = int(claimed)
  elif kind == 8:
    gSettingsSelSlot = int(claimed)
  elif kind == 9:
    gMi2Slot = int(claimed)
  elif kind == 10:
    gDebugUiSlot = int(claimed)
  elif kind == 11:
    gDebugEspSlot = int(claimed)
  elif kind == 12:
    gBotAiSlot = int(claimed)
  elif kind == 13:
    gModeTextSlot = int(claimed)
  elif kind == 14:
    gInspSlot = int(claimed)
  elif kind == 15:
    gBotNavSlot = int(claimed)
  elif kind == 16:
    gCodeGenProbeSlot = int(claimed)
  elif kind == 17:
    gModeSkipCtorSlot = int(claimed)
  elif kind == 18:
    gModeSkipShowSlot = int(claimed)
  elif kind == 34:
    gModeSkipTryCreateSlot = int(claimed)
  elif kind == 35:
    # THE NATIVE MOD-LOAD STEP (modloadnative.nim). One kind for ALL of its
    # rows, the same shape as uihooks/loadperf/nedeploy above: the row being
    # bound is parked in `gMlnArming` around the call.
    mlnNoteSlot(claimed)
  elif kind == 19:
    gSplPreloaderSlot = int(claimed)
  elif kind == 20:
    gRpStartSlotA = int(claimed)
  elif kind == 21:
    gRpStartSlotB = int(claimed)
  elif kind == 22:
    gPactOwnerSlot = int(claimed)
  elif kind == 23:
    gErrDlgMsgSlot = int(claimed)
  elif kind == 24:
    gErrDlgExcSlot = int(claimed)
  elif kind == 25:
    gErrDlgCritSlot = int(claimed)
  elif kind == 26:
    # SHOW-EVENT hooks (uihooks.nim). One kind for ALL screen sites: which site
    # this bind is for is parked in uihooks' own `gUihArming` around the call,
    # because `attachDrain` knows the kind but not the site.
    uihNoteSlot(claimed)
  elif kind == 27:
    # THE RAID-LOAD TIMELINE (loadperf.nim). One kind for ALL 33 rows, same
    # shape as uihooks above: the row is parked in loadperf's `gLpArming`.
    lpNoteSlot(claimed)
  elif kind == 28:
    gNtToggleSlot = int(claimed)
  elif kind == 32:
    gSbdSlotSlider = int(claimed)
  elif kind == 33:
    gSbdSlotSave = int(claimed)
  elif kind == 30:
    gNtCloseSlot = int(claimed)
  elif kind == 31:
    gNtCloseAllSlot = int(claimed)
  elif kind == 29:
    # THE DEPLOY-ORDER BREADCRUMB (nedeploy.nim). One kind for ALL four rows,
    # the same shape as uihooks and loadperf above: the row being bound is
    # parked in nedeploy's `gNdpArming` around the call.
    ndpNoteSlot(claimed)
  else:
    gDrainSlot = int(claimed)
  tablesUnlock()
  if kind == 1:
    gRenderMethod = spec
  elif kind >= 2 and kind <= KindMaxFeature:
    # Every FEATURE detour (2..KindMaxFeature). Only kind 0 -- the main-thread
    # update drain -- owns gDrainMethod/gDrainPerFrame. This used to be written
    # out as a hand-maintained `kind == 2 or kind == 3 or ...` chain, twice, and
    # a kind added without touching both places fell through to the `else` and
    # silently overwrote the drain's identity. A range test cannot be forgotten.
    discard
  else:
    gDrainMethod = spec
    gDrainPerFrame = perFrame
  okLog what & " bound to " & spec & " (" &
        $int(cHookStolen(hook)) & " bytes)" &
        (if perFrame or (kind >= 2 and kind <= KindMaxFeature): "" else:
           "; it runs more than once a frame, so its firing count is not a " &
           "frame count")
  return true

const gBridgeEnabled* = true
  ## The earlier static-RVA detour crashed the live client (the RVA was a real
  ## function but NOT the code Unity runs as Update -- this build's metadata
  ## methodPointers table does not hold the live pointer). The bridge now
  ## resolves BY NAME via the runtime's own `MethodInfo.methodPointer` (the path
  ## `fov`/`sain` already use), and is fail-safe: null/non-executable binds
  ## nothing and the queue falls back to the host thread -- it cannot crash by
  ## default. `bridgeDisableDrain` in `aowlspt-host.json` is the real off-switch.

## `hexOf` is defined above `installPatch`, because the codeGenModule resolver
## that `installPatch` calls logs RVAs with it.

proc dumpMethodInfo(m: Il2CppMethod; spec: string) =
  ## One guarded dump of a live `MethodInfo`'s first nine words, so that a build
  ## where offset 0 (`methodPointer`) reads null still yields the one fact that
  ## decides everything: whether ANY field holds an executable pointer into the
  ## il2cpp section, and at what offset. Read is gated by `aowl_is_readable`
  ## (a VirtualQuery, not a faulting dereference), so it is safe on the host
  ## thread even for a handle that is not the struct it is assumed to be.
  if m == nil or cIsReadable(m, 0x48'i32) == 0'i32:
    info "deep-probe: MethodInfo for " & spec & " is not readable"
    return
  var line = "deep-probe: MethodInfo " & spec & " ="
  for k in 0 ..< 9:
    let off = int32(k * 8)
    let p = cReadPtrAt(m, off)
    let insec = cInIl2cpp(p) != 0'i32
    let code = cIsCodePointer(p) != 0'i32
    var tag = ""
    if insec:
      tag = "(il2cpp+0x" & hexOf(uint64(cIl2cppRvaOf(p))) & ")"
    elif code:
      tag = "(exec)"
    line.add " +" & hexOf(uint64(off)) & "=0x" & hexOf(cast[uint64](p)) & tag
  okLog line

proc scanMethodPointer(m: Il2CppMethod; foundOff: var int): Il2CppPtr =
  ## The first field of a live `MethodInfo` that holds an executable pointer INTO
  ## the il2cpp section -- the code pointer, wherever this build put it. Offset 0
  ## first (the ordinary `methodPointer`), then 0x08 (`virtualMethodPointer`),
  ## then the rest. An executable page alone is not trusted; the pointer must be
  ## in the il2cpp section, which is where compiled managed bodies live and where
  ## a data or stub pointer is not. Returns nil when no field qualifies.
  result = cast[Il2CppPtr](0)
  foundOff = -1
  if m == nil or cIsReadable(m, 0x48'i32) == 0'i32:
    return
  for k in 0 ..< 9:
    let off = int32(k * 8)
    let p = cReadPtrAt(m, off)
    if cIsCodePointer(p) != 0'i32 and cInIl2cpp(p) != 0'i32:
      foundOff = int(off)
      return p

proc gatedRefusalNote(): string =
  ## What the LAST `gatedHandle` refusal was, appended to the log lines that
  ## would otherwise say only "not in this build".
  ##
  ## MEASURED 2026-09-02 19:46, build 07ba6863: `findClass` began (correctly)
  ## refusing the MT19937-64 value that `il2cpp_class_from_name` returns when
  ## called without its nonce token, and the only thing the log said was
  ## "no per-frame candidate UnityEngine.UI.CanvasUpdateRegistry in this
  ## build". That sentence is about the BUILD and it was FALSE -- the type is
  ## there; the export was trapped. The drain never bound, queued work was held
  ## for 28 minutes, and it took a disassembly session to find out why. A
  ## refusal that does not name what it refused is the silent decline this repo
  ## treats as the worst outcome available.
  if gGatedHandleRefusals == 0:
    return " (no gated-handle refusal has happened this session, so the " &
           "runtime genuinely answered nothing for this name)"
  result = " -- NOTE: this is not necessarily absent from the build. The last " &
           "gated-handle refusal was 0x" & hexOf(gGatedHandleLastValue) &
           " (" & gGatedHandleLastWhy & "), " & $gGatedHandleRefusals &
           " refusal(s) so far. `il2cpp_class_from_name` and " &
           "`il2cpp_class_get_method_from_name` are NONCE-GATED and this call " &
           "site passes NO token, so what comes back here is the trap's " &
           "MT19937-64 output. The name-only routes below do not need the " &
           "handle and are tried anyway."

proc resolveDrainByName(spec: string; verbose: bool): Il2CppPtr =
  ## The half of `resolveDrainPointer` that needs only the NAME -- no
  ## `MethodInfo`, no `Il2CppClass`, nothing out of a gated export.
  ##
  ## Split out because of a MEASURED regression on 2026-09-02. Until then the
  ## drain bound on this client through a sequence nobody had noticed was
  ## load-bearing: `findClass` returned the trap's random non-zero value,
  ## `findMethod` returned another one, both passed their `!= nil` checks, and
  ## `resolveDrainPointer` then reported "MethodInfo ... is not readable" and
  ## fell through to `nameIndexResolve`, which takes only `spec` and had never
  ## looked at either handle. A GARBAGE POINTER WAS THE TICKET PAST TWO NIL
  ## CHECKS INTO A ROUTE THAT NEVER DEREFERENCED IT.
  ##
  ## The moment the garbage was correctly refused, `if cls == nil: continue`
  ## skipped the candidate and this route became unreachable. The fix is here
  ## and not in the filter: accepting a random 64-bit value again is the
  ## 10-second `il2cpp_value_box` crash of `Crash_2026-09-02_224920325`.
  result = cast[Il2CppPtr](0)
  if not gNameIndex:
    if verbose:
      info "no MethodInfo for " & spec & " and nameIndex is not set, so there " &
           "is no name-only route to try"
    return
  # The drain is a DETOUR, so it asks as a patch: a shared RVA here would drain
  # every method folded onto it. No override -- same rule as the caller below.
  var whyShared = ""
  let viaName = nameIndexResolve(spec, -1'i32, true, false, whyShared)
  if viaName == nil:
    return
  result = viaName

proc resolveDrainPointer(m: Il2CppMethod; spec: string;
                         verbose: bool): Il2CppPtr =
  ## The full per-candidate resolution used by both binders: the ordinary
  ## `methodPointer` (offset 0, executable-checked), and -- only when that is
  ## null -- a one-shot diagnostic dump plus, if `bridgeDeepScan` is set, a scan
  ## of the rest of the struct for an executable il2cpp pointer to hook instead.
  result = methodPointer(gRt, m)
  if result != nil:
    auditCodeGen(m, spec, result)
    return
  if gMethodInfoDumps < MethodInfoDumpCap:
    inc gMethodInfoDumps
    dumpMethodInfo(m, spec)
  # Ahead of the deep scan, because this is a RESOLUTION and the scan is a
  # guess: IL2CPP's own per-assembly `methodPointers` table, selected by the
  # declaring type's image and indexed by this MethodInfo's own token RID.
  if gCodeGenResolve:
    let viaTable = resolveCodeGen(m, spec, verbose)
    if viaTable != nil:
      warn "codeGen: binding the drain for " & spec & " at il2cpp+0x" &
           hexOf(uint64(cIl2cppRvaOf(viaTable))) & " from its image's " &
           "methodPointers table (codeGenResolve is set). NOTE: a static RVA " &
           "out of this same table was bound on the live client once and the " &
           "drain never fired; run with codeGenAudit first if that has not " &
           "been re-tested on this build."
      return viaTable
  # Before the deep scan for the same reason `resolveCodeGen` is: this is a
  # RESOLUTION -- an address derived offline from the metadata and stamped to
  # this exact GameAssembly.dll -- and the scan below is a guess at "some field
  # that looks like code".
  if gNameIndex:
    # One implementation, in `resolveDrainByName` above, so the route reached
    # WITH a MethodInfo and the route reached WITHOUT one cannot drift apart.
    let viaName = resolveDrainByName(spec, verbose)
    if viaName != nil:
      warn "name index: binding the drain for " & spec & " at il2cpp+0x" &
           hexOf(uint64(cIl2cppRvaOf(viaName))) & ", from the offline index " &
           "(nameIndex is set). The address came from metadata, not from the " &
           "runtime, and the by-RVA binder byte-verified its prologue."
      return viaName
  if gDeepScan:
    var off = -1
    let scanned = scanMethodPointer(m, off)
    if scanned != nil:
      warn "deep-scan: " & spec & " has an executable il2cpp pointer at " &
           "MethodInfo+0x" & hexOf(uint64(off)) & " -> il2cpp+0x" &
           hexOf(uint64(cIl2cppRvaOf(scanned))) & "; hooking it (may crash if " &
           "it is a wrong-but-real function -- bridgeDeepScan opted in)"
      return scanned
  if verbose:
    info "no usable code pointer for " & spec
  return cast[Il2CppPtr](0)

var gCodeGenTestedHost = false
var gCodeGenTestedUnity = false
var gCodeGenHostBadHandles = 0

proc codeGenProbeNames(): seq[string] =
  ## The fixed probe set. The first three are targets the ux-patch, bot-diag and
  ## bot-cap headers bind by verified static RVA and that are observed FIRING on
  ## this client, so the table's answer for them is checkable against something
  ## already trusted.
  result = @[]
  result.add "EFT.GameWorld::RegisterPlayer"
  result.add "EFT.BotSpawner::AddPlayer"
  result.add "EFT.TarkovApplication::ExitApplication"
  result.add "UnityEngine.AssetBundle::LoadAsset"
  result.add "UnityEngine.Time::get_deltaTime"
  result.add "EFT.TarkovApplication::Update"

proc codeGenAuditSelfTest(where: string) =
  ## Resolve a fixed set of named methods BOTH ways and report. Read-only: it
  ## resolves and compares, and patches nothing.
  ##
  ## `where` names the THREAD, and that is the entire point of this version.
  ##
  ## History, because it is the argument for the shape:
  ##   v1 compared only inside `installPatch`/`resolveDrainPointer` -- produced
  ##      ZERO lines, because every target that binds on this client binds from
  ##      a verified static RVA with `cast[Il2CppMethod](0)` and never goes
  ##      through either proc.
  ##   v2 ran at first drain-bind, ~1.1s, and declared six MethodInfos
  ##      unreadable. The textures mod read one of them fine at 46s.
  ##   v3 waited 20s, then to the 180s deadline, and reported the SAME thing --
  ##      `+0` unreadable for all six. So it is not timing; and since the
  ##      resolver only ever dereferences 8 bytes, not span strictness either.
  ##
  ## What all three had in common, and what was never controlled: they ran on
  ## the HOST'S OWN THREAD. `abi/aowlspt_bridge.h` has recorded since it was
  ## written that "reading IL2CPP class/method metadata off the Unity main
  ## thread returns bogus pointers and faults ... findClass / findMethod handed
  ## back garbage and methodPointer read garbage -> null. That is a wrong-thread
  ## artifact, not proof of protected metadata." That is this symptom exactly,
  ## written down before this investigation started.
  ##
  ## So this runs TWICE -- once from the host tick thread, once from a rider on
  ## the `PreloaderUI::Update` detour, which is Unity's own main thread -- and
  ## the two logs are the experiment. Nothing else differs between them.
  if not gCodeGenAudit:
    return
  if not gReady:
    return

  let probes = codeGenProbeNames()
  okLog "codeGen audit [" & where & "]: resolving " & $probes.len &
        " named methods on this thread (tid " & $cThreadId() & "). Read-only."

  # THE CLASS HANDLE ITSELF, probed before any method. `findClass` returning
  # non-nil currently gates real features -- the textures mod's `runtimeReady`
  # and, until this build, this self-test. Whether that handle is a readable
  # struct has never been checked, and if it is not, those gates are passing on
  # a value that means nothing.
  let probeCls = findClass(gRt, "UnityEngine.AssetBundle")
  if probeCls == nil:
    warn "codeGen audit [" & where & "]: findClass(UnityEngine.AssetBundle) " &
         "returned NIL on this thread"
  elif cIsReadable(probeCls, 8'i32) != 0'i32:
    okLog "codeGen audit [" & where & "]: the CLASS handle for " &
          "UnityEngine.AssetBundle is READABLE. spans: " &
          probeMethodInfoSpans(probeCls)
  else:
    warn "codeGen audit [" & where & "]: the CLASS handle for " &
         "UnityEngine.AssetBundle is NON-NIL BUT UNREADABLE -- so findClass " &
         "is not a validity check, and every readiness gate in this codebase " &
         "that treats a non-nil findClass as proof that metadata is queryable " &
         "is passing on a value that means nothing. spans: " &
         probeMethodInfoSpans(probeCls)

  var compared = 0
  var resolvedByTable = 0
  var badHandles = 0
  let same0 = int(cCodeGenAgreeSame())
  let diff0 = int(cCodeGenAgreeDiff())

  for spec in probes:
    let sep = find(spec, "::")
    if sep < 0:
      continue
    let cls = findClass(gRt, spec.substr(0, sep - 1))
    if cls == nil:
      info "codeGen audit [" & where & "]: " & spec & " -- no such type"
      continue
    let m = findMethod(gRt, cls, spec.substr(sep + 2), -1)
    if m == nil:
      info "codeGen audit [" & where & "]: " & spec & " -- no such method"
      continue
    let handleOk = cIsReadable(m, 8'i32) != 0'i32
    if not handleOk:
      inc badHandles
    let live = methodPointer(gRt, m)
    let viaTable = resolveCodeGen(m, spec, false)
    if viaTable != nil:
      inc resolvedByTable
    if live != nil and viaTable != nil:
      inc compared
      if cCodeGenNoteAgreement(live, viaTable) != 0'i32:
        okLog "codeGen audit [" & where & "]: " & spec &
              " AGREES -- both il2cpp+0x" & hexOf(uint64(cIl2cppRvaOf(live)))
      else:
        warn "codeGen audit [" & where & "]: " & spec & " DISAGREES -- " &
             "methodPointer=il2cpp+0x" & hexOf(uint64(cIl2cppRvaOf(live))) &
             " table=il2cpp+0x" & hexOf(uint64(cIl2cppRvaOf(viaTable)))
    elif live == nil and viaTable != nil:
      okLog "codeGen audit [" & where & "]: " & spec & " -- methodPointer " &
            "NULL, table resolves it to il2cpp+0x" &
            hexOf(uint64(cIl2cppRvaOf(viaTable))) &
            ". THIS IS THE CASE ROUTE B FIXES."
    else:
      warn "codeGen audit [" & where & "]: " & spec & " -- MethodInfo handle " &
           (if handleOk: "readable but" else: "NOT READABLE and") &
           " neither side resolved. spans: " & probeMethodInfoSpans(m)

  let same = int(cCodeGenAgreeSame()) - same0
  let diff = int(cCodeGenAgreeDiff()) - diff0
  okLog "codeGen audit [" & where & "]: " & $probes.len & " probed, " &
        $badHandles & " with an unreadable MethodInfo, " & $resolvedByTable &
        " resolved by the table, " & $compared & " comparable (" & $same &
        " agreed, " & $diff & " disagreed)."

  if where == "host thread":
    gCodeGenHostBadHandles = badHandles
    return

  # The Unity-thread pass concludes, and it concludes by COMPARING ITSELF TO
  # THE HOST-THREAD PASS. That difference -- not either number alone -- is the
  # finding.
  if gCodeGenTestedHost and gCodeGenHostBadHandles > 0 and badHandles == 0:
    okLog "codeGen audit VERDICT: THREAD-DEPENDENT. On the host thread " &
          $gCodeGenHostBadHandles & " of " & $probes.len & " MethodInfo " &
          "handles were unreadable; on the Unity main thread " & $badHandles &
          " were. By-name resolution WORKS here and is simply not usable off " &
          "Unity's thread -- which is what aowlspt_bridge.h recorded all " &
          "along. Route B then needs no metadata parser: it needs to run here."
  elif badHandles >= probes.len:
    warn "codeGen audit VERDICT: NOT thread-dependent -- every MethodInfo is " &
         "unreadable on the Unity main thread too. By-name method resolution " &
         "is genuinely unavailable on this build, so a name-to-token source " &
         "other than a MethodInfo is required (metadata tables, or a " &
         "generated name-to-RVA index). This is the measurement that decides."
  if diff > 0:
    warn "codeGen audit VERDICT: RED -- " & $diff & " disagreed on the Unity " &
         "thread. Do NOT enable codeGenResolve."
  elif compared == 0:
    warn "codeGen audit VERDICT: INCONCLUSIVE -- nothing could be compared " &
         "even on the Unity main thread. This is NOT a green light; it is the " &
         "absence of evidence, not evidence of agreement."
  else:
    okLog "codeGen audit VERDICT: GREEN -- " & $compared & " compared, " &
          $same & " agreed, 0 disagreed, on the Unity main thread. " &
          "codeGenResolve is corroborated."

proc codeGenProbeFired() =
  ## The Unity-main-thread arm, dispatched from the shared
  ## `EFT.UI.PreloaderUI::Update` detour. Runs one pass, then costs a single
  ## bool compare per frame forever after.
  if gCodeGenTestedUnity:
    return
  gCodeGenTestedUnity = true
  codeGenAuditSelfTest("Unity main thread")

proc codeGenAuditHostPass() =
  ## The host-thread arm, from the tick loop. Deliberately NOT delayed: v3
  ## proved timing is not the variable, so a delay would only add latency.
  if gCodeGenTestedHost or not gCodeGenAudit or not gReady:
    return
  if cCodeGenReady() == 0'i32:
    if cCodeGenWaiting() != 0'i32:
      return                      # module not mapped yet; retry next tick
    gCodeGenTestedHost = true
    warn "codeGen audit: cannot run -- GameAssembly.dll is mapped but the " &
         "codeGenModules table did not validate: " & codeGenReason()
    return
  gCodeGenTestedHost = true
  codeGenAuditSelfTest("host thread")

proc bindMainDrain(verbose: bool): bool =
  ## Detours a method Unity calls once per frame on its main thread, so that
  ## `invoke_main` can be drained from *there* rather than from the host's own
  ## attached thread.
  ##
  ## Which method is a research question this host cannot answer at compile
  ## time, and this is the honest state of it.
  ##
  ## Unity's player loop is native C++ and is not in the metadata, so there is
  ## no `PlayerLoop::Update` to look up. What is reachable by name is *managed*
  ## code the loop calls, and a candidate has to be all four of: called every
  ## frame, called on the main thread only, present for the whole session, and
  ## compiled into a function whose first bytes the detour engine can relocate.
  ## The four below are tried in order, most specific first:
  ##
  ##   `EFT.MainApplication::Update` -- the game's own root behaviour. If it
  ##   exists it is the best of these: once a frame, main thread, alive from the
  ##   menu to the desktop. The name is what the class is called in pre-1.0
  ##   dumps and has **not** been verified against a post-1.0 client by anyone
  ##   who wrote this file, which is exactly why this is a list and not a
  ##   constant.
  ##
  ##   `EFT.GameWorld::Update` -- narrower, and certain to be absent in the
  ##   menu, so it can only ever be the answer inside a raid. Kept because a
  ##   raid is where a mod most wants the main thread, and because binding late
  ##   beats not binding.
  ##
  ##   `UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate` -- uGUI's per-frame
  ##   layout and graphic rebuild, driven from `Canvas.willRenderCanvases` on
  ##   the main thread. Engine code, so it is present whenever the UI module is,
  ##   which for this game is always. This is the reliable fallback.
  ##
  ##   `UnityEngine.Time::get_deltaTime` -- last, and reluctantly. It is a Unity
  ##   API that may only be called from the main thread, so whoever calls it is
  ##   on that thread; but it is called *many* times per frame rather than once,
  ##   and it is a small function whose compiled body may well be shorter than
  ##   the fourteen bytes a jump needs -- in which case the engine refuses it
  ##   and this loop moves on, which is the right outcome rather than a failure.
  ##
  ## Whichever binds gets the same treatment: an empty drain costs a handful of
  ## instructions, so being called ten times a frame instead of once is a
  ## difference in noise rather than in frame time.
  ##
  ## The hook goes through the same engine and the same slot table as a mod's
  ## patch, and is entered in `gPatches` like one. It has to be: the engine
  ## hands slots out in ascending order and the firing path indexes `gPatches`
  ## by slot, so a host hook kept outside that table would shift every mod's
  ## slot by one and deliver each patch to the wrong handler.
  if gDrainSlot >= 0:
    return true
  if not gReady:
    return false
  if gDisableDrain:
    return false

  # By NAME first, and by default the only path -- because it uses the *runtime's
  # own* `MethodInfo.methodPointer`, which is the pointer the game actually calls
  # every frame. The static RVA path below was tried on the live client and, even
  # with a byte-verified prologue, it bound a real function that Unity never
  # reached as `Update`: the drain never fired and the game crashed seconds later
  # when that other function ran with a corrupted prologue. The lesson is that on
  # this hardened build the decrypted metadata's `methodPointers` table does not
  # hold the live code pointer, so a fixed RVA out of it is the wrong target.
  #
  # The by-name path cannot make that mistake: if the runtime hands back a null
  # or non-executable pointer it binds nothing and the game runs detour-free,
  # which is the stable floor. The first two names are the post-1.0 root
  # application MonoBehaviour and the raid tick listener; the engine methods
  # after them are last-resort.
  #
  # Built here rather than as a module-level `seq`: a global whose initialiser
  # is a call is silently left zeroed in an `--app:lib` build.
  var candidates: seq[string] = @[]
  candidates.add "EFT.TarkovApplication::Update"
  candidates.add "EFT.GameWorldUnityTickListener::Update"
  candidates.add "EFT.GameWorld::Update"
  candidates.add "UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate"
  candidates.add "UnityEngine.Time::get_deltaTime"

  # Whether each candidate runs once per frame, in the same order. All but the
  # last are the player loop calling a method it calls once; `get_deltaTime` is
  # a property anything may read, several times a frame, which is why it is the
  # last resort. A mod is told this through `aowlspt.host::main_thread` so it
  # can say "frames" only when that is what it is counting.
  var perFrame: seq[bool] = @[]
  perFrame.add true
  perFrame.add true
  perFrame.add true
  perFrame.add true
  perFrame.add false

  var candidateIndex = -1

  for spec in candidates:
    inc candidateIndex
    let sep = find(spec, "::")
    if sep < 0:
      continue
    let typePart = spec.substr(0, sep - 1)
    let member = spec.substr(sep + 2)

    # A NIL CLASS OR METHOD IS NO LONGER THE END OF THIS CANDIDATE.
    #
    # Both of these come out of NONCE-GATED exports called with no token, so on
    # this client they answer with the trap's random value and `gatedHandle`
    # refuses them. That refusal is correct -- see `resolveDrainByName` -- but
    # `nameIndexResolve` needs only `spec`, and it is how this drain has
    # actually been binding all along. So a refused handle now costs the
    # runtime route and nothing else.
    let cls = findClass(gRt, typePart)
    var m: Il2CppMethod = cast[Il2CppMethod](0)
    if cls == nil:
      if verbose:
        info "no per-frame candidate " & typePart & " from the runtime" &
             gatedRefusalNote()
    else:
      # -1: a per-frame update takes no arguments, but naming an arity here
      # would miss an overload set and there is nothing to gain from strictness.
      m = findMethod(gRt, cls, member, -1)
      if m == nil and verbose:
        info typePart & " has no " & member & " from the runtime" &
             gatedRefusalNote()

    var fn: Il2CppPtr = cast[Il2CppPtr](0)
    if m != nil:
      fn = resolveDrainPointer(m, spec, verbose)
    else:
      fn = resolveDrainByName(spec, verbose)
      if fn != nil:
        warn "name index: binding the drain for " & spec & " at il2cpp+0x" &
             hexOf(uint64(cIl2cppRvaOf(fn))) & " with NO MethodInfo at all -- " &
             "the runtime refused to name the type or the method (see the note " &
             "above). The address came from metadata and the by-RVA binder " &
             "byte-verified its prologue."
    if fn == nil:
      continue

    let pf = candidateIndex < perFrame.len and perFrame[candidateIndex]
    if attachDrain(spec, fn, m, pf, verbose, 0'i32):
      return true

  # Static-RVA path (Experiment B), OFF by default. The address is now KNOWN
  # correct: the offline resolver that produced `TarkovApplication::Update` @
  # 0x977B10 reproduces all five BE-bypass RVAs and every SETTINGS.md VA exactly,
  # so this is not a guess. It stays opt-in because the earlier crash on this
  # exact target is unexplained -- either the trampolined detour engine on this
  # client, or `Update` not ticking in the menu where it was tried. Run
  # `bridgeSettingsProbe` first: if that read-only detour fires on the Unity
  # thread without crashing, the engine is fine and this should fire in a raid.
  # Reached only when `bridgeStaticRva` is set, after by-name (which fails
  # off-thread) has been tried.
  if gAllowStaticBridge:
    let staticCount = cBridgeTargetCount()
    for i in 0 ..< int(staticCount):
      let fn = cBridgeTargetAt(int32(i))
      if fn == nil:
        continue
      let spec = readCString(cBridgeTargetName(int32(i)))
      let pf = cBridgeTargetPerFrame(int32(i)) != 0'i32
      warn "binding the main-thread drain by validated STATIC RVA (" & spec &
           "); bridgeStaticRva is set (Experiment B)"
      if attachDrain(spec, fn, cast[Il2CppMethod](0), pf, verbose, 0'i32):
        return true

  result = false

proc bindRenderDrain(verbose: bool): bool =
  ## Detours a RENDER-phase per-frame method so `invoke_render`'s queue drains
  ## where immediate-mode `GL` drawing rasterizes -- the second half of the
  ## bridge, for ESP boxes and GL HUDs that the update-phase drain cannot draw.
  ##
  ## By NAME first, and by default the only path, for the same reason as
  ## `bindMainDrain`: the runtime's `MethodInfo.methodPointer` is the pointer the
  ## game actually calls, whereas a fixed RVA out of the decrypted metadata's
  ## `methodPointers` table bound a real-but-wrong function on the live client and
  ## crashed it. If the runtime hands back nothing usable, this binds nothing and
  ## `invoke_render` reports the render thread as unavailable -- the stable floor.
  ## There is deliberately no host-thread fallback: a GL call off the render
  ## thread does nothing useful and can fault, so if no render target binds the
  ## queue is simply not offered.
  ##
  ## Candidates, most-preferred first: `OnRenderObjectManager::OnRenderObject`
  ## (Unity's immediate-mode-GL callback, dispatched by a purpose-built manager
  ## kept alive through gameplay) then `EFT.CameraControl.CameraLodBiasController::
  ## OnPostRender` (the main game camera's post-render, a raid-time fallback).
  if gRenderDrainSlot >= 0:
    return true
  if not gReady:
    return false
  if gDisableDrain:
    return false

  var candidates: seq[string] = @[]
  candidates.add "OnRenderObjectManager::OnRenderObject"
  candidates.add "EFT.CameraControl.CameraLodBiasController::OnPostRender"

  for spec in candidates:
    let sep = find(spec, "::")
    if sep < 0:
      continue
    let typePart = spec.substr(0, sep - 1)
    let member = spec.substr(sep + 2)
    # Same shape as `bindMainDrain` above, and for the same measured reason:
    # a handle refused by `gatedHandle` must not cost the name-only route.
    let cls = findClass(gRt, typePart)
    var m: Il2CppMethod = cast[Il2CppMethod](0)
    if cls == nil:
      if verbose:
        info "no render candidate " & typePart & " from the runtime" &
             gatedRefusalNote()
    else:
      m = findMethod(gRt, cls, member, -1)
      if m == nil and verbose:
        info typePart & " has no " & member & " from the runtime" &
             gatedRefusalNote()

    var fn: Il2CppPtr = cast[Il2CppPtr](0)
    if m != nil:
      fn = resolveDrainPointer(m, spec, verbose)
    else:
      fn = resolveDrainByName(spec, verbose)
      if fn != nil:
        warn "name index: binding the RENDER drain for " & spec &
             " at il2cpp+0x" & hexOf(uint64(cIl2cppRvaOf(fn))) &
             " with NO MethodInfo at all -- the runtime refused to name the " &
             "type or the method (see the note above)."
    if fn == nil:
      continue
    if attachDrain(spec, fn, m, true, verbose, 1'i32):
      return true

  # Static-RVA last resort, OFF by default -- the same fragile, once-crashed path
  # as in `bindMainDrain`, reached only when `bridgeStaticRva` is set.
  if gAllowStaticBridge:
    let count = cBridgeRenderTargetCount()
    for i in 0 ..< int(count):
      let fn = cBridgeRenderTargetAt(int32(i))
      if fn == nil:
        continue
      let spec = readCString(cBridgeRenderTargetName(int32(i)))
      warn "binding the render-phase drain by STATIC RVA (" & spec & "); this " &
           "path is enabled only because bridgeStaticRva is set"
      if attachDrain(spec, fn, cast[Il2CppMethod](0), true, verbose, 1'i32):
        return true

  result = false

## Carries between independently-guarded steps: `object_class` and the resolved
## `System.Int32` class, each set in its own step and read by a later one, so a
## step that faults simply leaves its carry nil and the dependent step skips.
var gProbeCls: Il2CppClass = cast[Il2CppClass](0)
var gProbeI32: Il2CppClass = cast[Il2CppClass](0)

proc settingsMetaProbe(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_settings_meta_probe", cdecl.} =
  ## One RISKY managed op, selected by the step the C thunk stashed, run under the
  ## VEH guard so a fault here is caught and the game survives. Each op brackets
  ## itself with flushing logs; the guard returning nil means this step faulted.
  ## Steps are independent (own guard each), so P3 faulting does not hide P4/P5.
  let this = cast[Il2CppObject](a)
  let step = int(cProbeStep())

  if step == 2:
    # object_class (reads this+0, shown readable) then the class name (the first
    # real metadata dereference).
    okLog "il2cpp settings probe P2: about to object_class(this)"
    let cls = gRt.objectClass(this)
    gProbeCls = cls
    okLog "il2cpp settings probe P2: object_class = 0x" & hexOf(cast[uint64](cls))
    if cls != nil:
      okLog "il2cpp settings probe P2: about to read class name"
      let cn = gRt.classNamespace(cls)
      let nm = gRt.className(cls)
      okLog "il2cpp settings probe P2: class = " &
            (if cn.len > 0: cn & "." else: "") & nm
  elif step == 3:
    # findClass System.Int32: domain -> assemblies -> classFromName traversal.
    # This was the unlogged first op that took the client down before.
    okLog "il2cpp settings probe P3: about to findClass System.Int32"
    let i32 = findClass(gRt, "System.Int32")
    gProbeI32 = i32
    okLog "il2cpp settings probe P3: findClass System.Int32 = 0x" &
          hexOf(cast[uint64](i32))
  elif step == 4:
    # value_box: a managed-heap GC allocation. If P3 worked but this faults,
    # managed construction is the limit and STEP3 must repurpose, not build.
    if gProbeI32 == nil:
      okLog "il2cpp settings probe P4: skipped (System.Int32 did not resolve)"
    else:
      okLog "il2cpp settings probe P4: about to value_box(System.Int32, 1337)"
      let cell = cCellNew()
      cCellSetI32(cell, 1337'i32)
      let boxed = gRt.valueBox(gProbeI32, cell)
      cCellFree(cell)
      okLog "il2cpp settings probe P4: value_box = 0x" & hexOf(cast[uint64](boxed))
      if boxed != nil:
        let back = gRt.objectUnbox(boxed)
        okLog "il2cpp settings probe P4: box round-trip = " &
              $(if back != nil: cReadI32At(back) else: 0'i32) &
              " -> managed construction (object_new/value_box) works here"
  elif step == 5:
    # The field iterator: object_class -> il2cpp_class_get_fields. The protected
    # build that hid method pointers may also refuse this.
    if gProbeCls == nil:
      okLog "il2cpp settings probe P5: skipped (object_class was nil)"
    else:
      okLog "il2cpp settings probe P5: about to iterate SettingsScreen fields"
      var c = gProbeCls
      var depth = 0
      var logged = 0
      while c != nil and depth < 5 and logged < 50:
        var iter: Il2CppIter = cast[Il2CppIter](0)
        while logged < 50:
          let f = gRt.nextField(c, iter)
          if f == nil:
            break
          let fnm = gRt.fieldName(f)
          let ft = gRt.fieldType(f)
          let tn = (if ft != nil: gRt.typeName(ft) else: "?")
          let off = gRt.fieldOffset(f)
          okLog "il2cpp settings probe P5:   +0x" & hexOf(uint64(off)) &
                " " & fnm & " : " & tn
          inc logged
        c = gRt.classParent(c)
        inc depth
      okLog "il2cpp settings probe P5: field walk done (" & $logged & " fields)"

  return cast[Il2CppPtr](1)

proc settingsProbeFired(regs: Il2CppPtr) =
  ## Experiment A, fired from the read-only detour on `SettingsScreen::Show`.
  ##
  ## The whole point is the thread: `Show` is only ever called when the user
  ## opens the settings screen, and the settings UI runs on Unity's main thread,
  ## so if this fires at all it fires there. Comparing to the host boot thread is
  ## the proof: a thread id that is NOT the host's is Unity's, which means a
  ## static detour DOES reach the Unity thread on a user action -- the capability
  ## native settings injection needs. This reads `this` (RCX) as a bare pointer
  ## and logs it; it makes no managed call and writes nothing, so it is safe
  ## whatever thread it lands on.
  let tid = int(cThreadId())
  let selfPtr = cRegsInt(regs, 0'i32)   # RCX = `this`, the live SettingsScreen
  let onHost = (tid == int(gHostThreadId))
  okLog "il2cpp settings probe: SettingsScreen.Show fired on thread " & $tid &
        " (host thread " & $int(gHostThreadId) & "); " &
        (if onHost:
           "this IS the host thread -- NOT Unity's, unexpected"
         else:
           "this is NOT the host thread -> it is Unity's main thread, so a " &
           "static detour reaches the Unity thread on a user action and native " &
           "settings injection is VIABLE") &
        "; SettingsScreen this=0x" & hexOf(selfPtr) &
        (if selfPtr != 0'u64 and cIsReadable(cast[Il2CppPtr](selfPtr), 0x20'i32) != 0'i32:
           " (readable)" else: " (this not readable)")

  # The heavier work runs once, split so the log says exactly which operation
  # faults. The previous version crashed here with no line between "Show fired"
  # and the crash, because its first op was `findClass` (a domain/assembly
  # traversal) and there was no log before it.
  if onHost or gSettingsProbeDone or selfPtr == 0'u64:
    return
  gSettingsProbeDone = true

  # P1 -- the STEP3 primitive, and the one that actually matters: a plain raw
  # field read of the SettingsScreen. No metadata, no box, no invoke -- pure
  # memory, pre-checked with `cIsReadable` (a VirtualQuery, not a faulting
  # dereference), so it cannot crash. Retargeting an existing control's value
  # field (the fov/sain primitive the audit named as STEP3's real path) is
  # exactly this read plus a write, so if this succeeds that path is open.
  if cIsReadable(cast[Il2CppPtr](selfPtr), 0x60'i32) != 0'i32:
    var line = "il2cpp settings probe P1 (raw field read, the STEP3 primitive):"
    for k in 0 ..< 10:
      let off = int32(k * 8)
      let w = cReadPtrAt(cast[Il2CppPtr](selfPtr), off)
      line.add " +" & hexOf(uint64(off)) & "=0x" & hexOf(cast[uint64](w))
    okLog line
    okLog "il2cpp settings probe P1: raw field read on SettingsScreen SUCCEEDED" &
          " -> the field read/write path STEP3 needs is available here"
  else:
    okLog "il2cpp settings probe P1: SettingsScreen this is not readable for 0x60"

  # P2..P5 -- the RISKY managed metadata ops, each under its OWN VEH guard so a
  # fault in one (say findClass) does not hide the status of the others. The
  # guard returns nil on a fault; each op also brackets itself with flushing logs.
  for step in 2 .. 5:
    let r = cMetaProbeGuarded(cast[Il2CppPtr](selfPtr), int32(step))
    if r == nil:
      okLog "il2cpp settings probe: P" & $step & " FAULTED (the VEH guard kept " &
            "the game alive); see its 'about to' line above for the exact op"
  okLog "il2cpp settings probe: metadata steps done. If P1 succeeded, the field " &
        "read/write path STEP3 needs is available regardless of P2..P5"

proc bindSettingsProbe(verbose: bool): bool =
  ## Installs the read-only Experiment-A detour on `SettingsScreen::Show`, from
  ## the verified static target in `aowlspt_bridge.h`. Opt-in (`bridgeSettingsProbe`),
  ## and like the drains it binds nothing on a build whose prologue does not
  ## match. The detour sits on static code, so it installs as soon as
  ## GameAssembly is mapped and fires the first time the user opens settings.
  if gSettingsSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let count = cBridgeSettingsTargetCount()
  for i in 0 ..< int(count):
    let fn = cBridgeSettingsTargetAt(int32(i))
    if fn == nil:
      if verbose:
        info "settings probe target " & $i & " did not verify on this build"
      continue
    let spec = readCString(cBridgeSettingsTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 2'i32):
      okLog "settings probe armed on " & spec &
            "; open the in-game settings screen to fire it"
      return true
  result = false

proc looksLikeVersion(s: string): bool =
  ## A version-ish string: has a digit and a dot, is short, and is otherwise
  ## printable ASCII. Used to pick the version String field out of a component's
  ## fields without hard-coding an offset that a future build would move.
  if s.len == 0 or s.len > 64:
    return false
  var hasDigit = false
  var hasDot = false
  for ch in s:
    if ch >= '0' and ch <= '9': hasDigit = true
    elif ch == '.': hasDot = true
    elif ord(ch) < 0x20 or ord(ch) > 0x7E: return false
  result = hasDigit and hasDot

## Set by `versionBrandFired` and read by `brandNewStringImpl`, because the
## guarded alloc thunk passes only one pointer and the string is easier carried
## in a global than marshalled through it.
var gBrandText: string = ""

proc brandNewStringImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_brand_newstring", cdecl.} =
  ## Allocates the branded `System.String` from `gBrandText`. Run under the VEH
  ## guard by `cBrandNewStringGuarded`, so a fault in `il2cpp_string_new` on this
  ## protected build returns nil rather than crashing. `a` is unused.
  result = newString(gRt, gBrandText)

proc rawReadVersionString(p: Il2CppPtr): string =
  ## Reads a candidate `System.String` at `p` by its FIXED runtime layout, with
  ## no reflection and no runtime accessor -- the P1 primitive extended: length
  ## is the int32 at `+0x10`, the UTF-16 chars are inline at `+0x14`. Every read
  ## is `aowl_is_readable`-guarded, so a slot that is not a String just yields ""
  ## and is skipped. Only the BMP is decoded (ASCII in practice for a version).
  result = ""
  if p == nil or cIsReadable(p, 0x14'i32) == 0'i32:
    return
  let n = cReadI32At(cast[Il2CppPtr](cast[uint64](p) + 0x10'u64))
  if n <= 0'i32 or n > 64'i32:
    return
  let chars = cast[Il2CppPtr](cast[uint64](p) + 0x14'u64)
  if cIsReadable(chars, int32(n) * 2'i32) == 0'i32:
    return
  for i in 0 ..< int(n):
    let c = cWordAt(chars, uint64(i))
    if c == 0'u16 or c > 0x7E'u16:
      # Non-ASCII or embedded NUL: not the plain version label we want; bail so a
      # wrong slot cannot masquerade as a short string.
      return ""
    result.add char(c)

proc versionBrandFired(regs: Il2CppPtr) =
  ## Fired from the POSTFIX detour on `EFT.UI.PreloaderUI::Awake`, on the Unity
  ## main thread, *after* the original set the bottom-left version label.
  ##
  ## Staged and crash-proof by construction, because a fault here is on the Unity
  ## thread during boot:
  ##
  ##   * READ-ONLY probe (always): log the firing thread and whether `this + 0x20`
  ##     (Awake's `set_text` receiver, the label component) is readable, then scan
  ##     the component's pointer slots reading each as a `System.String` by its
  ##     FIXED layout (length @ +0x10, UTF-16 chars @ +0x14) and log any whose
  ##     content looks like a version. NO reflection: the live verdict is that
  ##     `il2cpp_object_get_class` / `il2cpp_class_get_name` (and every reflection
  ##     accessor) FAULT even on the Unity thread on this build, so the target is
  ##     found by CONTENT, not by class.
  ##   * FIELD-WRITE brand (opt-in `uxVersionBrandWrite`): allocate a branded
  ##     `System.String` (under the VEH guard, so even the alloc cannot crash) and
  ##     write its pointer straight into that slot by offset -- NO `runtime_invoke`,
  ##     NO `findMethod`, NO `objectClass`; a raw field write is what `fov`/`sain`
  ##     do. The write slot is VirtualQuery-guarded before the store.
  ##
  ## Every dereference is `aowl_is_readable`-guarded and the whole thing runs at
  ## most once. Any doubt -> leave the stock version, never crash.
  if gVersionBranded:
    return
  gVersionBranded = true          # once only, whatever the outcome below

  let tid = int(cThreadId())
  let onHost = (tid == int(gHostThreadId))
  okLog "version probe: PreloaderUI.Awake postfix fired on thread " & $tid &
        (if onHost: " (HOST thread -- unexpected; NOT Unity's)"
         else: " (NOT the host thread -> Unity's main thread)")

  let selfRaw = cRegsInt(regs, 0'i32)          # RCX = the PreloaderUI `this`
  if selfRaw == 0'u64:
    warn "version probe: `this` is null; nothing to read"
    return
  let self = cast[Il2CppPtr](selfRaw)
  # THE SECOND, INDEPENDENT ANCHOR SOURCE for the polling brand in
  # `modstab.nim`. This postfix fires at ~1.3 s, more than 13 s before the
  # first `PreloaderUI::Update` rider tick, and its `this` is the same live
  # PreloaderUI. It is captured here and ONLY here -- nothing in this probe
  # writes through it, and the offset this probe goes on to read
  # (`cUxVersionLabelOffset`) is the fact-#13 WRONG object; the polling brand
  # ignores that offset entirely and walks by NAME to AlphaLabel instead.
  # Two independent sources, because one of them being gated behind another
  # feature's flag is exactly what made this never resolve.
  if gVerPreloader == nil:
    gVerPreloader = self
  let off = cUxVersionLabelOffset()
  if cIsReadable(self, off + 8'i32) == 0'i32:
    warn "version probe: this+0x" & hexOf(uint64(off)) & " is not readable"
    return
  let label = hReadPtr(self, off)
  if label == nil or cIsReadable(label, 0x20'i32) == 0'i32:
    warn "version probe: label component (this+0x" & hexOf(uint64(off)) &
         ") is null or not readable"
    return
  okLog "version probe: label component at this+0x" & hexOf(uint64(off)) &
        " is readable; scanning its String slots by raw layout (no reflection)"

  # Raw scan for the text-backing String on the component. Read each pointer slot
  # and interpret it as a System.String by its FIXED layout (length @ +0x10,
  # UTF-16 chars @ +0x14) -- NO objectClass/className, because runtime reflection
  # TOKEN-GATED on this build and answer with a plausible random value when
  # called without their token (CLAUDE.md section 5). The version String is
  # found by CONTENT (`looksLikeVersion`), which is self-validating: a slot whose
  # bytes are not a short version-looking ASCII string is skipped, so a wrong slot
  # cannot be mistaken for the target.
  var textField = -1
  var textVal = ""
  var o = 0x10
  while o <= 0x180:
    if cIsReadable(label, int32(o + 8)) != 0'i32:
      let fp = hReadPtr(label, int32(o))
      let s = rawReadVersionString(fp)
      if s.len > 0 and looksLikeVersion(s):
        okLog "version probe: String slot +0x" & hexOf(uint64(o)) &
              " = \"" & s & "\"  <-- version-looking"
        if textField < 0:
          textField = o
          textVal = s
    o = o + 8

  if not gVersionWrite:
    okLog "version probe: read-only (set uxVersionBrandWrite to attempt a " &
          "field-write brand; no managed write was performed)"
    return

  # ---- opt-in field-write brand: guarded newString + raw field store ----
  if textField < 0:
    warn "version brand: no version-looking String slot found on the label " &
         "component; not writing (stock version left in place)"
    return
  if textVal.startsWith("aowlspt"):
    return                                      # already ours
  # "aowlspt <U+2014 em dash> <version>", em dash as explicit UTF-8 bytes so the
  # source stays ASCII; il2cpp_string_new takes UTF-8. The alloc runs under the
  # VEH guard (`cBrandNewStringGuarded`), so even il2cpp_string_new cannot crash.
  gBrandText = "aowlspt \xE2\x80\x94 " & textVal
  let ns = cBrandNewStringGuarded(cast[Il2CppPtr](0))
  if ns == nil or cIsReadable(ns, 0x14'i32) == 0'i32:
    warn "version brand: guarded newString failed/faulted or returned an " &
         "unreadable String; not writing (stock version left in place)"
    return
  okLog "version brand: allocated branded String ok; writing it into label " &
        "slot +0x" & hexOf(uint64(textField))
  # THE STATED EXCEPTION, AND WHY IT IS NOW BOUNDED (WRITE-AUDIT #9, section
  # 5.4; INTERACTION-LAYER-MAP M3/M6).
  #
  # This is the ONLY host store whose offset never came out of the field table:
  # it is DISCOVERED by scanning the component in 8-byte steps for a slot whose
  # CONTENTS look like a version string. That acceptance test is a test of the
  # contents, not of the declared type -- the check-that-cannot-fail shape
  # (CLAUDE.md 9b), and it is why the write audit ranked this site #2.
  #
  # The scan is kept (it is how the slot is identified at all) but it no longer
  # has the authority to write. The discovered offset must MATCH
  # `TMPro.TMP_Text.m_text`'s metadata offset, and the store then goes through
  # the generated FieldRef like every other site -- an 8-byte reference store
  # into a slot the metadata declares a reference, on a receiver whose klass
  # has been admitted. A discovered offset that is NOT m_text means this
  # component is not the type we think it is, and the honest answer to that is
  # to write nothing.
  if int32(textField) != cFrOff(frTmpMText()):
    warn "version brand: the discovered version-String slot is +0x" &
         hexOf(uint64(textField)) & ", but TMPro.TMP_Text.m_text is at +0x" &
         hexOf(uint64(cFrOff(frTmpMText()))) & " on this build. A slot found " &
         "by its CONTENTS is not evidence of a declared type, so nothing was " &
         "written (WRITE-AUDIT #9)."
    return
  # The label component was read out of PreloaderUI at its declared offset, so
  # its klass is a fact about the layout; a later fire presenting a different
  # klass is refused rather than written through.
  discard frAdmit("version brand", frTmpMText(), label)
  if frStorePtr("version brand", frTmpMText(), label, ns):
    okLog "version brand: TMPro.TMP_Text.m_text (+0x" &
          hexOf(uint64(cFrOff(frTmpMText()))) & ") set to \"" & gBrandText &
          "\" through the generated FieldRef"
  else:
    warn "version brand: the typed store into TMP_Text.m_text was REFUSED " &
         "(see the hostwrite REFUSED line above for which rule); the stock " &
         "version is left in place"

proc bindVersionBrand(verbose: bool): bool =
  ## Installs the POSTFIX detour on `EFT.UI.PreloaderUI::Awake` from the verified
  ## static target in `aowlspt_uxpatch.h`. Opt-in (`uxVersionBrand`); like the
  ## drains it binds nothing on a build whose prologue does not match, so it is a
  ## no-op rather than a hazard on any other build. If PreloaderUI.Awake already
  ## ran before this armed, the label is simply left unbranded (fail-safe) --
  ## there is no crash and nothing else is affected.
  if gVersionSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let fn = cUxVersionTarget()
  if fn == nil:
    if verbose:
      info "version brand: PreloaderUI.Awake did not verify on this build"
    return false
  # 2 register slots: `this` + IL2CPP's trailing MethodInfo*. `Awake` declares
  # no parameters (metadata parameterCount@34 = 0, not static), so every
  # argument is in a register and a POSTFIX is safe here. `attachDrain` refuses
  # the postfix rather than trusting this comment; `tools/drainaudit.py`
  # re-derives the 2 from the metadata offline.
  if attachDrain("EFT.UI.PreloaderUI::Awake", fn, cast[Il2CppMethod](0),
                 false, verbose, 3'i32, true, 2'i32):
    okLog "version brand armed on EFT.UI.PreloaderUI::Awake (postfix); the " &
          "bottom-left version label will read \"aowlspt â€” <version>\""
    return true
  result = false

## READ-ONLY GameWorld bot/player census. Kept in its own file to avoid colliding
## with concurrent host work; `include`d (not imported) so it shares this file's
## guarded raw-read primitives, `cRegsInt`, logging, `attachDrain`, and the
## verified `EFT.GameWorld::RegisterPlayer` target. Defines `botDiagRegisterFired`
## (dispatched by slot identity in `patchFired`) and `bindBotDiag`.
include "botdiag.nim"
## OFFLINE SCAV-CAP LIFT. Kept in its own file to avoid colliding with concurrent
## host work; `include`d (not imported) so it shares this file's guarded raw
## primitives, `cRegsInt`, logging, `attachDrain`, the VEH/SEH guard, and the
## verified `EFT.BotSpawner::AddPlayer` target. Defines `botCapAddPlayerFired`
## (dispatched by slot identity in `patchFired`) and `bindBotCap`.
include "botcap.nim"
## CATCH THE IN-GAME ERROR DIALOG. Kept in its own file to avoid colliding with
## concurrent host work; `include`d (not imported) so it shares this file's
## guarded raw primitives, `cRegsInt`, logging, `attachDrain`, the VEH/SEH guard
## and the three verified PreloaderUI error-screen targets. Defines `errDlgFired`
## (dispatched by slot identity in `patchFired`) and `bindErrDlg`.
include "errdlg.nim"
## BOT AI ACTIVATION RESCUE. Kept in its own file to avoid colliding with
## concurrent host work; `include`d (not imported) so it shares this file's
## guarded raw primitives, `cRegsInt`, logging, `attachDrain`, the VEH/SEH guard,
## and the verified `EFT.BotOwner::PreActivate` target. Defines
## `botAiPreActivateFired` (dispatched by slot identity in `patchFired`) and
## `bindBotAi`.
include "botai.nim"
## NATIVE BOT NAVIGATION API. Kept in its own file to avoid colliding with
## concurrent host work; `include`d (not imported) so it shares this file's
## guarded raw primitives, `cRegsInt`, `cNowMs`, logging, `attachDrain`, the
## VEH/SEH guard, and the verified `EFT.BotOwner::UpdateManual` target. Defines
## `botNavUpdateFired` (dispatched by slot identity in `patchFired`),
## `bindBotNav`, `bnSetWanted`/`bnParseCommands` (the poll-thread intake) and
## `botNavCensus` (the registry, carried back on the existing report).
include "botnav.nim"
## Phase 1 native-settings control-tree probe. Kept in its own file to avoid
## colliding with concurrent host work; `include`d (not imported) so it shares
## this file's guarded raw-read primitives, logging, `attachDrain`, and the
## verified `SettingsScreen::Show` target. Defines `settingsUiProbeFired`
## (dispatched by slot identity in `patchFired`) and `bindSettingsUiProbe`.
include "settingsui.nim"
## The DIRECT-INVOCATION proof ladder. Kept in its own file to avoid colliding
## with concurrent host work; `include`d (not imported) so it shares this file's
## guarded raw primitives, `cRegsInt`, logging, `attachDrain`, the VEH/SEH guard,
## the verified `SettingsScreen::EnsureTabInitialized` target -- and, because it
## comes AFTER `settingsui.nim`, that file's `suiReadString` and settings-tree
## offsets. Defines `mi2LadderFired` (dispatched by slot identity in
## `patchReturned`) and `bindManagedInvoke`.
## FORWARD DECLARATIONS for the native-UI layer.
##
## `invoke2.nim` owns the only proven Unity-thread detour where a live
## SettingsScreen and built controls both exist, and a SECOND detour on that
## function would overwrite the first's trampoline and silently kill it. So the
## native-UI proof RIDES invoke2's postfix as a drain. That means invoke2.nim
## calls forward into `nativeui.nim`, which is `include`d after it -- these two
## declarations are what make that legal.
proc nuProofWanted(): bool
proc nuProofRun(tab: Il2CppPtr)
## The unified-framework dual-backend proof rides the SAME drain, for the same
## reason. Declared here, defined in `aowlui.nim` (included after invoke2).
proc auProofWanted(): bool
proc auProofRun(tab: Il2CppPtr)
## The NATIVE-UI TOOLKIT's self-test rides the SAME drain, for the SAME reason.
## Declared here, defined in `nuikit.nim`, which is `include`d after
## `inspect.nim` because it CONSUMES the inspector's scene-root walk for canvas
## discovery rather than writing a second implementation of it.
proc nuKitSelfTestWanted(): bool
proc nuKitSelfTestRun(tab: Il2CppPtr)

include "invoke2.nim"

## THE NATIVE UNITY UI CONSTRUCTION LAYER -- the API mods build real UI on.
## `include`d immediately after `invoke2.nim` because it stands on that file's
## byte-verified `Component::get_gameObject` thunk and its `mi2FindTmp` anchor
## walk, and on `settingsui.nim`'s `suiReadString` above both. Defines
## `nuCreate`/`nuAdd`/`nuLayout`/`nuSetText`/`nuClone`/`nuDestroyAll`,
## `bindNativeUi`, and the visual self-proof `nuProofRun`.
include "nativeui.nim"

## THE MANAGED-WRITE GATE. `include`d immediately after `nativeui.nim` because
## it needs `nuKlassOf`, `nuAlive` and `nuActiveInHierarchy` from it, and
## BEFORE every feature that writes into the game's heap so they can all route
## through it. Readability was the only guard those features had, and on the
## IL2CPP GC heap a readability test cannot fail -- see `hostwrite.nim` for the
## two crash dumps that measured the consequence.
include "hostwrite.nim"

## The UNIFIED WIDGET FRAMEWORK, `include`d after `nativeui.nim` so it can use
## the `nu*` primitives directly. Composable widgets (uiPanel/uiLabel/uiToggle/
## uiButton/uiTabStrip/uiRow/bindToConfig) over BOTH backends -- the D3D11
## overlay and native Unity UI -- behind one caller-facing signature, with the
## backend selectable. The dual-backend self-proof is `auProofRun`.
include "aowlui.nim"

## The in-game, Unity-native debug overlay (the F3 panel + in-world AI markers).
## `include`d rather than imported, and LAST, because it stands on everything
## above it: this file's guarded raw primitives and `attachDrain`, botdiag's
## GameWorld offsets and guarded readers (`bdOk`-style hops, `bdIsAI`,
## `bdCollectAlive`), and invoke2's verified managed-call thunks (`Instantiate`,
## `SetParentAndAlign`, `get_gameObject`). Defines `debugUiFired`,
## `debugEspRegisterFired`, `duNoteGameWorld`, `bindDebugUi` and
## `bindDebugEspWorld`.
include "debugui.nim"

## PHASE 2 -- writing into the real settings screen. `include`d LAST, after
## `debugui.nim`, because it stands on all three of the files above it at once:
## `settingsui.nim`'s label chain and tree offsets, `invoke2.nim`'s verified
## managed-call thunks, and `debugui.nim`'s guarded scalar stores plus the
## `newString` + raw-`m_text` + dirty-byte recipe that is already proven live.
## Defines `swOnTabBuilt` (called from the settings postfix) and `swNoteFault`.
include "settingswrite.nim"

## PHASE 3 -- a per-mod settings PAGE rendered into the real settings screen, by
## CLONING stock controls (the only reflection-free way to make a control on this
## build) and rebinding the clones. Stands on `settingswrite.nim` for the klass
## census and the label/value primitives, and on `invoke2.nim` for Instantiate /
## SetParentAndAlign / SetActive. Defines `swPagesOnTabBuilt`.
include "settingspages.nim"

## The main menu's bottom-right GAME MODE label ("PVE ZONE" on a stock client),
## made host/mod-controlled. `include`d after `debugui.nim` for one specific
## reason: it drains the SAME function the debug overlay drains
## (`EFT.UI.PreloaderUI::Update`) and must be able to see `gDebugUiSlot` to
## refuse rather than overwrite the overlay's trampoline. It sets the text by
## CALLING the game's own `PreloaderUI::SetGameModeText` at its static RVA --
## not by writing `TMP.m_text` -- so it does not inherit the Phase-2a repaint
## problem. See `abi/aowlspt_modetext.h`. Defines `modeTextUpdateFired`
## (dispatched by slot identity in `patchReturned`), `modeTextSetWanted` and
## `bindModeText`.
include "modetext.nim"

## SKIP THE MODE SCREEN. Included after `modetext.nim` and before
## `inspect.nim`; it shares this file's guarded primitives and logging the
## same way, and it touches none of the PreloaderUI riders above -- its two
## detours are on functions nothing else in this host names.
include "modeskip.nim"

## THE UI OVERLAY-MASK SIGNAL. Included BEFORE cursorfree.nim because
## `cursorFreeHostMask` calls its `uiStateSettingsOpen()` to free the cursor
## while the game's own Settings screen is up. Reads `gSettingsLiveSelf`
## (settingsui.nim) and the cursor level; installs NO detour, rides the
## TarkovApplication::Update drain. See `aowlspt_uistate.h`.
include "uistate.nim"

## FREE THE MOUSE WHILE AN OVERLAY PANEL IS OPEN. Included after `debugui.nim`
## because it reads that file's `gDuEdit` to know whether the F3 layout editor
## is claiming the cursor, and it installs NO detour of its own: it rides the
## `EFT.TarkovApplication::Update` drain as an alias, the same way the deferred
## Submit above it does.
include "cursorfree.nim"

## THE LIVE INSPECTOR / REPL. `include`d LAST of all, because it stands on every
## file above it at once: `settingsui.nim`'s `suiReadString` and tab registry,
## `invoke2.nim`'s byte-verified managed-call targets, `debugui.nim`'s `duOk`,
## clone anchors and GameWorld cache, and `modetext.nim`'s slot -- which it may
## have to ride on. Defines `inspectFired` (dispatched by slot identity in
## `patchFired`, alongside the overlay and the mode-text rider), `inspectPoll`
## (the host tick thread's file channel) and `bindInspect`.
##
## It is the INSTRUMENT rather than a feature: a command channel that answers a
## question about the live object graph in seconds, with no rebuild and no
## restart. See the header of `inspect.nim` for why that is the highest-leverage
## thing available on the client side.
include "inspect.nim"

## THE F2 LIVE-INSPECTOR OVERLAY -- a read-only D3D11 panel that surfaces the
## inspector's own activity (bound anchors + a scrolling ring of commands and
## their answers) so a human can WATCH a find/press/auto-raid happen on screen.
## Included right after `inspect.nim` because it reads that file's published
## snapshot and sets its `gIoCapture` tap; it draws through `debugui.nim`'s
## shared-region submitter, so it is a registration, not a detour.
include "inspoverlay.nim"

## THE MODS TAB -- a sixth tab in the game's own settings screen, with a row of
## SUBTABS inside it, every widget of it a clone of one of the game's own. It is
## included LAST because it stands on `inspect.nim`'s transform walkers,
## `debugui.nim`'s guarded call primitives and `settingspages.nim`'s row
## renderer. Default OFF (`settingsModsTab`).
include "modstab.nim"

## SHOW-EVENT HOOKS. A small registry that lets a UI feature subscribe to "this
## screen was just shown" instead of hunting for its control on a per-frame
## cadence. ONE byte-verified POSTFIX detour per SUBSCRIBED screen; nothing is
## patched for a screen nobody subscribed to. Included AFTER `inspect.nim`
## (`iUnityAlive`) and `debugui.nim` (`duOk`), and BEFORE every subscriber.
## See `docs/UIHOOKS.md` for the API and the migration recipe.
include "uihooks.nim"

## SINGLEPLAYER REBRAND of the Matchmaker Offline Raid Screen. Included AFTER
## `inspect.nim` (it stands on the transform walkers and `gTxtTypeStr`) and
## `nativeui.nim` (the byte-verified setters + SetActive). It adds NO detour:
## `splRebrandDrainTick` rides the `TarkovApplication::Update` drain the same
## way the cursor-free feature does. Default OFF (`singleplayerRebrand`).
include "splrebrand.nim"

## HOST-NATIVE AUTO-RAID. Included AFTER `inspect.nim` (it stands on the
## transform walkers, the activeInHierarchy check and the DefaultUIButton press
## path) and AFTER `splrebrand.nim` (it reuses `splAnchor`/`splTmpOf`/`splTmpText`
## and depends on the same practice-toggle forcing to keep the raid offline). It
## adds NO detour: `autoRaidDrainTick` rides the `TarkovApplication::Update` drain
## the same way `splRebrandDrainTick` does. Default OFF (`uxAutoRaid`).
include "autoraid.nim"

## NATIVE RAID ENTRY -- the replacement for the UI-automation path above, which
## stalls on the unpressable character/side-select screen. It finds and presses
## NOTHING: it calls the game's own commit path at byte-verified static RVAs.
## Included here only because it uses `hexOf`, `cIsReadable`, `cReadI32At`,
## `cWordAt` and `cRegsInt` -- it stands on none of the UI walkers. Adds NO
## detour: `nativeRaidDrainTick` rides the `TarkovApplication::Update` drain.
## Both flags default OFF (`uxNativeRaid`, `uxNativeRaidDrive`).
include "natraid.nim"

## THE NATIVE uGUI ESP -- contact boxes as REAL Tarkov GameObjects rather than
## our own overlay pixels. `include`d HERE, after `inspect.nim`, because it is
## the first file that can stand on all four of the layers it needs at once:
## `nativeui.nim`'s `nu*` construction primitives and its bounded intern table,
## `debugui.nim`'s cached `gDuGameWorld`, guarded `duPlayerPos`, `duCamera` and
## `WorldToScreenPoint` thunk, `botdiag.nim`'s `bdReadSideRole`/`bdIsYou` and
## the GameWorld offsets, and `inspect.nim`'s scene-root enumeration plus the
## byte-verified `Component::GetComponent(String)` the canvas discovery walks
## with. It resolves NO address of its own and installs NO detour:
## `natEspDrainTick` rides the `TarkovApplication::Update` drain above. Flags
## `natEsp` and `natEspDiag`, both default OFF; `natEsp` additionally requires
## `nativeUi`, because the nu* primitives are its only way to draw.
## THE SHARED RAID-PHASE PREDICATE. `include`d BEFORE `natesp.nim` (which
## consults it) and AFTER `inspect.nim` (whose `iSceneNamePresent` supplies the
## `SessionEndUIScene` end-of-raid signal) and `debugui.nim` (whose
## `gDuGameWorld` it borrows). It installs NO detour, resolves NO address and
## writes nothing; `rpDrainTick` rides the `TarkovApplication::Update` drain.
include "raidphase.nim"

## THE VANILLA RAID-LOAD TIMELINE. 33 read-only POSTFIX detours on the markers
## the game already has for its own metrics (`ClientMetricsEvents::SetGame*`),
## plus the methods that bracket the three stretches in which the client logs
## nothing at all. It reads NO game memory -- one timestamp and one interlocked
## counter per hit -- so it opens no SEH guard and cannot fault into the client;
## every string it prints is built in `lpDrainTick`, on the Update drain, never
## in a handler. `include`d here because it needs `attachDrain`, `hexOf`,
## `readCString` and the log helpers and nothing else in this host. Flag
## `loadPerf`, DEFAULT OFF. Read it with `tools/hostlog.py feature loadperf`.
include "loadperf.nim"

## THE CAMERA API and the free camera built on it. `include`d AFTER
## `raidphase.nim` (it gates on `rpPhase`, and exits+restores the moment the
## phase stops reading DEPLOYED, which is what keeps it off the post-raid
## results screen), after `debugui.nim` (it reuses that file's already-verified
## `Camera::get_main` and `Component::get_transform` rather than adding a second
## acquisition path) and after `inspect.nim` (`iUnityAlive`, `iKlassOf`). It
## installs NO detour: `camDrainTick` rides the `TarkovApplication::Update`
## drain and `camRenderTick` rides the render drain.
include "camera.nim"

## IN-RAID ACTUATION OF THE LOCAL PLAYER -- walk / look / fire / aim / pose /
## lean, the `ECommand` input channel (reload, weapon swap, inventory) and the
## magazine unload+load cycle, so a test needs nobody at the keyboard.
## `include`d AFTER `raidphase.nim` (it gates every actuation on `rpDeployed`),
## after `debugui.nim` (it borrows `gDuGameWorld` rather than adding a second
## world-acquisition path) and after `inspect.nim` (`iUnityAlive`, `iKlassOf`).
## Its whole body is inside ONE `aowl_p_p_seh`; `pactDrainTick` rides the
## `TarkovApplication::Update` drain. Flag `playerActuation`, default OFF.
##
## THE BOT DRIVE PATH DOES NOT TRANSFER, and that is measured rather than
## assumed: `mods/sain/client/drivecalls.nim` drives a `BotOwner` through
## BotMover/BotSteering/ShootData field offsets the local `EFT.Player` does not
## have. See the header of `abi/aowlspt_pact.h`.
include "pact.nim"

## THE NATIVE-UI TOOLKIT -- `nuPanel`/`nuLabel` plus a generation-checked handle
## table, the layer a mod actually calls. MOVED AHEAD OF `natesp.nim`: it now
## also holds `nuCanvasFind`, THE HOST'S ONE CANVAS-ACQUISITION FUNCTION, and
## nimony forward-resolves procs across an include boundary but not reliably
## enough to leave natesp calling into a file included after it.
##
## `nuCanvasFind` CONSUMES the live inspector's proven `iSceneRoots` +
## `iVisComponent("Canvas")` walk, which is why this must stay after
## `inspect.nim`. natesp's own breadth-first canvas search is now a FALLBACK
## behind it rather than a second implementation.
include "nuikit.nim"

## THE DEPLOY-ORDER BREADCRUMB. `include`d immediately BEFORE `natesp.nim`,
## which prints its ordering line in the per-raid deploy ledger. Four read-only
## POSTFIX drains on EFT.LocalGame, all UNIQUE, all verified against the
## STARTUP PROLOGUE SNAPSHOT. It MEASURES whether OnGameStarted is the early
## signal or the late one and changes NO gate. Default OFF
## (`natespDeployProbe`).
include "nedeploy.nim"

include "natesp.nim"
## THE IN-GAME MOD LOADING SCREEN. Included AFTER nuikit (nuPanel/nuLabel/
## nuFindCanvas/nuSetText), inspect (iChildCount/iChildAt) and splrebrand
## (splAnchor/splTmpOf) -- it consumes all three. Its handle globals are here
## rather than with the plain ones above because `NuElem` only exists from
## nuikit onwards.
var gModLoadPanel = nuNone
var gModLoadTitle = nuNone
var gModLoadRows: seq[NuElem] = @[]
var gModLoadCapStyle: NuStyle
  ## The game's own loading caption, captured. Declared here rather than beside
  ## the other gModLoad* globals because `NuStyle` is nuikit's type and nuikit
  ## is included further down.
var gModLoadCaptionNode: Il2CppPtr = nil
  ## The caption's transform. Holding it is what makes the load-phase question
  ## a single liveness check instead of a scene walk -- and its destruction is
  ## the signal that the phase ended.
var gModLoadCaptionAt = 0'u64      ## last witness search, ms
var gModLoadPhaseSaid = false      ## "we are in a load phase" said once
var gModLoadCensusDone = false
  ## The one-shot TMP census has run. It exists because two boots of the
  ## external catchcaption tool could not identify the client's loading
  ## caption -- the host is already walking those roots during the window, so
  ## it is the instrument that can actually reach it.
var gModLoadCapIdent = ""          ## the caption's name/parent, for the log
var gModLoadCapLocale = ""
  ## Whether the configured text needle agrees with the caption we matched
  ## STRUCTURALLY. Reported, never gating -- the gate stopped depending on the
  ## client's language once the object names were measured.
var gModLoadCapSawParent = ""
  ## The first non-matching parent name a TMP was seen under, so a failed pass
  ## can distinguish "the container was renamed" from "there are no labels".
var gModLoadWalkLevel = 3
  ## BISECT KNOB for the caption search: 0 = no walk at all, 1 = enumerate and
  ## validate the scene roots then stop, 2 = five nodes with a line before each
  ## managed call, 3 = normal. Key `modLoadWalkLevel`. It exists because two
  ## reasoned fixes for a client-killing crash both missed; a ladder that makes
  ## the client name the failing hop is worth more than a third guess.
var gModLoadCapFrontier: seq[Il2CppPtr] = @[]
  ## The caption search is RESUMABLE and takes one bounded slice per poll.
  ## It replaced a version that walked every scene root at full budget in ONE
  ## frame -- up to ~78,000 managed calls with their allocations -- which KILLED
  ## THE CLIENT natively ~15s into boot, with il2cpp_alloc on the stack and
  ## nothing in the log, because the tick never returned.
var gModLoadCapNodes = 0
var gModLoadCapDropped = 0
var gModLoadCapCensus: seq[string] = @[]
  ## Identities of TMPs the search passed over, collected BY that search rather
  ## than by a second walk. This is what replaces the external caption tool.
var gModLoadNeedle = "loading"
  ## Displayed-text needle for the caption; `modLoadCaption` overrides it. The
  ## match is LOCALIZED, so this is a config key rather than a constant.
include "modloadnative.nim"

include "modload.nim"


## THE FRAME METER. Included anywhere after the log helpers and `readBoolKey`;
## it names nothing from any feature module, which is the property that makes it
## a valid instrument for bisecting those features.
include "frametime.nim"

## THE DRAIN PROFILER. Same placement rule as the frame meter above: it names
## nothing from any feature module, so it stays a valid instrument for the
## features it brackets.
include "drainprof.nim"

## RAYTRACED AUDIO. Same placement rule as the two instruments above: it names
## nothing from any feature module, so it can be armed or disarmed on its own.
include "audioray.nim"

## THE SHARED PER-FRAME REGION. Included AFTER `modstab.nim` because
## `bindRegion` names `gModsSlot` and `cDuPreloaderTarget`, and nimony
## forward-resolves procs across an include boundary but NOT variables.
include "region.nim"

## THE MAIN-MENU BETA NOTICE, DRAWN ON THE OVERLAY. Included AFTER
## `region.nim` because it registers with the shared region, and after
## `invoke2.nim` because it asks `UnityEngine.Screen::get_width` for the
## back-buffer size through that file's byte-verified target table. It
## installs NO detour. Default OFF (`uxBetaOverlay`).
include "betanotice.nim"

## (`nuikit.nim` is now included further up, immediately before `natesp.nim`,
## because natesp calls its `nuCanvasFind`.)


proc bindCodeGenProbe(verbose: bool): bool =
  ## THE FOURTH RIDER on `EFT.UI.PreloaderUI::Update`, and the only reason it
  ## exists is to get `codeGenAuditSelfTest` onto Unity's main thread.
  ##
  ## Same alias-or-attach discipline as `bindInspect`: if another feature has
  ## already claimed that function, this ALIASES onto its slot and installs no
  ## second detour -- because two detours on one function have the second
  ## overwrite the first's trampoline and silently kill the first feature. Only
  ## when nobody holds it does this verify a prologue and attach its own, and it
  ## verifies through `cDuPreloaderTarget`, which compares against the ORIGINAL
  ## bytes snapshotted before any feature bound, so it cannot self-reject
  ## because someone else detoured the function first.
  ##
  ## Read-only rider: it never suppresses the original and never writes.
  if gCodeGenProbeSlot >= 0:
    return true
  if not gCodeGenAudit:
    return false
  if not gReady or gDisableDrain:
    return false
  if gDebugUiSlot >= 0:
    gCodeGenProbeSlot = gDebugUiSlot
    okLog "codeGen audit armed as a RIDER on the debug overlay's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gCodeGenProbeSlot &
          ") -- the self-test will run on Unity's main thread"
    return true
  if gModeTextSlot >= 0:
    gCodeGenProbeSlot = gModeTextSlot
    okLog "codeGen audit armed as a RIDER on the menu mode-text feature's " &
          "existing EFT.UI.PreloaderUI::Update detour (slot " &
          $gCodeGenProbeSlot & ")"
    return true
  if gInspSlot >= 0:
    gCodeGenProbeSlot = gInspSlot
    okLog "codeGen audit armed as a RIDER on the live inspector's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gCodeGenProbeSlot & ")"
    return true
  let fn = cDuPreloaderTarget()
  if fn == nil:
    if verbose:
      warn "codeGen audit: EFT.UI.PreloaderUI::Update did not verify on this " &
           "build and no other feature holds it, so the self-test cannot be " &
           "run on Unity's main thread. The host-thread pass will still run, " &
           "but on its own it cannot tell a wrong-thread artifact from a " &
           "genuinely unavailable metadata path -- which is the whole question."
    return false
  if attachDrain("EFT.UI.PreloaderUI::Update", fn, cast[Il2CppMethod](0),
                 true, verbose, 16'i32):
    okLog "codeGen audit armed on EFT.UI.PreloaderUI::Update (per-frame, " &
          "Unity thread); the self-test runs once, there, read-only"
    return true
  result = false


proc bindSplPreloaderAnchor(verbose: bool): bool =
  ## Guarantee the durable DontDestroyOnLoad anchor (`gSplUpdatePreloader`) is
  ## captured whenever singleplayerRebrand OR forceOfflinePractice is on -- the
  ## SECOND half of fact #234's fix. That anchor is captured in the shared
  ## `EFT.UI.PreloaderUI::Update` block, which only runs when SOME rider holds
  ## that function. With liveInspector OFF (the shipped beta) and no other
  ## PreloaderUI rider on, it never ran, so `splFindScreen` had no anchor and
  ## enumerated no DontDestroyOnLoad roots -- the rebrand/offline-force silently
  ## never fired. This makes the singleplayer feature its OWN rider so it no
  ## longer depends on the inspector or any other feature.
  ##
  ## Same alias-or-attach discipline as `bindCodeGenProbe` (two detours on one
  ## function have the second overwrite the first's trampoline): if another
  ## feature already holds `PreloaderUI::Update`, the anchor is ALREADY being
  ## captured every frame, so this only records the slot and installs nothing.
  ## Only when nobody holds it does this verify the ORIGINAL prologue (via
  ## `cDuPreloaderTarget`, against the startup snapshot, so it cannot self-reject)
  ## and attach its own read-only rider. It carries no handler and never
  ## suppresses the original.
  if gSplPreloaderSlot >= 0:
    return true
  if not (gSplOn or gSplForceOffline):
    return false
  if not gReady or gDisableDrain:
    return false
  if gDebugUiSlot >= 0:
    gSplPreloaderSlot = gDebugUiSlot
    okLog "singleplayer anchor: riding the debug overlay's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gSplPreloaderSlot &
          ") to capture the DontDestroyOnLoad menu anchor"
    return true
  if gModeTextSlot >= 0:
    gSplPreloaderSlot = gModeTextSlot
    okLog "singleplayer anchor: riding the menu mode-text feature's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gSplPreloaderSlot & ")"
    return true
  if gInspSlot >= 0:
    gSplPreloaderSlot = gInspSlot
    okLog "singleplayer anchor: riding the live inspector's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gSplPreloaderSlot & ")"
    return true
  if gCodeGenProbeSlot >= 0:
    gSplPreloaderSlot = gCodeGenProbeSlot
    okLog "singleplayer anchor: riding the codeGen audit's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gSplPreloaderSlot & ")"
    return true
  if gModsSlot >= 0:
    gSplPreloaderSlot = gModsSlot
    okLog "singleplayer anchor: riding the mods tab's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gSplPreloaderSlot & ")"
    return true
  if gRegionSlot >= 0:
    gSplPreloaderSlot = gRegionSlot
    okLog "singleplayer anchor: riding the shared region's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gSplPreloaderSlot & ")"
    return true
  let fn = cDuPreloaderTarget()
  if fn == nil:
    if verbose:
      warn "singleplayer anchor: EFT.UI.PreloaderUI::Update did not verify on " &
           "this build and no other feature holds it, so the durable " &
           "DontDestroyOnLoad menu anchor cannot be captured. The rebrand and " &
           "forceOfflinePractice will only resolve if the live inspector or " &
           "another PreloaderUI rider is on. This is a REFUSAL, not a success."
    return false
  if attachDrain("EFT.UI.PreloaderUI::Update", fn, cast[Il2CppMethod](0),
                 true, verbose, 19'i32):
    okLog "singleplayer anchor: armed its OWN EFT.UI.PreloaderUI::Update rider " &
          "(slot " & $gSplPreloaderSlot & ") to capture the DontDestroyOnLoad " &
          "menu anchor -- independent of liveInspector (fact #234). Read-only; " &
          "no handler, never suppresses the original."
    return true
  result = false


proc hostEventSubscribe(ctx: Il2CppPtr; name: Il2CppPtr; nameLen: int32;
                        cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_event_subscribe", cdecl.} =
  let n = readBytes(name, nameLen)
  if n.len == 0 or cb == nil:
    gLastError = "a subscription needs a name and a handler"
    return ErrBadArg
  tablesLock()
  gSubs.add Sub(name: n, cb: cb, user: user, modIndex: int(cast[uint](ctx)))
  tablesUnlock()
  okLog "subscribed to " & n
  result = StatusOk

# --------------------------------------------------------------- store

proc guidOf(idx: int): string = modhost.modGuidOf(idx)

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
  ## Queued for whichever thread drains it, which is the point of this whole
  ## file's newest part: when a per-frame method could be detoured, that is
  ## Unity's own main thread and the name means what it says. When none could,
  ## it is the host's own attached thread, and the log says so at boot rather
  ## than letting the name imply otherwise. A mod can ask which it got --
  ## `call("aowlspt.host::main_thread")`.
  if cb == nil:
    return ErrBadArg
  enqueue(cb, user, cNowMs(), int(cast[uint](ctx)), false)
  result = StatusOk

proc hostInvokeRender(ctx: Il2CppPtr; cb: Il2CppPtr; user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_invoke_render", cdecl.} =
  ## Queued for the RENDER-phase drain: `cb` runs on Unity's thread during
  ## rendering, where `GL.*` immediate-mode drawing lands on the frame. This is
  ## what ESP and GL-HUD mods use instead of `invoke_main`, whose callback is on
  ## the same thread but in the update phase where GL draws nothing.
  ##
  ## Refused when no render-phase target is bound, rather than queued into a
  ## drain that will never run: a mod should gate on
  ## `call("aowlspt.host::render_thread")`, and refusing here keeps the queue
  ## from growing without a drainer if it does not. The BSG render callback the
  ## drain rides is raid-time, so on the menu this returns unavailable.
  if cb == nil:
    return ErrBadArg
  if gRenderDrainSlot < 0:
    gLastError = "no render-phase drain is bound (no GL render point could be " &
                 "detoured on this build, or the game is not in a raid yet)"
    return ErrUnsupported
  enqueueRender(cb, user, int(cast[uint](ctx)), false)
  result = StatusOk

proc hostSchedule(ctx: Il2CppPtr; delayMs: int32; cb: Il2CppPtr;
                  user: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_schedule", cdecl.} =
  ## Same queue, same thread as `invoke_main`, and deliberately so.
  ##
  ## The alternative was to leave delayed callbacks on the host thread, where
  ## the timing is better: the host ticks every 16ms regardless of what the
  ## game is doing, whereas the drain resolves a delay at frame granularity and
  ## a frame can be long. That was rejected. A mod that says "do this in two
  ## seconds" almost always means work of the same kind `invoke_main` carries,
  ## and if `schedule` stayed on the host thread the only way to get a *delayed
  ## main-thread* call would be to schedule a callback that calls `invoke_main`,
  ## paying two hops and an extra frame for something the host can just do. The
  ## cost is honest and small: a delay is now "at the first frame at or after
  ## the deadline", not "within a millisecond of it".
  if cb == nil:
    return ErrBadArg
  var d = delayMs
  if d < 0'i32: d = 0'i32
  enqueue(cb, user, cNowMs() + uint64(d), int(cast[uint](ctx)), false)
  result = StatusOk

# --------------------------------------------------------------- mods
#
# The loader is `host/common/modhost.nim` and is shared with the backend:
# discovery, the ABI version probe, `describe`/`init`/`on_load`, the mod table,
# ticking, and taking one out again. This host used to carry a near-verbatim
# copy of all of it. What is left here is the part that is genuinely this
# host's: what a mod leaves behind in *this* process, and the one entry in the
# host block only a host with a managed heap can fill.

proc armLive(hostBlock: Il2CppPtr) =
  ## `modhost.setHostBlockArm` calls this once per mod, after
  ## `aowl_hostapi_new` has built the block and before `aowlspt_init` is handed
  ## it. See `cHostApiArmLive` above for why the shared builder cannot do it.
  cHostApiArmLive(hostBlock)
  # And revision 4, after it, so `size` only ever grows. Two calls rather than
  # one because they are two capabilities: `handle_pointer` needs a managed heap
  # and `patch_typed` needs the detour engine, and `size` is a statement about
  # what was filled rather than about which header this was built from.
  cHostApiArmTyped(hostBlock)
  # And revision 6, `invoke_render`. Armed unconditionally: the entry is always a
  # real function, and it answers `ErrUnsupported` on its own until a render-phase
  # drain binds (which is typically raid-time). Arming it here rather than when
  # the render drain binds means a mod loaded in the menu already has the entry
  # and can start using it the moment `call("aowlspt.host::render_thread")` turns
  # true, without the host block having to be rebuilt.
  cHostApiArmRender(hostBlock)

proc dropModRegistrations(index: int) =
  ## Everything the mod at `index` left in this host, dropped before its library
  ## is freed.
  ##
  ## Order within this proc does not matter; the order *around* it does, and the
  ## loader guarantees it -- this runs after the mod's `on_unload` and before
  ## `FreeLibrary`. Every item here holds a function pointer into that library,
  ## so anything missed becomes a call into unmapped memory: a detour the game
  ## still jumps to, a subscriber an event still reaches, a timer that still
  ## comes due.
  tablesLock()
  var kept: seq[Sub] = @[]
  for sub1 in gSubs:
    if sub1.modIndex != index:
      kept.add sub1
  gSubs = kept
  # THE GC HANDLES, under the same lock. Not a function pointer into the mod --
  # nothing here crashes when the library goes -- but every one still held is a
  # game object the collector may not move or free for the rest of the session.
  # This is the item that made client-side hot reload a leak rather than a
  # capability, and it is closed here rather than in each mod's `on_unload`
  # because a contract every author has to remember is not a contract.
  let freed = releaseModHandles(index)
  trimHandles()
  tablesUnlock()
  # Said always, including the zero. A mod whose own `on_unload` releases its
  # handles -- `sain` does -- should produce 0 here, so a non-zero count from one
  # that believes it cleans up is the bug report, and a silent zero would be
  # indistinguishable from never having looked.
  # Worded so the ZERO case cannot be misread. The first version said "released
  # 0 GC handle(s) still held by mod slot 1", which a reader (and a relayed
  # excerpt that clipped the leading count) took as "handles are still held" --
  # i.e. as the cause of a locked DLL, which it was not. A diagnostic that reads
  # as an accusation when it is reporting success costs more than it gives.
  if freed == 0:
    okLog "hotreload: mod slot " & $index & " held no GC handles at teardown " &
          "(it released its own, which is what a well-behaved mod does)"
  else:
    warn "hotreload: mod slot " & $index & " still held " & $freed &
         " GC handle(s) at teardown; the host has freed them. The mod's own " &
         "on_unload should have -- this count is a bug report against the mod, " &
         "not against the unload."

  # Under the lock, because the drain runs on the game thread and may be part
  # way through this same list while a mod is being unloaded.
  cMqLock()
  var keptPending: seq[Pending] = @[]
  for pend in gPending:
    if pend.modIndex != index:
      keptPending.add pend
  gPending = keptPending
  cMqSetCount(int32(gPending.len))
  # The render queue holds function pointers into the same libraries, so it is
  # rebuilt under the same lock -- a render callback left behind after its mod is
  # freed is a jump into unmapped memory on the render thread.
  var keptRender: seq[Pending] = @[]
  for pend in gRenderPending:
    if pend.modIndex != index:
      keptRender.add pend
  gRenderPending = keptRender
  cRqSetCount(int32(gRenderPending.len))
  cMqUnlock()

  # The detours, under the lock: this releases slots back to the engine while
  # another thread may be claiming one, and it bumps each slot's generation --
  # which is what makes a firing that is in flight right now get dropped rather
  # than delivered to whoever takes the slot next. `okLog` is inside it and
  # that is a file write under a lock; it happens once per removed detour, on
  # an unload, and the alternative is collecting the names to print afterwards
  # for no benefit anybody can measure.
  tablesLock()
  for i in 0 ..< gPatches.len:
    if gPatches[i].live and gPatches[i].modIndex == index:
      let what = gPatches[i].target
      gPatches[i].live = false
      discard cHookRemove(gPatches[i].hook)
      # The engine's postfix table is indexed by slot and outlives the hook, so
      # it is cleared here too. A slot left armed would send the next patch to
      # take it down the postfix path with a prefix handler on the other end.
      cHookSetPostfix(int32(i), 0'i32)
      cHookFree(gPatches[i].hook)
      # And the slot itself, which is the whole point of a teardown that runs
      # while the game is still going. Without this the pool was one-way: the
      # method's bytes went back and the trampoline was freed, but the slot
      # stayed spent, so sixteen mod toggles into a session `patch()` answered
      # "no free patch slots" with every one of them holding nothing.
      #
      # The row is cleared to match. `cHookRelease` may hand this slot out
      # again, and a stale row would put the old mod's handler pointer -- into
      # a library that has been freed -- behind the new patch's number.
      gPatches[i] = deadPatch()
      cHookRelease(int32(i))
      okLog "removed the detour on " & what
  tablesUnlock()

proc digitsIn(text: string): int =
  ## The last run of digits in a string, as a number. Used on a url, where the
  ## port is the only number that can appear after the host -- `127.0.0.1:6969`
  ## gives 6969 rather than 127.
  result = 0
  var n = 0
  var any = false
  for ch in text:
    if ch >= '0' and ch <= '9':
      n = n * 10 + (ord(ch) - ord('0'))
      any = true
    else:
      if any:
        result = n
      n = 0
      any = false
  if any:
    result = n

proc readBackendPort(): int =
  ## The port the backend is on. Zero means "do not try", and the overlay then
  ## shows what the host knows rather than nothing at all.
  ##
  ## Two places, in order. `aowlspt-host.json`'s `backendPort` is the player's
  ## own setting and wins. Failing that, `backend.json` -- which the **installer**
  ## writes, naming the backend it just installed. Without that second half the
  ## shipped default (`backendPort: 0`) left the overlay and the in-game mod
  ## manager switched off on every fresh install, next to a file that said
  ## exactly where the backend was, and the only way to find out was to read the
  ## documentation for a setting nobody knew they needed.
  result = 0
  var text = ""
  if readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    var value = ""
    if pathGet(text, "backendPort", value):
      result = digitsIn(value)
  if result > 0:
    return
  var cfg = ""
  if readTextFile(joinPath(gDir, "backend.json"), cfg):
    var url = ""
    if pathGet(cfg, "backendUrl", url):
      let port = digitsIn(url)
      # A url with no port in it (`http://localhost/`) means the default HTTP
      # port, which this backend never listens on; treating that as a port
      # would have the host talk to something that is not it.
      if port > 0 and port < 65536:
        result = port

proc removePatches() =
  ## Every detour comes out before the host stops. Leaving one installed means
  ## the game jumps into a DLL that may be gone.
  tablesLock()
  for i in 0 ..< gPatches.len:
    if gPatches[i].live:
      gPatches[i].live = false
      discard cHookRemove(gPatches[i].hook)
      cHookSetPostfix(int32(i), 0'i32)
      cHookFree(gPatches[i].hook)
      gPatches[i] = deadPatch()
      cHookRelease(int32(i))
  tablesUnlock()

proc readSyncMs(): int =
  ## How often to ask the backend which client-side mods should be running,
  ## from `aowlspt-host.json`, key `modSyncMs`. Zero switches the whole thing
  ## off and leaves this host doing exactly what it did before it existed.
  ##
  ## Three seconds by default. It is a control loop over loaded code, not a
  ## display: the change it reacts to is a person clicking a switch, and the
  ## difference between reacting in one second and in three is not worth a
  ## request per second for the rest of the session.
  result = 3000
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    return
  var value = ""
  if pathGet(text, "modSyncMs", value):
    var n = 0
    var any = false
    for ch in value:
      if ch >= '0' and ch <= '9':
        n = n * 10 + (ord(ch) - ord('0'))
        any = true
    if any: result = n

proc stopOverlay() =
  if overlayRunning():
    overlayStop()

proc opsCount(): int = modhost.modCount()
proc opsGuid(i: int): string = modhost.modGuidOf(i)
proc opsName(i: int): string = modhost.modNameOf(i)
proc opsVersion(i: int): string = modhost.modVersionOf(i)
proc opsPath(i: int): string = modhost.modPathOf(i)
proc opsLive(i: int): bool = modhost.modIsLive(i)
proc opsFlags(i: int): uint32 = modhost.modFlagsOf(i)
proc opsIndex(guid: string): int = modhost.modIndexOf(guid)

proc opsReleased(): bool =
  ## Did the last unload actually free the library? Both halves must agree: the
  ## module must no longer be mapped AND the file must be writable. Either alone
  ## has a false pass in it -- a path can be unwritable for reasons that have
  ## nothing to do with us, and a module can be absent from the name lookup while
  ## a handle keeps the file open.
  result = not modhost.lastReleaseStillMapped() and
           modhost.lastReleaseCode() == 0'i32

proc opsHot(i: int): bool =
  ## Whether the mod at `i` declared AOWLSPT_MOD_HOT_RELOADABLE.
  ##
  ## Wired on the CLIENT ONLY. `modcontrol.doUnload` refuses by name for a mod
  ## this answers false for, and the mod stays loaded. See the note at the head
  ## of `modcontrol.nim` for why this side is the one that gates: the teardown
  ## covers what a mod registered through the host and cannot cover what it took
  ## directly -- a strong GC handle on a game object, a thread, a pointer handed
  ## to the game -- and on the client that difference is an access violation in
  ## a live raid rather than a stale route.
  ##
  ## `1'u32` written out rather than `modhost.ModHotReloadable`: an imported
  ## `const` arrives untyped and `and` then has no overload to pick. Same
  ## workaround, and same reason, as `aowlsim.nim` -- named here so a search for
  ## either finds the other.
  result = (modhost.modFlagsOf(i) and 1'u32) != 0'u32

proc opsQuiesce(): int32 =
  ## Is this a safe moment to call `FreeLibrary` on a mod?
  ##
  ## Answered from `cMqFireCount()` -- the fire counter of the main-thread drain
  ## this host ALREADY owns. That is the point: it rides a detour that is bound,
  ## proven and reported on elsewhere in this file, so it adds no second detour
  ## to a function (which would overwrite the first's trampoline) and no new
  ## prologue to verify.
  ##
  ## Three states, and the third is the reason this is not a bool:
  ##
  ##  * `QuietUnknown` when the drain is not bound, has never been proven to
  ##    fire, or is currently stalled. The host cannot see Unity's main thread,
  ##    so it does not know what the game is doing, so it must NOT answer quiet.
  ##    "I could not look" counted as a pass is the check that cannot fail.
  ##  * `QuietBusy` when the counter has not advanced since the last ask. A
  ##    scene teardown is exactly this: the player loop stops calling the hooked
  ##    method for hundreds of milliseconds. That is the window the two dead
  ##    runs freed their libraries in.
  ##  * `QuietYes` only after `QuietRuns` consecutive asks each saw the counter
  ##    advance. One advancing sample is a frame; several in a row is a game
  ##    that is running rather than one that is between things.
  ##
  ## Deliberately NOT derived from `gInRaidLast`: that is the backend's opinion,
  ## it arrives on a poll that was measured 25 s stale in the very incident this
  ## exists for, and a stale opinion read as a safe point is how we got here.
  const QuietRuns = 8
  if gDrainSlot < 0 or not gDrainProven or gDrainStalled:
    gQuietRun = 0
    return modcontrol.QuietUnknown
  let fires = int(cMqFireCount())
  if fires == gQuietLastFire:
    gQuietRun = 0
    return modcontrol.QuietBusy
  gQuietLastFire = fires
  if gQuietRun < QuietRuns:
    gQuietRun = gQuietRun + 1
    return modcontrol.QuietBusy
  result = modcontrol.QuietYes

proc opsCanUnload(ignored: int): bool = modhost.hasTeardown()
  ## True here in every run that reached `hostMain`, which installs
  ## `dropModRegistrations` before it loads anything. Asked of the loader
  ## rather than answered `true` outright: the loader is what refuses an
  ## unload without a teardown, and a capabilities reply that disagreed with it
  ## would have the manager offer a switch that always answers "deferred".

proc opsLoad(path: string): bool =
  modhost.loadOne(path, modhost.SideClient, HostName, HostVersion)

proc opsUnload(guid: string): string =
  ## Empty on success; otherwise the sentence the manager shows.
  ##
  ## `modhost.unloadByGuid` runs the mod's `on_unload`, then the teardown
  ## installed below -- which is where this host's detours, subscriptions and
  ## queued callbacks go -- and only then frees the library. The slot is kept
  ## rather than removed, because every context pointer handed to a mod is its
  ## index and compacting would repoint the survivors at their neighbours.
  var err = ""
  if not modhost.unloadByGuid(guid, err):
    return (if err.len > 0: err else: "the host refused to unload " & guid)
  # The overlay's row, marked stopped rather than dropped. Read back out of the
  # slot, which is still there: the loader keeps dead slots so that the context
  # pointers it handed out stay pointing at the right mod, and a dead slot
  # still carries what that mod said about itself.
  for i in 0 ..< modhost.modCount():
    if modhost.modGuidOf(i) == guid:
      overlaySetMod(guid, modhost.modNameOf(i), modhost.modVersionOf(i), false)
  result = ""

proc opsLog(msg: string) = info msg

proc startModControl() =
  modcontrol.controlInit(HostName, HostVersion, modhost.SideClient,
                         hostEmit,
                         HostOps(count: opsCount, guidOf: opsGuid,
                                 nameOf: opsName, versionOf: opsVersion,
                                 pathOf: opsPath, liveOf: opsLive,
                                 flagsOf: opsFlags, indexOf: opsIndex,
                                 canUnload: opsCanUnload, load: opsLoad,
                                 unload: opsUnload, log: opsLog,
                                 hotOf: opsHot, quiesce: opsQuiesce,
                                 released: opsReleased))

# --------------------------------------------------------------- runtime

proc waitForIl2Cpp(timeoutMs: int): bool =
  ## The host is injected before the game has built its runtime, so this waits.
  ##
  ## What it waits *on* is the correction of a crash. This used to poll
  ## `il2cpp_domain_get` until it answered, on the reasoning -- written in the
  ## comment that was here -- that the module appears well before the domain
  ## does, so the module alone is not enough to go on. The first half of that
  ## is true. The conclusion drawn from it was not: `il2cpp_domain_get` before
  ## `il2cpp_init` has run does not return nil, it reads a global that has not
  ## been written and faults inside the runtime. On the first real client this
  ## took the game down, with our own frame directly above the runtime's in
  ## `Player.log`. There is nothing here that can be polled, because *asking is
  ## the unsafe act*.
  ##
  ## So the signal comes from the other side: `aowlspt_il2cppready.h` arms a
  ## replacement for `GetProcAddress` in `UnityPlayer.dll`'s import table in
  ## the DLL constructor, and sets a flag when the `il2cpp_init` it handed out
  ## returns. Until that flag is set this touches nothing in the runtime -- not
  ## even to open it, since `openIl2Cpp` resolves exports and there is no need
  ## to have them before there is a domain to use them on.
  var waited = 0
  var nextNote = 10000
  # Said as soon as it is known, not at the end.
  #
  # The timeout report below carries the same numbers, and on the first real
  # client it never printed once: the game exited in under ten seconds, so the
  # only line that would have explained why was one the process did not live
  # long enough to write. A diagnosis that is only produced after a two-minute
  # wait is not available for any failure that is faster than two minutes --
  # which is most of them.
  var toldInit = 0
  while waited < timeoutMs:
    if cIl2Calls() != toldInit:
      toldInit = cIl2Calls()
      if cIl2Rc() != 0:
        okLog "il2cpp_init returned " & $cIl2Rc() & " after " & $waited & "ms"
      else:
        fail "il2cpp_init returned 0 after " & $waited & "ms, which is a " &
             "failure: the runtime did not initialise. Nothing will resolve, " &
             "and this is the game's own failure rather than the host's"
    if cIl2Ready() != 0:
      if not gRt.loaded:
        gRt = openIl2Cpp("")
      if gRt.loaded:
        # Safe now, and only now. A nil here is a real answer rather than a
        # fault, and is reported as one instead of being retried forever.
        let d = domainGet(gRt)
        if d != nil:
          gDomain = d
          okLog "IL2CPP is up after " & $(waited div 100 * 100) & "ms: " &
                "il2cpp_init returned " & $cIl2Rc() & " and was handed out " &
                $cIl2Seen() & " time(s)"
          return true
        fail "il2cpp_init returned " & $cIl2Rc() & " but there is no domain; " &
             "refusing to call into the runtime"
        return false
      fail "il2cpp_init has run but GameAssembly.dll could not be opened"
      return false
    cSleep(100'i32)
    waited = waited + 100
    if waited >= nextNote:
      # Otherwise a slow launch is indistinguishable from a hung host -- and
      # since the arming is what makes this terminate, say whether it happened.
      if cIl2Armed() == 0:
        warn "still waiting for the runtime (" & $(waited div 1000) & "s), " &
             "and nothing is watching for it: the il2cpp_init lookup was " &
             "never armed, so this will wait out its timeout"
      else:
        info "still waiting for the runtime (" & $(waited div 1000) & "s)"
      nextNote = nextNote + 10000
  # Not just "it did not come up": what was watched, whether the watch was
  # armed, and what the runtime said the last time it was asked to initialise.
  # A zero here is `il2cpp_init` reporting failure, which is a different
  # problem from a slow disk and must not read like one.
  fail "the runtime did not come up: the il2cpp_init lookup was " &
       (if cIl2Armed() != 0: "armed" else: "NOT armed") &
       ", init was handed out " & $cIl2Seen() & " time(s), called " &
       $cIl2Calls() & " time(s), and last returned " & $cIl2Rc() &
       " (non-zero is success)"
  result = false

proc readStaticBridgeEnabled(): bool =
  ## `aowlspt-host.json` beside the DLL, key `bridgeStaticRva`. Non-zero opts
  ## into the fragile static-RVA drain path (default off); absent or 0 keeps the
  ## safe by-name-only behaviour. A boolean read the same shallow way the other
  ## host settings are, so it needs no JSON parser.
  result = false
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    return
  let needle = "\"bridgeStaticRva\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  # true, or any non-zero digit
  if i < text.len and text[i] == 't':
    result = true
  elif i < text.len and text[i] >= '1' and text[i] <= '9':
    result = true

proc readBoolKey(key: string): bool =
  ## A shallow boolean read of one `aowlspt-host.json` key: true, or a non-zero
  ## leading digit, is true; absent or 0/false is false. Shared by the bridge's
  ## diagnostic flags, none of which is worth a JSON parser.
  result = false
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    return
  let needle = "\"" & key & "\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  if i < text.len and text[i] == 't':
    result = true
  elif i < text.len and text[i] >= '1' and text[i] <= '9':
    result = true

proc readBoolKeyDef(key: string; dflt: bool): bool =
  ## Like `readBoolKey`, but distinguishes ABSENT (return `dflt`) from PRESENT-
  ## and-false. Used for flags that default ON: `forceOfflinePractice`. Same
  ## shallow shape as `readBoolKey` -- no JSON parser. `tools/hostcfg.py` knows
  ## this reader (its BOOL_CALL regex accepts the `Def` suffix), so a key read
  ## this way is still one `set` can write.
  result = dflt
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    return
  let needle = "\"" & key & "\""
  let at = find(text, needle)
  if at < 0:
    return                                   # absent -> the default
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  if i < text.len and text[i] == 't':
    result = true
  elif i < text.len and text[i] == 'f':
    result = false
  elif i < text.len and text[i] == '0':
    result = false
  elif i < text.len and text[i] >= '1' and text[i] <= '9':
    result = true

proc readStrKey(key: string): string =
  ## A shallow read of one `aowlspt-host.json` STRING key: the contents of the
  ## first double-quoted run after `"key":`. Deliberately the same shallow shape
  ## as `readBoolKey` above, and for the same reason -- none of these settings is
  ## worth dragging a JSON parser into the host for.
  ##
  ## Returns "" when the key is absent, when the file is unreadable, or when the
  ## value is not a quoted string. It does NOT decode escapes: every key read
  ## this way is an opaque identifier (a Mongo profile id is hex), and silently
  ## half-decoding an escape would be worse than not accepting one.
  result = ""
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    return
  let needle = "\"" & key & "\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  if i >= text.len or text[i] != '"':
    return
  inc i
  var acc = ""
  # CAPPED, like every other loop that reads game-adjacent data: a file with an
  # unterminated quote must not become an unbounded scan.
  var guard = 0
  while i < text.len and text[i] != '"' and guard < 512:
    acc.add text[i]
    inc i
    inc guard
  if i < text.len and text[i] == '"':
    result = acc

proc readStrListKey(key: string): seq[string] =
  ## A shallow read of one `aowlspt-host.json` STRING-ARRAY key:
  ## `"hostHttpAllow": ["127.0.0.1", "localhost"]` -> `@["127.0.0.1",
  ## "localhost"]`. Same deliberately-shallow shape as `readBoolKey` /
  ## `readStrKey` above, and for the same reason.
  ##
  ## `readStrKey` CANNOT be used for these: it requires the first non-space
  ## character after the key to be a `"`, and for an array it is a `[`, so it
  ## returns "" -- an empty allowlist, which refuses everything, for entirely
  ## the wrong reason. That is exactly the shape of failure section 9b is
  ## about, so the array gets its own reader rather than a caller that
  ## "knows".
  ##
  ## Returns @[] when the key is absent, unreadable, or not an array. Bounded
  ## on both axes: at most 32 entries, at most 512 characters each.
  ##
  ## `tools/hostcfg.py`'s `STR_CALL` regex accepts `readStrKey` and
  ## `readStrListKey` alike, so a key read this way is still a key that tool
  ## knows about -- a key it cannot see is a key it refuses to write.
  result = @[]
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    return
  let needle = "\"" & key & "\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  if i >= text.len or text[i] != '[':
    return
  inc i
  var entries = 0
  var guard = 0
  while i < text.len and text[i] != ']' and entries < 32 and guard < 8192:
    inc guard
    if text[i] == '"':
      inc i
      var acc = ""
      var n = 0
      while i < text.len and text[i] != '"' and n < 512:
        # An escaped backslash is the only escape a Windows path needs, and it
        # is the only one honoured: `"D:\\Aowlspt"` -> `D:\Aowlspt`.
        if text[i] == '\\' and i + 1 < text.len:
          inc i
        acc = acc & text[i]
        inc i
        inc n
      if i < text.len and text[i] == '"':
        inc i
        result.add acc
        inc entries
      else:
        return                   # unterminated -- report NOTHING, not a half
    else:
      inc i

proc readDrainDisabled(): bool = readBoolKey("bridgeDisableDrain")

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

proc readIntKey(key: string; def: int): int =
  ## A shallow non-negative integer read of one `aowlspt-host.json` key, same
  ## shape as `readWaitMs` / `readBoolKey`. Returns `def` when the key is absent,
  ## unreadable, or not a run of digits. No JSON parser, on purpose.
  result = def
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-host.json"), text):
    return
  let needle = "\"" & key & "\""
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

# ------------------------------------------------------- backend key dump
#
# One-shot, diagnostic: read the client's baked HTTP body-crypto material so a
# captured session can be decrypted offline. Post-1.0 encrypts /client/game/*
# response bodies with AES (see reference_post1_aes_layer); the key and IV pool
# live as static byte[] fields on the global `HTTPTransportManager`. The three
# reads below (byte_at / read_ptr / is_readable) are the same C shims il2cpp.nim
# uses; they are re-declared here because that module keeps them file-private.
proc hByteAt(p: Il2CppPtr; i: uint64): uint8 {.importc: "aowl_byte_at", nodecl.}
proc hReadPtr(p: Il2CppPtr; off: int32): Il2CppPtr {.importc: "aowl_read_ptr", nodecl.}
proc hReadable(p: Il2CppPtr; size: int32): int32 {.importc: "aowl_is_readable", nodecl.}

proc il2ByteArrayHex(arrPtr: Il2CppPtr): string =
  ## An IL2CPP `byte[]` as hex: element count at +0x18, data at +0x20. Every
  ## read is VirtualQuery-guarded to its FULL extent first -- a raw read past a
  ## committed region faults on the host thread and takes the whole game down
  ## (which is exactly what an under-guarded first attempt did).
  if arrPtr == nullPtr() or hReadable(arrPtr, 0x20'i32) == 0'i32:
    return "<unreadable>"
  let n = int(cast[uint](hReadPtr(arrPtr, 0x18'i32)))
  if n < 0 or n > 8192: return "<len " & $n & ">"
  if hReadable(arrPtr, int32(0x20 + n)) == 0'i32:
    return "<data unreadable, len " & $n & ">"
  const digits = "0123456789abcdef"
  result = ""
  for i in 0 ..< n:
    let b = hByteAt(arrPtr, uint64(0x20 + i))
    result.add digits[int(b shr 4'u8)]
    result.add digits[int(b and 0xF'u8)]

proc staticFieldPtr(cls: Il2CppClass; fieldName: string): Il2CppPtr =
  ## No `runtimeClassInit` here: it RUNS the managed static constructor, and on
  ## the host's own (non-Unity) thread that faults and kills the game. By the
  ## time this runs the client has long since initialised the class itself, so
  ## the static data is already there to read -- these are pure C-API reads.
  okLog "keydump: findField " & fieldName
  let f = findField(gRt, cls, fieldName)
  okLog "keydump: findField returned"
  if f == nullPtr():
    warn "keydump: field " & fieldName & " not found"
    return nullPtr()
  let sdata = staticFieldData(gRt, cls)
  okLog "keydump: staticFieldData returned"
  if sdata == nullPtr():
    warn "keydump: no static data for " & fieldName
    return nullPtr()
  let off = fieldOffset(gRt, f)
  okLog "keydump: " & fieldName & " off=" & $off
  if off < 0 or off > 65536: return nullPtr()
  if hReadable(sdata, int32(off + 8)) == 0'i32:
    warn "keydump: static slot for " & fieldName & " unreadable"
    return nullPtr()
  result = hReadPtr(sdata, int32(off))

proc dumpBackendKey() =
  okLog "keydump: starting"
  var count = 0
  let assemblies = domainGetAssemblies(gRt, gDomain, count)
  if assemblies == nil: return
  # Find the class by ENUMERATING real classes (imageGetClass by index) and
  # matching the name -- classFromName with an empty namespace handed back bogus
  # non-NULL pointers whose name read faulted. Every class from imageGetClass is
  # a real one, so className on it is safe (guarded anyway).
  var cls: Il2CppClass = nullPtr()
  for i in 0 ..< count:
    let image = assemblyGetImage(gRt, assemblyAt(assemblies, i))
    if image == nil: continue
    if imageGetName(gRt, image) != "Assembly-CSharp.dll": continue
    let cc = imageGetClassCount(gRt, image)
    okLog "keydump: scanning " & $cc & " classes in Assembly-CSharp"
    for k in 0 ..< cc:
      let c = imageGetClass(gRt, image, k)
      if c == nullPtr() or hReadable(c, 8'i32) == 0'i32: continue
      if classNameSafe(gRt, c) == "HTTPTransportManager":
        cls = c
        break
    break
  if cls == nullPtr():
    warn "keydump: HTTPTransportManager not found by enumeration"
    return
  okLog "keydump: found HTTPTransportManager, reading statics"
  let keyPtr = staticFieldPtr(cls, "_key")
  okLog "KEYDUMP _key: " & il2ByteArrayHex(keyPtr)
  let poolPtr = staticFieldPtr(cls, "_ivPool")
  if poolPtr == nullPtr() or hReadable(poolPtr, 0x28'i32) == 0'i32:
    warn "keydump: _ivPool unreadable"
  else:
    let n = int(cast[uint](hReadPtr(poolPtr, 0x18'i32)))
    okLog "KEYDUMP _ivPool outer-len: " & $n
    # As a flat byte[] (in case the pool is one contiguous buffer):
    okLog "KEYDUMP _ivPool flat: " & il2ByteArrayHex(poolPtr)
    # As a jagged byte[][] (elements are byte[] pointers at +0x20 + i*8):
    if n > 0 and n <= 64 and hReadable(poolPtr, int32(0x20 + n * 8)) != 0'i32:
      for i in 0 ..< n:
        let inner = hReadPtr(poolPtr, int32(0x20 + i * 8))
        okLog "KEYDUMP _ivPool[" & $i & "]: " & il2ByteArrayHex(inner)

proc reportRuntime() =
  let gaps = missingEssential(gRt)
  if gaps.len > 0:
    for g in gaps:
      fail "essential IL2CPP entry point missing: " & g
    return
  okLog "IL2CPP runtime bound, all essential entry points present"

  # Neuter the BattlEye anti-cheat validation gate now that GameAssembly.dll is
  # mapped (two static .text byte patches; see aowlspt_beclient.h). Without it
  # the client shows "Anticheat loading failed / Game restart required" when the
  # menu reaches online play and quits. This is separate from the BE service
  # guard armed in the constructor.
  let becLanded = cBecNeuter()
  if cBecBaseFound == 0:
    warn "anti-cheat: GameAssembly.dll not found; BE client gate not patched"
  elif becLanded >= 2:
    okLog "anti-cheat: BE client validation gate neutered (2/2 patches)"
  else:
    warn "anti-cheat: only " & $becLanded & "/2 BE patches landed" &
         " (IsInstanceSuccessfully seen=" & $cBecIsInstSeen &
         ", OnRequestRestart seen=" & $cBecRestartSeen &
         "); offsets may not match this client build"

  # Exit-hang fix: with no BsgLauncher, confirming Exit spins forever on an
  # exit-loading screen (the async shutdown started at the confirm-accept lambda
  # never completes). Redirect the confirm-accept lambda (primary) and
  # ExitApplication (backstop) to a clean ExitProcess(0) -- static .text byte
  # patches, same discipline as the BE neuter above, firing before the async
  # work. Fail-safe: a site whose prologue does not match this build is skipped.
  let exitLanded = cUxExitNeuter()
  if exitLanded >= 1'i32:
    okLog "exit fix: confirmed Exit redirected to ExitProcess(0) (" &
          $exitLanded & "/2 sites; primary = the confirm-accept lambda, before " &
          "the async exit-loading shutdown that was hanging)"
  elif cUxBaseFound == 0:
    warn "exit fix: GameAssembly.dll not found; Exit still hangs"
  elif cUxExitSeen == 0:
    warn "exit fix: no exit prologue matched this build; Exit not patched " &
         "(Exit still hangs, nothing worse)"
  else:
    warn "exit fix: an exit prologue matched but the patch write failed"

  # OS-close hang fix (Fix 1b): the Exit-button patch above only covers the
  # in-game Exit flow. Closing the window via the title-bar X, taskbar Close, or
  # Alt+F4 posts WM_CLOSE to Unity's window proc, which funnels into the SAME
  # hanging async shutdown by a different caller. Catch those messages on the
  # game's UI thread and hard-exit (ExitProcess(0)) before any async work starts.
  #
  # LIVE FINDING: at this point (il2cpp init) the game's top-level window does
  # NOT exist yet, so there is no UI thread to hook and this first attempt is
  # expected to do nothing -- it is best-effort and quiet on failure, with the
  # host tick loop carrying the real arm.
  #
  # Gated on `osCloseFix` (default OFF): the previous implementation of this fix
  # crashed the client, so it must be switchable without a rebuild while it is
  # being re-proven.
  gOsCloseFix = readBoolKey("osCloseFix")
  if not gOsCloseFix:
    info "exit fix: osCloseFix is off; the OS window-close path is untouched " &
         "(the in-game Exit button is still patched). Set \"osCloseFix\": true " &
         "in aowlspt-host.json to arm it."
  else:
    # The message-independent console-control path is armed once here; it costs
    # nothing on a GUI launch with no console and covers the close routes that
    # never become a window message at all.
    discard cUxCloseCtrlArm()
    if cUxCloseHook() == 1'i32:
      gCloseEverArmed = true
      okLog "exit fix: OS-close hooks installed at boot on UI thread " &
            $cUxCloseTid() & " -- window-close (X / taskbar / Alt+F4) exits " &
            "via ExitProcess(0)"
    else:
      info "exit fix: game window not up yet; the OS-close hooks will be " &
           "installed from the host tick loop once the UI thread exists " &
           "(Exit button is already patched)"

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

## The last complaint written about the backend's mod set, so a server that is
## answering the wrong thing says so once rather than once every three seconds.
var gSyncError = ""

## The route the mod-sync feed is polling, without the report on the end of it,
## and how often. Empty when this host is not asking the backend anything.
var gSyncBase = ""
var gSyncMs = 0
## The last path actually handed to the feed, so an unchanged report costs
## nothing. `gReportSeq` starts at -1 rather than 0 because 0 is a real sequence
## -- the one a host has before it has decided anything -- and starting equal to
## it would suppress the first report this host ever makes.
var gSyncPath = ""
## Last raid-state the backend poll reported, so `graphicsSetInRaid` is called
## only on a change. Starts false: before any raid signal the menu is stock and
## the graphics gate (raidOnly) leaves it that way.
var gInRaidLast = false
var gReportSeq = -1
var gReportNextMs = 0'u64

## A per-mod settings page rendered into the real settings screen, fetched
## over the sync feed above and written back over the overlay's POST slot.
## Stands on `gSyncPath`/`gSyncBase`/`gSyncMs` (just declared) and on
## `settingspages.nim` (included earlier) for `SwPage`/`SwRow`/
## `swPageRegister`. Defines `modSetTick` and `modSetDrainPost`, called from
## `hostMain`'s tick loop, and `modSetQueueWrite`, which fulfils
## `settingspages.nim`'s forward declaration.
include "modsettingsrender.nim"
## THE MODS TAB'S DATA. AFTER `modsettingsrender.nim` because it reuses that
## file's `modSetParseF64`, and after `settingspages.nim` for `SwPage`/`SwRow`/
## `swPageRegister`. `modstab.nim` forward-declares `miArm`/`miTick`.
## GENERATED (tools/gen_keycodes.py) from the same global-metadata the client
## runs: UnityEngine.KeyCode ordinal -> name. Included BEFORE modsindex, which
## uses it to render a bare ordinal keybind as a key name instead of a number.
include "keycodes.nim"
include "modsindex.nim"

## STEP 1 of docs/NATIVETABS.md. After `modstab.nim` for `modsClone` /
## `modsComponent` / `modsSetParent` / `modsGoActive`, and after `nativeui.nim`
## for the byte-verified call wrappers.
include "settingsbind.nim"
include "nativetabs.nim"

## THE NATIVE COLOUR WIDGET. Fulfils `settingspages.nim`'s three forward
## declarations (`cwBuildForRow` / `cwRowColor` / `cwDestroySlot`) and defines
## `cwDrainTick`, called from the `TarkovApplication::Update` drain.
##
## Included HERE, and the position is load-bearing in both directions: it needs
## `nuikit.nim` (6014) for `nuPanel`/`nuLabel`/`nuSetColor` and
## `modsettingsrender.nim` (just above) for the `color` row that produces the
## work, and it must come BEFORE `gCwOn` is read in the flag pass, because
## nimony forward-resolves procs across an include boundary but NOT variables.
include "colorwidget.nim"

## THE POSTFX SUBTAB'S CONTENT. Fulfils `modstab.nim`'s two forward
## declarations (`pfxOnPanelUp` / `pfxOnScreenClosed`).
##
## Position is load-bearing in both directions, exactly as for the colour
## widget above: it needs `nuikit.nim` (6207) for `nuLabel`/`nuLive`/
## `nuElemRect`/`nuElemText` and `modstab.nim` (6142) for `gGfxPostGo` /
## `gGfxPostT` / `gGfxPanelT` / `modsFindTmp`, and it must come BEFORE `gPfxOn`
## is read in the flag pass, because nimony forward-resolves procs across an
## include boundary but NOT variables.
include "postfxrows.nim"
include "dlssrows.nim"

## THE POSTFX SUBTAB'S **NATIVE** ROWS -- the ones that drive the GAME'S OWN
## post-processing and shading rather than a D3D pass of ours. Additive to
## `postfxrows.nim` above and independent of it: with `settingsNativePostFx` on
## and the legacy `settingsPostFxRows` off, the page carries only these.
##
## Position is load-bearing in exactly the two directions the two files above
## are: it needs `nativeui.nim` for the byte-verified prefab wrappers
## (`nuInstantiateUnder` / `nuRowSlider` / `nuSliderValue` / `nuDropDownIndex`),
## `modstab.nim` for `gGfxPostT` / `modsComponent`, and `hostfieldwrite.nim`
## for the typed store gate the three AO rows go through -- and it must come
## BEFORE `gNpfOn` is read in the flag pass, because nimony forward-resolves
## procs across an include boundary but NOT variables.
include "nativepostfx.nim"

## THE NATIVE INVENTORY / ITEM-SPAWNER SCREEN. Defines `iuDrainTick`, called
## from the `TarkovApplication::Update` drain, and `bindInvUi`.
##
## Position is load-bearing in three directions, not two:
##   * `nuikit.nim` (6231) for `nuPanel`/`nuLabel`/`nkResolve`/`nuLive`;
##   * `inspect.nim` (6151) for `iVisComponent`/`iChildCount`/`iChildAt`, which
##     the donor-TMP walk uses, and `splrebrand.nim` (6173) for `splAnchor` --
##     the DontDestroyOnLoad anchor, since SceneManager excludes that scene by
##     design and anchoring anywhere else walks the wrong scene;
##   * `region.nim` (6248), which is the one translation unit that already
##     `#include`s `aowlspt_admin.h`. This screen reads that region's typed
##     query, and everything in that header is `static`.
## And it must come BEFORE `gIuOn` is read in the flag pass, because nimony
## forward-resolves procs across an include boundary but NOT variables.
include "invui.nim"

## Client-side mods' settings pages, published to the backend over the event
## bus so the F12 nav can list them at all. Stands on `modsettingsrender.nim`
## for the shared POST slot discipline (`gSbYieldUntil`) and on `gSyncMs`.
## Defines `sbTick`, called from `hostMain`'s tick loop.
include "settingsbridge.nim"

proc hex16(v: uint64): string =
  const digits = "0123456789abcdef"
  result = ""
  var started = false
  var shift = 60
  while shift >= 0:
    let nib = int((v shr uint64(shift)) and 0xF'u64)
    if nib != 0 or started or shift == 0:
      started = true
      result.add digits[nib]
    shift = shift - 4

proc publishReport(now: uint64) =
  ## Put what this host has actually done about the mods onto the end of the
  ## path it is already polling.
  ##
  ## This is the return leg, and it is deliberately not a channel. The client
  ## host has exactly one way to reach the backend -- the overlay's worker
  ## thread, which exists for the panel -- and `aowl_ov_sync_start` can be
  ## called again to change the path it fetches. So the report goes in the query
  ## string of the next poll: no socket, no thread, no request that would not
  ## have been made anyway, and nothing new that can fail. A push would have had
  ## to choose a moment to reach a server that may be down, which is the one
  ## property this side has spent the whole design refusing to depend on.
  ##
  ## Two reasons to rebuild, and only two:
  ##
  ##  * the report changed -- something was loaded, refused, or settled;
  ##  * the last one did not fit, and the rest are waiting their turn.
  ##
  ## Both are rate-limited to the poll interval, because the path is read by the
  ## worker once per poll and rewriting it faster changes nothing that anyone
  ## reads.
  if gSyncBase.len == 0:
    return
  # The bot registry is the THIRD reason to rebuild, and it needs to be checked
  # here rather than anywhere else: the two reasons above are both about the mod
  # rows, so a raid full of moving bots on a stage whose mods have long since
  # settled would rebuild the path exactly once and then freeze -- the census
  # would go out one time and never update again, which looks precisely like a
  # feature that does not work.
  #
  # Rate-limited by the same `gReportNextMs` as the rotation, because the worker
  # reads the path once per poll and rewriting it faster changes nothing anyone
  # reads. Publishing here also means the census the path carries is the one the
  # Unity thread had built as of this moment.
  var census = ""
  if gBotNav and not gBotNavOff:
    census = botNavCensus()
  let censusNew = census != gReportBotNav and now >= gReportNextMs
  if censusNew:
    gReportBotNav = census
    modcontrol.reportBotNav(census)
  let fresh = modcontrol.reportSeq() != gReportSeq
  let rotate = modcontrol.reportPending() and now >= gReportNextMs
  if not fresh and not rotate and not censusNew:
    return
  gReportSeq = modcontrol.reportSeq()
  gReportNextMs = now + uint64(gSyncMs)
  let path = modcontrol.reportPath(gSyncBase)
  if path == gSyncPath:
    return
  gSyncPath = path
  overlaySyncStart(path, int32(gSyncMs))
  # Only when something actually changed. A stage with more mods than fit in one
  # path rotates through them for the life of the process, and a line per
  # rotation would be a log line every few seconds saying nothing new.
  if fresh:
    info "telling the backend what happened to its mods: " & path

proc takeModSet() =
  ## Read the newest answer the backend gave about which client-side mods
  ## should be running, and queue whatever it takes to match it.
  ##
  ## Called from the host's own loop and nowhere else, immediately before
  ## `modcontrol.drain` performs what it queued. Both halves of that matter:
  ## the answer arrives on the overlay's worker thread and is only *read* here,
  ## and the load or unload itself happens in the drain, on this thread, with
  ## nothing but this host's own frames on the stack.
  ##
  ## Nothing at all happens on a poll that brought no answer, which is most of
  ## them, and nothing at all happens on an answer that does not parse. That is
  ## the whole safety argument: every failure of the far end -- down, starting,
  ## restarting, serving a 404, serving a body too big for the buffer --
  ## converges on "leave the mods alone", because the only thing that can move
  ## a mod is a complete document that says so.
  let doc = overlaySyncTake()
  if doc.len == 0:
    return
  var want: seq[DesiredMod] = @[]
  var err = ""
  if not parseDesired(doc, want, err):
    if err != gSyncError:
      gSyncError = err
      warn "the backend's client mod set was not usable, so nothing was " &
           "changed: " & err
    return
  if gSyncError.len > 0:
    gSyncError = ""
    okLog "the backend's client mod set is readable again"
  applyDesired(want, joinPath(gDir, "mods"))

  # The raid-state gate for the graphics post-process rides this same poll. Read
  # it only from a document parseDesired accepted (above), and only act on a
  # change â€” the grade turns on in a raid and the menu stays stock. An older
  # manager omits the field, parseInRaid returns false, and the last known
  # state is kept (default: not in raid, so raidOnly leaves the menu untouched).
  var raid = gInRaidLast
  if modcontrol.parseInRaid(doc, raid) and raid != gInRaidLast:
    gInRaidLast = raid
    graphicsSetInRaid(raid)
    betaNoticeSetMenu(raid)
    info "graphics: backend reports " & (if raid: "IN RAID â€” grading the world"
                                         else: "in menu â€” post-process off")

  # The beta notice's FINISHED STATE, once it has one: how many frames it
  # actually submitted on, not that we called a setter. Zero is the
  # falsifiable failure and it stays silent until there is a number.
  betaNoticeReport()

  # The menu's bottom-right game-mode label rides this same poll, for exactly
  # the reasons `inRaid` does: the client host has one way to reach the backend
  # and it is already using it, so a second channel would be a second thing that
  # can be down. Read only from a document `parseDesired` accepted, so a partial
  # or wrong-schema answer can never move the label. An older manager omits the
  # field, `parseMenuModeText` returns false, and the stock "PVE ZONE" stays.
  var wanted = ""
  if modcontrol.parseMenuModeText(doc, wanted):
    modeTextSetWanted(wanted)

  # Bot navigation commands ride the same poll for the same reason, and are held
  # to the same rule: read only from a document `parseDesired` accepted, gated
  # for length and charset in `parseBotNav` before the command grammar ever sees
  # them, and gated again per field in `bnParseCommands` before anything reaches
  # a game pointer. An older manager omits the field, `parseBotNav` returns
  # false, and no command is published -- the bots keep doing whatever their own
  # brains decided, which is the correct thing for this feature to do when it has
  # nothing to say.
  #
  # This runs on the POLL thread. It only publishes; every game-side effect
  # happens later on the Unity thread inside the guarded per-bot tick.
  if gBotNav and not gBotNavOff:
    # The registry going the other way is published in `publishReport`, which is
    # where every decision about the report path is made; nothing about it
    # belongs here.
    var navSpec = ""
    if modcontrol.parseBotNav(doc, navSpec):
      if navSpec.len == 0:
        var none: seq[BnCmd] = @[]
        bnSetWanted(none)
      else:
        let cmds = bnParseCommands(navSpec)
        bnSetWanted(cmds)

proc runPending() =
  ## The host thread's half, and it is now a much smaller half than it was.
  ##
  ## IT RUNS THE HOST'S OWN THREAD-PROOF ENTRIES AND NOTHING ELSE. Not when the
  ## drain has stalled, not when nothing bound, not ever. There is no thread
  ## other than the one the drain claimed on which a mod's main-thread callback
  ## is correct, so "the drain is not firing" cannot be a reason to run it
  ## somewhere else -- it can only be a reason to WAIT and to say so loudly.
  ##
  ## What this used to do, and what it cost (MEASURED 2026-09-02, Unity crash
  ## reports Crash_2026-09-02_204346544 and _211541986): it called `drainDue()`
  ## on the host's tick thread whenever `gDrainStalled` was set, and the tick
  ## loop set that 2 s into every boot because `TarkovApplication::Update` is
  ## not called until ~15 s. A mod's queued tick then reached
  ## `UnityEngine.Input::GetKey`, whose native body dereferences Unity's
  ## per-thread input manager with no null test, and the client died at 8.7 s.
  ## `main_thread`.`bound` said nothing was wrong the whole time.
  ##
  ## A mod that never gets its callback is a feature that does not work; a mod
  ## that gets it on the wrong thread is a client that dies. The host now
  ## chooses the first, counts it (`gMqDeferred`), and reports the depth and the
  ## reason from `mainTick`.
  if cMqCount() == 0'i32:
    return
  if gDrainSlot >= 0 and not gDrainStalled:
    # The drain still might carry them, so let it. This matters for exactly one
    # entry -- the thread proof -- and it is the whole value of that entry: if
    # this thread took it at 0:00:00 it would print "ran on the host's own
    # thread" and the real Unity-thread proof, which arrives ~15 s later when
    # `TarkovApplication::Update` is first called, would never be written at
    # all. `gDrainStalled` is now false during that wait (the state is
    # `DrainNeverFired`), which is what makes this test say "wait" instead of
    # "give up". A drain that never fires for the whole session leaves the
    # proof queued and silent HERE -- the tick loop's health report is what
    # says so, every 15 s, with the queue depth.
    return
  drainDue(true)

proc hostMain() {.exportc: "aowlspt_nim_host_main", cdecl.} =
  modhost.startClock()
  gDir = modhost.ownDirectory()
  if gDir.len == 0:
    return

  # A fresh log each launch. The interesting failure is always this run's.
  gHostThreadId = cThreadId()
  modhost.openLog(joinPath(gDir, "aowlspt-host.log"),
    HostName & " " & HostVersion & "\n" &
    "directory " & gDir & "\n" &
    "thread " & $int(gHostThreadId) & "\n\n")

  # THE COMMAND LINE, parsed ONCE, here, before anything else can want it and
  # before a single mod exists. `cmdargs.nim` owns the table; from this point
  # on it is IMMUTABLE and every reader only copies out of it, which is what
  # makes `aowlspt.host::cmdline` safe to call from a mod's own thread.
  caParseOnce()

  # The first thing said, because it is the first thing that happened and
  # because a client that does not start says nothing else. The guard ran in
  # the constructor, long before this log existed; these are its counters.
  #
  # Four states, and they are deliberately not collapsed into "on" and "off".
  # No UnityPlayer.dll at all is `hostharness` and the stand-in runtime, where
  # there is correctly nothing to do. The module present with none of the four
  # imports is a client without BSG's guard -- a different client, or a version
  # that dropped it -- and is also nothing to do. The module present with the
  # imports and nothing patched is a *failure*, and it is the one that must not
  # look like the other two, because the symptom is the game refusing to start
  # with no explanation anywhere.
  if cBeModule() == 0:
    info "no UnityPlayer.dll in this process, so BSG's BattlEye service " &
         "guard is not a question here"
  elif cBeArmed() == 0:
    info "UnityPlayer.dll imports none of the service-manager calls BSG's " &
         "BattlEye guard uses; nothing was patched and nothing needed to be"
  elif cBeArmed() < 4:
    warn "BSG's BattlEye service guard: only " & $cBeArmed() & " of 4 " &
         "import slots were patched. The client may still refuse to start, " &
         "and if it does, that is why"
  else:
    okLog "BSG's BattlEye service guard is answered from inside the process " &
          "(4 import slots); BattlEye is not installed, started or loaded"

  # The same constructor, the other patch. Reported separately and before the
  # wait, because if this did not arm the wait cannot succeed and the reason
  # has to be on the line above the symptom rather than 120 seconds below it.
  if cIl2Armed() == 0 and cBeModule() != 0:
    warn "the il2cpp_init lookup could not be armed; the runtime will be " &
         "reported as unavailable however long the game takes to come up"

  # Before a single mod is loaded, because the loader refuses an unload it has
  # no teardown for and the manager is told so in the capabilities reply.
  # `dropModRegistrations` is this host's half: subscriptions, queued
  # main-thread callbacks, and the detours the backend has no equivalent of.
  modhost.setModTeardown(dropModRegistrations)
  # And the half of the host block `aowl_hostapi_new` cannot fill.
  modhost.setHostBlockArm(armLive)

  # Before the first patch of any kind, including the host's own drain hook:
  # once this has run, `gPatches` never moves again, which is what lets the
  # firing path read it on the game's thread without a lock.
  reservePatchRows()

  storeInit(gDir)

  gAllowStaticBridge = readStaticBridgeEnabled()
  if gAllowStaticBridge:
    warn "bridgeStaticRva is set (Experiment B): the drain will bind to the " &
         "validated static RVA of TarkovApplication.Update (0x977B10); run " &
         "bridgeSettingsProbe first to confirm the detour engine on this client"
  gDisableDrain = readDrainDisabled()
  if gDisableDrain:
    warn "bridgeDisableDrain is set: no per-frame detour will be installed, " &
         "so NOTHING queued through invoke_main will ever run -- it is not " &
         "downgraded to the host thread, it is HELD (see runPending) -- and " &
         "invoke_render is unavailable"
  gUiProbe = readBoolKey("bridgeUiProbe")
  if gUiProbe:
    info "bridgeUiProbe is set: the drain self-test will also instantiate and " &
         "parent Unity UI GameObjects on the Unity thread once, to prove the " &
         "native settings-injection path"
  # The token-gated il2cpp export layer. DEFAULT OFF, and read here only;
  # it cannot BIND yet, because GameAssembly.dll is not mapped at
  # DLL-attach -- the same phase the nameIndex stamp cannot verify in.
  # Binding, the startup snapshot and the self-test all happen in
  # `hostReady`, after the runtime is up.
  gGatesOn = readBoolKey("il2cppGates")
  if gGatesOn:
    info "il2cppGates is set. The token-gated il2cpp export layer will " &
         "bind once GameAssembly.dll is mapped, and will run its live " &
         "self-test then. It is NOT bound yet and nothing resolves by " &
         "name through it: no mod has been switched over."
  # ---- the two GENERIC transport services (`hostnet.nim`) ----------------
  #
  # Both DEFAULT OFF, both answer a refusal by name when off, and neither
  # loads a DLL, creates a thread or touches game memory until it is used.
  # The allowlist and the root list have DEFAULTS rather than being empty when
  # the key is absent: an empty allowlist refuses everything, which is the
  # right behaviour for a key somebody deliberately emptied and the wrong one
  # for a key nobody has written yet.
  var hnAllow = readStrListKey("hostHttpAllow")
  if hnAllow.len == 0:
    hnAllow = @["127.0.0.1", "localhost"]
  var pwRoots = readStrListKey("hostPlayWavRoots")
  if pwRoots.len == 0:
    pwRoots = @["%TEMP%", "D:\\Aowlspt"]
  hnApplyConfig(readBoolKey("hostHttp"), hnAllow,
                readIntKey("hostHttpMaxInflight", 4),
                readIntKey("hostHttpMaxBody", 1048576),
                readBoolKey("hostPlayWav"), pwRoots)
  hnBootLog()
  gCodeGenAudit = readBoolKey("codeGenAudit")
  gRegionOn = readBoolKey("sharedRegion")
  gUnityPostProbeOn = readBoolKey("unityPostProbe")
  if gUnityPostProbeOn and not gRegionOn:
    warn "unityPostProbe is ON but sharedRegion is OFF. The Unity " &
         "post-processing survey is driven from the region's own per-frame " &
         "tick, so with the region unarmed it will NEVER run and no verdict " &
         "will ever be logged. Turn on sharedRegion (python tools/hostcfg.py " &
         "set sharedRegion on) or turn unityPostProbe back off."
  if gUnityPostProbeOn:
    info "graphics provider: D3D11 (aowlspt_graphics.h, back-buffer copy in " &
         "the overlay's Present). unityPostProbe is ON, but it is a READ-ONLY " &
         "SURVEY -- it writes no Unity post-processing state and suppresses " &
         "nothing, so the D3D11 path remains the only thing that grades a " &
         "frame. WHY: this build does ship Unity Post Processing Stack v2 " &
         "unstripped (measured offline, 118 types), but " &
         "ParameterOverride<T>.value is an instantiated-generic field offset " &
         "that GameAssembly.dll does not contain, and it will not be guessed."
  gRegionProjectorOn = readBoolKey("regionProjector")
  if gRegionProjectorOn and not gRegionOn:
    warn "regionProjector is ON but sharedRegion is OFF. The projector is " &
         "sampled from the region's own per-frame tick, so with the region " &
         "unarmed it will NEVER be installed and every consumer will keep " &
         "drawing bearing rings. Turn on sharedRegion (python tools/" &
         "hostcfg.py set sharedRegion on) or turn regionProjector back off."
  # THE EVENT-GUARD FALSIFICATION. Default OFF. A guard that has never caught
  # anything is indistinguishable from a guard that cannot catch anything, so
  # this subscribes a handler that faults ON PURPOSE (a store to 0x10, see
  # `abi/aowlspt_evguard.h`) and emits to it twice. PASS is: two FAULTED lines,
  # the second saying `unsubscribed`, a third emit reaching nobody, and the
  # process still alive to log the verdict. If the client dies here the guard
  # does not work on this build, which is also a result.
  #
  # It runs on the host's own boot thread, touches no game memory and resolves
  # no il2cpp name, so it is safe to run before the runtime is up.
  if readBoolKey("eventGuardSelfTest"):
    let evSelfTestEvent = "aowlspt.host.eventGuardSelfTest"
    let evSelfTestIndex = 0x7FFD
    info "eventGuardSelfTest is ON: about to dispatch to a DELIBERATELY " &
         "faulting event handler. Two FAULTED lines and a live client after " &
         "them is the PASS; a dead client here is the FAIL."
    tablesLock()
    gSubs.add Sub(name: evSelfTestEvent, cb: cEvSelfTestCb(),
                  user: cast[Il2CppPtr](0), modIndex: evSelfTestIndex,
                  faults: 0)
    tablesUnlock()
    if cEvInGuard() != 0'i32:
      warn "eventGuardSelfTest: this thread is ALREADY inside an " &
           "aowl_p_p_seh, so the dispatch would take the nested path and " &
           "prove nothing. INCONCLUSIVE -- not run."
    else:
      let first = deliverEvent(evSelfTestEvent, "{}", -1)
      let second = deliverEvent(evSelfTestEvent, "{}", -1)
      let third = deliverEvent(evSelfTestEvent, "{}", -1)
      if first == 1 and second == 1 and third == 0:
        okLog "eventGuardSelfTest PASS: the faulting handler was called " &
              "twice, both faults were caught, the process is alive to say " &
              "so, and the third dispatch reached 0 subscribers -- it was " &
              "unsubscribed at the limit."
      else:
        warn "eventGuardSelfTest: the process SURVIVED (the guard held), but " &
             "the delivery counts were " & $first & "/" & $second & "/" &
             $third & " where 1/1/0 was expected. The catch is proven; the " &
             "unsubscribe bookkeeping is NOT."
  betaNoticeReadFlags()
  # The breadcrumb file: a second, independent witness for the log's tail.
  #
  # The value is logged AS READ, not as declared: a flag defaulted to false in
  # source has already been found true in the deployed `aowlspt-host.json`,
  # with the dangerous branch running and the source saying otherwise.
  let crumbsWanted = readBoolKey("hostCrumbs")
  if crumbsWanted:
    let crumbPath = joinPath(gDir, "aowlspt-host.crumbs")
    let crumbErr = modhost.crumbArm(crumbPath, 20000)
    if crumbErr.len == 0:
      info "hostCrumbs read as TRUE from aowlspt-host.json: every log line is " &
           "also written, numbered, to " & crumbPath & " (capped at 20000). " &
           "That file is written with its own handle and flushed per record, " &
           "so if a hard death loses the log's tail the crumb numbers say how " &
           "far execution actually got."
    else:
      warn "hostCrumbs read as TRUE but the breadcrumb file is NOT armed: " &
           crumbErr
  else:
    info "hostCrumbs read as FALSE from aowlspt-host.json: no breadcrumb file. " &
         "Turn it on to get a second witness for the log tail after a crash."
  if gCodeGenAudit:
    info "codeGenAudit is set: whenever a method has BOTH a live methodPointer " &
         "and a codeGenModule table entry, the host will log whether the two " &
         "agree. Read-only -- it patches nothing."
  # Default OFF, like every other resolution flag here. Loading is attempted at
  # this point on purpose: it reads a file and the mapped PE headers, and needs
  # neither the IL2CPP runtime nor the Unity thread, so a bad index is reported
  # NOW rather than at first patch. GameAssembly.dll is NOT mapped this early,
  # so the stamp cannot verify here: the file is parsed and STAGED, the index
  # answers nothing, and the stamp is re-attempted at first use.
  gNameIndex = readBoolKey("nameIndex")
  if gNameIndex:
    let nidxLoaded = cNameIdxInit(toCString(gDir))
    if nidxLoaded == 0'i32 and cNameIdxStaged() != 0'i32:
      # GameAssembly.dll is not mapped at DLL-attach. The file is parsed and
      # STAGED; nothing resolves through it until the stamp verifies, which is
      # re-attempted on first use. This is not a refusal and not a fault.
      info "nameIndex: aowlspt-names.idx is parsed and STAGED (" &
           $int(cNameIdxCount()) & " entries), but its build stamp is NOT " &
           "verified yet: " & $cNameIdxReason() & ". No address from it is " &
           "usable until the stamp matches."
    elif nidxLoaded != 0'i32:
      okLog "nameIndex: loaded aowlspt-names.idx -- " & $int(cNameIdxCount()) &
            " name->RVA entries, build stamp 0x" &
            hexOf(cNameIdxImageKey()) & " MATCHES the loaded " &
            "GameAssembly.dll. VERIFIED IN-PROCESS: the imageKey only " &
            "(TimeDateStamp, SizeOfImage, AddressOfEntryPoint, CheckSum, read " &
            "from the mapped PE headers). NOT verified in-process: the " &
            "index's fileHash -- a SHA-256 of GameAssembly.dll on disk, which " &
            "a mapped image cannot reproduce because the loader page-aligns " &
            "and relocates sections; that one is a build-time guard, checked " &
            "offline by tools/il2cpp_nameindex.py check. " &
            "Names resolve from metadata frozen offline; " &
            "nothing here asks IL2CPP, which is the point, since MethodInfo " &
            "is unreadable on this build. Every address is still prologue " &
            "byte-verified before anything is patched."
    else:
      warn "nameIndex is set but the index was REFUSED: " & $cNameIdxReason() &
           ". No name will resolve through it; nothing is degraded, and no " &
           "address from it is being used."
  gCodeGenResolve = readBoolKey("codeGenResolve")
  if gCodeGenResolve:
    # This runs at DLL-attach, BEFORE `waiting for the IL2CPP runtime`. Asking
    # the table anything here is premature by about a second, so a negative is
    # reported as "not up yet", never as a verdict on the build.
    if cCodeGenReady() == 0'i32 and cCodeGenWaiting() != 0'i32:
      info "codeGenResolve is set. GameAssembly.dll is not mapped yet at this " &
           "point in boot, which is expected -- the codeGenModules table is " &
           "resolved lazily on first use and re-checked until it answers. " &
           "Nothing is being concluded about this build here."
    elif cCodeGenReady() != 0'i32:
      warn "codeGenResolve is set: when methodPointer reads null the host will " &
           "resolve the compiled address from IL2CPP's own per-assembly " &
           "methodPointers table (" & $int(cCodeGenModules()) & " modules, " &
           $int(cCodeGenValidNames()) & " with readable names) and patch THAT. " &
           "The table is corroborated: GameWorld::RegisterPlayer 0x25038c0, " &
           "BotSpawner::AddPlayer 0x2563ae0 and TarkovApplication::" &
           "ExitApplication 0x982610 come out of it exactly, and all three are " &
           "already bound and FIRING on this client from prologue-verified " &
           "static RVAs. Set codeGenAudit to have the client re-confirm that " &
           "for itself at boot."
    else:
      warn "codeGenResolve is set but the codeGenModules table did not " &
           "validate on this build (" & codeGenReason() & "); the fallback is " &
           "inert and every null methodPointer will still refuse."
  gDeepScan = readBoolKey("bridgeDeepScan")
  if gDeepScan:
    warn "bridgeDeepScan is set: when methodPointer is null the host will scan " &
         "the live MethodInfo for an executable il2cpp pointer and hook it -- " &
         "the decisive attempt on this build, and one that may crash"
  gSettingsProbe = readBoolKey("bridgeSettingsProbe")
  if gSettingsProbe:
    info "bridgeSettingsProbe is set: a read-only detour on SettingsScreen.Show " &
         "will log the thread it fires on when you open the settings screen " &
         "(Experiment A -- confirms a detour reaches the Unity thread)"
  # THE CAMERA API. `camBind` reads `cameraApi` and `cameraFreeCam` itself
  # (both default OFF) and byte-verifies its 15 targets against the startup
  # prologue snapshot. It installs no detour and resolves no name at runtime.
  camBind()
  # IN-RAID PLAYER ACTUATION. `pactBind` reads `playerActuation` itself (default
  # OFF) and does nothing else here: every byte-verify and the one capture
  # detour happen on the main-thread drain, where GameAssembly.dll is mapped by
  # construction. Asking at DLL-attach would read "no module" and latch that as
  # a verdict about the build, which is a fact about WHEN we asked.
  pactBind()
  # DEFAULT OFF, and it must stay off until the probe has said what the refcount
  # is. It drops references until the module unmaps, which is the right fix for
  # "something took a reference and never gave it back" and a way to unmap a
  # library out from under a legitimate holder for every other cause.
  modhost.setForceRelease(readBoolKey("modForceRelease"))
  gLpOn = readBoolKey("loadPerf")
  if gLpOn:
    info "loadPerf is set: 33 READ-ONLY POSTFIX detours will time the vanilla " &
         "raid load (menu network batch, matching, LoadMapAndData, bundle " &
         "loading, and the twelve ClientMetricsEvents phase markers the client " &
         "log already prints). It reads NO game memory and suppresses NO " &
         "original; it changes load behaviour in no way. NOTHING IS SKIPPED -- " &
         "this measures, it does not optimise."
  gBotDiag = readBoolKey("botDiag")
  if gBotDiag:
    info "botDiag is set: a READ-ONLY detour on EFT.GameWorld.RegisterPlayer " &
         "will log each bot/player registration and enumerate the registered " &
         "list (nickname, side/role, alive-state, position) during an offline " &
         "raid -- it answers spawned-but-frozen vs absent. NO write is performed."
  gBotCap = readBoolKey("unlimitedBots")
  if gBotCap:
    info "unlimitedBots is set: a kind=6 detour on EFT.BotSpawner.AddPlayer will " &
         "poke BotSpawner.MaxBots=0 (unlimited) once at offline-raid init, lifting " &
         "the cap that defers the scav wave pool (bosses bypass it via " &
         "IgnoreMaxBots; scavs do not). One guarded int32 write on the Unity " &
         "thread; fail-safe -- no write if the build/pointer does not check out."
  # CATCH THE IN-GAME ERROR DIALOG. This is one of the very few host features
  # that DEFAULTS ON, and the deviation from the usual default-off rule is
  # deliberate: the rule exists to keep a feature that WRITES from being live
  # before anyone asked for it, and this one never writes. It installs three
  # read-only postfix detours on prologue-verified, offline-UNIQUE targets, reads
  # two strings through VirtualQuery-guarded hops under the VEH/SEH guard, logs
  # one line, and always lets the original run so the window still appears.
  #
  # Defaulting it OFF would mean the default configuration is the one where an
  # unattended run that hits an error dialog reports IDLE and burns its whole
  # timeout -- which is precisely the failure this exists to end. A watcher you
  # have to remember to switch on is not a watcher.
  #
  # `"catchErrorDialogs": false` in aowlspt-host.json still turns it off.
  gErrDlg = readBoolKeyDef("catchErrorDialogs", true)
  if gErrDlg:
    info "catchErrorDialogs is on (default): read-only postfix detours on the " &
         "three EFT.UI.PreloaderUI error-screen entry points. An in-game error " &
         "dialog will write one ERRORDIALOG line to this log the moment it is " &
         "raised, with its header and message. The dialog is NEVER suppressed. " &
         "Nothing is written to the game."
  else:
    warn "catchErrorDialogs is explicitly false: in-game error dialogs will NOT " &
         "be caught. A run that hits one will look IDLE rather than failed, and " &
         "an unattended run will sit on it until it times out."
  # THE IN-GAME MOD LOADING SCREEN. Default ON, like catchErrorDialogs and for
  # the same reason: it exists to make a long silent wait legible, and a screen
  # you have to remember to switch on does not do that. It writes nothing to the
  # game, installs no detour, and builds NOTHING until the compile writes its
  # file -- so on an install whose mods are already built it is inert.
  gModLoad = readBoolKeyDef("modLoadScreen", true)
  # NO MODS BY DEFAULT. The client comes up carrying nothing so the mods folder
  # can be compiled from source behind our own loading screen. Gated on
  # modLoadScreen as well as its own key: deferring the mods with no screen to
  # release them would be a wait with no end and no explanation.
  gModLoadDeferMods = gModLoad and readBoolKeyDef("deferModLoad", true)
  # FALSIFICATION SWITCH for the release gate, default OFF. On, the main-menu
  # show event is IGNORED, so the gate can never open and only the 240s
  # deadline releases -- which is how a run demonstrates the gate HOLDING
  # (READY on disk, mods NOT released) rather than only ever demonstrating it
  # opening. A gate nobody has watched hold has not been shown to be a gate.
  gModLoadGateHold = readBoolKeyDef("modLoadGateHold", false)
  # THE NATIVE LOADING STEP (F1 of docs/BOOT-FLOW-MAP.md), DEFAULT OFF. It puts
  # the mod-build progress on the CLIENT'S OWN profile-loading caption instead
  # of on our from-scratch overlay, and it logs the game's own MenuLoadProfiler
  # stages with their thread ids. Gated on `modLoadScreen` as well as on its own
  # key, because it rides `modLoadTick` for its pump and reads the very lines
  # that tick parses -- with the screen off there is nothing to drive it.
  # IT DOES NOT DELAY THE BOOT: the deferred release stays gated on
  # MenuScreen::Show behind `deferModLoad`, exactly as before.
  gMlnOn = gModLoad and readBoolKeyDef("modLoadNative", false)
  if gMlnOn:
    info "modLoadNative is on: the mod-build progress is written to the " &
         "client's OWN profile-loading caption (ProfileLoadingScreen." &
         "_statusField@0xb0, reached from the screen receiver the game hands " &
         "us, written through TMP_Text::set_text @0x51BC1E0 and re-applied), " &
         "and modload.nim's three-line overlay stands down ONLY once a write " &
         "has been read back off the live TMP. Four read-only POSTFIX drains " &
         "are installed; nothing is delayed and no return value is changed."
  block:
    gModLoadWalkLevel = readIntKey("modLoadWalkLevel", 3)
    let n = readStrKey("modLoadCaption")
    if n.len > 0:
      gModLoadNeedle = toLowerAscii(n)
  if gModLoad:
    info "modLoadScreen is on (default): while the mods folder compiles, and " &
         "ONLY while the client's own loading caption is on screen, it shows " &
         "three lines of bare text -- what it is doing now, the overall " &
         "progress, the current step's progress -- in that caption's font and " &
         "frame. It renders aowlspt-modload.txt verbatim, builds nothing at " &
         "all until that file exists, and draws NOTHING at the main menu. The " &
         "caption is found STRUCTURALLY, by object name and parent name, " &
         "which are NOT localized; modLoadCaption (currently \"" &
         gModLoadNeedle & "\") is only a logged cross-check now, never the " &
         "gate."
  gBotAi = readBoolKey("botAiActivate")
  if gBotAi:
    info "botAiActivate is set: a kind=12 detour on EFT.BotOwner.PreActivate will " &
         "release BotWeaponManager.IsReady (one guarded byte per bot) -- the gate " &
         "BotOwner.UpdateManual checks before it will call BotOwner.Activate. " &
         "Without it a bot whose weapon change never completes stays in " &
         "_botState=1 forever: standing at its spawn, brain never ticking, knife " &
         "in hand and primary slung. Activate is NOT called by us and _botState " &
         "is NOT written; the game still runs its own NavMesh check and its own " &
         "Activate on its own schedule. Fail-safe -- no write if the " &
         "build/pointer does not check out."
  gBotNav = readBoolKey("botNav")
  if gBotNav:
    info "botNav is set: a kind=15 detour on EFT.BotOwner.UpdateManual (once per " &
         "live bot per frame, RCX = the BotOwner) keeps a live bot registry -- " &
         "id, role, difficulty, position, alive-state -- and services nav " &
         "commands sent over the existing modSyncMs poll. A command is a DIRECT " &
         "CALL to EFT.BotOwner.GoToPoint @0x81CB40, whose NavMeshPathStatus " &
         "return says whether the point was reachable. Every pointer hop the " &
         "callee makes is VirtualQuery-walked BEFORE the call, the whole tick " &
         "runs under the VEH/SEH guard, commands are re-issued on a 500 ms " &
         "throttle (never per frame -- GoToPoint allocates a managed path), and " &
         "the feature self-disables after 8 trapped faults. This one CALLS INTO " &
         "and WRITES TO game objects, unlike botDiag."
  gSettingsUiProbe = readBoolKey("settingsUiProbe")
  if gSettingsUiProbe:
    info "settingsUiProbe is set: read-only detours on SettingsScreen.Show " &
         "(Phase 1, arming/thread proof) and a POSTFIX on " &
         "SettingsScreen.EnsureTabInitialized (Phase 1.5, the walk that reads " &
         "controls -- they do not exist yet at Show) will log every control's " &
         "label, il2cpp klass pointer and value-widget pointer as each tab is " &
         "built. Open Settings and click each tab. NO write is ever performed."
  # PHASE 2 -- the WRITE side of the native settings screen. Both default OFF,
  # both ride the ShowScreen postfix the read probe already installs, so neither
  # costs a detour of its own; each needs `settingsUiProbe` to be on, because
  # that flag is what arms the hook they run from.
  gSwRelabel = readBoolKey("settingsRelabelProbe")
  gSwBind = readBoolKey("settingsBindProbe")
  if (gSwRelabel or gSwBind) and not gSettingsUiProbe:
    gSettingsUiProbe = true
    info "settingsRelabelProbe/settingsBindProbe is set, so settingsUiProbe " &
         "has been turned on with it -- the Phase-2 write runs from the same " &
         "ShowScreen postfix the read probe installs, and without that hook " &
         "there is nothing for it to run from."
  if gSwRelabel:
    info "settingsRelabelProbe is set: PHASE 2a. On the ShowScreen postfix the " &
         "host finds the Game-tab control whose stock label is 'FOV:' and " &
         "rewrites it to 'FOV: [aowlspt]' -- one il2cpp_string_new, one raw " &
         "store into m_text (+0xE0), one dirty byte (+0x378), which is the " &
         "same primitive the version brand and the F3 overlay use in " &
         "production. Idempotent (it never double-brands) and self-disabling " &
         "after two faults. Open Settings -> Game and read the FOV row."
  if gSwBind:
    info "settingsBindProbe is set: PHASE 2b. On the same postfix the host " &
         "READS the live value out of every control whose widget type it has " &
         "learned this session -- a toggle's m_IsOn (+0x120) and a float " &
         "slider's Slider.m_Value (+0x120) with its range -- and logs each " &
         "beside its label, so the offsets can be checked against what the " &
         "screen actually shows. NO value is written."
  # PHASE 3 -- the per-mod settings pages. Default OFF, and it needs the same
  # ShowScreen postfix, so it turns the read probe on with itself for the same
  # reason Phase 2 does.
  gSwPagesOn = readBoolKey("settingsPages")
  # `modSettingsRender` needs `settingsPages`' renderer, so it turns that on
  # with itself the same way `settingsPages` turns `settingsUiProbe` on --
  # a flag that draws mod pages but never renders anything is a feature that
  # looks off when it is armed.
  gModSetOn = readBoolKey("modSettingsRender")
  if gModSetOn and not gSwPagesOn:
    gSwPagesOn = true
    info "modSettingsRender is set, so settingsPages has been turned on " &
         "with it -- mod pages render through the same cloned-control " &
         "renderer the host page uses."
  if gSwPagesOn and not gSettingsUiProbe:
    gSettingsUiProbe = true
    info "settingsPages is set, so settingsUiProbe has been turned on with " &
         "it -- the pages are rendered from the same ShowScreen postfix the " &
         "read probe installs."
  if gSwPagesOn:
    info "settingsPages is set: PHASE 3. On the Game tab the host renders its " &
         "own settings page into the REAL settings screen, by CLONING a stock " &
         "toggle row (UnityEngine.Object::Instantiate + " &
         "TMP_DefaultControls::SetParentAndAlign, both byte-verified direct " &
         "calls) once per row, relabelling each clone and seeding it with " &
         "Toggle::SetIsOnWithoutNotify so the row shows its own value without " &
         "firing the donor setting's handler. The first page is the aowlspt " &
         "host's own flags out of aowlspt-host.json; a row the player changes " &
         "is read back and persisted to that file. Rows that are carried but " &
         "not yet wired are suffixed '(not done yet)'. Nothing the GAME " &
         "created is ever written -- only clones the host made itself -- and " &
         "the whole thing shares the Phase-2 fault budget."
  # THE MODS TAB (`settingsModsTab`). Default OFF. It is built from the live
  # SettingsScreen, which this host only ever learns about through the
  # ShowScreen postfix `settingsUiProbe` installs -- so, like Phase 2 and Phase
  # 3, it turns that flag on with itself rather than declining for a reason
  # nobody could see.
  gModsOn = readBoolKey("settingsModsTab")
  if gModsOn and not gSettingsUiProbe:
    gSettingsUiProbe = true
    info "settingsModsTab is set, so settingsUiProbe has been turned on with " &
         "it -- the tab is built from the live SettingsScreen pointer that " &
         "probe's ShowScreen postfix is what learns."
  if gModsOn:
    info "settingsModsTab is set: the host adds a SIXTH tab, MODS, to the " &
         "game's own settings screen by cloning a stock tab button into " &
         "SettingsScreen/Toggles and a stock panel beside the other five. " &
         "Inside it, a row of SUBTABS cloned from the game's own tab strip " &
         "switches between one page of settings per area, each page a set of " &
         "cloned stock rows laid out by the stock layout group -- nothing is " &
         "hand-positioned. It rides the existing PreloaderUI::Update detour " &
         "(never a second one), needs one of debugUi/uxMenuModeText/" &
         "liveInspector to have claimed that slot, and self-disables after " &
         "four trapped faults. Open Settings -> Game once to build it."
  # THE NATIVE LIFECYCLE RIDER (`settingsNativeLifecycle`). Default OFF, and
  # meaningless without `settingsModsTab` -- it only changes HOW the MODS tab
  # notices a stock tab was chosen, not whether the tab exists at all.
  #
  # It does NOT install a second detour on ShowScreen. It rides the SAME
  # `settingsUiProbe` ShowScreen-postfix drain `gModsOn` already forces on
  # (see above) -- exactly the "ride an existing detour as a drain" rule,
  # because ShowScreen already carries one live hook and a second physical
  # detour on the same function would overwrite its trampoline.
  #
  # IT IS ONLY HALF NATIVE. ShowScreen fires for every STOCK tab click, which
  # is a trustworthy native signal that MODS was just LEFT -- so that edge
  # (hide our panel + restore the stock one) is driven from the postfix the
  # instant it fires, instead of waiting up to a frame for the toggle poll.
  # There is NO equivalent native signal for ENTERING the MODS tab: our
  # cloned toggle is a plain `UnityEngine.UI.Toggle` in the stock
  # `ToggleGroup` and nothing calls `ShowScreen` (or anything else) when it
  # turns on -- confirmed by reading `modsTabTickBody`'s own edge detection,
  # which is the only place that ever learns the toggle went on. Making that
  # side native would mean either subclassing a managed type (reflection is
  # dead, `fact #35`) or calling `ShowScreen` ourselves with a synthetic
  # group value the original body was never verified against -- a blind call
  # this file will not make. So the SHOW edge stays exactly the existing
  # standing-check poll in `modsTabTickBody`, flag or no flag.
  gModsNativeLifecycle = readBoolKey("settingsNativeLifecycle")
  if gModsNativeLifecycle and not gModsOn:
    warn "settingsNativeLifecycle is set but settingsModsTab is not -- there " &
         "is no MODS tab for it to drive, so this does nothing"
  elif gModsNativeLifecycle:
    info "settingsNativeLifecycle is set: leaving MODS for a stock tab is " &
         "now driven from the ShowScreen postfix the moment it fires, " &
         "instead of the next frame's toggle poll. Entering MODS is still " &
         "poll-driven -- no game code calls anything when our cloned toggle " &
         "turns on. The old standing-check path is untouched and stays as " &
         "the backstop (and the only path at all when this flag is off)."
  # SKIP THE MODE SCREEN. Two independent conditions, both explicit: the flag,
  # and an actual profile id to select. `launchProfileId` is written by
  # `tools/aowllaunch.nim` from the SAME id it passes as `-token`, which is the
  # only thing that gives the client a PHPSESSID -- so if the launcher got far
  # enough to start the client at all, it knew this id.
  gModeSkipOn = readBoolKey("uxSkipModeScreen")
  # FEATURE F2, two independent flags, BOTH DEFAULT OFF and both independent of
  # `uxSkipModeScreen` above -- they bind a different function.
  #   `modeSkipProbe`          read-only census of the dictionary the boot
  #                            hands TryCreateInRaidCharacterSelection, once.
  #   `uxSkipModeScreenNative` the actual skip: answer true with the game's own
  #                            (key, value) pair and never construct the
  #                            selection controller, so there is NO frame of
  #                            the character/mode screen.
  gModeSkipProbeOn = readBoolKey("modeSkipProbe")
  gModeSkipNativeOn = readBoolKey("uxSkipModeScreenNative")
  gModeSkipWantId = readStrKey("launchProfileId")
  if gModeSkipOn and gModeSkipWantId.len == 0:
    warn "uxSkipModeScreen is set but `launchProfileId` is absent or empty in " &
         "aowlspt-host.json. There is no profile to select, so NOTHING will " &
         "be bound and the character/mode selection screen WILL appear. This " &
         "is a launcher error, not a host one: aowllaunch writes that key " &
         "from the same id it passes as -token."
  elif gModeSkipOn:
    info "uxSkipModeScreen is set: read-only postfix detours on " &
         "CharacterSelectionScreenController::.ctor and " &
         "CharacterSelectionScreen::ShowSlot will capture the slot whose " &
         "ProfileId is " & gModeSkipWantId & ", and the " &
         "TarkovApplication::Update drain will call the game's own " &
         "Submit for it a couple of ticks later. Neither detour suppresses " &
         "its original, so the screen is dismissed rather than prevented."
  # FREE THE MOUSE WHILE AN OVERLAY PANEL IS OPEN. Default OFF. `cursorFreeBoot`
  # verifies all four `UnityEngine.Cursor` targets against the startup prologue
  # snapshot and REFUSES to arm unless every one of them passes -- this feature
  # writes cursor state, and it will not write a state it could not first read.
  # `cursorFreeBoot` is deliberately NOT called here, for the same reason
  # `bindNativeUi` is not (see the note just below): this pass runs before
  # il2cpp is attached, so `GameAssembly.dll` may not be loaded and the prologue
  # snapshot may not be primed -- a verify run now would reject four perfectly
  # correct RVAs and blame the game build. It is called from the FIRST drain
  # tick instead, which by construction runs on Unity's thread with the module
  # loaded.
  # THE UI OVERLAY-MASK SIGNAL (aowl_ui_overlay_mask export). Default OFF. When
  # on, a guarded, self-disabling managed probe reads the game Settings screen's
  # live activeInHierarchy each tick for bit0; bit1/bit2 (F6/F3) are pure reads
  # of the cursor level and publish regardless. This flag also enables freeing
  # the cursor over the game's Settings screen (via cursorFreeHostMask), which
  # additionally needs overlayCursorFree on to act.
  gUiStateOn = readBoolKey("overlayStateSignal")
  if gUiStateOn:
    info "overlayStateSignal is set: aowl_ui_overlay_mask bit0 will report the " &
         "game Settings screen open by reading its live activeInHierarchy off " &
         "gSettingsLiveSelf at byte-verified static RVAs; with overlayCursorFree " &
         "also on, the cursor is freed while that screen is up."
  gCursorFreeOn = readBoolKey("overlayCursorFree")
  if gCursorFreeOn:
    info "overlayCursorFree is set: while any aowlspt overlay panel is open " &
         "the cursor will be freed by calling UnityEngine.Cursor's own " &
         "set_lockState/set_visible at byte-verified static RVAs, and the " &
         "game's own state -- read before it is changed, never assumed -- is " &
         "put back verbatim when the last panel closes. The targets are " &
         "verified on the first drain tick, not here, because il2cpp is not " &
         "attached yet at this point in boot."
  # SINGLEPLAYER REBRAND of the Matchmaker Offline Raid Screen. Default OFF. It
  # relabels the "PRACTICE GAME MODE" heading + description and hides the
  # practice-mode checkbox, reusing the byte-verified nativeui setters; it never
  # ticks the toggle, so offline routing is untouched. Discovery is live and by
  # displayed text, and it rides the TarkovApplication::Update drain.
  # FORCE OFFLINE / PRACTICE MODE. Default ON. Independent of the rebrand: when
  # set, the Matchmaker Offline Raid Screen's practice/offline toggle is auto-
  # forced ON (Toggle::set_isOn @0x55BA430, fact #71) the moment the screen
  # appears, so a raid entered by pressing straight through the menus (no manual
  # tick) stays OFFLINE and never enters the online NetworkGameMatching that
  # times out and crashes the load (fact #263). It never relabels or hides.
  gSplForceOffline = readBoolKeyDef("forceOfflinePractice", true)
  if gSplForceOffline:
    info "forceOfflinePractice is set (default ON): the Matchmaker Offline Raid " &
         "Screen's practice/offline toggle will be AUTO-enabled via the byte-" &
         "verified Toggle::set_isOn @0x55BA430, so solo raids stay offline no " &
         "matter how the user navigates. Discovery is live and by displayed " &
         "text; the toggle is left VISIBLE and ticked unless singleplayerRebrand " &
         "also hides it."
  gSplOn = readBoolKey("singleplayerRebrand")
  if gSplOn:
    info "singleplayerRebrand is set: the Matchmaker Offline Raid Screen's " &
         "\"PRACTICE GAME MODE\" heading and description will be relabelled to " &
         "SINGLEPLAYER branding via the real TMP_Text/LocalizedText setters, " &
         "and the \"Enable practice mode for this raid\" checkbox GameObject " &
         "will be SetActive(false). The screen is discovered live by displayed " &
         "text from a scene root (no hardcoded path); the toggle's value is " &
         "never changed, so the raid still routes to the emulated backend."
  # HOST-NATIVE AUTO-RAID. Default OFF (`uxAutoRaid`). On launch it drives the
  # menu into an OFFLINE raid on `autoRaidMap` (default "Woods") natively -- no
  # Python, no inspector -- by riding the TarkovApplication::Update drain and
  # reusing inspect.nim's find/active/press primitives. It only advances screens;
  # it relies on `singleplayerRebrand` to force the practice toggle so the raid
  # stays offline, so it should be run WITH that flag on.
  # THE MOD-FACING UI SHOW-EVENT BUS. Default ON: it installs the same
  # byte-verified detours the in-host subscribers already use, adds no second
  # detour to any site, and its per-firing cost is one small JSON string on a
  # screen open. Turning it OFF means a mod can still ASK
  # (`aowlspt.host::ui_show_status`) but will never be TOLD.
  gUihEventsOn = readBoolKeyDef("uiShowEvents", true)
  if not gUihEventsOn:
    info "uiShowEvents is OFF: the host will not emit the `ui.show` event, " &
         "and the show sites are bound only if an in-host feature wants them. " &
         "`aowlspt.host::ui_show_status` still answers, and its `flag` field " &
         "says false so a mod can tell this apart from a site that failed to " &
         "bind."
  gArOn = readBoolKey("uxAutoRaid")
  block:
    let m = readStrKey("autoRaidMap")
    if m.len > 0:
      gArMap = m
  block:
    # Which side to take on the PMC/SCAV selector that PLAY leads to, matched
    # against the CONTROL'S OBJECT NAME (case-insensitive substring). MEASURED
    # 2026-09-02: the screen after PLAY is `MatchMaker Side Selection Screen`,
    # and its captions are `DefaultUIButton._text` rather than TMP text, so the
    # displayed-text match the map tiles use is not available here. autoraid
    # logs every active control name it saw, once, so the names are a MEASURED
    # fact in the log rather than a guess in the code.
    let c = readStrKey("autoRaidSide")
    if c.len > 0:
      gArSide = c
  if gArOn:
    info "uxAutoRaid is set: on launch the host will drive the main menu into " &
         "an OFFLINE raid on map \"" & gArMap & "\" natively (PLAY -> NEXT -> " &
         "select map -> NEXT... -> READY), advancing only when each expected " &
         "control is visible, then going hands-off once READY is pressed. It " &
         "reuses the inspector's find/active/press primitives and rides the " &
         "TarkovApplication::Update drain -- no second detour, no Python, no " &
         "live inspector. Run WITH singleplayerRebrand so the raid stays offline."
  # NATIVE RAID ENTRY. Both default OFF, and deliberately SEPARATE:
  # `uxNativeRaid` runs STAGE 1 only -- a read-only probe that calls two getters
  # and reports the seven prerequisites as PASS/FAIL/INCONCLUSIVE. It writes
  # nothing and presses nothing, so it is safe to run on its own and answers the
  # open unknowns in ONE launch. `uxNativeRaidDrive` additionally arms STAGE 2
  # (write Side=Pmc, RaidMode=Local, then call OnReadyPressed) and does nothing
  # at all unless STAGE 1's verdict in the same session was PREREQS-PASS.
  gNrOn = readBoolKey("uxNativeRaid")
  gNrDrive = gNrOn and readBoolKey("uxNativeRaidDrive")
  if gNrOn:
    var nrTail = " uxNativeRaidDrive is OFF, so STAGE 2 will not write or press."
    if gNrDrive:
      nrTail = " uxNativeRaidDrive is ALSO set: if every prerequisite passes " &
               "it will then write Side=Pmc(0) and RaidMode=Local(1) into " &
               "MatchmakerOperation._raidSettings@0x40 (the object Ready() " &
               "actually reads) and call MatchmakerOperation::" &
               "OnReadyPressed(), at most once per readiness transition, then " &
               "go hands-off."
    # ACCURACY. This line used to say the probe was READ-ONLY and that it
    # "presses no GameObject" -- half of which was false, and the false half
    # killed the client on 2026-08-30 (NRE in OfflineInventoryController..ctor
    # under get_MatchmakerOperation). State what it really does.
    info "uxNativeRaid is set: on the TarkovApplication::Update drain (its RCX " &
         "is the TarkovApplication) the host will probe the native raid-entry " &
         "path and log a `nativeRaid PROBE` report. The probe DETOURS NOTHING, " &
         "WRITES NO GAME FIELD and PRESSES NO GameObject, but it is NOT " &
         "read-only: it CALLS get_CurrentRaidSettings (byte-verified to be a " &
         "pure field read) and a capped Location lookup. It REQUIRES that the " &
         "client has already built the matchmaker graph, waits for that with " &
         "guarded reads, and REFUSES with a logged reason if it never arrives." &
         nrTail
  # The native-UI layer. Both default OFF. `nativeUi` makes the API answer at
  # all; `nativeUiProof` additionally runs the one-shot visual self-proof.
  gNuOn = readBoolKey("nativeUi")
  gNuProof = gNuOn and readBoolKey("nativeUiProof")
  # `nativeUiImageProof` -- STAGE C, the Image-from-scratch spike. Its own flag
  # and NOT implied by `nativeUiProof`, because it answers a different question
  # (does a uGUI Graphic built from nothing render) that the native ESP is
  # blocked on, and because running it alone puts exactly one object on screen
  # instead of three, which keeps the visual evidence unambiguous.
  gNuImgProof = gNuOn and readBoolKey("nativeUiImageProof")
  # The unified widget framework. `aowlUi` arms the framework (its native
  # realisation reuses the nativeui primitives, so it implies `nativeUi`);
  # `aowlUiProof` runs the one-shot dual-backend self-proof.
  gAuOn = readBoolKey("aowlUi") and gNuOn
  gAuProof = gAuOn and readBoolKey("aowlUiProof")
  # The NATIVE-UI TOOLKIT. `nativeUiKit` arms nuPanel/nuLabel + the handle
  # table; `nativeUiKitProof` runs the one-shot self-test. The `and gNuOn` is
  # load-bearing, not defensive: the toolkit is a facade over the nu* layer and
  # without it every call would refuse, so arming it alone would produce a
  # feature whose only output is a refusal per call.
  gNkOn = readBoolKey("nativeUiKit") and gNuOn
  gNkProof = gNkOn and readBoolKey("nativeUiKitProof")
  # The NATIVE uGUI ESP. Both default OFF. `natEsp` arms discovery + the pool;
  # `natEspDiag` additionally logs the three-outcome verdict every 5s. The
  # `and gNuOn` is not belt-and-braces: without the nu* layer this feature has
  # no way to construct a single box, and arming it would only produce a
  # feature that reports "the callback ran" forever.
  # THE FRAME METER. Read FIRST among the per-frame features and ANDed with
  # nothing, on purpose: it is the instrument the others are measured with, and
  # an instrument that can be disabled by the subject is not an instrument.
  ftConfigure()
  # THE DRAIN PROFILER, for the identical reason and on the identical terms: it
  # is an instrument over the other features, so it is ANDed with none of them.
  dpConfigure()
  # RAYTRACED AUDIO, ANDed with nothing for the same reason: it depends on no
  # other feature. Default OFF, and it refuses BY NAME when its DLL path is
  # unset -- the licence forbids us shipping the library.
  arConfigure()
  # THE ESP PROVIDER, read BEFORE natEsp is armed so the "overlay" choice can
  # veto arming rather than arm a feature and then hide it. An absent or
  # unrecognised value falls back to "auto" LOUDLY -- a typo that silently
  # selected a provider would be a setting that cannot be got wrong, which is
  # the same thing as a setting that cannot be checked.
  gEspProvider = readStrKey("espProvider")
  if gEspProvider.len == 0: gEspProvider = "auto"
  if gEspProvider != "auto" and gEspProvider != "native" and
     gEspProvider != "overlay" and gEspProvider != "both":
    warn "espProvider = \"" & gEspProvider & "\" is not one of native / " &
         "overlay / both / auto. Falling back to \"auto\" (natEsp wins if it " &
         "is armed, otherwise debugEsp draws)."
    gEspProvider = "auto"
  let natEspAsked = readBoolKey("natEsp")
  gNeOn = natEspAsked and gNuOn and gEspProvider != "overlay"
  if natEspAsked and gNuOn and gEspProvider == "overlay":
    info "natEsp is set but espProvider=\"overlay\", so the NATIVE uGUI ESP " &
         "is NOT armed for this session and debugEsp's in-world markers are " &
         "the only ESP drawing. Set espProvider to \"native\" or \"auto\" to " &
         "swap them, or \"both\" to draw both (which is what produced the " &
         "doubled boxes)."
  gNeDiag = gNeOn and readBoolKey("natEspDiag")
  # THE FIREHOSE SWITCH, default OFF. `natEspDiag` decides WHETHER the verdict
  # is reported; `natespVerbose` decides only how often an UNCHANGED one is
  # REPEATED. ON restores the pre-throttle behaviour byte for byte (the full
  # ~3,000-character block every 5s and the full flicker meter every 1s). OFF
  # suppresses no measurement and can silence no not-PASS verdict.
  gNeVerbose = readBoolKey("natespVerbose")
  # THE DEPLOY-ORDER BREADCRUMB. Independent of `natEsp` on purpose: the
  # question it answers -- is OnGameStarted the early signal or the late one --
  # is about `raidphase`, which the maps HUD reads too, so the measurement must
  # be available whether or not the ESP itself is armed.
  gNdpOn = readBoolKey("natespDeployProbe")
  # THE PER-CLASS COLOURS, from `colorSetting(format="hex")`. Read ONCE here, at
  # config load, never per frame. A key that is absent or that does not parse
  # leaves the compiled default in place AND leaves `aowl_ne_col_source` saying
  # "default", so the verdict line reports what is in force rather than what was
  # asked for. Capped by cNeFactions(), a compile-time constant.
  if gNeOn:
    var nf = 0'i32
    while nf < cNeFactions():
      let key = neColourKey(nf)
      if key.len > 0:
        let v = readStrKey(key)
        if v.len > 0 and not neApplyColour(nf, v):
          warn "natesp: the colour setting \"" & key & "\" = \"" & v &
               "\" did not parse as #RRGGBB or #RRGGBBAA, or a channel was " &
               "out of range. The COMPILED DEFAULT for " &
               readCString(cNeFactionName(nf)) & " stays in force and the " &
               "verdict line will say `default`, not `settings` -- a colour " &
               "that silently fell back to black would draw an invisible box " &
               "while every call reported success."
      inc nf
  # THE NATIVE COLOUR WIDGET on the in-game settings screen. Default OFF.
  #
  # The `and gNuOn` is the same load-bearing condition `natEsp` has above and
  # for the same measured reason: without the nu*/nuikit layer this feature
  # cannot construct a single panel, so arming it would produce a page of
  # refusals rather than a control. It also needs `settingsPages`, which is
  # what renders a page for it to put a row on -- but that flag is read further
  # down, so the dependency is stated in the ledger line rather than ANDed here
  # where it would silently read false.
  gCwOn = readBoolKey("settingsColorWidget") and gNuOn
  # The NATIVE INVENTORY SCREEN. `and gNuOn` for the identical reason: without
  # the nu*/nuikit layer it cannot construct a single panel, so arming it would
  # produce a page of refusals rather than a screen. It additionally needs the
  # admin mod loaded on the SERVER side to answer anything -- that is not a
  # host flag and cannot be ANDed here, so the screen reports it on its own
  # note line instead of failing silently.
  gIuOn = readBoolKey("nativeInvUi") and gNuOn
  # NOTE: `bindNativeUi` is deliberately NOT called here. It was, and the first
  # live run showed why that is wrong: this pass runs before il2cpp is attached
  # and before GameAssembly.dll is loaded, so all 25 targets refused with "no
  # module" and the census reported them as 25 prologue REJECTIONS -- twenty-
  # five confident warnings blaming the game build for a start-order bug. The
  # census now runs in the `gReady` bind region below, after `cProPrimeAll()`.
  gMi2Probe = readBoolKey("managedInvokeProbe")
  # The proof RIDES invoke2's postfix detour rather than binding a second one,
  # so asking for the proof implies arming that detour. Saying so here, rather
  # than leaving the human to discover that `nativeUiProof` alone does nothing,
  # is the difference between a feature and a silent decline.
  if (gNuProof or gNuImgProof or gNkProof) and not gMi2Probe:
    gMi2Probe = true
    info "nativeUiProof/nativeUiImageProof is set, so managedInvokeProbe is " &
         "being armed with it: " &
         "the proof rides that detour on SettingsScreen.EnsureTabInitialized " &
         "as a drain, because a second detour on one function overwrites the " &
         "first's trampoline"
  if gMi2Probe:
    info "managedInvokeProbe is set: a POSTFIX detour on " &
         "SettingsScreen.EnsureTabInitialized will run a five-step ladder that " &
         "calls managed IL2CPP methods DIRECTLY at their static RVA -- no " &
         "reflection, no runtime_invoke. Steps: (1) instance getters, " &
         "(2) statics, (3) il2cpp_object_new, (4) GameObject::.ctor + " &
         "AddComponent routes, (5) clone a live settings label and retarget it. " &
         "Every step is separately VEH-guarded and logged BEGIN/END, so a fault " &
         "names its step and cannot crash the client. It takes over the " &
         "EnsureTabInitialized hook from the Phase-1.5 control probe."
  # The in-game debug overlay. Two flags, one detour: either of them arms the
  # per-frame PreloaderUI hook, because the panel and the markers are drawn from
  # the same body. The LAYOUT is read here too, so a bad config file is a boot-log
  # line rather than a surprise the first time the key is pressed.
  gDebugUi = readBoolKey("debugUi")
  gDebugEsp = readBoolKey("debugEsp")
  # ---- THE ARBITRATION, STATED OUT LOUD --------------------------------
  # Both ESPs draw the same contacts by different routes, so both on means
  # every contact is boxed twice. The decision is made HERE, once, at config
  # load, and it is LOGGED with the loser and the reason -- a feature that
  # vanishes without saying so is the failure mode this repo keeps paying for.
  # Only the DRAWING is suppressed: `gDebugEsp` stays true so the GameWorld
  # cache detour it arms keeps feeding botdiag, raidphase and the admin mod.
  if gDebugEsp and gNeOn and gEspProvider != "both":
    gDuEspSuppressed = true
    warn "TWO ESPs were armed: natEsp (native uGUI boxes) and debugEsp " &
         "(in-world markers drawn by the D3D11 overlay). They render the " &
         "same contacts, so both on draws every contact TWICE -- this is the " &
         "doubled ESP that was reported live. espProvider=\"" & gEspProvider &
         "\", so natEsp WINS and debugEsp's MARKERS are suppressed for this " &
         "session. debugEsp itself stays ON and its detour stays armed, " &
         "because that is what caches the live GameWorld pointer for botdiag, " &
         "raidphase and the admin mod -- switching the flag off instead would " &
         "have broken three other features silently. Set espProvider to " &
         "\"overlay\" to swap the winner, or \"both\" to get the doubled " &
         "boxes back deliberately."
  elif gDebugEsp and gNeOn and gEspProvider == "both":
    warn "espProvider=\"both\": natEsp AND debugEsp are both drawing. Every " &
         "contact will be boxed twice. This is what was asked for, said once " &
         "so it is not mistaken for a bug."
  if gDebugUi or gDebugEsp:
    duLoadLayout()
    info "debugUi/debugEsp is set: a per-frame detour on EFT.UI.PreloaderUI." &
         "Update (the Unity main thread) will draw a Minecraft-F3-style info " &
         "panel" &
         (if gDebugEsp: " and in-world markers over every registered AI bot"
          else: "") &
         " out of Unity UI labels CLONED from the client's own version label " &
         "(Object::Instantiate -- no reflection, no object creation). Press " &
         (if gDuCfg.toggleVk == 0x72: "F3" else: "VK " & $gDuCfg.toggleVk) &
         " in game to toggle it; layout is " & gDuCfg.source &
         " and is re-read on every toggle-on, so it can be edited live. The " &
         "whole body is VEH-guarded and writes only into labels it created."
  # The main menu's bottom-right game-mode label. Default OFF until proven live:
  # it is the first thing this host does that CALLS a managed method on the
  # Unity thread as a feature rather than as a probe.
  # REMOVE THE BOTTOM-RIGHT MODE BUTTON (`uxHideModeButton`). Default OFF, and
  # a BRAND NEW KEY on purpose: a default in source is not a value, and a flag
  # whose default was flipped in source was still `true` in a deployed
  # config.json for two launch cycles. A new name cannot inherit a stale value.
  gModeHideOn = readBoolKey("uxHideModeButton")
  # Same MenuScreen event as the seasons banner and the version brand: the
  # mode-button resolve walked on a frame cadence and gave up after 30
  # post-warm-up walks. It now walks once per menu (re)build.
  if gModeHideOn: uihWant(UihSiteMenuShow)
  gModeTextOn = readBoolKey("uxMenuModeText")
  # BOTH READ FIRST, THEN LOGGED AS ACTUALLY READ, THEN RESOLVED. The two are
  # MUTUALLY EXCLUSIVE and that is enforced here rather than left to fight on
  # the Unity thread: `uxMenuModeText` rewrites the text OF the control
  # `uxHideModeButton` removes, so with both on the host would walk the tree
  # twice and paint an object nobody can see.
  info "uxHideModeButton read as " & (if gModeHideOn: "ON" else: "OFF") &
       "; uxMenuModeText read as " & (if gModeTextOn: "ON" else: "OFF") &
       " (these are the values actually read from config, not the defaults)"
  if gModeHideOn and gModeTextOn:
    gModeTextOn = false
    warn "uxHideModeButton and uxMenuModeText are BOTH set. They target the " &
         "same control (Common UI/ChangeGameModeButton -- fact #116), so " &
         "uxHideModeButton WINS and uxMenuModeText is FORCED OFF for this " &
         "session. Rewriting the caption of a hidden button is per-frame work " &
         "on the Unity main thread for something nobody can see."
  if gModeHideOn:
    info "uxHideModeButton is set: the host switches off " &
         "Common UI/ChangeGameModeButton -- the bottom-right PVE ZONE / " &
         "switch-game-mode control -- because the character/mode selection " &
         "screen is skipped on launch and this is the last route back into " &
         "it. Same primitive as uxHideSeasons: ONE GameObject::SetActive" &
         "(false), never a destroy, never set back to true. The button is " &
         "found STRUCTURALLY by walking from a verified scene root, bounded " &
         "to 4000 nodes and 4 ms per pass, on a 4-frame hunt cadence that " &
         "drops to 120 frames once hidden or if a pass overruns, and it gives " &
         "up LOUDLY after 300 s rather than searching forever."
  if gModeTextOn:
    info "uxMenuModeText is set: a postfix detour on EFT.UI.PreloaderUI.Update " &
         "will set the menu's bottom-right corner label by CALLING the game's " &
         "own PreloaderUI.SetGameModeText. The text comes from the backend's " &
         "`menuModeText` on the mod-sync poll, which defaults to the logged-in " &
         "character's name. It needs backendPort + modSyncMs. It SHARES the " &
         "PreloaderUI.Update detour with debugUi/debugEsp -- one detour, one " &
         "trampoline, both features dispatched from the same firing -- so all " &
         "three flags can be on at once."
  # THE LIVE INSPECTOR / REPL (opt-in, default OFF). Not a feature -- the
  # INSTRUMENT. It rides the same `PreloaderUI::Update` detour the two flags
  # above share, so it costs no detour of its own, and its per-frame cost with
  # nothing queued is one interlocked load.
  gInspOn = readBoolKey("liveInspector")
  gInspWriteOn = readBoolKey("liveInspectorWrite")
  # OPT-IN dev/menu accelerator: raise the find/findtext/tree-walk PER-FRAME time
  # slice so a big search finishes in one or a few frames instead of many. Default
  # keeps the shipped 12ms so nothing changes unless set. Clamped to a sane range.
  # DANGER (fact #261): a large slice stalls the Unity main thread -- do NOT use a
  # big value on a run that will LOAD a raid; it is for reading the MENU fast.
  block:
    let s = readIntKey("inspectorSliceMs", 12)
    if s >= 1 and s <= 1000:
      InspFindSliceMs = uint64(s)
      if s != 12:
        info "inspectorSliceMs=" & $s & " ms: the live inspector's find/findtext/" &
             "tree-walk per-frame time slice is raised from the default 12 ms. This " &
             "makes big MENU searches near-instant. Do NOT run a raid LOAD with a " &
             "large slice -- it stalls the Unity main thread (fact #261)."
  inspectInit(gDir)
  if gInspOn:
    info "liveInspector is set: drop commands into aowlspt-inspect.txt beside " &
         "this DLL and every save with changed content runs them ON UNITY'S " &
         "MAIN THREAD, with answers in aowlspt-inspect-out.txt and in this log " &
         "-- no rebuild, no restart. Start with `help` and `anchors`. Every " &
         "hop is VirtualQuery-guarded, every command runs under its own VEH " &
         "guard, and a caught fault reports THE LAST HOP ATTEMPTED and its " &
         "pointer. Reads only unless liveInspectorWrite is also set." &
         (if gInspWriteOn:
            " liveInspectorWrite IS set: a batch containing `allow write` may " &
            "store into live managed objects and CALL game code."
          else: "")
  elif gInspWriteOn:
    info "liveInspectorWrite is set but liveInspector is not, so the inspector " &
         "is off entirely; set liveInspector to arm it"
  # THE F2 LIVE-INSPECTOR OVERLAY (opt-in, `inspectorOverlay`). Default OFF. It
  # draws through the shared region, so it also needs `sharedRegion` armed; and
  # it only has anything to show when `liveInspector` is on. All three are read
  # here so a bad combination is a boot-log line, not a silent empty panel.
  gIoOn = readBoolKey("inspectorOverlay")
  if gIoOn:
    info "inspectorOverlay is set: a read-only D3D11 panel will surface the " &
         "live inspector's activity (bound anchors + a scrolling ring of the " &
         "commands it runs and their answers). Press F2 in game to toggle it " &
         "(configurable in aowlspt-inspoverlay.json, written with defaults on " &
         "first run). It is a shared-region DRAW participant -- the F3/F12/F6 " &
         "path -- so it needs sharedRegion armed" &
         (if not gInspOn:
            ", and liveInspector too (it is currently OFF, so the panel would " &
            "be empty)."
          else: ".")
  gVersionBrand = readBoolKey("uxVersionBrand")
  gVersionWrite = readBoolKey("uxVersionBrandWrite")
  if gVersionWrite:
    gVersionBrand = true          # the write path needs the probe armed
  # THE BRAND THAT ACTUALLY SHOWS. `uxVersionBrand` now also arms the POLLING
  # brand in `modstab.nim`, which walks to AlphaLabel -- the label really on
  # screen -- and writes through the game's own setters.
  #
  # ONLY ONE WRITER. The old Awake probe stays, flag-gated and READ-ONLY: its
  # write half is forced off here, because two features both claiming to brand
  # a version label is how the human was told once that this worked when it did
  # not. Nothing is deleted; the old path simply cannot write while this is on.
  gVerOn = readBoolKey("uxVersionBrand")
  # EVENT, NOT POLLING. The brand is applied and RE-applied on uihooks site 2
  # (MenuScreen::Show), because a clobber happens on a menu rebuild and that is
  # exactly this event. Subscribing is what causes the site to be bound at all.
  if gVerOn: uihWant(UihSiteMenuShow)
  if gVerOn and gVersionWrite:
    gVersionWrite = false
    info "uxVersionBrandWrite has been turned OFF: the polling brand in " &
         "modstab.nim owns the version label now (it walks to AlphaLabel and " &
         "writes through LocalizedText::SetLabelText / TMP_Text::set_text). " &
         "The old field-write probe aimed at an object whose m_text is EMPTY, " &
         "which is why it never visibly worked; it stays armed READ-ONLY."
  if gVerOn:
    info "uxVersionBrand is set: the host polls for " &
         "<PreloaderUI>/BottomPanel/Content/UpperPart/AlphaLabel -- the label " &
         "actually on screen -- and rewrites it to \"aowlspt <ver>, " &
         "aoughwl.com  -  tarkov <ver> | <mode>\", carrying both halves of " &
         "the stock text through. It REFUSES to write to a label whose text " &
         "reads empty, because an empty label is the fingerprint of the wrong " &
         "object. It rides the shared PreloaderUI::Update detour on a " &
         "120-frame throttle and gives up after 8 applies."
  # THE MAIN-MENU SEASONS BANNER (`uxHideSeasons`). Default OFF.
  # NATIVE TABS (docs/NATIVETABS.md step 1). Default OFF. Needs the live
  # SettingsScreen the settingsUiProbe ShowScreen postfix learns, exactly like
  # the postfx subtab below, and binds ONE read-only detour on
  # UnityEngine.UI.Toggle::Set for the tab-press event.
  gNtFlagOn = readBoolKey("nativeTabs")
  # THE SELECTION PROOF, default ON while step 1 is being proven: after the tab
  # builds it presses its own toggle, judges, presses GAME back and judges
  # again. "The tab exists" is not the claim doc 4 makes; "selecting it shows
  # our panel and only ours" is.
  # BOTH DEFAULT OFF NOW. Step 1 has a live PASS, and a PROOF tab in the
  # player's settings row is not something anyone asked for -- it was
  # scaffolding. The subtab strip does NOT depend on either: it belongs to the
  # stock GRAPHICS tab.
  gNtProofTabOn = readBoolKey("nativeTabsProofTab")
  gNtProofOn = readBoolKeyDef("nativeTabsProofSelect", false) and gNtProofTabOn
  # STEP 2 (docs/NATIVETABS.md 5). Default OFF until it has a live PASS of its
  # own: `settingsPostFxSubtab`'s old cloned-strip path stays the shipping one
  # until then, so a failure here costs nothing that works today.
  # DEFAULT ON: this is the shipping PostFX subtab path now. It has a live
  # PASS ("exactly one subtab reads m_IsOn=1 and its panel is the ONLY active
  # one of the two", with the stock SettingsList byte-identical to the
  # feature-off baseline), and the cloned-strip approach it replaces has been
  # deleted rather than left switched off.
  gNtSubOn = readBoolKeyDef("nativeTabsSubtabs", true)
  # `settingsPostFxSubtab` now means only "fold the stock POSTFX tab away and
  # let postfxrows build into the stock PostFX panel". The STRIP is nativetabs
  # -- so turning the old key on without the new one would hide the stock tab
  # and leave nothing able to reach PostFX. It therefore implies the new path
  # rather than being silently incomplete.
  # STEP 3 (docs/NATIVETABS.md 7). Default OFF. Takes its data from
  # `modsindex.nim`'s lazy /aowlspt/settings/index fetch -- armed on the MODS
  # panel's show edge, cached for the session -- and NOT from
  # `modSettingsRender`, whose boot-time per-mod fetch is the measured
  # character-select crasher.
  gNtModsOn = readBoolKey("nativeTabsMods")
  # STEP 4: CONTROLS > MODS, a keybind LIST (display only this pass). Default
  # OFF. Data from /aowlspt/keybinds on the same worker transport, armed on
  # that subtab's show edge and cached for the session.
  gNtKbOn = readBoolKey("nativeTabsKeybinds")
  if gNtKbOn and not gNtOn:
    gNtOn = true
    info "nativeTabsKeybinds needs nativeTabs (it uses the native-tab build " &
         "and the shared Toggle::Set event), so nativeTabs has been turned " &
         "on with it."
  gNtOn = gNtFlagOn
  if gNtOn and not gSettingsUiProbe:
    gSettingsUiProbe = true
    info "nativeTabs is set, so settingsUiProbe has been turned on with it -- " &
         "it needs the live SettingsScreen that probe's ShowScreen postfix " &
         "is what learns."
  if gNtOn:
    info "nativeTabs is set: the host adds ONE proof tab to the settings " &
         "screen, built from a real UIAnimatedToggleSpawner joined to the " &
         "STOCK ToggleGroup and a real cloned SettingsTab panel emptied of " &
         "its rows. This is step 1 of docs/NATIVETABS.md and it deliberately " &
         "renders no rows yet."
    # THE BIND IS NOT DONE HERE. It moved into the `gReady` region below,
    # after `cProPrimeAll()` and after GameAssembly.dll is loaded -- both are
    # preconditions for a verify to mean anything. Binding in this flag pass
    # produced, live, "Toggle::Set did not verify against the startup prologue
    # snapshot" at [0:00:00.000] on a build where the bytes are in fact
    # correct: the snapshot had not been primed and the module was not loaded,
    # so the capture failed and the verify failed closed. That is the SAME
    # mistake the native-UI census made ("0 of 25 verified (25 REJECTED)"),
    # and its comment below is why this one is not repeated.
  gGfxOn = readBoolKey("settingsPostFxSubtab")
  if gGfxOn and not gNtSubOn:
    gNtSubOn = true
    info "settingsPostFxSubtab is set, so nativeTabsSubtabs has been turned " &
         "on with it: the old cloned-strip implementation of that feature is " &
         "DELETED, and the subtab strip is now nativetabs' defineSubtabs. " &
         "Without it the stock POSTFX tab would be hidden with nothing able " &
         "to reach PostFX."
  if gNtSubOn and not gNtOn:
    gNtOn = true
    info "nativeTabsSubtabs needs nativeTabs (it builds the strip inside the " &
         "native-tab machinery), so nativeTabs has been turned on with it."
  if gGfxOn and not gSettingsUiProbe:
    gSettingsUiProbe = true
    info "settingsPostFxSubtab is set, so settingsUiProbe has been turned on " &
         "with it -- it needs the live SettingsScreen that probe's ShowScreen " &
         "postfix is what learns."
  if gGfxOn:
    info "settingsPostFxSubtab is set: POSTFX is folded into GRAPHICS as a " &
         "subtab. The top row loses its POSTFX button (SetActive(false) -- " &
         "HIDDEN, never destroyed, and restored if the feature faults out) " &
         "and both the Graphics and PostFX panels gain a cloned two-button " &
         "strip, GENERAL | POSTFX, that switches the two STOCK " &
         "panels. Neither panel is cloned or written to; only their active " &
         "state is driven, because the game switches panels by ESettingsGroup " &
         "and a subtab of ours is not one."
  # THE POSTFX SUBTAB'S **LEGACY** CONTENT (`settingsPostFxRows`).
  #
  # DEFAULT OFF, AND NOW LEGACY. These 29 rows are the front end for
  # `mods/graphics` -- our OWN D3D composite pass over the back buffer. That
  # approach is superseded by `settingsNativePostFx` (default ON, further
  # down), which drives the GAME'S OWN post-processing and shading instead:
  # the same knobs, in BSG's pipeline, in the right colour space, at no extra
  # frame cost, and with a read-back off the game's own state rather than a
  # name-only row that admits it changes nothing.
  #
  # This flag is kept, rather than deleted, because the graphics mod still
  # exists and someone may want its pass. It is meaningful only when that mod
  # is actually present; with it off and the native set on, the POSTFX page
  # carries the native rows alone. The two sets are additive and independent,
  # so turning this back on gives both.
  #
  # Still inert without BOTH of the two features it stands on, so that is
  # resolved here rather than left to discover its own emptiness on the Unity
  # thread.
  gPfxOn = readBoolKey("settingsPostFxRows")
  if gPfxOn and not gGfxOn:
    gPfxOn = false
    warn "settingsPostFxRows is set but settingsPostFxSubtab is NOT. The rows " &
         "are built into the stock PostFX Settings panel, and without the " &
         "subtab there is no way for the player to reach that panel at all -- " &
         "the rows would exist and never be seen. NOT arming it; set " &
         "settingsPostFxSubtab too."
  if gPfxOn and not gNkOn:
    gPfxOn = false
    warn "settingsPostFxRows is set but nativeUiKit is NOT. Every row is a " &
         "from-scratch TextMeshProUGUI built through nuikit, which refuses " &
         "wholesale while that flag is off, so this would log 40 refusals and " &
         "build nothing. NOT arming it; set nativeUiKit too."
  if gPfxOn:
    info "settingsPostFxRows is set: the stock PostFX Settings panel -- which " &
         "is EMPTY once the stock POSTFX tab is folded into Graphics -- is " &
         "filled with the 29 settings mods/graphics declares, built FROM " &
         "SCRATCH through nuikit. NOTHING IS CLONED. They are NAMES ONLY: the " &
         "live values need the mod schema fetch (modSettingsRender), which " &
         "crashes the client at character-select and is not depended on here. " &
         "The banner on the page says so, and rows the active Preset owns are " &
         "marked, because a control that silently does nothing is worse than " &
         "a label that admits what it is."
  # THE DLSS SECTION ON THE STOCK GRAPHICS PAGE (`settingsDlssRows`).
  # DEFAULT OFF, and resolved here rather than left to discover its own
  # emptiness on the Unity thread: it stands on the same two features the
  # PostFX rows do -- `settingsPostFxSubtab` is what locates and validates the
  # "Graphics Settings" panel transform this file walks from, and `nativeUiKit`
  # is what arms the byte-verified target table every call goes through.
  gDlrOn = readBoolKey("settingsDlssRows")
  if gDlrOn and not gGfxOn:
    gDlrOn = false
    warn "settingsDlssRows is set but settingsPostFxSubtab is NOT. The rows " &
         "are parented into GraphicsSettingsTab._settingsContainer, which is " &
         "reached by walking from the 'Graphics Settings' panel transform " &
         "that feature locates -- without it there is no validated receiver " &
         "to walk from. NOT arming it; set settingsPostFxSubtab too."
  if gDlrOn and not gNkOn:
    gDlrOn = false
    warn "settingsDlssRows is set but nativeUiKit is NOT. Every row is an " &
         "instantiated game prefab driven through nuikit's byte-verified " &
         "target table, which refuses wholesale while that flag is off, so " &
         "this would refuse five rows and build nothing. NOT arming it; set " &
         "nativeUiKit too."
  if gDlrOn:
    info "settingsDlssRows is set: five aowl.dlss rows (DLSS version, " &
         "upscaler, and the three DLSS-5 re-lighting knobs) are instantiated " &
         "from the game's own toggle/float-slider prefabs into the stock " &
         "Graphics page. NOTHING IS APPLIED IN-PROCESS -- nvngx_dlss.dll is " &
         "open in this process and OptiScaler read its ini at attach, so the " &
         "values take effect on the NEXT launch, where aowlspt-launch runs " &
         "tools/dlssapply.py and prints a PASS/FAIL verdict. Every caption " &
         "says 'applies on restart'."
  # THE TWO SUB-FLAGS, both DEFAULT OFF and both inert unless the section
  # itself is armed. Kept separate from `settingsDlssRows` on purpose: each
  # turns on a DIFFERENT new call path into the client, and a single flag would
  # make "the rows regressed" and "the dropdowns regressed" the same bisect.
  gDlrDropOn = readBoolKey("settingsDlssDropdowns")
  gDlrTipsOn = readBoolKey("settingsDlssTooltips")
  if (gDlrDropOn or gDlrTipsOn) and not gDlrOn:
    gDlrDropOn = false
    gDlrTipsOn = false
    warn "settingsDlssDropdowns/settingsDlssTooltips are set but " &
         "settingsDlssRows is NOT. Both only decorate rows that feature " &
         "builds, so with it off there is nothing for either to act on. NOT " &
         "arming them."
  if gDlrDropOn:
    info "settingsDlssDropdowns is set: 'DLSS version' and 'Upscaler' are " &
         "cloned from GraphicsSettingsTab._dropDownTemplate@0xB0 and filled " &
         "by calling the game's own DropDownBox::Show. That call is refused " &
         "unless the receiver's own vtable slot 24 resolves to one of three " &
         "byte-verified Show bodies AND the managed String[] this host builds " &
         "really carries IEnumerable<string> in the interfaceOffsets table " &
         "Show dispatches against -- a MANAGED throw there could not be " &
         "caught. Any refusal falls back to the stepper slider and says so."
  if gDlrTipsOn:
    info "settingsDlssTooltips is set: each DLSS row gets the game's own " &
         "hover tooltip, via a SettingsTooltipData template allocated against " &
         "a class borrowed from the stock DlssPreset row and filled through " &
         "the typed hostfieldwrite gate. The verdict re-reads " &
         "_tooltipSettingsHover@0x98 -> _tooltipData@0x20 -> Text@0x20 off " &
         "each row, because SetTooltip has three silent no-op paths."
  # ===========================================================================
  # THE POSTFX SUBTAB'S **NATIVE** ROWS (`settingsNativePostFx`) -- DEFAULT ON.
  #
  # This is the only flag in this block that defaults ON, and the reason is
  # that it REPLACES something rather than adding to it. `mods/graphics` --
  # our own D3D composite pass, and the 29 name-only rows `settingsPostFxRows`
  # builds for it -- is now LEGACY and DEFAULT OFF (see the note on that flag
  # above). Shipping the replacement OFF as well would leave the POSTFX page
  # empty, which reads to a player as a feature that was removed.
  #
  # What these rows do instead: they drive the GAME'S OWN pipeline. Every one
  # of them either calls an applier the game already ships
  # (`CameraManager::SetSharpen` / `SetSSAO`,
  # `PostFxSettingsController::TryUpdate*`, `ChangedShadowQuality`) at a
  # byte-verified prologue, or stores into a PrismEffects AO field through the
  # typed hostfieldwrite gate. No detour is bound and nothing is composited.
  #
  # It is still inert without the two features it stands on, so that is
  # resolved HERE rather than left to discover its own emptiness on the Unity
  # thread.
  gNpfOn = readBoolKeyDef("settingsNativePostFx", true)
  if gNpfOn and not gGfxOn:
    gNpfOn = false
    warn "settingsNativePostFx is on but settingsPostFxSubtab is NOT. The " &
         "rows are instantiated into PostFXSettingsTab._settingsRoot@0xa0, " &
         "reached by walking from the POSTFX panel transform that feature " &
         "locates -- without it there is no validated receiver to walk from, " &
         "and no way for the player to reach the panel at all. NOT arming " &
         "it; set settingsPostFxSubtab too."
  if gNpfOn and not gNkOn:
    gNpfOn = false
    warn "settingsNativePostFx is on but nativeUiKit is NOT. Every row is an " &
         "instantiated game prefab driven through nuikit's byte-verified " &
         "target table, which refuses wholesale while that flag is off, so " &
         "this would refuse every row and build nothing. NOT arming it; set " &
         "nativeUiKit too."
  if gNpfOn:
    info "settingsNativePostFx is ON (default): the POSTFX page carries " &
         "NATIVE rows that drive the game's own post-processing and shading " &
         "-- sharpen, the six folded-away 1.0 colour settings (clarity, " &
         "brightness, saturation, colourfulness, luma sharpen, adaptive " &
         "sharpen), SSAO quality at ALL SIX ESSAOMode levels rather than the " &
         "four the stock dropdown offers, and Prism's AO intensity / radius / " &
         "blur passes. Each row is SEEDED from the game's own current value " &
         "read back off the live component, applies through the game's own " &
         "applier, and prints an APPLIED line carrying the value read back " &
         "from the FINISHED STATE -- never our own write read back. " &
         "CameraManager.Instance being null (the main menu, where there is no " &
         "raid camera) is reported INCONCLUSIVE, not off. " & npfSummary()
  # THE SHADOW ROWS (`settingsNativeShadows`) -- ITS OWN FLAG, DEFAULT OFF.
  #
  # Separate from the set above because it is the ONE row that can cost real
  # frames: `ChangedShadowQuality` drives `QualityLevelPreset::Apply`, which
  # re-renders the shadow map at more cascades and a higher resolution. Every
  # other native row on that page is free or nearly so. A single flag would
  # make "the postfx rows regressed" and "the game got slower" the same bisect.
  gNpfShadowsOn = readBoolKey("settingsNativeShadows")
  if gNpfShadowsOn and not gNpfOn:
    gNpfShadowsOn = false
    warn "settingsNativeShadows is set but settingsNativePostFx is NOT. The " &
         "shadow row is built by that feature, so with it off there is " &
         "nothing for this to add. NOT arming it."
  if gNpfShadowsOn:
    info "settingsNativeShadows is set: a shadow-quality row is added to the " &
         "NATIVE postfx set. THIS IS THE EXPENSIVE ONE -- it is the only row " &
         "on that page that can cost real frames, because raising it " &
         "re-renders the shadow map at more cascades and higher resolution. " &
         "Its tooltip says so in those words. Its verdict reads back " &
         "QualitySettings.shadowCascades -- the ENGINE's own opinion, not the " &
         "QualityLevelPreset object we asked to be installed, because reading " &
         "the preset back would be a check that cannot fail."
  gSeasonsOn = readBoolKey("uxHideSeasons")
  gBetaNoticeOn = readBoolKey("uxBetaNotice")
  # Same event for the seasons banner, the mode button and the beta notice --
  # all three hang off the one MenuScreen the Show postfix hands us, so none of
  # them walks the scene any more.
  if gSeasonsOn or gBetaNoticeOn: uihWant(UihSiteMenuShow)
  # BOTH LOGGED AS ACTUALLY READ, not as defaulted, and then resolved here
  # rather than left to fight on the Unity thread. They target the SAME
  # GameObject -- `Common UI/MenuScreen/SeasonsButton` -- from opposite
  # directions: one switches it off, the other keeps it on and rewrites its
  # text. With both set the host would hide the object it is branding.
  info "uxHideSeasons read as " & (if gSeasonsOn: "ON" else: "OFF") &
       "; uxBetaNotice read as " & (if gBetaNoticeOn: "ON" else: "OFF") &
       " (these are the values actually read from config, not the defaults)"
  if gBetaNoticeOn and gSeasonsOn:
    gSeasonsOn = false
    warn "uxBetaNotice and uxHideSeasons are BOTH set. They target the same " &
         "object (Common UI/MenuScreen/SeasonsButton), so uxBetaNotice WINS " &
         "and uxHideSeasons is FORCED OFF for this session -- the banner " &
         "stays on screen carrying the aowlspt beta notice instead of the " &
         "KORD BREACH / Season caption. If the notice cannot find a text " &
         "node inside the banner it declines and hides the banner itself, so " &
         "the uxHideSeasons outcome is still what you get in that case."
  if gBetaNoticeOn:
    info "uxBetaNotice is set: the host REPURPOSES " &
         "Common UI/MenuScreen/SeasonsButton -- the KORD BREACH / Season " &
         "banner above Play -- to read the aowlspt beta notice " &
         "(aoughwl.com, F12 for mod settings). It is reached as one named " &
         "child of the SAME MenuScreen uxHideSeasons already resolves, so " &
         "there is no scene walk and no budget. The text is written by " &
         "CALLING LocalizedText::SetLabelText and TMP_Text::set_text -- a " &
         "raw m_text store is clobbered -- and re-applied on a throttle, so " &
         "a menu rebuild is re-branded. If NO non-empty TextMeshProUGUI is " &
         "found inside the banner, it writes NOTHING, says so, and switches " &
         "the banner off: half a notice is worse than none."
  if gSeasonsOn:
    info "uxHideSeasons is set: the host switches off " &
         "Common UI/MenuScreen/SeasonsButton -- the KORD BREACH / Season " &
         "banner above Play -- because seasons do not apply to single-player. " &
         "It is found STRUCTURALLY (the banner carries no matching text at " &
         "all) and re-checked on a 120-frame throttle so a menu rebuild is " &
         "hidden again. It only ever sets active=false, never true, and it " &
         "does nothing at all if that child is not there."
  if gVersionBrand:
    info "uxVersionBrand is set: a postfix detour on PreloaderUI.Awake will " &
         "probe the version label on the Unity thread" &
         (if gVersionWrite:
            " and (uxVersionBrandWrite) attempt a field-write brand to " &
            "\"aowlspt <em dash> <version>\" -- no runtime_invoke"
          else:
            " (read-only: logs thread, readability, class, and String fields; " &
            "no managed write)") &
         " (fail-safe: unbranded if the build or timing does not match)"

  # Image CDN redirect (opt-in). Independent of IL2CPP -- it hooks ws2_32, which
  # is up from the start -- so it installs here rather than waiting for the
  # runtime. Off by default; when on, it steers the BSG asset-CDN host to this
  # backend and logs every hostname the client resolves (drained in the tick
  # loop) so a live run confirms the exact image host. Fail-safe: a failed
  # install leaves DNS untouched.
  gImageCdnRedirect = readBoolKey("imageCdnRedirect")
  if gImageCdnRedirect:
    cCdnSetEnabled(1'i32)
    let mask = int(cCdnInstall())
    if mask == 0:
      warn "imageCdnRedirect is set but no getaddrinfo export could be hooked; " &
           "image CDN requests will not be redirected"
    else:
      okLog "imageCdnRedirect is set: getaddrinfo hooked (" &
            (if (mask and 1) != 0: "GetAddrInfoW " else: "") &
            (if (mask and 2) != 0: "getaddrinfo " else: "") &
            "); s3-*.escapefromtarkov.com -> 127.0.0.1, and every resolved host " &
            "is logged once to confirm the real image host"

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

      # THE PROLOGUE SNAPSHOT, and it must be here: before the first `bind*`
      # below, therefore before the first detour exists, therefore while every
      # target still holds its ORIGINAL bytes. Everything downstream that
      # prologue-verifies compares against what this captures, so a feature
      # that shares a target with a feature that armed earlier can still
      # verify it. Doing this later would record trampolines and defeat the
      # entire point.
      cProPrimeAll()
      okLog "prologue snapshot: captured the original bytes of " &
            $int(cProRowsUsed()) & " target(s) before any detour was " &
            "installed (" & $int(cProPrimedCount()) & " primed" &
            (if int(cProBadCount()) > 0:
               ", " & $int(cProBadCount()) & " unreadable and therefore " &
               "left unverifiable"
             else: "") & "). Every later prologue check compares against " &
            "this, not against live memory, so two features may share one " &
            "target and both still verify it."

      # CAPACITY, STATED OUT LOUD. A full snapshot table makes `aowl_pro_verify`
      # return 0 for an RVA that was never captured -- byte-for-byte the same
      # answer as "the bytes differ" -- so every affected feature then reports
      # itself unverified and blames the client build. `aowl_pro_full` counted
      # exactly that and NOTHING read it, which is how it could have been
      # happening for a whole release without anyone knowing.
      #
      # MEASURED when this was added: 155 distinct RVAs across abi/*.h against a
      # 128-row table. The bound is now 512. This line exists so the next time
      # it fills, the log says so instead of the features lying about why.
      if int(cProFullCount()) > 0:
        fail readCString(cProHealthLine())
        fail "READ THAT AS: the features whose RVAs were dropped have NOT been " &
            "verified and will refuse to bind. That is our capacity limit, " &
            "not a changed game build -- do not go hunting a client update. " &
            "Raise AOWL_PRO_MAX_ROWS in abi/aowlspt_prologue.h (currently " &
            $int(cProCapacity()) & ") and rebuild."
      else:
        okLog readCString(cProHealthLine())

      # THE TOKEN-GATE LAYER, and it belongs exactly here: GameAssembly.dll
      # is now mapped (the runtime came up through it), and no `bind*`
      # below has installed a detour yet, so every gated export still
      # holds its ORIGINAL bytes. The layer prologue-verifies each of its
      # 40 exports against what it captures now, never against live
      # memory -- snapshotting later would record trampolines.
      if gGatesOn:
        if cGateBind() == 0:
          warn "il2cppGates is set but the layer could NOT bind: " &
               "GetModuleHandleA(GameAssembly.dll) returned NULL or its " &
               "PE headers were unreadable at this point in boot. No " &
               "gated export will be called; nothing is degraded, " &
               "because nothing resolves by name through it yet."
        else:
          cGateSnapshot()
          cGateSetEnabled(1'i32)
          cGtRun()
          # Per-case detail FIRST, so the summary below can be checked
          # against the raw numbers instead of being taken on trust.
          var i = 0'i32
          let n = cGtCaseCount()
          while i < n and i < 8'i32:      # capped
            let line = $cGtLine(i)
            if cGtVerdict(i) == 1'i32: okLog "il2cpp gates: " & line
            elif cGtVerdict(i) == 2'i32: fail "il2cpp gates: " & line
            else: warn "il2cpp gates: " & line
            inc i
          # THE ONE-LINE VERDICT. It states what was proven and what was
          # not, and it never says "safe" off the back of a call that
          # merely returned something -- the trap returns something too.
          let verdict =
            if cGtFailCount() > 0: "UNSAFE -- a gated export did not " &
              "honour its token; do NOT resolve by name"
            elif cGtPassCount() >= 2: "the gate mechanism is PROVEN IN " &
              "THIS CLIENT for both flavours. By-name resolution is now " &
              "POSSIBLE; it is NOT automatically safe to HOOK, because " &
              "6,261 RVAs have more than one owner"
            elif cGtPassCount() > 0: "PARTIAL -- one flavour proved, the " &
              "other did not; treat by-name as UNPROVEN"
            else: "INCONCLUSIVE -- nothing was proven either way"
          info "il2cpp gates: " & $int(cGtStaticArmed()) & " of " &
               "22 static ARMED, " & $int(cGtNonceArmable()) & " of 18 " &
               "nonce ARMABLE, " & $int(cGtRefused()) & " refused (" &
               $int(cGtPrologueBad()) & " on prologue), " &
               $int(cGtFaults()) & " faulted; self-test " &
               $int(cGtPassCount()) & " PASS / " & $int(cGtFailCount()) &
               " FAIL / " & $int(cGtInconcCount()) & " INCONCLUSIVE -- " &
               verdict
          if cGtRefused() > 0:
            info "il2cpp gates: first refusal was " & $cGtFirstRefusal()
          # A LEAKED NONCE ARM is worse than a FAIL and is checked first.
          # `il2cpp_nonce` arms a single-use TLS slot that only the export
          # itself consumes. A slot left armed disables the zero-slot
          # early-out that has been silently protecting every
          # stock-signature by-name call in this codebase -- the ~20 in
          # mods/sain among them -- and the next one dies in memcmp at
          # GameAssembly.dll+0x6206E0. That is exactly how this layer killed
          # the client on its first live run, about a second after logging
          # a clean 2 PASS / 0 FAIL / 0 faulted.
          if cGtLeakedArms() != 0'i32:
            cGateSetEnabled(0'i32)
            fail "il2cpp gates: DISARMED -- the self-test left " &
                 $int(cGtLeakedArms()) & " nonce slot(s) ARMED on this " &
                 "thread. Every stock-signature by-name call on this " &
                 "thread would now fault inside memcmp instead of " &
                 "early-outing to the trap. The verdict above is void; " &
                 "nothing about the gate mechanism was proven by this run."
          if cGtFailCount() > 0:
            # A FAIL means the map is stale or this is a different build.
            # Disarming is the only honest response: leaving it armed
            # would let a later caller take a random pointer.
            cGateSetEnabled(0'i32)
            warn "il2cpp gates: DISARMED after a FAIL. Regenerate " &
                 "abi/aowlspt_il2cpp_gates_data.h with " &
                 "tools/il2cpp_gatescan.py against this GameAssembly.dll."

      # Before any mod loads, and for one reason that is not about timing: the
      # detour engine hands out slots in ascending order and the firing path
      # indexes `gPatches` by slot, so the host's own hook has to claim slot 0
      # before a mod can claim it. Failing here is not fatal -- the queue keeps
      # running on this thread, which is what it did before any of this existed.
      if not gBridgeEnabled:
        info "main-thread bridge disabled (unstable detour, see gBridgeEnabled);" &
             " invoke_main work is QUEUED AND HELD, never run on the " &
             "host's own thread"
      elif not bindMainDrain(true):
        warn "no per-frame method could be detoured, so there is no thread " &
             "on which a queued invoke_main callback is safe; the host HOLDS " &
             "them rather than running them on its own thread (" &
             $int(gHostThreadId) & "). A mod that gates on " &
             "aowlspt.host::main_thread.bound simply will not tick" &
             gatedRefusalNote()
      # The render-phase drain, tried once here and retried in the tick loop.
      # Its primary target rides a render callback that may only be alive in a
      # raid, so a boot failure is expected in the menu and is not warned about;
      # the tick loop binds it when the game reaches a scene that has it.
      if not bindRenderDrain(true):
        info "no render-phase point bound yet; invoke_render (GL/ESP drawing) " &
             "is unavailable until a raid brings up a render callback to detour"
      # Experiment A: the read-only settings probe. Static code, so it installs
      # now and fires the first time the user opens the settings screen.
      if gSettingsProbe and not bindSettingsProbe(true):
        info "the settings probe did not verify SettingsScreen.Show on this build"

      # Phase 1 native-settings control-tree probe. Static code, so it installs
      # now and fires the first time the user opens the settings screen.
      if gSettingsUiProbe and not bindSettingsUiProbe(true):
        info "the settings-UI probe did not verify SettingsScreen.Show on this build"

      # Phase 1.5: the hook that actually reads controls. `Show` above proved the
      # mechanism but fires BEFORE any tab's controls exist; they are built
      # lazily by EnsureTabInitialized, so the walk hangs off that method's
      # POSTFIX. Same flag, same read-only discipline, separate slot.
      # Phase 1.6: the walk that actually reads the controls, on the POSTFIX of
      # `SettingsTab::OnTabSelected` -- its own target, shared with nothing, so
      # it always arms regardless of what claims EnsureTabInitialized below.
      if gSettingsUiProbe and not bindSettingsTickProbe(true):
        info "the settings control poll did not verify " &
             "GameSettingsTab.Update on this build"

      # The direct-invocation proof ladder (opt-in, default OFF). It shares
      # `SettingsScreen::EnsureTabInitialized` with the Phase-1.5 group->tab
      # registry below, so it arms FIRST and that registry then skips itself:
      # two detours on one function would have the second overwrite the first's
      # trampoline. Only the registry is given up -- the Phase-1.6 control walk
      # above is on a different target and keeps running, falling back to
      # naming tabs by klass when the registry is absent.
      # The native-UI layer's target census. HERE, not in the flag pass: this
      # is after `cProPrimeAll()` and after GameAssembly.dll is loaded, which
      # are both preconditions for a verify to mean anything. Running it early
      # is what produced "0 of 25 verified (25 REJECTED)" on a build where all
      # 25 were in fact fine. It binds no detour of its own -- the proof rides
      # invoke2's postfix below.
      if gNuOn:
        bindNativeUi(true)
      # NATIVE TABS' one detour, HERE for the same reason as the census above:
      # the prologue snapshot is primed and GameAssembly.dll is loaded, so a
      # verify means something. Bound after `bindNativeUi` so the target table
      # has already been censused and any refusal is attributable.
      if gNtOn:
        if not ntBindToggleEvent(false):
          gNtOn = false
          warn "nativeTabs: the toggle event did not bind, so the feature is " &
               "OFF for this session. Nothing was patched and nothing was " &
               "changed; the settings screen is exactly the screen the game " &
               "builds."
        else:
          # THE CLOSE PAIR, immediately after and only if the feature is live.
          # A partial bind is reported by `ntBindCloseProbe` itself and is not
          # fatal: without it the close is merely as invisible as it has
          # always been, which is a lost instrument, not a broken feature.
          discard ntBindCloseProbe(false)
      # THE VALUE BINDING's two detours, AFTER the nativetabs block and not
      # before it. Its toggle half owns no detour at all: it rides the
      # `Toggle::Set` prefix nativeTabs binds just above, because two detours
      # on one function have the second overwrite the first's trampoline.
      # Binding first meant it could not SEE whether that prefix exists, and a
      # feature whose event source is another feature's flag must say so out
      # loud rather than register rows that nothing will ever fire.
      sbdBind(false, gNtToggleSlot >= 0)
      if gAuOn:
        bindAowlUi(true)
      # The native-UI toolkit's readiness report, in the same region and for the
      # same reason: it names the nu* targets it stands on, and asking before
      # GameAssembly.dll is loaded would report every one of them as a prologue
      # rejection and blame the game build for a start-order problem.
      if gNkOn:
        bindNuiKit(true)
      # The native uGUI ESP, for the same reason and in the same place: its
      # readiness report is only meaningful after GameAssembly.dll is loaded
      # and `cProPrimeAll()` has primed the prologue snapshot the layers it
      # stands on verify against. It binds no detour.
      if gNeOn:
        bindNativeEsp(true)
      # The native COLOUR WIDGET, in the same region and for the same reason:
      # its banner names four managed targets and one field offset, and asking
      # about any of them before GameAssembly.dll is loaded and
      # `cProPrimeAll()` has primed the prologue snapshot would report them as
      # prologue rejections and blame the game build for a start-order bug --
      # the measured mistake that moved `bindNativeUi` here in the first place.
      # It binds no detour; it rides the Update drain.
      bindColorWidget(gCwOn)
      # The native INVENTORY SCREEN, in the same region and for the same
      # reason: its banner names two managed targets and one field offset, and
      # asking about any of them before GameAssembly.dll is loaded would report
      # them as prologue rejections and blame the game build for a start-order
      # bug. It binds no detour; it rides the Update drain.
      bindInvUi(gIuOn)

      if gMi2Probe and not bindManagedInvoke(true):
        info "the managed-invoke probe did not verify " &
             "SettingsScreen.EnsureTabInitialized on this build"

      if gSettingsUiProbe and gMi2Slot < 0 and not bindSettingsTabProbe(true):
        info "the settings control probe did not verify " &
             "SettingsScreen.EnsureTabInitialized on this build"

      # SHOW-EVENT HOOKS (uihooks.nim). STRICT ORDER, and a new subscriber MUST
      # keep it: every `*WantShowHook` runs FIRST so the arm pass knows which
      # sites anyone actually wants, then ONE `uihArm` installs exactly those
      # detours, then each subscriber reads back whether its site really bound.
      # Arming per-subscriber instead would install a second detour on a site two
      # features share, and the second would overwrite the first's trampoline.
      splWantShowHook()
      modLoadWantShowHook()
      arWantShowHook()
      # THE MOD-FACING `ui.show` BUS. Wants its sites here, with everyone
      # else, because arming happens ONCE and mods load later: if this waited
      # for a mod to subscribe, whether a site was bound would depend on mod
      # load order. Flag `uiShowEvents`, default ON; it never wants site 1.
      uihEventsWantShowHook()
      # The MenuScreen::Show site index is verified BY NAME here and only then
      # handed to modeskip, which cannot see `UihSiteMenuShow` at all (it is
      # included before uihooks.nim, so that constant and that header's C
      # accessors are both out of scope there). A row inserted above it makes
      # this REFUSE and say so, rather than subscribing to another function.
      block:
        let mshowName = readCString(cUihSiteName(int32(UihSiteMenuShow)))
        if iContains(mshowName, "MenuScreen::Show"):
          modeSkipWantShowHook(UihSiteMenuShow)
        elif gModeSkipOn:
          warn "skip mode screen: uihooks site " & $UihSiteMenuShow &
               " reads \"" & mshowName & "\", which is not a " &
               "MenuScreen::Show site, so the cached-controller DROP is NOT " &
               "armed. The freshness rule (a new controller .ctor before any " &
               "re-answer) still applies, so this is a lost safety net, not " &
               "an unsafe path."
      uihArm(true)
      splShowHookVerdict()
      modLoadShowHookVerdict()
      arShowHookVerdict()

      # Version-label brand (opt-in). Static code, so it installs now and fires
      # when PreloaderUI.Awake runs on its way to the menu. Fail-safe if the
      # prologue does not match or if Awake already ran before this armed.
      if gVersionBrand and not bindVersionBrand(true):
        info "version brand did not arm (PreloaderUI.Awake unverified on this " &
             "build, or drain disabled)"

      # READ-ONLY bot/player census (opt-in). GameWorld.RegisterPlayer is static
      # code, so the detour installs now and simply never fires until an offline
      # raid starts and players/bots begin registering. Fail-safe if the prologue
      # does not match on this build.
      # THE TRUE DEPLOY SIGNAL for the shared raid-phase latch. NOT flag-gated:
      # `raidphase` is the single gate ESP and the maps HUD both read, and a
      # flag that turned this off would silently restore the ten-second early
      # arm the user reported three times. Read-only, fires at most once per
      # raid, and `bindRaidStart` announces loudly if neither target verifies.
      discard bindRaidStart(true)

      # THE DEPLOY-ORDER BREADCRUMB (opt-in, `natespDeployProbe`). Four
      # read-only POSTFIX drains on EFT.LocalGame, bound here for the same
      # reason as the row above: static code, installs now, fires only when the
      # client walks the deploy path. It MEASURES whether `OnGameStarted` --
      # the signal `raidphase` currently latches on -- runs before or after the
      # countdown actually ends, and it changes NO gate. `bindNeDeployProbe`
      # reads the flag itself and names every row that did not verify.
      discard bindNeDeployProbe(true)

      # THE VANILLA RAID-LOAD TIMELINE (opt-in, `loadPerf`). All 33 targets are
      # static code, so the detours install now and simply never fire until the
      # client walks the load path. `lpBind` reads the flag itself, names every
      # row that did not bind together with its RVA and the snapshot's own
      # reason, and refuses the whole feature outright if the C table and the
      # Nim row names ever disagree in count -- binding row i's timestamp to
      # row j's name would be a timeline that cannot be falsified.
      discard lpBind(true)

      if gBotDiag and not bindBotDiag(true):
        info "botdiag did not arm (EFT.GameWorld.RegisterPlayer unverified on " &
             "this build, or drain disabled)"

      # OFFLINE SCAV-CAP LIFT (opt-in). BotSpawner.AddPlayer is static code, so the
      # detour installs now and never fires until an offline raid init reaches it;
      # then it pokes MaxBots=0 once. Fail-safe if the prologue does not match.
      if gBotCap and not bindBotCap(true):
        info "botcap did not arm (EFT.BotSpawner.AddPlayer unverified on this " &
             "build, or drain disabled)"

      # CATCH THE IN-GAME ERROR DIALOG (default ON). The three PreloaderUI
      # error-screen entry points are static code, so the detours install now and
      # simply never fire until the client decides to raise a window. `bindErrDlg`
      # reports per-target and warns loudly if NONE bound, because a silently
      # unarmed watcher is worse than no watcher: the run would look supervised
      # and would not be.
      # THE IN-GAME MOD LOADING SCREEN (default ON). Nothing to detour; this
      # only resolves the file it will render.
      discard bindModLoad(true)
      # THE NATIVE LOADING STEP (modloadnative.nim), `modLoadNative`, default
      # OFF. Four read-only POSTFIX drains; it binds nothing when the flag is
      # off and says so loudly when it binds nothing while the flag is on.
      discard bindModLoadNative(true)

      if gErrDlg and not bindErrDlg(true):
        warn "errdlg did not arm; in-game error dialogs will NOT be caught on " &
             "this run. Treat any IDLE verdict from harness.py as INCONCLUSIVE " &
             "rather than as 'the client is fine and waiting'."

      # BOT AI ACTIVATION RESCUE (opt-in). BotOwner.PreActivate is static code, so
      # the detour installs now and never fires until an offline raid activates a
      # bot; then it releases that bot's WeaponManager.IsReady. Fail-safe if the
      # prologue does not match.
      if gBotAi and not bindBotAi(true):
        info "botai did not arm (EFT.BotOwner.PreActivate unverified on this " &
             "build, or drain disabled)"

      # NATIVE BOT NAVIGATION API (opt-in). BotOwner.UpdateManual is static code,
      # so the detour installs now and never fires until a raid has ticking bots;
      # then it registers each one and services its nav commands. Fail-safe if
      # the prologue does not match. Nothing else in this host detours
      # UpdateManual -- anything that later wants it must ride kind 15.
      if gBotNav and not bindBotNav(true):
        info "botnav did not arm (EFT.BotOwner.UpdateManual unverified on this " &
             "build, or drain disabled)"

      # THE IN-GAME DEBUG OVERLAY (opt-in). PreloaderUI::Update is static code,
      # so the detour installs now and starts ticking as soon as the preloader
      # is up -- but it draws NOTHING until the toggle key is pressed. The
      # GameWorld cache is armed only when botdiag did not take
      # `GameWorld::RegisterPlayer`; when it did, botdiag feeds the cache and
      # this correctly installs nothing.
      if gDebugUi or gDebugEsp:
        if not bindDebugUi(true):
          info "the debug overlay did not arm (EFT.UI.PreloaderUI.Update " &
               "unverified on this build, or drain disabled)"
        elif gDebugEsp:
          discard bindDebugEspWorld(true)

      # THE MENU'S BOTTOM-RIGHT GAME-MODE LABEL (opt-in). Bound LAST, and it
      # still is: it wants `EFT.UI.PreloaderUI::Update`, the same function the
      # debug overlay above wants. It no longer REFUSES when the overlay got
      # there first -- it RIDES on the overlay's single detour, so both features
      # are live together. Ordering still matters, because whoever arms first is
      # the one that owns the trampoline and the other must be able to see the
      # claimed slot to alias onto it.
      # `uxHideModeButton` rides the SAME slot for the same reason: it needs a
      # per-frame tick on the Unity thread and the button it hides is the very
      # object this rider already walks to. One detour, one trampoline.
      if gModeTextOn or gModeHideOn:
        if not bindModeText(true):
          info "menu mode text did not arm (PreloaderUI.Update or " &
               "SetGameModeText unverified on this build, or drain disabled)"
        elif gModeTextOn and readBackendPort() <= 0:
          # Gated on `gModeTextOn`, not on the arm: `uxHideModeButton` needs no
          # backend at all, and warning it has "no source" would be a
          # confidently wrong diagnostic.
          # ARMED WITH NO SOURCE, said at boot rather than a minute into the
          # menu. The label's text comes from the backend on the mod-sync poll,
          # and with no port this host cannot ask. `backendPort` falls back to
          # the installer's `backend.json`, so reaching here means BOTH were
          # absent -- the hook will sit there correctly doing nothing.
          warn "menu mode text ARMED but has NO SOURCE: there is no " &
               "backendPort in aowlspt-host.json and no backendUrl in " &
               "backend.json, so this host cannot ask the backend what the " &
               "label should read and the corner will keep the game's stock " &
               "text. Set backendPort to the backend's port to use this."

      # SKIP THE MODE SCREEN (opt-in). Independent of every rider above: its two
      # detours are on `CharacterSelectionScreenController::.ctor` and
      # `CharacterSelectionScreen::ShowSlot`, both UNSHARED RVAs that nothing
      # else in this host touches, so there is no ordering constraint and no
      # trampoline to contend for. Its deferred `Submit` rides the
      # `TarkovApplication::Update` drain, which is already bound by now.
      if gModeSkipOn:
        if not bindModeSkip(true):
          info "skip mode screen did not arm (see the reason logged above: " &
               "no launchProfileId, targets unverified on this build, or " &
               "drain disabled). The selection screen will appear as normal."

      # FEATURE F2 -- the NO-FRAME skip, bound HERE and not later because the
      # site it hooks fires inside the boot's own `RunInitialLobbyFlow`, which
      # is well after the first `TarkovApplication::Update` tick this block
      # runs on but well BEFORE the first `ShowSlot`. If the log never shows
      # this site firing, binding too late is the first thing to check.
      if gModeSkipProbeOn or gModeSkipNativeOn:
        if not bindModeSkipNative(true):
          info "skip mode screen (F2, native) did not arm (see the reason " &
               "logged above: the 0x97BBF0 prologue did not verify, no " &
               "launchProfileId with the probe off, or the drain is " &
               "disabled). The selection screen will appear as normal."

      # THE LIVE INSPECTOR (opt-in). Bound LAST of the three riders on
      # `EFT.UI.PreloaderUI::Update`, which is exactly where it wants to be:
      # by now either of the other two has claimed the slot and this aliases
      # onto it without re-verifying a function that may already carry their
      # JUMP. Only when neither armed does it verify and attach its own.
      if gInspOn and not bindInspect(true):
        info "the live inspector did not arm (PreloaderUI.Update is neither " &
             "claimed by another feature nor verifiable on this build, or the " &
             "drain is disabled); the command file will not be read"

      # THE F2 OVERLAY (opt-in, `inspectorOverlay`). A REGISTRATION with the
      # shared region, not a rider and not a detour; armed here, after the
      # inspector, so it starts feeding its ring only once the inspector exists.
      if gIoOn:
        discard ioArm(true)

      # THE CODEGEN AUDIT (opt-in, `codeGenAudit`). Armed LAST of the four
      # riders on `EFT.UI.PreloaderUI::Update`, so by here any of the other
      # three may have claimed the slot and this aliases onto it for free.
      if gCodeGenAudit:
        discard bindCodeGenProbe(true)

      # THE MODS TAB (opt-in, `settingsModsTab`). Armed LAST of the five riders
      # on `EFT.UI.PreloaderUI::Update`, so by here any of the other four may
      # have claimed the slot and this aliases onto it for free. It never
      # attaches a detour of its own.
      if gModsOn or gVerOn or gSeasonsOn or gGfxOn or gBetaNoticeOn:
        discard bindModsTab(true)

      # THE SHARED PER-FRAME REGION (opt-in, `sharedRegion`). Armed LAST of
      # every rider on `EFT.UI.PreloaderUI::Update`, so by here any of the
      # others may have claimed the slot and this aliases onto it for free
      # and attaches nothing. It is the generic one: from here on a
      # per-frame draw or tick is a registration, not another entry in
      # this list.
      if gRegionOn:
        discard bindRegion(true)

      # THE SINGLEPLAYER ANCHOR (opt-in via singleplayerRebrand OR the default-ON
      # forceOfflinePractice). Armed LAST of the PreloaderUI::Update riders, so by
      # here any of the others may have claimed the slot and this aliases onto it
      # for free; only if NONE is on does it attach its own read-only rider. This
      # is what makes the offline-force and the rebrand work in the shipped beta
      # with liveInspector OFF (fact #234): it guarantees `gSplUpdatePreloader` is
      # captured so `splFindScreen` has a DontDestroyOnLoad anchor to walk.
      if gSplOn or gSplForceOffline:
        discard bindSplPreloaderAnchor(true)

      # THE MAIN-MENU BETA NOTICE (opt-in, `uxBetaOverlay`). Not a rider
      # and not a detour: a REGISTRATION with the region armed just above.
      # Armed after it so the log reads in the order things happened.
      if gBetaOverlayOn:
        discard bindBetaNotice(true)


  let modsDir = joinPath(gDir, "mods")
  # The runtime may not have come up, and that deliberately does not stop this:
  # a client mod that only logs, schedules and talks to the backend works
  # perfectly well without IL2CPP, and a host injected into a process that has
  # none at all is exactly what `hostharness --inject` is. `resolve` and `call`
  # report it; loading does not gate on it.
  # NO MODS BY DEFAULT, then OUR loading step.
  #
  # The client is brought up carrying nothing, so the mods folder can be
  # COMPILED FROM SOURCE while the player watches a panel that names each mod
  # and whether it was built, cached or failed -- instead of a silent wait in
  # which "compiling" and "hung" look identical. `modload.nim` renders that
  # panel; `modLoadReleaseMods()` below is what ends the wait.
  #
  # THE SAFETY, and it is not optional: a deferral that never resolves leaves
  # the player with NO MODS AT ALL and no way to know why. So this is a
  # deferral with a DEADLINE, not a gate -- if the compile never reports, the
  # mods are loaded anyway and the log says plainly that the screen never
  # finished. Failing towards "your mods work" is the only acceptable
  # direction here.
  if gModLoadDeferMods and gModLoad:
    gModsDirDeferred = modsDir
    gModLoadDeferredAt = cNowMs()
    info "deferModLoad is on (default): the client is starting with NO mods " &
         "loaded. They are loaded once the mod build reports ready via " &
         gModLoadScreenPath & ", so the loading screen can show each one being " &
         "built or taken from cache. HARD DEADLINE " &
         $int(ModLoadDeferMaxMs div 1000'u64) & "s: if that never reports, the " &
         "mods are loaded anyway and this log says so -- a stuck screen must " &
         "never cost the player their mods."
  else:
    if modhost.loadAll(modsDir, modhost.SideClient, HostName, HostVersion) == 0:
      info "no mods loaded; the host will idle"

  # The overlay, on this thread and not a moment earlier.
  #
  # It creates a window, a D3D11 device and a thread. Every one of those
  # deadlocks under the loader lock, so it cannot go anywhere near `DllMain` --
  # this is the boot thread the constructor started, which is exactly the place
  # for it. A failure is a warning: a host that loses its overlay still runs
  # every mod, and a game that will not start because a panel would not draw is
  # a worse trade than no panel.
  # F12 opens the in-game settings panel (the revamped settings screen), matching
  # the BepInEx/SPT muscle memory where F12 opened the mod-config manager. The
  # panel is the D3D11 Present overlay â€” the one injection technique proven stable
  # on this client (static byte-patch / hand-drawn overlay), rather than the
  # crash-prone live-managed IL2CPP settings UI. See the F12 spike notes.
  if overlayStart(VkF12, int32(readBackendPort())):
    okLog "overlay ready (F12 opens settings)"
    for i in 0 ..< modhost.modCount():
      if modhost.modIsLive(i):
        overlaySetMod(modhost.modGuidOf(i), modhost.modNameOf(i),
                      modhost.modVersionOf(i), true)
  else:
    warn "the overlay did not start: " & overlayStatus()

  # Full-frame post-process (aowl.graphics). Both this and the overlay want to
  # detour DXGI Present, and the detour engine refuses a second hook on the same
  # function (error -9) â€” so they cannot each install one. When the overlay is
  # up it owns the Present hook, and graphics runs from the overlay's pre-present
  # callback: grade the raw frame first, overlay UI composites on top. When the
  # overlay is absent (it is being retired for native settings), graphics owns
  # its own Present hook. Either way a failure is a missing effect, never fatal:
  # the C side latches broken and the pass becomes a no-op.
  if overlayRunning():
    if graphicsStartDriven():
      overlaySetPrePresent(graphicsGradePtr())
      overlaySetPreResize(graphicsReleasePtr())
      okLog "graphics post-process ready (via the overlay Present hook) â€” " &
            graphicsStatus()
    else:
      warn "the graphics post-process did not start: " & graphicsStatus()
  else:
    if graphicsStart():
      okLog "graphics post-process ready (own Present hook) â€” " & graphicsStatus()
    else:
      warn "the graphics post-process did not start: " & graphicsStatus()

  # The mods are up, so the host can start answering the manager. Before this
  # point a control request is ignored rather than queued.
  startModControl()

  # And the other half of it, which is the half that works across a process
  # boundary.
  #
  # `startModControl` wires this host into the manager's *event* protocol, and
  # on the server that is the whole story: the manager and the host share an
  # event channel because they share a process. Here they do not. Nothing in
  # this process ever emits `aowlspt.host.mods.unload`, so until now a player
  # switching off a client-side mod changed a stored selection on the server and
  # nothing at all in the game until it was restarted.
  #
  # So the client asks instead. The overlay's worker thread -- which already
  # exists, already polls, and is already the one HTTP client in this process --
  # fetches the manager's client-side decisions every few seconds, and the tick
  # loop below turns the newest whole answer into loads and unloads. The
  # direction matters: the backend is asked, never listened to, so a backend
  # that is down, starting or answering something else leaves this host running
  # precisely what it is running.
  let syncPort = readBackendPort()
  let syncMs = readSyncMs()
  if syncPort <= 0:
    info "no backendPort in aowlspt-host.json, so this host cannot ask the " &
         "server which mods to run; it loads what is in mods/ and keeps it"
  elif syncMs <= 0:
    info "modSyncMs is 0, so live mod control from the server is off"
  else:
    # The host's own version goes in the path: the manager checks each mod's
    # `pipeline` range against it, and without it the range would be matched
    # against the backend's version instead -- a different program, allowed to
    # be at a different version.
    gSyncBase = "/aowlspt/mods/client/" & HostVersion
    gSyncMs = syncMs
    gSyncPath = gSyncBase
    # Name this process before the first poll goes out. Only a host that asks
    # gets a session, because a session is only ever used to answer -- and the
    # answer exists to stop the manager holding a verdict from a client that has
    # since been restarted, which looks authoritative and is about a process
    # that no longer exists.
    let session = hex16(cNowMs() * 65536'u64 +
                        uint64(gHostThreadId and 0xFFFF'u32))
    modcontrol.reportSession(session)
    overlaySyncStart(gSyncPath, int32(syncMs))
    okLog "asking the backend on port " & $syncPort & " which client mods " &
          "should be running, every " & $syncMs & "ms; this host reports back " &
          "as session " & session

  okLog "host running"

  # Queued from *this* thread, drained by whoever drains. When the two are
  # different threads, the line it writes is the proof -- not the claim -- that
  # `invoke_main` leaves this thread and arrives on Unity's.
  enqueueHostSafe(cNowMs())

  var lastTick = cNowMs()
  gLastFireMs = lastTick
  var nextBindTry = lastTick + 5000'u64
  # How often the host may repeat the "the drain is not carrying work"
  # report while the state has not changed. Fifteen seconds, not two: the
  # first ~15 s of every boot is legitimately `DrainNeverFired`, and a line
  # a second about a wait the game imposes on us is noise that hides the
  # line that matters.
  var nextDrainSay = lastTick
  var nextRenderTry = lastTick + 5000'u64
  # OS-close subclass retry clock (see the tick-loop block below).
  var nextCloseTry = lastTick
  let closeGiveUpAt = lastTick + 300000'u64
  # One-shot backend-key dump, deferred until the client has reached its menu
  # and initialised HTTPTransportManager on its own -- reading (or worse,
  # force-initialising) it right after il2cpp_init faults and kills the game.
  var keyDumpAt = lastTick + 20000'u64
  var keyDumped = false
  # Backend-key runtime dump left in but disabled: reading IL2CPP class metadata
  # from the host's own thread faults too readily on the real client, even behind
  # VEH-guarded name reads. Ground-truth response shapes come from offline
  # analysis of the decrypted metadata + binary disassembly instead.
  discard keyDumpAt
  discard keyDumped
  while true:
    cSleep(16'i32)
    let now = cNowMs()
    let elapsed = int64(now - lastTick)
    lastTick = now

    # The codeGenModule audit self-test, retried from here rather than run once
    # at drain-bind. It gates itself on `codeGenAudit`, on the runtime being
    # queryable, on a delay, and on there being at least one method it can
    # actually compare -- so on most ticks it returns immediately having done
    # nothing, and it logs exactly once, when it has an answer worth logging.
    codeGenAuditHostPass()

    # OS-close hooks, checked here for the whole session (see `aowlspt_uxpatch.h`
    # for the three-step history that led to this shape).
    #
    # This is a CHECK, not a re-install. The hooks are thread-scoped, so once
    # they are on the game's UI thread they cover every window that thread pumps
    # -- including the one the raid re-creates. All this does per tick is find
    # the main window and compare its thread id with the one already hooked; if
    # they match it returns having written nothing, anywhere. The only case that
    # installs anything is a genuinely different UI thread id, which should never
    # happen in a normal session and is logged loudly if it does.
    #
    # The previous version wrote to windows every tick (re-subclassing across
    # threads) and killed the client eight seconds into boot. Nothing here writes
    # in the steady state, and nothing writes to a window at all.
    if gOsCloseFix and now >= nextCloseTry:
      nextCloseTry = now + 2000'u64
      var rearmed = 0'i32
      let armed = cUxCloseArm(addr rearmed)
      if rearmed != 0'i32:
        if not gCloseEverArmed:
          gCloseEverArmed = true
          okLog "exit fix: OS-close hooks installed on UI thread " &
                $cUxCloseTid() & " (main window 0x" & hexOf(cUxCloseHwnd()) &
                ") -- window X / taskbar Close / Alt+F4 now exit via " &
                "ExitProcess(0) instead of the hanging async shutdown"
        else:
          okLog "exit fix: OS-close hooks moved to UI thread " &
                $cUxCloseTid() & " (main window 0x" & hexOf(cUxCloseHwnd()) &
                ") -- the game's UI thread changed; the hooks follow it"
      elif armed == 0'i32 and not gCloseEverArmed and not gCloseWarned and
           now >= closeGiveUpAt:
        gCloseWarned = true          # say it once, but keep checking
        warn "exit fix: no main game window appeared within 5 minutes; the " &
             "OS-close hooks are not installed yet (window-X may still hang; " &
             "the Exit button is patched). Still checking."
    # THE HTTP COMPLETION DRAIN. Here, on the HOST thread, and not on the
    # worker that made the request -- `hostEmit` -> `deliverEvent` calls each
    # subscriber's handler SYNCHRONOUSLY on the emitting thread, so emitting
    # from a fresh worker would run a mod's handler on a thread the mod has
    # never seen, concurrently with its own ops tick, and on a thread mimalloc
    # did not watch it initialise on (CLAUDE.md section 1: that shape
    # `__fastfail`s with no Unity crash report at all). `hostnet.nim`'s banner
    # is the long form of this argument.
    #
    # Bounded per tick. On any session that never calls the verb this is one
    # interlocked compare and a return -- `aowl_hn_take_done` does not even
    # take its lock when nothing was ever submitted.
    block:
      var hnTaken = 0
      while hnTaken < HnDrainPerTick:
        let hnDone = hnTakeCompletion()
        if hnDone.len == 0: break
        hostEmit("host.http.done", hnDone)
        hnTaken = hnTaken + 1

    # Log any newly-seen resolver host from the image-CDN hook. Drained here, on
    # the host thread, because the hook fires on the game's DNS thread where
    # opening a log file mid-resolve is not safe. First sight only, so this is
    # near-always a no-op; the point is the one-time confirmation of which host
    # the image loader dials.
    if gImageCdnRedirect:
      var redir = 0'i32
      while true:
        let seen = cCdnTakeNewStr(addr redir)
        if seen == nil: break
        let hostName = $seen
        okLog "image-cdn: client resolved " & hostName &
              (if redir != 0: " -> redirected to 127.0.0.1" else: " (not redirected)")

    # Retry while nothing is bound. The first candidate that is worth having is
    # a game type, and the game's own types come up long after the runtime
    # does -- resolving once at boot would report a false negative for the rest
    # of the session. Quiet after the first attempt: the reasons do not change.
    if gBridgeEnabled and gDrainSlot < 0 and gReady and now >= nextBindTry:
      nextBindTry = now + 5000'u64
      if bindMainDrain(false):
        okLog "the main-thread drain bound late, on " & gDrainMethod
        # The boot self-test already ran -- on this host thread, because nothing
        # was bound then. Queue a fresh one so the managed-call proof actually
        # fires on Unity's thread now that there is a drain to carry it. This is
        # the only path that reaches the raid-only fallback target, so without it
        # that target would bind without ever proving itself.
        enqueueHostSafe(now)

    # The render-phase drain, retried on the same cadence: its render callback is
    # typically raid-time, so it usually binds here rather than at boot. When it
    # binds, queue a render self-test so the GL-path proof fires on the render
    # thread. `nextBindTry` is shared with the update retry above -- both are
    # cheap and neither needs its own clock.
    if gRenderDrainSlot < 0 and gReady and now >= nextRenderTry:
      nextRenderTry = now + 5000'u64
      if bindRenderDrain(false):
        okLog "the render-phase drain bound late, on " & gRenderMethod
        enqueueRender(cast[Il2CppPtr](0), cast[Il2CppPtr](0), -1, true)

    let fires = int(cMqFireCount())
    if fires != gLastFire:
      gLastFire = fires
      gLastFireMs = now
      gLastHealth = DrainLive
      if gDrainStalled:
        gDrainStalled = false
        okLog "the main-thread drain is firing again on " & gDrainMethod
      if not gDrainProven:
        gDrainProven = true
        # Reported from here rather than from the drain: the drain runs inside
        # the game's update path and opening a log file there would cost a file
        # handle on a frame, every frame it first fires.
        let mainTid = int(cMqThread())
        okLog "the drain fires on thread " & $mainTid & "; the host runs on " &
              $int(gHostThreadId)
        if uint32(mainTid) == gHostThreadId:
          # Only possible if the hooked method were somehow called from this
          # very thread, which would mean it is not the player loop's.
          warn "the drain fires on the host's own thread, so it is not " &
               "Unity's; a callback that touches a Unity object is unsafe " &
               "even though it is being dispatched"
        else:
          okLog "invoke_main now runs on Unity's main thread (" &
                gDrainMethod & ")"
    else:
      # WHY THE DRAIN IS NOT FIRING, in four states rather than one sentence.
      #
      # The old code had a single test -- "bound, and the fire count has not
      # moved for 2 s" -- and one response: take the queue back onto this
      # thread. Both halves were wrong.
      #
      # The clock was wrong because `gLastFireMs` was seeded at host boot, so
      # before the FIRST firing it measured how long ago the host started, not
      # how long ago the game stopped. `EFT.TarkovApplication::Update` is
      # detoured at ~0:00:01, as soon as the runtime can resolve the method, and
      # is first CALLED at ~15 s, because the behaviour the player loop ticks
      # does not exist until the preloader has built it. Nothing on our side can
      # make that happen sooner -- there is no earlier per-frame call on Unity's
      # thread to bind, which is the whole reason the candidate list exists. So
      # a 2 s patience against a 15 s wait was wrong BY DESIGN, and the state it
      # produced was not a stall: nothing had stopped, nothing had started.
      # `DrainNeverFired` says exactly that and nothing follows from it.
      #
      # The response was wrong for the reason in `runPending`. It is gone.
      let health = int(cMqHealth(int32(gDrainSlot), int32(fires),
                                 now - gLastFireMs, DrainStallMs))
      let stalledNow = (health == DrainStalled)
      if stalledNow != gDrainStalled:
        gDrainStalled = stalledNow
      if health != gLastHealth or (cMqCount() != 0'i32 and
                                   now >= nextDrainSay):
        # On CHANGE, or every 15 s while work is actually waiting. Silent when
        # the queue is empty, however unhealthy the drain is: a drain that is
        # not firing and has nothing to carry is not costing anybody anything,
        # and a line a second about it would bury the run.
        let depth = int(cMqCount())
        if health != DrainLive and depth != 0:
          nextDrainSay = now + 15000'u64
          gLastHealth = health
          warn "the main-thread drain is not carrying work: " &
               $cMqHealthText(int32(health)) & " (" & gDrainMethod &
               ", slot " & $gDrainSlot & ", fires " & $fires & ", " &
               $int((now - gLastFireMs) div 1000'u64) & "s since the count " &
               "last moved). " & $depth & " callback(s) are QUEUED and are " &
               "STAYING queued -- " & $gMqDeferred & " dispatch(es) deferred " &
               "so far. They will run on Unity's thread when it comes back " &
               "and on no other thread; running them here is the crash of " &
               "2026-09-02 (Input::GetKey off the main thread)." &
               (if health == DrainNeverFired:
                  " This is the ORDINARY state of the first ~15s of a boot " &
                  "and is not a fault."
                else: "")
        else:
          gLastHealth = health

    # THE COST OF DEFERRING, said out loud. `gMqRefused` only moves when the
    # queue is at `MqQueueCap` and a mod asked for another callback, which can
    # only happen if the drain has been silent for a long time -- so this line
    # is the difference between "work is waiting" and "work has been thrown
    # away", and those must never look the same in a log.
    if gMqRefused != gMqRefusedSaid:
      gMqRefusedSaid = gMqRefused
      warn "invoke_main REFUSED " & $gMqRefused & " callback(s): the queue is " &
           "at its cap of " & $MqQueueCap & " because the main-thread drain " &
           "is not firing (" & $cMqHealthText(int32(gLastHealth)) &
           "). These callbacks were NOT run anywhere and will not be; the " &
           "ones already queued still will, on Unity's thread."

    if not gAlienReported and cMqAlienFires() > 0'i32:
      gAlienReported = true
      # The hooked method turned out to be called from more than one thread.
      # Only the first thread to reach it ever drains, so this is a note about
      # the candidate rather than a fault -- but it means the choice was not as
      # main-thread-only as it looked.
      warn gDrainMethod & " also runs on other threads; only thread " &
           $int(cMqThread()) & " drains the queue"

    # THE LIVE INSPECTOR'S file channel. On this thread and not Unity's: it
    # opens and writes files, which is not something to do on a frame. All it
    # does here is hand a batch over and publish the answer the previous batch
    # produced; the batch itself runs on Unity's main thread. Costs one shared
    # file open every 250 ms while armed, and nothing at all when it is not.
    inspectPoll(now)
    runPending()
    # THE SHARED SLOT'S TAKE CURSOR IS ONE CURSOR, NOT TWO. `modSetTick`
    # and `takeModSet` both read `overlaySyncTake` against the same
    # serial/taken pair; the comment on `overlaySyncTake` already warns
    # "0 is another caller got there first" -- and until this line, the
    # other caller was always `takeModSet`, called first, every tick, so
    # every settings-index/schema body the backend ever answered was
    # consumed and discarded here before `modSetTick` could read it (it
    # is not valid `DesiredMod` JSON, so `takeModSet` silently dropped it
    # and returned). `modSetTick` gets first and exclusive access to the
    # slot for as long as it owns the path it armed; mod control's own
    # take only runs the rest of the time.
    modSetTick(now)
    if not modSetOwnsSlot():
      takeModSet()
    # The client-settings bridge reads the POST slot BEFORE `modSetDrainPost`
    # for the same reason `modSetTick` reads the GET slot before `takeModSet`:
    # one cursor, two readers, and whoever reads first wins. `sbTick` only
    # consumes a reply it armed itself (`gSbArmedAt`), so a native-page write
    # still reaches `modSetDrainPost` untouched.
    sbTick(now)
    modSetDrainPost()
    # Live mod control, off the emitting stack -- the only place in this host a
    # mod is loaded or unloaded while the game is running.
    modcontrol.drain()
    # THE RELOAD LEDGER, to the host log, and ONLY when a number moved. This is
    # what makes the acceptance test runnable at all: without it the counters
    # exist inside the process and no one outside can read them, so "it
    # reloaded" and "nothing happened" produce the same evidence -- nothing.
    #
    # `epoch` is the falsifiable half. It goes up once per COMPLETED unload, so
    # a mod that reports it on load reports a different number every reload; the
    # same number twice means the library did not change over, however healthy
    # the other counters look.
    #
    # A line only on change, for the reason every other counter in this loop is:
    # a line per frame at 60 fps buries the one that mattered.
    let rl = modcontrol.hotReloadCounters()
    if rl != gRlLast:
      gRlLast = rl
      # `hotreload:` with no space is the grep handle. Measured complaint from a
      # live run: a plain search for "refus" in this log is dominated by rdcache
      # and natesp, so the two lines that mattered were buried. Every line this
      # feature writes carries this prefix and nothing else in the host does.
      info "hotreload: attempted=" & $rl[0] & " completed=" & $rl[1] &
           " released=" & $rl[2] & " refused=" & $rl[3] &
           " deferred=" & $rl[4] & " epoch=" & $rl[5] &
           (if rl[1] > rl[2]: "  <-- COMPLETED BUT NOT RELEASED: the teardown " &
                              "ran and the DLL is still locked" else: "")
      # THE REASON, PER ATTEMPT, ON THE SAME OCCASION AS THE COUNT.
      # MEASURED 2026-09-04: the 6bd304e3 boot printed refused=4 and the host
      # log carried no cause for any of the four, so the number could not be
      # acted on. These lines come from the ledger itself rather than from a
      # separate log call, so a count without a reason is no longer possible.
      let notes = modcontrol.hotReloadNotes()
      var ni = 0
      while ni < notes.len:
        info "hotreload:   " & notes[ni]
        ni = ni + 1
      let dropped = modcontrol.hotReloadNotesDropped()
      if dropped > 0:
        info "hotreload:   ... and " & $dropped & " further attempt(s) whose " &
             "reason was not recorded (the " & $modcontrol.RlMaxNotes &
             "-line cap). This list is TRUNCATED, not complete."
      if rl[0] > 0 and notes.len == 0 and rl[1] == 0:
        warn "hotreload: " & $rl[0] & " attempt(s) and no completion and NO " &
             "RECORDED REASON. That is a defect in this ledger, not a verdict " &
             "about the mods."
      # The falsifiable half. `epoch` says the unload ran; only the version
      # string says the NEW code came back.
      let (vb, va) = modcontrol.hotReloadVersions()
      var vi = 0
      while vi < vb.len:
        if vi < va.len:
          info "hotreload:   version " & vb[vi] & " -> " & va[vi] &
               (if vb[vi] == va[vi]:
                  "  <-- THE SAME STRING: the library did not change over, " &
                  "however healthy the counters look"
                else: "  (changed over)")
        else:
          info "hotreload:   version " & vb[vi] & " -> UNMEASURED: this mod " &
               "was unloaded and has not come back, so whether the new code " &
               "loads is unknown, not proven"
        vi = vi + 1
    # And the answer, on the way back out. It rides the next poll of the same
    # route the desired set came in on -- see `publishReport`.
    publishReport(now)
    # THE DEFERRED MOD RELEASE, PERFORMED HERE AND NOWHERE ELSE.
    #
    # The gate that decides WHEN is on the Unity main thread (`modLoadTick`,
    # riding the `TarkovApplication::Update` drain); the LOAD is here, on the
    # same thread as the `modhost.tickMods` below it, because a mod's mimalloc
    # default heap is bound to the thread that first allocated on it and a
    # foreign thread allocating on it is a FAIL-FAST no guard can catch
    # (measured 2026-09-02 13:18, 0xc0000409 in admin.dll). Immediately before
    # tickMods on the same pass, so a mod loaded here is ticked on this pass.
    # Idle cost is one boolean compare.
    modLoadReleaseDrain()
    modhost.tickMods(elapsed)
