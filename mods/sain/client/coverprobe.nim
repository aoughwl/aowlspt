## The cover sensor: two engine entry points, resolved by name, refused with a
## reason.
##
## This is the only file in the mod that calls **Unity** rather than EFT, and
## it is the only file whose calls are illegal from the host's own thread. Both
## facts shape everything below.
##
## ## What is attempted, and why only these two
##
## | | |
## |---|---|
## | `UnityEngine.Physics::Raycast(Vector3, Vector3, System.Single)` | is a candidate breaking the enemy's line? Two of these per candidate; see `core/probe.nim` for what the second one asks. |
## | `UnityEngine.AI.NavMesh::SamplePosition(Vector3, out NavMeshHit, System.Single, System.Int32)` | is there ground a bot can stand on there? Optional: a refusal here loses the filter, not the sensor. |
##
## `Physics.OverlapSphere` -- what SAIN's `CoverFinder` actually uses -- is not
## attempted. It returns a managed array, which is an allocation per sample and
## a second guessed shape, and the two rays answer the same question. A
## `NavMesh.CalculatePath` for `EnemyView.pathDistance` is not attempted
## either: it needs a `NavMeshPath` *object*, which means constructing a
## managed instance from here, and that is a different kind of bet from calling
## a static with value arguments. `README.md` still lists path distance as
## blocked, and this file is why.
##
## ## Every name is checked before it is called
##
## `il2cpp_class_get_method_from_name` matches on name and arity and hands back
## the first overload it finds. `UnityEngine.Physics` has three
## three-argument `Raycast` overloads and only one of them is the one meant, so
## a resolution that stopped at "found something with the right arity" would be
## calling `Raycast(Ray, out RaycastHit, float)` with a `Vector3` in the first
## slot -- which does not crash. It reads adjacent stack as a ray and answers a
## plausible bool.
##
## So the declared parameter types are read out of the runtime's own metadata
## and compared, exactly. A mismatch **refuses by name, with the signature the
## runtime reported**, and the log carries it. That is the same discipline
## `armAimHook` applies to a detour, applied to a call. What it costs is that a
## build which spells the overload differently gets no cover sensor rather than
## a wrong one, and that is the trade this mod makes everywhere else too.
##
## The C API reachable from here cannot *enumerate* overloads -- it matches by
## arity -- so "the first three-argument `Raycast` is not the one we want" is a
## refusal rather than a search. Stated because it is a real limit: on a build
## where the overload order differs, this sensor is off and says so, and
## nothing here would silently pick the next one.
##
## ## Nothing is read out of a hit
##
## `NavMeshHit` is a value struct and the `out` parameter is a buffer this file
## hands over. It is sized by asking the runtime how big the struct is, zeroed,
## and **never read** -- only the method's `bool` return is used. Reading
## `NavMeshHit.position` would mean a field offset inside a value type, which
## is the one number nothing here can check, and it is the same refusal
## `sain.nim` makes about `DamageInfo`. The consequence is small and stated: a
## candidate is accepted where it was proposed rather than snapped to the
## nearest navmesh point.
##
## ## The thread
##
## `runSample` is called from an `onMainThread` callback and from nowhere else.
## It touches no bot table, allocates nothing, logs nothing and returns nothing
## but bools written into an array the poster owns. `client/mainthread.nim` is
## the gate that decides whether a sample is posted at all: the host reports
## whether its per-frame drain has actually fired, and until it has, this file
## is never entered.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import ".." / core / vec
import ".." / core / probe
import live

const
  RaycastOwner = "UnityEngine.Physics"
  RaycastMember = "Raycast"
  NavMeshOwner = "UnityEngine.AI.NavMesh"
  NavMeshMember = "SamplePosition"
  NavMeshHitType = "UnityEngine.AI.NavMeshHit"

  NavSampleRadius = 2.0
    ## How far from a candidate the navmesh may be and still count. Two metres:
    ## wide enough that a candidate a little inside a wall still finds the
    ## floor beside it, narrow enough that a candidate in the middle of a
    ## building's footprint does not borrow the pavement outside.
  NavAllAreas = -1'i32
    ## `NavMesh.AllAreas`. A constant of Unity's, not a guess about EFT.

  HitBufferWords = 16
    ## 128 bytes of scratch for the `out NavMeshHit`. The runtime is asked how
    ## big the struct really is and the binding refuses if the answer does not
    ## fit here, so this number is a ceiling rather than an assumption.

var gRayM: Il2CppMethod = cast[Il2CppMethod](0)
var gRayWhy = "not attempted"
var gNavM: Il2CppMethod = cast[Il2CppMethod](0)
var gNavWhy = "not attempted"
var gNavHitBytes = 0
var gTried = false

