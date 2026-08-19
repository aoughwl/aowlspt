## The knobs: one table, and the machinery that applies and un-applies it.
##
## Every entry here is a **guess about a name**. Unity's `QualitySettings`,
## `Time`, `Physics`, `Application` and `SystemInfo` are public, documented and
## stable across versions — but BSG ship an IL2CPP build with managed code
## stripping on, and a property setter that nothing in the game calls can be
## absent from `global-metadata.dat` entirely. So nothing in this file assumes:
## it asks the runtime, and when the runtime says no it records *what* it asked
## for and moves on.
##
## The rules, in order of how much they matter:
##
## 1. **A knob that cannot be read is never written.** The original value is
##    what makes the change reversible, and a change we cannot undo is one this
##    mod will not make. "No getter" is a refusal, not a reason to write blind.
## 2. **A value outside the knob's sane band is refused, not clamped.** Clamping
##    a typo into a plausible number hides the typo. The band is in the table.
## 3. **The write is read back.** Unity clamps several of these itself
##    (`shadowCascades` snaps to 0/2/4), so "the setter did not error" is not
##    the same claim as "the setting is now what I asked for", and the readout
##    says which happened.
## 4. **An enum is a number in both directions, and this file no longer
##    assumes otherwise.** It used to: the host bound an enum *argument* from a
##    JSON number but classified an enum *return* the way it classified any
##    other non-primitive, so `get(...)` handed back `{"handle":6,...}` and
##    `asFloat()` on that was 0.0 with `ok` true — a plausible number rather
##    than a refusal, and a leaked GC handle per read. Every enum knob was
##    therefore read through `bindMethodAs(..., [], fkI32)`, which is an
##    *assertion* about the underlying width rather than something the runtime
##    said.
##
##    `describeResult` unboxes an enum return by the payload width the runtime
##    reports now, so the boxed getter answers a plain number and the assertion
##    is not needed. It is still here, and it is still used — but only as a
##    **fallback**, entered when the boxed getter answers something
##    handle-shaped, which is what an older host does. A knob that went through
##    it says so in the log, because "the runtime's own metadata said 4 bytes"
##    and "this file asserted 4 bytes" are different amounts of confidence and
##    a readout that spelled them the same would be hiding the weaker one.
##
## 5. **A value that arrives handle-shaped is refused, whatever its kind.**
##    `asFloat`/`asInt` on `{"handle":6,"type":"..."}` are 0.0 and 0 with `ok`
##    true. That is the failure shape with the longest time-to-diagnosis
##    available, so every read here checks the shape before it trusts the
##    number — and releases the handle the host took out, because a poll that
##    leaks one per call pins an object per call.
##
## Nothing here has ever run against BSG's client.

import std/strutils
import aowlspt
import aowlspt/game
import aowlspt/json
import aowlspt/il2cpp
import aowlspt/fast

# ---------------------------------------------------------------------------
# Owners
# ---------------------------------------------------------------------------

const
  OwnerQuality* = 0
  OwnerApplication* = 1
  OwnerTime* = 2
  OwnerPhysics* = 3
  OwnerSystemInfo* = 4
  OwnerCount* = 5

proc ownerName*(i: int): string =
  ## A `case` rather than a `const` array because this is the one place the
  ## mapping lives and a mistyped index should be a compile error in a `case`
  ## rather than an out-of-bounds read.
  case i
  of OwnerQuality: result = "UnityEngine.QualitySettings"
  of OwnerApplication: result = "UnityEngine.Application"
  of OwnerTime: result = "UnityEngine.Time"
  of OwnerPhysics: result = "UnityEngine.Physics"
  of OwnerSystemInfo: result = "UnityEngine.SystemInfo"
  else: result = ""

# Declared bare and filled from inside a proc. A global initialised by a *call*
# is left zeroed in a nimony `--app:lib` build, and a zeroed `GameType` has an
# empty name — `resolveNow` warns about exactly that. `gameType` is a template
# for the same reason; here the array element is assigned instead.
var gOwners: array[OwnerCount, GameType]
var gOwnersReady = false

