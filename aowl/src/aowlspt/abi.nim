## The raw ABI, transliterated from `abi/aowlspt_abi.h`, for nimony/aowl.
##
## Deliberately mechanical: the same structs, in the same order, with the same
## calling convention, and nothing else. Ergonomics live in `aowlspt.nim`, so a
## new field in the header has exactly one place to be mirrored.
##
## Two nimony specifics that are load-bearing here:
##
##  * **Null pointers are written as `cast[T](0)`.** nimony's `ptr T` is non-nil
##    by default and rejects a bare `nil` literal, which is a feature — it means
##    every null in this file is one somebody chose.
##  * **`{.bycopy.}` objects match C layout.** `AowlSlice` is 16 bytes on x86-64
##    (8-byte pointer, 4-byte length, 4 bytes tail padding); `{.packed.}` would
##    break the match rather than tighten it. `sizeof` is asserted against the C
##    header by `tests/abi_layout.nim`.

const
  AbiVersion* = 1'u32
  AbiRevision* = 6'u32

  HostApiSizeRev1* = 168'i32
  HostApiSizeRev2* = 192'i32
  HostApiSizeRev3* = 208'i32
  HostApiSizeRev4* = 216'i32
  HostApiSizeRev5* = 224'i32
  HostApiSizeRev6* = 232'i32
    ## How large `HostApi` was at each revision, as literals.
    ##
    ## A capability test has to be against the boundary the capability appeared
    ## at, not against `sizeof(HostApi)`. The obvious form -- "the host's size is
    ## at least the size I know about" -- is right for exactly one revision:
    ## revision 3 grows `sizeof` to 208, so a mod asking only for the
    ## revision-2 store would start refusing a revision-2 host that has it.
    ##
    ## Literals rather than arithmetic over the struct because the whole point
    ## is that they must *not* move when the struct does.
    ## `tests/abi_layout.nim` and `tests/abi_layout.c` pin all four to the real
    ## offsets, from the two sides.
    ##
    ## Revision 3 is `handlePointer`/`handlePin`, revision 4 is `patchTyped`
    ## and revision 5 is `notifyPush`. They are separate boundaries rather than
    ## one because a host may have any of them without the others: the
    ## addresses need a managed heap, the typed patch needs a working detour
    ## engine, the push needs a listening socket, and `size` says how much was
    ## filled rather than which header the host saw.
    ##
    ## Revision 5 is where the *watermark* in that sentence stopped being free.
    ## Only the client host can fill 3 and 4; only the backend can fill 5; one
    ## integer cannot say "the fifth and not the third". A host in that position
    ## fills the entries under its watermark with the refusal it already owes --
    ## `abi/aowlspt_notify.h` does exactly that for the backend -- so a size test
    ## keeps meaning "there is a function here that will answer", which is all it
    ## ever established. It cannot mean more than that here in any case: nimony
    ## will not cast a proc field to a pointer to compare it against null.

type
  Status* = int32

const
  Ok* = 0'i32
  ErrGeneric* = -1'i32
  ErrAbi* = -2'i32
  ErrNotFound* = -3'i32
  ErrBadArg* = -4'i32
  ErrDecode* = -5'i32
  ErrUnsupported* = -6'i32
  ErrWrongThread* = -7'i32
  ErrDisposed* = -8'i32
  ErrModFault* = -9'i32

  ErrConfigParse* = -10'i32
    ## `config.json` exists and is **not readable JSON**, so no key in it can
    ## be answered. Distinct from `ErrNotFound`, which is the ordinary "no such
    ## setting, use your default".
    ##
    ## They were the same status, and that is how a BOM on the mod manager's
    ## config made it read `activeLists` as empty, resolve nothing, and write a
    ## selection naming only itself -- one mod out of ten loaded on the next
    ## start, with no error anywhere. A mod that falls back to defaults on any
    ## failure, which is most of them, cannot tell "absent" from "the file is
    ## broken" without this.
    ##
    ## `lastError()` after one of these names the file and the fault -- the
    ## offset and what was found there -- not the key. The key is not what is
    ## missing.

  ## Returned by a prefix patch to suppress the original method.
  PatchSkip* = 1'i32