## Counters, for the state line. `gRays` is the number that has to stay
## proportional to *time* rather than to bot count -- see `client/driver.nim`
## for the budget that enforces it.
var gRays = 0
var gNavSamples = 0
var gSamples = 0
var gSampleNs = 0'i64
var gPointsSeen = 0

proc raycastReady*(): bool = gRayM != nil
proc navMeshReady*(): bool = gNavM != nil

proc probeReady*(): bool =
  ## The sensor exists when the *ray* exists. The navmesh is a filter on top of
  ## it, and a build without one gets cover points chosen on the rays alone --
  ## which is worse and is not nothing.
  result = gRayM != nil

proc raycastWhy*(): string = gRayWhy
proc navMeshWhy*(): string = gNavWhy
proc raysCast*(): int = gRays
proc navSamples*(): int = gNavSamples
proc samplesTaken*(): int = gSamples
proc pointsProposed*(): int = gPointsSeen

proc sampleCostNs*(): int64 =
  ## What one sample cost on the game's own thread, averaged. -1 when none has
  ## been taken -- which is the answer against any runtime that does not carry
  ## these two names, and is the answer this mod has today.
  if gSamples <= 0: return -1'i64
  result = gSampleNs div int64(gSamples)

proc bindRaycast() =
  # THE REFUSAL COMES FIRST, and it is the reason this file exists in its
  # current shape. `signatureOf` below is `findClass` + `findMethod` +
  # dereference, and on this build that sequence is what killed the client --
  # MEASURED: the last line the mod ever logged was this function's own
  # breadcrumb. See `client/live.nim` and fact #35.
  #
  # The offline route is already measured and is written down here so the next
  # agent does not re-derive it. From
  # `tools/il2cpp_resolve.py <GameAssembly.dll> <metadata.dec> type 29163
  # --shared` (`UnityEngine.Physics`, image UnityEngine.PhysicsModule.dll):
  #
  #   bool Raycast(Vector3 origin, Vector3 direction, float maxDistance)
  #     rid=45  arity=3  RVA=0x5328830   NOT [shared]
  #     prologue 48 89 5C 24 08 57 48 83 EC 70 80 3D 51 D9 DA 01
  #
  # and it disambiguates what this file's own header warns cannot be
  # disambiguated through the C API: there are THREE arity-3 `Raycast`
  # overloads (rid 45, 50, 52) and the runtime hands back whichever it meets
  # first.
  #
  # It is NOT wired up, deliberately. Two things are missing and neither is a
  # detail: a mod has no byte-verified call-by-RVA facility (nothing in
  # `aowlspt/il2cpp`, `aowlspt/fast` or `aowlspt/game` takes an RVA), and the
  # ARGUMENT CONVENTION for two by-value `Vector3`s into an il2cpp static is
  # unverified -- this file's own header already says `aowlspt/fast` refuses
  # that shape. Asserting it would be a guess that returns a plausible bool,
  # which is the failure this mod is arranged against. So the sensor declines.
  if reflectionRefused():
    gRayWhy = "refused: " & ReflectionRefusal &
              " The cover sensor is OFF, so there are no cover points and " &
              "the cover decisions stay unreachable -- bots fight, search " &
              "and flank without taking cover. The offline RVA for the " &
              "right overload is measured and recorded in the source " &
              "(0x5328830, not shared); wiring it up needs a byte-verified " &
              "call-by-RVA path for mods and a verified argument convention " &
              "for two by-value Vector3s, and this mod will not assert " &
              "either one"
    return
  var params: seq[string] = @[]
  var ret = ""
  if not signatureOf(RaycastOwner, RaycastMember, 3, params, ret):
    gRayWhy = "refused: " & RaycastOwner & "::" & RaycastMember &
              " has no three-argument form on this build, so there are no " &
              "cover points and the cover decisions stay unreachable"
    return
  if params.len != 3 or params[0] != "UnityEngine.Vector3" or
     params[1] != "UnityEngine.Vector3" or params[2] != "System.Single" or
     ret != "System.Boolean":
    # Named rather than attempted. `Physics` carries three three-argument
    # `Raycast` overloads and the runtime hands back whichever it finds first;
    # calling the wrong one with a Vector3 where it wants a Ray answers a
    # plausible bool rather than failing.
    gRayWhy = "refused: the three-argument " & RaycastOwner & "::" &
              RaycastMember & " on this build is " & describeSig(params, ret) &
              ", and this reads (Vector3 origin, Vector3 direction, float " &
              "maxDistance) -> bool. The overload order differs here, and " &
              "picking the next one would be guessing"
    return
  let m = staticMethodOf(RaycastOwner, RaycastMember, 3)
  if m == nil:
    gRayWhy = "refused: " & RaycastOwner & "::" & RaycastMember &
              " resolved with the right signature but is not static, which " &
              "is not the method this meant"
    return
  gRayM = m
  gRayWhy = "boxed: " & RaycastOwner & "::" & RaycastMember & " " &
            describeSig(params, ret) &
            " through il2cpp_runtime_invoke -- two Vector3 arguments by " &
            "pointer is a shape aowlspt/fast refuses and this mod does not " &
            "assert a convention for a static"

