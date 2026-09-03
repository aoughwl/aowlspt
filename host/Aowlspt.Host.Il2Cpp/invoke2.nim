# invoke2.nim -- the DIRECT-INVOCATION proof ladder.
#
# `include`d into `aowlhost.nim` (NOT a separate module) so it shares that file's
# guarded raw primitives (`cIsReadable`/`cReadPtrAt`/`cReadI32At`/`cUxWritePtr`),
# its logging (`okLog`/`warn`/`info`), `hexOf`, `cRegsInt`, `attachDrain`, the
# VEH/SEH guard, and -- because it is included AFTER `settingsui.nim` -- that
# file's `suiReadString` and settings-tree offsets.
#
# WHAT IT IS PROVING
# ------------------
# CORRECTION (measured 2026-08-26, docs/IL2CPP_EXPORTS.md): reflection is NOT
# dead on this build, it is TOKEN-GATED, and the older wording here was wrong
# about the mechanism. This is stock IL2CPP with a gated export ABI: 38 of the
# 241 `il2cpp_*` exports take an extra trailing argument we never passed -- a
# pointer to 32 bytes -- and memcmp it before doing any work. On mismatch they
# neither return NULL nor abort; they tail-call a trap that lazily seeds a
# per-thread MT19937-64 and returns a uniform random non-zero uint64. THAT is
# why a nil check passes and the first dereference kills the client. It was
# never poisoned metadata; it was a random number.
#
# The P2-P5 symptoms were real, so the CONCLUSION below stands unchanged -- but
# state the cause correctly: `il2cpp_object_get_class` does not fault at all
# (it is `mov rax,[rcx]; ret`, which is worse: a bad pointer yields a plausible
# number silently), and `il2cpp_value_box` is intact and ungated.
#
# Raw field reads and writes work, which is enough to CHANGE the UI and not
# enough to CREATE it.
#
# The way out is that IL2CPP compiles every managed method to an ordinary native
# function. So we call those functions DIRECTLY at their RVA, with IL2CPP's
# calling convention -- which `abi/aowlspt_invoke2.h` documents with disassembled
# evidence from the game's own call sites. No MethodInfo lookup, no metadata
# query, no reflection.
#
# HOW IT IS PROVED SAFELY
# -----------------------
# A graduated ladder, five steps, each one:
#   * logged BEFORE and AFTER, so a fault names the step it died in;
#   * run under its OWN `aowl_p_p_seh` VEH/setjmp guard, so a fault in step 3
#     neither crashes the game nor hides steps 4 and 5;
#   * gated behind `managedInvokeProbe` (default OFF) and run at most once.
#
# It runs from inside the PROVEN Unity-thread detour on
# `SettingsScreen::EnsureTabInitialized` (POSTFIX, kind=9) -- the same target the
# Phase-1.5 control probe uses, and for the same reason: it is the only proven
# point where a live SettingsScreen AND real, built UI controls both exist. The
# two are mutually exclusive by arming order (see `bindManagedInvoke`).

# ---- the target table and call thunks (abi/aowlspt_invoke2.h) ----
proc cMi2Fn(i: int32): Il2CppPtr {.importc: "aowl_mi2_fn", nodecl.}
proc cMi2Name(i: int32): Il2CppPtr {.importc: "aowl_mi2_name", nodecl.}
proc cMi2Rva(i: int32): uint32 {.importc: "aowl_mi2_rva", nodecl.}
proc cMi2TargetCount(): int32 {.importc: "aowl_mi2_target_count", nodecl.}
proc cMi2BaseOk(): int32 {.importc: "aowl_mi2_base_ok", nodecl.}
proc cMi2OkCount(): int32 {.importc: "aowl_mi2_ok_count", nodecl.}
proc cMi2BadCount(): int32 {.importc: "aowl_mi2_bad_count", nodecl.}

