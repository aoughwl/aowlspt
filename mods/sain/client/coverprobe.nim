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
import drivecalls

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

  # `HitBufferWords = 16` (128 bytes of scratch for the `out NavMeshHit`) is
  # gone with the boxed path. The buffer is now an arena cell of exactly 36
  # bytes -- `UnityEngine.AI.NavMeshHit`'s MEASURED `native_size` out of
  # `Il2CppMetadataRegistration.typeDefinitionsSizes` -- staged by
  # `drivecalls.navSample`. See `NavMeshHitBytes` there for the measurement and
  # for the control reading that validates it.

var gRayWhy = "not attempted"
var gNavWhy = "not attempted"
var gTried = false

## Counters, for the state line. `gRays` is the number that has to stay
## proportional to *time* rather than to bot count -- see `client/driver.nim`
## for the budget that enforces it.
var gRays = 0
var gNavSamples = 0
var gSamples = 0
var gSampleNs = 0'i64
var gPointsSeen = 0

proc raycastReady*(): bool = canRaycast()
proc navMeshReady*(): bool = canSample()

proc probeReady*(): bool =
  ## The sensor exists when the *ray* exists. The navmesh is a filter on top of
  ## it, and a build without one gets cover points chosen on the rays alone --
  ## which is worse and is not nothing.
  result = canRaycast()

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

# `bindRaycast` and `bindNavMesh` USED TO BE HERE, 137 lines of them, and they
# are deleted rather than left unreferenced. Both resolved a class and a
# method BY NAME at run time, checked the returned signature, and refused
# when it did not classify. The checking was careful and it protected
# nothing: on this build `il2cpp_class_from_name` and
# `il2cpp_class_get_method_from_name` are TOKEN-GATED exports that return a
# uniform random non-zero uint64 on a token mismatch, so the handle being
# inspected was already a random number and every check ran on it happily.
# A verification that cannot fail is the bug (CLAUDE.md 9b).
#
# Dead code that calls a fatal export is not inert -- it is one edit away from
# being called again. The replacement is in `client/drivecalls.nim`, which
# resolves nothing at run time at all.

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
  # NOTHING HERE RESOLVES A NAME ANY MORE, and that is the whole change.
  #
  # `bindRaycast` / `bindNavMesh` above went through
  # `il2cpp_class_from_name` + `il2cpp_class_get_method_from_name`, which on
  # this build are TOKEN-GATED exports: called the stock way they do not fail,
  # they return a uniform random non-zero uint64. Fact #144 named this the
  # place the client dies -- and that fact should be read with the caveat that
  # the host log LOSES about six statements of tail on a hard death, so "died
  # at bindProbe 1/2" names the last line LOGGED, not necessarily the last line
  # EXECUTED. Either way the by-name route is the wrong route and it is gone.
  #
  # `client/drivecalls.nim` verifies both entry points at their offline-
  # resolved static RVA against the startup prologue snapshot. It reads code
  # pages; it patches nothing; it cannot return a random handle because it
  # never asks for one.
  info "sain: bindProbe -- byte-verifying Physics::Raycast @0x5328830 and " &
       "NavMesh::SamplePosition @0x5238930 at their offline RVAs; no name is " &
       "resolved at run time"
  verifyAll()
  gRayWhy = (if canRaycast():
               "RVA 0x5328830, 1 owner, prologue verified against the startup " &
               "snapshot -- bool Raycast(Vector3, Vector3, float)"
             else:
               "refused -- " & driveWhy())
  gNavWhy = (if canSample():
               "RVA 0x5238930, 1 owner, prologue verified; the out buffer is " &
               "36 bytes, the MEASURED native_size of UnityEngine.AI.NavMeshHit"
             else:
               "refused -- " & driveWhy())
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
  ## THREE OUTCOMES, NOT TWO. `drivecalls.raycastHits` answers through an `ok`
  ## flag as well as a bool, because "the ray reached nothing" and "this sensor
  ## could not answer" are different facts and the old code flattened them.
  ## Unanswered is reported here as **false** -- "not cover" -- which leaves
  ## the candidate set empty and the cover decisions exactly as unreachable as
  ## on a build with no sensor. The other direction invents cover everywhere,
  ## which is a bot walking confidently into open ground.
  result = false
  if r.maxDistance <= 0.0 or not canRaycast():
    return
  gRays = gRays + 1
  var ok = false
  let hit = raycastHits(r.origin.x, r.origin.y, r.origin.z,
                        r.direction.x, r.direction.y, r.direction.z,
                        r.maxDistance, ok)
  if not ok:
    return
  result = hit

proc standableAt(p: Vec3): bool =
  ## Whether the navmesh has ground within `NavSampleRadius` of a point.
  ##
  ## True when the sensor could not answer, because a filter that is absent
  ## must not REJECT: a build where `SamplePosition` refused gets its
  ## candidates filtered by the rays alone. That is the opposite default from
  ## `castRay` and the asymmetry is the point -- each one defaults to the
  ## answer that makes the sensor inert rather than the answer that makes it
  ## confidently wrong.
  result = true
  if not canSample():
    return
  gNavSamples = gNavSamples + 1
  var hx = 0.0
  var hy = 0.0
  var hz = 0.0
  var hd = 0.0
  var ok = false
  let found = navSample(p.x, p.y, p.z, NavSampleRadius, int32(NavAllAreas),
                        hx, hy, hz, hd, ok)
  if not ok:
    return
  result = found

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
  if not canRaycast() or not p.valid:
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
