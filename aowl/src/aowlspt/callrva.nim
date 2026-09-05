## Calling a game method AT A STATIC RVA.
##
## THE CAPABILITY THIS ADDS
## ------------------------
## Our mods could read the game and could not call it. `aowlspt/fast` binds a
## method BY NAME, and fact #145 is that a by-name route is fatal the moment it
## is USED rather than when it is resolved: calling `CameraManager::get_Instance`
## by name, binding `Physics::Raycast` by name and patching `AddActivePLayer` by
## name each killed the client instantly and silently. Resolving seventy names is
## harmless; using one is not.
##
## This module never resolves a name. It takes an RVA the caller already has,
## byte-verifies the code there against the prologue the caller DECLARES, and
## dispatches through the same 189-case shape table `fast` already uses.
##
## WHAT A MOD AUTHOR WRITES
## ------------------------
## ::
##
##     import aowlspt/callrva
##
##     # Declared ONCE, at module scope. The prologue hex is exactly what
##     #   python tools/il2cpp_resolve.py <GameAssembly.dll> <metadata> \
##     #          bytes 0x5328830 16
##     # prints, and nothing else. Copy it; never type it from memory.
##     var gRaycast = rvaTarget(
##       "UnityEngine.Physics::Raycast(Vector3,Vector3,float)",
##       0x5328830'u32,
##       "48 89 5C 24 08 57 48 83 EC 70 80 3D 51 D9 DA 01",
##       owners = 1)
##
##     proc lineOfSight(ox, oy, oz, dx, dy, dz, maxDist: float): CallOutcome =
##       var a = callArgs()
##       a.addVec3(ox, oy, oz)         # by-value Vector3 -> a pointer slot
##       a.addVec3(dx, dy, dz)         # ..and a second, in its own arena cell
##       a.addFloat(maxDist)           # a float, in XMM for ITS position
##       result = callBool(gRaycast, a)
##
##     let r = lineOfSight(...)
##     if r.kind == coOk:
##       use(r.b)
##     else:
##       log r.why                     # names WHY, never silently declines
##
## THREE OUTCOMES, NEVER TWO
## -------------------------
## `CallOutcome.kind` is `coOk` / `coRefused` / `coFaulted`, and the value is
## only meaningful for `coOk`. CLAUDE.md 9b: "I could not look" is not a pass,
## and a call that faulted is not a call that returned zero. Nothing here folds
## a refusal into a plausible default -- every failure path carries a `why` that
## names the specific reason, because a feature that declines silently is the
## worst outcome this project produces.
##
## AND THE TRAP THAT MATTERS MOST HERE
## -----------------------------------
## **"The call returned without faulting" is NOT evidence the convention is
## right.** A wrong convention returns plausible garbage; that is precisely the
## class of bug that has cost this project the most. Which is why the by-value
## aggregate rule in `abi/aowlspt_callrva.h` is backed by the CALLEE'S OWN
## INSTRUCTION BYTES from four methods on this build, and why `aowlspt/callproof`
## exists to settle it against a live client with an answer known exactly in
## advance rather than against a bool that cannot be wrong-looking.
##
## The C side is `abi/aowlspt_callrva.h`. Compile with `--passC:-I<repo>/abi`.

import std/strutils
import ".." / aowlspt
import aowlspt/il2cpp

{.emit: """#include "aowlspt_callrva.h" """.}

# ---------------------------------------------------------------------------
# The C side
# ---------------------------------------------------------------------------

proc cTargetInit(t: Il2CppPtr; rva: uint32) {.importc: "aowl_crva_t_init", nodecl.}
proc cTargetSigByte(t: Il2CppPtr; i: int32; v: int32) {.importc: "aowl_crva_t_sigbyte", nodecl.}
proc cTargetSetOwners(t: Il2CppPtr; n: int32) {.importc: "aowl_crva_t_owners", nodecl.}
proc cTargetVerify(t: Il2CppPtr): int32 {.importc: "aowl_crva_verify_w", nodecl.}
proc cTargetAccept(t: Il2CppPtr; snap: Il2CppPtr; n: int32): int32 {.importc: "aowl_crva_t_accept", nodecl.}

proc cSlotSetP(a: Il2CppPtr; i: int32; v: Il2CppPtr) {.importc: "aowl_fast_set_p", nodecl.}
proc cSlotSetG(a: Il2CppPtr; i: int32; v: int64) {.importc: "aowl_fast_set_g", nodecl.}
proc cSlotSetF(a: Il2CppPtr; i: int32; v: float) {.importc: "aowl_fast_set_f", nodecl.}

proc cArgAgg(i: int32; src: Il2CppPtr; size: int32): Il2CppPtr {.importc: "aowl_crva_arg_agg", nodecl.}
proc cArgOut(i: int32; size: int32): Il2CppPtr {.importc: "aowl_crva_arg_out", nodecl.}
proc cCell(i: int32): Il2CppPtr {.importc: "aowl_crva_cell", nodecl.}
proc cCellF32(i, off: int32; ok: Il2CppPtr): float {.importc: "aowl_crva_cell_f32_w", nodecl.}
proc cCellI32(i, off: int32; ok: Il2CppPtr): int32 {.importc: "aowl_crva_cell_i32_w", nodecl.}
proc cWriteF32(p: Il2CppPtr; off: int32; v: float) {.importc: "aowl_crva_w_f32", nodecl.}
proc cFaultCount(): int32 {.importc: "aowl_crva_fault_count", nodecl.}

