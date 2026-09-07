## bm/brain — `decide()`: cache -> ontology -> llm -> builtin, cheapest first.
##
## The tail of every tier is the SAME code (`decideFromRaw`): parse the tags out
## of the raw reply, drop the ones that are not in the grammar and say so, split
## what is left into sentences, hand each sentence to the sink in order, then
## store the line. There is deliberately no second path for the ontology or for
## a cache hit, because a per-tier copy of "strip the tags" is how one tier ends
## up speaking a bracket.
##
## The cache is keyed `(personId, normalized utterance, situation signature,
## engine, voice)` and NOT on memory, exactly as `mods/voice` does it. So it
## matches "the same kind of moment", not a stateful conversation, and
## `brainStats()` says so in a field rather than in a comment nobody reads.
##
## Persisted keys are HEX-ENCODED. The composite key contains a `\x1f` unit
## separator and `aowlspt/json`'s reader does not decode escapes back to the
## byte (measured in mods/voice: the key came back as the literal six characters
## and every persisted entry missed forever). Only `[0-9a-f]` ever touches JSON.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json as jr
import util
import prompt
import ontology
import llm

type
  Decision* = object
    text*: string
    tags*: seq[string]
    tier*: string            ## cache | ontology | llm | builtin
    cached*: bool
    engine*: string
    ms*: int64
    notes*: seq[string]
    segments*: seq[string]
    turnId*: int             ## >0 only when tier == "streaming"
    streaming*: bool         ## the reply is NOT finished; segments arrive later

# ------------------------------------------------------------------ config
var cCacheDir: string = ""
var cCacheMax: int = 512
var cMemoryTurns: int = 8
var cMinConfidence: float = 0.6

# ------------------------------------------------------------------ cache
var gKey: seq[string] = @[]
var gText: seq[string] = @[]
var gTags: seq[string] = @[]      ## "\x1f"-joined
var gTier: seq[string] = @[]
var gUsed: seq[int64] = @[]
var gTick: int64 = 0
var gHits: int = 0
var gMiss: int = 0
var gLoadNote: string = "not loaded"

# tier histogram
var gNCache: int = 0
var gNOntology: int = 0
var gNLlm: int = 0
var gNBuiltin: int = 0
var gLastCacheRead: int = -1

# streaming relay. nimony proc types are nimcall, not closures, so the sink a
# caller passed is parked here and the wrapper below is a top-level proc.
var gOuterSink: SegmentSink = nil
var gStreamTags: seq[string] = @[]
var gStreamSegs: seq[string] = @[]

const CacheIndex = "brain.json"
const Sentinel = "\n#aowlspt-basement-brain-end"

proc brainConfigure*(cacheDir: string; cacheMax: int; memoryTurns: int;
                     ontologyMinConfidence: float) =
  cCacheDir = cacheDir
  if cacheMax > 0: cCacheMax = cacheMax
  if memoryTurns > 0: cMemoryTurns = memoryTurns
  if ontologyMinConfidence > 0.0: cMinConfidence = ontologyMinConfidence

proc brainMemoryTurns*(): int = cMemoryTurns
proc brainMinConfidence*(): float = cMinConfidence
proc brainCacheNote*(): string = gLoadNote

proc joinTags(items: seq[string]): string =
  result = ""
  for it in items:
    if result.len > 0: result.add "\x1f"
    result.add it

proc splitTags(s: string): seq[string] =
  result = @[]
  var cur = ""
  for ch in s:
    if ch == '\x1f':
      if cur.len > 0: result.add cur
      cur = ""
    else: cur.add ch
  if cur.len > 0: result.add cur

proc hexEncode(s: string): string =
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
    if hi < 0 or lo < 0: return ""
    result.add char((hi shl 4) or lo)
    i = i + 2

proc cacheKey*(personId, utterance, signature, engine, voice: string): string =
  result = personId & "\x1f" & normalizeText(utterance) & "\x1f" & signature &
           "\x1f" & engine & "\x1f" & voice

proc findKey(key: string): int =
  result = -1
  var i = 0
  while i < gKey.len:
    if gKey[i] == key: return i
    i = i + 1

