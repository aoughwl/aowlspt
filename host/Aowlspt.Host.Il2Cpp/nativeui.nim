# nativeui.nim -- the NATIVE UNITY UI CONSTRUCTION LAYER, Nim surface.
#
# `include`d into `aowlhost.nim` (NOT a separate module) so it shares that
# file's guarded raw primitives (`cIsReadable`, `cReadPtrAt`), its logging
# (`okLog`/`warn`/`info`), `hexOf`, the VEH/SEH guard -- and, because it is
# included AFTER `settingsui.nim` and `invoke2.nim`, that file's
# `suiReadString` plus invoke2's `mi2FindTmp` anchor walk.
#
# WHAT THIS IS FOR
# ----------------
# `abi/aowlspt_nativeui.h` holds the byte-verified targets, the call thunks,
# the component-slot registry and the pure arithmetic. This file is the API
# mods call, and the part that enforces the discipline the C side cannot:
#
#   * ONE `aowl_p_p_seh` around a WHOLE operation, never nested. The guard is
#     not re-entrant -- an inner guard DISARMS the outer one -- so every public
#     entry point here is either already inside a guard or wraps itself once,
#     and this is stated per proc.
#   * every returned pointer re-validated by the code that consumes it, because
#     a step that faulted returns nil and the next step must NOTICE rather than
#     dereference it.
#   * read-back verification of the FINISHED STATE, never of our own write.
#
# THE BUG THIS LAYER EXISTS TO FIX
# --------------------------------
# The invoke2 ladder created a real GameObject, named it, round-tripped
# `get_name`, attached a RectTransform, cloned a live label, parented it into
# the settings canvas and activated it. Eight steps, each verified. Nothing
# appeared on screen, and `findtext` over 60k+ nodes found no trace.
#
# The missing piece was never creation. It was LAYOUT. A `RectTransform` fresh
# out of `AddComponent` has `sizeDelta == (0,0)`, and a zero-area rect renders
# nothing while every call on the way there reports success.
#
# `nuProofRun` does not assert that. It MEASURES it: it reads the rect back
# BEFORE laying out and AFTER, in that order, on the same element, and logs
# both. If the "before" is zero-area and the "after" is not, layout was the
# cause and the log says so with numbers. If the "before" already has area,
# the diagnosis was WRONG and the log says that instead. See `nuProofRun`.

# ---------------------------------------------------------------------------
# The C surface (abi/aowlspt_nativeui.h)
# ---------------------------------------------------------------------------
proc cNuFn(i: int32): Il2CppPtr {.importc: "aowl_nu_fn", nodecl.}
proc cNuName(i: int32): Il2CppPtr {.importc: "aowl_nu_name", nodecl.}
proc cNuRva(i: int32): uint32 {.importc: "aowl_nu_rva", nodecl.}
proc cNuTargetCount(): int32 {.importc: "aowl_nu_target_count", nodecl.}
proc cNuOkCount(): int32 {.importc: "aowl_nu_ok_count", nodecl.}
proc cNuBadCount(): int32 {.importc: "aowl_nu_bad_count", nodecl.}
proc cNuNoteFault() {.importc: "aowl_nu_note_fault", nodecl.}
proc cNuFaultCount(): int32 {.importc: "aowl_nu_fault_count", nodecl.}
proc cNuDisabled(): int32 {.importc: "aowl_nu_disabled", nodecl.}

proc cNuCallVPP(fn, self, a0: Il2CppPtr) {.importc: "aowl_nu_call_v_pp", nodecl.}
proc cNuCallVPB(fn, self: Il2CppPtr; a0: int32) {.
  importc: "aowl_nu_call_v_pb", nodecl.}
proc cNuCallVPI(fn, self: Il2CppPtr; a0: int32) {.
  importc: "aowl_nu_call_v_pi", nodecl.}
proc cNuCallVPF(fn, self: Il2CppPtr; a0: float32) {.
  importc: "aowl_nu_call_v_pf", nodecl.}
proc cNuCallVPPB(fn, self, a0: Il2CppPtr; a1: int32) {.
  importc: "aowl_nu_call_v_ppb", nodecl.}