# Small accessors the nimony side needs but that C expresses more honestly than
# a mirrored struct layout would. Mirroring `AowlCrvaTarget` field-by-field in
# nimony would be a SECOND declaration of a layout, and two declarations of one
# layout is a guessed offset waiting to happen -- exactly what CLAUDE.md 5
# forbids. So the struct is opaque here and every field goes through C.
{.emit: """
#include <stdint.h>

static void aowl_crva_t_init(void* p, uint32_t rva) {
    AowlCrvaTarget* t = (AowlCrvaTarget*)p;
    memset(t, 0, sizeof(*t));
    t->rva = rva;
    t->name = "";
}
static void aowl_crva_t_sigbyte(void* p, int32_t i, int32_t v) {
    AowlCrvaTarget* t = (AowlCrvaTarget*)p;
    if (i < 0 || i >= AOWL_CRVA_SIG_BYTES) return;
    t->sig[i] = (unsigned char)v;
    if (i + 1 > t->siglen) t->siglen = i + 1;
}
static void aowl_crva_t_owners(void* p, int32_t n) {
    ((AowlCrvaTarget*)p)->owners = n;
}
static int32_t aowl_crva_verify_w(void* p) {
    return aowl_crva_verify((AowlCrvaTarget*)p);
}

/* The DETOURED case, resolved. `aowl_crva_verify` refused because the live
 * first bytes are a JUMP; the nimony side then asked the HOST for its startup
 * snapshot of that RVA (`aowlspt.host::original_bytes`, primed before any
 * detour) and hands those bytes here. Same compare as the verify, against the
 * host's bytes instead of live memory; on a match the host's bytes are what
 * this mod's own snapshot table records for the RVA -- never the trampoline.
 * Everything that could refuse still refuses: module, section, page, length,
 * mismatch. */
static int32_t aowl_crva_t_accept(void* tp, const unsigned char* snap, int32_t n) {
    AowlCrvaTarget* t = (AowlCrvaTarget*)tp;
    int32_t why = AOWL_CRVA_OK;
    void* p;
    unsigned char b[AOWL_CRVA_SIG_BYTES];
    if (!t || !snap || n <= 0 || n > AOWL_CRVA_SIG_BYTES) return AOWL_CRVA_BAD_ARG;
    if (t->siglen <= 0) { t->why = AOWL_CRVA_NO_SIG; t->verified = 1; return t->why; }
    if (n < t->siglen) { t->why = AOWL_CRVA_MISMATCH; t->verified = 1; return t->why; }
    p = aowl_crva_code(t->rva, &why);
    if (!p) { t->why = why; t->verified = 1; return t->why; }
    if (memcmp(snap, t->sig, (size_t)t->siglen) != 0) {
        t->why = AOWL_CRVA_MISMATCH; t->verified = 1; return t->why;
    }
    memset(b, 0, sizeof b);
    memcpy(b, snap, (size_t)n);
    if (!aowl_crva_snap_find(t->rva)) (void)aowl_crva_snap_take(t->rva, b);
    t->fn = p;
    t->why = AOWL_CRVA_OK;
    t->verified = 1;
    return AOWL_CRVA_OK;
}

/* The nimony side carries the target as an opaque byte array, so the two
 * declarations of its SIZE must agree or the array is a buffer overrun waiting
 * to happen. Asserted at COMPILE time rather than trusted: a negative array
 * size is a hard error naming this line. */
typedef char aowl_crva_target_fits[(sizeof(AowlCrvaTarget) <= 64) ? 1 : -1];

/* Wrappers so the out-parameter is a plain pointer nimony can hand over. */
static float aowl_crva_cell_f32_w(int32_t i, int32_t off, void* ok) {
    int32_t k = 0; float v = aowl_crva_cell_f32(i, off, &k);
    if (ok) *(int32_t*)ok = k;
    return v;
}
static int32_t aowl_crva_cell_i32_w(int32_t i, int32_t off, void* ok) {
    int32_t k = 0; int32_t v = aowl_crva_cell_i32(i, off, &k);
    if (ok) *(int32_t*)ok = k;
    return v;
}
static void aowl_crva_w_f32(void* p, int32_t off, double v) {
    float f = (float)v;
    if (!p) return;
    memcpy((unsigned char*)p + off, &f, 4);
}
static const char* aowl_crva_reason_s(int32_t r) { return aowl_crva_reason(r); }

/* The two numbers that make "@0x0" unambiguous forever. `base` is
 * GameAssembly.dll's load address (0 = the module is not loaded, which is a
 * COMPLETELY different fault from a zeroed RVA); `fn` is what verify actually
 * resolved to, which is base+rva or NULL. Reported side by side so a zero on
 * one side can never be mistaken for a zero on the other. */
static uint64_t aowl_crva_base_u(void)  { return (uint64_t)(uintptr_t)aowl_crva_base(); }
static uint64_t aowl_crva_t_fn(void* p) { return (uint64_t)(uintptr_t)((AowlCrvaTarget*)p)->fn; }
static uint32_t aowl_crva_t_rva(void* p){ return ((AowlCrvaTarget*)p)->rva; }
static int32_t  aowl_crva_t_siglen(void* p){ return ((AowlCrvaTarget*)p)->siglen; }

/* `verified` and `why`, so `describe` can tell "not looked at yet" from
 * "looked at and refused". Without these it printed `resolved=0x0 <not
 * resolved>` for a target that verifies and calls perfectly a microsecond
 * later, because the wiring line is printed BEFORE the first verify -- a
 * diagnostic added to make a zeroed target unambiguous, being confidently
 * wrong about a healthy one. */
static int32_t  aowl_crva_t_verified(void* p){ return ((AowlCrvaTarget*)p)->verified; }
static int32_t  aowl_crva_t_why(void* p){ return ((AowlCrvaTarget*)p)->why; }

/* An 8-byte by-value aggregate, loaded as the packed value its register
 * carries. Out-parameter through `void*` like every other one here. */
static int32_t aowl_crva_agg8_w(const void* src, void* out) {
    int64_t v = 0;
    if (!aowl_crva_agg8(src, &v)) return 0;
    if (out) *(int64_t*)out = v;
    return 1;
}

/* The invoke wrapper: nimony cannot take the address of a local int64 and hand
 * it to C as `int64_t*` without a cast it refuses, so the out-parameters come
 * back through plain `void*` the same way every other out-parameter here does. */
static int32_t aowl_crva_invoke_w(void* t, void* mi, int32_t nslots,
                                  uint32_t mask, const void* a,
                                  int32_t retclass, void* og, void* of_) {
    int64_t g = 0; double f = 0.0;
    int32_t r = aowl_crva_invoke((AowlCrvaTarget*)t, mi, nslots, mask,
                                 (const AowlFastSlot*)a, retclass, &g, &f);
    if (og) *(int64_t*)og = g;
    if (of_) *(double*)of_ = f;
    return r;
}
""".}