proc persist() =
  if cCacheDir.len == 0: return
  if not ensureDir(cCacheDir): return
  var a = arr()
  var i = 0
  while i < gKey.len:
    var o = obj()
    o.put("keyHex", hexEncode(gKey[i]))
    o.put("text", gText[i])
    o.put("tagsHex", hexEncode(gTags[i]))
    o.put("tier", gTier[i])
    a.add done(o)
    i = i + 1
  var root = obj()
  root.put("schema", "aowlspt.basement.braincache/1")
  root.put("keyedOn", "personId, normalized utterance, situation signature, engine, voice -- NOT conversation memory")
  root.put("entries", done(a))
  discard writeAll(joinPath(cCacheDir, CacheIndex), done(root).text & Sentinel)

proc brainLoadCache*(note: var string) =
  gKey = @[]; gText = @[]; gTags = @[]; gTier = @[]; gUsed = @[]
  gTick = 0
  if cCacheDir.len == 0:
    note = "no cacheDir configured -- the line cache is in-memory only"
    gLoadNote = note
    return
  let text = readAll(joinPath(cCacheDir, CacheIndex))
  if text.len == 0:
    note = "0 entries (no " & CacheIndex & " on disk yet)"
    gLoadNote = note
    return
  if not text.endsWith(Sentinel):
    note = CacheIndex & " was written torn (no sentinel) -- starting empty"
    gLoadNote = note
    return
  for e in jr.each(jr.field(text, "entries")):
    let k = hexDecode(jr.asText(jr.child(e, "keyHex"), ""))
    if k.len == 0: continue
    gKey.add k
    gText.add jr.asText(jr.child(e, "text"), "")
    gTags.add hexDecode(jr.asText(jr.child(e, "tagsHex"), ""))
    gTier.add jr.asText(jr.child(e, "tier"), "ontology")
    gTick = gTick + 1
    gUsed.add gTick
  note = $gKey.len & " cached lines loaded"
  gLoadNote = note

proc dropAt(idx: int) =
  if idx < 0 or idx >= gKey.len: return
  var k: seq[string] = @[]; var t: seq[string] = @[]
  var g: seq[string] = @[]; var r: seq[string] = @[]; var u: seq[int64] = @[]
  var i = 0
  while i < gKey.len:
    if i != idx:
      k.add gKey[i]; t.add gText[i]; g.add gTags[i]; r.add gTier[i]; u.add gUsed[i]
    i = i + 1
  gKey = k; gText = t; gTags = g; gTier = r; gUsed = u

proc evictLru() =
  while gKey.len > cCacheMax and gKey.len > 0:
    var pick = 0
    var i = 1
    while i < gUsed.len:
      if gUsed[i] < gUsed[pick]: pick = i
      i = i + 1
    dropAt(pick)

proc brainCacheClear*() =
  gKey = @[]; gText = @[]; gTags = @[]; gTier = @[]; gUsed = @[]
  gTick = 0
  persist()

proc brainCacheCount*(): int = gKey.len

# ------------------------------------------------------------------ tags

proc tagName(t: string): string =
  let colon = t.find(':')
  if colon < 0: result = t.strip().toUpperAscii()
  else: result = t[0 ..< colon].strip().toUpperAscii()

proc isKnownTag(name: string): bool =
  let kt = knownTags()
  for k in kt:
    if k == name: return true
  result = false

# ------------------------------------------------------------------ the tail

proc emitSegments(text: string; sink: SegmentSink; segs: var seq[string]) =
  let parts = splitSentences(text)
  if parts.len == 0:
    if sink != nil: sink("", true)
    return
  var i = 0
  while i < parts.len:
    segs.add parts[i]
    if sink != nil: sink(parts[i], i == parts.len - 1)
    i = i + 1

