## metadata -- the `/client/metadata` key math and section-layout shuffle.
##
## Post-1.0 `GameAssembly.dll`, inside `il2cpp_init`, POSTs to
## `/client/metadata` to obtain the section-layout blob it needs to decrypt its
## own IL2CPP metadata. Without a correct answer the client dies at ~200 ms,
## before the normal session pipeline has even started. This module is the math
## behind that one route.
##
## The client sends `{"version":"<ver>","key":"<decimal>"}` where
##
##     key = TransformKey((internalKey + subKey) mod 2^32)  (rendered decimal)
##
## `internalKey` is a per-version constant baked into the client's own metadata
## file; `subKey` is one of ten values 5..14 derived on the client from that
## file's creation timestamp -- so it differs per install and the server must
## RECOVER it (`recoverSubKey`). Recovering it is what lets ONE stored blob serve
## every install regardless of local timestamp.
##
## The reply carries the section layout as a hex string in `data.value`. The
## client DESHUFFLES what we send using ITS subKey (a Durstenfeld pass keyed by
## `TransformKey(subKey)`), so the server must send the raw layout pre-shuffled
## with the INVERSE of that permutation -- `shuffleForSubKey` -- so the client's
## own pass reproduces the raw layout.
##
## Reference: `~/XM-MetadataDecrypt/eft_metadata_key/core.py` (the key math) and
## `gui/MetadataDecryptGui/MetadataDecryptor.cs` method `FetchHeaderProperties`
## (the client-side deshuffle). Everything here is offline arithmetic; nothing
## in this module reads the network or the game's files.

import std/strutils
import std/syncio
import aowlspt
import aowlspt/json

const
  Multiplier = 0x1657A1'u64
  Addend     = 0x3CF8479F'u64
  Modulus    = 0xC4653218'u64
  KeyModulus = 0x8BA'u64
  SubKeyLow  = 5     ## subKey is one of ten values, 5..14 inclusive
  SubKeyHigh = 14

# ---------------------------------------------------------------------------
# The key transform
# ---------------------------------------------------------------------------

proc transformKey*(value: uint32): uint32 =
  ## `((v mod 0x8BA) * 0x1657A1 + 0x3CF8479F) mod 0xC4653218`, all in 32-bit
  ## space. Computed through `uint64` because the sum before the final `mod`
  ## overflows 32 bits for large `v`; the modulus is < 2^32 so the result always
  ## fits back into `uint32`. This matches `_transform_key` in the reference
  ## `core.py` byte for byte.
  let reduced = uint64(value) mod KeyModulus
  let t = (reduced * Multiplier + Addend) mod Modulus
  result = uint32(t)