type
  LogLevel* = enum
    llTrace = 0'i32
    llDebug = 1
    llInfo = 2
    llSuccess = 3
    llWarn = 4
    llError = 5

  Encoding* = enum
    encJson = 0'i32
    encCbor = 1
    encRaw = 2
    encNif = 3

  Side* = enum
    sideServer = 1'i32
    sideClient = 2
    sideSim = 3

  PatchKind* = enum
    pkPrefix = 0'i32
    pkPostfix = 1
    pkFinalizer = 2

  RouteKind* = enum
    rkStatic = 0'i32
    rkDynamic = 1

  RvaSharedness* = enum
    ## What the caller asserts about how many methods live at an RVA, and the
    ## only two answers a mod is allowed to give.
    ##
    ## There is no `rvaUnknown`. 28.3% of by-name lookups on this build land on
    ## a folded address, and a detour on one fires for every method folded onto
    ## it -- so "I did not check" and "it is unique" must not be spellable as
    ## the same value. The host decides which it really is from the offline
    ## name index's own share count; this field says what the caller MEANT, and
    ## a disagreement is a refusal with both numbers in it.
    rvaExpectUnique = 0'i32
      ## The default and the only one to use without a reason. The host refuses
      ## the patch unless the index says this address has exactly one owner.
    rvaAllowShared = 1
      ## "I know it is folded (or unknown) and I want every firing anyway."
      ## Logged loudly at install, per target. It does NOT override the
      ## prologue check, the already-detoured check, or a spec whose name and
      ## RVA contradict each other.

  RvaPatchTarget* = object
    ## A patch target named by VERIFIED STATIC ADDRESS instead of by name.
    ##
    ## The DETOUR counterpart of `callrva.RvaTarget`, and separate from it on
    ## purpose: that one is for CALLING an address, which is correct code for
    ## the receiver passed even when the body is folded, so it carries `owners`
    ## for the log line and gates nothing on it. This one is for WRITING over a
    ## function's entry, where a folded body means the detour fires for every
    ## method on the address -- so here sharedness is a gate, not a note.
    ##
    ## By-name binding is what this exists to avoid: `findClass`/`findMethod`
    ## return non-nil handles into unmapped memory on this build, so the
    ## `MethodInfo` a by-name patch needs to derive the frame shape cannot be
    ## read, and using it is fatal rather than absent. Every field here is
    ## something that lookup would have supplied and that must therefore be
    ## derived OFFLINE, from `tools/il2cpp_resolve.py` and
    ## `tools/il2cpp_nameindex.py`, and declared.
    ##
    ## It is a struct rather than a hand-built spec string because all four
    ## parts are load-bearing and a string hides which one is missing: the
    ## first version of this in the FOV mod carried the *wrong type name* for
    ## the aiming-sensitivity getter for weeks, harmlessly, because nothing
    ## ever looked it up.
    name*: string
      ## `Ns.Type::Method` **as the offline name index spells it**, which is
      ## not always as the source spells it: a nested type carries no namespace
      ## on this build (`FirearmController::get_AimingSensitivity`, not
      ## `EFT.Player.FirearmController::...`). It is not decoration -- the host
      ## looks it up at `arity` to cross-check `rva` and to read the share
      ## count, so a name that resolves to nothing is a refusal.
    rva*: uint32
      ## Module-relative, against `GameAssembly.dll` (imagebase 0x180000000, so
      ## `VA - 0x180000000`). Must be inside the `il2cpp` PE section; the host
      ## checks that, `.text` holds no managed bodies.
    shape*: string
      ## The frame shape the host cannot derive without a `MethodInfo`:
      ## `i`/`s` for instance/static, one letter per DECLARED argument
      ## (`i` integer/bool/char, `f` float, `d` double, `o` object/string,
      ## `v` small value type, `V` value type wider than a register), then `>`
      ## and one return letter (the same set plus `x` for void).
      ## `float get_AimingSensitivity()` is `i>f`;
      ## `void CalculateScaleValueByFov(float)` is `if>x`.
    prologue*: seq[uint8]
      ## The method's first bytes, from `il2cpp_resolve.py bytes <RVA> 16`.
      ## Compared against the host's STARTUP SNAPSHOT -- never live memory, so
      ## another feature's trampoline cannot be what was read. Fewer than 8 is
      ## refused: a one-byte "verify" matches thousands of functions and is a
      ## check that cannot fail.
    expect*: RvaSharedness

  ModFlag* = enum
    mfHotReloadable  ## bit 0 — implements stateSave/stateLoad
    mfThreadSafe     ## bit 1 — callbacks are safe off the main thread

  ModFlags* = set[ModFlag]

  Handle* = uint64

  Bytes* = ptr UncheckedArray[uint8]

  AowlSlice* {.bycopy.} = object
    ## Borrowed bytes, valid only for the duration of the call that produced it.
    data*: Bytes
    len*: int32

  AowlBuffer* {.bycopy.} = object
    ## Owned bytes, allocated with the host allocator and freed by the receiver.
    data*: Bytes
    len*: int32

  HostInfo* {.bycopy.} = object
    size*: int32
    abiVersion*: uint32
    abiRevision*: uint32
    side*: int32
    hostName*: AowlSlice
    hostVersion*: AowlSlice
    sptVersion*: AowlSlice
    gameVersion*: AowlSlice
    encodings*: uint32
    modDir*: AowlSlice
    dataDir*: AowlSlice

  # -- callback shapes ------------------------------------------------------

  CallbackFn* = proc (user: pointer; payload: AowlSlice;
                      outBuf: ptr AowlBuffer): Status {.cdecl.}
  RouteFn* = proc (user: pointer; url, body, session: AowlSlice;
                   outBuf: ptr AowlBuffer): Status {.cdecl.}
  PatchFn* = proc (user: pointer; target, args: AowlSlice;
                   outBuf: ptr AowlBuffer): Status {.cdecl.}

  PatchFramePtr* = pointer
    ## A borrowed `const AowlPatchFrame*`. Opaque here: the accessors live in
    ## `aowlspt.nim`, over the `static` readers in `abi/aowlspt_frame.h`, so
    ## that this file stays a transliteration of the struct layout and nothing
    ## else.

  TypedPatchFn* = proc (user: pointer; frame: PatchFramePtr): Status {.cdecl.}
    ## Revision 4's patch handler: the same two return statuses, and a borrowed
    ## view of the saved registers instead of a JSON payload.

  ArgKind* = enum
    ## What one slot of a typed frame is, decided once at registration.
    ## Mirrors `AowlArgKind`; the numbers are wire values.
    akNone = 0'i32
    akInt = 1
    akFloat = 2
    akDouble = 3
    akObject = 4
    akValue = 5
    akBigValue = 6
    akVoid = 7
    akStack = 8
    akUnknown = 9

  HostApi* {.bycopy.} = object
    size*: int32
    ctx*: pointer
    info*: ptr HostInfo

    alloc*: proc (ctx: pointer; bytes: int32): pointer {.cdecl.}
    free*: proc (ctx: pointer; p: pointer) {.cdecl.}

    log*: proc (ctx: pointer; level: int32; message: AowlSlice) {.cdecl.}
    lastError*: proc (ctx: pointer; outSlice: ptr AowlSlice) {.cdecl.}

    configGet*: proc (ctx: pointer; key: AowlSlice; outBuf: ptr AowlBuffer): Status {.cdecl.}
    configSet*: proc (ctx: pointer; key, valueJson: AowlSlice): Status {.cdecl.}

    dbGet*: proc (ctx: pointer; path: AowlSlice; outBuf: ptr AowlBuffer): Status {.cdecl.}
    dbPatch*: proc (ctx: pointer; path, patchJson: AowlSlice): Status {.cdecl.}

    routeRegister*: proc (ctx: pointer; url: AowlSlice; kind: int32;
                          handler: RouteFn; user: pointer): Status {.cdecl.}

    eventSubscribe*: proc (ctx: pointer; name: AowlSlice;
                           handler: CallbackFn; user: pointer): Status {.cdecl.}
    eventEmit*: proc (ctx: pointer; name, payload: AowlSlice): Status {.cdecl.}

    call*: proc (ctx: pointer; target, args: AowlSlice; outBuf: ptr AowlBuffer): Status {.cdecl.}
    resolve*: proc (ctx: pointer; typeName: AowlSlice; outHandle: ptr Handle): Status {.cdecl.}
    handleRelease*: proc (ctx: pointer; handle: Handle) {.cdecl.}

    patch*: proc (ctx: pointer; target: AowlSlice; kind: int32;
                  handler: PatchFn; user: pointer): Status {.cdecl.}

    schedule*: proc (ctx: pointer; delayMs: int32;
                     cb: CallbackFn; user: pointer): Status {.cdecl.}
    invokeMain*: proc (ctx: pointer; cb: CallbackFn; user: pointer): Status {.cdecl.}

    nowMs*: proc (ctx: pointer): int64 {.cdecl.}

    # -- revision 2 ---------------------------------------------------------
    # Appended, never inserted: a mod built against revision 1 checks `size`
    # and simply does not see these.
    storeGet*: proc (ctx: pointer; key: AowlSlice; outBuf: ptr AowlBuffer): Status {.cdecl.}
    storeSet*: proc (ctx: pointer; key, value: AowlSlice): Status {.cdecl.}
    storeList*: proc (ctx: pointer; prefix: AowlSlice; outBuf: ptr AowlBuffer): Status {.cdecl.}

    # -- revision 3 ---------------------------------------------------------
    # The address behind a handle, for a mod that wants to reach an object on
    # its own fast path rather than through `call`. Present only on a host with
    # a managed heap, which is why `size` may still say revision 2 on a host
    # built from this same header -- see `livePointersReady`.
    handlePointer*: proc (ctx: pointer; handle: Handle;
                          outAddress: ptr uint64): Status {.cdecl.}
    handlePin*: proc (ctx: pointer; handle: Handle;
                      outPinned: ptr Handle): Status {.cdecl.}

    # -- revision 4 ---------------------------------------------------------
    # The same detour, with the arguments left in the registers the thunk saved
    # rather than described as JSON. See `patchTyped` in `aowlspt.nim` for what
    # that is worth and `abi/aowlspt_frame.h` for how the frame is read.
    patchTyped*: proc (ctx: pointer; target: AowlSlice; kind: int32;
                       handler: TypedPatchFn; user: pointer): Status {.cdecl.}

    # -- revision 5 ---------------------------------------------------------
    # Hand a notification to whatever the host has that reaches this player --
    # a websocket, on the backend. `ErrNotFound` means "no connection for that
    # session", which is a normal answer and the mod's cue to fall back rather
    # than a failure.
    notifyPush*: proc (ctx: pointer; session, payload: AowlSlice): Status {.cdecl.}

    # -- revision 6 ---------------------------------------------------------
    # Run `cb` on Unity's thread DURING rendering, where immediate-mode
    # `UnityEngine.GL` drawing rasterizes -- for native ESP and GL HUDs, which
    # `invokeMain` (the update phase) is on the right thread but the wrong point
    # in the frame to draw from. `ErrUnsupported` means no render-phase drain is
    # bound on this host/build/scene; a mod gates on
    # `call("aowlspt.host::render_thread")` -> `bound:true` and draws only then.
    invokeRender*: proc (ctx: pointer; cb: CallbackFn; user: pointer): Status {.cdecl.}

  ModInfo* {.bycopy.} = object
    size*: int32
    abiVersion*: uint32
    abiRevision*: uint32
    guid*: AowlSlice
    name*: AowlSlice
    author*: AowlSlice
    version*: AowlSlice
    sptRange*: AowlSlice
    sides*: uint32
    flags*: uint32

  ModApi* {.bycopy.} = object
    size*: int32
    self*: pointer
    onLoad*: proc (self: pointer): Status {.cdecl.}
    onUpdate*: proc (self: pointer; elapsedMs: int64): Status {.cdecl.}
    onUnload*: proc (self: pointer): Status {.cdecl.}
    stateSave*: proc (self: pointer; outBuf: ptr AowlBuffer): Status {.cdecl.}
    stateLoad*: proc (self: pointer; state: AowlSlice): Status {.cdecl.}

const
  SymAbiVersion* = "aowlspt_abi_version"
  SymDescribe* = "aowlspt_describe"
  SymInit* = "aowlspt_init"

func nilBytes*(): Bytes {.inline.} = cast[Bytes](0)
func isNilPtr*(p: pointer): bool {.inline.} = cast[uint](p) == 0'u
func isNilBytes*(p: Bytes): bool {.inline.} = cast[uint](p) == 0'u

func emptySlice*(): AowlSlice {.inline.} =
  AowlSlice(data: nilBytes(), len: 0'i32)

func emptyBuffer*(): AowlBuffer {.inline.} =
  AowlBuffer(data: nilBytes(), len: 0'i32)

func sideBit*(s: Side): uint32 {.inline.} = 1'u32 shl uint32(ord(s))
  ## The `sides` bitmask is `1 << AowlSide`, matching the header.

func flagBits*(flags: ModFlags): uint32 =
  result = 0'u32
  for f in flags:
    result = result or (1'u32 shl uint32(ord(f)))
