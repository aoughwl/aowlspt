## bm/rng — splitmix64. Seeded, deterministic, no global state.
##
## `std/random` is forbidden by the contract and would be wrong anyway: world
## generation must be reproducible from a seed alone (DESIGN §9.1), so every
## consumer carries its own `Rng` and nothing reads a hidden global.
##
## DECISION: `shuffle` is Fisher-Yates walking DOWNWARD with `nextInt(0, i)`.
## The direction matters only in that it must never change again -- it is part
## of what "the same seed gives the same world" means.

import util

type
  Rng* = object
    state*: uint64

proc initRng*(seed: uint64): Rng =
  result = Rng(state: seed)

proc next*(r: var Rng): uint64 =
  r.state = r.state + 0x9e3779b97f4a7c15'u64
  var z = r.state
  z = (z xor (z shr 30'u64)) * 0xbf58476d1ce4e5b9'u64
  z = (z xor (z shr 27'u64)) * 0x94d049bb133111eb'u64
  result = z xor (z shr 31'u64)

proc nextInt*(r: var Rng; lo, hi: int): int =
  ## Inclusive. `hi < lo` returns `lo` rather than dividing by zero -- a caller
  ## that passed an empty range gets a defined answer, not a torn worker.
  if hi <= lo: return lo
  let span = uint64(hi - lo + 1)
  result = lo + int(next(r) mod span)

proc nextFloat*(r: var Rng): float =
  ## [0,1). 53 bits, so it is exactly representable and never rounds to 1.0.
  result = float(int64(next(r) shr 11'u64)) / 9007199254740992.0

proc pick*(r: var Rng; items: seq[string]): string =
  if items.len == 0: return ""
  result = items[nextInt(r, 0, items.len - 1)]

proc shuffle*(r: var Rng; items: var seq[string]) =
  var i = items.len - 1
  while i > 0:
    let j = nextInt(r, 0, i)
    let t = items[i]
    items[i] = items[j]
    items[j] = t
    i = i - 1

proc seedFromText*(s: string): uint64 =
  result = fnv1a64(s)
