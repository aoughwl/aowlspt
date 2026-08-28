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
##       var a = argsF(1.0)
##       discard callFloat(damage, player, a)  # a call
##
## `callFloat` takes its `Args` as a `var`, so the pack has to be a variable:
## `callFloat(damage, player, argsF(1.0))` does not compile.
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

{.emit: """
/* Which thread this is.
 *
 * Here rather than left to the mod, for the reason the clock is: `{.emit.}` is
 * module-scoped, so a mod that declared this itself would get an
 * implicit-declaration error out of the C compiler naming a function it never
 * wrote. `aowlspt_fast.h` has already pulled in <windows.h> above.
 *
 * It is not decoration. "This callback ran on the game's thread" is the whole
 * claim behind `everyMain` and behind every Unity object a mod touches from
 * one, and a mod cannot check it against anything without a thread id to
 * compare. */
static int64_t aowl_thread_id(void) { return (int64_t)GetCurrentThreadId(); }

/* VirtualQuery, restated locally rather than pulled in from
 * `abi/aowlspt_shim.h`.
 *
 * `{.emit.}` is module-scoped and this module includes `aowlspt_fast.h`, not
 * `aowlspt_shim.h`; including the shim here to reach its `aowl_is_readable`
 * would drag its whole surface (and a second copy of every static in it) into
 * every mod that imports `fast`. The name is DIFFERENT on purpose so the two
 * can never be confused for one definition. `aowlspt_fast.h` has already
 * pulled in <windows.h>.
 *
 * Semantics match the shim exactly: committed, not a guard page, carrying a
 * readable protection, and the WHOLE range inside one region. */
static int32_t aowl_fast_is_readable(void* p, int32_t size) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || size <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY))) return 0;
    {
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)p + (uintptr_t)size;
        if (need < (uintptr_t)p) return 0;   /* overflow */
        return need <= end ? 1 : 0;
    }
}

""".}

# ---------------------------------------------------------------------------
# The C side
# ---------------------------------------------------------------------------

proc fastIsReadable(p: Il2CppPtr; size: int32): int32 {.
  importc: "aowl_fast_is_readable", nodecl.}

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
proc cFldSetPtrWb(fn, o: Il2CppPtr; off: int32; v: Il2CppPtr) {.importc: "aowl_fld_set_ptr_wb", nodecl.}

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

proc cThreadId(): int64 {.importc: "aowl_thread_id", nodecl.}

proc currentThreadId*(): int64 =
  ## The calling thread's id, as Windows numbers them.
  ##
  ## For checking that a callback ran where it was supposed to. A mod that
  ## touches a Unity object from a worker thread does not fail: it usually
  ## works, until the frame it does not, and the crash is nowhere near the
  ## call. Comparing this between two firings is how a mod establishes that
  ## `everyMain` really reached the game's thread rather than merely running.
  result = cThreadId()