proc nibbleShuffle*(value: uint32): uint32 =
  ## The header-word bit shuffle the client applies while decoding its own
  ## metadata header (`_nibble_shuffle` in `core.py`). The `/client/metadata`
  ## route does NOT use this -- recovering `internalKey` is the client's job, and
  ## the server is handed it directly in the stored blob -- but it is kept here
  ## so the whole transform lives in one place and a util that derives a blob can
  ## reuse it. Unsigned arithmetic wraps, which is exactly the reference's
  ## trailing `& 0xFFFFFFFF`.
  let a = (value and 0x66666666'u32) or
          ((value and 0xF1111111'u32) shl 3) or
          ((value shr 3) and 0x11111111'u32)
  let b = (value and 0x62222222'u32) or
          (((value and 0xF1111111'u32) shl 3) and 0xF3333333'u32) or
          ((value shr 3) and 0x11111111'u32)
  result = ((a shr 2) and 0x33333333'u32) or ((b shl 2))

# ---------------------------------------------------------------------------
# Recovering the client's subKey
# ---------------------------------------------------------------------------

proc recoverSubKey*(requestKey: uint32; internalKey: uint32): int =
  ## The subKey (5..14) whose `TransformKey((internalKey + subKey) mod 2^32)`
  ## equals the `key` the client sent, or -1 if none matches. Only ten values
  ## are possible, so this is a ten-iteration search, and it is what lets a
  ## single stored blob answer every install: the server does not need to know
  ## the client's metadata-file timestamp, it just recognises which of the ten
  ## keys arrived.
  for sub in SubKeyLow .. SubKeyHigh:
    let derived = internalKey + uint32(sub)   # (internalKey + subKey) mod 2^32
    if transformKey(derived) == requestKey:
      return sub
  result = -1

# ---------------------------------------------------------------------------
# The section-layout shuffle
# ---------------------------------------------------------------------------
#
# The client, on receiving `value`, runs (FetchHeaderProperties):
#
#     transformed = TransformKey(subKey)
#     for i in 0 ..< value.Length:
#         j = transformed mod (i + 1)     # j in [0, i]
#         swap(value[i], value[j])
#
# and then parses the RESULT as the section layout. So the layout the client
# ends up with is `clientShuffle(received)`. For the client to end up with our
# raw layout R we must send `received` such that `clientShuffle(received) = R`,
# i.e. the inverse permutation of R. Each step is a self-inverse transposition,
# so the inverse of the whole pass is the same swaps applied in reverse order.

proc clientShuffle*(hex: string; subKey: int): string =
  ## Exactly the pass the real client runs on the `value` it receives. Used to
  ## PROVE the server's pre-shuffle: `clientShuffle(shuffleForSubKey(R)) == R`.
  ## Renamed from the client's own word for it ("deshuffle") to the direction it
  ## actually moves in.
  result = hex
  let transformed = transformKey(uint32(subKey))
  var i = 0
  while i < result.len:
    let j = int(transformed mod uint32(i + 1))
    let tmp = result[i]
    result[i] = result[j]
    result[j] = tmp
    inc i

proc shuffleForSubKey*(rawLayoutHex: string; subKey: int): string =
  ## The `value` to put on the wire so that the client's own `clientShuffle`
  ## reproduces `rawLayoutHex`. The inverse permutation: the same indexed swaps
  ## as the client, applied from the last index down to the first.
  result = rawLayoutHex
  let transformed = transformKey(uint32(subKey))
  var i = result.len - 1
  while i >= 0:
    let j = int(transformed mod uint32(i + 1))
    let tmp = result[i]
    result[i] = result[j]
    result[j] = tmp
    dec i

# ---------------------------------------------------------------------------
# The stored per-version blob
# ---------------------------------------------------------------------------
#
# `mods/tarkov/data/metadata/<version>.json`, installed by `tools/metablob.py`
# from the user's own game install:
#
#     {"version":"1.1.0.1.46777","internalKey":"0x876F9333","valueHex":"<hex>"}
#
# `valueHex` is the RAW, un-shuffled section layout -- a run of 16-hex-char
# (DataSize, DataOffset) records. The server re-shuffles it per request against
# the recovered subKey, so one file serves every install.

type
  MetaBlob* = object
    ok*: bool           ## a well-formed blob was parsed
    version*: string
    internalKey*: uint32
    valueHex*: string   ## the raw, un-shuffled layout

proc parseHexU32(s: string): uint32 =
  ## `0x876F9333` or `876F9333` -> a `uint32`. Non-raising: unknown characters
  ## end the parse (`parseInt` raises, and a raising proc drags `try`/`except`
  ## into every caller for no gain here).
  var i = 0
  if s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'):
    i = 2
  var acc = 0'u64
  while i < s.len:
    let c = s[i]
    var d = -1
    if c >= '0' and c <= '9': d = ord(c) - ord('0')
    elif c >= 'a' and c <= 'f': d = ord(c) - ord('a') + 10
    elif c >= 'A' and c <= 'F': d = ord(c) - ord('A') + 10
    else: break
    acc = (acc shl 4) or uint64(d)
    inc i
  result = uint32(acc)

proc parseDecU32*(s: string): uint32 =
  ## A decimal string -> a `uint32`, non-raising. The client's `key` is a decimal
  ## rendering of a value below the modulus (< 2^32), so it fits; the `uint64`
  ## accumulator guards a malformed over-long input from tripping a check.
  var acc = 0'u64
  for c in s:
    if c < '0' or c > '9': break
    acc = acc * 10 + uint64(ord(c) - ord('0'))
  result = uint32(acc)

proc parseBlob*(text: string): MetaBlob =
  ## Parse the stored blob JSON. `ok` is false unless both `internalKey` and a
  ## non-empty `valueHex` are present.
  result = MetaBlob(ok: false, version: "", internalKey: 0'u32, valueHex: "")
  result.version = field(text, "version").asText("")
  let ikText = field(text, "internalKey").asText("")
  result.valueHex = field(text, "valueHex").asText("")
  if ikText.len == 0 or result.valueHex.len == 0:
    return
  result.internalKey = parseHexU32(ikText)
  result.ok = true

proc readWholeFile(path: string; into: var string): bool =
  ## Read a small text file without a raising call. `readFile`/`readAll` are
  ## `.raises`; `open` (the bool overload) and `readLine` are not, and the blob
  ## is a few hundred bytes of one-line JSON, so line reassembly is exact enough
  ## for a JSON parser that ignores the join.
  var f: File
  if not open(f, path, fmRead):
    return false
  into = ""
  var line = ""
  var first = true
  while readLine(f, line):
    if not first: into.add "\n"
    into.add line
    first = false
  close(f)
  result = true

proc blobPath*(version: string): string =
  ## Where `tools/metablob.py` installs a version's blob, under the mod's own
  ## directory.
  result = modDir() & "/data/metadata/" & version & ".json"

proc loadBlob*(version: string): MetaBlob =
  ## Load and parse the blob for `version`, or an `ok:false` blob if there is no
  ## file for it (the route logs that case and answers an error envelope rather
  ## than fabricate a layout).
  result = MetaBlob(ok: false, version: version, internalKey: 0'u32,
                    valueHex: "")
  var text = ""
  if not readWholeFile(blobPath(version), text):
    return
  result = parseBlob(text)
  if result.version.len == 0:
    result.version = version

# ---------------------------------------------------------------------------
# The response envelope
# ---------------------------------------------------------------------------
#
# This route does NOT use the standard `/client/*` envelope. BSG's own shape is
#
#     {"data":{"value":"<hex>"},"err":null,"errmsg":null,"status":null,
#      "errLog":{},"error":{"code":null,"message":null}}
#
# and the early il2cpp_init client scrapes it with a lenient regex,
# `\{[\s\n]*"value"\s*:\s*"([0-9a-fA-F]+)"[\s\n]*\}`, so `value` is the whole
# payload. On error we send the same envelope with `data:null` and a message --
# there is no `value` for the client to find, which is the honest outcome when
# we have no blob: a fabricated value only makes the client fail later, and more
# confusingly.

proc metaSuccess*(valueHex: string): string =
  result = "{\"data\":{\"value\":\"" & valueHex &
           "\"},\"err\":null,\"errmsg\":null,\"status\":null," &
           "\"errLog\":{},\"error\":{\"code\":null,\"message\":null}}"

proc metaError*(message: string): string =
  result = "{\"data\":null,\"err\":null,\"errmsg\":null,\"status\":null," &
           "\"errLog\":{},\"error\":{\"code\":null,\"message\":" &
           quoted(message) & "}}"

const
  RespMul    = 1624453'i64
  RespAdd    = 1023920427'i64
  RespMod    = 0x8ED7A18D'i64
  RespCursor = 0x65F6D'i64

proc shuffleResponseBody*(json: string): string =
  ## BSG's `/client/metadata` response body is not plain JSON on the wire: it is
  ## `[int32 little-endian length][json]` then byte-shuffled by a length-keyed
  ## Durstenfeld pass. The early `il2cpp_init` client deshuffles the body it
  ## receives *before* it scrapes `value` out of it -- so an un-shuffled JSON
  ## body deshuffles into garbage, the client finds no value, and `il2cpp_init`
  ## returns 0 exactly as if there were no server. This applies the inverse of
  ## that deshuffle (the same indexed swaps, in reverse order). It round-trips
  ## against `tools/metablob.py`'s `_deshuffle_response_body`.
  ##
  ## The generator's cursor starts at 0x65F6D and only increments; for a body
  ## this small it never reaches the 0xA53F260DDB0 wrap, so each table value is
  ## computed inline rather than tabulated.
  let n0 = json.len
  var framed = $char(n0 and 0xFF) & $char((n0 shr 8) and 0xFF) &
               $char((n0 shr 16) and 0xFF) & $char((n0 shr 24) and 0xFF) & json
  let n = framed.len
  let startEntry = n mod 0xAAB
  var i = n - 1
  while i >= 1:
    let cursorVal = RespCursor + int64(i + startEntry)
    let tv = (RespMul * cursorVal + RespAdd) mod RespMod
    let j = int(tv mod int64(i))
    let tmp = framed[i]
    framed[i] = framed[j]
    framed[j] = tmp
    dec i
  result = framed

# ---------------------------------------------------------------------------
# The route's core, factored out so it is testable without a live host
# ---------------------------------------------------------------------------

proc answerMetadata*(blob: MetaBlob; requestKey: uint32;
                     subKeyUsed: var int): string =
  ## Given a parsed blob and the client's request key, produce the exact bytes
  ## to answer with. `subKeyUsed` is set to the recovered subKey, or -1 when the
  ## blob is unusable or no subKey matches (the caller logs the -1 cases). Pure
  ## and host-free: the route is a thin wrapper that loads the blob and logs.
  subKeyUsed = -1
  if not blob.ok:
    return metaError("no metadata blob for version " & blob.version)
  let sub = recoverSubKey(requestKey, blob.internalKey)
  if sub < 0:
    return metaError("unrecognised metadata key for version " & blob.version)
  subKeyUsed = sub
  result = shuffleResponseBody(metaSuccess(shuffleForSubKey(blob.valueHex, sub)))