proc decideFromRaw*(raw: string; tier: string; engine: string;
                    preTags: seq[string]; sink: SegmentSink;
                    notes: var seq[string]): Decision =
  ## The shared tail of every tier. `preTags` are tags the tier already knows
  ## about (the ontology's row tags); tags written INSIDE `raw` are parsed out
  ## here. The returned `text` never contains a bracket.
  var d = Decision(text: "", tags: @[], tier: tier, cached: false,
                   engine: engine, ms: 0, notes: @[], segments: @[],
                   turnId: 0, streaming: false)
  var found: seq[string] = @[]
  let clean = stripTags(raw, found)
  var all: seq[string] = @[]
  for t in preTags: all.add t
  for t in found: all.add t
  for t in all:
    let n = tagName(t)
    if modelForbiddenTag(n):
      notes.add "dropped [" & n & "] -- that tag is the encounter machine's " &
                "own record of a believability roll and is never accepted " &
                "from a reply; the roll decides, not the speaker"
    elif isKnownTag(n):
      d.tags.add t
    else:
      notes.add "dropped unknown tag [" & n & "] -- not in the tag grammar; " &
                "it was stripped from the spoken line and not acted on"
  d.text = clean
  emitSegments(d.text, sink, d.segments)
  for n in notes: d.notes.add n
  result = d

# ------------------------------------------------------------------ llm relay

proc llmSinkWrapper(sentence: string; final: bool) =
  ## Strips tags per sentence as they stream so a tag is never spoken, and
  ## records them for the Decision.
  var found: seq[string] = @[]
  let clean = stripTags(sentence, found)
  for t in found: gStreamTags.add t
  if clean.len > 0:
    gStreamSegs.add clean
    if gOuterSink != nil: gOuterSink(clean, final)
  elif final and gStreamSegs.len == 0:
    if gOuterSink != nil: gOuterSink("", true)

# ------------------------------------------------------------------ streaming
#
# An in-flight LLM turn. `decide` starts one and returns a Decision whose tier
# is "streaming" and whose text is EMPTY -- the sentences arrive later, on the
# mod's tick, through the same sink a synchronous turn uses. The caller pumps
# with `brainStreamPump` and gets the finished Decision back on the poll that
# completes the turn.
#
# The per-turn state is parallel seqs, as everywhere else in this mod: nimony
# has no closures worth relying on in a DLL and a seq-of-object is a shape this
# codebase has been burned by. `gSBuf` is the text that has arrived but does
# not yet end a sentence; everything before the last boundary has already been
# spoken.
#
# TAGS. The grammar puts them at the END of the reply, so they are stripped
# per sentence on the way out (a tag must never be spoken even if the model
# puts one mid-reply) and APPLIED only once, by the caller, when the turn
# finishes. That is why `brainStreamPump` returns the tags on the completing
# poll and never before.

var gSId: seq[int] = @[]
var gSKey: seq[string] = @[]
var gSBuf: seq[string] = @[]        ## arrived, not yet a complete sentence
var gSSegs: seq[string] = @[]       ## "\x1f"-joined spoken segments
var gSTagsJ: seq[string] = @[]      ## "\x1f"-joined raw tags seen so far
var gSNotesJ: seq[string] = @[]     ## "\x1f"-joined notes
var gSFallback: seq[string] = @[]   ## the ontology line spoken on a timeout
var gSStartMs: seq[int64] = @[]
var gSEngine: seq[string] = @[]
var gNStream: int = 0
var gNTimeout: int = 0

proc findStream(id: int): int =
  result = -1
  var i = 0
  while i < gSId.len:
    if gSId[i] == id: return i
    i = i + 1

proc dropStreamAt(idx: int) =
  if idx < 0 or idx >= gSId.len: return
  var a: seq[int] = @[]
  var b: seq[string] = @[]
  var c: seq[string] = @[]
  var d: seq[string] = @[]
  var e: seq[string] = @[]
  var f: seq[string] = @[]
  var g: seq[string] = @[]
  var h: seq[int64] = @[]
  var k: seq[string] = @[]
  var i = 0
  while i < gSId.len:
    if i != idx:
      a.add gSId[i]
      b.add gSKey[i]
      c.add gSBuf[i]
      d.add gSSegs[i]
      e.add gSTagsJ[i]
      f.add gSNotesJ[i]
      g.add gSFallback[i]
      h.add gSStartMs[i]
      k.add gSEngine[i]
    i = i + 1
  gSId = a
  gSKey = b
  gSBuf = c
  gSSegs = d
  gSTagsJ = e
  gSNotesJ = f
  gSFallback = g
  gSStartMs = h
  gSEngine = k