proc initOwners*() =
  if gOwnersReady:
    return
  gOwnersReady = true
  var i = 0
  while i < OwnerCount:
    gOwners[i] = GameType(name: ownerName(i), handle: 0, tried: false)
    inc i

# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------

type
  KnobKind* = enum
    kkFloat, kkInt, kkBool, kkEnum

  Knob* = object
    section*: string   ## config section: "quality", "app", "time"
    key*: string       ## config key inside that section
    owner*: int
    prop*: string      ## the C# property name, without get_/set_
    alt*: string       ## a second name to try; "" when there is only one
    kind*: KnobKind
    lo*: float         ## sane band, inclusive
    hi*: float

const KnobCount* = 23

proc knobAt*(i: int): Knob =
  ## The table.
  ##
  ## Written as a `case` returning object literals rather than a `const` array
  ## for the reason above: in a `--app:lib` build a literal is the only shape
  ## that survives, and a `case` in a proc is a literal at every arm.
  ##
  ## `alt` exists because Unity renamed two of these. `masterTextureLimit`
  ## became `globalTextureMipmapLimit` in 2022.2 with the old name kept as an
  ## `[Obsolete]` forwarder, and `blendWeights` became `skinWeights` in 2019.
  ## Which one survived stripping in BSG's build is not knowable from here, so
  ## both are tried and the readout says which answered.
  case i
  of  0: result = Knob(section: "quality", key: "shadowDistance",
                       owner: OwnerQuality, prop: "shadowDistance", alt: "",
                       kind: kkFloat, lo: 10.0, hi: 400.0)
  of  1: result = Knob(section: "quality", key: "shadowCascades",
                       owner: OwnerQuality, prop: "shadowCascades", alt: "",
                       kind: kkInt, lo: 0.0, hi: 4.0)
  of  2: result = Knob(section: "quality", key: "shadowResolution",
                       owner: OwnerQuality, prop: "shadowResolution", alt: "",
                       kind: kkEnum, lo: 0.0, hi: 3.0)
  of  3: result = Knob(section: "quality", key: "lodBias",
                       owner: OwnerQuality, prop: "lodBias", alt: "",
                       kind: kkFloat, lo: 0.5, hi: 4.0)
  of  4: result = Knob(section: "quality", key: "maximumLODLevel",
                       owner: OwnerQuality, prop: "maximumLODLevel", alt: "",
                       kind: kkInt, lo: 0.0, hi: 3.0)
  of  5: result = Knob(section: "quality", key: "textureMipmapLimit",
                       owner: OwnerQuality, prop: "globalTextureMipmapLimit",
                       alt: "masterTextureLimit",
                       kind: kkInt, lo: 0.0, hi: 3.0)
  of  6: result = Knob(section: "quality", key: "anisotropicFiltering",
                       owner: OwnerQuality, prop: "anisotropicFiltering",
                       alt: "", kind: kkEnum, lo: 0.0, hi: 2.0)
  of  7: result = Knob(section: "quality", key: "pixelLightCount",
                       owner: OwnerQuality, prop: "pixelLightCount", alt: "",
                       kind: kkInt, lo: 0.0, hi: 8.0)
  of  8: result = Knob(section: "quality", key: "particleRaycastBudget",
                       owner: OwnerQuality, prop: "particleRaycastBudget",
                       alt: "", kind: kkInt, lo: 4.0, hi: 4096.0)
  of  9: result = Knob(section: "quality", key: "softParticles",
                       owner: OwnerQuality, prop: "softParticles", alt: "",
                       kind: kkBool, lo: 0.0, hi: 1.0)
  of 10: result = Knob(section: "quality", key: "realtimeReflectionProbes",
                       owner: OwnerQuality, prop: "realtimeReflectionProbes",
                       alt: "", kind: kkBool, lo: 0.0, hi: 1.0)
  of 11: result = Knob(section: "quality", key: "billboardsFaceCameraPosition",
                       owner: OwnerQuality,
                       prop: "billboardsFaceCameraPosition", alt: "",
                       kind: kkBool, lo: 0.0, hi: 1.0)
  of 12: result = Knob(section: "quality", key: "skinWeights",
                       owner: OwnerQuality, prop: "skinWeights",
                       alt: "blendWeights", kind: kkEnum, lo: 1.0, hi: 255.0)
  of 13: result = Knob(section: "quality", key: "vSyncCount",
                       owner: OwnerQuality, prop: "vSyncCount", alt: "",
                       kind: kkInt, lo: 0.0, hi: 4.0)
  of 14: result = Knob(section: "quality", key: "maxQueuedFrames",
                       owner: OwnerQuality, prop: "maxQueuedFrames", alt: "",
                       kind: kkInt, lo: 0.0, hi: 4.0)
  of 15: result = Knob(section: "quality", key: "streamingMipmapsActive",
                       owner: OwnerQuality, prop: "streamingMipmapsActive",
                       alt: "", kind: kkBool, lo: 0.0, hi: 1.0)
  of 16: result = Knob(section: "quality",
                       key: "streamingMipmapsMemoryBudget",
                       owner: OwnerQuality,
                       prop: "streamingMipmapsMemoryBudget", alt: "",
                       kind: kkFloat, lo: 128.0, hi: 16384.0)
  of 17: result = Knob(section: "quality", key: "asyncUploadTimeSlice",
                       owner: OwnerQuality, prop: "asyncUploadTimeSlice",
                       alt: "", kind: kkInt, lo: 1.0, hi: 33.0)
  of 18: result = Knob(section: "quality", key: "asyncUploadBufferSize",
                       owner: OwnerQuality, prop: "asyncUploadBufferSize",
                       alt: "", kind: kkInt, lo: 2.0, hi: 512.0)
  of 19: result = Knob(section: "quality", key: "asyncUploadPersistentBuffer",
                       owner: OwnerQuality,
                       prop: "asyncUploadPersistentBuffer", alt: "",
                       kind: kkBool, lo: 0.0, hi: 1.0)
  of 20: result = Knob(section: "app", key: "targetFrameRate",
                       owner: OwnerApplication, prop: "targetFrameRate",
                       alt: "", kind: kkInt, lo: -1.0, hi: 1000.0)
  of 21: result = Knob(section: "time", key: "fixedDeltaTime",
                       owner: OwnerTime, prop: "fixedDeltaTime", alt: "",
                       kind: kkFloat, lo: 0.00833, hi: 0.03334)
  of 22: result = Knob(section: "time", key: "maximumDeltaTime",
                       owner: OwnerTime, prop: "maximumDeltaTime", alt: "",
                       kind: kkFloat, lo: 0.02, hi: 0.5)
  else: result = Knob(section: "", key: "", owner: -1, prop: "", alt: "",
                      kind: kkFloat, lo: 0.0, hi: 0.0)

