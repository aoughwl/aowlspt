## A deterministic pseudo-random source.
##
## Bot AI wants jitter — reaction times, aim wander, how long a bot hesitates
## before pushing — and it wants that jitter to be *reproducible*, because a
## decision core that cannot be replayed cannot be tested. `std/random` would
## give neither reproducibility across a restart nor a cheap per-bot stream.
##
## This is xorshift64*: one multiply and three shifts, no allocation, and one
## `Rng` per bot so two bots never contend or correlate.

type
  Rng* = object
    state*: uint64

func newRng*(seed: uint64): Rng =
  ## Zero is a fixed point of xorshift, so it is folded away rather than left
  ## to produce a bot whose every "random" answer is the same number.
  Rng(state: (if seed == 0'u64: 0x9E3779B97F4A7C15'u64 else: seed))

func nextU64*(r: var Rng): uint64 =
  var x = r.state
  x = x xor (x shr 12)
  x = x xor (x shl 25)
  x = x xor (x shr 27)
  r.state = x
  result = x * 0x2545F4914F6CDD1D'u64

func nextFloat*(r: var Rng): float =
  ## Uniform in [0, 1). The top 24 bits only: the low bits of an xorshift are
  ## the weakest and nothing here needs 53 bits of mantissa.
  let v = nextU64(r) shr 40
  result = float(int(v)) / 16777216.0

func rangeF*(r: var Rng; lo, hi: float): float =
  if hi <= lo: return lo
  result = lo + nextFloat(r) * (hi - lo)

func chance*(r: var Rng; probability: float): bool =
  if probability <= 0.0: return false
  if probability >= 1.0: return true
  result = nextFloat(r) < probability

func hashSeed*(s: string; salt: uint64): uint64 =
  ## FNV-1a over a bot's profile id, so a given bot keeps its personality quirks
  ## for the whole raid without anything being stored per bot.
  var h = 0xCBF29CE484222325'u64 xor salt
  for ch in s:
    h = h xor uint64(ord(ch))
    h = h * 0x100000001B3'u64
  result = h
