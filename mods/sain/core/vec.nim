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
  ## Newton's method, seeded from a halving loop.
  ##
  ## Not `math.sqrt` because the only places this is needed are the handful of
  ## spots that genuinely want a metre distance rather than a comparison, and
  ## importing a module for that is more coupling than the core wants. Every
  ## hot comparison uses `sqrDistance` and never gets here at all.
  if v <= 0.0: return 0.0
  var g = v
  if g > 1.0:
    var s = 1.0
    while s * s < v:
      s = s * 2.0
    g = s
  var i = 0
  while i < 24:
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