proc kindName*(k: KnobKind): string =
  case k
  of kkFloat: result = "float"
  of kkInt: result = "int"
  of kkBool: result = "bool"
  of kkEnum: result = "enum"

# ---------------------------------------------------------------------------
# Per-knob state
# ---------------------------------------------------------------------------

type
  KnobState* = object
    apply*: bool      ## the config asked for it
    want*: float      ## the value the config asked for
    readable*: bool   ## a getter answered
    applied*: bool    ## a setter ran and did not error
    exact*: bool      ## the read-back equalled `want`
    orig*: float      ## what it was before we touched it
    have*: float      ## what it is now, read back
    prop*: string     ## the property name that actually answered
    viaAssertion*: bool ## written through `bindMethodAs`, not the host's own
                        ## metadata — a weaker claim, so it is recorded
    why*: string      ## the refusal, when there is one

# Zeroed is the correct starting state: nothing asked for, nothing applied,
# no reason yet. A zeroed nimony string is a valid empty one.
var gState*: array[KnobCount, KnobState]

# ---------------------------------------------------------------------------
# The runtime, for the enum knobs only
# ---------------------------------------------------------------------------

var gRt: Il2Cpp
var gRtOpen = false

proc openRuntime*(): bool =
  ## Opens `GameAssembly.dll` in this process. Retried until it takes, because
  ## a mod loaded before the runtime would otherwise never bind — and never
  ## called at load time, where the game's assemblies do not exist yet.
  if gRtOpen:
    return true
  gRt = openIl2Cpp()
  if not gRt.loaded:
    return false
  gRtOpen = true
  result = true

