## Bindings to the IL2CPP runtime C API, as exported by `GameAssembly.dll`.
##
## This module is the reason aowlspt can reach a post-1.0 Tarkov client at all,
## so it is worth being explicit about why it exists and why it looks like this.
##
## Post-1.0 Tarkov is IL2CPP: the C# was translated to C++ ahead of time and
## there are no managed assemblies left to load a plugin into. The usual answer
## is a stack that reconstructs the managed world -- BepInEx 6 IL2CPP runs a
## CoreCLR inside the process, Cpp2IL rebuilds proxy assemblies out of the
## metadata, and Il2CppInterop marshals between the two. It works, and it is an
## enormous amount of machinery to arrive back where you started.
##
## None of it is necessary. Unity's IL2CPP runtime exports its own C API from
## `GameAssembly.dll` -- 242 functions, by name, unmangled -- and that API is
## the exact shape aowlspt's ABI already wanted: look a type up by name, look a
## method up on it, invoke it with an argument array. So the post-1.0 client
## host calls the runtime directly. No second runtime in the process, no
## generated assemblies, no interop layer, and the host is written in the same
## language as the mods it hosts.
##
## **Why the indirect calls go through C.** nimony will not `cast` between a
## `pointer` and a `proc` type -- in either direction, and via an integer as
## well. That rules out the ordinary shape for this, which is a record of
## function pointers filled in by `GetProcAddress`. Rather than give up the
## runtime symbol resolution (which is not optional: inside the game the module
## is already loaded, and out of it the path is only known to the caller), the
## indirect call is done in `abi/aowlspt_shim.h`, one trampoline per distinct
## signature. There are eighteen of them and they are each one line. Compile with
## `--passC:-I<repo>/abi`.
##
## **What this module deliberately does not do:** it does not read
## `global-metadata.dat`. BSG ship that file encrypted and the runtime decrypts
## it for itself during `il2cpp_init`. Going around that would be breaking a
## protection rather than using an interface, so everything here goes in through
## the runtime's own front door and sees exactly what the runtime chose to
## expose.

import std/windows/winlean
import std/widestrs

type
  ## Every IL2CPP handle is an opaque pointer. They are distinguished by name
  ## for the reader's benefit; the compiler treats them all alike.
  Il2CppPtr* = nil pointer

  Il2CppDomain* = Il2CppPtr
  Il2CppAssembly* = Il2CppPtr
  Il2CppImage* = Il2CppPtr
  Il2CppClass* = Il2CppPtr
  Il2CppObject* = Il2CppPtr
  Il2CppMethod* = Il2CppPtr      ## `MethodInfo*`
  Il2CppField* = Il2CppPtr       ## `FieldInfo*`
  Il2CppProperty* = Il2CppPtr    ## `PropertyInfo*`
  Il2CppType* = Il2CppPtr
  Il2CppString* = Il2CppPtr
  Il2CppThread* = Il2CppPtr
  Il2CppException* = Il2CppPtr

  ## Cursor for the `il2cpp_*_get_*` enumerators, which each take a `void**`
  ## initialised to null and advance it.
  Il2CppIter* = Il2CppPtr

proc nullPtr*(): Il2CppPtr {.inline.} =
  result = cast[Il2CppPtr](0)

proc isNull*(p: Il2CppPtr): bool {.inline.} =
  result = p == nil

# ---------------------------------------------------------------------------
# Trampolines
# ---------------------------------------------------------------------------

{.emit: """#include "aowlspt_shim.h" """.}
## The SHAPE half of `gatedHandle` below. In a header of its own, with no
## <windows.h> and no host types, so `tools/test_handleshape.py` can compile
## and RUN it -- an untested safety rule is a comment. The shipped code and
## the tested code are the same function; that is the point of the split.
{.emit: """#include "aowlspt_handle.h" """.}

proc tpV(f: Il2CppPtr): Il2CppPtr {.importc: "aowl_p_v", nodecl.}
proc tpP(f, a: Il2CppPtr): Il2CppPtr {.importc: "aowl_p_p", nodecl.}
proc tpPP(f, a, b: Il2CppPtr): Il2CppPtr {.importc: "aowl_p_pp", nodecl.}
proc tpPPP(f, a, b, c: Il2CppPtr): Il2CppPtr {.importc: "aowl_p_ppp", nodecl.}
proc tpPPPP(f, a, b, c, d: Il2CppPtr): Il2CppPtr {.importc: "aowl_p_pppp", nodecl.}
proc tpPPI(f, a, b: Il2CppPtr; i: int32): Il2CppPtr {.importc: "aowl_p_ppi", nodecl.}
proc tpPZ(f, a: Il2CppPtr; z: uint64): Il2CppPtr {.importc: "aowl_p_pz", nodecl.}
proc tpU(f: Il2CppPtr; u: uint32): Il2CppPtr {.importc: "aowl_p_u", nodecl.}

proc tvV(f: Il2CppPtr) {.importc: "aowl_v_v", nodecl.}
proc tvP(f, a: Il2CppPtr) {.importc: "aowl_v_p", nodecl.}
proc tvPP(f, a, b: Il2CppPtr) {.importc: "aowl_v_pp", nodecl.}
proc tvPPP(f, a, b, c: Il2CppPtr) {.importc: "aowl_v_ppp", nodecl.}
proc tvU(f: Il2CppPtr; u: uint32) {.importc: "aowl_v_u", nodecl.}

proc ti32P(f, a: Il2CppPtr): int32 {.importc: "aowl_i32_p", nodecl.}
proc tu32P(f, a: Il2CppPtr): uint32 {.importc: "aowl_u32_p", nodecl.}
proc tzP(f, a: Il2CppPtr): uint64 {.importc: "aowl_z_p", nodecl.}
proc tu32PI(f, a: Il2CppPtr; i: int32): uint32 {.importc: "aowl_u32_pi", nodecl.}
proc tu32PP(f, a, b: Il2CppPtr): uint32 {.importc: "aowl_u32_pp", nodecl.}

proc byteAt(p: Il2CppPtr; i: uint64): uint8 {.importc: "aowl_byte_at", nodecl.}
proc readPtr(p: Il2CppPtr; off: int32): Il2CppPtr {.
  importc: "aowl_read_ptr", nodecl.}
proc isCodePtr(p: Il2CppPtr): int32 {.
  importc: "aowl_is_code_pointer", nodecl.}
proc isReadable(p: Il2CppPtr; size: int32): int32 {.
  importc: "aowl_is_readable", nodecl.}