proc appendJoined(cur: var string; item: string) =
  if item.len == 0: return
  if cur.len > 0: cur.add "\x1f"
  cur.add item

proc brainStreamCount*(): int = gSId.len
proc brainStreamIdAt*(i: int): int =
  if i < 0 or i >= gSId.len: return 0
  result = gSId[i]

proc emitStreamSentence(idx: int; sentence: string; final: bool;
                        sink: SegmentSink) =
  var found: seq[string] = @[]
  let clean = stripTags(sentence, found)
  var tags = gSTagsJ[idx]
  for t in found: appendJoined(tags, t)
  gSTagsJ[idx] = tags
  if clean.len > 0:
    var segs = gSSegs[idx]
    appendJoined(segs, clean)
    gSSegs[idx] = segs
    if sink != nil: sink(clean, final)
  elif final:
    # The stream must be terminated exactly once even when the last fragment
    # was nothing but a tag -- a client waiting for `final` would hang.
    if sink != nil: sink("", true)

proc buildStreamDecision(idx: int; tier: string): Decision =
  var d = Decision(text: "", tags: @[], tier: tier, cached: false,
                   engine: gSEngine[idx], ms: 0, notes: @[], segments: @[],
                   turnId: gSId[idx], streaming: false)
  var notes: seq[string] = splitTags(gSNotesJ[idx])
  for t in splitTags(gSTagsJ[idx]):
    let n = tagName(t)
    if modelForbiddenTag(n):
      notes.add "dropped [" & n & "] -- the encounter machine emits that " &
                "tag, a model never does"
    elif isKnownTag(n): d.tags.add t
    else:
      notes.add "dropped unknown tag [" & n & "] -- not in the tag grammar; " &
                "it was stripped from the spoken line and not acted on"
  d.segments = splitTags(gSSegs[idx])
  var joined = ""
  for sgm in d.segments:
    if joined.len > 0: joined.add " "
    joined.add sgm
  d.text = joined
  for n in notes: d.notes.add n
  d.ms = wallMs() - gSStartMs[idx]
  result = d

