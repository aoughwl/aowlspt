## aowlscene.nim -- the LIVE SCENE API, the "talk to the running Unity game"
## foundation layer that the UI framework and mods build on.
##
## WHERE IT LIVES AND WHY
## ----------------------
## A standalone, importable Nimony module (NOT `include`d into `aowlhost.nim`
## like `nativeui.nim`/`invoke2.nim`), so BOTH the host and a mod can
## `import aowlscene` and get the same surface. Its only dependency is
## `aowlspt/il2cpp` (pure handle types) plus its own C header
## `abi/aowlspt_scene.h`, which REUSES the already-proven machinery of
## `aowlspt_invoke2.h` (verified-RVA target table, shaped call thunks,
## il2cpp_string_new) and `aowlspt_shim.h` (the VirtualQuery gate and the ONE
## SEH guard). It adds no new calling-convention claim -- every RVA it calls was
## resolved offline and is byte-verified at runtime.
##
## WHAT IS PROVEN vs WHAT NEEDS A LIVE RUN
## ---------------------------------------
## PROVEN OFFLINE (tests/scene/scene_selftest.c, exit 0): the sharedness verdict,
## the liveness predicate, the Vector2 RAX decode, the float reinterpret, the
## guarded typed field read/write, and that every RVA lookup DECLINES (returns
## nil) rather than faulting when the prologue does not verify.
##
## NEEDS A LIVE RUN (INCONCLUSIVE until the coordinator deploys and runs
## `sceneProofRun` from a Unity-thread detour): the managed calls themselves --
## get_gameObject, get_transform, get_name, GetInstanceID, get_parent,
## get_childCount, GetChild, Transform::Find, Component::GetComponent. The exact
## host-log line that settles each is named in `sceneProofReport`.
##
## THE GUARD CONTRACT (rule 3, non-negotiable)
## -------------------------------------------
## The ONE `aowl_p_p_seh` is NOT re-entrant. Every proc here assumes it is
## already running inside the caller's single guard (which the host establishes
## at the `TarkovApplication::Update` bridge / a detour entry). These procs do
## NOT wrap themselves -- doing so would DISARM the outer guard. The exception is
## `sceneProofRun`, which is a standalone entry point and therefore establishes
## exactly one guard around its whole body via `aowl_p_p_seh`.
##
## Every hop is re-validated by the code that consumes it: a call that faulted or
## hit a dead wrapper returns nil, and the next step NOTICES rather than
## dereferencing it. A bad handle REFUSES with a named reason; it never faults
## the client. That refusal-not-fault property is the whole value of this layer.

import aowlspt/il2cpp

{.emit: """#include "aowlspt_scene.h" """.}

# ---------------------------------------------------------------------------
# C surface (abi/aowlspt_scene.h) + reused invoke2 primitives
# ---------------------------------------------------------------------------
proc cSceneFn(i: int32): Il2CppPtr {.importc: "aowl_scene_fn", nodecl.}
proc cSceneName(i: int32): cstring {.importc: "aowl_scene_name", nodecl.}
proc cSceneRva(i: int32): uint32 {.importc: "aowl_scene_rva", nodecl.}
proc cSceneTargetCount(): int32 {.importc: "aowl_scene_target_count", nodecl.}
proc cSceneOkCount(): int32 {.importc: "aowl_scene_ok_count", nodecl.}
proc cSceneBadCount(): int32 {.importc: "aowl_scene_bad_count", nodecl.}

proc cSceneCallPPI(fn, self: Il2CppPtr; a0: int32): Il2CppPtr {.
  importc: "aowl_scene_call_p_pi", nodecl.}

proc cSceneAlive(obj: Il2CppPtr): int32 {.importc: "aowl_scene_alive", nodecl.}
proc cSceneCachedAlive(v: uint64): int32 {.
  importc: "aowl_scene_cachedptr_alive", nodecl.}

proc cSceneFieldReadable(obj: Il2CppPtr; off, n: int32): int32 {.
  importc: "aowl_scene_field_readable", nodecl.}
