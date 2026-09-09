## perfbench -- what a client-side call actually costs.
##
##     perfbench [PATH-TO-GameAssembly.dll] [--iters N]
##
## The claim aowlspt makes for the client is that a native mod beats the
## C#/BepInEx mod it replaces. That claim is only worth anything with a number
## behind it, and the number that matters is not "native is faster than
## managed" -- it is *which of aowlspt's own paths you used*. The boxed path and
## the bound path differ by more than an order of magnitude, and a mod that
## ports a per-frame loop onto the boxed one comes out slower than the C# it
## replaced. This tool exists so that is a measurement rather than an opinion.
##
## It runs against `tests/mockil2cpp`, which is a stand-in. What that does and
## does not establish is set out in docs/PERF.md and repeated in the output,
## because a benchmark whose caveats live somewhere else gets quoted without
## them.
##
## Build: `aowl build` and `aowl test` already build this, through
## `buildPerfBench` in `tools/aowl.nim`. It is a separate step from the other
## tools because it needs `--passC:-DAOWLSPT_FAST_BENCH` for the fast path's
## bench fixture and the host's own `invoke` for the boxed path it measures
## against. By hand, that is:
##
##     nimony c --passC:-I<repo>/abi --passC:-DAOWLSPT_FAST_BENCH \
##       -p:<repo>/installer/src -p:<repo>/aowl/src \
##       -p:<repo>/host/Aowlspt.Host.Il2Cpp \
##       -o:<repo>/installer/build/perfbench.exe <repo>/tools/perfbench.nim

import std/[syncio, cmdline, strutils]
import aowlspt/il2cpp
import aowlspt/fast
import invoke

# Both headers, here, because a `{.emit.}` in an imported module does not
# necessarily land above this translation unit's uses of it -- the include
# guards make a second one free.
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_fast.h" """.}

# The bench fixture from `abi/aowlspt_fast.h`. See the header for why the
# benchmark brings its own compiled methods rather than using the mock's:
# the mock's `methodPointer` is a generic invoker taking `void**`, where the
# real runtime's is the compiled method with the declared signature.
proc benchMethod(which: int32): Il2CppPtr {.importc: "aowl_bench_method", nodecl.}
proc benchTicks(): int32 {.importc: "aowl_bench_tick_count", nodecl.}

const Usage = """
perfbench -- nanoseconds per client-side operation, against tests/mockil2cpp

  perfbench [PATH-TO-GameAssembly.dll] [options]

Options
  --iters N     iterations for the cheap operations (default 2000000)
  -h, --help    this
"""

# ---------------------------------------------------------------------------
# The patch paths
# ---------------------------------------------------------------------------
#
# A hook's price is not the detour. It is the payload, and until ABI revision 4
# there was one payload: JSON. These rows are what that costs and what the typed
# frame costs instead, on the same method, in the same run, with the same
# detour engine underneath.
#
# **What is measured.** `EFT.Player::Ping(Single) -> Single` in the stand-in, a
# static compiled method reached through a bound call -- so the unpatched row is
# a real bound call and every other row is that same call with the detour in the
# middle. The dispatchers below are the host's: they call `describeArgs`,
# `describeReturn` and `applyPatchReturn` out of `invoke.nim`, which is the host
# module, rather than a second implementation that could be faster than the
# thing being reported on. What they stand in for is the mod: a JSON row copies
# the payload into a second string, because that is what `toString` does on the
# other side of the ABI, and reads one member out of it.
#
# Every row in the table below uses `EFT.Player::Ping` and nothing else, and it
# is checked at run time for having a compiled body rather than an invoker --
# see `pbIsCompiled`. The fast-path rows above use `abi/aowlspt_fast.h`'s own
# fixture, which is compiled by construction.
#
# **What is not measured**, and it favours JSON: `Ping` takes a float and no
# references, so `describeArgs` registers no GC handle. A hook on a method with
# an object argument -- which is most of the interesting ones -- pays one
# `il2cpp_gchandle_new` and one `il2cpp_gchandle_free` per reference per firing
# on top of these numbers, and the typed path pays neither.

{.emit: """#include "aowlspt_detour.h" """.}
{.emit: """#include "aowlspt_frame.h" """.}

