## Binding primitives: one scalar on a game object, bound once, read forever.
##
## `aowlspt/fast` gives two things — a method resolved to a function pointer,
## and a field resolved to a byte offset. This file is the third thing a mod
## actually needs, which is *either of those, whichever the game has*.
##
## That is not a convenience. BSG expose the same quantity as a public field on
## one type and as a property on another, and the two are unrelated at the
## metadata level: a property compiles to `get_X`/`set_X` and has no field
## behind it, a field has no method behind it. A mod that guessed wrong would
## get "no such method" or "no such field" and no hint that the other spelling
## was right there. So a `Slot` tries the field first — it is the cheaper read
## by a factor of four — and falls back to the accessor pair, and remembers
## which one it found.
##
## Everything here binds against a **type name**, and the type name comes from a
## live object rather than from this file wherever it can (`typeNameOf`). EFT
## renames private types between builds and SPT renames them again; the name of
## the class an object *is* cannot be stale, and the member name is the only
## thing left to be wrong about.
##
## Nothing in this file is on the per-frame path except `getF`/`getB`/`getP`
## and `setF`, which are one branch and one load or one indirect call.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast

# ---------------------------------------------------------------------------
# Type names from live objects
# ---------------------------------------------------------------------------

proc typeNameOf*(rt: Il2Cpp; obj: Il2CppPtr): string =
  ## The qualified name of the class an object actually is.
  ##
  ## Not the declared return type of whatever handed it over: `get_MainPlayer`
  ## is declared to return `Player` and returns a `LocalPlayer`, and the member
  ## we want may be the override. Binding against the concrete class also means
  ## `findMethod` starts at the right end of the hierarchy.
  result = ""
  if obj == nil or not rt.loaded:
    return
  let c = objectClass(rt, obj)
  if c == nil:
    return
  let ns = classNamespace(rt, c)
  let n = className(rt, c)
  if n.len == 0:
    return
  result = (if ns.len > 0: ns & "." & n else: n)

# ---------------------------------------------------------------------------
# A scalar slot
# ---------------------------------------------------------------------------

type
  SlotKind* = enum
    skNone,       ## not bound; every read answers the caller's default
    skField,      ## a field at a byte offset: one load
    skMethod      ## a property: `get_X`, and `set_X` if a write was asked for

  Slot* = object
    ## One scalar on one type. Bind once per session — the offset and the
    ## function pointer belong to the *type*, not to the object, so a new
    ## weapon does not invalidate them; only the object pointers change.
    kind*: SlotKind
    fb*: FieldBinding
    getter*: Binding
    setter*: Binding
    why*: string        ## what was found, or why nothing was

