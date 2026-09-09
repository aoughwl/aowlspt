## A pseudo-random number generator, written out rather than imported.
##
## There is deliberately no RNG anywhere else in this emulator — `emu/ids`
## explains why: an id that came out of a global source of entropy cannot be
## looked up again when a bug report names it. Loot is the one thing that
## genuinely has to vary, and the way to keep both properties is to make the
## variation *explicit*: a generator with its whole state in a value the caller
## holds, seeded from the raid id.
##
## So "the loot on raid 65f1a2..." is reproducible. Given the same database and
## the same raid id, `emu/loot` produces the same floor, byte for byte,
## including the item ids — which is what makes a screenshot of a broken
## container something that can be regenerated rather than guessed at.
##
## xorshift64* is what is implemented. It is four instructions, its period is
## 2^64-1, and it passes the only test that matters here: the low bits are not
## a counter. A cryptographic generator would be the wrong tool — this output
## decides where a bandage lies, and predicting it is not an attack.
##
## The one trap it has is a **zero state, which is a fixed point**: xorshift on
## zero returns zero forever, so a raid id that happened to hash to zero would
## produce a map with every roll identical. `seededRng` cannot return one.

type
  Rng* = object
    ## The whole generator. A value, not a global: two callers with the same
    ## seed do not interfere, and a caller that wants to replay a sequence keeps
    ## a copy of this and starts again.
    state*: uint64

const
  FnvOffset = 0xcbf29ce484222325'u64
  FnvPrime = 0x100000001b3'u64
  Mix = 0x2545f4914f6cdd1d'u64

proc hashText*(s: string): uint64 =
  ## FNV-1a. Used to turn a raid id into a seed, so the seed is derived from the
  ## text of the id rather than from a parse of it — a raid id is a MongoId
  ## today and the derivation should not care if it stops being one.
  result = FnvOffset
  for ch in s:
    result = result xor uint64(uint8(ord(ch)))
    result = result * FnvPrime

proc seededRng*(seed: string): Rng =
  ## A generator seeded from arbitrary text. Never returns the zero state.
  var h = hashText(seed)
  if h == 0'u64:
    h = FnvOffset
  result = Rng(state: h)

proc seededRng*(seed: uint64): Rng =
  var h = seed
  if h == 0'u64:
    h = FnvOffset
  result = Rng(state: h)

proc nextU64*(r: var Rng): uint64 =
  ## xorshift64*, advanced once.
  var x = r.state
  x = x xor (x shr 12'u64)
  x = x xor (x shl 25'u64)
  x = x xor (x shr 27'u64)
  r.state = x
  result = x * Mix

proc nextInt*(r: var Rng; bound: int): int =
  ## A value in `[0, bound)`. Zero for a bound that is not positive, because
  ## every caller here is indexing a list and an empty list is a real case.
  ##
  ## The modulo bias is left in. With a 64-bit value and bounds in the hundreds
  ## the bias is on the order of 2^-55, and rejection sampling here would buy
  ## nothing except a loop with no upper limit on its running time.
  if bound <= 1:
    return 0
  result = int(nextU64(r) mod uint64(bound))

proc nextFloat*(r: var Rng): float =
  ## A value in `[0, 1)`, from the top 53 bits — the low bits of any xorshift
  ## are its weakest, and taking the mantissa off the top costs nothing.
  result = float(nextU64(r) shr 11'u64) * (1.0 / 9007199254740992.0)

proc chance*(r: var Rng; probability: float): bool =
  ## One roll against a probability. Clamped rather than trusted: a database row
  ## with a probability of 1.4 means "always", not "always plus a wrapped
  ## comparison", and one of -0.1 means never.
  if probability <= 0.0:
    return false
  if probability >= 1.0:
    return true
  result = nextFloat(r) < probability

proc pickWeighted*(r: var Rng; weights: seq[float]): int =
  ## An index chosen in proportion to `weights`. Returns -1 when there is
  ## nothing to choose from or every weight is zero — a caller must be able to
  ## tell "the pool is empty" from "it picked the first one", because spawning
  ## element zero of an empty distribution is how a map ends up carpeted in
  ## whatever item happens to sort first.
  var total = 0.0
  for w in weights:
    if w > 0.0:
      total = total + w
  if total <= 0.0:
    return -1
  let target = nextFloat(r) * total
  var acc = 0.0
  for i in 0 ..< weights.len:
    if weights[i] <= 0.0:
      continue
    acc = acc + weights[i]
    if target < acc:
      return i
  # Floating-point accumulation can land a hair past the last boundary.
  var last = -1
  for i in 0 ..< weights.len:
    if weights[i] > 0.0:
      last = i
  result = last

const HexDigits = "0123456789abcdef"

proc mongoId*(r: var Rng): string =
  ## A 24-character hex id drawn from the generator.
  ##
  ## Not `emu/ids.newId`, and that is the point: `newId` counts from a clock, so
  ## the same raid replayed would name the same rifle differently. An id that
  ## comes out of the seeded stream makes the whole loot document a function of
  ## the raid id alone. Collision with a profile's own ids is not a concern —
  ## these ids only ever live inside one raid's loot list.
  result = ""
  var i = 0
  while i < 3:
    let v = nextU64(r)
    var k = 0
    while k < 8:
      result.add HexDigits[int((v shr uint64(k * 4)) and 0xF'u64)]
      inc k
    inc i
