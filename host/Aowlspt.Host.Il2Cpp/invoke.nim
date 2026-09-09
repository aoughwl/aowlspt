## Turning a JSON argument list into an IL2CPP call, and its result back.
##
## This is what makes `call` more than a curiosity: a mod names a method and
## passes values, and something has to decide what those values mean to the
## runtime. IL2CPP will not tell you -- `il2cpp_runtime_invoke` takes
## `void** params` and trusts you completely. Hand it an `Il2CppObject*` where
## it wanted a pointer-to-int and it reads the object header as an integer,
## with no error anywhere.
##
## So the types come from the method itself. `il2cpp_method_get_param` gives
## the declared parameter type, `il2cpp_type_get_name` gives its name, and the
## value is boxed to match. An argument that cannot be converted to the
## declared type is refused by name rather than coerced, because a silent
## coercion here is a wrong value in the game rather than an error in the log.

import std/strutils
import aowlspt/il2cpp

{.emit: """#include "aowlspt_shim.h" """.}

type ArgsPtr* = nil pointer

proc cArgsNew*(n: int32): ArgsPtr {.importc: "aowl_args_new", nodecl.}
proc cArgsFree*(p: ArgsPtr) {.importc: "aowl_args_free", nodecl.}
proc cArgsPtr*(p: ArgsPtr): Il2CppPtr {.importc: "aowl_args_ptr", nodecl.}
proc cArgsSetRef*(p: ArgsPtr; i: int32; v: Il2CppPtr) {.
  importc: "aowl_args_set_ref", nodecl.}
proc cArgsSetI32*(p: ArgsPtr; i: int32; v: int32) {.
  importc: "aowl_args_set_i32", nodecl.}
proc cArgsSetI64*(p: ArgsPtr; i: int32; v: int64) {.
  importc: "aowl_args_set_i64", nodecl.}
proc cArgsSetF32*(p: ArgsPtr; i: int32; v: float) {.
  importc: "aowl_args_set_f32", nodecl.}
proc cArgsSetF64*(p: ArgsPtr; i: int32; v: float) {.
  importc: "aowl_args_set_f64", nodecl.}

proc cRegsInt*(p: Il2CppPtr; i: int32): uint64 {.
  importc: "aowl_regs_int", nodecl.}
proc cRegsFlt*(p: Il2CppPtr; i: int32): float {.
  importc: "aowl_regs_flt", nodecl.}
## A `System.Single` argument, read as one. The thunk saves each XMM register
## with `movsd` -- the low 64 bits -- because only the method's declared
## signature says how wide the argument is, and the thunk does not have it. A
## float lives in the low 32 of those bits and the rest is register residue, so
## reading the slot as a double produces a number unrelated to the argument:
## 12.5f came back as 0.000000. Two readers, picked by declared type.
proc cRegsF32*(p: Il2CppPtr; i: int32): float {.
  importc: "aowl_regs_f32", nodecl.}
## What the original returned, on the postfix path. Two readers for the same
## reason there are two for a float argument: RAX and XMM0 are both saved
## because the thunk cannot know which holds the value, and only the declared
## return type says. See `aowl_regs_ret_f32` in the shim.
proc cRegsRetInt*(p: Il2CppPtr): uint64 {.importc: "aowl_regs_ret_int", nodecl.}
proc cRegsRetF32*(p: Il2CppPtr): float {.importc: "aowl_regs_ret_f32", nodecl.}
proc cRegsRetF64*(p: Il2CppPtr): float {.importc: "aowl_regs_ret_f64", nodecl.}

proc cRegsSetRetInt*(p: Il2CppPtr; v: uint64) {.
  importc: "aowl_regs_set_ret_int", nodecl.}
proc cRegsSetRetF32*(p: Il2CppPtr; v: float) {.
  importc: "aowl_regs_set_ret_f32", nodecl.}
proc cRegsSetRetF64*(p: Il2CppPtr; v: float) {.
  importc: "aowl_regs_set_ret_f64", nodecl.}

