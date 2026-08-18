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
    # A reference field: the same handle treatment a reference return gets, so
    # walking a field chain works exactly like walking a property chain.
    let p = cCellGetPtr(cell)
    if p == nil:
      out1 = "null"
    else:
      let gc = gcHandleNew(rt, p, false)
      if gc == 0'u32:
        out1 = "{\"type\":\"" & t & "\"}"
      else:
        handles.add cast[Il2CppPtr](0)
        isObject.add true
        gcHandles.add gc
        out1 = "{\"handle\":" & $handles.len & ",\"type\":\"" & t & "\"}"
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