proc runtimeOpen*(): bool = gRtOpen

# ---------------------------------------------------------------------------
# Reading and writing one knob
# ---------------------------------------------------------------------------

const Epsilon = 0.0005

proc nearly(a, b: float): bool =
  var d = a - b
  if d < 0.0: d = -d
  result = d <= Epsilon

proc handleShaped*(raw: string): bool =
  ## Whether a boxed result is a live-object handle rather than a scalar.
  ##
  ## This is the one check standing between the mod and the worst failure shape
  ## the boxed path has: `asFloat` on `{"handle":6,"type":"System.Int32"}` is
  ## 0.0 with `ok` true, so a knob would report "original 0.0" and then
  ## faithfully restore a zero it never read. The host does not answer this way
  ## for anything in the table any more; it did for enums until recently, and
  ## an older host in the same install still does.
  result = find(raw, "\"handle\":") >= 0 or find(raw, "\"type\":") >= 0

proc dropHandle(r: CallResult) =
  ## Let go of a handle the host took out on a value this mod is refusing.
  ## A refused read that keeps the handle pins one object per call, and the
  ## probe path runs over all 23 knobs on every self-test.
  let o = asObject(r)
  if o.ok:
    release(o.handle)

proc readScalar(t: var GameType; k: Knob; name: string;
                value: var float; why: var string): bool =
  ## The boxed path, for every kind including enums. One call per knob, once —
  ## `docs/PERF.md` puts that at about a microsecond, which is the right budget
  ## for something that happens at most twice in a session.
  ##
  ## An enum comes back as a plain number now: `describeResult` unboxes a
  ## small value type by the payload width the runtime reports, rather than
  ## registering a handle over it. `readEnumAsserted` below is what happens
  ## when that is not true — an older host — and the caller decides which by
  ## looking at the shape rather than at a version number.
  value = 0.0
  why = ""
  let r = t.get(name)
  if r.failed:
    why = r.error
    return false
  if r.isNull:
    why = "the getter returned null"
    return false
  if handleShaped(r.raw):
    dropHandle(r)
    why = "this host answered " & r.raw & " rather than a number"
    return false
  case k.kind
  of kkFloat: value = r.asFloat(0.0)
  of kkInt: value = float(r.asInt(0))
  of kkBool: value = (if r.asBool(false): 1.0 else: 0.0)
  of kkEnum: value = float(r.asInt(0))
  result = true

proc writeScalar(t: var GameType; k: Knob; name: string;
                 value: float; why: var string): bool =
  why = ""
  var r: CallResult
  case k.kind
  of kkFloat: r = t.set(name, v(value))
  of kkInt: r = t.set(name, v(int(value)))
  of kkBool: r = t.set(name, v(value > 0.5))
  of kkEnum:
    # The boxed path handles this: the host binds a value-type parameter from a
    # JSON number by the payload width the runtime reports, so an enum setter is
    # an ordinary call. It did not always, and `writeEnumAsserted` below is
    # still here as the fallback — a mod that only works against the newest
    # host is a mod that silently stops working on an older one, and the
    # fallback costs one refused call to find out.
    r = t.set(name, v(int(value)))
  if r.failed:
    why = r.error
    return false
  result = true