proc cNuCallPP(fn, self: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_call_p_p", nodecl.}
proc cNuCallPPP(fn, self, a0: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_call_p_pp", nodecl.}
proc cNuCallPS1(fn, a0: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_call_p_s1", nodecl.}
proc cNuCallVS1(fn, a0: Il2CppPtr) {.importc: "aowl_nu_call_v_s1", nodecl.}
proc cNuCallVS2(fn, a0, a1: Il2CppPtr) {.importc: "aowl_nu_call_v_s2", nodecl.}
proc cNuCallBP(fn, self: Il2CppPtr): int32 {.importc: "aowl_nu_call_b_p", nodecl.}
proc cNuCallBS1(fn, a0: Il2CppPtr): int32 {.
  importc: "aowl_nu_call_b_s1", nodecl.}
proc cNuCallGeneric0(fn, self, mi: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_call_generic0", nodecl.}

proc cNuV2InSet(x, y: float32) {.importc: "aowl_nu_v2in_set", nodecl.}
proc cNuV2InPtr(): Il2CppPtr {.importc: "aowl_nu_v2in_ptr", nodecl.}
proc cNuV2OutPtr(): Il2CppPtr {.importc: "aowl_nu_v2out_ptr", nodecl.}
proc cNuV2OutX(): float32 {.importc: "aowl_nu_v2out_x", nodecl.}
proc cNuV2OutY(): float32 {.importc: "aowl_nu_v2out_y", nodecl.}
proc cNuRectPtr(): Il2CppPtr {.importc: "aowl_nu_rect_ptr", nodecl.}
proc cNuRectX(): float32 {.importc: "aowl_nu_rect_x", nodecl.}
proc cNuRectY(): float32 {.importc: "aowl_nu_rect_y", nodecl.}
proc cNuRectW(): float32 {.importc: "aowl_nu_rect_w", nodecl.}
proc cNuRectH(): float32 {.importc: "aowl_nu_rect_h", nodecl.}
proc cNuRectContains(rx, ry, rw, rh, px, py: float32): int32 {.
  importc: "aowl_nu_rect_contains", nodecl.}
proc cNuRectRenderable(w, h: float32): int32 {.
  importc: "aowl_nu_rect_renderable", nodecl.}

proc cNuKindName(k: int32): Il2CppPtr {.importc: "aowl_nu_kind_name", nodecl.}
proc cNuKindEvidence(k: int32): Il2CppPtr {.
  importc: "aowl_nu_kind_evidence", nodecl.}
proc cNuKindSlotRva(k: int32): uint32 {.
  importc: "aowl_nu_kind_slot_rva", nodecl.}
proc cNuKindCount(): int32 {.importc: "aowl_nu_kind_count", nodecl.}
proc cNuKindMi(k: int32): Il2CppPtr {.importc: "aowl_nu_kind_mi", nodecl.}
proc cNuSlotState(k: int32): int32 {.importc: "aowl_nu_slot_state", nodecl.}
proc cNuSlotJudge(k: int32; got: Il2CppPtr): int32 {.
  importc: "aowl_nu_slot_judge", nodecl.}
proc cNuRefSet(k: int32; live: Il2CppPtr): int32 {.
  importc: "aowl_nu_ref_set", nodecl.}
proc cNuRefKlass(k: int32): Il2CppPtr {.importc: "aowl_nu_ref_klass", nodecl.}
proc cNuGotKlass(k: int32): Il2CppPtr {.importc: "aowl_nu_got_klass", nodecl.}
proc cNuKlassOf(o: Il2CppPtr): Il2CppPtr {.importc: "aowl_nu_klass_of", nodecl.}

proc cNuIntern(s: cstring): Il2CppPtr {.importc: "aowl_nu_intern", nodecl.}
proc cNuInternCount(): int32 {.importc: "aowl_nu_intern_count", nodecl.}
proc cNuInternOverflowed(): int32 {.
  importc: "aowl_nu_intern_overflowed", nodecl.}

proc cNuOwn(go: Il2CppPtr): int32 {.importc: "aowl_nu_own", nodecl.}
proc cNuDisown(go: Il2CppPtr) {.importc: "aowl_nu_disown", nodecl.}
proc cNuOwnedCount(): int32 {.importc: "aowl_nu_owned_count", nodecl.}
proc cNuOwnedAt(i: int32): Il2CppPtr {.importc: "aowl_nu_owned_at", nodecl.}
proc cNuOwnedClear() {.importc: "aowl_nu_owned_clear", nodecl.}
proc cNuObjectNew(klass: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_object_new", nodecl.}

# ---- target indices, mirroring the AOWL_NU_* defines --------------------
#
# Each carries the EXACT row name from `aowl_nu_targets`, checked by
# `tools/idxbind.py`. That check is not ceremony here: this table is twenty-five
# rows of near-identical `_Injected` setters and getters, so a row inserted
# above `set_sizeDelta` would silently point it at `set_pivot`, every call would
# still succeed, and the element would simply be laid out wrongly -- exactly the
# invisible-but-successful failure this whole layer exists to end.
const
  NuTGoCtorString    =  0'i32  ## UnityEngine.GameObject::.ctor(String)
  NuTGoSetActive     =  1'i32  ## UnityEngine.GameObject::SetActive
  NuTGoGetTransform  =  2'i32  ## UnityEngine.GameObject::get_transform
  NuTGoActiveInHier  =  3'i32  ## UnityEngine.GameObject::get_activeInHierarchy
  NuTGoSetLayer      =  4'i32  ## UnityEngine.GameObject::set_layer
  NuTAddComponentGen =  5'i32  ## UnityEngine.GameObject::AddComponent<T>
  NuTObjGetName      =  6'i32  ## UnityEngine.Object::get_name
  NuTObjDestroy      =  7'i32  ## UnityEngine.Object::Destroy(Object)
  NuTObjInstantiate  =  8'i32  ## UnityEngine.Object::Instantiate(Object)
  NuTObjAlive        =  9'i32  ## UnityEngine.Object::op_Implicit(Object)
  NuTTrSetParent2    = 10'i32  ## UnityEngine.Transform::SetParent(Transform,bool)
  NuTTrSetAsFirstSib = 11'i32  ## UnityEngine.Transform::SetAsFirstSibling
  NuTRtSetAnchorMin  = 12'i32  ## UnityEngine.RectTransform::set_anchorMin_Injected
  NuTRtSetAnchorMax  = 13'i32  ## UnityEngine.RectTransform::set_anchorMax_Injected
  NuTRtSetAnchoredPos= 14'i32  ## UnityEngine.RectTransform::set_anchoredPosition_Injected
  NuTRtSetSizeDelta  = 15'i32  ## UnityEngine.RectTransform::set_sizeDelta_Injected
  NuTRtSetPivot      = 16'i32  ## UnityEngine.RectTransform::set_pivot_Injected
  NuTRtGetAnchoredPos= 17'i32  ## UnityEngine.RectTransform::get_anchoredPosition_Injected
  NuTRtGetSizeDelta  = 18'i32  ## UnityEngine.RectTransform::get_sizeDelta_Injected
  NuTRtGetRect       = 19'i32  ## UnityEngine.RectTransform::get_rect_Injected
  NuTTmpSetText      = 20'i32  ## TMPro.TMP_Text::set_text
  NuTTmpGetText      = 21'i32  ## TMPro.TMP_Text::get_text
  NuTTmpSetFontSize  = 22'i32  ## TMPro.TMP_Text::set_fontSize
  NuTLocSetLabelText = 23'i32  ## LocalizedText::SetLabelText
  NuTSetParentAlign  = 24'i32  ## TMPro.TMP_DefaultControls::SetParentAndAlign

# ---- component kinds, mirroring the AOWL_NU_KIND_* defines --------------
const
  NuKindRectTransform = 0'i32
  NuKindTmpText       = 1'i32
  NuKindImage         = 2'i32
  NuKindButton        = 3'i32

# ---- slot verdicts, mirroring the AOWL_NU_SLOT_* defines ----------------
const
  NuSlotUnknown  = 0'i32
  NuSlotVerified = 1'i32
  NuSlotPoisoned = 2'i32
  NuSlotNoRef    = 3'i32

proc nuSlotStateName(s: int32): string =
  case int(s)
  of 0: "UNKNOWN (not exercised yet)"
  of 1: "VERIFIED (produced the reference class)"
  of 2: "POISONED (produced the WRONG class -- refused for the session)"
  of 3: "INCONCLUSIVE (no live reference instance to check against)"
  else: "?"

# ---------------------------------------------------------------------------
# Flags. Default OFF, both of them.
#   nativeUi       -- the layer answers at all
#   nativeUiProof  -- additionally run the one-shot visual self-proof
# ---------------------------------------------------------------------------
var gNuOn = false
var gNuProof = false
var gNuProofDone = false

proc nuProofWanted(): bool = gNuProof and not gNuProofDone

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------
proc nuFn(i: int32): Il2CppPtr =
  ## A verified code pointer, or nil. Refusal is LOGGED: a target that never
  ## bound must not be indistinguishable from a step that ran and did nothing.
  result = cNuFn(i)
  if result == nil:
    warn "nativeui: target " & readCString(cNuName(i)) & " @ 0x" &
         hexOf(uint64(cNuRva(i))) & " did not verify against the startup " &
         "prologue snapshot on this build; the operation needing it is refused"

proc nuOk(p: Il2CppPtr; n: int32): bool =
  ## Every hop, not just the first. `a->b->c` is three of these.
  p != nil and cIsReadable(p, n) != 0'i32

proc nuF(v: float32): string = formatFloat(float64(v), ffDecimal, 1)

proc nuStr(s: string): Il2CppPtr =
  ## An INTERNED managed string. Allocated at most once per distinct text for
  ## the life of the process -- rule 7, no per-frame managed allocation.
  ## `toCString`, not a `cstring` cast: nimony converts only a string LITERAL
  ## to a cstring, and every text this layer is asked for arrives as a runtime
  ## string. The C side copies the bytes into its own intern table before it
  ## allocates, so the borrowed buffer does not have to outlive the call.
  ## `toCString` takes its argument by `var`, hence the local copy.
  var tmp = s
  cNuIntern(toCString(tmp))

proc nuKlassOf(o: Il2CppPtr): Il2CppPtr = cNuKlassOf(o)

proc nuTransformOf(go: Il2CppPtr): Il2CppPtr =
  ## The GameObject's Transform (a RectTransform, for a UI object).
  let fn = nuFn(NuTGoGetTransform)
  if fn == nil or not nuOk(go, 0x10'i32): return nil
  result = cNuCallPP(fn, go)
  if not nuOk(result, 0x10'i32): result = nil

proc nuGameObjectOf(component: Il2CppPtr): Il2CppPtr =
  ## `Component::get_gameObject`. Reuses invoke2's byte-verified target rather
  ## than duplicating a 26th row for a function that is already proven live.
  let fn = mi2Fn(Mi2GetGameObject)
  if fn == nil or not nuOk(component, 0x10'i32): return nil
  result = cMi2CallPP(fn, component)
  if not nuOk(result, 0x10'i32): result = nil

proc nuAlive(obj: Il2CppPtr): bool =
  ## `Object::op_Implicit` -- Unity's OWN liveness test. NOT the same question
  ## as "is the pointer non-null": a destroyed Unity object keeps a live
  ## managed shell that reads back perfectly and answers false here.
  let fn = nuFn(NuTObjAlive)
  if fn == nil or not nuOk(obj, 0x10'i32): return false
  cNuCallBS1(fn, obj) != 0'i32

proc nuActiveInHierarchy(go: Il2CppPtr): bool =
  ## One third of the visual proof. `activeSelf` is NOT this question: a node
  ## can be active while an ancestor is not, and then it renders nothing.
  let fn = nuFn(NuTGoActiveInHier)
  if fn == nil or not nuOk(go, 0x10'i32): return false
  cNuCallBP(fn, go) != 0'i32

proc nuSetActive(go: Il2CppPtr; on: bool): bool =
  let fn = nuFn(NuTGoSetActive)
  if fn == nil or not nuOk(go, 0x10'i32): return false
  cNuCallVPB(fn, go, (if on: 1'i32 else: 0'i32))
  true

proc nuSetLayer(go: Il2CppPtr; layer: int32): bool =
  ## Layer 5 is Unity's `UI` layer. A UI element on the wrong layer can be
  ## culled by the canvas camera and render nothing -- a second, independent
  ## way to be invisible while every call succeeds.
  let fn = nuFn(NuTGoSetLayer)
  if fn == nil or not nuOk(go, 0x10'i32): return false
  cNuCallVPI(fn, go, layer)
  true

# ---------------------------------------------------------------------------
# CREATE
# ---------------------------------------------------------------------------
proc nuCreate(name: string; klassDonor: Il2CppPtr): Il2CppPtr =
  ## A new, empty GameObject called `name`.
  ##
  ## `klassDonor` is a LIVE GameObject whose object header supplies the
  ## `Il2CppClass*`. That is the whole trick and it is why no metadata lookup
  ## and no token-gated export is involved: holding one instance of a type
  ## makes its class pointer free. Passing a donor that is not a GameObject
  ## allocates the wrong class -- so the ctor round-trip below is the check,
  ## not a formality.
  ##
  ## The caller must already be inside a guard. Returns nil on any refusal.
  if not gNuOn or cNuDisabled() != 0'i32: return nil
  if not nuOk(klassDonor, 0x10'i32):
    warn "nativeui: create(\"" & name & "\"): the class donor is null or " &
         "unreadable; refusing (an offset that can read null is not a path)"
    return nil
  let klass = nuKlassOf(klassDonor)
  if klass == nil: return nil
  let obj = cNuObjectNew(klass)
  if not nuOk(obj, 0x10'i32):
    warn "nativeui: create(\"" & name & "\"): il2cpp_object_new returned " &
         "null or unreadable"
    return nil
  if nuKlassOf(obj) != klass:
    warn "nativeui: create(\"" & name & "\"): the allocation's header klass " &
         "0x" & hexOf(cast[uint64](nuKlassOf(obj))) & " is not the class " &
         "requested 0x" & hexOf(cast[uint64](klass)) & "; refusing to construct it"
    return nil
  let fnCtor = nuFn(NuTGoCtorString)
  let nameStr = nuStr(name)
  if fnCtor == nil or nameStr == nil:
    if nameStr == nil:
      warn "nativeui: create(\"" & name & "\"): no managed string (intern " &
           "table full=" & $int(cNuInternOverflowed()) & ", used " &
           $int(cNuInternCount()) & ")"
    return nil
  cNuCallVPP(fnCtor, obj, nameStr)
  # THE CHECK. A raw allocation that was never constructed has no native Unity
  # object behind it and cannot answer get_name. Comparing against the string
  # we passed is a round-trip through the game, not a self-comparison.
  let fnName = nuFn(NuTObjGetName)
  if fnName != nil:
    let back = suiReadString(cNuCallPP(fnName, obj))
    if back != name:
      warn "nativeui: create(\"" & name & "\"): get_name round-trip read \"" &
           back & "\" -- the object was allocated but not constructed; refusing"
      return nil
  discard cNuOwn(obj)
  result = obj

proc nuClone(original: Il2CppPtr): Il2CppPtr =
  ## `Object::Instantiate(Object)` -- STATIC, RCX=original, RDX=MethodInfo*=0.
  ## Proven live by the invoke2 ladder. Still the cheapest way to get a UI
  ## element that already has every styling component the game configured.
  ## The clone's klass must match the original's, or it is not a clone.
  if not gNuOn or cNuDisabled() != 0'i32: return nil
  let fn = nuFn(NuTObjInstantiate)
  if fn == nil or not nuOk(original, 0x10'i32): return nil
  let c = cNuCallPS1(fn, original)
  if not nuOk(c, 0x10'i32): return nil
  if nuKlassOf(c) != nuKlassOf(original):
    warn "nativeui: clone: the clone's klass 0x" &
         hexOf(cast[uint64](nuKlassOf(c))) & " differs from the original's 0x" &
         hexOf(cast[uint64](nuKlassOf(original))) & "; refusing it"
    return nil
  result = c

# ---------------------------------------------------------------------------
# ADD COMPONENT -- the generalised slot route
# ---------------------------------------------------------------------------
proc nuRegisterReference(kind: int32; liveInstance: Il2CppPtr): bool =
  ## Record the reference class for `kind` from a LIVE instance reached by
  ## walking from something already validated. Without this, `nuAdd` for that
  ## kind can only ever return INCONCLUSIVE.
  if not nuOk(liveInstance, 0x10'i32): return false
  result = cNuRefSet(kind, liveInstance) != 0'i32
  if result:
    okLog "nativeui: reference instance for " & readCString(cNuKindName(kind)) &
          " registered from a live object 0x" &
          hexOf(cast[uint64](liveInstance)) & "; its klass = 0x" &
          hexOf(cast[uint64](cNuRefKlass(kind)))
  else:
    warn "nativeui: refusing the reference instance for " &
         readCString(cNuKindName(kind)) & ": either its class pointer is " &
         "unreadable, or a DIFFERENT reference was already recorded for this " &
         "kind -- which means one of the two walks is wrong"

proc nuAdd(go: Il2CppPtr; kind: int32): Il2CppPtr =
  ## Attach a component of `kind` and return it, or nil.
  ##
  ## The route is `AddComponent<T>()` at the shared generic body, with the
  ## `MethodInfo*` READ FROM THE GAME'S OWN `.data` cache slot -- the pointer
  ## the game computed for itself. No `System.Type`, so none of the
  ## token-gated exports is touched. (`AddComponent(Type)` needs
  ## `il2cpp_class_get_type` + `il2cpp_type_get_object`; those are gated, and
  ## they are the only thing that has ever faulted on this path.)
  ##
  ## The result is JUDGED against the kind's reference class before it is
  ## handed back. A slot attributed to the wrong T returns a component of the
  ## wrong class, the kind is poisoned for the session, and this returns nil.
  ## A kind with no reference is INCONCLUSIVE and also returns nil -- "I could
  ## not look" is not a pass.
  if not gNuOn or cNuDisabled() != 0'i32: return nil
  if kind < 0'i32 or kind >= cNuKindCount(): return nil
  let kname = readCString(cNuKindName(kind))
  if cNuSlotState(kind) == NuSlotPoisoned:
    warn "nativeui: add(" & kname & "): this kind is POISONED (its slot 0x" &
         hexOf(uint64(cNuKindSlotRva(kind))) & " produced klass 0x" &
         hexOf(cast[uint64](cNuGotKlass(kind))) & " where the live reference " &
         "is 0x" & hexOf(cast[uint64](cNuRefKlass(kind))) &
         "); refusing for the rest of the session"
    return nil
  let fn = nuFn(NuTAddComponentGen)
  if fn == nil or not nuOk(go, 0x10'i32): return nil
  let mi = cNuKindMi(kind)
  if mi == nil:
    warn "nativeui: add(" & kname & "): the game's MethodInfo* cache slot at " &
         ".data 0x" & hexOf(uint64(cNuKindSlotRva(kind))) & " is still NULL. " &
         "That is LAZY-NOT-YET, not an error -- IL2CPP fills it the first " &
         "time the owning method runs. Refusing rather than passing a NULL " &
         "MethodInfo, which the shared generic body dereferences at +0x38."
    return nil
  let comp = cNuCallGeneric0(fn, go, mi)
  if not nuOk(comp, 0x10'i32):
    warn "nativeui: add(" & kname & "): AddComponent<T> returned null or " &
         "unreadable"
    return nil
  let verdict = cNuSlotJudge(kind, comp)
  if verdict == NuSlotVerified:
    if cNuSlotState(kind) == NuSlotVerified:
      okLog "nativeui: add(" & kname & "): slot 0x" &
            hexOf(uint64(cNuKindSlotRva(kind))) &
            " VERIFIED -- the component's klass 0x" &
            hexOf(cast[uint64](cNuGotKlass(kind))) &
            " equals the live reference instance's"
    return comp
  if verdict == NuSlotNoRef:
    warn "nativeui: add(" & kname & "): INCONCLUSIVE. A component came back " &
         "with klass 0x" & hexOf(cast[uint64](cNuGotKlass(kind))) &
         ", but there is no live reference instance of " & kname &
         " to check it against, so we cannot say it is the right class. " &
         "Refusing to use it. Evidence for this slot: " &
         readCString(cNuKindEvidence(kind))
    return nil
  warn "nativeui: add(" & kname & "): FAILED. The slot produced klass 0x" &
       hexOf(cast[uint64](cNuGotKlass(kind))) & " but a live " & kname &
       " has klass 0x" & hexOf(cast[uint64](cNuRefKlass(kind))) &
       ". The slot attribution is WRONG -- this kind is now refused for the " &
       "session. Re-derive it with tools/addcompslots.py."
  result = nil

# ---------------------------------------------------------------------------
# HIERARCHY
# ---------------------------------------------------------------------------
proc nuParentAligned(childGo, parentGo: Il2CppPtr): bool =
  ## `TMP_DefaultControls::SetParentAndAlign(child, parent)` -- Unity's own UI
  ## parenting helper, compiled into this build. It does SetParent(false),
  ## resets the local transform and copies the LAYER, which is the third
  ## invisible-but-successful failure mode this avoids.
  if not gNuOn: return false
  let fn = nuFn(NuTSetParentAlign)
  if fn == nil or not nuOk(childGo, 0x10'i32) or not nuOk(parentGo, 0x10'i32):
    return false
  cNuCallVS2(fn, childGo, parentGo)
  true

proc nuParentTransform(childTr, parentTr: Il2CppPtr; worldPositionStays: bool): bool =
  ## `Transform::SetParent(Transform, bool)`. The lower-level route, for a
  ## caller that has transforms rather than GameObjects.
  if not gNuOn: return false
  let fn = nuFn(NuTTrSetParent2)
  if fn == nil or not nuOk(childTr, 0x10'i32) or not nuOk(parentTr, 0x10'i32):
    return false
  cNuCallVPPB(fn, childTr, parentTr, (if worldPositionStays: 1'i32 else: 0'i32))
  true

proc nuFirstSibling(tr: Il2CppPtr): bool =
  if not gNuOn: return false
  let fn = nuFn(NuTTrSetAsFirstSib)
  if fn == nil or not nuOk(tr, 0x10'i32): return false
  discard cNuCallPP(fn, tr)
  true

# ---------------------------------------------------------------------------
# LAYOUT -- through the `_Injected` setters ONLY
#
# `UnityEngine.RectTransform` declares exactly ONE il2cpp field
# (`reapplyDrivenProperties`, static). Every geometry property is native-side,
# so there is no offset to write and no blind write to make. The `_Injected`
# variants take `(this, Vector2* value, MethodInfo*)`, which removes the
# by-value struct ABI from the problem entirely -- in both directions.
# ---------------------------------------------------------------------------
proc nuSetV2(rt: Il2CppPtr; target: int32; x, y: float32): bool =
  let fn = nuFn(target)
  if fn == nil or not nuOk(rt, 0x10'i32): return false
  cNuV2InSet(x, y)
  cNuCallVPP(fn, rt, cNuV2InPtr())
  true

proc nuGetV2(rt: Il2CppPtr; target: int32): (bool, float32, float32) =
  let fn = nuFn(target)
  if fn == nil or not nuOk(rt, 0x10'i32): return (false, 0'f32, 0'f32)
  cNuCallVPP(fn, rt, cNuV2OutPtr())
  (true, cNuV2OutX(), cNuV2OutY())

proc nuGetRect(rt: Il2CppPtr): (bool, float32, float32, float32, float32) =
  ## `get_rect_Injected(this, Rect* ret, MethodInfo*)` -- x, y, width, height,
  ## written into a buffer we own. This is the read that decides whether an
  ## element renders, and it is why the proof can be conclusive from the log
  ## alone.
  let fn = nuFn(NuTRtGetRect)
  if fn == nil or not nuOk(rt, 0x10'i32):
    return (false, 0'f32, 0'f32, 0'f32, 0'f32)
  cNuCallVPP(fn, rt, cNuRectPtr())
  (true, cNuRectX(), cNuRectY(), cNuRectW(), cNuRectH())

proc nuGetSize(rt: Il2CppPtr): (bool, float32, float32) =
  nuGetV2(rt, NuTRtGetSizeDelta)
proc nuGetPos(rt: Il2CppPtr): (bool, float32, float32) =
  nuGetV2(rt, NuTRtGetAnchoredPos)

proc nuLayout(rt: Il2CppPtr;
              anchorMinX, anchorMinY, anchorMaxX, anchorMaxY: float32;
              pivotX, pivotY: float32;
              width, height: float32;
              posX, posY: float32): bool =
  ## The whole geometry of an element, in one call, in the order Unity itself
  ## uses: anchors, then pivot, then size, then position. Position is applied
  ## LAST because `anchoredPosition` is interpreted relative to the anchors and
  ## the pivot -- setting it first and then moving the anchors silently moves
  ## the element.
  ##
  ## This is not optional. An element created without it has
  ## `sizeDelta == (0,0)` and renders nothing while every call succeeds, which
  ## is exactly what the invoke2 ladder produced.
  if not gNuOn: return false
  if not nuOk(rt, 0x10'i32):
    warn "nativeui: layout: the RectTransform is null or unreadable; refusing"
    return false
  if cNuRectRenderable(width, height) == 0'i32:
    warn "nativeui: layout: refusing a size of " & nuF(width) & "x" &
         nuF(height) & " -- it is zero-area, non-finite or absurd, and would " &
         "render nothing while every call reported success"
    return false
  result = nuSetV2(rt, NuTRtSetAnchorMin, anchorMinX, anchorMinY) and
           nuSetV2(rt, NuTRtSetAnchorMax, anchorMaxX, anchorMaxY) and
           nuSetV2(rt, NuTRtSetPivot, pivotX, pivotY) and
           nuSetV2(rt, NuTRtSetSizeDelta, width, height) and
           nuSetV2(rt, NuTRtSetAnchoredPos, posX, posY)

# ---------------------------------------------------------------------------
# TEXT
# ---------------------------------------------------------------------------
proc nuGetText(tmp: Il2CppPtr): string =
  ## `TMP_Text::get_text`, decoded by the FIXED System.String layout the host
  ## already trusts. Reading the PROPERTY rather than the `m_text` field is
  ## deliberate: the field is what LocalizedText clobbers, so reading it back
  ## would be reading our own write.
  let fn = nuFn(NuTTmpGetText)
  if fn == nil or not nuOk(tmp, 0x10'i32): return ""
  suiReadString(cNuCallPP(fn, tmp))

proc nuSetText(tmp: Il2CppPtr; s: string; localized: Il2CppPtr = nil): bool =
  ## Set TMP text through the REAL setters and re-apply.
  ##
  ## Writing `m_text` raw does not stick: `LocalizedText` clobbers it. When a
  ## LocalizedText component is present it must be told too, and the TMP write
  ## is then RE-APPLIED, because the clobber can land after ours.
  ##
  ## `ForceMeshUpdate` is deliberately NOT called: it resolves to 0x628110,
  ## which is `C2 00 00` -- this build's universal empty-body stub shared by
  ## 6,438 methods, not that method's code. Calling it would look like a
  ## refresh and do nothing.
  if not gNuOn: return false
  let fnSet = nuFn(NuTTmpSetText)
  let str = nuStr(s)
  if fnSet == nil or str == nil or not nuOk(tmp, 0x10'i32): return false
  cNuCallVPP(fnSet, tmp, str)
  if localized != nil and nuOk(localized, 0x10'i32):
    let fnLoc = nuFn(NuTLocSetLabelText)
    if fnLoc != nil:
      cNuCallVPP(fnLoc, localized, str)
      cNuCallVPP(fnSet, tmp, str)          # re-apply after the clobber
  result = true

proc nuSetFontSize(tmp: Il2CppPtr; size: float32): bool =
  ## `TMP_Text::set_fontSize(float)` -- the float goes in XMM1, the hidden
  ## MethodInfo* in R8.
  if not gNuOn: return false
  let fn = nuFn(NuTTmpSetFontSize)
  if fn == nil or not nuOk(tmp, 0x10'i32): return false
  cNuCallVPF(fn, tmp, size)
  true

# ---------------------------------------------------------------------------
# INPUT -- POLLED, v1
#
# There is no delegate path here on purpose. A Button.onClick handler needs a
# managed `UnityAction`, and a hand-built delegate needs a valid `invoke_impl`
# AND a valid `MethodInfo*` for a method that exists in no assembly. Nothing
# about that is demonstrated on this build, and an unproven delegate handed to
# Unity's event system faults on a frame we do not control.
#
# The host already runs every frame on the Unity thread through the
# TarkovApplication::Update bridge, so interaction is a per-frame READ. This is
# the arithmetic half; the caller supplies the pointer position it already has.
# ---------------------------------------------------------------------------
proc nuHitTest(rt: Il2CppPtr; px, py: float32): bool =
  ## Is (px, py), in the element's own local rect space, inside it?
  ## A zero-area rect contains nothing -- so an element that failed layout
  ## cannot be "clicked" by accident either.
  let (ok, rx, ry, rw, rh) = nuGetRect(rt)
  if not ok: return false
  cNuRectContains(rx, ry, rw, rh, px, py) != 0'i32

# ---------------------------------------------------------------------------
# TEARDOWN -- creating UI that cannot be torn down is a leak
# ---------------------------------------------------------------------------
proc nuDestroy(go: Il2CppPtr): bool =
  ## `Object::Destroy(Object)`, once, only if Unity still considers it alive.
  if not gNuOn: return false
  let fn = nuFn(NuTObjDestroy)
  if fn == nil or not nuOk(go, 0x10'i32): return false
  if not nuAlive(go): return false
  cNuCallVS1(fn, go)
  cNuDisown(go)
  true

proc nuDestroyAll(): int =
  ## Tear down everything this layer created. Capped by construction (the
  ## owned table is a fixed 64 entries), and each entry is liveness-checked
  ## before it is destroyed, so a second call cannot double-destroy.
  result = 0
  if not gNuOn: return
  let fn = nuFn(NuTObjDestroy)
  if fn == nil: return
  let n = int(cNuOwnedCount())
  for i in 0 ..< n:                       # capped: n <= AOWL_NU_MAX_OWNED
    let go = cNuOwnedAt(int32(i))
    if go != nil and nuOk(go, 0x10'i32) and nuAlive(go):
      cNuCallVS1(fn, go)
      inc result
  cNuOwnedClear()
  okLog "nativeui: destroyAll destroyed " & $result & " of " & $n &
        " owned object(s); the rest were already gone"

# ---------------------------------------------------------------------------
# THE VISUAL SELF-PROOF
#
# CLAUDE.md 9b, applied literally. The invoke2 ladder logged eight successes
# and produced nothing on screen, because every one of its checks compared a
# call against itself. This asserts the FINISHED STATE instead, and states one
# of THREE verdicts.
#
# It also MEASURES the diagnosis rather than assuming it: the rect is read
# BEFORE layout and AFTER, on the same element. If the "before" is zero-area
# and the "after" is not, missing layout was the cause of the invisible label
# and the numbers say so. If the "before" already has area, the diagnosis was
# wrong, and the log says THAT.
#
# What the human should see in aowlspt-host.log, in order:
#
#   nativeui PROOF: ... rect BEFORE layout = (x,y,w,h) ...  w=0.0 h=0.0
#   nativeui PROOF: ... rect AFTER  layout = (x,y,w,h) ...  w=520.0 h=44.0
#   nativeui PROOF: get_text round-trip = "AOWLSPT NATIVE UI ..."
#   nativeui PROOF: activeInHierarchy = true
#   nativeui PROOF: VERDICT = PASS
#
# and, on screen, that text near the top-left of the settings panel. It is
# also findable with the inspector, by the text it DISPLAYS:
#   findtext AOWLSPT NATIVE UI
# ---------------------------------------------------------------------------

const NuProofText = "AOWLSPT NATIVE UI PROOF"
const NuProofName = "aowlspt-nativeui-proof"

var gNuProofVerdict = "not run"

proc nuProofBody(tabPtr: Il2CppPtr) =
  ## The whole proof. Called ONLY from inside `nuProofRun`'s single guard --
  ## it must not add one of its own, because `aowl_p_p_seh` is not re-entrant
  ## and a nested guard would DISARM the outer one.
  gNuProofVerdict = "INCONCLUSIVE"
  okLog "nativeui PROOF: BEGIN. " & $int(cNuOkCount()) & " of " &
        $int(cNuTargetCount()) & " targets verified against the startup " &
        "prologue snapshot (" & $int(cNuBadCount()) & " rejected)."

  # -- 1. a live anchor, reached by WALKING, never by an offset that can read
  #       null. `mi2FindTmp` walks the settings tab down to a TextMeshProUGUI
  #       whose m_text decodes to real text -- so the anchor is proven to BE a
  #       TMP before it is used as one.
  mi2FindTmp(tabPtr)
  if gMi2Tmp == nil or gMi2TmpOwner == nil:
    warn "nativeui PROOF: INCONCLUSIVE -- no readable TextMeshProUGUI on this " &
         "tab, so there is no validated live object to walk from. Nothing was " &
         "created. Open another settings tab to retry."
    return
  let anchorGo = nuGameObjectOf(gMi2Tmp)
  let parentGo = nuGameObjectOf(gMi2TmpOwner)
  if anchorGo == nil or parentGo == nil:
    warn "nativeui PROOF: INCONCLUSIVE -- the anchor TMP or its owner has no " &
         "readable GameObject; nothing was created"
    return
  okLog "nativeui PROOF: anchor TMP=0x" & hexOf(cast[uint64](gMi2Tmp)) &
        " anchorGO=0x" & hexOf(cast[uint64](anchorGo)) &
        " parentGO=0x" & hexOf(cast[uint64](parentGo))

  # -- 2. reference instances, so the slot check can be conclusive.
  #       TMP: the anchor itself, which we just proved reads real text.
  #       RectTransform: the anchor's own transform -- a TextMeshProUGUI is a
  #       Graphic, so its transform is necessarily a RectTransform. That is
  #       the independent source; it does not come from any .data slot.
  discard nuRegisterReference(NuKindTmpText, gMi2Tmp)
  let anchorRt = nuTransformOf(anchorGo)
  if anchorRt != nil:
    discard nuRegisterReference(NuKindRectTransform, anchorRt)
  else:
    warn "nativeui PROOF: the anchor's transform is unreadable, so the " &
         "RectTransform slot cannot be verified; it will report INCONCLUSIVE"

  # -- 3. create
  let go = nuCreate(NuProofName, parentGo)
  if go == nil:
    warn "nativeui PROOF: FAIL -- creation refused (see the reason above)"
    gNuProofVerdict = "FAIL"
    return

  # -- 4. RectTransform, through the generalised slot, klass-judged
  let rt = nuAdd(go, NuKindRectTransform)
  if rt == nil:
    warn "nativeui PROOF: " &
         (if cNuSlotState(NuKindRectTransform) == NuSlotPoisoned:
            "FAIL -- the RectTransform slot produced the wrong class"
          else: "INCONCLUSIVE -- the RectTransform slot could not be settled") &
         ". Tearing the object down rather than leaving a half-built node."
    gNuProofVerdict = (if cNuSlotState(NuKindRectTransform) == NuSlotPoisoned:
                         "FAIL" else: "INCONCLUSIVE")
    discard nuDestroy(go)
    return

  # -- 5. into the live hierarchy, on the UI layer
  if not nuParentAligned(go, parentGo):
    warn "nativeui PROOF: INCONCLUSIVE -- could not parent into the live " &
         "canvas; tearing down"
    discard nuDestroy(go)
    return
  discard nuSetLayer(go, 5'i32)          # Unity's built-in `UI` layer

  # -- 6. THE MEASUREMENT THAT SETTLES THE DIAGNOSIS.
  #       Read the rect BEFORE any layout. If missing layout is what made the
  #       invoke2 label invisible, this is zero-area.
  let (okB, bx, by, bw, bh) = nuGetRect(rt)
  if okB:
    okLog "nativeui PROOF: rect BEFORE layout = (" & nuF(bx) & ", " & nuF(by) &
          ", " & nuF(bw) & ", " & nuF(bh) & ")  renderable=" &
          $(cNuRectRenderable(bw, bh) != 0'i32) &
          "   <-- a zero-area rect here is the invoke2 ladder's invisible " &
          "label, measured"
  else:
    warn "nativeui PROOF: could not read the rect before layout; the " &
         "before/after comparison will be inconclusive"

  # -- 7. text, then layout
  let tmp = nuAdd(go, NuKindTmpText)
  if tmp == nil:
    warn "nativeui PROOF: " &
         (if cNuSlotState(NuKindTmpText) == NuSlotPoisoned:
            "FAIL -- the TextMeshProUGUI slot produced the wrong class"
          else: "INCONCLUSIVE -- the TextMeshProUGUI slot could not be settled") &
         "; tearing down"
    gNuProofVerdict = (if cNuSlotState(NuKindTmpText) == NuSlotPoisoned:
                         "FAIL" else: "INCONCLUSIVE")
    discard nuDestroy(go)
    return
  discard nuSetFontSize(tmp, 28.0'f32)
  discard nuSetText(tmp, NuProofText)

  # Top-left corner of the parent, 520x44, inset 24px. Anchored to the parent's
  # top-left so the position does not depend on the parent's size.
  if not nuLayout(rt,
                  0.0'f32, 1.0'f32,      # anchorMin  (left, top)
                  0.0'f32, 1.0'f32,      # anchorMax  (left, top)
                  0.0'f32, 1.0'f32,      # pivot      (left, top)
                  520.0'f32, 44.0'f32,   # size
                  24.0'f32, -24.0'f32):  # position
    warn "nativeui PROOF: FAIL -- layout refused; tearing down"
    gNuProofVerdict = "FAIL"
    discard nuDestroy(go)
    return

  discard nuSetActive(go, true)
  discard nuSetText(tmp, NuProofText)     # re-apply after activation

  # -- 8. THE FINISHED STATE. Three independent reads, none of them a
  #       comparison against our own write.
  let (okA, ax, ay, aw, ah) = nuGetRect(rt)
  let back = nuGetText(tmp)
  let active = nuActiveInHierarchy(go)
  let renderable = okA and cNuRectRenderable(aw, ah) != 0'i32

  if okA:
    okLog "nativeui PROOF: rect AFTER  layout = (" & nuF(ax) & ", " & nuF(ay) &
          ", " & nuF(aw) & ", " & nuF(ah) & ")  renderable=" & $renderable
  okLog "nativeui PROOF: get_text round-trip = \"" & back & "\"" &
        (if back == NuProofText: "  <-- EXACT MATCH"
         else: "  <-- does NOT match what was set")
  okLog "nativeui PROOF: activeInHierarchy = " & $active
  let (okP, px, py) = nuGetPos(rt)
  if okP:
    okLog "nativeui PROOF: anchoredPosition = (" & nuF(px) & ", " & nuF(py) & ")"

  # -- 9. the diagnosis, stated from the two measurements
  if okB and okA:
    if cNuRectRenderable(bw, bh) == 0'i32 and renderable:
      okLog "nativeui PROOF: DIAGNOSIS CONFIRMED -- the element was zero-area " &
            "(" & nuF(bw) & "x" & nuF(bh) & ") before layout and " &
            nuF(aw) & "x" & nuF(ah) & " after. Missing layout, not missing " &
            "creation, is what made the invoke2 label invisible."
    elif cNuRectRenderable(bw, bh) != 0'i32:
      warn "nativeui PROOF: DIAGNOSIS WRONG -- the element ALREADY had area (" &
           nuF(bw) & "x" & nuF(bh) & ") before any layout call, so a missing " &
           "size is NOT what made the invoke2 label invisible. Look elsewhere."
    else:
      warn "nativeui PROOF: DIAGNOSIS UNSETTLED -- the rect was zero-area " &
           "before layout AND after it (" & nuF(aw) & "x" & nuF(ah) & ")"

  # -- 10. ONE verdict, from the finished state only.
  if renderable and active and back == NuProofText:
    gNuProofVerdict = "PASS"
    okLog "nativeui PROOF: VERDICT = PASS. A GameObject built from scratch " &
          "inside a detour is parented into the live settings canvas, has a " &
          "non-zero rect, is active in the hierarchy, and reports the text it " &
          "was given. Confirm on screen, and with the inspector: " &
          "`findtext " & NuProofText & "`."
  elif not okA or not okB:
    gNuProofVerdict = "INCONCLUSIVE"
    warn "nativeui PROOF: VERDICT = INCONCLUSIVE -- the rect could not be " &
         "read back, so nothing is settled. This is NOT a pass."
  else:
    gNuProofVerdict = "FAIL"
    warn "nativeui PROOF: VERDICT = FAIL -- renderable=" & $renderable &
         " activeInHierarchy=" & $active & " textMatches=" &
         $(back == NuProofText) & ". The element exists and does not render. " &
         "Leaving it in place so the inspector can be pointed at it: " &
         "0x" & hexOf(cast[uint64](go))

  # -- 11. the slot census, so the log alone says which kinds are usable
  for k in 0 ..< int(cNuKindCount()):     # capped: AOWL_NU_MAX_KINDS
    okLog "nativeui PROOF: slot " & readCString(cNuKindName(int32(k))) &
          " @ .data 0x" & hexOf(uint64(cNuKindSlotRva(int32(k)))) & " -> " &
          nuSlotStateName(cNuSlotState(int32(k)))
  okLog "nativeui PROOF: END (verdict " & gNuProofVerdict & ")"

# ---- the single guard ------------------------------------------------------
# ONE `aowl_p_p_seh` around the WHOLE proof. Not one per step: the guard is not
# re-entrant, and a nested inner guard disarms the outer one. The cost of the
# coarser grain is that a fault names the proof rather than the step -- which
# is why every stage above logs its own line, so the last line without a
# successor names where it died.
{.emit: """
extern void* aowl_nu_proof_body(void* a);
static void* aowl_nu_proof_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_nu_proof_body, a);
}
""".}
proc cNuProofGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nu_proof_guarded", nodecl.}

proc nuProofBodyC(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_nu_proof_body", cdecl.} =
  nuProofBody(a)
  result = cast[Il2CppPtr](1)

proc nuProofRun(tab: Il2CppPtr) =
  ## Runs at most once per session, whatever the outcome -- a second run would
  ## build a second label and the screen would stop being evidence.
  if not gNuOn or not gNuProof or gNuProofDone: return
  if cNuDisabled() != 0'i32:
    warn "nativeui: the layer has self-disabled after " &
         $int(cNuFaultCount()) & " fault(s); the proof will not run"
    return
  gNuProofDone = true
  if cNuProofGuarded(tab) == nil:
    cNuNoteFault()
    warn "nativeui PROOF: FAULTED -- the VEH guard caught it and the game " &
         "survived. The last `nativeui PROOF:` line above names how far it " &
         "got. Fault count is now " & $int(cNuFaultCount()) & " of 6."

proc bindNativeUi(verbose: bool) =
  ## No detour of its own, by design. Two detours on one function have the
  ## second overwrite the first's trampoline and silently kill the first
  ## feature, and the only proven Unity-thread point where a live SettingsScreen
  ## AND built controls both exist is already taken by invoke2's POSTFIX hook on
  ## `SettingsScreen::EnsureTabInitialized`. So this RIDES that detour as a
  ## drain instead of binding a second one.
  ##
  ## All this does is report the target census, once, so an unverified build is
  ## obvious in the log before any operation is attempted rather than as
  ## twenty-five separate refusals.
  if not gNuOn: return
  var ok = 0
  var bad = 0
  for i in 0 ..< int(cNuTargetCount()):   # capped by the table size
    if cNuFn(int32(i)) != nil: inc ok else: inc bad
  okLog "nativeui: " & $ok & " of " & $int(cNuTargetCount()) &
        " managed targets verified by RVA + startup-snapshot prologue on this " &
        "build" & (if bad > 0: " (" & $bad & " REJECTED)" else: "")
  if bad > 0:
    warn "nativeui: " & $bad & " target(s) did not match. Every refusal is " &
         "logged individually above with its name and RVA. This layer refuses " &
         "the operations that need them rather than calling an address whose " &
         "bytes are not what this build's metadata says."
  for k in 0 ..< int(cNuKindCount()):
    if verbose:
      info "nativeui: component kind " & readCString(cNuKindName(int32(k))) &
           " -> AddComponent<T> MethodInfo* cache slot .data 0x" &
           hexOf(uint64(cNuKindSlotRva(int32(k)))) & "; evidence: " &
           readCString(cNuKindEvidence(int32(k)))
  if gNuProof:
    okLog "nativeui: the visual self-proof is ARMED. It rides invoke2's " &
          "POSTFIX detour on SettingsScreen::EnsureTabInitialized, so it needs " &
          "`managedInvokeProbe` on as well; open Settings and click a tab."
