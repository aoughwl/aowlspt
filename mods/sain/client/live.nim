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
## **There is one thing that decision costs**, and it is worth stating plainly:
## a host `Handle` -- what `game.nim` and a `hookArgs` reference argument hand
## back -- is an *index into the host's table*, and the ABI has no entry point
## that turns one into the raw pointer the fast path needs. So the two worlds do
## not mix: anything read on the fast path has to be reached from a pointer this
## file obtained itself. The host path is still used for the two things it is
## better at -- the capability probe and the spawn hook -- both of which happen
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

proc openLive*(): bool =
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
    # Refusing here rather than at the first call: a runtime missing
    # `il2cpp_object_get_class` cannot do lazy binding at all, and finding that
    # out per bot per frame would be a log full of the same line.
    warn "sain: the IL2CPP runtime is missing " & $missing.len &
         " essential entry points; the fast path is unavailable"
    return false
  gLive = true
  result = true

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

proc initFloatReaders() =
  gF0 = FieldBinding(ok: true, why: "", target: "unboxed+0", offset: 0'i32,
                     kind: fkF32, bindNs: 0'i64)
  gF4 = FieldBinding(ok: true, why: "", target: "unboxed+4", offset: 4'i32,
                     kind: fkF32, bindNs: 0'i64)
  gF8 = FieldBinding(ok: true, why: "", target: "unboxed+8", offset: 8'i32,
                     kind: fkF32, bindNs: 0'i64)
  gI0 = FieldBinding(ok: true, why: "", target: "unboxed+0", offset: 0'i32,
                     kind: fkI32, bindNs: 0'i64)

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
  LazyCall* = object
    ## One member, resolved against the class of the object it is first used
    ## with, and re-resolved if that class changes.
    ##
    ## `b.ok` says the fast path took it. `m` is the `MethodInfo*` either way,
    ## so a member the fast path refuses -- a `Vector3` return, a value-type
    ## return, an enum argument -- is still reachable through
    ## `il2cpp_runtime_invoke`, which is a boxing call rather than a register
    ## call but is still nowhere near the host's 1235 ns. That is the split
    ## `docs/PERF.md` describes, made per member instead of per module.
    member*: string
    argc*: int32
    argcAlts*: seq[int32]   ## other arities to try; EFT overloads by arity
    kinds*: seq[FastKind]   ## empty => infer from the runtime's metadata
    ret*: FastKind          ## fkNone => infer
    cls*: Il2CppClass       ## the class this is currently bound against
    m*: Il2CppMethod
    b*: Binding
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
           b: emptyBinding(), tried: false, why: "")

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

proc buildBinding(owner, member: string; m: Il2CppMethod;
                  kinds: openArray[FastKind]; ret: FastKind): Binding =
  ## `fast.bindMethodAs` with the `findClass` step removed.
  ##
  ## It exists because `bindMethodAs` takes a type *name*, and the whole point
  ## of binding lazily is that the class is already in hand and its name is
  ## either unknown, unstable, or -- for a generic instantiation -- not a name
  ## the resolver would accept back. Every field of `Binding` is exported, so
  ## this is the public shape rather than a reach inside. What it has to get
  ## right is what `bindMethodAs` gets right: refuse a shape the generated
  ## trampolines do not cover, set the float mask against the *native* slot
  ## index (which is one higher on an instance method, because `this` is slot
  ## zero), and read staticness from the runtime rather than assuming it.
  result = emptyBinding()
  result.target = owner & "::" & member
  if kinds.len > MaxArgs:
    result.why = result.target & ": too many arguments for the fast path"
    return
  if ret == fkNone or ret == fkF64:
    result.why = result.target &
      ": the return type is not one the fast path classifies; using the " &
      "reflective path"
    return
  let fn = methodPointer(gRt, m)
  if fn == nil:
    result.why = result.target &
      ": MethodInfo.methodPointer is not a code address on this build"
    return
  result.isStatic = methodIsStatic(gRt, m)
  let base = (if result.isStatic: 0'i32 else: 1'i32)
  var mask = 0'u32
  for i in 0 ..< kinds.len:
    let k = kinds[i]
    if k == fkNone or k == fkVoid or k == fkF64:
      result.why = result.target & ": argument " & $i & " is " & describe(k) &
                   ", which the fast path does not pass"
      return
    if k == fkF32:
      mask = mask or (1'u32 shl uint32(int32(i) + base))
  result.fn = fn
  result.info = m
  result.argc = int32(kinds.len)
  result.slots = int32(kinds.len) + base
  result.mask = mask
  result.ret = ret
  result.ok = true
  result.why = result.target & ": " &
    (if result.isStatic: "static" else: "instance") & ", " &
    $kinds.len & " arg(s), returns " & describe(ret)

proc findOn(cls: Il2CppClass; member: string; argc: int32;
            alts: seq[int32]; usedArgc: var int32): Il2CppMethod =
  ## Look a member up on a class, then on each of its ancestors.
  ##
  ## `il2cpp_class_get_method_from_name` does not walk the base chain, and half
  ## of what SAIN reads on a bot is declared on `Player` and reached through a
  ## subclass instance -- so without this every lazy binding against a real bot
  ## would refuse and the mod would run entirely on defaults.
  usedArgc = argc
  var c = cls
  while c != nil:
    var m = findMethod(gRt, c, member, int(argc))
    if m != nil:
      return m
    var i = 0
    while i < alts.len:
      m = findMethod(gRt, c, member, int(alts[i]))
      if m != nil:
        usedArgc = alts[i]
        return m
      inc i
    c = classParent(gRt, c)
  result = cast[Il2CppMethod](0)

proc resolveOn(l: var LazyCall; cls: Il2CppClass) =
  ## Find the member on this class and try to put it on the fast path.
  l.cls = cls
  l.tried = true
  l.m = cast[Il2CppMethod](0)
  l.b = emptyBinding()
  let owner = fullName(gRt, cls)

  var usedArgc = l.argc
  let found = findOn(cls, l.member, l.argc, l.argcAlts, usedArgc)
  if found == nil:
    l.why = owner & "::" & l.member & ": no such member on this class or any " &
            "of its ancestors"
    return
  l.m = found
  l.argc = usedArgc

  # The signature: stated if the caller stated it, inferred otherwise.
  var kinds: seq[FastKind] = @[]
  var rk = l.ret
  if l.kinds.len > 0:
    for i in 0 ..< l.kinds.len:
      kinds.add l.kinds[i]
  else:
    var bad = false
    for i in 0 ..< int(usedArgc):
      let tn = typeName(gRt, methodParam(gRt, found, i))
      let k = classifyType(gRt, tn)
      if k == fkNone:
        bad = true
        break
      kinds.add k
    if bad:
      l.why = owner & "::" & l.member &
              ": an argument type the fast path will not classify " &
              "(a Vector3, an enum or a generic); using il2cpp_runtime_invoke"
      return
  if rk == fkNone:
    rk = classifyType(gRt, typeName(gRt, methodReturnType(gRt, found)))
  if rk == fkNone:
    l.why = owner & "::" & l.member &
            ": returns a type the fast path will not classify (a Vector3 or " &
            "another value type wider than eight bytes); using " &
            "il2cpp_runtime_invoke"
    return

  l.b = buildBinding(owner, l.member, found, kinds, rk)
  l.why = l.b.why

proc ensure*(l: var LazyCall; obj: Il2CppPtr): bool =
  ## True when the member is callable on this object, by one path or the other.
  ##
  ## The class comparison is the whole per-call overhead of binding lazily: one
  ## `il2cpp_object_get_class` and one pointer compare.
  if obj == nil or not gLive:
    return false
  let c = objectClass(gRt, obj)
  if c == nil:
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
  result = unboxInt(r) != 0

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
  ## **One of the two places the fast path refuses**, exactly as `docs/PERF.md`
  ## says it does. Win64 returns a 12-byte struct through a hidden pointer
  ## argument, which is a different *call shape* rather than a different
  ## register class, and `aowlspt/fast` covers register classes. So this is
  ## `il2cpp_runtime_invoke`, which boxes the result: one managed allocation
  ## per read, and the only per-frame allocation this mod makes.
  ##
  ## It is still far cheaper than what it replaces. The host's boxed path for
  ## the same read was ~1235 ns of name lookup, JSON and ABI crossing, after
  ## which the mod parsed the three numbers back out of the text.
  result = zeroVec()
  if not ensure(l, obj):
    return
  let r = reflect(l.m, obj, cast[Il2CppPtr](0))
  result = unboxVec3(r)

proc callVec*(l: var LazyCall; obj: Il2CppPtr; p: Vec3; flag: bool): bool =
  ## A method whose first argument is a `Vector3` -- `Mover.GoToPoint`,
  ## `Steering.LookToPoint`.
  ##
  ## The other refusal, and the one `abi/aowlspt_fast.h` calls out by name.
  ## Reflective, and the marshalling is the convention IL2CPP shares with Mono:
  ## a `void**` in which a value-type slot points at the raw value and a
  ## reference slot *is* the pointer. `xyz` is a local and stays alive across
  ## the call, which is the whole requirement.
  ##
  ## Arguments past the first are filled with neutral values: `false` for a
  ## bool that is not the one flag the caller cares about, `-1` for a float
  ## (EFT's own "no preference" for a reach distance), `0` for an integer.
  ## Guessing a *meaningful* default would be worse than this -- these are the
  ## values that make a long overload behave like its shortest form.
  if not ensure(l, obj):
    return false
  var xyz: array[3, float32] = [float32(p.x), float32(p.y), float32(p.z)]
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
  let c = objectClass(gRt, boxed)
  if c == nil:
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
    pPosition*: LazyCall         ## Vector3 -> reflective
    pLookDir*: LazyCall          ## Vector3 -> reflective

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

    # BotOwner components
    boMemory*: LazyCall
    boWeapon*: LazyCall
    boMover*: LazyCall
    boSteering*: LazyCall
    boShoot*: LazyCall
    boMedecine*: LazyCall

    # The bot's memory
    memUnderFire*: LazyCall
    memGoalEnemy*: LazyCall

    # The enemy record the game keeps
    enPerson*: LazyCall
    enVisible*: LazyCall
    enCanShoot*: LazyCall
    enPosition*: LazyCall        ## Vector3 -> reflective

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
    mvGoTo*: LazyCall            ## Vector3 argument -> reflective
    mvSprint*: LazyCall          ## one bool -> fast
    mvStop*: LazyCall
    stLookTo*: LazyCall          ## Vector3 argument -> reflective
    sdShoot*: LazyCall

var gB*: SainBindings

proc bindAll*() =
  ## Fill the table. Called once, from the first tick on which the runtime is
  ## up -- never from `onLoad`, where the game's assemblies do not exist and
  ## every binding would correctly refuse.
  if gB.ready:
    return
  initFloatReaders()

  # The two static entry points. `EFT.GameWorld::get_Instance` is the shape
  # every EFT manager uses. On a build where the singleton lives on
  # `Comfort.Common.Singleton<GameWorld>` instead, this refuses and says so:
  # that type is a generic instantiation and `findClass` cannot name it, which
  # is a real gap rather than something to paper over. The reflective fallback
  # below covers the case where the method exists but its signature does not
  # classify.
  gB.worldInstance = bindMethodAs(gRt, "EFT.GameWorld", "get_Instance",
                                  [], fkPtr)
  gB.worldWhy = gB.worldInstance.why
  gB.worldMethod = gB.worldInstance.info
  if not gB.worldInstance.ok:
    let c = findClass(gRt, "EFT.GameWorld")
    if c != nil:
      gB.worldMethod = findMethod(gRt, c, "get_Instance", 0)

  gB.worldAlive = bindMethodAs(gRt, "EFT.GameWorld", "get_AllAlivePlayersList",
                               [], fkPtr)
  gB.aliveWhy = gB.worldAlive.why
  gB.aliveMethod = gB.worldAlive.info
  if not gB.worldAlive.ok:
    let c = findClass(gRt, "EFT.GameWorld")
    if c != nil:
      gB.aliveMethod = findMethod(gRt, c, "get_AllAlivePlayersList", 0)

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

  gB.boMemory = lazy("get_Memory")
  gB.boWeapon = lazy("get_WeaponManager")
  gB.boMover = lazy("get_Mover")
  gB.boSteering = lazy("get_Steering")
  gB.boShoot = lazy("get_ShootData")
  gB.boMedecine = lazy("get_Medecine")

  gB.memUnderFire = lazy("get_IsUnderFire")
  gB.memGoalEnemy = lazy("get_GoalEnemy")

  gB.enPerson = lazy("get_Person")
  gB.enVisible = lazy("get_IsVisible")
  gB.enCanShoot = lazy("get_CanShoot")
  gB.enPosition = lazy("get_CurrPosition")

  gB.wmHaveBullets = lazy("get_HaveBullets")
  gB.wmReady = lazy("get_IsReady")
  gB.wmReload = lazy("get_Reload")
  gB.rlTryReload = lazy("TryReload")
  gB.rlBullets = lazy("get_BulletCount")
  gB.rlMaxBullets = lazy("get_MaxBulletCount")

  gB.medFirstAid = lazy("get_FirstAid")
  gB.medStims = lazy("get_Stimulators")
  gB.medSurgery = lazy("get_SurgicalKit")
  gB.faHave = lazy("get_HaveSmth2Use")
  gB.stimHave = lazy("get_HaveSmth2Use")
  gB.surgHave = lazy("get_HaveWork")
  gB.faApply = lazy("TryApplyToCurrentPart")
  gB.stimApply = lazy("TryApply")
  gB.surgApply = lazy("TryApplyToCurrentPart")

  # `GoToPoint` is overloaded by arity across client versions -- one argument in
  # the shortest form, five or six in the fullest. Trying arities in order of
  # preference is cheaper and more durable than pinning one, and it happens
  # once per class rather than per call.
  gB.mvGoTo = lazy("GoToPoint", 1'i32)
  gB.mvGoTo.argcAlts = @[2'i32, 3'i32, 4'i32, 5'i32, 6'i32]
  gB.mvSprint = lazyAs("Sprint", [fkBool], fkVoid)
  gB.mvStop = lazy("Stop")
  gB.stLookTo = lazy("LookToPoint", 1'i32)
  gB.stLookTo.argcAlts = @[2'i32]
  gB.sdShoot = lazy("Shoot")

  gB.ready = true

proc reportOne(name: string; l: LazyCall) =
  if l.b.ok:
    info "sain:   fast    " & name & " -- " & l.b.why
  elif l.m != nil:
    info "sain:   boxed   " & name & " -- " & l.why
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

# ---------------------------------------------------------------------------
# The world
# ---------------------------------------------------------------------------

proc worldObject*(): Il2CppPtr =
  ## `GameWorld.Instance`, or null between raids -- which is an ordinary answer
  ## rather than a failure.
  result = cast[Il2CppPtr](0)
  if not gLive or not gB.ready:
    return
  if gB.worldInstance.ok:
    var a = noArgs()
    return callPtr(gB.worldInstance, cast[Il2CppPtr](0), a)
  if gB.worldMethod == nil:
    return
  result = reflect(gB.worldMethod, cast[Il2CppPtr](0), cast[Il2CppPtr](0))

proc alivePlayers*(world: Il2CppPtr): Il2CppPtr =
  result = cast[Il2CppPtr](0)
  if world == nil:
    return
  if gB.worldAlive.ok:
    var a = noArgs()
    return callPtr(gB.worldAlive, world, a)
  if gB.aliveMethod == nil:
    return
  result = reflect(gB.aliveMethod, world, cast[Il2CppPtr](0))

proc listLen*(list: Il2CppPtr): int =
  result = 0
  if list == nil:
    return
  result = callIntOn(gB.listCount, list, 0)

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