proc cInvokeW(t: Il2CppPtr; mi: Il2CppPtr; nslots: int32; mask: uint32;
              a: Il2CppPtr; retclass: int32;
              og: Il2CppPtr; ofv: Il2CppPtr): int32 {.
  importc: "aowl_crva_invoke_w", nodecl.}
proc cReason(r: int32): cstring {.importc: "aowl_crva_reason_s", nodecl.}
proc cBaseU(): uint64 {.importc: "aowl_crva_base_u", nodecl.}
proc cTargetFn(t: Il2CppPtr): uint64 {.importc: "aowl_crva_t_fn", nodecl.}
proc cTargetRva(t: Il2CppPtr): uint32 {.importc: "aowl_crva_t_rva", nodecl.}
proc cTargetSiglen(t: Il2CppPtr): int32 {.importc: "aowl_crva_t_siglen", nodecl.}
proc cTargetVerified(t: Il2CppPtr): int32 {.importc: "aowl_crva_t_verified", nodecl.}
proc cTargetWhy(t: Il2CppPtr): int32 {.importc: "aowl_crva_t_why", nodecl.}
proc cAggClass(size: int32): int32 {.importc: "aowl_crva_agg_class", nodecl.}
proc cAgg8(src: Il2CppPtr; outv: Il2CppPtr): int32 {.importc: "aowl_crva_agg8_w", nodecl.}

const
  MaxCallSlots* = 12
    ## Total argument POSITIONS one call can have, counting an sret buffer,
    ## `this`, every declared argument and the trailing `MethodInfo*`.
    ##
    ## It was 5 -- what Win64 passes in registers before it starts using the
    ## stack -- and a wider shape was REFUSED rather than spilled, which
    ## blocked every 8- and 9-slot method outright. `aowlspt_fast.h` now emits
    ## the stack cases, so the cap is the table's width and not the register
    ## file's. It must equal `AOWL_FAST_MAX_SLOTS`; `aowl_crva_invoke` checks
    ## against the C constant, so a disagreement is a refusal and never a
    ## truncated call.
  RegisterSlots* = 4
    ## Positions 0..3 get a register (RCX/RDX/R8/R9, or XMM0..3 for a float).
    ## From position 4 up an argument is an 8-byte stack slot whatever its
    ## type, which is why `mask` only ever describes the first four.
  MaxArenaCells* = 16
  ArenaCellBytes* = 64

# ---------------------------------------------------------------------------
# A target
# ---------------------------------------------------------------------------

type
  RvaTarget* = object
    ## A method identified by its RVA and by the bytes it is DECLARED to start
    ## with. Declare one at module scope and reuse it: verification is
    ## capture-once and the result is cached, so the cost is paid on the first
    ## call and never again.
    name*: string
    rva*: uint32
    owners*: int32
      ## How many methods share this RVA, from the offline symbol table. 0 means
      ## "not stated". CALLING a shared RVA is fine -- it is correct code for
      ## the receiver passed -- so this is carried for the log line, not as a
      ## gate. DETOURING a shared RVA is the unbounded-blast-radius case, and
      ## this module never detours anything.
    declaredSig*: string
    storage*: array[64, uint8]   ## the opaque `AowlCrvaTarget`
    prepared*: bool

  CallKind* = enum
    coOk        ## the call ran and the value is real
    coRefused   ## nothing was called; `why` names the reason
    coFaulted   ## the call took an access violation and the guard caught it

  CallOutcome* = object
    kind*: CallKind
    why*: string
    code*: int32      ## the AOWL_CRVA_* verdict
    g*: int64         ## RAX, for integer/pointer/bool returns
    f*: float         ## XMM0, for float/double returns

  CallArgs* = object
    ## The register slots for one call, filled positionally. Nothing is
    ## inferred: slot 0 is whatever the caller says slot 0 is -- `this` for an
    ## instance method, the hidden return buffer for an sret call, or the first
    ## argument for a plain static one.
    slots*: array[12, uint64]
    n*: int32
    mask*: uint32
      ## bit i set => slot i is a float, i.e. XMM_i. Only bits 0..3 mean
      ## anything: a float in position 4 or beyond is an 8-byte stack slot
      ## carrying the float bits in its low half, so there is no register
      ## class left to choose. `AOWL_FAST_CODE` narrows the mask to four bits
      ## for that reason, and `addFloat` stops setting bits past `RegisterSlots`.
    cells*: int32       ## arena cells consumed so far
    bad*: bool          ## a staging step refused; the call must not run
    badWhy*: string

