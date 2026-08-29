## vx/cache — a persisted response + TTS-line cache for the voice pipeline.
##
## ---------------------------------------------------------------------------
## WHY
## ---------------------------------------------------------------------------
##
## Every reply in the ported mod was generated live: reason (LLM) then speak
## (piper) on every single `say`/`turn`, measured at 609-750 ms for the cheap
## builtin path and seconds for a real model + cold whisper. For the lines that
## repeat -- a scav's greeting, a boss taunt, "reloading", "on your six" -- that
## is the same LLM+TTS work over and over for a byte-identical wav. This cache
## returns the stored `{reply, wav}` for a `(agent, utterance, engine, voice)`
## it has seen before, WITHOUT touching the LLM or piper. That is the latency
## win the brief asked for.
##
## ---------------------------------------------------------------------------
## WHAT IS AND IS NOT CACHED -- said plainly, because a silent semantics change
## is exactly the class of bug this repo keeps getting burned by
## ---------------------------------------------------------------------------
##
## The key is `(agentId, normalized utterance, llmEngine, voiceId)`. It does
## NOT include the conversation memory, so the cache deliberately ignores
## dialogue context: it is a match for stateless, repeated LINES (greetings,
## taunts, common phrases), not for a long stateful conversation where the same
## words should draw a different reply depending on history. Changing engine or
## voice changes the key and therefore misses -- a cached wav is only ever
## replayed for the exact engine and voice that produced it. Both facts are
## reported on `/aowlspt/voice/status` so nobody is fooled into thinking a hit
## carries conversational memory that it does not.
##
## Bounded by `cacheMaxEntries` with LRU eviction and an optional TTL. Persisted
## under `cacheDir` (default `mods/voice/data/cache/`) as `index.json` plus one
## wav per entry, so it survives a backend restart. The index is written with a
## sentinel tail and read back checked for it -- a torn write is detected and
## the cache starts empty rather than parsing half a file into plausible-looking
## garbage (the tear-guard idiom from mods/maps; nimony's stdlib has no
## moveFile, so temp-then-rename is not available).

import std/strutils
import std/dirs
import std/paths
import std/errorcodes/errorcodes
import aowlspt
import aowlspt/server
import aowlspt/json as jr
import engine

# ---------------------------------------------------------------------------
# Config + state. Literal initialisers only (DLL globals; a call-initialised
# global is silently zeroed by nimony), assigned at run time in cacheConfigure.
# ---------------------------------------------------------------------------

var gCEnabled: bool = true
var gCMax: int = 256
var gCDir: string = ""
var gCTtlMs: int64 = 0            ## 0 = never expires

var gCKey: seq[string] = @[]
var gCReply: seq[string] = @[]
var gCWav: seq[string] = @[]      ## absolute path inside cacheDir, or "" (tts=none)
var gCUsed: seq[int64] = @[]      ## last-touched tick, for LRU
var gCBorn: seq[int64] = @[]      ## creation time (ms), for TTL
var gCTick: int64 = 0
var gCHits: int = 0
var gCMiss: int = 0
var gCLoadNote: string = "not loaded"

const IndexName = "index.json"
const Sentinel = "\n#aowlspt-voicecache-end"

proc cacheEnabledP*(): bool = gCEnabled
proc cacheDirPath*(): string = gCDir
proc cacheMax*(): int = gCMax
proc cacheTtlMs*(): int64 = gCTtlMs
proc cacheCount*(): int = gCKey.len
proc cacheHits*(): int = gCHits
proc cacheMisses*(): int = gCMiss
proc cacheLoadNote*(): string = gCLoadNote

# ---------------------------------------------------------------------------
# Key building
# ---------------------------------------------------------------------------

proc normUtterance*(s: string): string =
  ## Fold what should hit the same line onto one key: lowercase, collapse
  ## whitespace, drop trailing sentence punctuation. Deliberately conservative
  ## -- it must never fold two genuinely different utterances together, because
  ## a cache that returns a hit for input it never stored is the bug the brief
  ## calls out. So only case, spacing and trailing .?! are normalised away.
  result = oneLine(s).toLowerAscii()
  while result.len > 0 and (result[result.len-1] == '.' or
        result[result.len-1] == '?' or result[result.len-1] == '!' or
        result[result.len-1] == ',' or result[result.len-1] == ' '):
    result = result[0 ..< result.len-1]

proc cacheKey*(agentId, utterance, engine, voice: string): string =
  ## The composite key. `\x1f` (unit separator) cannot appear in any component,
  ## so distinct tuples cannot collide by concatenation.
  result = agentId & "\x1f" & normUtterance(utterance) & "\x1f" &
           engine & "\x1f" & voice