proc cMi2CallPP(fn, self: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mi2_call_p_p", nodecl.}
proc cMi2CallIP(fn, self: Il2CppPtr): int32 {.
  importc: "aowl_mi2_call_i_p", nodecl.}
proc cMi2CallIV(fn: Il2CppPtr): int32 {.importc: "aowl_mi2_call_i_v", nodecl.}
proc cMi2CallVPP(fn, self, a0: Il2CppPtr) {.
  importc: "aowl_mi2_call_v_pp", nodecl.}
proc cMi2CallVPB(fn, self: Il2CppPtr; a0: int32) {.
  importc: "aowl_mi2_call_v_pb", nodecl.}
proc cMi2CallPPP(fn, self, a0: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mi2_call_p_pp", nodecl.}
proc cMi2CallPS1(fn, a0: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mi2_call_p_s1", nodecl.}
proc cMi2CallVS2(fn, a0, a1: Il2CppPtr) {.
  importc: "aowl_mi2_call_v_s2", nodecl.}
proc cMi2CallGeneric0(fn, self, mi: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mi2_call_generic0", nodecl.}

proc cMi2HaveObjectNew(): int32 {.importc: "aowl_mi2_have_object_new", nodecl.}
proc cMi2HaveTypeRoute(): int32 {.importc: "aowl_mi2_have_type_route", nodecl.}
proc cMi2ObjectNew(klass: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mi2_object_new", nodecl.}
proc cMi2ProbeName(): Il2CppPtr {.importc: "aowl_mi2_probe_name", nodecl.}
proc cMi2ProbeText(): Il2CppPtr {.importc: "aowl_mi2_probe_text", nodecl.}
proc cMi2ProbeNameStr(): Il2CppPtr {.
  importc: "aowl_mi2_probe_name_str", nodecl.}
proc cMi2ProbeTextStr(): Il2CppPtr {.
  importc: "aowl_mi2_probe_text_str", nodecl.}
proc cMi2TypeObjectOf(klass: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mi2_type_object_of", nodecl.}
proc cMi2TypeRouteWhy(): cstring {.
  importc: "aowl_mi2_type_route_why", nodecl.}
proc cMi2GoClassSlot(): Il2CppPtr {.importc: "aowl_mi2_go_class_slot", nodecl.}
proc cMi2AddCompRectMi(): Il2CppPtr {.
  importc: "aowl_mi2_addcomp_rect_mi", nodecl.}

# ---- target indices, mirroring the AOWL_MI2_* defines ----
const
  Mi2GetGameObject   = 0'i32           ## UnityEngine.Component::get_gameObject
  Mi2GetInstanceId   = 1'i32           ## UnityEngine.Object::GetInstanceID
  Mi2GetName         = 2'i32           ## UnityEngine.Object::get_name
  Mi2SetName         = 3'i32           ## UnityEngine.Object::set_name
  Mi2FrameCount      = 4'i32           ## UnityEngine.Time::get_frameCount
  Mi2ScreenWidth     = 5'i32           ## UnityEngine.Screen::get_width
  Mi2ScreenHeight    = 6'i32           ## UnityEngine.Screen::get_height
  Mi2GoCtorString    = 7'i32           ## UnityEngine.GameObject::.ctor(String)
  Mi2GoSetActive     = 8'i32           ## UnityEngine.GameObject::SetActive
  Mi2GoGetTransform  = 9'i32           ## UnityEngine.GameObject::get_transform
  Mi2SetParentAlign  = 10'i32          ## TMPro.TMP_DefaultControls::SetParentAndAlign
  Mi2Instantiate     = 11'i32          ## UnityEngine.Object::Instantiate(Object)
  Mi2AddComponentTy  = 12'i32          ## UnityEngine.GameObject::AddComponent(Type)
  Mi2AddComponentGen = 13'i32          ## UnityEngine.GameObject::AddComponent<T>
  Mi2SetAsFirstSibling = 14'i32        ## UnityEngine.Transform::SetAsFirstSibling

# ---------------------------------------------------------------------------
# Ladder state
#
# Each step runs under its own guard, so the steps cannot pass values to one
# another on the stack -- they pass them here. Every one is re-validated by the
# step that reads it (nil check + `cIsReadable`), because a step that faulted
# leaves its output nil and the next step must notice rather than dereference it.
# ---------------------------------------------------------------------------
var gMi2Self: Il2CppPtr = nil       ## the live SettingsScreen (`this`)
var gMi2Go: Il2CppPtr = nil         ## its GameObject, from step 1
var gMi2GoClass: Il2CppPtr = nil    ## Il2CppClass* UnityEngine.GameObject
var gMi2New: Il2CppPtr = nil        ## the GameObject built in steps 3/4
var gMi2Tmp: Il2CppPtr = nil        ## a live TextMeshProUGUI, for step 5
var gMi2TmpOwner: Il2CppPtr = nil   ## the control that owns it (parent anchor)

proc mi2Fn(i: int32): Il2CppPtr =
  ## A verified code pointer, or nil. Logged on refusal so an unbound target is
  ## never mistaken for a step that ran and did nothing.
  result = cMi2Fn(i)
  if result == nil:
    warn "invoke2: target " & readCString(cMi2Name(i)) & " @ 0x" &
         hexOf(uint64(cMi2Rva(i))) & " did not verify on this build; the step " &
         "that needs it is skipped"

proc mi2Str(p: Il2CppPtr): string =
  ## A returned `System.String*` as text, by the FIXED layout the host already
  ## trusts (length @ +0x10, UTF-16 @ +0x14) -- `suiReadString`, from
  ## `settingsui.nim`. Self-validating: a wrong call cannot return readable text
  ## by accident.
  result = suiReadString(p)

# ---------------------------------------------------------------------------
# STEP 1 -- read-only instance calls by RVA
#
# `Component::get_gameObject(this)` then `Object::GetInstanceID` and
# `Object::get_name` on what it returned. All three are side-effect-free
# getters. Together they prove the instance convention end to end: a reference
# return that is a real Unity object (its instance id is non-zero), and a String
# return whose bytes decode to the object's actual name.
# ---------------------------------------------------------------------------
proc mi2Step1() =
  okLog "invoke2 STEP 1: BEGIN -- direct-RVA instance getters on this=0x" &
        hexOf(cast[uint64](gMi2Self))
  let fnGo = mi2Fn(Mi2GetGameObject)
  if fnGo == nil or gMi2Self == nil:
    return
  okLog "invoke2 STEP 1: calling Component::get_gameObject @ 0x" &
        hexOf(uint64(cMi2Rva(Mi2GetGameObject))) & " (RCX=this, RDX=MethodInfo*=0)"
  let go = cMi2CallPP(fnGo, gMi2Self)
  okLog "invoke2 STEP 1: get_gameObject returned 0x" & hexOf(cast[uint64](go))
  if go == nil or cIsReadable(go, 0x10'i32) == 0'i32:
    warn "invoke2 STEP 1: the returned GameObject is null or unreadable; " &
         "steps 3-5 have no anchor and will be skipped"
    return
  gMi2Go = go
  gMi2GoClass = cReadPtrAt(go, 0'i32)      # Il2CppObject header: klass @ +0
  okLog "invoke2 STEP 1: GameObject klass (raw header read, no reflection) = 0x" &
        hexOf(cast[uint64](gMi2GoClass))

  let fnId = mi2Fn(Mi2GetInstanceId)
  if fnId != nil:
    okLog "invoke2 STEP 1: calling Object::GetInstanceID @ 0x" &
          hexOf(uint64(cMi2Rva(Mi2GetInstanceId)))
    let id = cMi2CallIP(fnId, go)
    okLog "invoke2 STEP 1: GetInstanceID = " & $int(id) &
          (if id != 0'i32: "  <-- non-zero: a REAL live Unity object"
           else: "  <-- zero, which a live object never is; suspect")

  let fnName = mi2Fn(Mi2GetName)
  if fnName != nil:
    okLog "invoke2 STEP 1: calling Object::get_name @ 0x" &
          hexOf(uint64(cMi2Rva(Mi2GetName)))
    let sp = cMi2CallPP(fnName, go)
    let s = mi2Str(sp)
    okLog "invoke2 STEP 1: get_name returned String*=0x" & hexOf(cast[uint64](sp)) &
          " -> \"" & s & "\"" &
          (if s.len > 0: "  <-- DECODED: direct-RVA instance calls WORK"
           else: "  <-- did not decode as a String")
  okLog "invoke2 STEP 1: END"

# ---------------------------------------------------------------------------
# STEP 2 -- static calls by RVA
#
# Three zero-argument statics whose answers are independently checkable:
# `Time.frameCount` (large and increasing), `Screen.width`/`Screen.height` (the
# window). RCX carries only the hidden MethodInfo*, which these bodies never
# read -- the static half of the convention.
# ---------------------------------------------------------------------------
proc mi2Step2() =
  okLog "invoke2 STEP 2: BEGIN -- direct-RVA STATIC calls (RCX=MethodInfo*=0)"
  let fnF = mi2Fn(Mi2FrameCount)
  if fnF != nil:
    okLog "invoke2 STEP 2: calling Time::get_frameCount @ 0x" &
          hexOf(uint64(cMi2Rva(Mi2FrameCount)))
    okLog "invoke2 STEP 2: Time.frameCount = " & $int(cMi2CallIV(fnF))
  let fnW = mi2Fn(Mi2ScreenWidth)
  let fnH = mi2Fn(Mi2ScreenHeight)
  if fnW != nil and fnH != nil:
    okLog "invoke2 STEP 2: calling Screen::get_width/get_height @ 0x" &
          hexOf(uint64(cMi2Rva(Mi2ScreenWidth))) & " / 0x" &
          hexOf(uint64(cMi2Rva(Mi2ScreenHeight)))
    okLog "invoke2 STEP 2: Screen = " & $int(cMi2CallIV(fnW)) & "x" &
          $int(cMi2CallIV(fnH)) &
          "  <-- compare with the game window: if it matches, static " &
          "direct-RVA calls WORK"
  okLog "invoke2 STEP 2: END"

# ---------------------------------------------------------------------------
# STEP 3 -- allocate a managed object
#
# `il2cpp_object_new(klass)`, where `klass` came from the raw object header of a
# LIVE GameObject (step 1) rather than from any metadata lookup. That is the
# whole trick: the class pointer for a type is free the moment you hold one
# instance of it, so no `il2cpp_class_from_name` and no reflection is involved.
#
# The game's own .data cache slot for `Il2CppClass* UnityEngine.GameObject` is
# read too, purely as a CROSS-CHECK: if the two agree, the header read is
# confirmed against the compiler's own answer.
# ---------------------------------------------------------------------------
proc mi2Step3() =
  okLog "invoke2 STEP 3: BEGIN -- il2cpp_object_new for UnityEngine.GameObject"
  if cMi2HaveObjectNew() == 0'i32:
    warn "invoke2 STEP 3: il2cpp_object_new is not exported by this " &
         "GameAssembly.dll; object creation is unreachable this way"
    return
  if gMi2GoClass == nil:
    warn "invoke2 STEP 3: no GameObject klass from step 1; skipping"
    return
  let slot = cMi2GoClassSlot()
  okLog "invoke2 STEP 3: klass from live header = 0x" &
        hexOf(cast[uint64](gMi2GoClass)) & "; klass from the game's own .data " &
        "cache slot (RVA 0x6e03058) = 0x" & hexOf(cast[uint64](slot)) &
        (if slot == nil: "  (not initialised yet -- expected, it is lazy)"
         elif slot == gMi2GoClass: "  <-- THEY AGREE"
         else: "  <-- they DISAGREE; trusting the live header")
  okLog "invoke2 STEP 3: calling il2cpp_object_new(0x" &
        hexOf(cast[uint64](gMi2GoClass)) & ")"
  let obj = cMi2ObjectNew(gMi2GoClass)
  okLog "invoke2 STEP 3: il2cpp_object_new returned 0x" & hexOf(cast[uint64](obj))
  if obj == nil or cIsReadable(obj, 0x10'i32) == 0'i32:
    warn "invoke2 STEP 3: the allocation is null or unreadable; step 4 skipped"
    return
  let hdr = cReadPtrAt(obj, 0'i32)
  okLog "invoke2 STEP 3: allocated object's header klass = 0x" &
        hexOf(cast[uint64](hdr)) &
        (if hdr == gMi2GoClass:
           "  <-- matches the requested class: MANAGED ALLOCATION WORKS"
         else: "  <-- does NOT match the requested class; not trusting it")
  if hdr == gMi2GoClass:
    gMi2New = obj
  okLog "invoke2 STEP 3: END"

# ---------------------------------------------------------------------------
# STEP 4 -- construct it, and try to attach a component
#
# The constructor first: `GameObject::.ctor(String)` on the raw allocation from
# step 3, which is EXACTLY what the game's own `CreateUIElementRoot` does two
# instructions after `il2cpp::vm::Object::New`. The proof it worked is a
# round-trip: `get_name` on the constructed object must read back the string we
# passed. A raw allocation that was never constructed has no native Unity object
# behind it and cannot answer that.
#
# Then the component question, which is the one that decides whether a full
# CREATE path exists or only a CLONE path:
#
#   4a  the GENERIC route: `AddComponent<T>()` is shared code selected entirely
#       by its `MethodInfo*`. We do not synthesise one -- we read the pointer the
#       game itself wrote into its .data cache slot for
#       `AddComponent<RectTransform>`. No reflection, no metadata walk.
#   4b  the TYPE route: `AddComponent(System.Type)` needs a live `System.Type`,
#       which means `il2cpp_class_get_type` + `il2cpp_type_get_object`. Those sit
#       on the reflection surface this build has been faulting on, so they are
#       PROBED -- resolve them, call them, log what comes back -- and the result
#       is reported rather than assumed. The System.Type is only produced here;
#       it is deliberately NOT handed to AddComponent, because attaching an
#       arbitrary EFT MonoBehaviour to a detached GameObject would run its Awake.
# ---------------------------------------------------------------------------
proc mi2Step4() =
  okLog "invoke2 STEP 4: BEGIN -- GameObject::.ctor(String) + AddComponent routes"
  if gMi2New == nil:
    warn "invoke2 STEP 4: no allocation from step 3; skipping the ctor"
  else:
    let fnCtor = mi2Fn(Mi2GoCtorString)
    let nameStr = cMi2ProbeNameStr()
    okLog "invoke2 STEP 4: il2cpp_string_new(\"" & readCString(cMi2ProbeName()) &
          "\") = 0x" &
          hexOf(cast[uint64](nameStr))
    if fnCtor != nil and nameStr != nil:
      okLog "invoke2 STEP 4: calling GameObject::.ctor @ 0x" &
            hexOf(uint64(cMi2Rva(Mi2GoCtorString))) &
            " (RCX=this, RDX=name, R8=MethodInfo*=0)"
      cMi2CallVPP(fnCtor, gMi2New, nameStr)
      okLog "invoke2 STEP 4: .ctor returned without faulting"
      let fnName = mi2Fn(Mi2GetName)
      if fnName != nil:
        let back = mi2Str(cMi2CallPP(fnName, gMi2New))
        okLog "invoke2 STEP 4: get_name round-trip = \"" & back & "\"" &
              (if back == readCString(cMi2ProbeName()):
                 "  <-- EXACT MATCH: a real GameObject was CREATED from a detour"
               else: "  <-- does not match what was passed")
      let fnAct = mi2Fn(Mi2GoSetActive)
      if fnAct != nil:
        okLog "invoke2 STEP 4: calling GameObject::SetActive(false) @ 0x" &
              hexOf(uint64(cMi2Rva(Mi2GoSetActive))) & " (a bool argument)"
        cMi2CallVPB(fnAct, gMi2New, 0'i32)
        okLog "invoke2 STEP 4: SetActive returned without faulting"

  # ---- 4a: the generic AddComponent<T>, driven by the game's own MethodInfo ----
  let mi = cMi2AddCompRectMi()
  okLog "invoke2 STEP 4a: MethodInfo* for AddComponent<RectTransform> from the " &
        "game's .data cache slot (RVA 0x6e19580) = 0x" & hexOf(cast[uint64](mi))
  if mi == nil:
    okLog "invoke2 STEP 4a: that slot is still null -- TMP's default-control " &
          "code has not run yet, so the instantiation's MethodInfo does not " &
          "exist. NOT calling a generic method with a NULL MethodInfo (the " &
          "callee dereferences it at +0x38)."
  elif gMi2New == nil:
    warn "invoke2 STEP 4a: no constructed GameObject to attach to; skipping"
  else:
    let fnGen = mi2Fn(Mi2AddComponentGen)
    if fnGen != nil:
      okLog "invoke2 STEP 4a: calling GameObject::AddComponent<RectTransform> @ 0x" &
            hexOf(uint64(cMi2Rva(Mi2AddComponentGen))) &
            " (RCX=this, RDX=the REAL MethodInfo*)"
      let comp = cMi2CallGeneric0(fnGen, gMi2New, mi)
      okLog "invoke2 STEP 4a: AddComponent<RectTransform> returned 0x" &
            hexOf(cast[uint64](comp)) &
            (if comp != nil:
               "  <-- A COMPONENT WAS ATTACHED without reflection"
             else: "  <-- null; no component attached")

  # ---- 4b: can a System.Type be produced at all on this build? ----
  if cMi2HaveTypeRoute() == 0'i32:
    okLog "invoke2 STEP 4b: the AddComponent(Type) route is unreachable -- " &
          $cMi2TypeRouteWhy()
  elif gMi2GoClass == nil:
    okLog "invoke2 STEP 4b: no klass to convert; skipping"
  else:
    okLog "invoke2 STEP 4b: probing il2cpp_class_get_type (through the ARMED " &
          "token gate) + il2cpp_type_get_object on the GameObject klass -- " &
          "probed, not assumed"
    let tobj = cMi2TypeObjectOf(gMi2GoClass)
    okLog "invoke2 STEP 4b: System.Type object = 0x" & hexOf(cast[uint64](tobj)) &
          "  (" & $cMi2TypeRouteWhy() & ")" &
          (if tobj != nil:
             "  <-- a live System.Type EXISTS, so AddComponent(Type) is reachable " &
             "for any type we hold a klass for"
           else: "  <-- null; the AddComponent(Type) route is NOT reachable")
  okLog "invoke2 STEP 4: END"

# ---------------------------------------------------------------------------
# STEP 5 -- the visible proof: CLONE a live UI label and retarget it
#
# `Object::Instantiate(Object original)` is static, takes one reference and
# needs neither a `System.Type` nor a generic `MethodInfo*` -- so it is the one
# UI-creation path that is reachable no matter how steps 4a/4b turn out.
#
# It is called on the TextMeshProUGUI COMPONENT rather than on its GameObject,
# deliberately: Unity clones the whole GameObject either way, but cloning the
# component hands back the CLONED COMPONENT directly, which is the pointer we
# need for the raw `m_text` write. Cloning the GameObject would hand back a
# GameObject and leave us needing `GetComponent` -- which needs a Type again.
#
# Then: `SetParentAndAlign(cloneGO, ownerGO)` -- Unity's own UI parenting helper,
# static, two GameObjects, no Type -- puts it into the live Canvas hierarchy,
# `SetActive(true)` shows it, and the proven raw pointer write puts our text in
# `m_text`. That last step is the host's existing, live-validated primitive; the
# new part is everything that produced an object to write into.
# ---------------------------------------------------------------------------
proc mi2FindTmp(tabPtr: Il2CppPtr) =
  ## First control on this tab that has a TextMeshProUGUI behind it, by the
  ## same guarded chain `suiReadControlLabel` walks: control.Text -> LocalizedText
  ## -> List<TMP> -> items[0]. Read-only; every hop `cIsReadable`-guarded.
  gMi2Tmp = nil
  gMi2TmpOwner = nil
  if tabPtr == nil or cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) == 0'i32:
    return
  let lst = cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    return
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if arr == nil or size <= 0'i32:
    return
  let n = (if size > 16'i32: 16'i32 else: size)
  for i in 0 ..< int(n):
    let slot = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) == 0'i32:
      continue
    let control = cReadPtrAt(slot, 0'i32)
    if control == nil or cIsReadable(control, cSuiOffCtrlText() + 8'i32) == 0'i32:
      continue
    let locText = cReadPtrAt(control, cSuiOffCtrlText())
    if locText == nil or cIsReadable(locText, cSuiOffLocTextList() + 8'i32) == 0'i32:
      continue
    let tmpList = cReadPtrAt(locText, cSuiOffLocTextList())
    if tmpList == nil or cIsReadable(tmpList, cSuiOffListItems() + 8'i32) == 0'i32:
      continue
    let tmpArr = cReadPtrAt(tmpList, cSuiOffListItems())
    if tmpArr == nil or cIsReadable(tmpArr, cSuiOffArrElems() + 8'i32) == 0'i32:
      continue
    let tmp0 = cReadPtrAt(tmpArr, cSuiOffArrElems())
    if tmp0 == nil or cIsReadable(tmp0, cSuiOffTmpMText() + 8'i32) == 0'i32:
      continue
    if suiReadString(cReadPtrAt(tmp0, cSuiOffTmpMText())).len == 0:
      continue                     # no readable label: not the anchor we want
    gMi2Tmp = tmp0
    gMi2TmpOwner = control
    return

proc mi2Step5(tabPtr: Il2CppPtr) =
  okLog "invoke2 STEP 5: BEGIN -- clone a live UI label via Object::Instantiate"
  mi2FindTmp(tabPtr)
  if gMi2Tmp == nil:
    warn "invoke2 STEP 5: no readable TextMeshProUGUI found on this tab; " &
         "nothing to clone (open another settings tab to retry)"
    return
  okLog "invoke2 STEP 5: anchor TMP=0x" & hexOf(cast[uint64](gMi2Tmp)) &
        " owner control=0x" & hexOf(cast[uint64](gMi2TmpOwner)) &
        " current label=\"" & suiReadString(cReadPtrAt(gMi2Tmp,
                                                       cSuiOffTmpMText())) & "\""

  let fnInst = mi2Fn(Mi2Instantiate)
  if fnInst == nil:
    return
  okLog "invoke2 STEP 5: calling Object::Instantiate(Object) @ 0x" &
        hexOf(uint64(cMi2Rva(Mi2Instantiate))) & " (STATIC: RCX=original, " &
        "RDX=MethodInfo*=0) on the TMP COMPONENT"
  let clone = cMi2CallPS1(fnInst, gMi2Tmp)
  okLog "invoke2 STEP 5: Instantiate returned 0x" & hexOf(cast[uint64](clone))
  if clone == nil or cIsReadable(clone, cSuiOffTmpMText() + 8'i32) == 0'i32:
    warn "invoke2 STEP 5: the clone is null or unreadable; no visible proof"
    return
  okLog "invoke2 STEP 5: clone klass = 0x" &
        hexOf(cast[uint64](cReadPtrAt(clone, 0'i32))) & " (anchor klass = 0x" &
        hexOf(cast[uint64](cReadPtrAt(gMi2Tmp, 0'i32))) & ")"

  # The clone's GameObject, and the anchor's, by the same instance call step 1
  # proved. Both are needed for the parenting helper.
  let fnGo = mi2Fn(Mi2GetGameObject)
  if fnGo == nil:
    return
  let cloneGo = cMi2CallPP(fnGo, clone)
  let ownerGo = (if gMi2TmpOwner != nil: cMi2CallPP(fnGo, gMi2TmpOwner)
                 else: cast[Il2CppPtr](0))
  okLog "invoke2 STEP 5: cloneGO=0x" & hexOf(cast[uint64](cloneGo)) &
        " ownerGO=0x" & hexOf(cast[uint64](ownerGo))

  if cloneGo != nil and ownerGo != nil:
    let fnPar = mi2Fn(Mi2SetParentAlign)
    if fnPar != nil:
      okLog "invoke2 STEP 5: calling TMP_DefaultControls::SetParentAndAlign @ 0x" &
            hexOf(uint64(cMi2Rva(Mi2SetParentAlign))) &
            " (STATIC: RCX=child, RDX=parent, R8=MethodInfo*=0)"
      cMi2CallVS2(fnPar, cloneGo, ownerGo)
      okLog "invoke2 STEP 5: SetParentAndAlign returned without faulting -- the " &
            "clone is now inside the live settings Canvas hierarchy"

  # The text, by the PROVEN raw field write -- the same primitive the version
  # brand uses. `m_text` is a reference slot on TextMeshProUGUI at the offset
  # `aowlspt_settingsui.h` already validated live.
  let s = cMi2ProbeTextStr()
  okLog "invoke2 STEP 5: il2cpp_string_new(\"" & readCString(cMi2ProbeText()) &
        "\") = 0x" &
        hexOf(cast[uint64](s))
  if s != nil:
    if cUxWritePtr(clone, cSuiOffTmpMText(), s) != 0'i32:
      okLog "invoke2 STEP 5: wrote the probe text into the clone's m_text (+0x" &
            hexOf(uint64(cSuiOffTmpMText())) & ") by raw field write"
    else:
      warn "invoke2 STEP 5: the clone's m_text slot was not safely writable"

  if cloneGo != nil:
    let fnAct = mi2Fn(Mi2GoSetActive)
    if fnAct != nil:
      okLog "invoke2 STEP 5: calling GameObject::SetActive(true) on the clone"
      cMi2CallVPB(fnAct, cloneGo, 1'i32)
      okLog "invoke2 STEP 5: SetActive returned without faulting"
  okLog "invoke2 STEP 5: END -- if a duplicated label reading \"" &
        readCString(cMi2ProbeText()) & "\" is visible on the settings screen, Unity UI is CREATABLE from a " &
        "detour with no reflection"

# ---------------------------------------------------------------------------
# The guarded step runner
#
# One exported body, dispatched on a step number the C thunk stashes -- the same
# shape `settingsMetaProbe` uses, and for the same reason: `aowl_p_p_seh` carries
# exactly one pointer, and each step must be guarded SEPARATELY so a fault in one
# neither crashes the game nor hides the ones after it.
# ---------------------------------------------------------------------------
{.emit: """
extern void* aowl_mi2_step_body(void* a);
static int g_aowl_mi2_step = 0;
static int aowl_mi2_step_get(void) { return g_aowl_mi2_step; }
static void* aowl_mi2_step_guarded(void* a, int step) {
    g_aowl_mi2_step = step;
    return aowl_p_p_seh((void*)aowl_mi2_step_body, a);
}
""".}
proc cMi2StepGet(): int32 {.importc: "aowl_mi2_step_get", nodecl.}
proc cMi2StepGuarded(a: Il2CppPtr; step: int32): Il2CppPtr {.
  importc: "aowl_mi2_step_guarded", nodecl.}

proc mi2StepBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_mi2_step_body", cdecl.} =
  ## `a` is the tab pointer (step 5 needs it); the step number comes from the
  ## C-side global. Returns a non-nil sentinel on clean completion; the guard
  ## returns nil if this step faulted.
  case int(cMi2StepGet())
  of 1: mi2Step1()
  of 2: mi2Step2()
  of 3: mi2Step3()
  of 4: mi2Step4()
  of 5: mi2Step5(a)
  else: discard
  result = cast[Il2CppPtr](1)

## Runs at most once per session, whatever the outcome: the ladder is a proof,
## not a feature, and a second run would clone a second label.
var gMi2Done = false
var gMi2Fires = 0

proc mi2LadderFired(regs: Il2CppPtr) =
  ## Dispatched by slot identity from `patchReturned` for the kind=9 POSTFIX
  ## detour on `SettingsScreen::EnsureTabInitialized`. The tab's controls exist
  ## by the time this runs -- that is the whole reason the hook is a postfix.
  inc gMi2Fires
  let tid = int(cThreadId())
  let onHost = (tid == int(gHostThreadId))
  let selfPtr = cRegsInt(regs, 0'i32)            # RCX = this (SettingsScreen)
  let group = cast[int32](uint32(cRegsInt(regs, 1'i32) and 0xFFFFFFFF'u64))
  if gMi2Fires == 1:
    okLog "invoke2: ladder hook first fired on thread " & $tid &
          " (host thread " & $int(gHostThreadId) & ")" &
          (if onHost: " -- HOST thread (unexpected, NOT Unity's); refusing"
           else: " -- Unity's main thread") & "; this=0x" & hexOf(selfPtr)
  if onHost or gMi2Done or selfPtr == 0'u64:
    return
  gMi2Done = true                                # once only, whatever follows
  gMi2Self = cast[Il2CppPtr](selfPtr)

  let off = cSuiGroupTabOffset(group)
  var tab: Il2CppPtr = nil
  if off >= 0'i32 and cIsReadable(gMi2Self, off + 8'i32) != 0'i32:
    tab = cReadPtrAt(gMi2Self, off)
  okLog "invoke2: running the direct-invocation ladder (group=" &
        readCString(cSuiGroupName(group)) & ", tab=0x" &
        hexOf(cast[uint64](tab)) & "). " & $int(cMi2OkCount()) &
        " target(s) verified, " & $int(cMi2BadCount()) & " rejected so far."

  for step in 1 .. 5:
    if cMi2StepGuarded(tab, int32(step)) == nil:
      warn "invoke2 STEP " & $step & ": FAULTED -- the VEH guard caught it and " &
           "the game survived. This step is the answer for this build; the " &
           "remaining steps still run."
  okLog "invoke2: ladder complete. Every step above is logged BEGIN/END, so the " &
        "last BEGIN without an END names exactly where a fault landed."

  # THE NATIVE-UI LAYER RIDES THIS DETOUR AS A DRAIN.
  #
  # It is not a second hook: two detours on one function have the second
  # overwrite the first's trampoline and silently kill the first feature. This
  # is the same tab pointer, the same Unity-thread frame, after the ladder has
  # finished -- and `nuProofRun` carries its own single `aowl_p_p_seh`, which is
  # correct here because the ladder's per-step guards have all returned by now.
  # Nothing above this line is changed by it.
  if nuProofWanted():
    nuProofRun(tab)
  # The unified framework's dual-backend proof rides the SAME drain (already
  # inside this postfix's guard -- it opens none of its own, per §3 no nesting).
  if auProofWanted():
    auProofRun(tab)
  # The NATIVE-UI TOOLKIT's self-test rides the SAME drain. Also inside this
  # postfix's guard, so it opens NONE of its own (§3: nesting disarms the outer).
  if nuKitSelfTestWanted():
    nuKitSelfTestRun(tab)

proc bindManagedInvoke(verbose: bool): bool =
  ## Installs the kind=9 POSTFIX detour on `SettingsScreen::EnsureTabInitialized`
  ## from the verified static target in `aowlspt_bridge.h` -- the same target the
  ## Phase-1.5 control probe uses, so the two are MUTUALLY EXCLUSIVE: two hooks
  ## on one function would have the second overwrite the first's trampoline.
  ## This one arms first when `managedInvokeProbe` is set, and the control probe
  ## then skips itself. Opt-in; binds nothing on a build whose prologue differs.
  if gMi2Slot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  # Report the target census once, so an unverified build is obvious in the log
  # before any step runs rather than as five separate skips.
  var ok = 0
  var bad = 0
  for i in 0 ..< int(cMi2TargetCount()):
    if cMi2Fn(int32(i)) != nil: inc ok else: inc bad
  okLog "invoke2: " & $ok & " of " & $int(cMi2TargetCount()) &
        " managed targets verified by RVA + prologue on this build" &
        (if bad > 0: " (" & $bad & " rejected)" else: "")
  if cMi2BaseOk() == 0'i32:
    if verbose:
      info "invoke2: GameAssembly.dll is not loaded; nothing to bind"
    return false
  let count = cBridgeSettingsTabTargetCount()
  for i in 0 ..< int(count):
    let fn = cBridgeSettingsTabTargetAt(int32(i))
    if fn == nil:
      if verbose:
        info "invoke2: tab-init target " & $i & " did not verify on this build"
      continue
    let spec = readCString(cBridgeSettingsTabTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 9'i32,
                   true, cBridgeSettingsTabTargetSlots(int32(i))):
      okLog "managed-invoke probe armed POSTFIX on " & spec &
            "; open Settings and click a tab to run the five-step " &
            "direct-RVA invocation ladder (every step guarded; a fault is " &
            "caught and named, never a crash)"
      return true
  result = false