proc noSlot*(): Slot =
  Slot(kind: skNone, fb: FieldBinding(ok: false, why: "", target: "",
       offset: 0'i32, kind: fkNone, bindNs: 0'i64),
       getter: Binding(ok: false, why: "", target: "",
                       fn: nullPtr(), info: nullPtr(), argc: 0'i32,
                       slots: 0'i32, mask: 0'u32, ret: fkNone,
                       isStatic: false, bindNs: 0'i64),
       setter: Binding(ok: false, why: "", target: "",
                       fn: nullPtr(), info: nullPtr(), argc: 0'i32,
                       slots: 0'i32, mask: 0'u32, ret: fkNone,
                       isStatic: false, bindNs: 0'i64),
       why: "")

proc bindSlot*(rt: Il2Cpp; owner, member: string; wantWrite = false): Slot =
  ## Binds `member` on `owner`, field first.
  ##
  ## A failure is not fatal and never guessed around: `why` says which of the
  ## two spellings was tried and what the runtime said about each, because a
  ## member that quietly reads zero forever is the failure mode this whole file
  ## exists to make impossible.
  result = noSlot()
  if owner.len == 0:
    result.why = member & ": no owning type (the object it lives on was null)"
    return

  result.fb = bindField(rt, owner, member)
  if result.fb.ok:
    result.kind = skField
    result.why = result.fb.why
    return

  result.getter = bindMethod(rt, owner, "get_" & member, 0)
  if result.getter.ok:
    result.kind = skMethod
    result.why = result.getter.why
    if wantWrite:
      result.setter = bindMethod(rt, owner, "set_" & member, 1)
      if not result.setter.ok:
        result.why = result.why & "; read-only (" & result.setter.why & ")"
    return

  # Both refused. Report both reasons: "no field X" alone reads like the member
  # does not exist, when the usual cause is that it is a property.
  result.why = owner & "::" & member & " — not a field (" & result.fb.why &
               ") and not a property (" & result.getter.why & ")"

proc bindSlotOn*(rt: Il2Cpp; obj: Il2CppPtr; member: string; kind: FastKind;
                 wantWrite = false): Slot =
  ## The same, bound against a **live object's own class** instead of a name.
  ##
  ## `bindSlot` reaches its type through `findClass`, which takes a qualified
  ## name — and there are types in this game that no name reaches. A nested
  ## class is the one that matters here: `Player.FirearmController` is
  ## `FirearmController` with `Player`'s namespace as far as the C API is
  ## concerned, so the obvious `EFT.FirearmController` finds nothing and the
  ## whole weapon group would silently bind to zero members. A generic
  ## instantiation is the same problem with a worse name.
  ##
  ## `bindOnObject` starts from the object's own class and walks its base chain,
  ## so there is no name to be wrong about. The cost is that it cannot infer:
  ## the caller states the return's register class, which is why this takes a
  ## `kind` and `bindSlot` does not.
  ##
  ## The order is deliberately the reverse of `bindSlot`'s. There, the field is
  ## tried first because it is the cheaper read. Here, the accessor is tried
  ## first because it is the one that works at all when the class cannot be
  ## named — the field path below still needs a name, and is only a fallback for
  ## a nameable type whose member happens to be a field.
  result = noSlot()
  if obj == nil:
    result.why = member & ": no object to bind against"
    return

  var none: seq[FastKind] = @[]
  result.getter = bindOnObject(rt, obj, "get_" & member, none, kind)
  if result.getter.ok:
    result.kind = skMethod
    result.why = result.getter.why
    if wantWrite:
      var one: seq[FastKind] = @[]
      one.add kind
      result.setter = bindOnObject(rt, obj, "set_" & member, one, fkVoid)
      if not result.setter.ok:
        result.why = result.why & "; read-only (" & result.setter.why & ")"
    return

  let named = typeNameOf(rt, obj)
  let accessorWhy = result.getter.why
  result = bindSlot(rt, named, member, wantWrite)
  if not result.bound():
    result.why = result.why & "; and not on the object itself (" &
                 accessorWhy & ")"

proc bound*(s: Slot): bool = s.kind != skNone

proc writable*(s: Slot): bool =
  ## A field is always writable; a property only if it declared a setter.
  (s.kind == skField) or (s.kind == skMethod and s.setter.ok)

proc getF*(s: Slot; obj: Il2CppPtr; default = 0.0): float =
  ## One `float` off one object. Two nanoseconds as a field, eight as a getter.
  result = default
  if obj == nil:
    return
  if s.kind == skField:
    result = readFloat(s.fb, obj)
  elif s.kind == skMethod:
    var a = noArgs()
    result = callFloat(s.getter, obj, a)

proc getB*(s: Slot; obj: Il2CppPtr; default = false): bool =
  result = default
  if obj == nil:
    return
  if s.kind == skField:
    result = readBool(s.fb, obj)
  elif s.kind == skMethod:
    var a = noArgs()
    result = callBool(s.getter, obj, a)

proc getI*(s: Slot; obj: Il2CppPtr; default = 0): int =
  result = default
  if obj == nil:
    return
  if s.kind == skField:
    result = int(readInt(s.fb, obj))
  elif s.kind == skMethod:
    var a = noArgs()
    result = int(callInt(s.getter, obj, a))

proc getP*(s: Slot; obj: Il2CppPtr): Il2CppPtr =
  ## A reference member — the whole object chain is these.
  ##
  ## The result is a **raw managed pointer, good for this frame only**. The
  ## collector moves objects, so nothing here is ever stored across a frame:
  ## the chain is re-walked from the root every frame, which costs a handful of
  ## loads and removes an entire class of bug.
  result = nullPtr()
  if obj == nil:
    return
  if s.kind == skField:
    result = readPtr(s.fb, obj)
  elif s.kind == skMethod:
    var a = noArgs()
    result = callPtr(s.getter, obj, a)

proc setF*(s: Slot; obj: Il2CppPtr; value: float) =
  if obj == nil:
    return
  if s.kind == skField:
    writeFloat(s.fb, obj, value)
  elif s.kind == skMethod and s.setter.ok:
    var a = argsF(value)
    callVoid(s.setter, obj, a)

proc setB*(s: Slot; obj: Il2CppPtr; value: bool) =
  if obj == nil:
    return
  if s.kind == skField:
    writeBool(s.fb, obj, value)
  elif s.kind == skMethod and s.setter.ok:
    var a = noArgs()
    addBool(a, value)
    callVoid(s.setter, obj, a)

# ---------------------------------------------------------------------------
# Vector fields
# ---------------------------------------------------------------------------
#
# `bindField` refuses a `UnityEngine.Vector3` field, and it is right to: a value
# type wider than eight bytes cannot be *loaded*, it has to be copied, and
# handing back a garbage float would be worse than refusing.
#
# But a Vector3 field is three `System.Single` fields laid end to end at a known
# offset, and reading the components separately is exactly as safe as reading
# any other float by offset. So this bypasses `bindField` for the offset only —
# `il2cpp_field_get_offset` is the same call `bindField` makes — and then builds
# three ordinary float FieldBindings at +0, +4 and +8.
#
# The instance-size bound is repeated here rather than inherited, because it is
# the check that stops a *static* field's offset (which is an offset into the
# class's static block, not into any object) from being used as an instance one.

type
  VecSlot* = object
    ## A `Vector2` or `Vector3` field, as two or three float loads.
    ok*: bool
    n*: int             ## 2 or 3
    comp*: array[3, FieldBinding]
    why*: string

proc floatAt(target: string; off: int32): FieldBinding =
  FieldBinding(ok: true, why: target, target: target, offset: off,
               kind: fkF32, bindNs: 0'i64)

proc bindVecField*(rt: Il2Cpp; owner, member: string; n: int): VecSlot =
  ## Binds a Vector2/Vector3 **field** as its float components.
  result = VecSlot(ok: false, n: n,
                   comp: [FieldBinding(ok: false, why: "", target: "",
                                       offset: 0'i32, kind: fkNone, bindNs: 0'i64),
                          FieldBinding(ok: false, why: "", target: "",
                                       offset: 0'i32, kind: fkNone, bindNs: 0'i64),
                          FieldBinding(ok: false, why: "", target: "",
                                       offset: 0'i32, kind: fkNone, bindNs: 0'i64)],
                   why: "")
  let target = owner & "::" & member
  if owner.len == 0:
    result.why = member & ": no owning type"
    return
  let cls = findClass(rt, owner)
  if cls == nil:
    result.why = "no such type: " & owner
    return
  let f = findField(rt, cls, member)
  if f == nil:
    result.why = "no field " & target
    return
  let tn = typeName(rt, fieldType(rt, f))
  if tn != "UnityEngine.Vector2" and tn != "UnityEngine.Vector3" and
     tn != "UnityEngine.Vector4":
    result.why = target & " is declared " & tn & ", not a vector"
    return
  let off = fieldOffset(rt, f)
  let size = classInstanceSize(rt, cls)
  # Offset zero is the object header and never a field; an offset at or past
  # the instance size is not addressing this object at all, which is what a
  # static field's offset looks like from here.
  if off <= 0 or (size > 0 and off + 4 * n > size):
    result.why = target & ": offset " & $off & " does not hold " & $n &
                 " floats inside an instance of size " & $size
    return
  for i in 0 ..< n:
    result.comp[i] = floatAt(target, int32(off + 4 * i))
  result.ok = true
  result.why = target & ": " & tn & " at offset " & $off

proc getX*(v: VecSlot; obj: Il2CppPtr): float =
  result = 0.0
  if v.ok and obj != nil: result = readFloat(v.comp[0], obj)
proc getY*(v: VecSlot; obj: Il2CppPtr): float =
  result = 0.0
  if v.ok and obj != nil: result = readFloat(v.comp[1], obj)
proc getZ*(v: VecSlot; obj: Il2CppPtr): float =
  result = 0.0
  if v.ok and v.n >= 3 and obj != nil: result = readFloat(v.comp[2], obj)

proc setXYZ*(v: VecSlot; obj: Il2CppPtr; x, y, z: float) =
  if not v.ok or obj == nil:
    return
  writeFloat(v.comp[0], obj, x)
  writeFloat(v.comp[1], obj, y)
  if v.n >= 3:
    writeFloat(v.comp[2], obj, z)

# ---------------------------------------------------------------------------
# Finding a vector field whose name we are not sure of
# ---------------------------------------------------------------------------

proc lowerAscii(s: string): string =
  result = ""
  for ch in s:
    if ch >= 'A' and ch <= 'Z':
      result.add char(ord(ch) + 32)
    else:
      result.add ch

proc containsCI(haystack, needle: string): bool =
  ## Case-insensitive substring. `std/strutils` has `contains`, but the names
  ## being matched here are `_rotation`, `Rotation` and `rotation_0` depending
  ## on the build, and the case is the part we must not depend on.
  let h = lowerAscii(haystack)
  let n = lowerAscii(needle)
  if n.len == 0:
    return true
  if n.len > h.len:
    return false
  for start in 0 .. h.len - n.len:
    var same = true
    for i in 0 ..< n.len:
      if h[start + i] != n[i]:
        same = false
        break
    if same:
      return true
  result = false

proc findVecFieldNamed*(rt: Il2Cpp; owner, hint: string; n: int;
                        found: var string): VecSlot =
  ## The vector field on `owner` whose name contains `hint`.
  ##
  ## The view angles and the body velocity are the two inputs this mod needs
  ## that BSG expose only as a `Vector2`/`Vector3` *property*, and a value-type
  ## return is unreachable on both paths (see `live.nim`). The backing field is
  ## reachable — but its name is a compiler-generated private one and differs
  ## between builds. Scanning for it once at bind time is honest about that;
  ## hard-coding `_rotation` and reading zeroes forever would not be.
  ##
  ## The scan is over one class's declared fields, once, and it reports the
  ## name it settled on so that a wrong match is visible in the log rather than
  ## being a mystery in the sway.
  found = ""
  result = VecSlot(ok: false, n: n,
                   comp: [FieldBinding(ok: false, why: "", target: "",
                                       offset: 0'i32, kind: fkNone, bindNs: 0'i64),
                          FieldBinding(ok: false, why: "", target: "",
                                       offset: 0'i32, kind: fkNone, bindNs: 0'i64),
                          FieldBinding(ok: false, why: "", target: "",
                                       offset: 0'i32, kind: fkNone, bindNs: 0'i64)],
                   why: "")
  if owner.len == 0:
    result.why = "no owning type for a vector named like '" & hint & "'"
    return
  let cls = findClass(rt, owner)
  if cls == nil:
    result.why = "no such type: " & owner
    return
  let want = (if n == 2: "UnityEngine.Vector2" else: "UnityEngine.Vector3")

  var iter: Il2CppIter = nullPtr()
  var name = ""
  while true:
    let f = nextField(rt, cls, iter)
    if f == nil:
      break
    name = fieldName(rt, f)
    if not containsCI(name, hint):
      continue
    if typeName(rt, fieldType(rt, f)) != want:
      continue
    found = name
    result = bindVecField(rt, owner, name, n)
    if result.ok:
      return
  if found.len == 0:
    result.why = owner & " has no " & want & " field whose name contains '" &
                 hint & "'"

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

proc report*(label: string; s: Slot) =
  ## One line per binding, once. `docs/PERF.md` asks for exactly this: a
  ## refused binding is a mod that quietly does nothing otherwise.
  if s.bound():
    debug "sway  bound " & label & " (" & s.why & ")"
  else:
    warn "sway  " & label & " unavailable: " & s.why

proc report*(label: string; v: VecSlot) =
  if v.ok:
    debug "sway  bound " & label & " (" & v.why & ")"
  else:
    warn "sway  " & label & " unavailable: " & v.why
