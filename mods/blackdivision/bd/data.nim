## Reading this mod's own files, and the small amount of arithmetic the rest of
## it needs.
##
## Everything Black Division *is* — six bot templates, their configs, their
## loadouts, the locale string, the achievements — is data, and it ships beside
## the binary in `data/`. The host tells a mod where that is (`dataDir()`), and
## nimony's own `readFile` gets it off disk; there is no file service in the
## plugin API and none is needed for this.
##
## `readFile` is `{.raises.}`, so every call is wrapped. A missing data file is
## reported and the load continues without that piece — a mod that refuses to
## start because one loadout is absent takes the other five bots down with it.

import std/syncio
import aowlspt

var gSeed: uint32 = 0x9E3779B9'u32

proc seedRandom*(seed: int64) =
  ## Seeded once from the host clock. The sequence is then deterministic for the
  ## rest of the run, which is what makes a bug report about a spawn roll worth
  ## anything.
  var s = uint32(seed and 0xFFFFFFFF'i64)
  if s == 0'u32:
    s = 0x9E3779B9'u32
  gSeed = s

proc nextRandom*(): uint32 =
  ## xorshift32. Not a good generator for cryptography and an entirely good one
  ## for "does this squad spawn"; written out here rather than pulled from the
  ## stdlib because a stdlib generator's global state is initialised by a call,
  ## and a global initialised by a call in a `--app:lib` build is left zeroed.
  var x = gSeed
  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)
  gSeed = x
  result = x

proc randomBelow*(n: int): int =
  ## `0 ..< n`.
  if n <= 0:
    return 0
  result = int(nextRandom() mod uint32(n))

proc randomBetween*(lo, hi: int): int =
  ## Inclusive both ends, and tolerant of a config that has them backwards.
  var a = lo
  var b = hi
  if a > b:
    let t = a
    a = b
    b = t
  result = a + randomBelow(b - a + 1)

proc rollPercent*(chance: int): bool =
  ## True `chance` times in a hundred.
  if chance <= 0:
    return false
  if chance >= 100:
    return true
  result = randomBelow(100) < chance

proc biasedFraction*(): float =
  ## A number in 0.0 .. 1.0 weighted towards the low end, which is what upstream
  ## used to decide how far into a raid the hunt squad arrives. The bias is the
  ## point: a squad that turns up in the first third of the raid is the event,
  ## and a uniform roll puts half of them past the point where the player has
  ## already left.
  ##
  ## Three draws, smallest wins — a cheap order statistic that needs no `pow`.
  var best = 1.0
  var i = 0
  while i < 3:
    let v = float(randomBelow(1000)) / 1000.0
    if v < best:
      best = v
    inc i
  result = best

proc readTextFile*(path: string): string =
  ## The whole file, or the empty string with a line in the log.
  result = ""
  try:
    result = readFile(path)
  except:
    result = ""
  if result.len == 0:
    warn "blackdivision: could not read " & path

proc dataFile*(relative: string): string =
  ## A path under this mod's `data/` directory. Forward slashes throughout:
  ## Windows accepts them, and they keep the separator out of every string
  ## literal in the mod.
  result = dataDir() & "/" & relative

proc readData*(relative: string): string =
  result = readTextFile(dataFile(relative))