proc keyHash(key: string): string =
  ## FNV-1a 64-bit, as hex -- a stable filename for a key. Used only to name the
  ## wav on disk; correctness never rests on it (lookup compares the full key).
  var h: uint64 = 0xcbf29ce484222325'u64
  for ch in key:
    h = h xor uint64(ord(ch))
    h = h * 0x100000001b3'u64
  const hexd = "0123456789abcdef"
  result = ""
  var i = 0
  while i < 16:
    let nib = int((h shr (uint64(60 - i*4))) and 0xF'u64)
    result.add hexd[nib]
    i = i + 1

proc hexEncode(s: string): string =
  ## The composite key contains a `\x1f` unit separator. `aowlspt/json`'s reader
  ## does not decode a `` escape back to the byte on load (measured: the
  ## loaded key came back as the literal six characters ``, so it never
  ## matched a live key and every persisted entry missed). Hex-encoding the key
  ## before it touches JSON sidesteps the escaping question entirely -- only
  ## `[0-9a-f]` is ever serialized, which round-trips through anything.
  const hexd = "0123456789abcdef"
  result = ""
  for ch in s:
    let b = ord(ch)
    result.add hexd[(b shr 4) and 0xF]
    result.add hexd[b and 0xF]

proc hexNibble(c: char): int =
  if c >= '0' and c <= '9': return ord(c) - ord('0')
  if c >= 'a' and c <= 'f': return 10 + ord(c) - ord('a')
  if c >= 'A' and c <= 'F': return 10 + ord(c) - ord('A')
  result = -1

proc hexDecode(s: string): string =
  result = ""
  var i = 0
  while i + 1 < s.len:
    let hi = hexNibble(s[i])
    let lo = hexNibble(s[i+1])
    if hi < 0 or lo < 0: return ""   # not valid hex -> treat as empty, drop entry
    result.add char((hi shl 4) or lo)
    i = i + 2

proc findKey(key: string): int =
  result = -1
  var i = 0
  while i < gCKey.len:
    if gCKey[i] == key: return i
    i = i + 1

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

proc baseName(p: string): string =
  var i = p.len - 1
  while i >= 0 and p[i] != '/' and p[i] != '\\':
    i = i - 1
  result = p[i+1 ..< p.len]

proc ensureDir(): bool =
  if gCDir.len == 0: return false
  let made = tryCreateFinalDir(path(gCDir))
  result = (made == Success or made == NameExists)

proc persist() =
  ## Write the index. wav paths are stored as basenames so the cache dir can be
  ## moved wholesale. Sentinel-tailed so a torn read is detectable.
  if gCDir.len == 0: return
  if not ensureDir(): return
  var a = arr()
  var i = 0
  while i < gCKey.len:
    var o = obj()
    o.put("keyHex", hexEncode(gCKey[i]))
    o.put("reply", gCReply[i])
    o.put("wav", (if gCWav[i].len > 0: baseName(gCWav[i]) else: ""))
    o.put("born", int(gCBorn[i]))
    a.add done(o)
    i = i + 1
  var root = obj()
  root.put("schema", "aowlspt.voicecache/1")
  root.put("entries", done(a))
  let text = done(root).text & Sentinel
  discard writeAll(joinPath(gCDir, IndexName), text)

proc cacheLoad*() =
  ## Read a persisted index back at load. A missing file is an empty cache, not
  ## an error. A file without the sentinel was written torn -> discard it.
  gCKey = @[]; gCReply = @[]; gCWav = @[]; gCUsed = @[]; gCBorn = @[]
  gCTick = 0
  if gCDir.len == 0:
    gCLoadNote = "no cacheDir configured"
    return
  let text = readAll(joinPath(gCDir, IndexName))
  if text.len == 0:
    gCLoadNote = "0 entries (no index on disk yet)"
    return
  if not text.endsWith(Sentinel):
    gCLoadNote = "index.json was written torn (no sentinel) -- starting empty"
    return
  let items = jr.each(jr.field(text, "entries"))
  var skipped = 0
  for e in items:
    let key = hexDecode(jr.asText(jr.child(e, "keyHex"), ""))
    let reply = jr.asText(jr.child(e, "reply"), "")
    let wavBase = jr.asText(jr.child(e, "wav"), "")
    let born = int64(jr.asInt(jr.child(e, "born"), 0))
    if key.len == 0: continue
    var wavAbs = ""
    if wavBase.len > 0:
      wavAbs = joinPath(gCDir, wavBase)
      if not exists(wavAbs):
        # The wav the index promised is gone. Do NOT keep an entry whose hit
        # would hand back a path to nothing -- drop it so a miss regenerates.
        skipped = skipped + 1
        continue
    gCKey.add key
    gCReply.add reply
    gCWav.add wavAbs
    gCBorn.add born
    gCTick = gCTick + 1
    gCUsed.add gCTick
  gCLoadNote = $gCKey.len & " entries loaded" &
    (if skipped > 0: ", " & $skipped & " dropped (wav missing)" else: "")

# ---------------------------------------------------------------------------
# Configure
# ---------------------------------------------------------------------------

proc cacheConfigure*(enabled: bool; maxEntries: int; dir: string; ttlMs: int64) =
  gCEnabled = enabled
  if maxEntries > 0: gCMax = maxEntries
  gCDir = dir
  gCTtlMs = (if ttlMs > 0: ttlMs else: 0)

# ---------------------------------------------------------------------------
# Lookup / store
# ---------------------------------------------------------------------------

proc expired(idx: int): bool =
  if gCTtlMs <= 0: return false
  result = (nowMs() - gCBorn[idx]) > gCTtlMs

proc dropAt(idx: int) =
  ## Rebuild the parallel seqs without `idx` (nimony seq has no delete), and
  ## remove its wav from disk so the directory stays bounded too.
  if idx < 0 or idx >= gCKey.len: return
  if gCWav[idx].len > 0:
    try: removeFile(path(gCWav[idx]))
    except: discard
  var k: seq[string] = @[]; var r: seq[string] = @[]; var w: seq[string] = @[]
  var u: seq[int64] = @[]; var b: seq[int64] = @[]
  var i = 0
  while i < gCKey.len:
    if i != idx:
      k.add gCKey[i]; r.add gCReply[i]; w.add gCWav[i]
      u.add gCUsed[i]; b.add gCBorn[i]
    i = i + 1
  gCKey = k; gCReply = r; gCWav = w; gCUsed = u; gCBorn = b

proc evictLru() =
  ## Enforce the bound: while over capacity, drop the least-recently-used entry.
  while gCKey.len > gCMax and gCKey.len > 0:
    var pick = 0
    var i = 1
    while i < gCUsed.len:
      if gCUsed[i] < gCUsed[pick]: pick = i
      i = i + 1
    dropAt(pick)

proc cacheLookup*(key: string; reply, wav: var string): bool =
  ## A HIT returns the stored reply + wav and marks the entry most-recently-used.
  ## Counts hits/misses so `/status` and the response can PROVE a hit happened
  ## rather than asserting it. TTL-expired entries are dropped and count a miss.
  reply = ""; wav = ""
  if not gCEnabled:
    return false
  let idx = findKey(key)
  if idx < 0:
    gCMiss = gCMiss + 1
    return false
  if expired(idx):
    dropAt(idx)
    gCMiss = gCMiss + 1
    return false
  gCTick = gCTick + 1
  gCUsed[idx] = gCTick
  reply = gCReply[idx]
  wav = gCWav[idx]
  gCHits = gCHits + 1
  result = true

proc cacheStore*(key, reply, srcWav: string) =
  ## Store a freshly generated reply + wav under `key`. The source wav (in the
  ## backend's temp dir) is COPIED into the cache dir under a stable name so it
  ## outlives the temp file. If storing the wav fails, the reply is still cached
  ## with an empty wav rather than a dangling path.
  if not gCEnabled or key.len == 0: return
  var dstWav = ""
  if srcWav.len > 0 and exists(srcWav):
    if ensureDir():
      let dst = joinPath(gCDir, keyHash(key) & ".wav")
      let bytes = readAll(srcWav)
      if bytes.len > 0 and writeAll(dst, bytes):
        dstWav = dst
  let existing = findKey(key)
  if existing >= 0:
    # Refresh in place (e.g. a re-generate after a config change).
    if gCWav[existing].len > 0 and gCWav[existing] != dstWav:
      try: removeFile(path(gCWav[existing]))
      except: discard
    gCReply[existing] = reply
    gCWav[existing] = dstWav
    gCBorn[existing] = nowMs()
    gCTick = gCTick + 1
    gCUsed[existing] = gCTick
  else:
    gCKey.add key
    gCReply.add reply
    gCWav.add dstWav
    gCBorn.add nowMs()
    gCTick = gCTick + 1
    gCUsed.add gCTick
  evictLru()
  persist()
