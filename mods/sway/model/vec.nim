## Three numbers and the scalar helpers the model needs.
##
## The C# this is ported from leaned on UnityEngine — `Vector3`, `Mathf.Lerp`,
## `Mathf.Clamp01`. None of that exists here and none of it should: the whole
## point of keeping the model in its own module is that it can be ticked with
## no game attached, and a dependency on the engine would put the game back in
## the middle of it.
##
## The axes are (pitch, yaw, roll) in degrees throughout, in that order, which
## is the order BSG's rotation springs take.

import std/math

type
  Vec3* = object
    x*, y*, z*: float

const Zero3* = Vec3(x: 0.0, y: 0.0, z: 0.0)

proc vec3*(x, y, z: float): Vec3 = Vec3(x: x, y: y, z: z)

proc `+`*(a, b: Vec3): Vec3 = Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
proc `-`*(a, b: Vec3): Vec3 = Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
proc `*`*(a: Vec3; s: float): Vec3 = Vec3(x: a.x * s, y: a.y * s, z: a.z * s)

proc sqrMagnitude*(a: Vec3): float = a.x * a.x + a.y * a.y + a.z * a.z
proc magnitude*(a: Vec3): float = sqrt(sqrMagnitude(a))

proc clampMagnitude*(a: Vec3; limit: float): Vec3 =
  ## Shortens without rotating, so a clamped deflection still points where the
  ## unclamped one did. Clamping each axis separately would bend the direction
  ## towards the nearest corner of the cube, which is visible as the weapon
  ## drifting diagonally on a hard flick.
  let m2 = sqrMagnitude(a)
  if limit <= 0.0:
    return Zero3
  if m2 <= limit * limit:
    return a
  let m = sqrt(m2)
  if m <= 0.0:
    return Zero3
  result = a * (limit / m)

# ---------------------------------------------------------------------------
# Scalars
# ---------------------------------------------------------------------------

proc fmax*(a, b: float): float = (if a > b: a else: b)
proc fmin*(a, b: float): float = (if a < b: a else: b)

proc clampf*(v, lo, hi: float): float =
  if v < lo: lo elif v > hi: hi else: v

proc clamp01*(v: float): float = clampf(v, 0.0, 1.0)

proc lerpf*(a, b, t: float): float = a + (b - a) * clamp01(t)

proc moveTowards*(current, target, maxDelta: float): float =
  ## Linear approach at a fixed rate, unlike `lerpf`'s exponential one. Holding
  ## fatigue builds at so much per second whether it is near its ceiling or not,
  ## which is what a rate is; a lerp would make the last third take forever.
  let d = target - current
  if d > maxDelta: return current + maxDelta
  if d < -maxDelta: return current - maxDelta
  result = target

proc frac*(v: float): float = v - floor(v)

proc deltaAngle*(a, b: float): float =
  ## Signed shortest way round from `a` to `b`, in degrees. Turning past 359
  ## degrees to 1 is a two degree turn, not a 358 degree one, and the raw
  ## subtraction would hand the inertia oscillator a spike the size of a full
  ## revolution every time the player crossed north.
  var d = frac((b - a) / 360.0) * 360.0
  if d > 180.0: d = d - 360.0
  if d < -180.0: d = d + 360.0
  result = d

proc ceilToInt*(v: float): int = int(ceil(v))
proc floorToInt*(v: float): int = int(floor(v))

proc clampi*(v, lo, hi: int): int =
  if v < lo: lo elif v > hi: hi else: v

proc fabs*(v: float): float = (if v < 0.0: -v else: v)

proc isFinite*(v: float): bool =
  ## False for a NaN and for either infinity. `v != v` catches the NaN; the
  ## magnitude test catches the infinities without naming a constant the
  ## platform might not agree with.
  if v != v:
    return false
  result = v > -1.0e300 and v < 1.0e300

proc isFinite*(a: Vec3): bool =
  isFinite(a.x) and isFinite(a.y) and isFinite(a.z)
