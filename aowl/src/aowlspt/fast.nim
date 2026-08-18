## The fast path: calling the game without going through `il2cpp_runtime_invoke`.
##
## `aowlspt/game` is the comfortable API. It reaches the game the way the ABI
## does: a target string, a JSON argument list, a name lookup, a box per
## argument, `il2cpp_runtime_invoke`, and a boxed return parsed back out of
## JSON. That is the right shape for a mod that calls into the game when
## something happens, and the wrong shape for one that calls into it on every
## frame for every entity.
##
## This module is the other shape. A mod **binds** a method or a field once --
## at load, or the first frame the game exists -- and gets back a small object
## it can call through every frame:
##
##     var health: FieldBinding
##     var damage: Binding
##
##     proc onUpdate(elapsedMs: int64): Status =
##       if not health.ok:
##         health = bindField(rt, "EFT.Player", "Health")
##         damage = bindMethod(rt, "EFT.Player", "Damage", 1)
##         if not damage.ok:
##           warn damage.why
##       let hp = readFloat(health, player)   # a load
##       discard callFloat(damage, player, argsF(1.0))  # a call
##
## **What is actually removed.** A bound call is: pack the arguments into a
## five-slot buffer, one switch on a byte, one indirect call to the compiled
## method. No name lookup, no allocation, no boxing, no JSON, no crossing the
## host ABI at all. A bound field read is a load from `object + offset`.
##
## **Why a mod can do this without the host.** `openIl2Cpp()` binds the already
## loaded `GameAssembly.dll` by `GetModuleHandleW`, and a mod DLL is in the same
## process as the host. So a mod holds its own `Il2Cpp` and talks to the runtime
## directly; the host is not on the path and its handle table, its target-string
## parser and its JSON are all skipped. The host is still what got the mod
## loaded, what attached the calling thread, and what a mod should use for
## everything that is not hot.
##
## **Three rules that are not negotiable.**
##
## 1. *Bind inside a proc, never as a global initialiser.* In a nimony
##    `--app:lib` build a global initialised by a *call* is silently left
##    zeroed -- the same trap `gameType` is a template to avoid. `var b =
##    bindMethod(...)` at module scope produces a zeroed `Binding`, whose `ok`
##    is false, so it fails safe; but it never becomes true either. Declare the
##    global bare and assign to it from `onLoad`/`onUpdate`.
##
## 2. *A bound call takes a raw object pointer, not a `Handle`.* Handles exist
##    because the collector moves objects; a pointer held across two frames is a
##    use-after-free waiting for its moment. The fast path cannot afford to
##    dereference a GC handle per call, so the caller owns that problem: get the
##    pointer once per frame from a handle you hold, or from a `patch` that
##    handed you `this`, and do not keep it.
##
## 3. *A binding refuses rather than approximating.* Every signature this cannot
##    express -- a `double` argument, a `Vector3`, a fifth argument, a type the
##    runtime will not classify -- comes back with `ok = false` and a `why` that
##    names it. A call through a wrongly classified signature does not crash: it
##    reads a float out of a general-purpose register and hands the game a
##    number, which is the worst failure mode available.
##
## The C side is `abi/aowlspt_fast.h`, which explains how 189 generated cases
## cover every signature this accepts and why the ones it rejects are rejected.
## Compile with `--passC:-I<repo>/abi`.

import aowlspt/il2cpp

{.emit: """#include "aowlspt_fast.h" """.}

# ---------------------------------------------------------------------------
# The C side
# ---------------------------------------------------------------------------

proc cSetG(a: Il2CppPtr; i: int32; v: int64) {.importc: "aowl_fast_set_g", nodecl.}
proc cSetP(a: Il2CppPtr; i: int32; v: Il2CppPtr) {.importc: "aowl_fast_set_p", nodecl.}
proc cSetF(a: Il2CppPtr; i: int32; v: float) {.importc: "aowl_fast_set_f", nodecl.}

proc cFastG(fn, mi: Il2CppPtr; n: int32; mask: uint32; a: Il2CppPtr): int64 {.
  importc: "aowl_fast_g", nodecl.}
proc cFastF(fn, mi: Il2CppPtr; n: int32; mask: uint32; a: Il2CppPtr): float {.
  importc: "aowl_fast_f", nodecl.}
proc cFastD(fn, mi: Il2CppPtr; n: int32; mask: uint32; a: Il2CppPtr): float {.
  importc: "aowl_fast_d", nodecl.}