proc brainStreamPump*(id: int; sink: SegmentSink; d: var Decision;
                      note: var string): bool =
  ## Consume whatever of turn `id` has arrived, speaking every sentence that
  ## completed. Returns TRUE only on the poll that FINISHES the turn, and `d`
  ## is meaningful only then. An unknown id returns false with a note saying
  ## so, rather than looking like a turn that is merely still running.
  note = ""
  let idx = findStream(id)
  if idx < 0:
    note = "no in-flight turn " & $id
    return false
  var newText = ""
  var finished = false
  var pnote = ""
  let alive = llmStreamPoll(id, newText, finished, pnote)
  if not alive:
    note = "the llm layer has no turn " & $id & ": " & pnote
    dropStreamAt(idx)
    return false
  if newText.len > 0:
    var buf = gSBuf[idx]
    buf.add newText
    # Tags sit at the END of a reply, and a half-arrived tag must never be
    # spoken: MEASURED 2026-09-07 on the live sidecar, `[MOOD: -0.2]` was
    # split at its decimal point and spoken as "[MOOD: -0." and "2]". So only
    # the text BEFORE the first `[` is split into sentences; everything from
    # the bracket on waits in the buffer until the stream ends, where
    # emitStreamSentence strips and records it.
    let cut = buf.find('[')
    let head = (if cut >= 0: buf[0 ..< cut] else: buf)
    let tail = (if cut >= 0: buf[cut .. ^1] else: "")
    let parts = splitSentences(head)
    if parts.len > 1:
      var i = 0
      while i < parts.len - 1:
        emitStreamSentence(idx, parts[i], false, sink)
        i = i + 1
      buf = tailAfter(head, parts[parts.len - 1]) & tail
    gSBuf[idx] = buf
  let timedOut = (not finished) and
                 (wallMs() - gSStartMs[idx]) > int64(llmTurnTimeoutMs())
  if not finished and not timedOut:
    return false
  var notes = gSNotesJ[idx]
  if timedOut:
    gNTimeout = gNTimeout + 1
    gSBuf[idx] = ""
    appendJoined(notes, "TIMED OUT after " & $llmTurnTimeoutMs() &
      " ms with no end of stream; the ontology's fallback row was spoken " &
      "instead. That row is a template, NOT a language model, and this is " &
      "not a short reply -- the model never finished.")
    gSNotesJ[idx] = notes
    emitStreamSentence(idx, gSFallback[idx], true, sink)
    d = buildStreamDecision(idx, "timeout")
  else:
    if pnote.len > 0: appendJoined(notes, pnote)
    gSNotesJ[idx] = notes
    # The remainder may hold several sentences plus the tags: strip the tags
    # once, record them, then speak the sentences in order, the last as final.
    var restFound: seq[string] = @[]
    let rest = stripTags(gSBuf[idx], restFound).strip()
    if restFound.len > 0:
      var tg = gSTagsJ[idx]
      for t in restFound: appendJoined(tg, t)
      gSTagsJ[idx] = tg
    let restParts = splitSentences(rest)
    if restParts.len == 0:
      emitStreamSentence(idx, "", true, sink)
    else:
      var j = 0
      while j < restParts.len:
        emitStreamSentence(idx, restParts[j], j == restParts.len - 1, sink)
        j = j + 1
    gSBuf[idx] = ""
    d = buildStreamDecision(idx, "llm")
    gNLlm = gNLlm + 1
  # The cache stores the FINISHED text, exactly as the synchronous path does,
  # so a repeat of the same line in the same kind of moment is answered from
  # tier 0 with no stream at all.
  if d.text.len > 0:
    gTick = gTick + 1
    gKey.add gSKey[idx]
    gText.add d.text
    gTags.add joinTags(d.tags)
    gTier.add d.tier
    gUsed.add gTick
    evictLru()
    persist()
  llmStreamDrop(id)
  dropStreamAt(idx)
  note = "turn " & $id & " finished (" & d.tier & ")"
  result = true

proc brainStreamBegin(key, engine, fallback: string; id: int; note: string) =
  gNStream = gNStream + 1
  gSId.add id
  gSKey.add key
  gSBuf.add ""
  gSSegs.add ""
  gSTagsJ.add ""
  gSNotesJ.add note
  gSFallback.add fallback
  gSStartMs.add wallMs()
  gSEngine.add engine

# ------------------------------------------------------------------ decide