proc cSceneReadBits(obj: Il2CppPtr; off, n: int32; ok: var int32): uint64 {.
  importc: "aowl_scene_read_bits", nodecl.}
proc cSceneWriteBits(obj: Il2CppPtr; off, n: int32; val: uint64): int32 {.
  importc: "aowl_scene_write_bits", nodecl.}

proc cSceneBitsF32(b: uint32): float32 {.importc: "aowl_scene_bits_f32", nodecl.}
proc cSceneBitsF64(b: uint64): float64 {.importc: "aowl_scene_bits_f64", nodecl.}
proc cSceneF32Bits(v: float32): uint32 {.importc: "aowl_scene_f32_bits", nodecl.}
proc cSceneF64Bits(v: float64): uint64 {.importc: "aowl_scene_f64_bits", nodecl.}

proc cSceneVec2X(packed: uint64): float64 {.importc: "aowl_scene_vec2_x", nodecl.}
proc cSceneVec2Y(packed: uint64): float64 {.importc: "aowl_scene_vec2_y", nodecl.}

proc cSceneShareVerdict(owners: int32): int32 {.
  importc: "aowl_scene_share_verdict", nodecl.}

# reused from aowlspt_invoke2.h (pulled in by aowlspt_scene.h)
proc cMi2Fn(i: int32): Il2CppPtr {.importc: "aowl_mi2_fn", nodecl.}
proc cMi2CallPP(fn, self: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mi2_call_p_p", nodecl.}
proc cMi2CallIP(fn, self: Il2CppPtr): int32 {.
  importc: "aowl_mi2_call_i_p", nodecl.}
proc cMi2CallPPP(fn, self, a0: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mi2_call_p_pp", nodecl.}
proc cMi2StringNew(s: cstring): Il2CppPtr {.
  importc: "aowl_mi2_string_new", nodecl.}

# the self-proof body + result readback (from aowlspt_scene.h)
proc cSceneProofGuarded(self: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_scene_proof_guarded", nodecl.}
proc cSceneProofStep(i: int32): int32 {.
  importc: "aowl_scene_proof_step_get", nodecl.}
proc cSceneProofInstanceId(): int32 {.
  importc: "aowl_scene_proof_instanceid_get", nodecl.}
proc cSceneProofChildCount(): int32 {.
  importc: "aowl_scene_proof_childcount_get", nodecl.}
proc cSceneProofRan(): int32 {.importc: "aowl_scene_proof_ran_get", nodecl.}

# invoke2 target indices this API reuses (mirroring the AOWL_MI2_* defines).
const
  Mi2GetGameObject  = 0'i32   ## UnityEngine.Component::get_gameObject
  Mi2GetInstanceId  = 1'i32   ## UnityEngine.Object::GetInstanceID
  Mi2GetName        = 2'i32   ## UnityEngine.Object::get_name
  Mi2GoGetTransform = 9'i32   ## UnityEngine.GameObject::get_transform

# scene target indices (mirroring the AOWL_SCENE_* defines).
const
  ScGetParent     = 0'i32   ## UnityEngine.Transform::get_parent
  ScGetChildCount = 1'i32   ## UnityEngine.Transform::get_childCount
  ScGetChild      = 2'i32   ## UnityEngine.Transform::GetChild
  ScFind          = 3'i32   ## UnityEngine.Transform::Find
  ScGetComponent  = 4'i32   ## UnityEngine.Component::GetComponent(string)

# ---------------------------------------------------------------------------
# Three-outcome results. PASS / FAIL / INCONCLUSIVE, never two. (CLAUDE.md 9b)
#
# A ref result carries an Il2CppPtr; a value result an int64 / float64. The
# `why` string is filled on every non-PASS so a refusal can name its reason,
# and left empty on PASS.
# ---------------------------------------------------------------------------
type
  Outcome* = enum
    ocInconclusive = 0   ## could not look: unverified RVA, unreadable hop, no receiver
    ocPass         = 1
    ocFail         = 2   ## looked, and the finished state is wrong

  RefResult* = object
    outcome*: Outcome
    value*: Il2CppPtr
    why*: string

  IntResult* = object
    outcome*: Outcome
    value*: int64
    why*: string

  FloatResult* = object
    outcome*: Outcome
    value*: float64
    why*: string

  Vec2* = object
    x*, y*: float64

proc refPass(p: Il2CppPtr): RefResult = RefResult(outcome: ocPass, value: p, why: "")
proc refFail(why: string): RefResult = RefResult(outcome: ocFail, value: nil, why: why)
proc refInc(why: string): RefResult =
  RefResult(outcome: ocInconclusive, value: nil, why: why)

proc intPass(v: int64): IntResult = IntResult(outcome: ocPass, value: v, why: "")
proc intFail(why: string): IntResult = IntResult(outcome: ocFail, value: 0, why: why)
proc intInc(why: string): IntResult =
  IntResult(outcome: ocInconclusive, value: 0, why: why)

proc floatPass(v: float64): FloatResult =
  FloatResult(outcome: ocPass, value: v, why: "")
proc floatInc(why: string): FloatResult =
  FloatResult(outcome: ocInconclusive, value: 0.0, why: why)

proc isPass*(r: RefResult): bool = r.outcome == ocPass
proc isPass*(r: IntResult): bool = r.outcome == ocPass
proc isPass*(r: FloatResult): bool = r.outcome == ocPass

# ---------------------------------------------------------------------------
# Liveness -- the canonical gate. (fact #182/#184)
# ---------------------------------------------------------------------------
proc isAlive*(obj: Il2CppPtr): bool =
  ## True iff `obj` is a live Unity wrapper: readable AND its native half
  ## (`m_CachedPtr` @ +0x10) is non-zero. A "!= nil" check is NOT enough -- a
  ## destroyed object keeps a valid-looking wrapper whose every engine call
  ## faults. Use this before ANY call that reaches into Unity.
  obj != nil and cSceneAlive(obj) != 0

# ---------------------------------------------------------------------------
# Identity / naming -- proven read-only getters (invoke2 table).
# ---------------------------------------------------------------------------
proc gameObjectOf*(comp: Il2CppPtr): RefResult =
  ## The GameObject owning a live Component. `comp` MUST be a Component (a
  ## Transform is one); Component::get_gameObject.
  if not isAlive(comp): return refInc("receiver is not a live Component")
  let fn = cMi2Fn(Mi2GetGameObject)
  if fn == nil: return refInc("get_gameObject RVA did not verify on this build")
  let go = cMi2CallPP(fn, comp)
  if go == nil or not isAlive(go): return refFail("get_gameObject returned a dead/nil object")
  refPass(go)

proc transformOf*(go: Il2CppPtr): RefResult =
  ## The Transform of a live GameObject; GameObject::get_transform.
  if not isAlive(go): return refInc("receiver is not a live GameObject")
  let fn = cMi2Fn(Mi2GoGetTransform)
  if fn == nil: return refInc("get_transform RVA did not verify on this build")
  let tr = cMi2CallPP(fn, go)
  if tr == nil or not isAlive(tr): return refFail("get_transform returned a dead/nil Transform")
  refPass(tr)

proc instanceId*(obj: Il2CppPtr): IntResult =
  ## Object::GetInstanceID. A live object's id is never 0, so the answer is
  ## self-validating.
  if not isAlive(obj): return intInc("receiver is not a live object")
  let fn = cMi2Fn(Mi2GetInstanceId)
  if fn == nil: return intInc("GetInstanceID RVA did not verify on this build")
  let id = cMi2CallIP(fn, obj)
  if id == 0: return intFail("GetInstanceID returned 0 on a supposedly live object")
  intPass(int64(id))

proc nameHandle*(obj: Il2CppPtr): RefResult =
  ## Object::get_name -> a managed System.String reference (decode with the
  ## host's fixed String layout). Read-only.
  if not isAlive(obj): return refInc("receiver is not a live object")
  let fn = cMi2Fn(Mi2GetName)
  if fn == nil: return refInc("get_name RVA did not verify on this build")
  let s = cMi2CallPP(fn, obj)
  if s == nil: return refFail("get_name returned nil")
  refPass(s)

# ---------------------------------------------------------------------------
# Hierarchy -- verified scene table (get_parent/childCount/GetChild/Find).
# ---------------------------------------------------------------------------
proc parentOf*(tr: Il2CppPtr): RefResult =
  ## Transform::get_parent. A scene root legitimately has NO parent -> that is
  ## INCONCLUSIVE ("no parent"), not FAIL.
  if not isAlive(tr): return refInc("receiver is not a live Transform")
  let fn = cSceneFn(ScGetParent)
  if fn == nil: return refInc("get_parent RVA did not verify on this build")
  let p = cMi2CallPP(fn, tr)
  if p == nil: return refInc("transform has no parent (scene root)")
  if not isAlive(p): return refFail("get_parent returned a dead wrapper")
  refPass(p)

proc childCount*(tr: Il2CppPtr): IntResult =
  ## Transform::get_childCount, sanity-bounded.
  if not isAlive(tr): return intInc("receiver is not a live Transform")
  let fn = cSceneFn(ScGetChildCount)
  if fn == nil: return intInc("get_childCount RVA did not verify on this build")
  let c = cMi2CallIP(fn, tr)
  if c < 0 or c >= 100000: return intFail("get_childCount returned an absurd count")
  intPass(int64(c))

proc childAt*(tr: Il2CppPtr; index: int32): RefResult =
  ## Transform::GetChild(index), bounds-checked against get_childCount first.
  if not isAlive(tr): return refInc("receiver is not a live Transform")
  let cc = childCount(tr)
  if not isPass(cc): return refInc("child count unavailable: " & cc.why)
  if index < 0 or int64(index) >= cc.value:
    return refFail("child index " & $index & " out of range 0.." & $(cc.value - 1))
  let fn = cSceneFn(ScGetChild)
  if fn == nil: return refInc("GetChild RVA did not verify on this build")
  let ch = cSceneCallPPI(fn, tr, index)
  if ch == nil or not isAlive(ch): return refFail("GetChild returned a dead/nil child")
  refPass(ch)

proc findChild*(tr: Il2CppPtr; path: string): RefResult =
  ## Transform::Find(path) -- Unity's own hierarchy-path lookup, e.g.
  ## "Panel/Row/Label". Returns INCONCLUSIVE when not found (a missing name is
  ## not a failure of the API); FAIL only on a dead result.
  if not isAlive(tr): return refInc("receiver is not a live Transform")
  let fn = cSceneFn(ScFind)
  if fn == nil: return refInc("Transform::Find RVA did not verify on this build")
  var pathCopy = path
  let s = cMi2StringNew(toCString(pathCopy))
  if s == nil: return refInc("could not allocate the path String")
  let found = cMi2CallPPP(fn, tr, s)
  if found == nil: return refInc("no descendant at path '" & path & "'")
  if not isAlive(found): return refFail("Transform::Find returned a dead wrapper")
  refPass(found)

# ---------------------------------------------------------------------------
# Components -- Component::GetComponent(string). (fact #68 trap handled)
# ---------------------------------------------------------------------------
proc getComponent*(comp: Il2CppPtr; typeName: string): RefResult =
  ## Ask a live COMPONENT (a Transform will do) for another component by type
  ## name. THE TRAP: GetComponent is declared on Component; handing it a
  ## GameObject faults inside Unity. Pass a Transform, not a GameObject -- use
  ## `transformOf` first if you only have the GameObject. A type the object does
  ## not have is INCONCLUSIVE (absent), not FAIL.
  if not isAlive(comp): return refInc("receiver is not a live Component (did you pass a GameObject?)")
  let fn = cSceneFn(ScGetComponent)
  if fn == nil: return refInc("GetComponent RVA did not verify on this build")
  var typeNameCopy = typeName
  let s = cMi2StringNew(toCString(typeNameCopy))
  if s == nil: return refInc("could not allocate the type-name String")
  let got = cMi2CallPPP(fn, comp, s)
  if got == nil: return refInc("no component of type '" & typeName & "' on this object")
  if not isAlive(got): return refFail("GetComponent returned a dead wrapper")
  refPass(got)

proc hasComponent*(comp: Il2CppPtr; typeName: string): bool =
  ## True only if GetComponent returned a live component. An INCONCLUSIVE
  ## (unverified RVA / dead receiver) is reported as false -- callers wanting to
  ## distinguish "absent" from "could not look" must use `getComponent`.
  isPass(getComponent(comp, typeName))

# ---------------------------------------------------------------------------
# Typed field access -- guarded, offset-based, three-outcome.
#
# Offsets come from the resolver (tools/fldoff.py `field <Type> <name>`), NEVER
# guessed. These procs take the resolved offset; a name->offset convenience
# belongs in a per-type wrapper on top, not here, so this layer never has to
# ship a metadata table.
# ---------------------------------------------------------------------------
proc readI32*(obj: Il2CppPtr; off: int32): IntResult =
  if obj == nil: return intInc("nil object")
  var ok: int32 = 0
  let bits = cSceneReadBits(obj, off, 4, ok)
  if ok == 0: return intInc("field @ +" & $off & " not readable")
  intPass(int64(int32(bits and 0xffffffff'u64)))

proc readU32*(obj: Il2CppPtr; off: int32): IntResult =
  if obj == nil: return intInc("nil object")
  var ok: int32 = 0
  let bits = cSceneReadBits(obj, off, 4, ok)
  if ok == 0: return intInc("field @ +" & $off & " not readable")
  intPass(int64(bits and 0xffffffff'u64))

proc readI64*(obj: Il2CppPtr; off: int32): IntResult =
  if obj == nil: return intInc("nil object")
  var ok: int32 = 0
  let bits = cSceneReadBits(obj, off, 8, ok)
  if ok == 0: return intInc("field @ +" & $off & " not readable")
  intPass(int64(bits))

proc readU8*(obj: Il2CppPtr; off: int32): IntResult =
  if obj == nil: return intInc("nil object")
  var ok: int32 = 0
  let bits = cSceneReadBits(obj, off, 1, ok)
  if ok == 0: return intInc("field @ +" & $off & " not readable")
  intPass(int64(bits and 0xff'u64))

proc readBool*(obj: Il2CppPtr; off: int32): IntResult =
  ## A managed bool is one byte; nonzero -> 1.
  let r = readU8(obj, off)
  if not isPass(r): return r
  intPass(if r.value != 0: 1'i64 else: 0'i64)

proc readF32*(obj: Il2CppPtr; off: int32): FloatResult =
  if obj == nil: return floatInc("nil object")
  var ok: int32 = 0
  let bits = cSceneReadBits(obj, off, 4, ok)
  if ok == 0: return floatInc("field @ +" & $off & " not readable")
  floatPass(float64(cSceneBitsF32(uint32(bits and 0xffffffff'u64))))

proc readF64*(obj: Il2CppPtr; off: int32): FloatResult =
  if obj == nil: return floatInc("nil object")
  var ok: int32 = 0
  let bits = cSceneReadBits(obj, off, 8, ok)
  if ok == 0: return floatInc("field @ +" & $off & " not readable")
  floatPass(cSceneBitsF64(bits))

proc readPtr*(obj: Il2CppPtr; off: int32): RefResult =
  ## Read a reference field. The returned pointer is NOT dereferenced or
  ## liveness-checked here (it may legitimately be nil); the consumer must
  ## `isAlive` it before use.
  if obj == nil: return refInc("nil object")
  var ok: int32 = 0
  let bits = cSceneReadBits(obj, off, 8, ok)
  if ok == 0: return refInc("field @ +" & $off & " not readable")
  refPass(cast[Il2CppPtr](bits))

proc writeI32*(obj: Il2CppPtr; off: int32; val: int32): bool =
  ## Read-validate-write: refused (false) if the page is not writable. Never a
  ## blind write.
  if obj == nil: return false
  cSceneWriteBits(obj, off, 4, uint64(uint32(val))) != 0

proc writeF32*(obj: Il2CppPtr; off: int32; val: float32): bool =
  if obj == nil: return false
  cSceneWriteBits(obj, off, 4, uint64(cSceneF32Bits(val))) != 0

proc writeU8*(obj: Il2CppPtr; off: int32; val: uint8): bool =
  if obj == nil: return false
  cSceneWriteBits(obj, off, 1, uint64(val)) != 0

proc writeBool*(obj: Il2CppPtr; off: int32; val: bool): bool =
  writeU8(obj, off, if val: 1'u8 else: 0'u8)

# ---------------------------------------------------------------------------
# Struct-return decode -- a Vector2 getter returns 8 bytes packed in RAX.
# ---------------------------------------------------------------------------
proc decodeVec2*(packed: uint64): Vec2 =
  ## Unpack a Vector2 returned in RAX (x = low 32 bits, y = high 32 bits).
  ## Given the uint64 from a 0-arg Vector2 getter called through the int-class
  ## thunk. Wider structs (Vector3/Rect) use the sret route in aowlspt_debugui.h.
  Vec2(x: cSceneVec2X(packed), y: cSceneVec2Y(packed))

# ---------------------------------------------------------------------------
# Sharedness gate -- for anyone deciding whether an RVA is DETOUR-safe. (fact #57)
# ---------------------------------------------------------------------------
type ShareVerdict* = enum
  svDetourOk = 0   ## owners == 1: unique, safe to detour
  svCallOnly = 1   ## owners  > 1: shared, calling is fine, DO NOT detour
  svRefuse   = 2   ## owners <= 0: unknown, refuse to detour

proc shareVerdict*(owners: int32): ShareVerdict =
  ## CALLING a shared address is correct code; DETOURING one has unbounded blast
  ## radius. UNKNOWN is treated as refuse, never as safe. This API only ever
  ## CALLS, so it never needs a unique owner -- this is here for callers that
  ## want to detour something they resolved.
  case cSceneShareVerdict(owners)
  of 0: svDetourOk
  of 1: svCallOnly
  else: svRefuse

# ---------------------------------------------------------------------------
# Verification / diagnostics
# ---------------------------------------------------------------------------
proc sceneTargetsVerified*(): int32 = cSceneOkCount()
proc sceneTargetsRejected*(): int32 = cSceneBadCount()

# ---------------------------------------------------------------------------
# The in-client SELF-PROOF.
#
# Runs the read-only core against a live Component `self` under ONE guard, then
# formats a PASS/FAIL/INCONCLUSIVE report the coordinator logs. INCONCLUSIVE
# until deployed and run: it settles the live behaviour of every getter above.
# ---------------------------------------------------------------------------
proc outcomeName(code: int32): string =
  case code
  of 1: "PASS"
  of 2: "FAIL"
  of 3: "INCONCLUSIVE"
  else: "not-run"

proc sceneProofRun*(self: Il2CppPtr) =
  ## Establishes the ONE guard (in C, `aowl_scene_proof_guarded`) and runs the
  ## proof body. Call this from a Unity-thread detour, passing the detour's
  ## `this` (a live Component). Read the outcome with `sceneProofReport`. Do NOT
  ## call from inside another `aowl_p_p_seh` -- the guard is not re-entrant.
  discard cSceneProofGuarded(self)

proc sceneProofReport*(): string =
  ## Human-readable per-step verdict. The exact host-log line that settles each
  ## live getter. Call after `sceneProofRun`.
  if cSceneProofRan() == 0:
    return "scene PROOF: not run (call sceneProofRun with a live Component first)"
  const names = [
    "get_gameObject", "get_transform", "get_name", "GetInstanceID",
    "isAlive", "get_parent", "get_childCount", "GetChild(0)", "field read(+0x10)"]
  var s = "scene PROOF:"
  var i = 0'i32
  while i < 9'i32:
    s = s & "\n  " & names[i] & " = " & outcomeName(cSceneProofStep(i))
    inc i
  s = s & "\n  instanceId=" & $cSceneProofInstanceId() &
        " childCount=" & $cSceneProofChildCount()
  s
