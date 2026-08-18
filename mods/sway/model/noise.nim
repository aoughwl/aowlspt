## Band-limited 1-D value noise.
##
## Unity's PerlinNoise sampled along a line is cheap but has a visible period
## and a habit of parking near zero, which reads as a stutter rather than a
## tremor. This is a hash-based value noise with a smootherstep interpolant
## instead: continuous in the first and second derivative, so a stack of these
## layers looks like flesh rather than like a sawtooth.

import vec

proc smootherstep(t: float): float =
  t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

proc hash*(i, seed: int): float =
  ## The C# did this in `unchecked` 32-bit integer arithmetic. uint32 here
  ## wraps at the same width and produces bit-identical results, which matters:
  ## the noise is the mod's fingerprint and a different hash is a different
  ## feel, not merely a different sample.
  var h: uint32 = cast[uint32](int32(i)) * 374761393'u32 +
                  cast[uint32](int32(seed)) * 668265263'u32
  h = (h xor (h shr 13'u32)) * 1274126177'u32
  h = h xor (h shr 16'u32)
  result = (float(h) / float(high(uint32))) * 2.0 - 1.0

proc signed*(x: float; seed: int): float =
  ## Signed noise in roughly [-1, 1] at position `x` on stream `seed`.
  let i = floorToInt(x)
  let f = x - float(i)
  let t = smootherstep(f)
  let a = hash(i, seed)
  let b = hash(i + 1, seed)
  result = a + (b - a) * t

proc fractal*(x: float; seed, octaves: int; spread: float): float =
  ## Several detuned octaves summed and normalised. `spread` pushes each octave
  ## off an exact frequency multiple so the layers never realign into an
  ## audible-looking beat.
  var sum = 0.0
  var norm = 0.0
  var amp = 1.0
  var freq = 1.0
  var o = 0
  while o < octaves:
    let detune = 1.0 + spread * (hash(o * 71 + 13, seed) * 0.5)
    sum = sum + signed(x * freq * detune, seed + o * 977) * amp
    norm = norm + amp
    amp = amp * 0.55
    # 1.87 rather than 2.0: an irrational-ish ratio keeps the octaves from ever
    # sharing a period.
    freq = freq * 1.87
    inc o
  result = (if norm > 0.0: sum / norm else: 0.0)
