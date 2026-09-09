## metadatatest -- the `/client/metadata` key math and section-layout shuffle,
## proved without a live host.
##
##     metadatatest
##
## The route in `mods/tarkov/tarkov.nim` (`onMetadata`) is a thin wrapper: it
## loads a per-version blob off disk, logs a missing one, and otherwise calls
## `answerMetadata`. Everything that has to be *correct* -- the key transform,
## recovering the client's sub-key, and pre-shuffling the layout so the client's
## own deshuffle reproduces it -- is pure arithmetic in `emu/metadata`, and that
## is what this gate exercises directly. No sockets, no host, no real blob: a
## fabricated blob proves the plumbing.

import std/[syncio, strutils]
import emu/metadata

var gChecks = 0
var gFailures = 0

proc check(what: string; cond: bool; detail = "") =
  inc gChecks
  if cond:
    echo "  ok   " & what
  else:
    inc gFailures
    echo "  FAIL " & what & (if detail.len > 0: "  -- " & detail else: "")

proc valueOf(envelope: string): string =
  ## The `value` the client's regex would pull out of a success envelope, or ""
  ## if there is none (an error envelope carries `data:null` and no value).
  result = ""
  let needle = "\"value\":\""
  let at = find(envelope, needle)
  if at < 0: return
  var i = at + needle.len
  while i < envelope.len and envelope[i] != '"':
    result.add envelope[i]
    inc i

const
  InternalKey = 0x876F9333'u32   ## the real 1.1.0.1.46777 constant
  # A fabricated raw layout: three 16-hex-char (DataSize, DataOffset) records.
  # The plumbing does not care whether these are the real offsets -- only that
  # what the client deshuffles equals what we stored.
  RawLayout = "00001000000002000000080000000A00000004000000001C"

proc main() =
  echo "metadatatest -- /client/metadata math"

  # -- transformKey: a fixed known-answer, so a silent change to the constants
  #    is caught. Computed from the reference core.py `_transform_key`.
  echo "transformKey"
  check "transformKey(0) == addend mod modulus",
        transformKey(0'u32) == 0x3CF8479F'u32,
        "got " & $transformKey(0'u32)
  # transformKey(internalKey+9) is the request key for subKey 9; just assert it
  # is stable and below the modulus.
  check "transformKey result is below the modulus",
        uint64(transformKey(InternalKey + 9'u32)) < 0xC4653218'u64

  # -- recoverSubKey round-trip: for every sub-key 5..14 the client could have
  #    derived, the key it would send recovers to exactly that sub-key.
  echo "recoverSubKey round-trip (subKey 5..14)"
  for sub in 5 .. 14:
    let requestKey = transformKey(InternalKey + uint32(sub))
    let got = recoverSubKey(requestKey, InternalKey)
    check "subKey " & $sub & " round-trips", got == sub,
          "recovered " & $got & " from key " & $requestKey
  # A key that belongs to no sub-key is rejected, not mis-attributed.
  check "an unrecognised key recovers to -1",
        recoverSubKey(0'u32, InternalKey) == -1,
        "got " & $recoverSubKey(0'u32, InternalKey)

  # -- shuffle/deshuffle involution: the client's own pass on what the server
  #    pre-shuffles must reproduce the raw layout, for every sub-key.
  echo "shuffle involution (clientShuffle . shuffleForSubKey == id)"
  for sub in 5 .. 14:
    let onWire = shuffleForSubKey(RawLayout, sub)
    let recovered = clientShuffle(onWire, sub)
    check "subKey " & $sub & " round-trips the layout", recovered == RawLayout,
          "recovered '" & recovered & "'"
  # And the pre-shuffle is a real permutation for a non-trivial layout, not a
  # no-op that would pass the involution vacuously.
  check "the wire value differs from the raw layout (subKey 9)",
        shuffleForSubKey(RawLayout, 9) != RawLayout

  # -- the route core, against a fabricated installed blob.
  echo "answerMetadata against a fabricated blob"
  let blobText = "{\"version\":\"1.1.0.1.46777\"," &
                 "\"internalKey\":\"0x876F9333\"," &
                 "\"valueHex\":\"" & RawLayout & "\"}"
  let blob = parseBlob(blobText)
  check "blob parses", blob.ok
  check "blob internalKey parsed from hex", blob.internalKey == InternalKey,
        "got " & $blob.internalKey
  check "blob valueHex is the raw layout", blob.valueHex == RawLayout

  # A request carrying the key for a known sub-key (9).
  let sub = 9
  let requestKey = transformKey(InternalKey + uint32(sub))
  # ...as the client actually sends it: a decimal string, parsed back.
  let requestKeyText = $requestKey
  check "decimal key parses back to the request key",
        parseDecU32(requestKeyText) == requestKey

  var usedSub = -1
  let response = answerMetadata(blob, parseDecU32(requestKeyText), usedSub)
  check "the route recovered sub-key 9", usedSub == 9, "got " & $usedSub
  check "response carries the exact BSG success envelope keys",
        find(response, "\"errLog\":{}") >= 0 and
        find(response, "\"error\":{\"code\":null,\"message\":null}") >= 0 and
        find(response, "\"err\":null") >= 0,
        response
  # The whole point: the client, deshuffling the value with its sub-key, gets
  # back exactly the raw layout the server stored.
  let onWire = valueOf(response)
  check "response value deshuffles (subKey 9) to the stored raw layout",
        clientShuffle(onWire, sub) == RawLayout,
        "deshuffled '" & clientShuffle(onWire, sub) & "'"

  # -- the missing-blob path: no fabricated value, and the version is named.
  echo "missing-blob path"
  let missing = MetaBlob(ok: false, version: "9.9.9.9.99999",
                         internalKey: 0'u32, valueHex: "")
  var missSub = -1
  let errResp = answerMetadata(missing, requestKey, missSub)
  check "missing blob recovers no sub-key", missSub == -1
  check "missing blob answers an error envelope (data:null)",
        find(errResp, "\"data\":null") >= 0
  check "error envelope carries no value for the client's regex",
        valueOf(errResp).len == 0, "value was '" & valueOf(errResp) & "'"
  check "error message names the version",
        find(errResp, "9.9.9.9.99999") >= 0, errResp
  # A blob that parses but whose key nobody sent is also an error, not a guess.
  var badSub = -1
  let badResp = answerMetadata(blob, 12345'u32, badSub)
  check "an unrecognised key on a good blob is an error", badSub == -1 and
        find(badResp, "\"data\":null") >= 0

  echo ""
  echo "checks: " & $gChecks & "   failures: " & $gFailures
  if gFailures == 0:
    echo "PASS"
  else:
    echo "FAIL"
    quit 1

main()