proc handleShapeOk(v: uint64): int32 {.
  importc: "aowl_handle_shape_ok", nodecl.}
proc wordAt(p: Il2CppPtr; i: uint64): uint16 {.importc: "aowl_word_at", nodecl.}

# ---------------------------------------------------------------------------
# The entry point table
# ---------------------------------------------------------------------------

type
  Entry* = enum
    eSetDataDir, eSetConfigDir, eInit, eShutdown,
    eDomainGet, eDomainGetAssemblies, eAssemblyGetImage,
    eImageGetName, eImageGetClassCount, eImageGetClass,
    eClassFromName, eClassGetName, eClassGetNamespace, eClassGetParent,
    eClassGetMethods, eClassGetFields, eClassGetProperties,
    eClassGetMethodFromName, eClassGetFieldFromName, eClassGetPropertyFromName,
    eClassGetType, eClassIsValuetype, eClassInstanceSize, eRuntimeClassInit,
    eMethodGetName, eMethodGetParamCount, eMethodGetReturnType,
    eMethodGetParam, eMethodGetClass,
    eFieldGetName, eFieldGetType, eFieldGetOffset,
    eFieldGetValue, eFieldSetValue, eFieldStaticGetValue, eFieldStaticSetValue,
    ePropertyGetName, ePropertyGetGetMethod, ePropertyGetSetMethod,
    eRuntimeInvoke, eObjectNew, eRuntimeObjectInit, eObjectGetClass,
    eValueBox, eObjectUnbox,
    eStringNew, eStringChars, eStringLength,
    eTypeGetName, eTypeGetObject,
    eThreadAttach, eThreadDetach, eThreadCurrent,
    eGcHandleNew, eGcHandleGetTarget, eGcHandleFree,
    eFree,
    ## Appended in one group, for the same reason as `eMethodGetFlags` below:
    ## the enum's order is `EntryNames`' order, and inserting renames every
    ## entry after the insertion point without touching a line of this file.
    eClassFromType, eFieldGetFlags, eClassStaticFieldData, eGcWriteBarrier,
    ## Appended rather than inserted: the enum's order is the order of
    ## `EntryNames`, and moving an existing member renames every entry
    ## after it without changing a line of this file.
    eMethodGetFlags,
    ## Managed-array construction, appended for the same append-only reason.
    ## `il2cpp_array_new(elementClass, length)` returns an `Il2CppArray*`; it is
    ## what lets a mod hand a `byte[]` to a managed method — e.g. building the
    ## replacement image bytes for `ImageConversion.LoadImage` (see
    ## `mods/textures`). Not `Essential`: a mod that never constructs an array
    ## does not need it, and a build that stripped it is still hostable.
    eArrayNew,
    ## Appended, again, rather than inserted -- same append-only reason. These
    ## two are the runtime half of the codeGenModule code-pointer fallback (see
    ## `abi/aowlspt_codegen.h`): with them the walk from a `MethodInfo*` to its
    ## declaring image's NAME and to its metadata TOKEN needs no guessed struct
    ## offset for `MethodInfo`, `Il2CppClass` or `Il2CppImage`. Both were
    ## confirmed present in `GameAssembly.dll`'s export directory for build
    ## 1.1.0.1.46777 (386 exports) before being added here. Not `Essential`:
    ## a build without them simply loses the fallback.
    eClassGetImage, eMethodGetToken

const NumEntries* = 65

const EntryNames*: array[NumEntries, string] = [
  "il2cpp_set_data_dir", "il2cpp_set_config_dir", "il2cpp_init",
  "il2cpp_shutdown",
  "il2cpp_domain_get", "il2cpp_domain_get_assemblies",
  "il2cpp_assembly_get_image",
  "il2cpp_image_get_name", "il2cpp_image_get_class_count",
  "il2cpp_image_get_class",
  "il2cpp_class_from_name", "il2cpp_class_get_name",
  "il2cpp_class_get_namespace", "il2cpp_class_get_parent",
  "il2cpp_class_get_methods", "il2cpp_class_get_fields",
  "il2cpp_class_get_properties",
  "il2cpp_class_get_method_from_name", "il2cpp_class_get_field_from_name",
  "il2cpp_class_get_property_from_name",
  "il2cpp_class_get_type", "il2cpp_class_is_valuetype",
  "il2cpp_class_instance_size", "il2cpp_runtime_class_init",
  "il2cpp_method_get_name", "il2cpp_method_get_param_count",
  "il2cpp_method_get_return_type", "il2cpp_method_get_param",
  "il2cpp_method_get_class",
  "il2cpp_field_get_name", "il2cpp_field_get_type", "il2cpp_field_get_offset",
  "il2cpp_field_get_value", "il2cpp_field_set_value",
  "il2cpp_field_static_get_value", "il2cpp_field_static_set_value",
  "il2cpp_property_get_name", "il2cpp_property_get_get_method",
  "il2cpp_property_get_set_method",
  "il2cpp_runtime_invoke", "il2cpp_object_new", "il2cpp_runtime_object_init",
  "il2cpp_object_get_class", "il2cpp_value_box", "il2cpp_object_unbox",
  "il2cpp_string_new", "il2cpp_string_chars", "il2cpp_string_length",
  "il2cpp_type_get_name", "il2cpp_type_get_object",
  "il2cpp_thread_attach", "il2cpp_thread_detach", "il2cpp_thread_current",
  "il2cpp_gchandle_new", "il2cpp_gchandle_get_target", "il2cpp_gchandle_free",
  "il2cpp_free",
  "il2cpp_class_from_il2cpp_type", "il2cpp_field_get_flags",
  "il2cpp_class_get_static_field_data", "il2cpp_gc_wbarrier_set_field",
  "il2cpp_method_get_flags",
  "il2cpp_array_new",
  "il2cpp_class_get_image", "il2cpp_method_get_token"
]

## The entry points the host cannot work without, as opposed to the ones it
## would merely like to have. Separated so a Unity version that dropped
## something cosmetic is not confused with one that cannot host a mod at all.
const Essential*: array[9, Entry] = [
  eDomainGet, eDomainGetAssemblies, eAssemblyGetImage,
  eClassFromName, eClassGetMethodFromName, eClassGetFieldFromName,
  eRuntimeInvoke, eStringNew, eThreadAttach
]

