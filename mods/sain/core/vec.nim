## Vectors, and the small amount of geometry the decision core needs.
##
## Pure: nothing here touches the game. That is the point of the whole `core/`
## directory — the decision model can be exercised on a laptop with no Tarkov
## anywhere near it, which is how it gets tested at all.
##
## Everything is `float` (64-bit here) rather than Unity's 32-bit floats. The
## decisions taken from these numbers are threshold comparisons at metre scale;
## the precision difference is far below anything that changes an answer, and
## keeping one float type avoids a conversion at every call site.

type
  Vec3* = object
    x*, y*, z*: float

func vec3*(x, y, z: float): Vec3 = Vec3(x: x, y: y, z: z)
func zeroVec*(): Vec3 = Vec3(x: 0.0, y: 0.0, z: 0.0)

func `+`*(a, b: Vec3): Vec3 = Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
func `-`*(a, b: Vec3): Vec3 = Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
func `*`*(a: Vec3; s: float): Vec3 = Vec3(x: a.x * s, y: a.y * s, z: a.z * s)

func dot*(a, b: Vec3): float = a.x * b.x + a.y * b.y + a.z * b.z

func sqrMagnitude*(a: Vec3): float = a.x * a.x + a.y * a.y + a.z * a.z

func sqrt0*(v: float): float =
  ## Newton's method, seeded from a power-of-two bracket.
  ##
  ## Not `math.sqrt` because the only places this is needed are the handful of
  ## spots that genuinely want a metre distance rather than a comparison, and
  ## importing a module for that is more coupling than the core wants. Every
  ## hot comparison uses `sqrDistance` and never gets here at all.
  ##
  ## **This was 24 iterations and it seeded only from above**, and both halves
  ## of that are worth recording because together they made this the most
  ## expensive function in the mod by a wide margin -- a Newton step is a
  ## floating divide, and 24 of them is roughly 160 ns a call on the machine
  ## this is measured on. `core/probe.nim` calls it about thirty times per
  ## cover sample and that alone was six microseconds.
  ##
  ## The old seed was a doubling loop entered only when `v > 1`, so a small
  ## `v` started at `g = v` -- for `v = 1e-8` that is a relative error of
  ## almost -1, the first step overshoots to 0.5, and convergence back down is
  ## *linear* for a dozen steps before the quadratic part begins. Twenty-four
  ## iterations was the honest cover for that, and the cover was the wrong fix.
  ##
  ## Bracketing from both sides makes the seed within a factor of two of the
  ## answer for every input, so the initial relative error is at most 1 and
  ## Newton's `e -> e^2 / (2(1+e))` gives 0.25, 0.025, 3e-4, 5e-8, 1e-15,
  ## 6e-31: **six steps reach the limit of a double**. Eight is what is run,
  ## which is margin rather than need, and the loops that build the seed are
  ## multiplies and compares rather than divides.
  if v <= 0.0: return 0.0
  var g = v
  if v > 1.0:
    # The smallest power of two whose square is at least `v`: g is in
    # [sqrt(v), 2*sqrt(v)).
    var s = 1.0
    while s * s < v:
      s = s * 2.0
    g = s
  elif v < 1.0:
    # The largest power of two whose square is at most `v`, doubled: g is in
    # (sqrt(v), 2*sqrt(v)]. This branch is the one that did not exist.
    var s = 1.0
    while s * s > v:
      s = s * 0.5
    g = s * 2.0
  var i = 0
  while i < 8:
    g = 0.5 * (g + v / g)
    inc i
  result = g

func magnitude*(a: Vec3): float = sqrt0(sqrMagnitude(a))

func sqrDistance*(a, b: Vec3): float =
  ## The distance test used on every hot path. Comparing squared distances
  ## against squared thresholds removes a square root per bot per enemy per
  ## tick — with 30 bots and a dozen enemies each that is a few hundred roots a
  ## frame that never happen.
  let dx = a.x - b.x
  let dy = a.y - b.y
  let dz = a.z - b.z
  result = dx * dx + dy * dy + dz * dz

func distance*(a, b: Vec3): float = sqrt0(sqrDistance(a, b))

func normalized*(a: Vec3): Vec3 =
  let m = magnitude(a)
  if m <= 0.000001: return zeroVec()
  result = Vec3(x: a.x / m, y: a.y / m, z: a.z / m)

func flat*(a: Vec3): Vec3 =
  ## Height removed. Most "is he near me" tests want ground distance: a bot two
  ## floors up is not close, but a bot two floors up is also not reachable, and
  ## conflating the two is what makes bots stare at ceilings.
  Vec3(x: a.x, y: 0.0, z: a.z)

func clampf*(v, lo, hi: float): float =
  if v < lo: lo elif v > hi: hi else: v

func lerp*(a, b, t: float): float = a + (b - a) * clampf(t, 0.0, 1.0)

func angleCos*(a, b: Vec3): float =
  ## The cosine of the angle between two directions, which is what every
  ## field-of-view test actually wants. Comparing cosines instead of degrees
  ## means no `acos` on the vision path.
  let ma = magnitude(a)
  let mb = magnitude(b)
  if ma <= 0.000001 or mb <= 0.000001: return 0.0
  result = clampf(dot(a, b) / (ma * mb), -1.0, 1.0)

func perpXZ*(a: Vec3): Vec3 =
  ## The horizontal left-hand perpendicular. Every flank, every spread-out and
  ## every "step sideways out of the doorway" is this vector and a scalar, and
  ## having it once means none of them reimplements the sign convention.
  Vec3(x: -a.z, y: 0.0, z: a.x)

func withY*(a: Vec3; y: float): Vec3 = Vec3(x: a.x, y: y, z: a.z)

func lerpVec*(a, b: Vec3; t: float): Vec3 =
  let u = clampf(t, 0.0, 1.0)
  Vec3(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u,
       z: a.z + (b.z - a.z) * u)

func flatDistance*(a, b: Vec3): float =
  ## Ground distance. Two bots on different floors of a building are far apart
  ## for the purpose of "can he hear me" and close for the purpose of "is he in
  ## my squad", and using the wrong one of those is why bots in most mods
  ## converge on stairwells.
  let dx = a.x - b.x
  let dz = a.z - b.z
  result = sqrt0(dx * dx + dz * dz)

func towards*(from1, to1: Vec3; metres: float): Vec3 =
  ## A point `metres` along the line from one place to another. Clamped at the
  ## destination rather than overshooting it.
  let d = to1 - from1
  let m = magnitude(d)
  if m <= 0.000001: return to1
  let t = clampf(metres / m, 0.0, 1.0)
  result = from1 + d * t

func away*(from1, threat: Vec3; metres: float): Vec3 =
  ## The other direction, which is not the same computation with a negative
  ## distance: the fall-back when the two points coincide has to pick *some*
  ## direction rather than returning the threat's own position.
  let d = from1 - threat
  let m = magnitude(d)
  if m <= 0.000001:
    return Vec3(x: from1.x + metres, y: from1.y, z: from1.z)
  result = from1 + d * (metres / m)