proc bindNavMesh() =
  # Same refusal, same reason, and this one has NEVER RUN on this client: the
  # process died in `bindRaycast` above before reaching it. Its offline route
  # is measured too, from `type 30426 --shared` (`UnityEngine.AI.NavMesh`,
  # image UnityEngine.AIModule.dll):
  #
  #   bool SamplePosition(Vector3, NavMeshHit, float, int)
  #     rid=48  arity=4  RVA=0x5238930   NOT [shared]
  #
  # It additionally needs `payloadSizeOf(NavMeshHit)`, which is `findClass` +
  # `classInstanceSize` -- the same dead path -- so an RVA alone would not be
  # enough here even once the call path exists.
  if reflectionRefused():
    gNavWhy = "refused: " & ReflectionRefusal &
              " The navmesh filter is OFF. It is a filter on a sensor that " &
              "is itself off, so nothing further is lost today. Offline RVA " &
              "0x5238930 (not shared) is recorded in the source, but sizing " &
              "the `out NavMeshHit` buffer needs the same dead by-name path, " &
              "so this one needs more than an RVA"
    return
  var params: seq[string] = @[]
  var ret = ""
  if not signatureOf(NavMeshOwner, NavMeshMember, 4, params, ret):
    gNavWhy = "refused: " & NavMeshOwner & "::" & NavMeshMember &
              " has no four-argument form on this build; candidates are " &
              "accepted on the rays alone, so a bot may be sent to a place " &
              "it cannot stand"
    return
  var hitOk = false
  if params.len == 4:
    # The `out` parameter's declared name may or may not carry a trailing `&`
    # depending on how the runtime renders a byref, so the test is containment
    # rather than equality -- and it is still a test rather than a position.
    let p1 = params[1]
    var k = 0
    while k + 10 <= p1.len:
      if p1.substr(k, k + 9) == "NavMeshHit":
        hitOk = true
        break
      inc k
  if params.len != 4 or params[0] != "UnityEngine.Vector3" or not hitOk or
     params[2] != "System.Single" or params[3] != "System.Int32" or
     ret != "System.Boolean":
    gNavWhy = "refused: " & NavMeshOwner & "::" & NavMeshMember &
              " on this build is " & describeSig(params, ret) & ", and this " &
              "reads (Vector3, out NavMeshHit, float, int) -> bool"
    return
  let sz = payloadSizeOf(NavMeshHitType)
  if sz <= 0 or sz > HitBufferWords * 8:
    gNavWhy = "refused: the runtime reports " & NavMeshHitType & " as " &
              $sz & " bytes, which is not a size this can hand over safely " &
              "(the scratch buffer is " & $(HitBufferWords * 8) & ")"
    return
  let m = staticMethodOf(NavMeshOwner, NavMeshMember, 4)
  if m == nil:
    gNavWhy = "refused: " & NavMeshOwner & "::" & NavMeshMember &
              " is not static on this build"
    return
  gNavM = m
  gNavHitBytes = sz
  gNavWhy = "boxed: " & NavMeshOwner & "::" & NavMeshMember & " " &
            describeSig(params, ret) & " through il2cpp_runtime_invoke; the " &
            "hit is a " & $sz & "-byte buffer this mod hands over and never " &
            "reads, so nothing depends on its layout"

proc bindProbe*() =
  ## Resolve both, once, on the first tick the runtime is up. Never from
  ## `onLoad`: the game's assemblies are not loaded there and both would
  ## correctly refuse for the wrong reason.
  if gTried:
    return
  gTried = true
  if not liveReady():
    gRayWhy = "refused: no IL2CPP runtime is bound in this process"
    gNavWhy = gRayWhy
    return
  # Named separately: these two resolve UnityEngine statics rather than EFT
  # members, so a fault in one of them is a different bug from a fault in
  # `bindAll`, and a single "bindProbe" line could not say which.
  info "sain: bindProbe 1/2 -- UnityEngine.Physics::Raycast"
  bindRaycast()
  info "sain: bindProbe 2/2 -- UnityEngine.AI.NavMesh::SamplePosition"
  bindNavMesh()
  info "sain: bindProbe complete"