type
  Il2Cpp* = object
    handle*: Il2CppPtr
    loaded*: bool
    lastError*: int32
    ## Indexed by `ord(Entry)`. nimony has neither enum-indexed arrays nor
    ## iteration over an enum type, so the ordinal is used directly and
    ## `EntryNames` is kept in the same order by construction.
    fns*: array[NumEntries, Il2CppPtr]
    missing*: seq[string]

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

proc getModuleHandleW(name: WideCString): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetModuleHandleW", sideEffect.}
proc loadLibraryExW(name: WideCString; reserved: Il2CppPtr;
                    flags: uint32): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "LoadLibraryExW", sideEffect.}
proc getLastErrorCode(): int32 {.
  stdcall, dynlib: "kernel32", importc: "GetLastError", sideEffect.}
proc getProcAddress(module: Il2CppPtr; name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetProcAddress", sideEffect.}

proc toWide(s: string): WideCStringObj =
  var t = s
  result = newWideCString(t)

proc has*(rt: Il2Cpp; e: Entry): bool {.inline.} =
  result = rt.fns[ord(e)] != nil

proc openIl2Cpp*(path: string = ""): Il2Cpp =
  ## Binds to the IL2CPP runtime.
  ##
  ## With no path the already-loaded `GameAssembly.dll` is used, which is the
  ## in-game case and the only correct one there. With a path the module is
  ## loaded, which is for out-of-process tooling.
  result = Il2Cpp(handle: cast[Il2CppPtr](0), loaded: false, lastError: 0'i32,
                  missing: @[])
  for i in 0 ..< NumEntries:
    result.fns[i] = cast[Il2CppPtr](0)

  if path.len == 0:
    let w = toWide("GameAssembly.dll")
    result.handle = getModuleHandleW(w.toWideCString)
  else:
    # LOAD_WITH_ALTERED_SEARCH_PATH. `GameAssembly.dll` imports `UnityPlayer.dll`
    # and `baselib.dll` from beside itself, and a plain LoadLibraryW resolves
    # those against the *caller's* directory -- so loading a game module from
    # anywhere else fails with a "module not found" that names the wrong module.
    let w = toWide(path)
    result.handle = loadLibraryExW(w.toWideCString, cast[Il2CppPtr](0),
                                   0x00000008'u32)

  if result.handle == nil:
    result.lastError = getLastErrorCode()
    return

  for i in 0 ..< NumEntries:
    var name = EntryNames[i]
    let p = getProcAddress(result.handle, toCString(name))
    result.fns[i] = p
    if p == nil:
      result.missing.add name

  result.loaded = true

proc missingEssential*(rt: Il2Cpp): seq[string] =
  result = @[]
  for e in Essential:
    if not rt.has(e):
      result.add EntryNames[ord(e)]

# ---------------------------------------------------------------------------
# Handles that came out of a TOKEN-GATED export
# ---------------------------------------------------------------------------

var gGatedHandleRefusals* = 0
  ## How many handles `gatedHandle` REFUSED. Counted rather than assumed: "the
  ## filter is working" and "the trap never fired" answer identically from
  ## outside, and only this counter tells them apart.

var gGatedHandleLastValue* = 0'u64
  ## The VALUE of the most recent refusal, and `gGatedHandleLastWhy` says which
  ## filter rejected it.
  ##
  ## These exist because the first version of this filter had only the counter
  ## above, and nobody prints a counter. MEASURED 2026-09-02 19:46: it refused
  ## every per-frame drain candidate, the main-thread drain never bound, queued
  ## work was held for 28 minutes, and the only thing the log said was "no
  ## per-frame candidate UnityEngine.UI.CanvasUpdateRegistry in this build" --
  ## which is a sentence about the BUILD and was not true. A refusal that does
  ## not say what it refused is the silent decline this repo treats as the
  ## worst outcome available; it cost a whole boot to work out by hand.
  ##
  ## Cheap by construction: two stores on a path that is already returning nil,
  ## and nothing at all on the accepting path.

var gGatedHandleLastWhy* = ""
  ## "non-canonical/misaligned" or "not readable". See above.

proc gatedHandle(p: Il2CppPtr): Il2CppPtr =
  ## The HANDLE half of the defence `readCString` (below) already applies to
  ## strings, and the half that was missing.
  ##
  ## MEASURED 2026-09-02, Unity crash report `Crash_2026-09-02_224920325`,
  ## host build sha256 350dba69, ~10 s after boot, on the Unity drain thread:
  ##
  ##   aowl_thunk_common+0x66      the PREFIX dispatch return address
  ##     -> ... -> bridgeProof+0x105 -> valueBox+0x1b -> GameAssembly, 0xC0000005
  ##   RCX = 0x6e11f7fc349b3101    the Il2CppClass* argument to il2cpp_value_box
  ##   RDX = 0x000001ed62c8c1f0    a real, readable cell
  ##
  ## `bridgeProof` had done `findClass(gRt, "System.Int32")`, and the byte at
  ## that boxing call site is `movl $0x67932,(%rax)` -- 424242 decimal, which
  ## is `cCellSetI32(cell, 424242)` exactly, so the class handle was the one
  ## thing wrong. `il2cpp_class_from_name` is `AOWL_GATE_KIND_NONCE` in
  ## `abi/aowlspt_il2cpp_gates_data.h`: called with the stock signature it
  ## returns MT19937-64 output, always NON-ZERO, so `c != nil` passed.
  ##
  ## THREE INDEPENDENT FILTERS, each of which CAN fail on real input:
  ##
  ##   1. Canonical address. Every Win64 user-mode pointer has bits 47..63
  ##      clear. A uniform random 64-bit value does not, with probability
  ##      1 - 2^-17. The observed 0x6e11f7fc349b3101 fails here.
  ##   2. Alignment. Every IL2CPP metadata record is at least pointer-aligned.
  ##      A random value is not, seven times in eight. The observed value ends
  ##      in 0x01 and fails here too.
  ##
  ##      1 and 2 are `aowl_handle_shape_ok` in `abi/aowlspt_handle.h`, which
  ##      is where they are so that `tools/test_handleshape.py` can compile and
  ##      run them offline against both controls.
  ##   3. Committed and readable, by VirtualQuery -- the same call
  ##      `readCString` makes -- over 0x10 bytes. 0x10 and not more: the
  ##      SMALLEST record reached through here is `Il2CppType` (8 bytes of
  ##      `data` plus a 4-byte bitfield, padded to 16), and demanding 0x20
  ##      would REFUSE a real one that legitimately sits in the last 24 bytes
  ##      of its region -- a silent decline, which is the outcome this repo
  ##      treats as worse than a loud failure.
  ##
  ## This is a REFUSAL, NOT A GUARANTEE, in exactly the sense `readCString`
  ## states below: it narrows a certain crash to an improbable one. It does not
  ## make a gated export safe to call. The only thing that does is
  ## `aowl_host_gate_call` with a real token.
  ##
  ## Returning nil is the safe direction because every caller here, and every
  ## caller of those callers, already branches on nil -- that is the "the
  ## runtime did not answer" path they take when the export is simply absent.
  result = nullPtr()
  if p == nil:
    return
  # Filters 1 and 2 live in `abi/aowlspt_handle.h` and are exercised offline by
  # `tools/test_handleshape.py` -- including the negative control that matters,
  # 200,000 uniform random 64-bit values, of which it accepted 0.
  if handleShapeOk(cast[uint64](p)) == 0'i32:
    gGatedHandleRefusals = gGatedHandleRefusals + 1
    gGatedHandleLastValue = cast[uint64](p)
    gGatedHandleLastWhy = "non-canonical or misaligned"
    return
  # Filter 3 needs the OS, which is why it is here and not in that header.
  if isReadable(p, 0x10'i32) == 0'i32:
    gGatedHandleRefusals = gGatedHandleRefusals + 1
    gGatedHandleLastValue = cast[uint64](p)
    gGatedHandleLastWhy = "canonical and aligned, but not readable memory"
    return
  result = p

# ---------------------------------------------------------------------------
# Strings
# ---------------------------------------------------------------------------

var gReadCStringRefusals* = 0
  ## How many times `readCString` REFUSED a pointer. Non-zero means something
  ## handed it a value that is not a string; see the comment below for why
  ## that is the expected failure mode rather than a nil.

proc readCStringPlausible(b: uint8): bool =
  ## Every string this proc is ever asked for is an IL2CPP name (class,
  ## namespace, method, field, property, image) or one of the host's own
  ## static ASCII buffers. None of them contain a byte outside printable
  ## ASCII plus tab/CR/LF.
  result = b == 0x09'u8 or b == 0x0a'u8 or b == 0x0d'u8 or
           (b >= 0x20'u8 and b <= 0x7e'u8)

proc readCString*(p: Il2CppPtr): string =
  ## Copies a NUL-terminated ASCII string the runtime owns -- or REFUSES.
  ##
  ## **THE NIL CHECK BELOW CANNOT FIRE FOR THE CASE THAT KILLED THE CLIENT,
  ## AND THAT IS WHY THE REST OF THIS PROC EXISTS.** Measured (fact #198,
  ## `docs/IL2CPP_EXPORTS.md`): 38 of the 241 `il2cpp_*` exports are
  ## TOKEN-GATED -- they take a trailing 32-byte token argument the stock
  ## signature does not have and `memcmp` it before doing any work. On
  ## mismatch they do not return NULL and do not abort: they tail-call a trap
  ## that seeds a per-thread MT19937-64 and returns a uniform random
  ## **non-zero** uint64. `il2cpp_class_get_name` is one of them. So `p != nil`
  ## passes, the first `byteAt` dereferences a random address, and the process
  ## dies with 0xC0000005 -- which is exactly what took the client down at
  ## 10:30:54 through `fov`'s `bindOnObject -> fullName -> className` chain,
  ## faulting at +0x31 inside this loop.
  ##
  ## A nil check is therefore not a check. What follows is: a VirtualQuery on
  ## the pointer (a random 64-bit address is overwhelmingly not committed
  ## readable memory) re-run at every page-sized step, and a printable-ASCII
  ## gate on every byte (a random address that IS mapped is overwhelmingly not
  ## an ASCII identifier). Both can fail on real input and both say so by
  ## returning "" and bumping `gReadCStringRefusals`, which every caller
  ## already treats as "the runtime did not answer" -- `className`,
  ## `classNamespace`, `methodName`, `fieldName`, `propertyName`, `imageName`
  ## and `typeName` all return "" when the export is simply absent.
  ##
  ## This is a refusal, not a guarantee. It narrows a certain crash to an
  ## unlikely one; it does not make a gated export safe to call.
  result = ""
  if p == nil:
    return
  # One byte, not a fixed span: a short name legitimately sits at the tail of
  # a committed region, and demanding N readable bytes would REFUSE it. The
  # page-boundary re-check below is what keeps that sound -- VirtualQuery
  # approves a whole region, so the only way a walk leaves approved memory is
  # by crossing into the next page.
  const Page = 0x1000'u64
  if isReadable(p, 1'i32) == 0'i32:
    gReadCStringRefusals = gReadCStringRefusals + 1
    return
  let base = cast[uint64](p)
  var i = 0'u64
  while true:
    if i > 0'u64 and ((base + i) mod Page) == 0'u64:
      # Every hop re-checked, not just the first.
      if isReadable(cast[Il2CppPtr](base + i), 1'i32) == 0'i32:
        gReadCStringRefusals = gReadCStringRefusals + 1
        result = ""
        return
    let b = byteAt(p, i)
    if b == 0'u8:
      break
    if not readCStringPlausible(b):
      gReadCStringRefusals = gReadCStringRefusals + 1
      result = ""
      return
    result.add char(b)
    i = i + 1'u64
    if i > 4096'u64:   # a runaway read means the pointer was not a string
      gReadCStringRefusals = gReadCStringRefusals + 1
      result = ""
      return

# ---------------------------------------------------------------------------
# The typed API
# ---------------------------------------------------------------------------

proc setDataDir*(rt: Il2Cpp; dir: string) =
  if not rt.has(eSetDataDir): return
  var d = dir
  tvP(rt.fns[ord(eSetDataDir)], cast[Il2CppPtr](toCString(d)))

proc setConfigDir*(rt: Il2Cpp; dir: string) =
  if not rt.has(eSetConfigDir): return
  var d = dir
  tvP(rt.fns[ord(eSetConfigDir)], cast[Il2CppPtr](toCString(d)))

proc init*(rt: Il2Cpp; domainName: string): Il2CppDomain =
  if not rt.has(eInit): return nullPtr()
  var n = domainName
  result = tpP(rt.fns[ord(eInit)], cast[Il2CppPtr](toCString(n)))

proc shutdown*(rt: Il2Cpp) =
  if not rt.has(eShutdown): return
  tvV(rt.fns[ord(eShutdown)])

proc domainGet*(rt: Il2Cpp): Il2CppDomain =
  if not rt.has(eDomainGet): return nullPtr()
  result = tpV(rt.fns[ord(eDomainGet)])

proc domainGetAssemblies*(rt: Il2Cpp; domain: Il2CppDomain;
                          count: var int): Il2CppPtr =
  ## Returns the raw `Il2CppAssembly**`; use `assemblyAt` to index it.
  count = 0
  if not rt.has(eDomainGetAssemblies): return nullPtr()
  var size = 0'u64
  result = tpPP(rt.fns[ord(eDomainGetAssemblies)], domain,
                cast[Il2CppPtr](addr size))
  count = int(size)

proc assemblyAt*(assemblies: Il2CppPtr; index: int): Il2CppAssembly =
  ## Indexes the `Il2CppAssembly**` returned above. A pointer array, so the
  ## stride is one pointer.
  if assemblies == nil:
    return nullPtr()
  var v = 0'u64
  for b in 0 ..< 8:
    v = v or (uint64(byteAt(assemblies, uint64(index * 8 + b))) shl (b * 8))
  result = cast[Il2CppPtr](v)

proc assemblyGetImage*(rt: Il2Cpp; a: Il2CppAssembly): Il2CppImage =
  if not rt.has(eAssemblyGetImage): return nullPtr()
  result = tpP(rt.fns[ord(eAssemblyGetImage)], a)

proc imageGetName*(rt: Il2Cpp; i: Il2CppImage): string =
  if not rt.has(eImageGetName): return ""
  result = readCString(tpP(rt.fns[ord(eImageGetName)], i))

proc imageGetClassCount*(rt: Il2Cpp; i: Il2CppImage): int =
  if not rt.has(eImageGetClassCount): return 0
  result = int(tzP(rt.fns[ord(eImageGetClassCount)], i))

proc imageGetClass*(rt: Il2Cpp; i: Il2CppImage; index: int): Il2CppClass =
  if not rt.has(eImageGetClass): return nullPtr()
  result = tpPZ(rt.fns[ord(eImageGetClass)], i, uint64(index))

proc methodClass*(rt: Il2Cpp; m: Il2CppMethod): Il2CppClass =
  ## The type a method was declared on. `il2cpp_method_get_class` is an
  ## exported entry point, so this is an interface call rather than a read of
  ## `MethodInfo.klass` at an assumed offset.
  if not rt.has(eMethodGetClass): return nullPtr()
  if m == nil: return nullPtr()
  result = gatedHandle(tpP(rt.fns[ord(eMethodGetClass)], m))

proc classGetImage*(rt: Il2Cpp; c: Il2CppClass): Il2CppImage =
  ## The assembly image a class was defined in. Exported by the runtime, so this
  ## is an interface call and not a struct-offset read -- which matters, because
  ## it is the hop the codeGenModule code-pointer fallback needs and a guessed
  ## `Il2CppClass.image` offset would be exactly the kind of coin flip this
  ## project refuses.
  if not rt.has(eClassGetImage): return nullPtr()
  result = tpP(rt.fns[ord(eClassGetImage)], c)

proc methodToken*(rt: Il2Cpp; m: Il2CppMethod): uint32 =
  ## A method's metadata token. `token and 0xFFFFFF` is its RID within its own
  ## image, which is the index (minus one) into that image's
  ## `Il2CppCodeGenModule.methodPointers`. Zero means unavailable.
  ##
  ## Called through a uint32-returning trampoline rather than the size_t one:
  ## the high half of RAX is unspecified for a uint32-returning callee, so
  ## reading it as a size_t can bring garbage back in the top 32 bits.
  if not rt.has(eMethodGetToken): return 0'u32
  if m == nil: return 0'u32
  result = tu32P(rt.fns[ord(eMethodGetToken)], m)

proc classFromName*(rt: Il2Cpp; image: Il2CppImage;
                    ns, name: string): Il2CppClass =
  if not rt.has(eClassFromName): return nullPtr()
  var n1 = ns
  var n2 = name
  result = gatedHandle(tpPPP(rt.fns[ord(eClassFromName)], image,
                             cast[Il2CppPtr](toCString(n1)),
                             cast[Il2CppPtr](toCString(n2))))

proc className*(rt: Il2Cpp; c: Il2CppClass): string =
  if not rt.has(eClassGetName): return ""
  result = readCString(tpP(rt.fns[ord(eClassGetName)], c))

proc tpPSeh(f, a: Il2CppPtr): Il2CppPtr {.importc: "aowl_p_p_seh", nodecl.}
proc classNameSafe*(rt: Il2Cpp; c: Il2CppClass): string =
  ## `className` that returns "" instead of faulting when `c` is a class handed
  ## back by a blind enumeration that is not safe to dereference. For scanning
  ## every class in an image to find one by name; see the host's key dump.
  if not rt.has(eClassGetName): return ""
  let p = tpPSeh(rt.fns[ord(eClassGetName)], c)
  if p == nullPtr(): return ""
  result = readCString(p)

proc classNamespace*(rt: Il2Cpp; c: Il2CppClass): string =
  if not rt.has(eClassGetNamespace): return ""
  result = readCString(tpP(rt.fns[ord(eClassGetNamespace)], c))

proc classParent*(rt: Il2Cpp; c: Il2CppClass): Il2CppClass =
  if not rt.has(eClassGetParent): return nullPtr()
  result = gatedHandle(tpP(rt.fns[ord(eClassGetParent)], c))

proc nextMethod*(rt: Il2Cpp; c: Il2CppClass; iter: var Il2CppIter): Il2CppMethod =
  if not rt.has(eClassGetMethods): return nullPtr()
  result = tpPP(rt.fns[ord(eClassGetMethods)], c, cast[Il2CppPtr](addr iter))

proc nextField*(rt: Il2Cpp; c: Il2CppClass; iter: var Il2CppIter): Il2CppField =
  if not rt.has(eClassGetFields): return nullPtr()
  result = gatedHandle(tpPP(rt.fns[ord(eClassGetFields)], c,
                            cast[Il2CppPtr](addr iter)))

proc nextProperty*(rt: Il2Cpp; c: Il2CppClass;
                   iter: var Il2CppIter): Il2CppProperty =
  if not rt.has(eClassGetProperties): return nullPtr()
  result = tpPP(rt.fns[ord(eClassGetProperties)], c, cast[Il2CppPtr](addr iter))

proc findMethod*(rt: Il2Cpp; c: Il2CppClass; name: string;
                 argc: int): Il2CppMethod =
  if not rt.has(eClassGetMethodFromName): return nullPtr()
  var n = name
  result = gatedHandle(tpPPI(rt.fns[ord(eClassGetMethodFromName)], c,
                             cast[Il2CppPtr](toCString(n)), int32(argc)))

proc findField*(rt: Il2Cpp; c: Il2CppClass; name: string): Il2CppField =
  if not rt.has(eClassGetFieldFromName): return nullPtr()
  var n = name
  result = gatedHandle(tpPP(rt.fns[ord(eClassGetFieldFromName)], c,
                            cast[Il2CppPtr](toCString(n))))

proc findProperty*(rt: Il2Cpp; c: Il2CppClass; name: string): Il2CppProperty =
  if not rt.has(eClassGetPropertyFromName): return nullPtr()
  var n = name
  result = gatedHandle(tpPP(rt.fns[ord(eClassGetPropertyFromName)], c,
                            cast[Il2CppPtr](toCString(n))))

proc classType*(rt: Il2Cpp; c: Il2CppClass): Il2CppType =
  if not rt.has(eClassGetType): return nullPtr()
  result = gatedHandle(tpP(rt.fns[ord(eClassGetType)], c))

proc classIsValueType*(rt: Il2Cpp; c: Il2CppClass): bool =
  if not rt.has(eClassIsValuetype): return false
  result = ti32P(rt.fns[ord(eClassIsValuetype)], c) != 0'i32

proc classInstanceSize*(rt: Il2Cpp; c: Il2CppClass): int =
  if not rt.has(eClassInstanceSize): return 0
  result = int(ti32P(rt.fns[ord(eClassInstanceSize)], c))

proc runtimeClassInit*(rt: Il2Cpp; c: Il2CppClass) =
  if not rt.has(eRuntimeClassInit): return
  tvP(rt.fns[ord(eRuntimeClassInit)], c)

proc methodName*(rt: Il2Cpp; m: Il2CppMethod): string =
  if not rt.has(eMethodGetName): return ""
  result = readCString(tpP(rt.fns[ord(eMethodGetName)], m))

proc methodParamCount*(rt: Il2Cpp; m: Il2CppMethod): int =
  if not rt.has(eMethodGetParamCount): return 0
  result = int(tu32P(rt.fns[ord(eMethodGetParamCount)], m))

proc methodReturnType*(rt: Il2Cpp; m: Il2CppMethod): Il2CppType =
  if not rt.has(eMethodGetReturnType): return nullPtr()
  result = gatedHandle(tpP(rt.fns[ord(eMethodGetReturnType)], m))

proc methodParam*(rt: Il2Cpp; m: Il2CppMethod; index: int): Il2CppType =
  if not rt.has(eMethodGetParam): return nullPtr()
  result = gatedHandle(tpPZ(rt.fns[ord(eMethodGetParam)], m, uint64(index)))

proc fieldName*(rt: Il2Cpp; f: Il2CppField): string =
  if not rt.has(eFieldGetName): return ""
  result = readCString(tpP(rt.fns[ord(eFieldGetName)], f))

proc fieldType*(rt: Il2Cpp; f: Il2CppField): Il2CppType =
  if not rt.has(eFieldGetType): return nullPtr()
  result = gatedHandle(tpP(rt.fns[ord(eFieldGetType)], f))

proc fieldOffset*(rt: Il2Cpp; f: Il2CppField): int =
  if not rt.has(eFieldGetOffset): return -1
  result = int(tzP(rt.fns[ord(eFieldGetOffset)], f))

proc fieldGetValue*(rt: Il2Cpp; obj: Il2CppObject; f: Il2CppField;
                    into: Il2CppPtr) =
  if not rt.has(eFieldGetValue): return
  tvPPP(rt.fns[ord(eFieldGetValue)], obj, f, into)

proc fieldSetValue*(rt: Il2Cpp; obj: Il2CppObject; f: Il2CppField;
                    value: Il2CppPtr) =
  if not rt.has(eFieldSetValue): return
  tvPPP(rt.fns[ord(eFieldSetValue)], obj, f, value)

proc fieldStaticGetValue*(rt: Il2Cpp; f: Il2CppField; into: Il2CppPtr) =
  if not rt.has(eFieldStaticGetValue): return
  tvPP(rt.fns[ord(eFieldStaticGetValue)], f, into)

proc fieldStaticSetValue*(rt: Il2Cpp; f: Il2CppField; value: Il2CppPtr) =
  if not rt.has(eFieldStaticSetValue): return
  tvPP(rt.fns[ord(eFieldStaticSetValue)], f, value)

proc propertyName*(rt: Il2Cpp; p: Il2CppProperty): string =
  if not rt.has(ePropertyGetName): return ""
  result = readCString(tpP(rt.fns[ord(ePropertyGetName)], p))

proc propertyGetter*(rt: Il2Cpp; p: Il2CppProperty): Il2CppMethod =
  if not rt.has(ePropertyGetGetMethod): return nullPtr()
  result = tpP(rt.fns[ord(ePropertyGetGetMethod)], p)

proc propertySetter*(rt: Il2Cpp; p: Il2CppProperty): Il2CppMethod =
  if not rt.has(ePropertyGetSetMethod): return nullPtr()
  result = tpP(rt.fns[ord(ePropertyGetSetMethod)], p)

proc invoke*(rt: Il2Cpp; m: Il2CppMethod; obj: Il2CppObject;
             args: Il2CppPtr; exc: var Il2CppException): Il2CppObject =
  ## `args` is an `Il2CppPtr` to an array of pointers, or null for none.
  ##
  ## The exception out-parameter is not optional. IL2CPP does not unwind
  ## through a C caller; a managed throw comes back here as a written-to
  ## pointer and an ignored one is a silently wrong result.
  exc = nullPtr()
  if not rt.has(eRuntimeInvoke): return nullPtr()
  result = tpPPPP(rt.fns[ord(eRuntimeInvoke)], m, obj, args,
                  cast[Il2CppPtr](addr exc))

proc objectNew*(rt: Il2Cpp; c: Il2CppClass): Il2CppObject =
  if not rt.has(eObjectNew): return nullPtr()
  result = tpP(rt.fns[ord(eObjectNew)], c)

proc objectClass*(rt: Il2Cpp; obj: Il2CppObject): Il2CppClass =
  if not rt.has(eObjectGetClass): return nullPtr()
  result = tpP(rt.fns[ord(eObjectGetClass)], obj)

proc arrayNew*(rt: Il2Cpp; elementClass: Il2CppClass; count: int): Il2CppPtr =
  ## Allocate a managed 1-D array of `elementClass` with `count` elements, e.g.
  ## a `byte[]` from the `System.Byte` class. Returns null if the runtime did
  ## not export `il2cpp_array_new`, if the class is null, or if `count` is
  ## negative — the caller then does nothing, which is the safe outcome.
  ##
  ## The element data of the returned `Il2CppArray*` begins at the standard
  ## 64-bit IL2CPP array header size (32 bytes: `Il2CppObject{klass, monitor}`
  ## 16 + `bounds` 8 + `max_length` 8) past the pointer. A caller filling it
  ## writes `count` bytes from that offset, which stays inside the allocation.
  if not rt.has(eArrayNew) or elementClass == nil or count < 0:
    return nullPtr()
  result = tpPZ(rt.fns[ord(eArrayNew)], elementClass, uint64(count))

proc valueBox*(rt: Il2Cpp; c: Il2CppClass; data: Il2CppPtr): Il2CppObject =
  if not rt.has(eValueBox): return nullPtr()
  result = tpPP(rt.fns[ord(eValueBox)], c, data)

proc objectUnbox*(rt: Il2Cpp; obj: Il2CppObject): Il2CppPtr =
  if not rt.has(eObjectUnbox): return nullPtr()
  result = tpP(rt.fns[ord(eObjectUnbox)], obj)

proc newString*(rt: Il2Cpp; s: string): Il2CppString =
  if not rt.has(eStringNew): return nullPtr()
  var t = s
  result = tpP(rt.fns[ord(eStringNew)], cast[Il2CppPtr](toCString(t)))

proc readString*(rt: Il2Cpp; s: Il2CppString): string =
  ## A managed `System.String` as UTF-8.
  ##
  ## Only the BMP is decoded; a surrogate pair comes out as replacement
  ## characters rather than as one wrong character. Everything this is used for
  ## -- type names, member names, JSON -- is ASCII in practice, and quietly
  ## producing mojibake would be worse than visibly not handling it.
  result = ""
  if s == nil or not rt.has(eStringChars) or not rt.has(eStringLength):
    return
  let n = ti32P(rt.fns[ord(eStringLength)], s)
  if n <= 0'i32:
    return
  let chars = tpP(rt.fns[ord(eStringChars)], s)
  if chars == nil:
    return
  for i in 0 ..< int(n):
    let c = wordAt(chars, uint64(i))
    if c < 0x80'u16:
      result.add char(c)
    elif c < 0x800'u16:
      result.add char(0xC0'u16 or (c shr 6))
      result.add char(0x80'u16 or (c and 0x3F'u16))
    elif c >= 0xD800'u16 and c <= 0xDFFF'u16:
      result.add "\xEF\xBF\xBD"
    else:
      result.add char(0xE0'u16 or (c shr 12))
      result.add char(0x80'u16 or ((c shr 6) and 0x3F'u16))
      result.add char(0x80'u16 or (c and 0x3F'u16))

proc typeName*(rt: Il2Cpp; t: Il2CppType): string =
  ## The runtime allocates this one and expects it back.
  if not rt.has(eTypeGetName): return ""
  let p = tpP(rt.fns[ord(eTypeGetName)], t)
  result = readCString(p)
  if rt.has(eFree) and p != nil:
    tvP(rt.fns[ord(eFree)], p)

proc threadAttach*(rt: Il2Cpp; domain: Il2CppDomain): Il2CppThread =
  ## Every thread that is not one the runtime created must attach before it
  ## calls in. Skipping this does not fail loudly -- it corrupts the GC's view
  ## of the stack and the process dies somewhere else, later.
  if not rt.has(eThreadAttach): return nullPtr()
  result = tpP(rt.fns[ord(eThreadAttach)], domain)

proc threadDetach*(rt: Il2Cpp; t: Il2CppThread) =
  if not rt.has(eThreadDetach): return
  tvP(rt.fns[ord(eThreadDetach)], t)

proc threadCurrent*(rt: Il2Cpp): Il2CppThread =
  if not rt.has(eThreadCurrent): return nullPtr()
  result = tpV(rt.fns[ord(eThreadCurrent)])

proc gcHandleNew*(rt: Il2Cpp; obj: Il2CppObject; pinned: bool): uint32 =
  if not rt.has(eGcHandleNew): return 0'u32
  result = tu32PI(rt.fns[ord(eGcHandleNew)], obj, (if pinned: 1'i32 else: 0'i32))

proc gcHandleTarget*(rt: Il2Cpp; h: uint32): Il2CppObject =
  if not rt.has(eGcHandleGetTarget): return nullPtr()
  result = tpU(rt.fns[ord(eGcHandleGetTarget)], h)

proc gcHandleFree*(rt: Il2Cpp; h: uint32) =
  if not rt.has(eGcHandleFree): return
  tvU(rt.fns[ord(eGcHandleFree)], h)

# ---------------------------------------------------------------------------
# Name resolution
# ---------------------------------------------------------------------------

proc splitTypeName*(qualified: string; ns, name: var string) =
  ## Splits `Namespace.Nested.Type` at the last dot: IL2CPP keeps namespace and
  ## type name separate, and everything a mod author writes keeps them together.
  var cut = -1
  var i = qualified.len - 1
  while i >= 0:
    if qualified[i] == '.':
      cut = i
      break
    dec i
  if cut < 0:
    ns = ""
    name = qualified
  else:
    ns = qualified.substr(0, cut - 1)
    name = qualified.substr(cut + 1)

proc findClass*(rt: Il2Cpp; qualified: string): Il2CppClass =
  ## Looks a type up by qualified name across every loaded assembly.
  ##
  ## Searching all images rather than requiring an assembly name is the point:
  ## Tarkov and SPT move types between assemblies across releases, and a mod
  ## that named the assembly would break on a release where nothing about the
  ## type itself changed.
  result = nullPtr()
  if not rt.loaded:
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

  for i in 0 ..< count:
    let image = rt.assemblyGetImage(assemblyAt(assemblies, i))
    if image == nil:
      continue
    let c = rt.classFromName(image, ns, name)
    if c != nil:
      return c

proc methodPointer*(rt: Il2Cpp; m: Il2CppMethod): Il2CppPtr =
  ## The compiled function behind a method.
  ##
  ## IL2CPP exposes no accessor for this, so it is read directly: it is the
  ## first field of `MethodInfo` and has been for every Unity version this
  ## targets. That is a layout assumption rather than an interface, so the
  ## result is checked before it is used -- a pointer that is not in an
  ## executable page means the assumption is wrong on this build, and the
  ## caller gets nothing rather than a patch aimed at the middle of a struct.
  result = cast[Il2CppPtr](0)
  if m == nil:
    return
  # Before dereferencing `m` at all: a real client can hand back a non-nil
  # method handle that is not a readable `MethodInfo` (an unverified type name
  # resolving to something that is not one), and the raw read below faults on
  # it and takes the game down rather than returning nothing. `MethodInfo`'s
  # first field is one pointer, so eight bytes is what has to be readable.
  if isReadable(m, 8'i32) == 0'i32:
    return
  let p = readPtr(m, 0'i32)
  if p == nil:
    return
  if isCodePtr(p) == 0'i32:
    return
  result = p

proc fullName*(rt: Il2Cpp; c: Il2CppClass): string =
  if c == nil:
    return ""
  let ns = rt.classNamespace(c)
  let n = rt.className(c)
  if ns.len == 0:
    result = n
  else:
    result = ns & "." & n

proc methodFlags*(rt: Il2Cpp; m: Il2CppMethod): uint32 =
  ## The method's attribute flags. Bit 0x10 is `static`, which is the one thing
  ## the detour path needs: a compiled instance method takes `this` in the first
  ## argument register and a static one does not, so getting this wrong shifts
  ## every argument by one and reports the wrong values with total confidence.
  if not rt.has(eMethodGetFlags): return 0'u32
  var iflags = 0'u32
  result = tu32PP(rt.fns[ord(eMethodGetFlags)], m,
                  cast[Il2CppPtr](addr iflags))

proc methodIsStatic*(rt: Il2Cpp; m: Il2CppMethod): bool =
  result = (methodFlags(rt, m) and 0x10'u32) != 0'u32

proc classFromType*(rt: Il2Cpp; t: Il2CppType): Il2CppClass =
  ## The class behind a type, exactly.
  ##
  ## The alternative is to take the type's *name* and look the class up by it,
  ## which works for `System.Int32` and falls apart on a generic, an array or a
  ## nested type -- the printed name is not always a name the resolver accepts.
  ## Classifying a parameter is the difference between binding a method on the
  ## fast path and refusing it, so it is worth an entry point.
  if not rt.has(eClassFromType): return nullPtr()
  result = tpP(rt.fns[ord(eClassFromType)], t)

var gBoxHeader = -1

proc boxHeaderBytes*(rt: Il2Cpp): int =
  ## How much of a value type's reported instance size is object header --
  ## measured, not assumed.
  ##
  ## `il2cpp_class_get_instance_size` on the game reports a value type's
  ## **boxed** size, header plus payload, because that is the only form the
  ## runtime allocates. That is not universal: a stand-in can just as reasonably
  ## report the payload, and both answers are self-consistent, so no single
  ## number in isolation tells them apart.
  ##
  ## One number whose payload is *known* does. `System.Int32` holds four bytes
  ## by definition, so whatever this runtime reports for it, minus four, is the
  ## header. `System.Double` only checks that answer: eight bytes of payload
  ## must report four more than `Int32` does, and if it does not, this runtime
  ## is not measuring what it is assumed to be, and the fallback stands.
  ##
  ## Getting it wrong subtracts a header that is not there, which turns every
  ## small value type into a negative width and refuses it -- an enum reported
  ## as unclassifiable, a shaped call quietly falling back to reflection, and
  ## the log saying the shape was checked. Two mods hit exactly that before this
  ## existed; the host has the same calculation in `invoke.nim`.
  if gBoxHeader >= 0:
    return gBoxHeader
  gBoxHeader = 16
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

proc valueWidth*(rt: Il2Cpp; c: Il2CppClass): int =
  ## The payload width of a value type, or 0 if it is not one. See
  ## `boxHeaderBytes` for why the header is measured rather than named.
  result = 0
  if c == nil or not classIsValueType(rt, c):
    return 0
  let n = classInstanceSize(rt, c) - boxHeaderBytes(rt)
  if n > 0:
    result = n

proc fieldFlags*(rt: Il2Cpp; f: Il2CppField): uint32 =
  ## Field attributes. Bit 0x10 is `static`, which cannot be inferred reliably
  ## from the offset: a static field's offset is into the class's static data,
  ## not into an instance, and the two ranges can overlap.
  if not rt.has(eFieldGetFlags): return 0'u32
  result = tu32P(rt.fns[ord(eFieldGetFlags)], f)

proc fieldIsStatic*(rt: Il2Cpp; f: Il2CppField): bool =
  result = (fieldFlags(rt, f) and 0x10'u32) != 0'u32

proc staticFieldData*(rt: Il2Cpp; c: Il2CppClass): Il2CppPtr =
  ## The base address of a class's static storage, which is what a static
  ## field's offset is relative to.
  if not rt.has(eClassStaticFieldData): return nullPtr()
  result = tpP(rt.fns[ord(eClassStaticFieldData)], c)

proc writeBarrier*(rt: Il2Cpp; obj, field, value: Il2CppPtr) =
  ## Stores a reference into a field *and tells the collector*.
  ##
  ## Writing the pointer directly is faster and is how an object gets collected
  ## while something still points at it: a generational collector needs to know
  ## that an old object now references a young one, and a plain store does not
  ## tell it. The crash arrives at the next collection, far from the write.
  if not rt.has(eGcWriteBarrier):
    return
  tvPPP(rt.fns[ord(eGcWriteBarrier)], obj, field, value)

proc hasWriteBarrier*(rt: Il2Cpp): bool = rt.has(eGcWriteBarrier)

proc writeBarrierFn*(rt: Il2Cpp): Il2CppPtr =
  ## The resolved entry itself, for the fast path.
  ##
  ## `writeBarrier` above is the pleasant form and costs a `has` test and an
  ## `Il2Cpp` copy per call. A `FieldBinding` is bound once and written many
  ## times, so it keeps this pointer instead and branches on nil -- which is
  ## also how it records that a runtime *without* the entry was bound against,
  ## rather than silently deciding that question again at every write.
  if not rt.has(eGcWriteBarrier): return nullPtr()
  result = rt.fns[ord(eGcWriteBarrier)]