proc noArgsBindingStub(): Binding =
  ## A refused binding to hand back before the runtime is open. Written as an
  ## object literal so it is a literal everywhere it is used.
  Binding(ok: false, why: "", target: "", fn: nullPtr(), info: nullPtr(),
          argc: 0'i32, slots: 0'i32, mask: 0'u32, ret: fkNone,
          isStatic: true, bindNs: 0'i64)

proc enumBinding(owner, member: string; setter: bool;
                 why: var string): Binding =
  ## An enum property, by asserted register class. **The fallback, not the
  ## first choice** — see rule 4 at the top of this file.
  ##
  ## This used to say `aowlspt/fast`'s `classifyType` refuses an enum outright,
  ## because it decided from `findClass` and `classIsValueType` alone and
  ## nothing there says whether the underlying type is a byte, an int or a long.
  ## **It no longer refuses one**: `classifyClass` checks the type name first
  ## and then the width the runtime reports, so an enum narrow enough for a
  ## register classifies like any other value type. This proc is therefore one
  ## fallback further out than it was — it is what remains for a host whose
  ## boxed path came back handle-shaped, and `bindMethodAs` is still the
  ## sanctioned way to state a signature outright. What is being asserted here
  ## is narrow and checkable: `AnisotropicFiltering`,
  ## `ShadowResolution` and `SkinWeights` are all `enum : int` in Unity's own
  ## source, so one general-purpose register holding a 32-bit integer is the
  ## whole shape. `mask` stays 0 — no slot is a float.
  ##
  ## The host's boxed path does better than this now, because it asks the
  ## runtime for the width rather than asserting it. So this runs only where the
  ## boxed path came back handle-shaped, and every knob that used it says so.
  why = ""
  if not gRtOpen:
    why = "the IL2CPP runtime is not open"
    return noArgsBindingStub()
  if setter:
    result = bindMethodAs(gRt, owner, "set_" & member, [fkI32], fkVoid)
  else:
    result = bindMethodAs(gRt, owner, "get_" & member, [], fkI32)
  if not result.ok:
    why = result.why

proc readEnumAsserted(owner, prop: string; value: var float;
                      why: var string): bool =
  value = 0.0
  let b = enumBinding(owner, prop, false, why)
  if not b.ok:
    return false
  var a = noArgs()
  value = float(callInt32(b, nullPtr(), a))
  result = true

proc writeEnumAsserted(owner, prop: string; value: float;
                       why: var string): bool =
  let b = enumBinding(owner, prop, true, why)
  if not b.ok:
    return false
  var a = argsI(int64(value))
  callVoid(b, nullPtr(), a)
  result = true

proc readOne(t: var GameType; k: Knob; name: string; value: var float;
             viaAssert: var bool; why: var string): bool =
  ## One read of one name, boxed first and asserted only if it has to be.
  ##
  ## The fallback is entered on the *shape* of the answer rather than on a host
  ## version, because a version number is a claim about what should happen and
  ## the shape is what did. A knob whose getter is simply absent gets one clean
  ## refusal and does not also collect a binding failure for a method that is
  ## not there.
  viaAssert = false
  why = ""
  var w1 = ""
  if readScalar(t, k, name, value, w1):
    return true
  if k.kind != kkEnum or find(w1, "rather than a number") < 0:
    why = w1
    return false
  # An older host: it classified the enum return the way it classifies any
  # other non-primitive. Assert the width instead, and record that it was an
  # assertion.
  var w2 = ""
  if readEnumAsserted(ownerName(k.owner), name, value, w2):
    viaAssert = true
    return true
  why = w1 & "; and as an asserted int32 binding: " & w2
  result = false

proc tryNames(t: var GameType; k: Knob; value: var float;
              chosen: var string; viaAssert: var bool;
              why: var string): bool =
  ## `prop` first, then `alt`. The reason for reporting which one answered is
  ## that the two are not always the same setting on the same build, and a log
  ## line saying "shadow bias applied" without saying through which name is a
  ## line that cannot be checked later.
  chosen = k.prop
  viaAssert = false
  var w1 = ""
  if readOne(t, k, k.prop, value, viaAssert, w1):
    return true
  if k.alt.len == 0:
    why = w1
    return false
  chosen = k.alt
  var w2 = ""
  if readOne(t, k, k.alt, value, viaAssert, w2):
    return true
  chosen = k.prop
  viaAssert = false
  why = w1 & "; and " & k.alt & ": " & w2
  result = false

proc applyOne(t: var GameType; i: int) =
  let k = knobAt(i)
  gState[i].readable = false
  gState[i].applied = false
  gState[i].exact = false
  gState[i].viaAssertion = false
  gState[i].why = ""
  gState[i].prop = k.prop

  if not gState[i].apply:
    gState[i].why = "not enabled in config.json"
    return

  if not resolveNow(t):
    gState[i].why = "no such type: " & ownerName(k.owner)
    return

  # Rule 2: a value outside the band is refused rather than clamped.
  if gState[i].want < k.lo or gState[i].want > k.hi:
    gState[i].why = "value " & $gState[i].want & " is outside the band " &
                    $k.lo & " .. " & $k.hi & "; refused rather than clamped"
    return

  # Rule 1: read first. No original, no write.
  var orig = 0.0
  var chosen = ""
  var readAsserted = false
  var why = ""
  if not tryNames(t, k, orig, chosen, readAsserted, why):
    gState[i].why = "not readable on this build (" & why & ")"
    return
  gState[i].readable = true
  gState[i].orig = orig
  gState[i].have = orig
  gState[i].prop = chosen
  gState[i].viaAssertion = readAsserted

  var wwhy = ""
  var wrote = writeScalar(t, k, chosen, gState[i].want, wwhy)
  if not wrote and k.kind == kkEnum:
    # The host refused the enum — an older one, or a payload wider than eight
    # bytes. Assert the register class instead, and say in the log that the
    # value went in through an assertion rather than through the runtime's own
    # metadata, because those are different amounts of confidence.
    var awhy = ""
    if writeEnumAsserted(ownerName(k.owner), chosen, gState[i].want, awhy):
      wrote = true
      wwhy = ""
      gState[i].viaAssertion = true
    else:
      wwhy = wwhy & "; and as an asserted int32 binding: " & awhy
  if not wrote:
    gState[i].why = "readable but not writable (" & wwhy & ")"
    return
  gState[i].applied = true

  # Rule 3: read it back. Unity clamps several of these itself.
  var now = 0.0
  var c2 = ""
  var a2 = false
  var w3 = ""
  if tryNames(t, k, now, c2, a2, w3):
    gState[i].have = now
    if a2: gState[i].viaAssertion = true
    gState[i].exact = nearly(now, gState[i].want)
    if not gState[i].exact:
      gState[i].why = "the engine clamped it to " & $now
  else:
    gState[i].why = "written, but the read-back failed (" & w3 & ")"

proc restoreOne(t: var GameType; i: int) =
  if not gState[i].applied:
    return
  let k = knobAt(i)
  var why = ""
  var ok1 = writeScalar(t, k, gState[i].prop, gState[i].orig, why)
  if not ok1 and k.kind == kkEnum:
    ok1 = writeEnumAsserted(ownerName(k.owner), gState[i].prop,
                            gState[i].orig, why)
  if not ok1:
    gState[i].why = "could not be restored (" & why & ")"
    return

  # Rule 3 again, and it was missing here. A restore that only checks the setter
  # did not error makes exactly the claim the apply path refuses to make: the
  # engine clamps, and a `shadowCascades` that went in as 3 and came back as 4
  # would have been reported as "restored to 3". So the original is read back
  # too, and a restore that did not land says so instead of being counted.
  gState[i].applied = false
  var now = 0.0
  var c2 = ""
  var a2 = false
  var w3 = ""
  if tryNames(t, k, now, c2, a2, w3):
    gState[i].have = now
    if a2: gState[i].viaAssertion = true
    if not nearly(now, gState[i].orig):
      gState[i].why = "restored, but it read back as " & $now &
                      " rather than the original " & $gState[i].orig
    else:
      gState[i].why = ""
  else:
    gState[i].have = gState[i].orig
    gState[i].why = "restored, but the read-back failed (" & w3 & ")"

proc dispatch(i: int; restore: bool) =
  ## The owner is picked here rather than by indexing a `var` array through a
  ## helper that returns `var`, which nimony does not have.
  let k = knobAt(i)
  if k.owner < 0 or k.owner >= OwnerCount:
    return
  if restore:
    restoreOne(gOwners[k.owner], i)
  else:
    applyOne(gOwners[k.owner], i)

proc applyAll*(): int =
  ## Applies every enabled knob. Returns how many took effect.
  initOwners()
  result = 0
  var i = 0
  while i < KnobCount:
    dispatch(i, false)
    if gState[i].applied:
      inc result
    inc i

proc restoreAll*(): int =
  ## Puts back every original, in reverse. Reverse because two knobs on the
  ## same underlying setting (`skinWeights` and `blendWeights` are one setting
  ## under two names) must be undone in the order opposite to the one they were
  ## applied in, or the second undo overwrites the first.
  initOwners()
  result = 0
  var i = KnobCount - 1
  while i >= 0:
    let was = gState[i].applied
    dispatch(i, true)
    if was and not gState[i].applied:
      inc result
    dec i

proc appliedCount*(): int =
  result = 0
  var i = 0
  while i < KnobCount:
    if gState[i].applied: inc result
    inc i

proc refusedCount*(): int =
  result = 0
  var i = 0
  while i < KnobCount:
    if gState[i].apply and not gState[i].applied: inc result
    inc i

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

proc readKnobConfig*(doc: string; missing: var int) =
  ## Each knob is `{"apply": bool, "value": number}` under its section. A knob
  ## whose object is absent is simply off, which is the conservative default
  ## and needs no entry in the file.
  var i = 0
  while i < KnobCount:
    let k = knobAt(i)
    let base = k.section & "." & k.key
    let ja = field(doc, base & ".apply")
    let jv = field(doc, base & ".value")
    if not ja.exists:
      inc missing
      gState[i].apply = false
    else:
      gState[i].apply = asBool(ja, false)
    if jv.exists:
      gState[i].want = asFloat(jv, 0.0)
    else:
      if gState[i].apply:
        inc missing
      gState[i].want = 0.0
    inc i

# ---------------------------------------------------------------------------
# Report-only readings
# ---------------------------------------------------------------------------
#
# Read, logged, and deliberately never written.
#
# `Physics.autoSyncTransforms` and the two solver-iteration counts are real
# performance knobs and this mod does not touch them, because all three change
# what a physics query answers. `autoSyncTransforms = false` makes a raycast
# see transforms as they were at the last sync rather than as they are now;
# fewer solver iterations change where a body ends up. Either can change what a
# bullet hits. That is over the line this mod keeps: CPU and pixels yes,
# anything that alters what the player can hit relative to anything else, no.
#
# `Time.timeScale` is here for the opposite reason — it is not a performance
# setting at all, and reading it is how the readout can say "the numbers below
# were taken while the game was paused".

const ReportCount* = 7

proc reportAt*(i: int): Knob =
  case i
  of 0: result = Knob(section: "report", key: "autoSyncTransforms",
                      owner: OwnerPhysics, prop: "autoSyncTransforms", alt: "",
                      kind: kkBool, lo: 0.0, hi: 1.0)
  of 1: result = Knob(section: "report", key: "defaultSolverIterations",
                      owner: OwnerPhysics, prop: "defaultSolverIterations",
                      alt: "", kind: kkInt, lo: 0.0, hi: 64.0)
  of 2: result = Knob(section: "report", key: "defaultSolverVelocityIterations",
                      owner: OwnerPhysics,
                      prop: "defaultSolverVelocityIterations", alt: "",
                      kind: kkInt, lo: 0.0, hi: 64.0)
  of 3: result = Knob(section: "report", key: "timeScale",
                      owner: OwnerTime, prop: "timeScale", alt: "",
                      kind: kkFloat, lo: 0.0, hi: 100.0)
  of 4: result = Knob(section: "report", key: "fixedDeltaTime",
                      owner: OwnerTime, prop: "fixedDeltaTime", alt: "",
                      kind: kkFloat, lo: 0.0, hi: 1.0)
  of 5: result = Knob(section: "report", key: "processorCount",
                      owner: OwnerSystemInfo, prop: "processorCount", alt: "",
                      kind: kkInt, lo: 0.0, hi: 1024.0)
  of 6: result = Knob(section: "report", key: "systemMemorySize",
                      owner: OwnerSystemInfo, prop: "systemMemorySize", alt: "",
                      kind: kkInt, lo: 0.0, hi: 1048576.0)
  else: result = Knob(section: "", key: "", owner: -1, prop: "", alt: "",
                      kind: kkFloat, lo: 0.0, hi: 0.0)

proc readReport*(i: int; value: var float; why: var string): bool =
  initOwners()
  let k = reportAt(i)
  value = 0.0
  why = ""
  if k.owner < 0 or k.owner >= OwnerCount:
    why = "no such reading"
    return false
  if not resolveNow(gOwners[k.owner]):
    why = "no such type: " & ownerName(k.owner)
    return false
  result = readScalar(gOwners[k.owner], k, k.prop, value, why)

proc readGraphicsDevice*(): string =
  ## A string, so it does not fit `readReport`'s float shape. Worth its own
  ## call: a frame-rate number with no idea what GPU produced it is not a
  ## measurement anybody can compare with anything.
  initOwners()
  if not resolveNow(gOwners[OwnerSystemInfo]):
    return ""
  let r = gOwners[OwnerSystemInfo].get("graphicsDeviceName")
  if r.failed or r.isNull:
    return ""
  result = r.asText()

proc probeKnob*(i: int; value: var float; chosen: var string;
                viaAssert: var bool; why: var string): bool =
  ## Reads a knob without writing it.
  ##
  ## This is the resolve-or-refuse evidence on its own, independent of whether
  ## `config.json` enabled the knob: a mod that only learns which names exist
  ## for the settings it was asked to change knows nothing about the rest, and
  ## "which of these 23 names exist on this build" is exactly the question a
  ## first run against a new game version needs answered.
  initOwners()
  value = 0.0
  chosen = ""
  viaAssert = false
  why = ""
  if i < 0 or i >= KnobCount:
    why = "no such knob"
    return false
  let k = knobAt(i)
  if k.owner < 0 or k.owner >= OwnerCount:
    why = "no such owner"
    return false
  if not resolveNow(gOwners[k.owner]):
    why = "no such type: " & ownerName(k.owner)
    return false
  result = tryNames(gOwners[k.owner], k, value, chosen, viaAssert, why)

proc rawGet*(owner: int; prop: string; raw: var string): bool =
  ## The boxed getter's *unparsed* answer.
  ##
  ## Here for one experiment, run in the self-test and worth re-running against
  ## every new host and every new game build: what does `GameType.get` hand back
  ## for a property whose type is an enum? On this host the answer is a plain
  ## number, because `describeResult` unboxes a small value type by the width
  ## the runtime reports. It used to be `{"handle":n,"type":"System.Int32"}`,
  ## and on that answer `asFloat()` is 0.0 with `ok` true — a plausible number
  ## rather than a refusal, which is the failure shape with the longest
  ## time-to-diagnosis available.
  ##
  ## So this stays. The mod no longer *assumes* the old answer, but it still
  ## checks for it, and `readOne` falls back to an asserted binding when it sees
  ## it. A handle the experiment provokes is released here rather than kept:
  ## the whole point of the experiment is that this shape is the wrong one.
  initOwners()
  raw = ""
  if owner < 0 or owner >= OwnerCount:
    return false
  if not resolveNow(gOwners[owner]):
    return false
  let r = gOwners[owner].get(prop)
  if r.failed:
    raw = "error: " & r.error
    return false
  raw = r.raw
  if handleShaped(raw):
    dropHandle(r)
  result = true
