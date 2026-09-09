## MongoIds, and the small amount of arithmetic the rest of the emulator needs.
##
## The client parses almost every id it is given as a 24-character hex MongoId
## and rejects anything else, so an id is not a place to be creative. A real
## MongoId is four bytes of timestamp, five of machine/process and three of
## counter; what matters here is only that it is 24 hex characters and that two
## calls never collide.
##
## There is no random number generator in play. The high half of an id is the
## **run number** and the low half is a counter within that run, which makes ids
## reproducible within a run — and that is a feature when a bug report says "the
## stash item with id X".
##
## ## Why the run number is persisted, and what went wrong when it was not
##
## This used to seed itself from `nowMs()`, and the ABI is explicit that
## `now_ms` is *monotonic milliseconds since host start* — so the seed was a
## two-digit number of milliseconds and the counter restarted at 1 on every
## boot. The consequence is not a cosmetic collision. Server A created a profile
## `00000000003f000000000001` whose stash was `…0002` and equipment `…0003`;
## server B, started against the same store, issued those same three ids to
## three items a player bought. `Inventory.items` then held ten items with seven
## distinct ids, the stash root was also a rifle, and the client — which draws
## the stash by walking `parentId` down from the root — could no longer draw the
## tree at all.
##
## Neither existing test could see it: `emutest` restarts but issues nothing
## afterwards, and `soak` issues thousands of ids and never restarts. It took a
## run against a real database to produce it.
##
## The requirement is therefore not "a better seed". It is: **an id issued after
## a restart can never be one an earlier run could have issued.** A clock cannot
## give that — the ABI does not offer a wall clock, and a monotonic one restarts
## with the process — so the run number is read from the store at load, advanced
## by one, and written back before a single id is handed out. One write per
## server start, and the in-run counter has 48 bits, which is not a space a
## server exhausts.
##
## A load that cannot establish the run number **refuses to start the mod**.
## That is deliberate and it is the whole point: a server that cannot guarantee
## a fresh id is a server that corrupts the next profile it touches, and
## starting anyway to avoid an error message is how the bug above happened.

import aowlspt
import aowlspt/server
import store

const RunKey = "ids.run"
  ## The run number, as 12 hex digits. Its own key rather than a field on
  ## anything: it must be readable before any profile is, and it belongs to the
  ## server rather than to a player.

var gCounter = 0
var gSeed = 0'i64
var gReady = false

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

proc fromHex(s: string): int64 =
  ## Hex text to a number, without raising. `parseHexInt` is `.raises` and can
  ## only be called inside a `try`, which is a lot of machinery for reading back
  ## twelve digits this module wrote itself. A character that is not a hex digit
  ## ends the parse rather than throwing: a truncated value reads as a smaller
  ## run number, and the caller below treats *not larger than the last one* as a
  ## failure, so a corrupt value refuses rather than repeating a run.
  result = 0'i64
  for ch in s:
    var d = -1
    if ch >= '0' and ch <= '9': d = ord(ch) - ord('0')
    elif ch >= 'a' and ch <= 'f': d = ord(ch) - ord('a') + 10
    elif ch >= 'A' and ch <= 'F': d = ord(ch) - ord('A') + 10
    if d < 0:
      return
    result = result * 16'i64 + int64(d)

proc initIds*(): bool =
  ## Establishes this run's number and records it. Called once, at load, before
  ## anything can ask for an id. False means no id may be issued.
  ##
  ## The write happens **before** the first id is handed out, not at shutdown: a
  ## server that is killed rather than stopped must still not reuse this run's
  ## number, and a number written at shutdown is a number a kill never writes.
  var usable = true
  let stored = readKey(RunKey, usable)
  if not usable:
    # The key is there and could not be read. Guessing a run number here is
    # exactly the mistake this module exists to stop -- see `emu/store` for the
    # general shape of "absent" and "unreadable" answering the same value.
    error "the id run number could not be read; refusing to issue ids"
    return false
  let previous = fromHex(stored)
  let run = previous + 1'i64
  if run <= previous:
    error "the id run number did not advance; refusing to issue ids"
    return false
  if save(RunKey, hex(run, 12)) != Ok:
    error "the id run number could not be written: " & lastError() &
          "; refusing to issue ids"
    return false
  gSeed = run
  gCounter = 0
  gReady = true
  info "ids: run " & hex(run, 12)
  result = true

proc idsReady*(): bool = gReady

proc newId*(): string =
  ## A fresh MongoId. 24 hex characters: the run number, then a counter.
  ##
  ## Never repeated within a run because the counter only advances, and never
  ## repeated *across* runs because the run number came out of the store and was
  ## written back before this could be called.
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