proc cFldI32(o: Il2CppPtr; off: int32): int32 {.importc: "aowl_fld_i32", nodecl.}
proc cFldI64(o: Il2CppPtr; off: int32): int64 {.importc: "aowl_fld_i64", nodecl.}
proc cFldF32(o: Il2CppPtr; off: int32): float {.importc: "aowl_fld_f32", nodecl.}
proc cFldF64(o: Il2CppPtr; off: int32): float {.importc: "aowl_fld_f64", nodecl.}
proc cFldU8(o: Il2CppPtr; off: int32): int32 {.importc: "aowl_fld_u8", nodecl.}
proc cFldPtr(o: Il2CppPtr; off: int32): Il2CppPtr {.importc: "aowl_fld_ptr", nodecl.}

proc cFldSetI32(o: Il2CppPtr; off: int32; v: int32) {.importc: "aowl_fld_set_i32", nodecl.}
proc cFldSetI64(o: Il2CppPtr; off: int32; v: int64) {.importc: "aowl_fld_set_i64", nodecl.}
proc cFldSetF32(o: Il2CppPtr; off: int32; v: float) {.importc: "aowl_fld_set_f32", nodecl.}
proc cFldSetF64(o: Il2CppPtr; off: int32; v: float) {.importc: "aowl_fld_set_f64", nodecl.}
proc cFldSetU8(o: Il2CppPtr; off: int32; v: int32) {.importc: "aowl_fld_set_u8", nodecl.}
proc cFldSetPtr(o: Il2CppPtr; off: int32; v: Il2CppPtr) {.importc: "aowl_fld_set_ptr", nodecl.}

# The clock, wrapped rather than exported raw.
#
# `importc ... nodecl` only works in a translation unit that has the header, and
# the `{.emit.}` above is scoped to *this* module -- so an importing mod calling
# `perfCounter` directly got an implicit-declaration error from the C compiler
# rather than anything a nimony error message would explain. Two mods hit that
# and fell back to the host's millisecond clock, which is the wrong resolution
# for measuring a hot loop.
#
# The wrappers below are ordinary nimony procs. They are in this module, so they
# have the header; an importer calls them, not the C.
proc cPerfCounter(): int64 {.importc: "aowl_perf_counter", nodecl.}
proc cPerfFreq(): int64 {.importc: "aowl_perf_freq", nodecl.}

proc perfCounter*(): int64 =
  ## QueryPerformanceCounter. Exposed because a mod measuring its own hot loop
  ## wants the same clock the bindings report their cost on.
  result = cPerfCounter()

proc perfFreq*(): int64 = cPerfFreq()