proc decide*(worldPrompt, rules: string; c: PersonCard; s: Situation;
             memory, facts, utterance: string; sink: SegmentSink;
             streamed: var bool; turnId: var int): Decision =
  ## `streamed` is the honest half of the answer: TRUE means the returned
  ## Decision is a RECEIPT (tier "streaming", empty text) and the sentences
  ## will arrive later through `sink` on `brainStreamPump`. FALSE means the
  ## Decision is the whole reply, exactly as before.
  streamed = false
  turnId = 0
  let t0 = wallMs()
  let engine = llmEngine()
  let sig = situationSignature(s)
  let key = cacheKey(c.id, utterance, sig, engine, c.voice)
  var notes: seq[string] = @[]

  # ---- tier 0: the line cache
  let idx = findKey(key)
  if idx >= 0:
    gTick = gTick + 1
    gUsed[idx] = gTick
    gHits = gHits + 1
    gNCache = gNCache + 1
    var d = Decision(text: gText[idx], tags: splitTags(gTags[idx]),
                     tier: "cache", cached: true, engine: engine, ms: 0,
                     notes: @[], segments: @[], turnId: 0, streaming: false)
    d.notes.add "line cache HIT (originally tier " & gTier[idx] &
                "); the key holds no conversation memory, so this matches a " &
                "repeated line in the same kind of moment, not a stateful turn"
    emitSegments(d.text, sink, d.segments)   # a hit replays through the sink
    d.ms = wallMs() - t0
    result = d
    return
  gMiss = gMiss + 1

  # ---- tier 1: the ontology
  var conf = 0.0
  let intent = classifyIntent(utterance, conf)
  notes.add "intent=" & intent & " confidence=" & $conf &
            " (threshold " & $cMinConfidence & ")"
  let templatesOnly = engine == "builtin" or engine == "none"
  var tableIntent = ""
  if intent != "unknown" and conf >= cMinConfidence:
    # With a real model configured the table answers only the trivial repeats.
    # Everything else is exactly the material a model is for, and a table that
    # intercepts it makes the model look broken rather than absent.
    if templatesOnly or intent == "greet" or intent == "insult":
      tableIntent = intent
    else:
      notes.add "intent=" & intent & " passes to the " & engine &
                " tier: with a model configured the table answers only " &
                "greet/insult, and only at confidence >= " & $cMinConfidence
  elif templatesOnly:
    # No model is going to answer this one, so the honest in-character move is
    # to ask them to say it again -- from the SAME table, in this person's
    # stance bucket -- rather than serve the generic fallback row. With a real
    # engine configured the LLM tier below gets the turn instead.
    tableIntent = "unknown"
  if tableIntent.len > 0:
    var reply = ""
    var rowTags: seq[string] = @[]
    if ontologyReply(tableIntent, c, s, utterance, reply, rowTags):
      notes.add "ontology row " & tableIntent & " x " & bucketFor(c, s) &
                " -- a table lookup in data/ontology.json, not a model"
      var d = decideFromRaw(reply, "ontology", engine, rowTags, sink, notes)
      gNOntology = gNOntology + 1
      gTick = gTick + 1
      gKey.add key; gText.add d.text; gTags.add joinTags(d.tags)
      gTier.add "ontology"; gUsed.add gTick
      evictLru(); persist()
      d.ms = wallMs() - t0
      result = d
      return
    notes.add "no ontology row for " & tableIntent & " x " & bucketFor(c, s) &
              "; falling through"

  # ---- tier 2: the LLM
  if engine != "builtin" and engine != "none":
    let sys = stablePrefix(worldPrompt, rules, c)
    let usr = volatileSuffix(c, s, memory, facts, utterance)
    if llmCanStream():
      var sid = 0
      var snote = ""
      if llmStreamStart(sys, usr, sid, snote):
        # The fallback line is resolved NOW, while the card and situation are
        # in hand, so a timeout 60 s from here has something in character to
        # say instead of silence.
        var fb = ""
        var fbTags: seq[string] = @[]
        if not ontologyFallback(c, s, utterance, fb, fbTags): fb = "..."
        var nj = ""
        for n in notes: appendJoined(nj, n)
        appendJoined(nj, snote)
        brainStreamBegin(key, engine, fb, sid, nj)
        var ds = Decision(text: "", tags: @[], tier: "streaming",
                          cached: false, engine: engine, ms: 0, notes: @[],
                          segments: @[], turnId: sid, streaming: true)
        for n in notes: ds.notes.add n
        ds.notes.add snote
        ds.notes.add "STREAMING: this answer is a receipt, not the reply. " &
          "The sentences are spoken as they arrive and reach the client as " &
          "`say` segments on the event stream; the last one carries " &
          "final:true. Set llmStreaming:false for the synchronous shape."
        ds.ms = wallMs() - t0
        streamed = true
        turnId = sid
        result = ds
        return
      notes.add "streaming did not start (" & snote &
                "); this turn was answered synchronously instead"
    gOuterSink = sink
    gStreamTags = @[]
    gStreamSegs = @[]
    var lnote = ""
    var cacheRead = -1
    var stopReason = ""
    var full = ""
    if llmHasFake():
      full = llmFakeSyncComplete(llmSinkWrapper, lnote)
    else:
      full = llmComplete(sys, usr, llmSinkWrapper, lnote, cacheRead, stopReason)
    gOuterSink = nil
    gLastCacheRead = cacheRead
    if lnote.len > 0: notes.add lnote
    if stopReason == "refusal":
      notes.add "the model refused (stop_reason=refusal); serving the " &
                "ontology fallback row instead, which is not a language model"
    elif full.len > 0:
      var d = Decision(text: "", tags: @[], tier: "llm", cached: false,
                       engine: engine, ms: 0, notes: @[], segments: @[],
                       turnId: 0, streaming: false)
      for t in gStreamTags:
        let n = tagName(t)
        if modelForbiddenTag(n):
          notes.add "dropped [" & n & "] -- the encounter machine emits that " &
                    "tag, a model never does"
        elif isKnownTag(n): d.tags.add t
        else:
          notes.add "dropped unknown tag [" & n & "] -- not in the tag grammar; " &
                    "it was stripped from the spoken line and not acted on"
      var joined = ""
      for sgm in gStreamSegs:
        if joined.len > 0: joined.add " "
        joined.add sgm
      d.text = joined
      d.segments = gStreamSegs
      for n in notes: d.notes.add n
      gNLlm = gNLlm + 1
      gTick = gTick + 1
      gKey.add key; gText.add d.text; gTags.add joinTags(d.tags)
      gTier.add "llm"; gUsed.add gTick
      evictLru(); persist()
      d.ms = wallMs() - t0
      result = d
      return
    else:
      notes.add "the llm tier produced nothing; falling through to builtin"

  # ---- tier 3: builtin (the ontology's fallback row)
  var reply = ""
  var fbTags: seq[string] = @[]
  if not ontologyFallback(c, s, utterance, reply, fbTags):
    reply = "..."
    notes.add "no fallback row loaded (" & ontologyNote() &
              ") -- serving an ellipsis rather than silence"
  notes.add "tier=builtin: a template row from data/ontology.json. It is " &
            "not a language model. Set llmEngine to anthropic (with " &
            "ANTHROPIC_API_KEY in the environment) or llamacpp for real " &
            "generation."
  var d = decideFromRaw(reply, "builtin", engine, fbTags, sink, notes)
  gNBuiltin = gNBuiltin + 1
  gTick = gTick + 1
  gKey.add key; gText.add d.text; gTags.add joinTags(d.tags)
  gTier.add "builtin"; gUsed.add gTick
  evictLru(); persist()
  d.ms = wallMs() - t0
  result = d