proc nanosBetween*(startTicks, endTicks: int64): int64 =
  ## Ticks to nanoseconds. Multiplies before dividing, because the frequency is
  ## around 10 MHz and dividing first turns every measurement under a
  ## microsecond into zero.
  let f = perfFreq()
  if f <= 0: return 0
  result = ((endTicks - startTicks) * 1000000000'i64) div f

# ---------------------------------------------------------------------------
# The allocation counter
# ---------------------------------------------------------------------------
#
# "This path allocates nothing" is a claim, and a claim about a hot loop is
# worth what it is measured at. `allocationCount()` is the measurement: every
# nimony binary statically links mimalloc with `MI_STAT=1`, and mimalloc keeps
# a **cumulative** count of the blocks it has handed out that nothing on the
# free path lowers. Cumulative is what makes it usable here -- a string built
# and freed once per firing leaves the *live* figure exactly where it was, so
# `getOccupiedMem` would report zero growth for a path allocating at frame
# rate.
#
# The counter is per binary, because the allocator is: a mod DLL and the host
# DLL each link their own. That is not a limitation, it is the shape of the
# question -- "does the mod side allocate" and "does the host side allocate"
# are two claims, and the host answers its own through
# `call("aowlspt.host::patch_stats")`.
#
# The struct below is a prefix of mimalloc's `mi_stats_t`, which is all
# `mi_stats_get` is asked for -- it copies `min(size, sizeof)` and stamps the
# version, so a prefix is a supported way to read it. The version is checked
# rather than assumed, and `allocProbeOk()` goes further: it makes an
# allocation and confirms the counter moved. A wrong field would otherwise read
# as "nothing allocated", which is exactly the answer this is used to
# establish -- and did, once: see the note on `malloc_requested` below.

{.emit: """
#include <stdint.h>
#include <string.h>

typedef struct AowlMiCount   { int64_t total, peak, current; } AowlMiCount;
typedef struct AowlMiCounter { int64_t total; } AowlMiCounter;

/* The prefix of mimalloc's `mi_stats_t`, in declaration order.
 *
 * Two things about which field to read, and both were found by the counter
 * answering zero for a loop that certainly allocated.
 *
 * `malloc_requested` is the obvious one and it is **only maintained under
 * `MI_STAT > 1`**, which is a debug build. nimony compiles mimalloc with
 * `MI_STAT=1`, so that field is a permanent zero here -- and a permanent zero
 * is exactly the answer this is used to establish, which makes it the worst
 * possible field to have picked.
 *
 * `malloc_normal_count` is a *counter*, and mimalloc's counters "can just be
 * increased" -- nothing on the free path lowers one. That is what makes it a
 * proof rather than a snapshot: an unchanged count across a loop means the loop
 * made no allocations at all, not that it freed as many as it made.
 *
 * `MI_STAT_VERSION` is 1 and `mi_stats_get` stamps it, so a mismatch means the
 * layout moved and the number must not be trusted. */
typedef struct AowlMiStats {
  int32_t     version;
  AowlMiCount pages, reserved, committed, reset, purged, page_committed,
              pages_abandoned, threads, malloc_normal, malloc_huge,
              malloc_requested;
  AowlMiCounter mmap_calls, commit_calls, reset_calls, purge_calls,
                arena_count, malloc_normal_count, malloc_huge_count;
} AowlMiStats;

extern void mi_stats_merge(void);
extern void mi_stats_get(size_t stats_size, void* stats);

static int64_t aowl_alloc_count(void) {
  AowlMiStats st;
  memset(&st, 0, sizeof(st));
  /* Folds this thread's counters into the process-wide ones, so a hook that
     fires on the game thread is visible to a check made on another. */
  mi_stats_merge();
  mi_stats_get(sizeof(st), (void*)&st);
  if (st.version != 1) return -1;
  return st.malloc_normal_count.total + st.malloc_huge_count.total;
}

/* Bytes currently live, rather than ever handed out.
 *
 * The counter beside it is cumulative and that is what makes it a proof: an
 * unchanged total means a loop allocated nothing at all. This one answers the
 * other question, and it is the one a leak hunt wants -- "is the heap the same
 * size it was after all that", which a cumulative figure cannot say. It is a
 * *snapshot* and nothing about it is a proof: a run that allocated and freed
 * leaves it where it was, which is exactly the answer that is wanted here and
 * exactly the answer that made it useless for the claim above. Read both. */
static int64_t aowl_alloc_live(void) {
  AowlMiStats st;
  memset(&st, 0, sizeof(st));
  mi_stats_merge();
  mi_stats_get(sizeof(st), (void*)&st);
  if (st.version != 1) return -1;
  return st.malloc_normal.current + st.malloc_huge.current;
}

static int64_t aowl_alloc_bytes(void) {
  AowlMiStats st;
  memset(&st, 0, sizeof(st));
  mi_stats_merge();
  mi_stats_get(sizeof(st), (void*)&st);
  if (st.version != 1) return -1;
  return st.malloc_normal.total + st.malloc_huge.total;
}
""".}

proc cAllocCount(): int64 {.importc: "aowl_alloc_count", nodecl.}
proc cAllocBytes(): int64 {.importc: "aowl_alloc_bytes", nodecl.}
proc cAllocLive(): int64 {.importc: "aowl_alloc_live", nodecl.}

proc allocationCount*(): int64 =
  ## How many blocks this binary's allocator has ever handed out, or -1 when
  ## the counter could not be read.
  ##
  ## Monotone: a free does not lower it. That is the whole reason it is usable
  ## as a proof -- take it, run a loop, take it again, and an unchanged number
  ## means the loop allocated nothing at all rather than nothing *net*. A
  ## live-bytes figure like `getOccupiedMem` cannot say that: a string built and
  ## freed once per firing leaves it exactly where it was.
  ##
  ## Per binary, because the allocator is: a mod DLL and the host DLL each link
  ## their own mimalloc. That is the shape of the question rather than a
  ## limitation -- "does the mod side allocate" and "does the host side
  ## allocate" are two claims, and the host answers its own through
  ## `call("aowlspt.host::patch_stats")`.
  result = cAllocCount()

proc allocatedBytes*(): int64 =
  ## The same, in bytes of block size. Reported beside the count because a
  ## number of bytes is what a reader wants to see; the *count* is what an
  ## assertion should be written against, since nothing lowers it.
  result = cAllocBytes()

proc liveBytes*(): int64 =
  ## How many bytes this binary's allocator is holding right now, or -1 when the
  ## counter could not be read.
  ##
  ## A snapshot rather than a proof -- see `allocationCount` for the difference
  ## and why the cumulative one is the one to assert against. This is the figure
  ## to *watch over time*: a heap that is the same size after ten thousand
  ## cycles as after ten is a heap nothing is accumulating in, and no cumulative
  ## counter can say that.
  result = cAllocLive()

proc allocProbeOk*(): bool =
  ## Whether `allocationCount` is actually reading the allocator.
  ##
  ## It makes an allocation of a known size and checks that the count moved.
  ## Without this, a build where the counters are compiled out reports a
  ## constant -- and a constant is indistinguishable from "your loop allocated
  ## nothing", which is the one answer this must never give by accident. That is
  ## not hypothetical: the first version of this read `malloc_requested`, which
  ## is only maintained in a debug build, and reported a confident zero for a
  ## loop allocating at frame rate.
  let before = allocationCount()
  if before < 0'i64: return false
  var probe = ""
  for i in 0 ..< 4099:
    probe.add 'x'
  let after = allocationCount()
  # Kept alive past the second read; without a use, the string is free to be
  # optimised out and the probe would measure nothing.
  if probe.len != 4099: return false
  result = after > before

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

proc classifyClass*(rt: Il2Cpp; c: Il2CppClass): FastKind =
  ## A class, as a register class.
  ##
  ## An **enum** lands here, and it used to be refused: it passes as its
  ## underlying integer, nothing in the C API names which one, and guessing
  ## `Int32` is wrong for the `long` enums that exist. But the width is not a
  ## guess -- it is `instance size` minus the object header, and the header is
  ## measured rather than assumed (`boxHeaderBytes`). So an enum, and any other
  ## value type small enough to travel in a register, is classified by the size
  ## the runtime reports for it.
  ##
  ## A value type too wide for a register is still refused, and must be: Win64
  ## passes it by hidden pointer, which is a different call *shape* rather than
  ## a different register. `bindRaw` is how a mod states that shape.
  if c == nil:
    return fkNone
  if not classIsValueType(rt, c):
    # A class: one register holding an address.
    return fkPtr
  # Ask what it *is* before measuring how wide it is. `System.Single` and
  # `System.Double` are value types that travel in **SSE** registers, and
  # `System.Boolean` is one that a callee reads as a byte -- and all three are
  # widths (4, 8, 1) the register-class test below happily calls an integer.
  # Getting this wrong does not crash: a float bound as `fkI32` is passed in
  # RCX instead of XMM0 and its result read out of RAX, so `Boost(4.0)`
  # answers `0.0` rather than `24.0`. A plausible number is the worst possible
  # failure, so the name is consulted first and the width is only for the
  # types no name decides -- enums, and small structs.
  let named = primitiveKind(fullName(rt, c))
  if named != fkNone:
    return named
  let w = valueWidth(rt, c)
  if w <= 0:
    return fkNone
  # 1, 2, 4 and 8 are the sizes Win64 puts in a general-purpose register; 3, 5,
  # 6, 7 and anything above 8 go to memory.
  if w == 1 or w == 2 or w == 4:
    return fkI32
  if w == 8:
    return fkI64
  result = fkNone

proc classifyDeclared*(rt: Il2Cpp; t: Il2CppType): FastKind =
  ## The same, from the **declared type** rather than from its printed name.
  ##
  ## This is the one that works on a generic instantiation, an array or a
  ## nested type: `il2cpp_class_from_il2cpp_type` answers exactly, where the
  ## printed name is not always a name the resolver accepts. Prefer it wherever
  ## the type itself is in hand, which is everywhere the signature is being
  ## walked.
  let c = classFromType(rt, t)
  if c == nil:
    # The runtime could not name a class for it. That is a refusal, not a
    # reference: reporting `fkPtr` here would guess a register for something
    # nobody has established the shape of.
    return fkNone
  result = classifyClass(rt, c)

proc classifyType*(rt: Il2Cpp; t: string): FastKind =
  ## A parameter or return type, as a register class.
  ##
  ## Anything not a primitive has to be decided by asking the runtime whether
  ## it is a value type, because that is the whole question: a reference is one
  ## register holding an address, and a value type of any size above eight
  ## bytes is passed by a hidden pointer, which is a different call shape
  ## entirely rather than a different register.
  ##
  ## The lookup here is by qualified **name**, so a generic instantiation, an
  ## array type or a nested type whose name `findClass` cannot resolve still
  ## comes back `fkNone` and the binding is refused. `classifyDeclared` below
  ## takes the declared type itself and has no such problem; this overload
  ## remains for the callers that only ever have a name.
  ##
  ## Conservative in the one direction that matters: the failure is "you must
  ## classify this yourself", not a call with the arguments in the wrong
  ## registers.
  result = primitiveKind(t)
  if result != fkNone:
    return
  if t.len == 0:
    return fkNone
  let c = findClass(rt, t)
  if c == nil:
    return fkNone
  # Whatever `classifyClass` says, including `fkNone`. An unconditional
  # `result = fkPtr` stood here and made every resolvable non-primitive a
  # reference -- which silently disarmed the `classifyType(...) == fkNone`
  # gate that `classicmovement` and `fov` use to refuse a value type too wide
  # for a register.
  result = classifyClass(rt, c)

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

const MaxArgs* = 4

const MaxSlots* = 12
  ## Argument POSITIONS a shaped call can use: a hidden struct-return pointer,
  ## `this`, every declared argument and the trailing `MethodInfo*`.
  ##
  ## It was 5 -- the point at which Win64 stops using registers -- and that
  ## made a wider call impossible rather than merely slower. `aowlspt_fast.h`
  ## now emits the stack cases too, so this is the width of that TABLE and not
  ## the width of the register file. It MUST equal `AOWL_FAST_MAX_SLOTS`: the
  ## C side is what actually dispatches, and a disagreement between the two is
  ## a call with the arguments in the wrong places. `bindRaw` refuses a wider
  ## shape against this constant; `aowl_crva_invoke` refuses one against the C
  ## constant, so neither side can silently truncate a shape.
  ##
  ## Only positions 0..3 have a register CLASS to choose, so `floatMask` still
  ## only describes four bits: a float in position 4 or beyond is an 8-byte
  ## stack slot carrying its bits in the low half, and `AOWL_FAST_CODE`
  ## narrows the mask accordingly.
  ##
  ## `MaxArgs` above is deliberately NOT raised with it. That is the by-NAME
  ## path, whose limit is signature CLASSIFICATION rather than slot count, and
  ## fact #145 says a by-name route is fatal the moment it is used.

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
  ##
  ## **A NIL CHECK ON THE CLASS BELOW WOULD NOT BE A CHECK, SO THERE IS NOT
  ## ONE.** `objectClass` is `il2cpp_object_get_class`, which is literally
  ## `mov rax,[rcx]; ret` -- it validates nothing, so a bad object yields a
  ## plausible NON-NIL number. `fullName` then reaches
  ## `il2cpp_class_get_name`, which is TOKEN-GATED and answers a uniform
  ## random NON-ZERO uint64 on gate mismatch rather than NULL. That pair is
  ## what killed the client at 10:30:54 (fact #198): every nil check on the
  ## path passed and the first dereference was 0xC0000005, inside
  ## `readCString`.
  ##
  ## So the gates here are the ones that CAN fail: VirtualQuery on the object
  ## before its first word is read, VirtualQuery on the class handle before it
  ## is used, and an EMPTY NAME treated as a refusal -- `readCString` now
  ## returns "" and bumps `gReadCStringRefusals` when the pointer it was given
  ## is not readable or is not printable ASCII, which is how a random answer
  ## announces itself instead of faulting.
  ##
  ## This narrows a certain crash to an unlikely one. It does not make a gated
  ## export safe to call, and a byte-verified static RVA remains the only
  ## route that bypasses the gate outright.
  if obj == nil:
    return noBinding("::" & member, "no object to bind against")
  if fastIsReadable(obj, 8'i32) == 0'i32:
    return noBinding("::" & member,
                     "the object is non-nil but its first word is not " &
                     "readable -- refusing to ask it for its class")
  var cls = objectClass(rt, obj)
  if cls != nil and fastIsReadable(cast[Il2CppPtr](cls), 8'i32) == 0'i32:
    return noBinding("::" & member,
                     "il2cpp_object_get_class answered a non-nil value that " &
                     "is not readable memory. That export validates nothing " &
                     "(mov rax,[rcx]; ret), so this is what a bad object " &
                     "looks like -- refusing rather than dereferencing it")
  var name = fullName(rt, cls)
  if cls != nil and name.len == 0:
    return noBinding("::" & member,
                     "the class name came back EMPTY -- il2cpp_class_get_name " &
                     "is token-gated and answers a random non-zero value on " &
                     "mismatch, which readCString refused. Nothing was " &
                     "dereferenced and nothing was bound")
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

  # Classified from the **declared type**, not from its printed name: the two
  # differ exactly where it matters -- a generic instantiation, an array, a
  # nested type -- and the name form is kept only as the fallback for a runtime
  # too old to answer `il2cpp_class_from_il2cpp_type`.
  var kinds: seq[FastKind] = @[]
  for i in 0 ..< argc:
    let pt = methodParam(rt, m, i)
    let tn = typeName(rt, pt)
    var k = classifyDeclared(rt, pt)
    if k == fkNone:
      k = classifyType(rt, tn)
    if k == fkNone:
      result.why = result.target & ": argument " & $i & " is declared " & tn &
        ", which the fast path will not classify -- a value type wider than a " &
        "register is passed by hidden pointer, which is a different call " &
        "shape. State it with bindMethodAs, or bindRaw for the shape."
      return
    kinds.add k

  let rt2 = methodReturnType(rt, m)
  let rtn = typeName(rt, rt2)
  var rk = classifyDeclared(rt, rt2)
  if rk == fkNone:
    rk = classifyType(rt, rtn)
  if rk == fkNone:
    result.why = result.target & ": returns " & rtn &
      ", which the fast path will not classify -- a value type wider than a " &
      "register comes back by hidden pointer, which is a different call " &
      "shape. State it with bindMethodAs, or bindRaw for the shape."
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
    wbarrier*: Il2CppPtr
      ## `il2cpp_gc_wbarrier_set_field`, resolved at bind time, or nil on a
      ## runtime that does not export it. Kept here rather than looked up per
      ## write: a binding is made once and written many times, and the answer
      ## cannot change under a binding that is already live.

proc bindField*(rt: Il2Cpp; owner, fieldName: string): FieldBinding =
  ## Binds an **instance** field.
  ##
  ## A static field is refused *by name*, not approximated: for a static field
  ## `il2cpp_field_get_offset` returns an offset into the class's static data
  ## block rather than into any object, and applying an instance read to it
  ## would read some object's payload at the same offset and hand back a
  ## number. `bindStaticField` is the one that binds those, and the two produce
  ## different types on purpose -- see the note there.
  ##
  ## Staticness is asked of the runtime (`il2cpp_field_get_flags`) wherever the
  ## runtime answers, and only inferred from the offset where it does not. The
  ## inference is a guard, not a test: the two offset ranges overlap, so a
  ## static field can sit at an offset that is perfectly plausible inside an
  ## instance -- which is precisely what the stand-in's `Player::SpawnCount`
  ## does, at the same offset as `Player::Health`.
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

  # The runtime's own answer, where it has one. This comes first because it is
  # the only *correct* test: the offset test below cannot distinguish a static
  # field at offset 16 from an instance field at offset 16, and both exist.
  if rt.has(eFieldGetFlags) and fieldIsStatic(rt, f):
    result.why = result.target &
      " is a static field: its offset is into the class's static data block, " &
      "not into an object. Bind it with bindStaticField, which reads that " &
      "block -- an instance read of the same offset would answer a " &
      "neighbouring field's bytes."
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

  let ft = fieldType(rt, f)
  let tn = typeName(rt, ft)
  var k = classifyDeclared(rt, ft)
  if k == fkNone:
    k = classifyType(rt, tn)
  if k == fkNone or k == fkVoid:
    result.why = result.target & " is declared " & tn &
      ", which the fast path will not read by offset. A value type wider than " &
      "eight bytes has to be copied, not loaded."
    return

  result.offset = int32(off)
  result.kind = k
  # Resolved once, here, so `writePtr` is a branch on a pointer rather than a
  # lookup. On a runtime with no barrier entry this stays nil and the binding
  # remembers that, instead of asking again at every write.
  result.wbarrier = writeBarrierFn(rt)
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
  ## Writing a reference field, **through the collector's write barrier** when
  ## the runtime has one.
  ##
  ## IL2CPP's collector has to be told when an object starts referring to
  ## another one. `il2cpp_gc_wbarrier_set_field` is what tells it; skipping it
  ## and storing the pointer directly can get a young object collected while an
  ## old one still references it, and the crash then arrives at the next
  ## collection, far from the write and with nothing on the stack to connect
  ## the two. That is the worst failure shape this file can produce, so it is
  ## the default rather than the option.
  ##
  ## This used to be the unbarriered store, documented as such and left to the
  ## caller to be careful about -- while `writeBarrier` sat bound and unused in
  ## `il2cpp.nim` one call site away. A hazard that is *documented* is still a
  ## hazard; the note told a mod author to reason about object age at every
  ## write, which is not a thing anyone can reliably do.
  ##
  ## On a runtime with no barrier entry the store still happens, unbarriered,
  ## because the alternative is a field that silently does not get written.
  ## `barrierReady` is how a mod asks which of those it is getting.
  if not f.ok or obj == nil: return
  if f.wbarrier != nil:
    cFldSetPtrWb(f.wbarrier, obj, f.offset, v)
  else:
    cFldSetPtr(obj, f.offset, v)

proc writePtrRaw*(f: FieldBinding; obj: Il2CppPtr; v: Il2CppPtr) =
  ## The unbarriered store, for the one case that is genuinely safe: writing
  ## back a pointer the object already reachably holds -- clearing a field to
  ## nil, or restoring a value read out of the same object a moment ago.
  ##
  ## Nothing in this repository needs it. It exists so that a mod that has
  ## measured the barrier and found it in its way can say so explicitly,
  ## instead of the default being the dangerous one for everybody.
  if not f.ok or obj == nil: return
  cFldSetPtr(obj, f.offset, v)

proc barrierReady*(f: FieldBinding): bool =
  ## Whether `writePtr` on this binding goes through the collector.
  result = f.wbarrier != nil

# ---------------------------------------------------------------------------
# Static field bindings
# ---------------------------------------------------------------------------
#
# ## Why this is a different type rather than a flag on `FieldBinding`
#
# A static field's offset is into the class's static data block; an instance
# field's is into the object. The two ranges overlap completely -- the stand-in
# runtime has `EFT.Player::SpawnCount` (static, `Int32`) and
# `EFT.Player::Health` (instance, `Single`) both at offset 16, which is not a
# contrivance but the ordinary case, since neither number knows about the
# other.
#
# So the failure mode of getting this wrong is not a crash and not a refusal.
# `readInt` on a static binding applied to an object reads a `float`'s bits as
# an integer and answers 1091567616; `readFloat` on an instance binding applied
# to the static block reads a spawn count as a float. Both are numbers, both
# arrive with `ok` true, and a mod acts on them.
#
# The only defence that actually holds is one the compiler makes: a static
# binding is a **different type**, and its readers take no object at all.
#
#     readFloat(fHealth, player)      # instance: FieldBinding + an object
#     readInt(fSpawnCount)            # static:   StaticFieldBinding, no object
#
# Passing either to the other's reader does not compile. That is the whole
# design; everything below is bookkeeping.
#
# ## What binding one costs, and why it is done once
#
# `il2cpp_class_get_static_field_data` is a call, and the address it returns
# does not move for the life of the class. So it is asked once, at bind time,
# and the binding holds the block. A read is then the same one load an instance
# read is, from a base that is a constant instead of an object.
#
# `il2cpp_runtime_class_init` runs first. A class whose static constructor has
# not run has a static block that exists and is zero, and "the field is zero"
# is not distinguishable from "the field is zero because nothing has
# initialised it yet".

type
  StaticFieldBinding* = object
    ## A **static** field, resolved to the address of its storage.
    ##
    ## Deliberately not a `FieldBinding` with a flag: see the note above. The
    ## readers below take no object, so an instance binding and a static one
    ## cannot be swapped by accident even when both are in scope and both are
    ## called `f`.
    ok*: bool
    why*: string
    target*: string
    base*: Il2CppPtr    ## the class's static data block
    offset*: int32      ## where in it this field lives
    kind*: FastKind
    bindNs*: int64

proc bindStaticField*(rt: Il2Cpp; owner, fieldName: string): StaticFieldBinding =
  ## Binds a **static** field, refusing an instance one.
  ##
  ## Both directions are refusals rather than approximations, and both are
  ## asked of the runtime:
  ##
  ## * A runtime that does not export `il2cpp_field_get_flags` cannot say
  ##   whether a field is static, so this refuses rather than assuming. The
  ##   offset cannot stand in for the flag -- that is the whole point of the
  ##   note above.
  ## * A runtime that does not export `il2cpp_class_get_static_field_data`
  ##   cannot say where the block is, and adding an offset to nil is how a mod
  ##   reads address 16.
  let t0 = perfCounter()
  result = StaticFieldBinding(ok: false, why: "",
                              target: owner & "::" & fieldName,
                              base: nullPtr(), offset: 0'i32, kind: fkNone,
                              bindNs: 0'i64)

  if not rt.has(eFieldGetFlags):
    result.why = result.target &
      ": this runtime does not export il2cpp_field_get_flags, so there is no " &
      "way to establish that the field is static. Refusing rather than " &
      "guessing from the offset, which cannot tell the two apart."
    return
  if not rt.has(eClassStaticFieldData):
    result.why = result.target &
      ": this runtime does not export il2cpp_class_get_static_field_data, so " &
      "the static block has no address. Use the boxed path."
    return

  let cls = findClass(rt, owner)
  if cls == nil:
    result.why = "no such type: " & owner &
                 " (the game's assemblies may not be loaded yet)"
    return
  let f = findField(rt, cls, fieldName)
  if f == nil:
    result.why = "no field " & result.target
    return
  if not fieldIsStatic(rt, f):
    result.why = result.target &
      " is an instance field: its offset is into an object, not into the " &
      "class's static block. Bind it with bindField and read it off an " &
      "object -- reading it here would answer whatever the static block " &
      "happens to hold at the same offset."
    return

  # The static constructor, before the block is read. Otherwise a field that is
  # zero because nothing has initialised it yet is indistinguishable from one
  # that is zero.
  runtimeClassInit(rt, cls)

  let base = staticFieldData(rt, cls)
  if base == nil:
    result.why = result.target &
      ": the runtime gave no static data block for " & owner &
      " (a class with no static storage, or one that has not been initialised)"
    return

  let off = fieldOffset(rt, f)
  if off < 0:
    result.why = result.target & ": negative offset " & $off
    return

  let ft = fieldType(rt, f)
  let tn = typeName(rt, ft)
  var k = classifyDeclared(rt, ft)
  if k == fkNone:
    k = classifyType(rt, tn)
  if k == fkNone or k == fkVoid:
    result.why = result.target & " is declared " & tn &
      ", which the fast path will not read by offset. A value type wider than " &
      "eight bytes has to be copied, not loaded."
    return

  # Kept as base and offset rather than added here: the addition is the same
  # one an instance read does, it happens in C where the arithmetic is on a
  # `char*`, and nimony will not add an integer to a pointer anyway.
  result.base = base
  result.offset = int32(off)
  result.kind = k
  result.ok = true
  result.bindNs = nanosBetween(t0, perfCounter())
  result.why = result.target & ": static " & describe(k) & " at offset " &
    $off & " of the class's static block"

proc readInt*(f: StaticFieldBinding): int64 =
  ## No object argument, and that is the safety property rather than a
  ## convenience: an instance binding cannot reach this overload.
  result = 0'i64
  if not f.ok: return
  if f.kind == fkI64 or f.kind == fkPtr:
    result = cFldI64(f.base, f.offset)
  elif f.kind == fkBool:
    result = int64(cFldU8(f.base, f.offset))
  else:
    result = int64(cFldI32(f.base, f.offset))

proc readInt32*(f: StaticFieldBinding): int32 =
  result = int32(readInt(f))

proc readBool*(f: StaticFieldBinding): bool =
  result = false
  if not f.ok: return
  result = cFldU8(f.base, f.offset) != 0'i32

proc readFloat*(f: StaticFieldBinding): float =
  result = 0.0
  if not f.ok: return
  if f.kind == fkF64:
    result = cFldF64(f.base, f.offset)
  else:
    result = cFldF32(f.base, f.offset)

proc readPtr*(f: StaticFieldBinding): Il2CppPtr =
  ## A static reference field -- which is how a hand-rolled singleton is
  ## spelled when it is not a property. Same warning as `callPtr`: a raw
  ## managed pointer, good for this frame.
  result = nullPtr()
  if not f.ok: return
  result = cFldPtr(f.base, f.offset)

proc writeInt*(f: StaticFieldBinding; v: int64) =
  if not f.ok: return
  if f.kind == fkI64:
    cFldSetI64(f.base, f.offset, v)
  elif f.kind == fkBool:
    cFldSetU8(f.base, f.offset, int32(v))
  else:
    cFldSetI32(f.base, f.offset, int32(v))

proc writeBool*(f: StaticFieldBinding; v: bool) =
  if not f.ok: return
  cFldSetU8(f.base, f.offset, (if v: 1'i32 else: 0'i32))

proc writeFloat*(f: StaticFieldBinding; v: float) =
  if not f.ok: return
  if f.kind == fkF64:
    cFldSetF64(f.base, f.offset, v)
  else:
    cFldSetF32(f.base, f.offset, v)

proc writePtrRaw*(f: StaticFieldBinding; v: Il2CppPtr) =
  ## Stores a reference into a static field, **without** a write barrier, and
  ## the name says so because there is no barriered version to reach for.
  ##
  ## `il2cpp_gc_wbarrier_set_field` takes the *object* whose field is being
  ## written, so that the collector can mark that object's card. A static field
  ## has no such object: the storage is a GC root in its own right, scanned on
  ## every collection rather than reached through an owner. Passing the static
  ## block where an object header is expected is not a conservative choice, it
  ## is a wrong pointer handed to the collector.
  ##
  ## So this is the honest shape: the store a static reference field needs, and
  ## a name that does not let a caller believe a barrier happened.
  if not f.ok: return
  cFldSetPtr(f.base, f.offset, v)