# Is the method this is about to time a *compiled* one?
#
# `tests/mockil2cpp` carries two function pointers per method: the invoker,
# which `il2cpp_runtime_invoke` calls and which boxes its result, and the
# compiled body with the signature IL2CPP would give it. A row with no compiled
# body has `methodPointer` pointing at the invoker -- so binding it, detouring
# it or timing it measures the invoker, plausibly and silently. A bound call on
# one reads the boxed object's *address* as the return value: as a bool that is
# true about fifteen times in sixteen because the allocator aligns, which passes
# once and fails 6.25% of the time over two hundred thousand calls.
#
# So it is asked rather than remembered. `-2` means the runtime is not the
# stand-in and has no such export, which is not a failure -- against the real
# GameAssembly every method is compiled by definition.
{.emit: """
static int32_t aowl_pb_is_compiled(void* mod, const char* t, const char* m) {
  if (!mod) return -1;
  {
    void* f = (void*)GetProcAddress((HMODULE)mod, "mock_is_compiled");
    if (!f) return -2;
    return ((int32_t(*)(const char*, const char*))f)(t, m);
  }
}
static int32_t aowl_pb_uncompiled_count(void* mod) {
  void* f;
  if (!mod) return -1;
  f = (void*)GetProcAddress((HMODULE)mod, "mock_uncompiled_count");
  if (!f) return -2;
  return ((int32_t(*)(void))f)();
}
""".}

proc pbIsCompiled(m: Il2CppPtr; t, name: cstring): int32 {.
  importc: "aowl_pb_is_compiled", nodecl.}
proc pbUncompiledCount(m: Il2CppPtr): int32 {.
  importc: "aowl_pb_uncompiled_count", nodecl.}

proc cHookNew(): Il2CppPtr {.importc: "aowl_hook_new", nodecl.}
proc cHookFree(p: Il2CppPtr) {.importc: "aowl_hook_free", nodecl.}
proc cHookAttach(p, target: Il2CppPtr): int32 {.importc: "aowl_hook_attach", nodecl.}
proc cHookRemove(p: Il2CppPtr): int32 {.importc: "aowl_hook_remove", nodecl.}
proc cHookErrorText(rc: int32): Il2CppPtr {.importc: "aowl_hook_error_text", nodecl.}
proc cHookSetPostfix(slot: int32; on: int32) {.
  importc: "aowl_hook_set_postfix", nodecl.}

proc cFrameSlot(depth: int32): Il2CppPtr {.importc: "aowl_frame_slot", nodecl.}
proc cFrameArm(f, regs, kinds: Il2CppPtr; argc, retKind: int32;
               flags: uint32; self: uint64) {.importc: "aowl_frame_arm", nodecl.}
proc cFrameDisarm(f: Il2CppPtr) {.importc: "aowl_frame_disarm", nodecl.}
proc cFrameFlt(f: Il2CppPtr; i: int32; ok: pointer): float {.
  importc: "aowl_frame_flt", nodecl.}
proc cFrameRetFlt(f: Il2CppPtr; ok: pointer): float {.
  importc: "aowl_frame_ret_flt", nodecl.}
proc cFrameSetRetFlt(f: Il2CppPtr; v: float): int32 {.
  importc: "aowl_frame_set_ret_flt", nodecl.}

const
  ModeOff = 0'i32
  ModeJsonPrefix = 1'i32
  ModeTypedPrefix = 2'i32
  ModeJsonPostfix = 3'i32
  ModeJsonPostfixReplace = 4'i32
  ModeTypedPostfix = 5'i32
  ModeTypedPostfixReplace = 6'i32