# ------------------------------------------------------------------ stats

proc brainStats*(): JsonObject =
  var tiers = obj()
  tiers.put("cache", gNCache)
  tiers.put("ontology", gNOntology)
  tiers.put("llm", gNLlm)
  tiers.put("builtin", gNBuiltin)
  result = obj()
  result.put("hits", gHits)
  result.put("misses", gMiss)
  result.put("entries", gKey.len)
  result.put("maxEntries", cCacheMax)
  result.put("tiers", done(tiers))
  result.put("lastCacheReadInputTokens", gLastCacheRead)
  result.put("streamsStarted", gNStream)
  result.put("streamsInFlight", gSId.len)
  result.put("streamTimeouts", gNTimeout)
  result.put("engine", llmEngine())
  result.put("minConfidence", cMinConfidence)
  result.put("memoryTurns", cMemoryTurns)
  result.put("keyedOn", "personId, normalized utterance, situation signature, engine, voice -- NOT conversation memory")
  result.put("cacheNote", gLoadNote)
  result.put("ontology", ontologyNote())

proc decisionJson*(d: Decision): JsonObject =
  var tagsA = arr()
  for t in d.tags: tagsA.add t
  var notesA = arr()
  for n in d.notes: notesA.add n
  var segsA = arr()
  for s in d.segments: segsA.add s
  result = obj()
  result.put("text", d.text)
  result.put("tags", done(tagsA))
  result.put("tier", d.tier)
  result.put("cached", d.cached)
  result.put("engine", d.engine)
  result.put("ms", int(d.ms))
  result.put("notes", done(notesA))
  result.put("segments", done(segsA))
  result.put("turnId", d.turnId)
  result.put("streaming", d.streaming)