proc cCellNew*(): Il2CppPtr {.importc: "aowl_cell_new", nodecl.}
proc cCellFree*(p: Il2CppPtr) {.importc: "aowl_cell_free", nodecl.}
proc cCellSetI32*(p: Il2CppPtr; v: int32) {.importc: "aowl_cell_set_i32", nodecl.}
proc cCellSetI64*(p: Il2CppPtr; v: int64) {.importc: "aowl_cell_set_i64", nodecl.}
proc cCellSetF32*(p: Il2CppPtr; v: float) {.importc: "aowl_cell_set_f32", nodecl.}
proc cCellSetF64*(p: Il2CppPtr; v: float) {.importc: "aowl_cell_set_f64", nodecl.}
proc cCellSetPtr*(p, v: Il2CppPtr) {.importc: "aowl_cell_set_ptr", nodecl.}
proc cCellGetPtr*(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_cell_get_ptr", nodecl.}

proc cReadI32*(p: Il2CppPtr): int32 {.importc: "aowl_read_i32", nodecl.}
proc cReadI64*(p: Il2CppPtr): int64 {.importc: "aowl_read_i64", nodecl.}
proc cReadF32*(p: Il2CppPtr): float {.importc: "aowl_read_f32", nodecl.}
proc cReadF64*(p: Il2CppPtr): float {.importc: "aowl_read_f64", nodecl.}

# --------------------------------------------------------------- json

type
  JsonKind* = enum
    jkNull, jkBool, jkInt, jkFloat, jkString, jkHandle

  JsonValue* = object
    kind*: JsonKind
    b*: bool
    i*: int64
    f*: float
    s*: string

proc describe*(k: JsonKind): string =
  ## The wording a mod author sees when an argument is refused. "a string" is
  ## worth the six lines; "jkString" is not.
  case k
  of jkNull: result = "null"
  of jkBool: result = "a boolean"
  of jkInt: result = "an integer"
  of jkFloat: result = "a number with a fraction"
  of jkString: result = "a string"
  of jkHandle: result = "a handle"

proc jsonNull*(): JsonValue =
  result = JsonValue(kind: jkNull, b: false, i: 0'i64, f: 0.0, s: "")

proc isSpace(c: char): bool =
  result = c == ' ' or c == '\t' or c == '\n' or c == '\r'

proc skipSpace(text: string; i: var int) =
  ## A free proc rather than a nested one: nimony will not let a nested proc
  ## touch its enclosing scope's locals without making it a closure, and a
  ## closure for this would be silly.
  while i < text.len and isSpace(text[i]):
    inc i

proc parseArgs*(text: string; into: var seq[JsonValue]; error: var string): bool =
  ## A scalar JSON array: `[1, 2.5, "x", true, null]`.
  ##
  ## Deliberately not a general JSON parser. Everything that crosses this
  ## boundary is a positional argument list of scalars; nested objects and
  ## arrays have no meaning to `il2cpp_runtime_invoke` without a type to
  ## deserialise them into, so accepting them would only defer the error.
  ##
  ## One extension: a string of the form `"#7"` is a handle, not text. That is
  ## how a mod passes an object it resolved earlier as an argument.
  into = @[]
  error = ""
  var i = 0
  let n = text.len

  skipSpace(text, i)
  if i >= n:
    return true            # empty text means no arguments
  if text[i] != '[':
    error = "arguments must be a JSON array, got: " & text
    return false
  inc i

  while true:
    skipSpace(text, i)
    if i >= n:
      error = "unterminated argument array"
      return false
    if text[i] == ']':
      inc i
      return true

    if text[i] == '"':
      inc i
      var sv = ""
      while i < n and text[i] != '"':
        if text[i] == '\\' and i + 1 < n:
          inc i
          case text[i]
          of 'n': sv.add '\n'
          of 't': sv.add '\t'
          of 'r': sv.add '\r'
          else: sv.add text[i]
        else:
          sv.add text[i]
        inc i
      if i >= n:
        error = "unterminated string in argument array"
        return false
      inc i
      if sv.len > 1 and sv[0] == '#':
        var h = 0'i64
        var okNum = true
        for k in 1 ..< sv.len:
          if sv[k] >= '0' and sv[k] <= '9':
            h = h * 10 + int64(ord(sv[k]) - ord('0'))
          else:
            okNum = false
        if okNum:
          into.add JsonValue(kind: jkHandle, b: false, i: h, f: 0.0, s: sv)
        else:
          into.add JsonValue(kind: jkString, b: false, i: 0'i64, f: 0.0, s: sv)
      else:
        into.add JsonValue(kind: jkString, b: false, i: 0'i64, f: 0.0, s: sv)

    elif text.substr(i).startsWith("true"):
      into.add JsonValue(kind: jkBool, b: true, i: 1'i64, f: 1.0, s: "")
      i = i + 4
    elif text.substr(i).startsWith("false"):
      into.add JsonValue(kind: jkBool, b: false, i: 0'i64, f: 0.0, s: "")
      i = i + 5
    elif text.substr(i).startsWith("null"):
      into.add jsonNull()
      i = i + 4
    else:
      var neg = false
      if i < n and (text[i] == '-' or text[i] == '+'):
        neg = text[i] == '-'
        inc i
      var whole = 0'i64
      var digits = 0
      while i < n and text[i] >= '0' and text[i] <= '9':
        whole = whole * 10 + int64(ord(text[i]) - ord('0'))
        inc digits
        inc i
      if digits == 0:
        error = "not a number at offset " & $i & " in: " & text
        return false
      if i < n and text[i] == '.':
        inc i
        var frac = 0.0
        var scale = 0.1
        while i < n and text[i] >= '0' and text[i] <= '9':
          frac = frac + float(ord(text[i]) - ord('0')) * scale
          scale = scale * 0.1
          inc i
        var value = float(whole) + frac
        if neg: value = -value
        into.add JsonValue(kind: jkFloat, b: false, i: int64(value), f: value,
                           s: "")
      else:
        var value = whole
        if neg: value = -value
        into.add JsonValue(kind: jkInt, b: false, i: value, f: float(value),
                           s: "")

    skipSpace(text, i)
    if i < n and text[i] == ',':
      inc i
      continue
    if i < n and text[i] == ']':
      inc i
      return true
    if i >= n:
      error = "unterminated argument array"
      return false
    error = "expected ',' or ']' at offset " & $i & " in: " & text
    return false

# --------------------------------------------------------------- binding

proc isIntegerType(t: string): bool =
  result = t == "System.Int32" or t == "System.Int16" or t == "System.SByte" or
           t == "System.Byte" or t == "System.UInt16" or t == "System.UInt32" or
           t == "System.Char"

proc isLongType(t: string): bool =
  result = t == "System.Int64" or t == "System.UInt64" or t == "System.IntPtr"

const BoxHeaderFallback = 16
  ## `sizeof(Il2CppObject)` on x64: a class pointer and a monitor pointer.

var gBoxHeader = -1

proc boxHeaderBytes*(rt: Il2Cpp): int =
  ## How much of a value type's reported instance size is object header --
  ## asked of the runtime rather than assumed.
  ##
  ## `il2cpp_class_instance_size` on the game reports the **boxed** size, header
  ## plus payload, because that is the only form the runtime allocates. That is
  ## not universal: a stand-in can just as reasonably report the payload, and
  ## both answers are self-consistent, so no single number in isolation
  ## distinguishes them.
  ##
  ## One number whose payload is *known* does. `System.Int32` holds four bytes
  ## by definition, so whatever this runtime reports for it, minus four, is the
  ## header. `System.Double` is used only to check that answer: eight bytes of
  ## payload must report four more than `Int32` does, and if it does not, this
  ## runtime is not measuring what it is assumed to be measuring and the
  ## fallback is kept.
  ##
  ## Getting it wrong subtracts a header that is not there, which turns every
  ## small value type into a negative width and refuses it -- an enum argument
  ## reported as unclassifiable, a shaped call falling back to reflection, both
  ## quietly, and both while the code looks as though it had checked.
  if gBoxHeader >= 0:
    return gBoxHeader
  gBoxHeader = BoxHeaderFallback
  let i32 = findClass(rt, "System.Int32")
  if i32 != nil:
    let a = classInstanceSize(rt, i32)
    if a >= 4:
      let f64 = findClass(rt, "System.Double")
      var agree = true
      if f64 != nil:
        agree = classInstanceSize(rt, f64) - a == 4
      if agree:
        gBoxHeader = a - 4
  result = gBoxHeader

proc valueWidth(rt: Il2Cpp; t: Il2CppType): int =
  ## The payload width of a value type, or 0 if it is not one.
  result = 0
  let c = classFromType(rt, t)
  if c == nil or not classIsValueType(rt, c):
    return 0
  let n = classInstanceSize(rt, c) - boxHeaderBytes(rt)
  if n > 0:
    result = n

proc bindArgs*(rt: Il2Cpp; m: Il2CppMethod; values: seq[JsonValue];
               handles: seq[Il2CppPtr]; args: ArgsPtr;
               error: var string): bool =
  ## Boxes each value to the parameter type the method declares.
  error = ""
  for i in 0 ..< values.len:
    let t = typeName(rt, methodParam(rt, m, i))
    let v = values[i]

    if v.kind == jkHandle:
      let idx = int(v.i)
      if idx <= 0 or idx > handles.len:
        error = "argument " & $i & ": no such handle " & v.s
        return false
      cArgsSetRef(args, int32(i), handles[idx - 1])
      continue

    if t == "System.String":
      if v.kind != jkString:
        error = "argument " & $i & " is declared " & t & " but " &
                describe(v.kind) & " was given"
        return false
      cArgsSetRef(args, int32(i), newString(rt, v.s))
    elif t == "System.Boolean":
      if v.kind != jkBool:
        error = "argument " & $i & " is declared " & t & " but " &
                describe(v.kind) & " was given"
        return false
      cArgsSetI32(args, int32(i), (if v.b: 1'i32 else: 0'i32))
    elif isIntegerType(t):
      if v.kind != jkInt:
        error = "argument " & $i & " is declared " & t & " but " &
                describe(v.kind) & " was given"
        return false
      cArgsSetI32(args, int32(i), int32(v.i))
    elif isLongType(t):
      if v.kind != jkInt:
        error = "argument " & $i & " is declared " & t & " but " &
                describe(v.kind) & " was given"
        return false
      cArgsSetI64(args, int32(i), v.i)
    elif t == "System.Single":
      if v.kind != jkFloat and v.kind != jkInt:
        error = "argument " & $i & " is declared " & t & " but " &
                describe(v.kind) & " was given"
        return false
      cArgsSetF32(args, int32(i), v.f)
    elif t == "System.Double":
      if v.kind != jkFloat and v.kind != jkInt:
        error = "argument " & $i & " is declared " & t & " but " &
                describe(v.kind) & " was given"
        return false
      cArgsSetF64(args, int32(i), v.f)
    elif v.kind == jkNull:
      # A null reference is the one thing that fits any reference type.
      cArgsSetRef(args, int32(i), cast[Il2CppPtr](0))
    elif v.kind == jkInt and valueWidth(rt, methodParam(rt, m, i)) > 0:
      # An **enum**, which is most of what this game's methods take: every
      # state, condition, damage kind and body part is one. It is declared by
      # its own name (`EFT.EPhysicalCondition`), so none of the branches above
      # match it, and it used to land in the refusal below -- a mod could patch
      # such a method and read its arguments but could not call it.
      #
      # Nothing is boxed: `runtime_invoke` takes a value type as a pointer to
      # the raw value, which is exactly what `aowl_args_set_i32` leaves behind.
      # The width comes from the runtime rather than from an assumption that
      # every enum is an `int` -- a `byte` or `long` enum is legal and this
      # game has both.
      #
      # This also accepts a small struct built from one integer, which is
      # wrong-ish and harmless: such a struct's single field is at offset 0 and
      # the value written is the value it would have. A struct with more than
      # one field cannot be expressed as a JSON number in the first place, so
      # there is nothing here to get wrong that a mod could reach.
      let w = valueWidth(rt, methodParam(rt, m, i))
      if w <= 4:
        cArgsSetI32(args, int32(i), int32(v.i))
      elif w <= 8:
        cArgsSetI64(args, int32(i), v.i)
      else:
        error = "argument " & $i & " is declared " & t & ", a " & $w &
                "-byte value type; this host can build one of at most 8 bytes " &
                "from a number"
        return false
    else:
      error = "argument " & $i & " is declared " & t &
              ", which this host cannot build from a JSON scalar. " &
              "Resolve it to a handle and pass \"#n\"."
      return false
  result = true

proc describeResult*(rt: Il2Cpp; m: Il2CppMethod; res: Il2CppObject;
                    handles: var seq[Il2CppPtr];
                    isObject: var seq[bool];
                    gcHandles: var seq[uint32]): string =
  ## The return value as JSON. Value types are unboxed by their declared return
  ## type rather than by inspecting the object, since a boxed `Single` and a
  ## boxed `Int32` are the same shape and only the declaration distinguishes
  ## them.
  let rt2 = typeName(rt, methodReturnType(rt, m))
  if rt2 == "System.Void":
    return ""
  if res == nil:
    return "null"
  if rt2 == "System.String":
    return "\"" & readString(rt, res) & "\""
  let raw = objectUnbox(rt, res)
  if rt2 == "System.Boolean":
    return (if cReadI32(raw) != 0'i32: "true" else: "false")
  if isIntegerType(rt2):
    return $int(cReadI32(raw))
  if isLongType(rt2):
    return $cReadI64(raw)
  if rt2 == "System.Single":
    return $cReadF32(raw)
  if rt2 == "System.Double":
    return $cReadF64(raw)
  # An **enum**, or any small value type the runtime can name. It arrives boxed,
  # like every value type coming back from `runtime_invoke`, and the branches
  # above do not match it because it is declared by its own name
  # (`EFT.EPhysicalCondition`, `UnityEngine.ShadowResolution`, `EPlayerState`).
  #
  # It used to fall through to the reference path below, which is wrong twice
  # over: the mod got `{"handle":6,"type":"System.Int32"}` where it asked for a
  # number, so `asFloat()` answered 0.0 with `ok` true -- a wrong value that
  # reads as a right one -- and a GC handle was taken out on it that nothing
  # would ever release. The width comes from the runtime rather than from
  # assuming every enum is an `int`.
  let vw = valueWidth(rt, methodReturnType(rt, m))
  if vw > 0 and vw <= 8:
    if vw <= 4:
      return $int(cReadI32(raw))
    return $cReadI64(raw)

  # A reference type that is not a string: a *live object*, which is the thing
  # a mod actually wants -- this player, this weapon, this world -- rather than
  # the class it is an instance of.
  #
  # It is registered as a handle and the handle is returned, so the mod can call
  # methods on the object it just got back. Reporting only the type name (which
  # is what this did) meant every instance in the game was unreachable: you
  # could ask `EFT.Player` for its static members and never touch a player.
  #
  # The pointer is **not** kept. It is held through an IL2CPP GC handle, because
  # the collector moves and frees objects and a raw pointer held across two
  # frames is a use-after-free waiting for the right moment. `handle_release`
  # frees it; a mod that never releases pins the object for the session, which
  # is a leak rather than a crash and is the right way round.
  let cls = objectClass(rt, res)
  let gc = gcHandleNew(rt, res, false)
  if gc == 0'u32:
    # No GC handle means no safe way to keep it. Reporting the type alone is
    # honest: the mod finds out it cannot hold this rather than holding
    # something that will be freed underneath it.
    return "{\"type\":\"" & fullName(rt, cls) & "\"}"
  handles.add cast[Il2CppPtr](0)
  isObject.add true
  gcHandles.add gc
  result = "{\"handle\":" & $handles.len & ",\"type\":\"" &
           fullName(rt, cls) & "\"}"

# ---------------------------------------------------------------------------
# Fields
# ---------------------------------------------------------------------------
#
# A property compiles to `get_X`/`set_X` and is reachable through an ordinary
# call. A *field* is not: it has no method behind it, and half of what a mod
# wants to read on this game is a field -- often a private one, which is exactly
# what reflection is for.
#
# So `call` grows one piece of syntax: a member beginning with `@` names a
# field. `#7::@health` reads it, and the same target with one argument writes
# it. No new ABI entry, because the escape hatch is already the thing that means
# "reach something the header has not grown a door for".

# ---------------------------------------------------------------------------
# Decoding a patched method's arguments
# ---------------------------------------------------------------------------
#
# The detour thunk saves RCX/RDX/R8/R9 and XMM0-3 -- every register an argument
# can arrive in on this ABI -- and hands the frame here. Turning that back into
# values needs the method's declared signature, for the same reason binding an
# argument does: the bytes in a register do not say whether they are an `int`,
# a `float` or a pointer, and only the declaration knows.
#
# Position picks the register file. Argument 0 is RCX *or* XMM0 depending on its
# declared type, argument 1 is RDX *or* XMM1, and so on -- there is not a
# separate counter per file. Getting that wrong reads the right bits from the
# wrong place for every argument after the first float.
#
# A compiled instance method takes `this` in position 0, so its declared
# parameters start at position 1. A static one starts at 0. That is what
# `methodIsStatic` is for, and it is the difference between correct values and
# confidently wrong ones.

proc escapeForJson*(s: string): string =
  ## A game string reaches a patch handler inside a JSON array, so it has to be
  ## escaped -- a nickname with a quote in it would otherwise produce a body the
  ## handler cannot parse, blamed on the handler.
  result = ""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if ord(ch) < 0x20:
        const hexd = "0123456789abcdef"
        result.add "\\u00"
        result.add hexd[(ord(ch) shr 4) and 0xF]
        result.add hexd[ord(ch) and 0xF]
      else:
        result.add ch

const MaxRegArgs* = 4

proc reportableArgs*(isStatic: bool; declared: int): int =
  ## How many of `declared` parameters land in a register the thunk saved.
  ##
  ## `this` occupies register position 0 on an instance method and pushes every
  ## parameter along by one, so an instance method has room for three and a
  ## static one for four. Stated once, here, because the payload and its
  ## `stackArgs` count both need it as a number -- `frameKinds` needs the same
  ## rule per index and applies it there -- and the day the window moves it
  ## must move in both.
  if declared <= 0:
    return 0
  let room = (if isStatic: MaxRegArgs else: MaxRegArgs - 1)
  result = (if declared < room: declared else: room)

type ArgShape* = enum
  ## What a parameter or field type turns out to be, once the runtime is asked
  ## rather than guessed at.
  asUnknown    ## the runtime could not name a class for it
  asValueSmall ## a value type that fits in a register: an enum, a small struct
  asValueBig   ## a value type too large for a register; it arrives by hidden
               ## pointer, so there is nothing in the register to report
  asReference  ## a class: the register holds an object pointer

proc shapeOfType*(rt: Il2Cpp; t: Il2CppType; bytes: var int): ArgShape =
  ## Classifies a declared type, by asking the runtime for the class behind it.
  ##
  ## This exists because the alternative -- "everything I do not recognise by
  ## name is a reference" -- is a crash rather than a wrong answer. An `enum`
  ## parameter (`EPhysicalCondition`, `EPlayerState`, every state enum this game
  ## passes around) arrives as a small integer in a register, and handing that
  ## integer to `il2cpp_gchandle_new` as if it were an object is undefined
  ## behaviour inside the collector. A mod cannot protect itself from it either:
  ## it asks for the arguments without knowing the signature.
  bytes = 0
  let c = classFromType(rt, t)
  if c == nil:
    return asUnknown
  if not classIsValueType(rt, c):
    return asReference
  # The header comes from `boxHeaderBytes`, which measures it against two known
  # types, rather than from a constant. See that proc for why a constant here
  # reads as "every value type is unclassifiable" against a runtime that reports
  # sizes the other way round.
  let n = classInstanceSize(rt, c) - boxHeaderBytes(rt)
  bytes = n
  if n > 0 and n <= 8:
    return asValueSmall
  result = asValueBig

proc referenceHandle(rt: Il2Cpp; p: Il2CppPtr; typeName1: string;
                     handles: var seq[Il2CppPtr]; isObject: var seq[bool];
                     gcHandles: var seq[uint32]): string =
  ## A reference, as a handle a patch handler can call methods on.
  ##
  ## The handle lives until the handler returns and no longer -- `patchFired`
  ## reclaims it. See its comment for why that is the only workable lifetime on
  ## a path that fires thousands of times a second.
  if p == nil:
    return "null"
  let gc = gcHandleNew(rt, p, false)
  if gc == 0'u32:
    return "{\"type\":\"" & typeName1 & "\"}"
  handles.add cast[Il2CppPtr](0)
  isObject.add true
  gcHandles.add gc
  result = "{\"handle\":" & $handles.len & ",\"type\":\"" & typeName1 & "\"}"

proc describeArgs*(rt: Il2Cpp; m: Il2CppMethod; regs: Il2CppPtr;
                   handles: var seq[Il2CppPtr]; isObject: var seq[bool];
                   gcHandles: var seq[uint32]): string =
  ## What a patched method was called with, as JSON:
  ##
  ##     {"this":{"handle":3,"type":"EFT.Player"},"argc":2,"stackArgs":0,
  ##      "args":[...]}
  ##     {"this":null,"argc":0,"stackArgs":0,"args":[]}   -- a static method
  ##
  ## An object rather than a bare array, and that is the whole point of the
  ## shape. `this` is not a declared parameter -- it arrives in RCX ahead of
  ## them -- and it used to be dropped, which cost two mods five features
  ## between them: telling the local player from a bot *is* `__instance.IsAI`,
  ## and redirecting one context's tilt without knowing the context aims every
  ## context at one player's.
  ##
  ## Putting it in the array as element zero would have been more compact and
  ## would have made every argument index depend on whether the method is
  ## static, which is the kind of thing that goes wrong silently and far away.
  ## A handler reading `"args"` reads the declared parameters and nothing else,
  ## and a static method's `"this"` is `null` rather than absent, so "no
  ## instance" cannot be confused with "the payload did not say".
  ##
  ## **An argument past the register window is named, not dropped.** Win64
  ## passes the first four arguments in registers and the thunk saves those
  ## four; `this` is one of them on an instance method, so a four-argument
  ## instance method's last parameter travelled on the stack and there is
  ## nothing in the frame to report. That much is the ABI and cannot be argued
  ## with. What can be argued with is what the payload then says, and it used
  ## to say nothing: the array stopped early, so a handler reading argument 3
  ## got the same empty answer it would get for an argument that was genuinely
  ## empty, and went on to decide something on a value the game never supplied.
  ##
  ## So the array is always `argc` long and the missing one is
  ##
  ##     {"onStack":true,"type":"System.Single"}
  ##
  ## which no real argument can be confused with, and argument *n* is declared
  ## parameter *n* whatever the method's shape -- the same rule
  ## `AOWLSPT_ARG_STACK` already holds the typed path to, and the two paths
  ## disagreed about it until now. Two counts come with it: `argc`, the
  ## declared parameter count, and `stackArgs`, how many of them are in that
  ## state. A handler that wants to refuse the whole firing can read one number
  ## and refuse; one that only wants argument 0 carries on, which is why this
  ## is a marker rather than a refusal to install the patch. Most hooks want
  ## the first argument of a method whose later ones they have no use for, and
  ## turning a partial answer into no answer at all would have cost working
  ## features to prevent a mistake a named slot already prevents.
  ##
  ## The `"type"` in the marker is load-bearing and not decoration: it names
  ## what was lost, and it is also what makes the marker fail *closed* in a mod
  ## that has never heard of `onStack` -- an object carrying `"type"` and no
  ## `"handle"` is already the shape those mods refuse.
  let isStatic = methodIsStatic(rt, m)
  let declared = methodParamCount(rt, m)
  let onStack = declared - reportableArgs(isStatic, declared)

  var out1 = "{\"this\":"
  if isStatic:
    out1.add "null"
  else:
    let self = cast[Il2CppPtr](cRegsInt(regs, 0'i32))
    var selfType = "System.Object"
    let sc = objectClass(rt, self)
    if sc != nil:
      selfType = fullName(rt, sc)
    out1.add referenceHandle(rt, self, selfType, handles, isObject, gcHandles)
  out1.add ",\"argc\":" & $declared
  out1.add ",\"stackArgs\":" & $onStack
  out1.add ",\"args\":["

  var i = 0
  while i < declared:
    let pos = (if isStatic: i else: i + 1)
    if i > 0: out1.add ","
    let t = typeName(rt, methodParam(rt, m, i))
    if pos >= MaxRegArgs:
      # Past the register window. The thunk did not save it and nothing here
      # can recover it, so it is named rather than omitted -- and named with
      # its declared type, which is the part of it that *is* knowable.
      out1.add "{\"onStack\":true,\"type\":\"" & escapeForJson(t) & "\"}"
    elif t == "System.Single":
      out1.add $cRegsF32(regs, int32(pos))
    elif t == "System.Double":
      out1.add $cRegsFlt(regs, int32(pos))
    elif t == "System.Boolean":
      out1.add (if (cRegsInt(regs, int32(pos)) and 0xFF'u64) != 0'u64: "true"
                else: "false")
    elif isIntegerType(t):
      out1.add $int(int32(cRegsInt(regs, int32(pos)) and 0xFFFFFFFF'u64))
    elif isLongType(t):
      out1.add $int64(cRegsInt(regs, int32(pos)))
    elif t == "System.String":
      let p = cast[Il2CppPtr](cRegsInt(regs, int32(pos)))
      if p == nil:
        out1.add "null"
      else:
        out1.add "\"" & escapeForJson(readString(rt, p)) & "\""
    else:
      # Everything else is asked about rather than assumed. What used to be
      # here treated any unrecognised type as a reference and made a GC handle
      # out of whatever the register held, which for an enum parameter means
      # handing the collector the number 2 as an object.
      var bytes = 0
      case shapeOfType(rt, methodParam(rt, m, i), bytes)
      of asValueSmall:
        # An enum or a small value type: the register holds the value itself.
        # Reported the same way an integer parameter is, because that is what
        # it is -- an enum is its underlying integer once compiled.
        if bytes <= 4:
          out1.add $int(int32(cRegsInt(regs, int32(pos)) and 0xFFFFFFFF'u64))
        else:
          out1.add $int64(cRegsInt(regs, int32(pos)))
      of asValueBig:
        # Larger than a register, so it arrived by hidden reference and the
        # register holds a pointer to a copy whose layout this cannot read.
        # Named and refused rather than invented.
        out1.add "{\"valueType\":\"" & t & "\"}"
      of asReference:
        # A reference argument. Registered as a handle so the patch can call
        # methods on the very object the game was about to act on -- which is
        # the whole reason to want the arguments at all.
        out1.add referenceHandle(rt,
                                 cast[Il2CppPtr](cRegsInt(regs, int32(pos))),
                                 t, handles, isObject, gcHandles)
      of asUnknown:
        # The runtime would not name a class for it. Saying so is much better
        # than guessing that it is an object: the guess is a crash.
        out1.add "{\"type\":\"" & t & "\"}"
    inc i
  out1.add "]}"
  result = out1

proc describeReturn*(rt: Il2Cpp; m: Il2CppMethod; regs: Il2CppPtr;
                     handles: var seq[Il2CppPtr]; isObject: var seq[bool];
                     gcHandles: var seq[uint32]): string =
  ## What a patched method returned, as JSON, for a postfix handler.
  ##
  ## The mirror image of `describeArgs`, and it reads the frame by the same
  ## rule: the bytes do not say what they are, the **declared return type**
  ## does. An integer or a reference is in RAX, a `Single` or a `Double` is in
  ## XMM0, and the thunk saved both because it has no signature to consult.
  ##
  ## A reference return is registered as a handle on the same terms `this` is:
  ## live until the handler returns, and reclaimed by `patchReturned`. That is
  ## what lets a postfix on a factory method inspect -- or keep, by pinning --
  ## the object the game just built.
  let t = typeName(rt, methodReturnType(rt, m))
  if t == "System.Void":
    return "null"
  if t == "System.Boolean":
    return (if (cRegsRetInt(regs) and 0xFF'u64) != 0'u64: "true" else: "false")
  if t == "System.Single":
    return $cRegsRetF32(regs)
  if t == "System.Double":
    return $cRegsRetF64(regs)
  if isIntegerType(t):
    return $int(int32(cRegsRetInt(regs) and 0xFFFFFFFF'u64))
  if isLongType(t):
    return $int64(cRegsRetInt(regs))
  if t == "System.String":
    let p = cast[Il2CppPtr](cRegsRetInt(regs))
    if p == nil:
      return "null"
    return "\"" & escapeForJson(readString(rt, p)) & "\""
  var bytes = 0
  case shapeOfType(rt, methodReturnType(rt, m), bytes)
  of asValueSmall:
    if bytes <= 4:
      return $int(int32(cRegsRetInt(regs) and 0xFFFFFFFF'u64))
    return $int64(cRegsRetInt(regs))
  of asValueBig:
    # Refused at registration, so reaching here means the shape changed under
    # us. Named rather than invented, exactly as the argument path does.
    return "{\"valueType\":\"" & t & "\"}"
  of asReference:
    return referenceHandle(rt, cast[Il2CppPtr](cRegsRetInt(regs)), t,
                           handles, isObject, gcHandles)
  of asUnknown:
    return "{\"type\":\"" & t & "\"}"

# ---------------------------------------------------------------------------
# Typed frame shapes (ABI revision 4)
# ---------------------------------------------------------------------------
#
# The JSON path asks the runtime what every argument is on *every* firing:
# `typeName` on each parameter, `classFromType` and `classIsValueType` for
# anything it does not recognise by name, `gcHandleNew` for every reference. On
# a method the game runs per bot per frame that is the whole cost.
#
# None of it can change between firings. A method's declared signature is fixed
# when the assembly is compiled, so the answers are worked out once, here, at
# registration -- and the firing path becomes six stores into a pooled frame.
#
# The kinds are the wire values of `AowlArgKind` in `abi/aowlspt_frame.h`, held
# as bytes because that is what the frame points at.

const
  AkNone* = 0'u8
  AkInt* = 1'u8
  AkFloat* = 2'u8
  AkDouble* = 3'u8
  AkObject* = 4'u8
  AkValue* = 5'u8
  AkBigValue* = 6'u8
  AkVoid* = 7'u8
  AkStack* = 8'u8
  AkUnknown* = 9'u8

proc argKindOf*(rt: Il2Cpp; t: Il2CppType): uint8 =
  ## What one declared type is, as a register-file classification.
  ##
  ## By name where the name is decisive and by `shapeOfType` otherwise, which is
  ## the same split `describeArgs` makes and for the same reason: "anything I do
  ## not recognise is a reference" hands the collector an enum's integer value as
  ## if it were an object.
  ##
  ## `System.String` is an object here rather than a string. The JSON path reads
  ## the characters out because it has to produce text; a typed handler is given
  ## the address and may do as it likes with it, which is both cheaper and more
  ## honest -- reading a managed string allocates, and this path does not.
  let n = typeName(rt, t)
  if n == "System.Void": return AkVoid
  if n == "System.Single": return AkFloat
  if n == "System.Double": return AkDouble
  if n == "System.Boolean" or n == "System.Char": return AkInt
  if isIntegerType(n) or isLongType(n): return AkInt
  if n == "System.String": return AkObject
  var bytes = 0
  case shapeOfType(rt, t, bytes)
  of asValueSmall: result = AkValue
  of asValueBig: result = AkBigValue
  of asReference: result = AkObject
  of asUnknown: result = AkUnknown

proc frameKinds*(rt: Il2Cpp; m: Il2CppMethod): seq[uint8] =
  ## One byte per **declared** parameter, in declaration order.
  ##
  ## Parameters past the fourth register position are `AkStack`: named rather
  ## than dropped, so that argument *n* is always declared parameter *n*
  ## whatever the method's shape. `describeArgs` used to stop early instead,
  ## which meant the two paths described the same method differently; it now
  ## marks the slot the same way and the rule is one rule.
  result = @[]
  let isStatic = methodIsStatic(rt, m)
  let declared = methodParamCount(rt, m)
  for i in 0 ..< declared:
    let pos = (if isStatic: i else: i + 1)
    if pos >= MaxRegArgs:
      result.add AkStack
    else:
      result.add argKindOf(rt, methodParam(rt, m, i))

const PostfixMaxSlots* = 4
  ## Register slots a postfix-patched call may use. Four, because that is what
  ## Win64 passes in registers before it starts using the stack -- and the
  ## postfix thunk `call`s the original from inside its own frame, so a stack
  ## argument would be read from the wrong address. See `aowlspt_detour.h`.

proc postfixSlots*(rt: Il2Cpp; m: Il2CppMethod): int =
  ## How many register slots the *compiled* call uses: `this` where there is
  ## one, the declared arguments, and IL2CPP's trailing `MethodInfo*`.
  ##
  ## The `MethodInfo*` is counted because IL2CPP passes it, and forgetting it is
  ## the difference between a method that fits and one whose last argument lands
  ## on the stack. Counting it makes this conservative by one slot on a build
  ## that somehow does not -- which is the direction to be wrong in.
  result = methodParamCount(rt, m) + 1
  if not methodIsStatic(rt, m):
    result = result + 1

proc postfixRefusal*(rt: Il2Cpp; m: Il2CppMethod; target: string): string =
  ## Empty if this method can carry a postfix; otherwise the sentence to hand
  ## the mod author, naming which of the two shapes stopped it.
  ##
  ## Both refusals are about the thunk having to regain control after the
  ## original rather than tail-jumping into it, and both are silent corruption
  ## if honoured anyway -- a wrong argument or a return value nobody can read.
  ## Refusing is the whole point.
  let rn = typeName(rt, methodReturnType(rt, m))
  if rn != "System.Void":
    var bytes = 0
    if shapeOfType(rt, methodReturnType(rt, m), bytes) == asValueBig:
      return "a postfix on " & target & " is refused: it returns " & rn &
             ", a " & $bytes & "-byte value type, which Win64 returns through " &
             "a caller-allocated buffer rather than in a register. The host " &
             "cannot read that buffer's layout, so a postfix there could " &
             "neither report the result nor replace it -- it would be a patch " &
             "that silently observes nothing. Use a prefix that suppresses, " &
             "or reach the value another way."
  let slots = postfixSlots(rt, m)
  if slots > PostfixMaxSlots:
    return "a postfix on " & target & " is refused: its compiled call uses " &
           $slots & " register slots (" & $methodParamCount(rt, m) &
           " declared argument(s)" &
           (if methodIsStatic(rt, m): "" else: ", plus `this`") &
           ", plus IL2CPP's trailing MethodInfo*), and past " &
           $PostfixMaxSlots & " they arrive on the stack. A postfix has to " &
           "call the original rather than jump to it, and a called original " &
           "would read the thunk's frame where its stack arguments should be. " &
           "A prefix on this method is unaffected."
  result = ""

proc thisOf*(rt: Il2Cpp; m: Il2CppMethod; regs: Il2CppPtr): Il2CppPtr =
  ## The instance a patched method was called on, or nil for a static method.
  if methodIsStatic(rt, m):
    return cast[Il2CppPtr](0)
  result = cast[Il2CppPtr](cRegsInt(regs, 0'i32))

proc applyPatchReturn*(rt: Il2Cpp; m: Il2CppMethod; regs: Il2CppPtr;
                       json: string): bool =
  ## Writes a replacement return value into the saved frame, by the method's
  ## **declared** return type. Returns false when the type is one this cannot
  ## produce, so the caller can refuse the suppression rather than let the
  ## original be skipped and garbage returned in its place -- which would be the
  ## worst outcome available.
  let t = typeName(rt, methodReturnType(rt, m))
  if t == "System.Void":
    cRegsSetRetInt(regs, 0'u64)
    return true
  var values: seq[JsonValue] = @[]
  var err = ""
  # The handler hands back a bare value; wrapping it in an array reuses the one
  # parser rather than growing a second one that can disagree with it.
  if not parseArgs("[" & json & "]", values, err) or values.len != 1:
    return false
  let v = values[0]
  if t == "System.Single":
    if v.kind == jkFloat: cRegsSetRetF32(regs, v.f)
    elif v.kind == jkInt: cRegsSetRetF32(regs, float(v.i))
    else: return false
    return true
  if t == "System.Double":
    if v.kind == jkFloat: cRegsSetRetF64(regs, v.f)
    elif v.kind == jkInt: cRegsSetRetF64(regs, float(v.i))
    else: return false
    return true
  if t == "System.Boolean":
    if v.kind != jkBool: return false
    cRegsSetRetInt(regs, (if v.b: 1'u64 else: 0'u64))
    return true
  if isIntegerType(t) or isLongType(t):
    if v.kind != jkInt: return false
    cRegsSetRetInt(regs, uint64(v.i))
    return true
  if t == "System.String":
    if v.kind == jkNull:
      cRegsSetRetInt(regs, 0'u64)
      return true
    if v.kind != jkString: return false
    cRegsSetRetInt(regs, uint64(cast[uint](newString(rt, v.s))))
    return true
  if v.kind == jkNull:
    cRegsSetRetInt(regs, 0'u64)
    return true
  result = false

proc readField*(rt: Il2Cpp; cls: Il2CppClass; obj: Il2CppObject;
                name: string; handles: var seq[Il2CppPtr];
                isObject: var seq[bool]; gcHandles: var seq[uint32];
                error: var string): string =
  error = ""
  let f = findField(rt, cls, name)
  if f == nil:
    error = "no field " & name
    return ""
  let t = typeName(rt, fieldType(rt, f))
  let cell = cCellNew()
  if cell == nil:
    error = "out of memory"
    return ""
  if obj == nil:
    fieldStaticGetValue(rt, f, cell)
  else:
    fieldGetValue(rt, obj, f, cell)

  var out1 = ""
  if t == "System.Boolean":
    out1 = (if cReadI32(cell) != 0'i32: "true" else: "false")
  elif isIntegerType(t):
    out1 = $int(cReadI32(cell))
  elif isLongType(t):
    out1 = $cReadI64(cell)
  elif t == "System.Single":
    out1 = $cReadF32(cell)
  elif t == "System.Double":
    out1 = $cReadF64(cell)
  elif t == "System.String":
    let sp = cCellGetPtr(cell)
    out1 = (if sp == nil: "null" else: "\"" & readString(rt, sp) & "\"")
  else:
    # Same classification the arguments get, and for the same reason: an enum
    # field read as a reference hands the collector its integer value. The
    # names this branch sees are the ones the tests above did not match, which
    # is every enum in the game.
    var bytes = 0
    case shapeOfType(rt, fieldType(rt, f), bytes)
    of asValueSmall:
      out1 = (if bytes <= 4: $int(cReadI32(cell)) else: $cReadI64(cell))
    of asValueBig:
      # A struct field larger than the cell. `il2cpp_field_get_value` copied
      # it into a buffer whose layout this cannot read without the field's own
      # type walked out, so it is named and refused.
      out1 = "{\"valueType\":\"" & t & "\"}"
    of asReference:
      # A reference field: the same handle treatment a reference return gets,
      # so walking a field chain works exactly like walking a property chain.
      out1 = referenceHandle(rt, cCellGetPtr(cell), t, handles, isObject,
                             gcHandles)
    of asUnknown:
      out1 = "{\"type\":\"" & t & "\"}"
  cCellFree(cell)
  result = out1

proc writeField*(rt: Il2Cpp; cls: Il2CppClass; obj: Il2CppObject;
                 name: string; value: JsonValue; handles: seq[Il2CppPtr];
                 error: var string): bool =
  ## Written by the field's **declared** type, for the same reason arguments
  ## are: the bytes for a float and an int of the same numeric value are not
  ## the same bytes, and nothing downstream would notice the difference until
  ## the game read it.
  error = ""
  let f = findField(rt, cls, name)
  if f == nil:
    error = "no field " & name
    return false
  let t = typeName(rt, fieldType(rt, f))
  let cell = cCellNew()
  if cell == nil:
    error = "out of memory"
    return false

  var ok1 = true
  if t == "System.Boolean":
    if value.kind != jkBool:
      error = "field " & name & " is declared " & t & " but " &
              describe(value.kind) & " was given"
      ok1 = false
    else:
      cCellSetI32(cell, (if value.b: 1'i32 else: 0'i32))
  elif isIntegerType(t):
    if value.kind != jkInt:
      error = "field " & name & " is declared " & t & " but " &
              describe(value.kind) & " was given"
      ok1 = false
    else:
      cCellSetI32(cell, int32(value.i))
  elif isLongType(t):
    if value.kind != jkInt:
      error = "field " & name & " is declared " & t & " but " &
              describe(value.kind) & " was given"
      ok1 = false
    else:
      cCellSetI64(cell, value.i)
  elif t == "System.Single":
    if value.kind == jkFloat: cCellSetF32(cell, value.f)
    elif value.kind == jkInt: cCellSetF32(cell, float(value.i))
    else:
      error = "field " & name & " is declared " & t & " but " &
              describe(value.kind) & " was given"
      ok1 = false
  elif t == "System.Double":
    if value.kind == jkFloat: cCellSetF64(cell, value.f)
    elif value.kind == jkInt: cCellSetF64(cell, float(value.i))
    else:
      error = "field " & name & " is declared " & t & " but " &
              describe(value.kind) & " was given"
      ok1 = false
  elif t == "System.String":
    if value.kind != jkString:
      error = "field " & name & " is declared " & t & " but " &
              describe(value.kind) & " was given"
      ok1 = false
    else:
      cCellSetPtr(cell, newString(rt, value.s))
  elif value.kind == jkInt and valueWidth(rt, fieldType(rt, f)) > 0:
    # An enum field, written from a number -- the other half of the read above,
    # which has classified enums correctly for a while. Writing one required a
    # handle, and there is no handle to a value type, so every enum field in
    # the game was read-only through this API for no reason anyone chose.
    let w = valueWidth(rt, fieldType(rt, f))
    if w <= 4:
      cCellSetI32(cell, int32(value.i))
    elif w <= 8:
      cCellSetI64(cell, value.i)
    else:
      error = "field " & name & " is declared " & t & ", a " & $w &
              "-byte value type; this host can write one of at most 8 bytes " &
              "from a number"
      ok1 = false
  else:
    if value.kind != jkHandle:
      error = "field " & name & " is a " & t &
              "; only a handle can be written to it"
      ok1 = false
    else:
      let idx = int(value.i)
      if idx <= 0 or idx > handles.len:
        error = "no such handle for field " & name
        ok1 = false
      else:
        cCellSetPtr(cell, handles[idx - 1])

  if ok1:
    if obj == nil:
      fieldStaticSetValue(rt, f, cell)
    else:
      fieldSetValue(rt, obj, f, cell)
  cCellFree(cell)
  result = ok1