var gMode = ModeOff
var gBenchRt = Il2Cpp(handle: cast[Il2CppPtr](0), loaded: false,
                      lastError: 0'i32, missing: @[])
var gBenchMethod: Il2CppMethod = cast[Il2CppMethod](0)
## `Ping` is static and takes one `System.Single`, so the shape is one byte and
## the return is a float. Built once here, exactly as `installPatch` builds it
## once at registration -- that is the optimisation, not an incidental detail.
var gBenchKinds: seq[uint8] = @[2'u8]   # AOWLSPT_ARG_FLOAT
var gBenchHandles: seq[Il2CppPtr] = @[]
var gBenchIsObj: seq[bool] = @[]
var gBenchGcs: seq[uint32] = @[]
var gBenchSink = 0.0
var gBenchFires = 0'i64

proc jsonRoundTrip(payload: string): float =
  ## What the mod side of a JSON firing does, and no more.
  ##
  ## The copy is not padding: `patchTrampoline` calls `toString` on the slice
  ## the host handed over, because a slice is borrowed and dies with the call.
  ## That is one allocation per firing on the mod's own heap, and it is the
  ## half of the JSON cost that does not show up in the host's profile at all.
  var mine = payload
  var i = 0
  var acc = 0.0
  while i < mine.len:
    let ch = mine[i]
    if ch >= '0' and ch <= '9':
      acc = acc + float(ord(ch) - ord('0'))
    inc i
  result = acc

proc benchFired(slot: int32; regs: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## The prefix dispatcher, in both flavours.
  gBenchFires = gBenchFires + 1'i64
  if gMode == ModeJsonPrefix:
    let text = describeArgs(gBenchRt, gBenchMethod, regs,
                            gBenchHandles, gBenchIsObj, gBenchGcs)
    gBenchSink = gBenchSink + jsonRoundTrip(text)
    return 0'i32
  if gMode == ModeTypedPrefix:
    let f = cFrameSlot(0'i32)
    cFrameArm(f, regs, cast[Il2CppPtr](addr gBenchKinds[0]), 1'i32,
              2'i32, 0x2'u32, 0'u64)
    var ok = 0'i32
    gBenchSink = gBenchSink + cFrameFlt(f, 0'i32, addr ok)
    cFrameDisarm(f)
    return 0'i32
  result = 0'i32

proc benchReturned(slot: int32; regs: Il2CppPtr): int32 {.
    exportc: "aowlspt_nim_patch_returned", cdecl.} =
  ## The postfix dispatcher, in three flavours: watch as JSON, watch and replace
  ## as JSON, and the typed pair.
  gBenchFires = gBenchFires + 1'i64
  if gMode == ModeJsonPostfix or gMode == ModeJsonPostfixReplace:
    let resultText = describeReturn(gBenchRt, gBenchMethod, regs,
                                    gBenchHandles, gBenchIsObj, gBenchGcs)
    let argsText = describeArgs(gBenchRt, gBenchMethod, regs,
                                gBenchHandles, gBenchIsObj, gBenchGcs)
    let payload = argsText.substr(0, argsText.len - 2) & ",\"result\":" &
                  resultText & "}"
    gBenchSink = gBenchSink + jsonRoundTrip(payload)
    if gMode == ModeJsonPostfixReplace:
      # And back: the mod formats a replacement as text, the host parses it and
      # writes it into the frame by the declared return type.
      let replacement = $(gBenchSink * 0.0 + 3.5)
      if not applyPatchReturn(gBenchRt, gBenchMethod, regs, replacement):
        return 0'i32
      return 1'i32
    return 0'i32
  if gMode == ModeTypedPostfix or gMode == ModeTypedPostfixReplace:
    let f = cFrameSlot(0'i32)
    cFrameArm(f, regs, cast[Il2CppPtr](addr gBenchKinds[0]), 1'i32,
              2'i32, 0x3'u32, 0'u64)   # STATIC | POSTFIX
    var ok = 0'i32
    let got = cFrameRetFlt(f, addr ok)
    gBenchSink = gBenchSink + got
    var st = 0'i32
    if gMode == ModeTypedPostfixReplace:
      if cFrameSetRetFlt(f, got * 2.0) != 0'i32:
        st = 1'i32
    cFrameDisarm(f)
    return st
  result = 0'i32

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

type
  Row = object
    name: string
    nsPerOp100: int64    ## nanoseconds x100, so the table has two decimals
    iters: int

var gRows: seq[Row] = @[]

proc pad(s: string; width: int): string =
  result = s
  while result.len < width:
    result.add ' '

proc padLeft(s: string; width: int): string =
  result = ""
  var n = width - s.len
  while n > 0:
    result.add ' '
    dec n
  result.add s

proc fixed2(v100: int64): string =
  ## A hundredths-of-a-nanosecond count as "12.34". Hand-rolled because the
  ## measurement is an integer count of ticks and formatting it through a float
  ## would introduce the only rounding in the whole path.
  let whole = v100 div 100'i64
  var frac = v100 mod 100'i64
  if frac < 0: frac = -frac
  var f = $frac
  if f.len < 2: f = "0" & f
  result = $whole & "." & f

proc record(name: string; iters: int; t0, t1: int64) =
  let total = nanosBetween(t0, t1)
  var per100 = 0'i64
  if iters > 0:
    per100 = (total * 100'i64) div int64(iters)
  gRows.add Row(name: name, nsPerOp100: per100, iters: iters)

proc printTable() =
  # The fastest row is the baseline, because "how many times slower is the
  # convenient path" is the number a mod author is deciding on.
  var best = 0'i64
  for r in gRows:
    if r.nsPerOp100 > 0'i64 and (best == 0'i64 or r.nsPerOp100 < best):
      best = r.nsPerOp100

  echo ""
  echo pad("operation", 52) & padLeft("ns/op", 12) & padLeft("x fastest", 12) &
       padLeft("iterations", 13)
  echo repeat("-", 89)
  for r in gRows:
    var ratio = ""
    if best > 0'i64:
      ratio = fixed2((r.nsPerOp100 * 100'i64) div best)
    echo pad(r.name, 52) & padLeft(fixed2(r.nsPerOp100), 12) &
         padLeft(ratio, 12) & padLeft($r.iters, 13)

# ---------------------------------------------------------------------------
# The bench
# ---------------------------------------------------------------------------

type
  Options = object
    dll: string
    iters: int
    help: bool
    badFlag: string

proc parseArgs(): Options =
  result = Options(dll: "tests\\mockil2cpp\\GameAssembly.dll",
                   iters: 2000000, help: false, badFlag: "")
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--iters":
      inc i
      if i <= n:
        var v = 0
        var ok = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            ok = true
          else:
            ok = false
            break
        if ok and v > 0: result.iters = v
    elif a == "--runtime":
      # Accepted because the gate passes it. It used to work only by accident:
      # `--runtime` fell through to the "unknown flag" case and was ignored,
      # and the path after it was picked up by the positional branch below --
      # so the right DLL was benchmarked for the wrong reason, and a typo in
      # the flag would have benchmarked the default silently.
      inc i
      if i <= n: result.dll = paramStr(i)
    elif a == "--help" or a == "-h":
      result.help = true
    elif a.startsWith("-"):
      # A flag nobody parses is a flag whose absence nobody notices. `--check`
      # was passed by the gate for a threshold this tool has never had.
      result.badFlag = a
    else:
      result.dll = a
    inc i

# A sink for every result the benchmarks produce. Without somewhere for the
# values to go, a compiler at -O2 is entitled to delete the loop body and the
# tool would report the cost of an empty loop with total confidence.
var gSinkF = 0.0
var gSinkI = 0'i64
var gSinkS = 0

proc main(): int =
  let opt = parseArgs()
  if opt.help:
    echo Usage
    return 0
  if opt.badFlag.len > 0:
    echo "perfbench: no such option " & opt.badFlag
    echo Usage
    return 2

  var rt = openIl2Cpp(opt.dll)
  if not rt.loaded:
    echo "error  could not load " & opt.dll & " (GetLastError " &
         $rt.lastError & ")"
    echo "       build it first: aowl test, or the mock's own build step"
    return 1
  let missing = rt.missingEssential()
  if missing.len > 0:
    echo "error  " & opt.dll & " is missing " & $missing.len &
         " essential entry points"
    return 1

  # The mock stays un-initialised until `il2cpp_init`, exactly as the real
  # runtime does, and `mock_wire` is what fills in every methodPointer.
  let domain = rt.init("perfbench")
  if domain == nil:
    echo "error  il2cpp_init returned no domain"
    return 1

  echo "perfbench -- " & opt.dll
  echo ""

  # --- the objects under test -------------------------------------------
  #
  # Reached the way a mod reaches them: a static singleton getter, then an
  # instance property off it.
  let worldCls = findClass(rt, "EFT.GameWorld")
  let playerCls = findClass(rt, "EFT.Player")
  if worldCls == nil or playerCls == nil:
    echo "error  the stand-in runtime does not have EFT.GameWorld/EFT.Player"
    return 1

  var exc: Il2CppException = nullPtr()
  let mInstance = findMethod(rt, worldCls, "get_Instance", 0)
  let world = invoke(rt, mInstance, nullPtr(), nullPtr(), exc)
  let mMainPlayer = findMethod(rt, worldCls, "get_MainPlayer", 0)
  let player = invoke(rt, mMainPlayer, world, nullPtr(), exc)
  if player == nil:
    echo "error  could not reach a player instance"
    return 1

  # --- bindings ----------------------------------------------------------

  let fbHealth = bindField(rt, "EFT.Player", "Health")
  let fbLevel = bindField(rt, "EFT.Player", "Level")
  echo "bind   " & fbHealth.why & "  (" & $fbHealth.bindNs & " ns)"
  echo "bind   " & fbLevel.why & "  (" & $fbLevel.bindNs & " ns)"
  if not fbHealth.ok:
    echo "error  the field binding failed; nothing below would mean anything"
    return 1

  # The method binding, inferred from the stand-in's own metadata. This proves
  # the inference: the signature below is read out of `il2cpp_method_get_param`
  # and `il2cpp_method_get_return_type`, not written here.
  #
  # It is deliberately **not called**. The mock's `methodPointer` is its generic
  # invoker rather than a compiled method with this signature, so calling it
  # through a typed trampoline would pass a `float` where a `void**` is read.
  # That is a gap in the stand-in, not in the binding -- see docs/PERF.md.
  let bDamage = bindMethod(rt, "EFT.Player", "Damage", 1)
  echo "bind   " & bDamage.why & "  (" & $bDamage.bindNs & " ns)"
  let bAdd = bindMethod(rt, "EFT.Player", "Add", 2)
  echo "bind   " & bAdd.why & "  (" & $bAdd.bindNs & " ns)"

  # The refusals, exercised rather than described. Each of these is a case
  # where a fallback would be a call with the arguments in the wrong registers.
  let bBad = bindMethod(rt, "EFT.Player", "Damage", 3)
  echo "refuse " & bBad.why
  let bDouble = bindMethodAs(rt, "EFT.Player", "Scale", [fkF64], fkF32)
  echo "refuse " & bDouble.why
  let bWide = bindMethodAs(rt, "EFT.Player", "Add",
                           [fkI32, fkI32, fkI32, fkI32, fkI32], fkI32)
  echo "refuse " & bWide.why
  let bNoType = bindMethod(rt, "EFT.Nowhere", "Whatever", 0)
  echo "refuse " & bNoType.why

  # --- the fixture bindings ---------------------------------------------
  #
  # Same shape a real binding produces, over `abi/aowlspt_fast.h`'s compiled
  # stand-ins. `methodPointer` is still read by offset out of the fixture's
  # MethodInfo and still checked for being in an executable page, so the whole
  # mechanism is on the measured path.
  let miDamage = benchMethod(0'i32)
  let miGetHealth = benchMethod(1'i32)
  let miAdd = benchMethod(2'i32)
  let miTick = benchMethod(3'i32)

  var fastDamage = Binding(ok: true, why: "", target: "fixture Damage",
                           fn: methodPointer(rt, miDamage), info: miDamage,
                           argc: 1'i32, slots: 2'i32, mask: 0b10'u32,
                           ret: fkF32, isStatic: false, bindNs: 0'i64)
  var fastHealth = Binding(ok: true, why: "", target: "fixture get_Health",
                           fn: methodPointer(rt, miGetHealth), info: miGetHealth,
                           argc: 0'i32, slots: 1'i32, mask: 0'u32,
                           ret: fkF32, isStatic: false, bindNs: 0'i64)
  var fastAdd = Binding(ok: true, why: "", target: "fixture Add",
                        fn: methodPointer(rt, miAdd), info: miAdd,
                        argc: 2'i32, slots: 2'i32, mask: 0'u32,
                        ret: fkI32, isStatic: true, bindNs: 0'i64)
  var fastTick = Binding(ok: true, why: "", target: "fixture Tick",
                         fn: methodPointer(rt, miTick), info: miTick,
                         argc: 0'i32, slots: 1'i32, mask: 0'u32,
                         ret: fkVoid, isStatic: false, bindNs: 0'i64)
  if fastDamage.fn == nil or fastAdd.fn == nil:
    echo "error  the fixture's methodPointer did not pass the code-page check"
    return 1

  # --- correctness before speed -----------------------------------------
  #
  # A benchmark of a path that returns the wrong answer is a benchmark of
  # nothing. The fast call writes the mock player's health field; the boxed
  # path reads it back through the runtime's own accessor. If the two agree,
  # the register classes and the field offset are both right.
  var a1 = argsF(2.5)
  let afterFast = callFloat(fastDamage, player, a1)
  let mGetHealth = findMethod(rt, playerCls, "get_Health", 0)
  let boxed = invoke(rt, mGetHealth, player, nullPtr(), exc)
  let boxedHealth = cReadF32(objectUnbox(rt, boxed))
  let direct = readFloat(fbHealth, player)
  echo ""
  echo "check  fast call left health at " & $afterFast &
       ", boxed get_Health reads " & $boxedHealth &
       ", direct field read " & $direct
  if afterFast != boxedHealth or direct != boxedHealth:
    echo "error  the three paths disagree; the numbers below are meaningless"
    return 1

  var a2 = argsII(2'i64, 40'i64)
  let sum = callInt32(fastAdd, nullPtr(), a2)
  echo "check  fast static call Add(2, 40) = " & $sum
  if sum != 42'i32:
    echo "error  a static fast call returned the wrong value"
    return 1

  # --- benchmarks --------------------------------------------------------

  let n = opt.iters
  # The boxed host path allocates a boxed return per call and the stand-in
  # never frees one, so it runs fewer iterations. Reported per-op either way.
  let nBoxed = (if n div 20 < 1000: 1000 else: n div 20)

  var t0 = 0'i64
  var t1 = 0'i64

  # 1. The boxed path, exactly as `AowlHostApi.call` runs it for a named type:
  #    resolve the type across every loaded assembly, find the method, parse
  #    the JSON arguments, box each one against its declared parameter type,
  #    invoke, and format the result back to JSON.
  var handles: seq[Il2CppPtr] = @[]
  var isObj: seq[bool] = @[]
  var gcs: seq[uint32] = @[]
  var err = ""
  t0 = perfCounter()
  for i in 0 ..< nBoxed:
    var values: seq[JsonValue] = @[]
    discard parseArgs("[2,40]", values, err)
    let cls = findClass(rt, "EFT.Player")
    let m = findMethod(rt, cls, "Add", 2)
    let args = cArgsNew(2'i32)
    discard bindArgs(rt, m, values, handles, args, err)
    var e2: Il2CppException = nullPtr()
    let res = invoke(rt, m, nullPtr(), cArgsPtr(args), e2)
    let text = describeResult(rt, m, res, handles, isObj, gcs)
    cArgsFree(args)
    gSinkS = gSinkS + text.len
  t1 = perfCounter()
  record("boxed call, type resolved by name (host `call`)", nBoxed, t0, t1)

  # 2. The same without the name resolution -- what `call` costs on a handle
  #    target, where the host already has the class.
  t0 = perfCounter()
  for i in 0 ..< nBoxed:
    var values: seq[JsonValue] = @[]
    discard parseArgs("[2,40]", values, err)
    let m = findMethod(rt, playerCls, "Add", 2)
    let args = cArgsNew(2'i32)
    discard bindArgs(rt, m, values, handles, args, err)
    var e2: Il2CppException = nullPtr()
    let res = invoke(rt, m, nullPtr(), cArgsPtr(args), e2)
    let text = describeResult(rt, m, res, handles, isObj, gcs)
    cArgsFree(args)
    gSinkS = gSinkS + text.len
  t1 = perfCounter()
  record("boxed call, class in hand (host `#n::` target)", nBoxed, t0, t1)

  # 3. The floor of the boxed path: everything pre-resolved, nothing but
  #    `il2cpp_runtime_invoke` and the unbox. No host does this -- it is here
  #    so the next row's gap is attributable to the dispatch rather than to
  #    the JSON around it.
  let mAdd = findMethod(rt, playerCls, "Add", 2)
  let argsFixed = cArgsNew(2'i32)
  cArgsSetI32(argsFixed, 0'i32, 2'i32)
  cArgsSetI32(argsFixed, 1'i32, 40'i32)
  t0 = perfCounter()
  for i in 0 ..< nBoxed:
    var e2: Il2CppException = nullPtr()
    let res = invoke(rt, mAdd, nullPtr(), cArgsPtr(argsFixed), e2)
    gSinkI = gSinkI + int64(cReadI32(objectUnbox(rt, res)))
  t1 = perfCounter()
  record("il2cpp_runtime_invoke alone, args prebuilt", nBoxed, t0, t1)

  # 4. The fast call, two integer arguments, static.
  t0 = perfCounter()
  for i in 0 ..< n:
    var aa = argsII(2'i64, 40'i64)
    gSinkI = gSinkI + int64(callInt32(fastAdd, nullPtr(), aa))
  t1 = perfCounter()
  record("fast call, static, 2 int args -> int", n, t0, t1)

  # 5. The fast call, one float argument, instance. The shape a per-frame mod
  #    actually has.
  t0 = perfCounter()
  for i in 0 ..< n:
    var aa = argsF(0.0)
    gSinkF = gSinkF + callFloat(fastDamage, player, aa)
  t1 = perfCounter()
  record("fast call, instance, 1 float arg -> float", n, t0, t1)

  # 6. The floor: an instance call with no arguments and no return.
  t0 = perfCounter()
  for i in 0 ..< n:
    var aa = noArgs()
    callVoid(fastTick, player, aa)
  t1 = perfCounter()
  record("fast call, instance, no args, void", n, t0, t1)
  gSinkI = gSinkI + int64(benchTicks())

  # 7. Reading one field the way a mod reads it today: a property getter
  #    through the boxed path.
  t0 = perfCounter()
  for i in 0 ..< nBoxed:
    var e2: Il2CppException = nullPtr()
    let res = invoke(rt, mGetHealth, player, nullPtr(), e2)
    gSinkF = gSinkF + cReadF32(objectUnbox(rt, res))
  t1 = perfCounter()
  record("field via property getter, boxed invoke", nBoxed, t0, t1)

  # 8. The same field through the host's `@Name` field path, which is what
  #    `GameObj.field` compiles to: find the FieldInfo, ask for its type's
  #    name, branch on the string, read into a scratch cell, format as JSON.
  t0 = perfCounter()
  for i in 0 ..< nBoxed:
    var e3 = ""
    let text = readField(rt, playerCls, player, "Health", handles, isObj, gcs, e3)
    gSinkS = gSinkS + text.len
  t1 = perfCounter()
  record("field via host `@Name` path (JSON out)", nBoxed, t0, t1)

  # 9. The bound field: one load.
  t0 = perfCounter()
  for i in 0 ..< n:
    gSinkF = gSinkF + readFloat(fbHealth, player)
  t1 = perfCounter()
  record("field via cached offset, direct load", n, t0, t1)

  # 10. The same load for an integer field, which goes through a different
  #     accessor. Here to show the two are the same cost -- if they ever
  #     diverge, something in the kind dispatch has stopped being folded.
  t0 = perfCounter()
  for i in 0 ..< n:
    gSinkI = gSinkI + int64(readInt32(fbLevel, player))
  t1 = perfCounter()
  record("field via cached offset, int32", n, t0, t1)

  # --- what a hook costs -------------------------------------------------
  #
  # Six rows on one method, so that the only variable is the payload. The
  # unpatched row is taken first and with the detour not yet installed, which
  # matters: a hook the engine has landed changes the first fourteen bytes of
  # the function, and measuring "unpatched" after removing one would be
  # measuring a restored function rather than an untouched one.
  gBenchRt = rt
  let pingMethod = findMethod(rt, playerCls, "Ping", 1)
  var bPing = bindMethod(rt, "EFT.Player", "Ping", 1)
  echo "bind   " & bPing.why & "  (" & $bPing.bindNs & " ns)"
  if pingMethod == nil or not bPing.ok:
    echo "error  no EFT.Player::Ping to hook; the patch rows are skipped"
  else:
    # And that it is a compiled body rather than the mock's invoker. Every row
    # below is a *bound* call into a *detoured* function, and both of those go
    # through `methodPointer`; on an invoker-only row they would time the
    # invoker and report six confident numbers about the wrong function.
    let compiled = pbIsCompiled(rt.handle, "EFT.Player", "Ping")
    if compiled == 0'i32:
      echo "error  EFT.Player::Ping has no compiled body in this runtime, so"
      echo "       every patch row below would be timing the invoker instead."
      return 1
    elif compiled == 1'i32:
      echo "check  EFT.Player::Ping is a compiled method (" &
           $int(pbUncompiledCount(rt.handle)) &
           " invoker-only rows in this runtime, none of them used here)"
    gBenchMethod = pingMethod
    let nHook = (if n div 100 < 20000: 20000 else: n div 100)

    var pa = argsF(1.0)
    for i in 0 ..< 2000:
      gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
    t0 = perfCounter()
    for i in 0 ..< nHook:
      gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
    t1 = perfCounter()
    record("bound call, unpatched", nHook, t0, t1)

    let pingFn = methodPointer(rt, pingMethod)
    let hook = cHookNew()
    let slot = cHookAttach(hook, pingFn)
    if slot < 0'i32:
      echo "error  could not detour EFT.Player::Ping: " &
           readCString(cHookErrorText(slot))
    else:
      # Prefix first: the engine's post table is off, so the thunk tail-jumps
      # into the trampoline and never comes back.
      cHookSetPostfix(slot, 0'i32)

      gMode = ModeJsonPrefix
      for i in 0 ..< 200:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t0 = perfCounter()
      for i in 0 ..< nHook:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t1 = perfCounter()
      record("prefix hook, JSON arguments", nHook, t0, t1)

      gMode = ModeTypedPrefix
      for i in 0 ..< 200:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t0 = perfCounter()
      for i in 0 ..< nHook:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t1 = perfCounter()
      record("prefix hook, typed frame", nHook, t0, t1)

      # And now the postfix path: the thunk calls the original and comes back,
      # which is the same detour and a different branch at the top of it.
      cHookSetPostfix(slot, 1'i32)

      gMode = ModeJsonPostfix
      for i in 0 ..< 200:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t0 = perfCounter()
      for i in 0 ..< nHook:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t1 = perfCounter()
      record("postfix hook, JSON result and arguments", nHook, t0, t1)

      gMode = ModeJsonPostfixReplace
      for i in 0 ..< 200:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t0 = perfCounter()
      for i in 0 ..< nHook:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t1 = perfCounter()
      record("postfix hook, JSON + replacement", nHook, t0, t1)

      gMode = ModeTypedPostfix
      for i in 0 ..< 200:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t0 = perfCounter()
      for i in 0 ..< nHook:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t1 = perfCounter()
      record("postfix hook, typed frame", nHook, t0, t1)

      gMode = ModeTypedPostfixReplace
      for i in 0 ..< 200:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t0 = perfCounter()
      for i in 0 ..< nHook:
        gSinkF = gSinkF + callFloat(bPing, nullPtr(), pa)
      t1 = perfCounter()
      record("postfix hook, typed frame + replacement", nHook, t0, t1)

      gMode = ModeOff
      cHookSetPostfix(slot, 0'i32)
      discard cHookRemove(hook)
      # Every row above ran through the detour, and this is how that is known
      # rather than assumed: six loops of `nHook` firings each, and a dispatcher
      # that was never reached would leave this at zero while every row still
      # reported a plausible number.
      echo ""
      # Six measured loops plus six warm-ups, all of them through the detour.
      let expected = int64(nHook + 200) * 6'i64
      echo "check  the hook fired " & $gBenchFires & " times across " &
           $expected & " patched calls"
      if gBenchFires < expected:
        echo "error  the detour did not fire on every patched call; the patch"
        echo "       rows above are measuring an unpatched function"
    cHookFree(hook)
    gSinkF = gSinkF + gBenchSink

  printTable()

  echo ""
  echo "sink " & $gSinkI & " " & $gSinkS & " " & $int(gSinkF) &
       "   (printed so the loops cannot be optimised away)"
  echo ""
  echo "This is tests/mockil2cpp, not Tarkov. It proves the mechanism -- the"
  echo "boxing, the dispatch, the offsets -- and not BSG's implementation of"
  echo "the same C API. See docs/PERF.md for what that leaves open."
  result = 0

discard main()