proc hexRva(v: uint32): string =
  ## Lower-case hex, no prefix. Local because the SDK has no `toHex` and a
  ## second dependency for eight characters is not worth one.
  const digits = "0123456789abcdef"
  result = ""
  var started = false
  var shift = 28
  while shift >= 0:
    let nib = int((v shr uint32(shift)) and 0xF'u32)
    if nib != 0 or started or shift == 0:
      started = true
      result.add digits[nib]
    shift = shift - 4

proc reasonOf(code: int32): string =
  result = ""
  let c = cReason(code)
  var i = 0
  while i < 4096:
    let ch = c[i]
    if ch == '\0': break
    result.add ch
    inc i

proc hexNib(c: char; v: var int32): bool =
  if c >= '0' and c <= '9': v = int32(ord(c) - ord('0')); return true
  if c >= 'a' and c <= 'f': v = int32(ord(c) - ord('a') + 10); return true
  if c >= 'A' and c <= 'F': v = int32(ord(c) - ord('A') + 10); return true
  result = false

proc rvaTarget*(name: string; rva: uint32; prologueHex: string;
                owners: int32 = 0): RvaTarget =
  ## Declare a call target.
  ##
  ## `prologueHex` is the DECLARED prologue -- paste it from
  ## `il2cpp_resolve.py ... bytes <RVA> 16`, space-separated or not. It is what
  ## makes a stale RVA on a different game build a loud refusal instead of a
  ## jump into the middle of an unrelated function, so an empty string is
  ## itself refused at call time (`AOWL_CRVA_NO_SIG`) rather than treated as
  ## "nothing asserted".
  result = RvaTarget(name: name, rva: rva, owners: owners,
                     declaredSig: prologueHex, prepared: false)
  for i in 0 ..< 64:
    result.storage[i] = 0'u8

proc prepare(t: var RvaTarget) =
  ## Parse the declared prologue into the C target, once. Capped at 16 bytes
  ## and at 4x that many characters; a malformed string produces a SHORT
  ## signature, which then fails the compare rather than passing a partial one.
  if t.prepared: return
  t.prepared = true
  let p = cast[Il2CppPtr](addr t.storage[0])
  cTargetInit(p, t.rva)
  cTargetSetOwners(p, t.owners)
  var hi = -1'i32
  var idx = 0'i32
  var i = 0
  while i < t.declaredSig.len and idx < 16'i32:
    var v = 0'i32
    if hexNib(t.declaredSig[i], v):
      if hi < 0:
        hi = v
      else:
        cTargetSigByte(p, idx, hi * 16'i32 + v)
        inc idx
        hi = -1'i32
    inc i

proc hex64(v: uint64): string =
  const digits = "0123456789abcdef"
  result = ""
  var started = false
  var shift = 60
  while shift >= 0:
    let nib = int((v shr uint64(shift)) and 0xF'u64)
    if nib != 0 or started or shift == 0:
      started = true
      result.add digits[nib]
    shift = shift - 4

proc describe*(t: var RvaTarget): string =
  ## Everything needed to tell a zeroed target from an unloaded module from a
  ## bad address, in one line. A bare "@0x0" was ambiguous between all three
  ## and cost a whole live run to disambiguate; it never will again.
  prepare(t)
  let p = cast[Il2CppPtr](addr t.storage[0])
  let base = cBaseU()
  let rva = cTargetRva(p)
  let fn = cTargetFn(p)
  # `resolved` has THREE readings and used to have one. A target that has not
  # been verified yet has fn == 0 and is perfectly healthy -- which is the
  # normal state of the wiring line, because it is printed BEFORE the first
  # verify on purpose. Printing "<not resolved>" there was a diagnostic added
  # to make a zeroed target unambiguous, being confidently wrong about a
  # target whose very next call succeeded. Three outcomes, never two.
  let resolved =
    if fn != 0'u64: "0x" & hex64(fn)
    elif cTargetVerified(p) == 0'i32:
      "<NOT YET VERIFIED -- verify() has not run on this target; this is not a failure>"
    else:
      "<REFUSED: " & reasonOf(cTargetWhy(p)) & ">"
  result = "name=" & (if t.name.len == 0: "<EMPTY>" else: t.name) &
    " rva=0x" & hexRva(rva) &
    " siglen=" & $cTargetSiglen(p) &
    " base=0x" & (if base == 0'u64: "0 <GameAssembly.dll NOT LOADED>" else: hex64(base)) &
    " resolved=" & resolved

proc looksZeroed*(t: RvaTarget): bool =
  ## The signature of the nimony `--app:lib` module-scope trap: a global
  ## initialised by a CALL is silently left zeroed, so name, rva and the
  ## declared prologue are ALL empty at once. That triple can only happen one
  ## way, and it is worth naming rather than letting it present as "no prologue
  ## was declared" -- which is true, and is not the cause.
  t.rva == 0'u32 and t.declaredSig.len == 0 and t.name.len == 0

const AowlCrvaDetoured = 5'i32
  ## `AOWL_CRVA_DETOURED` in abi/aowlspt_callrva.h; mirrored here because the
  ## nimony side branches on it and a header define is not visible to nimony.

proc hostSnapshot(rva: uint32; outb: var array[16, uint8]; n: var int;
                  why: var string): bool =
  ## Ask the host for its STARTUP snapshot of the first bytes at `rva` --
  ## `call("aowlspt.host::original_bytes", {"rva":"0x.."})`, answered from the
  ## prologue table the host primes before it installs any detour. Three
  ## outcomes: bytes (true), the host said it has no row (false, `why` quotes
  ## it), or the host has no such verb / is not bound (false, `why` says so).
  ## A host that predates the verb makes every detoured target a refusal, as
  ## before -- never a silent pass.
  n = 0
  why = ""
  if not hostReady():
    why = "the host is not bound yet, so it could not be asked"
    return false
  var raw = ""
  let args = "{\"rva\":\"0x" & hexRva(rva) & "\"}"
  let st = call("aowlspt.host::original_bytes", args, raw)
  if st != Ok:
    why = "this host has no `aowlspt.host::original_bytes` verb (status " &
          $st & "), so a function the host detours cannot be verified from " &
          "a mod on this host build"
    return false
  if find(raw, "\"have\":true") < 0:
    why = "the host answered without bytes: " & raw
    return false
  let at = find(raw, "\"bytes\":\"")
  if at < 0:
    why = "the host said have=true but carried no `bytes` field: " & raw
    return false
  var i = at + 9
  var hi = -1'i32
  while i < raw.len and n < 16:
    let c = raw[i]
    if c == '"': break
    var v = 0'i32
    if not hexNib(c, v):
      why = "the host's `bytes` field is not hex: " & raw
      n = 0
      return false
    if hi < 0:
      hi = v
    else:
      outb[n] = uint8(hi * 16'i32 + v)
      inc n
      hi = -1'i32
    inc i
  if n == 0:
    why = "the host's `bytes` field was empty: " & raw
    return false
  result = true

proc verify*(t: var RvaTarget): CallOutcome =
  ## Byte-verify the target without calling it. Idempotent and cached. Safe to
  ## run at mod init: it only reads the code page and never patches.
  ##
  ## A target whose LIVE first bytes are a JUMP is not refused outright any
  ## more: the host is asked for its pre-detour snapshot and the compare runs
  ## against that (see `hostSnapshot`). Calling through a hook is correct;
  ## what was never acceptable was trusting a trampoline as identity.
  if looksZeroed(t):
    return CallOutcome(kind: coRefused, code: 7'i32, g: 0'i64, f: 0.0,
      why: "this RvaTarget is entirely ZEROED (no name, rva 0, no prologue). " &
           "That is the nimony --app:lib trap `aowlspt/fast` documents: a " &
           "global initialised by a CALL at module scope is silently left " &
           "zeroed. Declare the global BARE and assign it from onLoad, never " &
           "`var t = rvaTarget(...)` at module scope.")
  prepare(t)
  let ownersNote =
    (if t.owners == 1'i32: ", 1 owner"
     elif t.owners > 1'i32: ", " & $t.owners & " owners share this RVA (fine to CALL, never to detour)"
     else: "")
  let code = cTargetVerify(cast[Il2CppPtr](addr t.storage[0]))
  if code == 0'i32:
    result = CallOutcome(kind: coOk, why: t.name & ": prologue verified " &
      "against the snapshot [" & describe(t) & "]" & ownersNote,
      code: 0'i32, g: 0'i64, f: 0.0)
  elif code == AowlCrvaDetoured:
    # The live bytes are somebody's JUMP. That somebody is almost always the
    # HOST (MEASURED 2026-09-05: Toggle::Set, SettingsScreen::Close and
    # MenuScreen::ShowInRaid, all hooked by uihooks/nativetabs), and CALLING
    # through a hook is correct -- the hook runs, then the original. What the
    # byte-compare is for is identity, and the host kept the pre-detour bytes:
    # ask it. No answer, or a different answer, is still a refusal.
    var snap = [0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8,
                0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8]
    var n = 0
    var whyHost = ""
    if hostSnapshot(t.rva, snap, n, whyHost):
      let code2 = cTargetAccept(cast[Il2CppPtr](addr t.storage[0]),
                                cast[Il2CppPtr](addr snap[0]), int32(n))
      if code2 == 0'i32:
        result = CallOutcome(kind: coOk, why: t.name & ": prologue verified " &
          "against the HOST's startup snapshot -- the live bytes are a JUMP " &
          "because the host itself detours this function; a CALL goes " &
          "through its hook and then the original, which is correct code " &
          "for this receiver [" & describe(t) & "]" & ownersNote,
          code: 0'i32, g: 0'i64, f: 0.0)
      else:
        result = CallOutcome(kind: coRefused,
          why: t.name & ": " & reasonOf(code2) & " -- compared against the " &
               "HOST's startup snapshot, because the live bytes are a JUMP [" &
               describe(t) & "]",
          code: code2, g: 0'i64, f: 0.0)
    else:
      result = CallOutcome(kind: coRefused,
        why: t.name & ": " & reasonOf(code) & "; the host was asked for its " &
             "startup snapshot of this RVA and " & whyHost & " [" &
             describe(t) & "]",
        code: code, g: 0'i64, f: 0.0)
  else:
    result = CallOutcome(kind: coRefused,
      why: t.name & ": " & reasonOf(code) & " [" & describe(t) & "]",
      code: code, g: 0'i64, f: 0.0)

proc faultCount*(): int32 =
  ## How many guarded calls have faulted, process-wide. A mod self-disables off
  ## this rather than inventing its own counter.
  cFaultCount()

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

proc callArgs*(): CallArgs =
  result = CallArgs(n: 0'i32, mask: 0'u32, cells: 0'i32, bad: false, badWhy: "",
                    slots: [0'u64, 0'u64, 0'u64, 0'u64, 0'u64, 0'u64,
                            0'u64, 0'u64, 0'u64, 0'u64, 0'u64, 0'u64])

proc refuse(a: var CallArgs; why: string) =
  if not a.bad:
    a.bad = true
    a.badWhy = why

proc addPtr*(a: var CallArgs; p: Il2CppPtr) =
  ## A reference: an object, a string, an array, `this`. The pointer itself.
  if a.n >= int32(MaxCallSlots):
    refuse(a, "more than " & $MaxCallSlots & " argument slots"); return
  cSlotSetP(cast[Il2CppPtr](addr a.slots[0]), a.n, p)
  inc a.n

proc addInt*(a: var CallArgs; v: int64) =
  ## Every integer, bool and enum: one general-purpose register.
  if a.n >= int32(MaxCallSlots):
    refuse(a, "more than " & $MaxCallSlots & " argument slots"); return
  cSlotSetG(cast[Il2CppPtr](addr a.slots[0]), a.n, v)
  inc a.n

proc addBool*(a: var CallArgs; v: bool) =
  addInt(a, (if v: 1'i64 else: 0'i64))

proc addFloat*(a: var CallArgs; v: float) =
  ## A C# `float`. It lands in XMM_i for its slot INDEX i -- measured on
  ## `Physics::Raycast@0x5328830`, whose third parameter arrives in XMM2 while
  ## slots 0 and 1 are consumed by pointers. Position picks the register; the
  ## other slots being integer-class does not shift it.
  if a.n >= int32(MaxCallSlots):
    refuse(a, "more than " & $MaxCallSlots & " argument slots"); return
  cSlotSetF(cast[Il2CppPtr](addr a.slots[0]), a.n, v)
  # Only the first four positions have a register class to choose. Past that
  # the float travels as an 8-byte stack slot with its bits in the low half --
  # `cSlotSetF` writes all eight bytes so the high half is defined -- and
  # setting a mask bit there would describe a register that is not used.
  if a.n < int32(RegisterSlots):
    a.mask = a.mask or (1'u32 shl uint32(a.n))
  inc a.n

proc addAggregate*(a: var CallArgs; src: Il2CppPtr; size: int32) =
  ## A by-value struct argument.
  ##
  ## MEASURED on this build, from the callee's own bytes: an aggregate wider
  ## than a register arrives as a POINTER in the integer-class register for its
  ## position. `Vector3::Dot@0x5297BF0` dereferences RCX and RDX at +0/+4/+8;
  ## `Camera::WorldToScreenPoint@0x525F940` dereferences R8. This copies `size`
  ## bytes into an arena cell the call keeps alive and passes that cell.
  ##
  ## An aggregate of EXACTLY 8 bytes goes the other way: packed INTO the
  ## integer-class register, first field in the low half. That is measured, on
  ## this build, from `Vector2::Dot@0x529BB60`, whose whole body spills RCX and
  ## RDX to the stack and reads its four floats out of the spilled bytes --
  ## it never dereferences either register. So this stages no arena cell for a
  ## size of 8; it loads the eight bytes and passes them as the value.
  ##
  ## Sizes 1, 2 and 4 are STILL REFUSED. The ABI rule that covers 8 covers
  ## them, and that extrapolation is exactly what left 8 filed as unknowable
  ## for months while the answer sat in a callee we could already read.
  ## Nothing needs them yet; whatever needs one first should measure it.
  let klass = cAggClass(size)
  if klass == 2'i32:                     # AOWL_CRVA_AGG_INREG
    var packed = 0'i64
    if cAgg8(src, cast[Il2CppPtr](addr packed)) == 0'i32:
      refuse(a, "an 8-byte by-value aggregate whose source failed VirtualQuery")
      return
    addInt(a, packed)
    return
  if klass != 1'i32:                     # AOWL_CRVA_AGG_POINTER
    refuse(a, "a " & $size & "-byte by-value aggregate: on Win64 a size of " &
              "exactly 1, 2 or 4 passes IN the register rather than by " &
              "pointer, and THAT size has not been measured on this build. " &
              "(8 bytes has been, and is accepted.) Refusing rather than " &
              "choosing one of two conventions.")
    return
  if a.cells >= int32(MaxArenaCells):
    refuse(a, "more than " & $MaxArenaCells & " staged aggregates in one call"); return
  let cell = cArgAgg(a.cells, src, size)
  if cell == nil:
    refuse(a, "staging a " & $size & "-byte aggregate: the source failed " &
              "VirtualQuery, or it does not fit an arena cell (" &
              $ArenaCellBytes & " bytes)")
    return
  inc a.cells
  addPtr(a, cell)

proc addVec3*(a: var CallArgs; x, y, z: float) =
  ## The common case, spelled out. Layout x@0 y@4 z@8 is not assumed -- it is
  ## read straight off `Vector3::Dot@0x5297BF0`, which multiplies `[rcx]` by
  ## `[rdx]`, `[rcx+4]` by `[rdx+4]` and `[rcx+8]` by `[rdx+8]`.
  if a.cells >= int32(MaxArenaCells):
    refuse(a, "more than " & $MaxArenaCells & " staged aggregates in one call"); return
  let cell = cArgOut(a.cells, 12'i32)
  if cell == nil:
    refuse(a, "no arena cell for a Vector3"); return
  cWriteF32(cell, 0'i32, x)
  cWriteF32(cell, 4'i32, y)
  cWriteF32(cell, 8'i32, z)
  inc a.cells
  addPtr(a, cell)

proc addVec2*(a: var CallArgs; x, y: float) =
  ## A by-value `UnityEngine.Vector2`. Eight bytes, so it travels PACKED IN the
  ## register rather than by pointer, and no arena cell is consumed.
  ##
  ## Layout x@0 y@4 is not assumed -- it is read straight off
  ## `Vector2::Dot@0x529BB60`, which multiplies the low half of RCX by the low
  ## half of RDX and byte 4 of each by byte 4 of the other.
  var bits = 0'i64
  var buf: array[8, uint8] = [0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8]
  cWriteF32(cast[Il2CppPtr](addr buf[0]), 0'i32, x)
  cWriteF32(cast[Il2CppPtr](addr buf[0]), 4'i32, y)
  if cAgg8(cast[Il2CppPtr](addr buf[0]), cast[Il2CppPtr](addr bits)) == 0'i32:
    refuse(a, "a Vector2 could not be packed"); return
  addInt(a, bits)

proc addOut*(a: var CallArgs; size: int32): int32 =
  ## An `out`/`ref` parameter: a zeroed arena cell the callee writes through.
  ## Returns the CELL INDEX to read back with `outFloat`/`outInt` after the
  ## call, or -1 if it refused.
  ##
  ## Sizing an out-buffer is the caller's responsibility and it must come from
  ## `instance_size`, NOT from subtracting a header from boxed field offsets.
  ## The `UnityEngine.AI.NavMeshHit` case is the live example: boxed offsets
  ## give m_Position@0x10 .. m_Hit@0x30, which INFERS a 36-byte unboxed payload
  ## -- an inference, not a measurement. Confirm `instance_size` before
  ## allocating against it.
  result = -1'i32
  if a.cells >= int32(MaxArenaCells):
    refuse(a, "more than " & $MaxArenaCells & " staged buffers in one call"); return
  let cell = cArgOut(a.cells, size)
  if cell == nil:
    refuse(a, "an out-buffer of " & $size & " bytes does not fit an arena cell (" &
              $ArenaCellBytes & " bytes)")
    return
  result = a.cells
  inc a.cells
  addPtr(a, cell)

proc addSret*(a: var CallArgs; size: int32): int32 =
  ## The HIDDEN RETURN BUFFER for a method returning an aggregate wider than 8
  ## bytes. It must be slot 0, before `this` and before every argument.
  ##
  ## MEASURED, twice, and the two cases agree:
  ##   static   `Vector3::Cross@0x5297A60` -- args are in RDX and R8, one
  ##            register right of where `Dot` (same parameters, scalar return)
  ##            puts them, so RCX is the buffer.
  ##   instance `Camera::WorldToScreenPoint@0x525F940` -- writes `[rcx]` and
  ##            `[rcx+8]`, reads `this` from RDX and the argument through R8.
  ##
  ## So: RCX = retbuf, RDX = this-or-arg0, R8 = next, R9 = MethodInfo*.
  ## A Vector2 (8 bytes) does NOT use this shape -- it comes back packed in
  ## RAX -- so passing a size of 8 here would be the wrong call entirely and
  ## `addOut` refuses it for you.
  if a.n != 0'i32:
    refuse(a, "the hidden return buffer must be slot 0, before `this` and " &
              "every argument")
    return -1'i32
  result = addOut(a, size)

proc outFloat*(cell: int32; off: int32; ok: var bool): float =
  ## Read a float back out of an out/sret cell. `ok` is false when the read
  ## could not be made -- which is not the same answer as 0.0, and this never
  ## flattens the two.
  var k = 0'i32
  result = cCellF32(cell, off, cast[Il2CppPtr](addr k))
  ok = k != 0'i32

proc outInt*(cell: int32; off: int32; ok: var bool): int32 =
  var k = 0'i32
  result = cCellI32(cell, off, cast[Il2CppPtr](addr k))
  ok = k != 0'i32

proc outPtr*(cell: int32): Il2CppPtr =
  ## The address of an out cell, for a caller that wants to read it with the
  ## ordinary field helpers.
  cCell(cell)

# ---------------------------------------------------------------------------
# Strings
# ---------------------------------------------------------------------------

proc addString*(a: var CallArgs; rt: Il2Cpp; s: string) =
  ## A `System.String` argument, built with `il2cpp_string_new`.
  ##
  ## This is a separate entry point rather than something `addPtr` hides because
  ## it is the one argument form that runs GAME code to produce the argument,
  ## and that call goes through the EXPORT ABI rather than through this module.
  ##
  ## A NOTE ON WHY THAT DISTINCTION NOW MATTERS. This module used to be able to
  ## say "the export surface barely works, so RVA calls are all we have". That
  ## reason is measured false: `docs/IL2CPP_EXPORTS.md` (branch
  ## `feat-il2cpp-export-map`) shows the build is stock IL2CPP with a
  ## TOKEN-GATED export ABI -- 38 of 241 exports take an extra trailing pointer
  ## to 32 bytes and `memcmp` it, and on mismatch return a UNIFORM RANDOM
  ## NON-ZERO uint64 rather than NULL. That is what "a non-nil handle that kills
  ## the client on first dereference" always was. `il2cpp_string_new` is not in
  ## the gated set on that map, which is why this works today.
  ##
  ## The reason to prefer an RVA call is therefore NOT that the exports are
  ## broken. It is that a direct RVA call does not go through the export ABI at
  ## all, so it is unaffected by the gates, by a nonce, or by anything else that
  ## surface does -- and that it never resolves a NAME (fact #145).
  ##
  ## It ALLOCATES on the managed heap, so it must not be on a per-frame path
  ## (rule 7). Build the string once, keep the `Il2CppString`, and pass it with
  ## `addPtr` thereafter.
  let sp = newString(rt, s)
  if cast[Il2CppPtr](sp) == nil:
    refuse(a, "il2cpp_string_new returned null for a " & $s.len & "-char string")
    return
  addPtr(a, cast[Il2CppPtr](sp))

# ---------------------------------------------------------------------------
# Calling
# ---------------------------------------------------------------------------

proc run(t: var RvaTarget; a: var CallArgs; retclass: int32): CallOutcome =
  if a.bad:
    return CallOutcome(kind: coRefused,
      why: t.name & ": arguments were not staged -- " & a.badWhy,
      code: 8'i32, g: 0'i64, f: 0.0)
  if looksZeroed(t):
    return CallOutcome(kind: coRefused, code: 7'i32, g: 0'i64, f: 0.0,
      why: "refusing to call an entirely ZEROED RvaTarget -- see `verify` for " &
           "the module-scope initialiser trap this is")
  prepare(t)
  var g = 0'i64
  var f = 0.0
  let code = cInvokeW(cast[Il2CppPtr](addr t.storage[0]), nil, a.n, a.mask,
                      cast[Il2CppPtr](addr a.slots[0]), retclass,
                      cast[Il2CppPtr](addr g), cast[Il2CppPtr](addr f))
  if code == 0'i32:
    result = CallOutcome(kind: coOk, why: "", code: 0'i32, g: g, f: f)
  elif code == 10'i32:
    result = CallOutcome(kind: coFaulted,
      why: t.name & ": " & reasonOf(code) & " (fault " & $faultCount() &
           ") [" & describe(t) & "]",
      code: code, g: 0'i64, f: 0.0)
  else:
    result = CallOutcome(kind: coRefused,
      why: t.name & ": " & reasonOf(code) & " [" & describe(t) & "]",
      code: code, g: 0'i64, f: 0.0)

proc callVoid*(t: var RvaTarget; a: var CallArgs): CallOutcome =
  run(t, a, 0'i32)

proc callInt*(t: var RvaTarget; a: var CallArgs): CallOutcome =
  ## Every integer-class return: int, enum, and any pointer or reference. RAX.
  run(t, a, 0'i32)

proc callBool*(t: var RvaTarget; a: var CallArgs): CallOutcome =
  ## A `bool` return. Only the low byte of RAX is defined, so it is masked here
  ## rather than left to a caller to remember.
  result = run(t, a, 0'i32)
  if result.kind == coOk:
    result.g = result.g and 0xFF'i64

proc callPtr*(t: var RvaTarget; a: var CallArgs): CallOutcome =
  run(t, a, 0'i32)

proc callFloat*(t: var RvaTarget; a: var CallArgs): CallOutcome =
  ## A C# `float` return: 32 bits in XMM0. Not interchangeable with `callDouble`
  ## -- reading one as the other produces a number rather than an error.
  run(t, a, 1'i32)

proc callDouble*(t: var RvaTarget; a: var CallArgs): CallOutcome =
  run(t, a, 2'i32)

proc asPtr*(o: CallOutcome): Il2CppPtr =
  ## The returned reference, or nil. nil for a refusal too -- always check
  ## `kind` first; this deliberately does not encode "refused" as a pointer.
  if o.kind == coOk: cast[Il2CppPtr](o.g) else: cast[Il2CppPtr](0)

proc asBool*(o: CallOutcome): bool =
  if o.kind == coOk: o.g != 0'i64 else: false
