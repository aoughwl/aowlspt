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
## Build (this does not go through `aowl build-tools`, which does not know
## about `-d:AOWLSPT_FAST_BENCH`):
##
##     nimony c --passC:-I<repo>/abi --passC:-DAOWLSPT_FAST_BENCH \
##       -p:<repo>/aowl/src -p:<repo>/host/Aowlspt.Host.Il2Cpp \
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

proc parseArgs(): Options =
  result = Options(dll: "tests\\mockil2cpp\\GameAssembly.dll",
                   iters: 2000000, help: false)
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
    elif a == "--help" or a == "-h":
      result.help = true
    elif not a.startsWith("-"):
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