proc probeState*(): string =
  ## One line each, for `report()`. Both halves always, because "the cover
  ## sensor is on" without saying whether the navmesh filter came with it is
  ## the kind of half-statement this mod's log exists to avoid.
  result = "cover sensor -- ray: " & gRayWhy & " | navmesh: " & gNavWhy

# ---------------------------------------------------------------------------
# The sample itself. Unity's thread, and nothing else's.
# ---------------------------------------------------------------------------

proc castRay(r: ProbeRay): bool =
  ## True when something stopped the ray inside `maxDistance`.
  ##
  ## A refused binding answers **false**, and that direction is deliberate:
  ## false means "nothing in the way", which `core/probe.heightFrom` reads as
  ## "this candidate is not cover", which leaves the set empty and the cover
  ## decisions exactly as unreachable as they are on a build with no sensor at
  ## all. The other direction would invent cover everywhere.
  result = false
  if gRayM == nil or r.maxDistance <= 0.0:
    return
  var origin: array[4, float32] = [float32(r.origin.x), float32(r.origin.y),
                                   float32(r.origin.z), 0.0'f32]
  var dir: array[4, float32] = [float32(r.direction.x),
                                float32(r.direction.y),
                                float32(r.direction.z), 0.0'f32]
  var maxd: float32 = float32(r.maxDistance)
  # The IL2CPP invoke convention, which is Mono's: a value-type slot points at
  # the raw value and a reference slot *is* the pointer. Three value types
  # here, so three addresses of locals that outlive the call.
  var argv: array[3, Il2CppPtr] = [cast[Il2CppPtr](addr origin[0]),
                                   cast[Il2CppPtr](addr dir[0]),
                                   cast[Il2CppPtr](addr maxd)]
  gRays = gRays + 1
  result = unboxBool(invokeStatic(gRayM, cast[Il2CppPtr](addr argv[0])))

proc standableAt(p: Vec3): bool =
  ## Whether the navmesh has ground within `NavSampleRadius` of a point.
  ##
  ## True when the binding refused, because a sensor that is absent must not
  ## reject: a build with no `NavMesh` gets its candidates filtered by the rays
  ## alone.
  result = true
  if gNavM == nil:
    return
  var at: array[4, float32] = [float32(p.x), float32(p.y), float32(p.z),
                               0.0'f32]
  var hit: array[HitBufferWords, int64] = [
    0'i64, 0'i64, 0'i64, 0'i64, 0'i64, 0'i64, 0'i64, 0'i64,
    0'i64, 0'i64, 0'i64, 0'i64, 0'i64, 0'i64, 0'i64, 0'i64]
  var radius: float32 = float32(NavSampleRadius)
  var mask: int32 = NavAllAreas
  var argv: array[4, Il2CppPtr] = [cast[Il2CppPtr](addr at[0]),
                                   cast[Il2CppPtr](addr hit[0]),
                                   cast[Il2CppPtr](addr radius),
                                   cast[Il2CppPtr](addr mask)]
  gNavSamples = gNavSamples + 1
  result = unboxBool(invokeStatic(gNavM, cast[Il2CppPtr](addr argv[0])))

proc runSample*(p: ProbePlan; a: var ProbeAnswers) =
  ## One sample, start to finish, on Unity's thread.
  ##
  ## Two rays and at most one navmesh sample per candidate, and the order is
  ## the cheap test first: a candidate whose chest ray is clear is not cover
  ## whatever the navmesh says, so its stand ray and its navmesh sample are
  ## never taken. In an open field that turns a 24-call sample into 8.
  ##
  ## Nothing here allocates, nothing here logs, nothing here touches the bot
  ## table. The counters are plain increments on this thread's own globals and
  ## are read for a log line rather than for a decision.
  if gRayM == nil or not p.valid:
    return
  let t0 = perfCounter()
  var i = 0
  while i < p.count:
    let c = p.candidates[i]
    var ans = zeroAnswer()
    ans.chestBlocked = castRay(c.chest)
    if ans.chestBlocked:
      ans.standBlocked = castRay(c.stand)
      ans.standable = standableAt(c.position)
      gPointsSeen = gPointsSeen + 1
    a[i] = ans
    inc i
  gSampleNs = gSampleNs + nanosBetween(t0, perfCounter())
  gSamples = gSamples + 1
