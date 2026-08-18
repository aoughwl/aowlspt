## MongoIds, and the small amount of arithmetic the rest of the emulator needs.
##
## The client parses almost every id it is given as a 24-character hex MongoId
## and rejects anything else, so an id is not a place to be creative. A real
## MongoId is four bytes of timestamp, five of machine/process and three of
## counter; what matters here is only that it is 24 hex characters and that two
## calls never collide.
##
## There is no random number generator in play. The timestamp is the host clock
## and the tail is a counter, which makes ids reproducible within a run — and
## that is a feature when a bug report says "the stash item with id X".

import aowlspt

var gCounter = 0
var gSeed = 0'i64

const HexDigits = "0123456789abcdef"

proc hex*(value: int64; width: int): string =
  ## `value` as lower-case hex, right-aligned in `width` digits, truncated from
  ## the left if it does not fit -- an id must be exactly the width the client
  ## expects, so overflowing is not something to report, it is something to cut.
  result = ""
  var v = value
  if v < 0: v = -v
  var i = 0
  var digits = ""
  while i < width:
    digits.add HexDigits[int(v and 0xF'i64)]
    v = v shr 4
    inc i
  # `digits` came out least-significant first.
  var k = digits.len - 1
  while k >= 0:
    result.add digits[k]
    dec k

proc seedIds*(seed: int64) =
  ## Called once at load with the host clock, so two runs of the server do not
  ## hand out the same ids to different objects.
  gSeed = seed
  gCounter = 0

proc newId*(): string =
  ## A fresh MongoId. 24 hex characters, never repeated within a run.
  inc gCounter
  result = hex(gSeed, 12) & hex(int64(gCounter), 12)

proc isMongoId*(s: string): bool =
  if s.len != 24:
    return false
  for ch in s:
    let d = ch >= '0' and ch <= '9'
    let l = ch >= 'a' and ch <= 'f'
    let u = ch >= 'A' and ch <= 'F'
    if not (d or l or u):
      return false
  result = true

proc accountIdOf*(profileId: string): int =
  ## The client wants a numeric `aid` alongside the string id. Derived from the
  ## id rather than counted separately, so the pair cannot drift apart across a
  ## restart.
  var acc = 0
  for ch in profileId:
    var d = 0
    if ch >= '0' and ch <= '9': d = ord(ch) - ord('0')
    elif ch >= 'a' and ch <= 'f': d = ord(ch) - ord('a') + 10
    acc = (acc * 31 + d) and 0x3FFFFFF
  # Zero and one are reserved by the client for "no account".
  result = acc + 2