proc nanosBetween*(startTicks, endTicks: int64): int64 =
  ## Ticks to nanoseconds. Multiplies before dividing, because the frequency is
  ## around 10 MHz and dividing first turns every measurement under a
  ## microsecond into zero.
  let f = perfFreq()
  if f <= 0: return 0
  result = ((endTicks - startTicks) * 1000000000'i64) div f

# ---------------------------------------------------------------------------
# Kinds
# ---------------------------------------------------------------------------

type
  FastKind* = enum
    ## The register class of one slot, which is all Win64 cares about.
    ##
    ## `fkPtr` is every reference type -- a string, an object, an array. They
    ## are indistinguishable to the call: one general-purpose register holding
    ## an address. `fkNone` is "this module will not classify it", which is a
    ## refusal rather than a kind.
    fkNone, fkVoid, fkBool, fkI32, fkI64, fkF32, fkF64, fkPtr

proc describe*(k: FastKind): string =
  case k
  of fkNone: result = "unclassifiable"
  of fkVoid: result = "void"
  of fkBool: result = "a bool"
  of fkI32: result = "a 32-bit integer"
  of fkI64: result = "a 64-bit integer"
  of fkF32: result = "a float"
  of fkF64: result = "a double"
  of fkPtr: result = "a reference"

proc primitiveKind(t: string): FastKind =
  ## The kinds decidable from the type name alone.
  ##
  ## `System.Char` is here as `fkI32` because C# `char` is 16-bit and passes in
  ## a general register like every other small integer; the callee reads the
  ## width it declared.
  if t == "System.Void": result = fkVoid
  elif t == "System.Boolean": result = fkBool
  elif t == "System.Single": result = fkF32
  elif t == "System.Double": result = fkF64
  elif t == "System.SByte" or t == "System.Byte" or
       t == "System.Int16" or t == "System.UInt16" or
       t == "System.Int32" or t == "System.UInt32" or
       t == "System.Char": result = fkI32
  elif t == "System.Int64" or t == "System.UInt64" or
       t == "System.IntPtr" or t == "System.UIntPtr": result = fkI64
  elif t == "System.String" or t == "System.Object": result = fkPtr
  else: result = fkNone

proc classifyType*(rt: Il2Cpp; t: string): FastKind =
  ## A parameter or return type, as a register class.
  ##
  ## Anything not a primitive has to be decided by asking the runtime whether
  ## it is a value type, because that is the whole question: a reference is one
  ## register holding an address, and a value type of any size above eight
  ## bytes is passed by a hidden pointer, which is a different call shape
  ## entirely rather than a different register.
  ##
  ## The lookup is by qualified name through `findClass`, which is what this
  ## module has -- there is no `il2cpp_class_from_il2cpp_type` in the binding
  ## yet (see docs/PERF.md). So a generic instantiation, an array type or a
  ## nested type whose name `findClass` cannot resolve comes back `fkNone` and
  ## the binding is refused. Conservative in the one direction that matters:
  ## the failure is "you must classify this yourself", not a call with the
  ## arguments in the wrong registers.
  result = primitiveKind(t)
  if result != fkNone:
    return
  if t.len == 0:
    return fkNone
  let c = findClass(rt, t)
  if c == nil:
    return fkNone
  if classIsValueType(rt, c):
    # An enum lands here too. It does pass as its underlying integer, but
    # nothing in the C API says which one, and guessing `Int32` is wrong for
    # the `long` enums that do exist. `bindMethodAs` is the way to say so.
    return fkNone
  result = fkPtr

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

const MaxArgs* = 4

const MaxSlots* = 5
  ## Native register slots a call can use: `this` plus four arguments, which is
  ## what Win64 passes before it starts using the stack. A shaped call counts
  ## its own slots against this, including a hidden struct-return pointer.
  ## Four declared arguments plus `this` is five slots, which is exactly the
  ## four general-purpose and four SSE registers Win64 passes arguments in
  ## before it starts using the stack. Past that the shape count doubles per
  ## slot and the call stops being free anyway.

type
  Args* = object
    ## The argument buffer for one call.
    ##
    ## Slot 0 is reserved for `this` and filled at call time, so a static and an
    ## instance call use the same buffer with a different base -- which is why
    ## `n` counts the *declared* arguments and the slots start at index 1.
    ##
    ## Declared as `uint64` for the alignment and never read or written from
    ## nimony: every access goes through the union in `aowlspt_fast.h`. Reading
    ## a float out of storage declared as an integer is precisely the aliasing
    ## case a compiler may reorder.
    n*: int32
    mask*: uint32       ## bit i set => declared argument i is a float
    slots*: array[5, uint64]

proc noArgs*(): Args =
  result = Args(n: 0, mask: 0'u32, slots: [0'u64, 0'u64, 0'u64, 0'u64, 0'u64])

proc reset*(a: var Args) =
  a.n = 0
  a.mask = 0'u32

