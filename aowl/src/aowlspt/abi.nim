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
  AbiRevision* = 1'u32

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