proc addInt*(a: var Args; v: int64) =
  ## Every integer, every bool and every enum: one general-purpose register.
  if a.n >= int32(MaxArgs): return
  cSetG(cast[Il2CppPtr](addr a.slots[0]), a.n + 1'i32, v)
  a.n = a.n + 1'i32

proc addBool*(a: var Args; v: bool) =
  addInt(a, (if v: 1'i64 else: 0'i64))

proc addFloat*(a: var Args; v: float) =
  ## A C# `float`. Narrowed to 32 bits in C, where the slot's type is known.
  if a.n >= int32(MaxArgs): return
  cSetF(cast[Il2CppPtr](addr a.slots[0]), a.n + 1'i32, v)
  a.mask = a.mask or (1'u32 shl uint32(a.n))
  a.n = a.n + 1'i32

proc addPtr*(a: var Args; v: Il2CppPtr) =
  ## A reference: an object, a string, an array. The pointer itself, not a
  ## pointer to it -- that difference is the whole reason the boxed path takes
  ## a `void**` and gets it wrong when a caller guesses.
  if a.n >= int32(MaxArgs): return
  cSetP(cast[Il2CppPtr](addr a.slots[0]), a.n + 1'i32, v)
  a.n = a.n + 1'i32

# Constructors for the common arities, so a call site is one expression.
proc argsI*(a: int64): Args =
  result = noArgs()
  addInt(result, a)
proc argsF*(a: float): Args =
  result = noArgs()
  addFloat(result, a)
proc argsP*(a: Il2CppPtr): Args =
  result = noArgs()
  addPtr(result, a)
proc argsII*(a, b: int64): Args =
  result = noArgs()
  addInt(result, a)
  addInt(result, b)
proc argsFF*(a, b: float): Args =
  result = noArgs()
  addFloat(result, a)
  addFloat(result, b)

# ---------------------------------------------------------------------------
# Method bindings
# ---------------------------------------------------------------------------

type
  Binding* = object
    ## A method, resolved down to a function pointer and a signature code.
    ##
    ## `why` is filled on failure *and* on success: on success it says what the
    ## binding is, which is what a mod wants in its log the one time it runs.
    ok*: bool
    why*: string
    target*: string          ## "EFT.Player::Damage", for messages
    fn*: Il2CppPtr           ## MethodInfo.methodPointer, the compiled function
    info*: Il2CppMethod      ## the MethodInfo*, passed as the trailing argument
    argc*: int32
    slots*: int32            ## argc, plus one if this is an instance method
    mask*: uint32            ## bit i set => native slot i is a float
    ret*: FastKind
    isStatic*: bool
    bindNs*: int64           ## what the binding cost, in nanoseconds

proc noBinding(target, why: string): Binding =
  result = Binding(ok: false, why: why, target: target,
                   fn: cast[Il2CppPtr](0), info: cast[Il2CppPtr](0),
                   argc: 0'i32, slots: 0'i32, mask: 0'u32, ret: fkNone,
                   isStatic: false, bindNs: 0'i64)

proc bindInClass*(rt: Il2Cpp; cls: Il2CppClass; owner, member: string;
                  argKinds: openArray[FastKind]; ret: FastKind): Binding

proc bindMethodAs*(rt: Il2Cpp; owner, member: string;
                   argKinds: openArray[FastKind]; ret: FastKind): Binding =
  ## Binds a method with the signature stated rather than inferred.
  ##
  ## The escape hatch for everything `classifyType` refuses: an enum parameter,
  ## a generic instantiation, an array. The mod is asserting the register
  ## classes, and it is on the mod to be right -- which is why the inferring
  ## version exists and this one is the exception.
  let t0 = perfCounter()
  result = noBinding(owner & "::" & member, "")

  if argKinds.len > MaxArgs:
    result.why = result.target & ": " & $argKinds.len &
                 " arguments; the fast path passes at most " & $MaxArgs &
                 " before Win64 starts using the stack"
    return
  if ret == fkNone:
    result.why = result.target & ": the return type was not classified"
    return

  let cls = findClass(rt, owner)
  if cls == nil:
    result.why = "no such type: " & owner &
                 " (the game's assemblies may not be loaded yet)"
    return
  result = bindInClass(rt, cls, owner, member, argKinds, ret)
  result.bindNs = nanosBetween(t0, perfCounter())

proc bindInClass*(rt: Il2Cpp; cls: Il2CppClass; owner, member: string;
                  argKinds: openArray[FastKind]; ret: FastKind): Binding =
  ## The same, against a class already in hand.
  ##
  ## Two things need this and neither can use the by-name form. Binding against
  ## **the object's own class** rather than the one the mod named is the
  ## difference between calling a subclass's override and silently calling the
  ## base implementation -- a bound call is non-virtual by construction, so a
  ## binding taken against `EFT.Player` by name calls `EFT.Player`'s body even
  ## on a bot subclass that overrides it. And a generic instantiation such as
  ## `List<Player>` has no name `findClass` accepts, but every instance of one
  ## can hand over its class.
  ##
  ## `owner` here is only used for the messages, so a caller with a class and no
  ## good name may pass whatever reads best in a log.
  let t0 = perfCounter()
  result = noBinding(owner & "::" & member, "")
  if argKinds.len > MaxArgs:
    result.why = result.target & ": " & $argKinds.len &
                 " arguments; the fast path passes at most " & $MaxArgs &
                 " before Win64 starts using the stack"
    return
  if ret == fkNone:
    result.why = result.target & ": the return type was not classified"
    return
  if cls == nil:
    result.why = result.target & ": no class was given"
    return
  let m = findMethod(rt, cls, member, argKinds.len)
  if m == nil:
    result.why = "no method " & result.target & " taking " & $argKinds.len &
                 " argument(s)"
    return

  # The compiled function. `methodPointer` reads `MethodInfo`'s first field and
  # refuses anything that is not in an executable page, so a Unity version that
  # moved the field fails here rather than calling into the middle of a struct.
  let fn = methodPointer(rt, m)
  if fn == nil:
    result.why = result.target &
      ": MethodInfo.methodPointer is not a code address on this build. " &
      "The layout assumption behind the fast path does not hold here; " &
      "use the boxed path."
    return

  result.isStatic = methodIsStatic(rt, m)
  let base = (if result.isStatic: 0'i32 else: 1'i32)
  var mask = 0'u32
  for i in 0 ..< argKinds.len:
    let k = argKinds[i]
    if k == fkNone or k == fkVoid:
      result.why = result.target & ": argument " & $i & " is " & describe(k)
      return
    if k == fkF64:
      # A double and a float both arrive in XMM and the callee reads different
      # widths out of it, so they are not interchangeable -- and a third slot
      # kind would take the generated table from 63 shapes to 364.
      result.why = result.target & ": argument " & $i &
        " is a double, which the fast path does not pass (see abi/aowlspt_fast.h)"
      return
    if k == fkF32:
      mask = mask or (1'u32 shl uint32(int32(i) + base))

  result.fn = fn
  result.info = m
  result.argc = int32(argKinds.len)
  result.slots = int32(argKinds.len) + base
  result.mask = mask
  result.ret = ret
  result.ok = true
  result.bindNs = nanosBetween(t0, perfCounter())
  result.why = result.target & ": " &
    (if result.isStatic: "static" else: "instance") & ", " &
    $argKinds.len & " arg(s), returns " & describe(ret)

proc bindOnObject*(rt: Il2Cpp; obj: Il2CppPtr; member: string;
                   argKinds: openArray[FastKind]; ret: FastKind): Binding =
  ## Binds against the class of a live object, walking its base chain.
  ##
  ## This is what a mod holding an instance actually wants: the object knows its
  ## own type, including the subclass the game handed it, and including generic
  ## instantiations that cannot be named.
  if obj == nil:
    return noBinding("::" & member, "no object to bind against")
  var cls = objectClass(rt, obj)
  var name = fullName(rt, cls)
  while cls != nil:
    let b = bindInClass(rt, cls, name, member, argKinds, ret)
    if b.ok:
      return b
    cls = classParent(rt, cls)
    if cls != nil:
      name = fullName(rt, cls)
  result = noBinding(name & "::" & member,
                     "no method " & member & "/" & $argKinds.len &
                     " on that object or any of its base classes")

proc bindMethod*(rt: Il2Cpp; owner, member: string; argc: int): Binding =
  ## Binds a method, inferring the signature from the runtime's own metadata.
  ##
  ## This is the one to use. `argc` is needed because IL2CPP looks a method up
  ## by name *and* arity -- an overload set has no other discriminator here.
  ##
  ## Everything about the signature comes from `il2cpp_method_get_param` and
  ## `il2cpp_method_get_return_type`, so the register classes are the runtime's
  ## answer rather than the mod author's memory of the C#. A type it will not
  ## classify refuses the binding; `bindMethodAs` is the way past that.
  let t0 = perfCounter()
  result = noBinding(owner & "::" & member, "")
  if argc < 0 or argc > MaxArgs:
    result.why = result.target & ": " & $argc &
                 " arguments; the fast path passes at most " & $MaxArgs
    return

  let cls = findClass(rt, owner)
  if cls == nil:
    result.why = "no such type: " & owner &
                 " (the game's assemblies may not be loaded yet)"
    return
  let m = findMethod(rt, cls, member, argc)
  if m == nil:
    result.why = "no method " & result.target & " taking " & $argc &
                 " argument(s)"
    return

  var kinds: seq[FastKind] = @[]
  for i in 0 ..< argc:
    let tn = typeName(rt, methodParam(rt, m, i))
    let k = classifyType(rt, tn)
    if k == fkNone:
      result.why = result.target & ": argument " & $i & " is declared " & tn &
        ", which the fast path will not classify. If it is a reference or an " &
        "enum, say so with bindMethodAs."
      return
    kinds.add k

  let rtn = typeName(rt, methodReturnType(rt, m))
  let rk = classifyType(rt, rtn)
  if rk == fkNone:
    result.why = result.target & ": returns " & rtn &
      ", which the fast path will not classify. If it is a reference or an " &
      "enum, say so with bindMethodAs."
    return

  result = bindMethodAs(rt, owner, member, kinds, rk)
  # The inference walked the parameter list, and that is part of what binding
  # cost; `bindMethodAs` only timed its own half.
  result.bindNs = nanosBetween(t0, perfCounter())

# ---------------------------------------------------------------------------
# Stating the call shape outright
# ---------------------------------------------------------------------------
#
# `bindMethod` classifies each declared parameter into a register class and
# refuses anything it cannot. `bindMethodAs` lets a mod assert those classes.
# Neither can express a method whose *shape* differs from its signature -- and
# on Win64 the two most common such methods in this game are exactly the ones a
# mod wants most.
#
# A `Vector3` is twelve bytes. Win64 passes anything larger than eight and not a
# power of two **by hidden pointer**, and returns it the same way: the caller
# allocates the space, passes its address as an invisible first argument, and
# the callee writes through it and returns that address. So
#
#     Vector3 Player::get_Position()            is really
#     void*   get_Position(void* sret, void* this, MethodInfo*)
#
#     void Mover::GoToPoint(Vector3 p, ...)     is really
#     void GoToPoint(void* this, void* p, ..., MethodInfo*)
#
# Every slot in both is a plain pointer -- which the existing trampoline table
# already passes. Nothing new is needed in the C at all; what was missing was a
# way to say "this method has four pointer slots" when its signature says it has
# one argument.
#
# That is what `bindRaw` is. It is the sharpest tool here: the mod is asserting
# a calling convention, and a wrong assertion is a call into the game with the
# arguments in the wrong registers. It exists because the alternative -- the
# reflective path -- costs about a hundred times as much and allocates a managed
# object per call, on a path that runs per bot per frame.

type
  ShapedArgs* = object
    ## Slots for a shaped call, filled positionally by the mod. Unlike `Args`,
    ## nothing here is inferred: slot 0 is whatever the mod says slot 0 is.
    slots*: array[MaxSlots, uint64]
    n*: int32

proc shaped*(): ShapedArgs =
  result = ShapedArgs(n: 0'i32)

proc addSlotPtr*(a: var ShapedArgs; p: Il2CppPtr) =
  if a.n >= int32(MaxSlots): return
  cSetP(cast[Il2CppPtr](addr a.slots[0]), a.n, p)
  inc a.n

proc addSlotInt*(a: var ShapedArgs; v: int64) =
  if a.n >= int32(MaxSlots): return
  cSetG(cast[Il2CppPtr](addr a.slots[0]), a.n, v)
  inc a.n

proc addSlotFloat*(a: var ShapedArgs; v: float) =
  ## The slot's *mask* bit lives on the binding, not here: a shaped call states
  ## its whole shape up front, so which slots are floats is fixed at bind time
  ## and cannot be varied per call.
  if a.n >= int32(MaxSlots): return
  cSetF(cast[Il2CppPtr](addr a.slots[0]), a.n, v)
  inc a.n

proc bindRaw*(rt: Il2Cpp; cls: Il2CppClass; owner, member: string;
              declaredArgc: int; slots: int; floatMask: uint32;
              ret: FastKind): Binding =
  ## Binds a method by its **native slot shape** rather than its signature.
  ##
  ## `declaredArgc` finds the method (IL2CPP looks up by name and arity);
  ## `slots` is how many registers the call actually uses, counting a hidden
  ## return pointer and `this`; `floatMask` says which of those are floats.
  ##
  ## The mod is asserting the convention. Getting `slots` wrong reads an
  ## uninitialised register as an argument -- a plausible number rather than a
  ## crash -- so this is the last resort, not the first, and every use of it
  ## should say in a comment why the shape is what it claims.
  let t0 = perfCounter()
  result = noBinding(owner & "::" & member, "")
  if slots < 0 or slots > MaxSlots:
    result.why = result.target & ": " & $slots &
                 " slots; the fast path passes at most " & $MaxSlots
    return
  if cls == nil:
    result.why = result.target & ": no class was given"
    return
  let m = findMethod(rt, cls, member, declaredArgc)
  if m == nil:
    result.why = "no method " & result.target & " taking " & $declaredArgc &
                 " argument(s)"
    return
  let fn = methodPointer(rt, m)
  if fn == nil:
    result.why = result.target &
      ": MethodInfo.methodPointer is not a code address on this build"
    return

  result.fn = fn
  result.info = m
  result.isStatic = methodIsStatic(rt, m)
  # A shaped call fills every slot itself, including `this`, so the caller must
  # not have one written for it: `argc` equals `slots` and `isStatic` is forced
  # true for the calling path. What the method really is stays in `why`.
  result.argc = int32(slots)
  result.slots = int32(slots)
  result.mask = floatMask
  result.ret = ret
  result.ok = true
  result.bindNs = nanosBetween(t0, perfCounter())
  result.why = result.target & ": shaped, " & $slots & " slot(s), " &
    (if result.isStatic: "static" else: "instance") & ", returns " &
    describe(ret)
  result.isStatic = true

proc callShapedPtr*(b: Binding; a: var ShapedArgs): Il2CppPtr =
  ## A shaped call returning a pointer -- which is what a struct return is: the
  ## address the callee wrote through, and the same address the caller passed.
  result = cast[Il2CppPtr](0)
  if not b.ok or a.n != b.slots: return
  let v = cFastG(b.fn, b.info, b.slots, b.mask,
                 cast[Il2CppPtr](addr a.slots[0]))
  result = cast[Il2CppPtr](v)

proc callShapedVoid*(b: Binding; a: var ShapedArgs) =
  if not b.ok or a.n != b.slots: return
  discard cFastG(b.fn, b.info, b.slots, b.mask,
                 cast[Il2CppPtr](addr a.slots[0]))

proc callShapedFloat*(b: Binding; a: var ShapedArgs): float =
  result = 0.0
  if not b.ok or a.n != b.slots: return
  if b.ret == fkF64:
    result = cFastD(b.fn, b.info, b.slots, b.mask,
                    cast[Il2CppPtr](addr a.slots[0]))
  else:
    result = cFastF(b.fn, b.info, b.slots, b.mask,
                    cast[Il2CppPtr](addr a.slots[0]))

# ---------------------------------------------------------------------------
# Calling
# ---------------------------------------------------------------------------

proc slotBase(b: Binding; self: Il2CppPtr; a: var Args): Il2CppPtr =
  ## Where the call's slot array starts, and `this` written into it if there
  ## is one. Static calls start at slot 1, which is where `addInt` and friends
  ## put the first declared argument, so nothing is shuffled.
  if b.isStatic:
    result = cast[Il2CppPtr](addr a.slots[1])
  else:
    cSetP(cast[Il2CppPtr](addr a.slots[0]), 0'i32, self)
    result = cast[Il2CppPtr](addr a.slots[0])

proc callable(b: Binding; a: Args): bool {.inline.} =
  ## The one check kept on the hot path. Arity is checked because getting it
  ## wrong reads an uninitialised slot as an argument, which is a plausible
  ## number rather than a crash; the mask is not, because it came from the
  ## binding rather than the call site.
  result = b.ok and a.n == b.argc

proc callVoid*(b: Binding; self: Il2CppPtr; a: var Args) =
  ## Calls, discarding whatever came back. Safe for a non-void method too --
  ## the return register is simply not read.
  if not callable(b, a): return
  discard cFastG(b.fn, b.info, b.slots, b.mask, slotBase(b, self, a))

proc callInt*(b: Binding; self: Il2CppPtr; a: var Args): int64 =
  ## Every integer return, at its full width. A method declared `Int32` leaves
  ## the upper 32 bits of RAX undefined, so narrow with `int32(...)` if the
  ## sign matters.
  result = 0'i64
  if not callable(b, a): return
  result = cFastG(b.fn, b.info, b.slots, b.mask, slotBase(b, self, a))

proc callInt32*(b: Binding; self: Il2CppPtr; a: var Args): int32 =
  result = int32(callInt(b, self, a))

proc callBool*(b: Binding; self: Il2CppPtr; a: var Args): bool =
  ## A C# `bool` is one byte in AL and the rest of RAX is undefined, so only
  ## the low byte is looked at.
  result = (callInt(b, self, a) and 0xFF'i64) != 0'i64

proc callPtr*(b: Binding; self: Il2CppPtr; a: var Args): Il2CppPtr =
  ## A reference return -- an object, a string, an array.
  ##
  ## This is a **raw pointer into the managed heap** and the collector may move
  ## or free it. Use it within the frame, or take a GC handle if it must
  ## outlive one; do not store it.
  result = cast[Il2CppPtr](0)
  if not callable(b, a): return
  let v = cFastG(b.fn, b.info, b.slots, b.mask, slotBase(b, self, a))
  result = cast[Il2CppPtr](v)

proc callFloat*(b: Binding; self: Il2CppPtr; a: var Args): float =
  ## A `float` or `double` return, widened to nimony's 64-bit `float`.
  ##
  ## Which of the two dispatchers is used is decided by the binding, not here:
  ## a float return leaves 32 bits in XMM0 and a double leaves 64, and reading
  ## one as the other produces a plausible number rather than an error.
  result = 0.0
  if not callable(b, a): return
  let p = slotBase(b, self, a)
  if b.ret == fkF64:
    result = cFastD(b.fn, b.info, b.slots, b.mask, p)
  else:
    result = cFastF(b.fn, b.info, b.slots, b.mask, p)

# ---------------------------------------------------------------------------
# Field bindings
# ---------------------------------------------------------------------------

type
  FieldBinding* = object
    ## An instance field, resolved to a byte offset.
    ##
    ## After this, reading it is a load. The boxed path for the same read is:
    ## find the FieldInfo by name, ask for its type, ask the runtime for the
    ## type's *name* (which it allocates and the caller frees), branch on the
    ## string, call `il2cpp_field_get_value` into a scratch buffer, and format
    ## the result as JSON.
    ok*: bool
    why*: string
    target*: string
    offset*: int32
    kind*: FastKind
    bindNs*: int64

proc bindField*(rt: Il2Cpp; owner, fieldName: string): FieldBinding =
  ## Binds an **instance** field.
  ##
  ## A static field is refused, and the reason is worth stating: for a static
  ## field `il2cpp_field_get_offset` returns an offset into the class's static
  ## data block, not into any object, and reaching that block needs
  ## `il2cpp_class_get_static_field_data`, which is not in the binding yet.
  ## Applying an instance read to it would read some object's payload at the
  ## same offset and hand back a number. Since the C API exposes no field flags
  ## in the current binding either, staticness is inferred from the offset
  ## falling outside the object -- see below.
  let t0 = perfCounter()
  result = FieldBinding(ok: false, why: "", target: owner & "::" & fieldName,
                        offset: 0'i32, kind: fkNone, bindNs: 0'i64)

  let cls = findClass(rt, owner)
  if cls == nil:
    result.why = "no such type: " & owner &
                 " (the game's assemblies may not be loaded yet)"
    return
  let f = findField(rt, cls, fieldName)
  if f == nil:
    result.why = "no field " & result.target
    return

  let off = fieldOffset(rt, f)
  let size = classInstanceSize(rt, cls)
  # The bound is the guard. An offset of zero is the object header (never a
  # field), and one at or past the instance size is not addressing this object
  # at all -- which is exactly what a static field's offset looks like from
  # here. Refusing beats reading a neighbouring field with total confidence.
  if off <= 0 or (size > 0 and off >= size):
    result.why = result.target & ": offset " & $off &
      " is outside an instance of size " & $size &
      " -- a static field, or a layout this path cannot use. Use the boxed path."
    return

  let tn = typeName(rt, fieldType(rt, f))
  let k = classifyType(rt, tn)
  if k == fkNone or k == fkVoid:
    result.why = result.target & " is declared " & tn &
      ", which the fast path will not read by offset. A value type wider than " &
      "eight bytes has to be copied, not loaded."
    return

  result.offset = int32(off)
  result.kind = k
  result.ok = true
  result.bindNs = nanosBetween(t0, perfCounter())
  result.why = result.target & ": " & describe(k) & " at offset " & $off

proc readInt*(f: FieldBinding; obj: Il2CppPtr): int64 =
  result = 0'i64
  if not f.ok or obj == nil: return
  if f.kind == fkI64 or f.kind == fkPtr:
    result = cFldI64(obj, f.offset)
  elif f.kind == fkBool:
    result = int64(cFldU8(obj, f.offset))
  else:
    result = int64(cFldI32(obj, f.offset))

proc readInt32*(f: FieldBinding; obj: Il2CppPtr): int32 =
  result = int32(readInt(f, obj))

proc readBool*(f: FieldBinding; obj: Il2CppPtr): bool =
  result = false
  if not f.ok or obj == nil: return
  result = cFldU8(obj, f.offset) != 0'i32

proc readFloat*(f: FieldBinding; obj: Il2CppPtr): float =
  ## The read a hot mod actually does. One load; the widening to nimony's
  ## 64-bit `float` happens in C where the field's own width is known.
  result = 0.0
  if not f.ok or obj == nil: return
  if f.kind == fkF64:
    result = cFldF64(obj, f.offset)
  else:
    result = cFldF32(obj, f.offset)

proc readPtr*(f: FieldBinding; obj: Il2CppPtr): Il2CppPtr =
  ## A reference field. Same warning as `callPtr`: a raw managed pointer,
  ## good for this frame.
  result = cast[Il2CppPtr](0)
  if not f.ok or obj == nil: return
  result = cFldPtr(obj, f.offset)

proc writeInt*(f: FieldBinding; obj: Il2CppPtr; v: int64) =
  if not f.ok or obj == nil: return
  if f.kind == fkI64:
    cFldSetI64(obj, f.offset, v)
  elif f.kind == fkBool:
    cFldSetU8(obj, f.offset, int32(v))
  else:
    cFldSetI32(obj, f.offset, int32(v))

proc writeBool*(f: FieldBinding; obj: Il2CppPtr; v: bool) =
  if not f.ok or obj == nil: return
  cFldSetU8(obj, f.offset, (if v: 1'i32 else: 0'i32))

proc writeFloat*(f: FieldBinding; obj: Il2CppPtr; v: float) =
  if not f.ok or obj == nil: return
  if f.kind == fkF64:
    cFldSetF64(obj, f.offset, v)
  else:
    cFldSetF32(obj, f.offset, v)

proc writePtr*(f: FieldBinding; obj: Il2CppPtr; v: Il2CppPtr) =
  ## Writing a reference field **without a write barrier**.
  ##
  ## IL2CPP's collector needs to be told when an object starts referring to
  ## another one; `il2cpp_gc_wbarrier_set_field` is what does that, and it is
  ## not in the binding. Storing a young object into an old one's field and
  ## skipping the barrier can get that object collected while it is still
  ## referenced. Safe for a pointer the object already reachably holds; not
  ## safe for a fresh allocation. Use the boxed path if that distinction is not
  ## obviously on your side.
  if not f.ok or obj == nil: return
  cFldSetPtr(obj, f.offset, v)
