## bm/ontology — tier 1: a typed `intent x stance-bucket` table, in data.
##
## Say plainly what this is, because the word "ontology" invites the wrong
## picture: it is a LOOKUP. Patterns classify an utterance into one of the
## intents in `data/ontology.json`; the person's attitude and their faction's
## standing pick one of five stance buckets; the (intent, bucket) pair selects a
## row with a template string and a fixed tag set. There is no graph, no
## inference, no model. It is deterministic and sub-millisecond, which is the
## entire point: most lines in a survival world are the same twenty lines.
##
## Every reply from here is marked `tier:"ontology"` by the brain, and the
## `fallback` rows (served by the `builtin` tier) carry `notALanguageModel` in
## the data itself so the honesty cannot be edited out of the code alone.

import std/strutils
import aowlspt/json as jr
import util
import prompt

# Parallel seqs; no std/tables. Literal initialisers only (DLL globals).
var gIntentId: seq[string] = @[]
var gIntentPatterns: seq[string] = @[]   ## "\x1f"-joined, all normalised

var gRowIntent: seq[string] = @[]
var gRowBucket: seq[string] = @[]
var gRowText: seq[string] = @[]
var gRowTags: seq[string] = @[]          ## "\x1f"-joined

var gRowYell: seq[string] = @[]          ## unit-separator-joined SHOUTED variants, may be empty

# The proactive bark tables (`barks` in ontology.json): trigger x bucket ->
# four-plus plain lines and their shouted variants. These are NOT replies --
# nothing the player said selects one. They are what a person says on their own
# initiative when the encounter machine notices something.
var gBarkTrigger: seq[string] = @[]
var gBarkBucket: seq[string] = @[]
var gBarkText: seq[string] = @[]         ## unit-separator-joined
var gBarkYell: seq[string] = @[]         ## unit-separator-joined

# The OFFSCREEN narrative table (`offscreen` in ontology.json): one row per
# event kind (fight, trade, meet, loot, hunt), each with four-plus one-line
# templates over the slots {a} {b} {place} {extra}. bm/offscreen resolves an
# encounter with no client and no model; this is where the sentence it writes
# into the journal comes from, so the set of things the world can SAY about
# itself stays in data.
var gOffEvent: seq[string] = @[]
var gOffText: seq[string] = @[]          ## unit-separator-joined

var gFbBucket: seq[string] = @[]
var gFbText: seq[string] = @[]
var gFbTags: seq[string] = @[]

var gLoaded: bool = false
var gLoadNote: string = "not loaded"

proc ontologyIntentCount*(): int = gIntentId.len
proc ontologyRowCount*(): int = gRowIntent.len
proc ontologyOffscreenRowCount*(): int = gOffEvent.len
proc ontologyFallbackCount*(): int = gFbBucket.len
proc ontologyBarkRowCount*(): int = gBarkTrigger.len
proc ontologyLoaded*(): bool = gLoaded
proc ontologyNote*(): string = gLoadNote

proc joinSep(items: seq[string]): string =
  result = ""
  for it in items:
    if result.len > 0: result.add "\x1f"
    result.add it

proc splitSep(s: string): seq[string] =
  result = @[]
  var cur = ""
  for ch in s:
    if ch == '\x1f':
      if cur.len > 0: result.add cur
      cur = ""
    else:
      cur.add ch
  if cur.len > 0: result.add cur

proc textsOf(j: JsonRef): seq[string] =
  result = @[]
  let items = jr.each(j)
  for e in items:
    let t = jr.asText(e, "")
    if t.len > 0: result.add t

proc ontologyLoad*(text: string; note: var string): bool =
  ## Reads `data/ontology.json`. Returns false with a note a person can act on;
  ## an empty table is never reported as a successful load.
  gIntentId = @[]; gIntentPatterns = @[]
  gRowIntent = @[]; gRowBucket = @[]; gRowText = @[]; gRowTags = @[]
  gRowYell = @[]
  gFbBucket = @[]; gFbText = @[]; gFbTags = @[]
  gBarkTrigger = @[]; gBarkBucket = @[]; gBarkText = @[]; gBarkYell = @[]
  gOffEvent = @[]; gOffText = @[]
  gLoaded = false
  if text.len == 0:
    note = "ontology.json is missing or empty -- the ontology tier will never fire"
    gLoadNote = note
    return false

  let intentItems = jr.each(jr.field(text, "intents"))
  for it in intentItems:
    let id = jr.asText(jr.child(it, "id"), "")
    if id.len == 0: continue
    var pats: seq[string] = @[]
    let rawPats = textsOf(jr.child(it, "patterns"))
    for p in rawPats:
      let n = normalizeText(p)
      if n.len > 0: pats.add n
    gIntentId.add id
    gIntentPatterns.add joinSep(pats)

  let rowItems = jr.each(jr.field(text, "rows"))
  for r in rowItems:
    let i = jr.asText(jr.child(r, "intent"), "")
    let b = jr.asText(jr.child(r, "bucket"), "")
    let t = jr.asText(jr.child(r, "text"), "")
    if i.len == 0 or b.len == 0 or t.len == 0: continue
    var variants = @[t]
    for a in textsOf(jr.child(r, "alts")):
      if a.len > 0: variants.add a
    gRowIntent.add i
    gRowBucket.add b
    gRowText.add joinSep(variants)
    gRowTags.add joinSep(textsOf(jr.child(r, "tags")))
    gRowYell.add joinSep(textsOf(jr.child(r, "yell")))

  let barkItems = jr.each(jr.field(text, "barks"))
  for bk in barkItems:
    let tg = jr.asText(jr.child(bk, "trigger"), "")
    let bb = jr.asText(jr.child(bk, "bucket"), "")
    let texts = textsOf(jr.child(bk, "texts"))
    if tg.len == 0 or bb.len == 0 or texts.len == 0: continue
    gBarkTrigger.add tg
    gBarkBucket.add bb
    gBarkText.add joinSep(texts)
    gBarkYell.add joinSep(textsOf(jr.child(bk, "yell")))

  let offItems = jr.each(jr.field(text, "offscreen"))
  for ov in offItems:
    let ev = jr.asText(jr.child(ov, "event"), "")
    let texts = textsOf(jr.child(ov, "texts"))
    if ev.len == 0 or texts.len == 0: continue
    gOffEvent.add ev
    gOffText.add joinSep(texts)

  let fbItems = jr.each(jr.field(text, "fallback"))
  for f in fbItems:
    let b = jr.asText(jr.child(f, "bucket"), "")
    let t = jr.asText(jr.child(f, "text"), "")
    if b.len == 0 or t.len == 0: continue
    var fvariants = @[t]
    for a in textsOf(jr.child(f, "alts")):
      if a.len > 0: fvariants.add a
    gFbBucket.add b
    gFbText.add joinSep(fvariants)
    gFbTags.add joinSep(textsOf(jr.child(f, "tags")))

  if gIntentId.len == 0 or gRowIntent.len == 0:
    note = "ontology.json parsed but produced " & $gIntentId.len &
           " intents and " & $gRowIntent.len &
           " rows -- check the 'intents' and 'rows' arrays"
    gLoadNote = note
    return false
  gLoaded = true
  var variantN = 0
  var thinRows = 0
  for rt in gRowText:
    let n = splitSep(rt).len
    variantN = variantN + n
    if n < 4: thinRows = thinRows + 1
  var barkLines = 0
  var thinBarks = 0
  for bt in gBarkText:
    let n = splitSep(bt).len
    barkLines = barkLines + n
    if n < 4: thinBarks = thinBarks + 1
  note = $gIntentId.len & " intents, " & $gRowIntent.len & " rows, " &
         $variantN & " lines, " & $thinRows & " row(s) with fewer than 4, " &
         $gFbBucket.len & " fallback rows, " & $gBarkTrigger.len &
         " bark rows (" & $barkLines & " bark lines, " & $thinBarks &
         " with fewer than 4), " & $gOffEvent.len & " offscreen event row(s)"
  gLoadNote = note
  result = true

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

proc wordCount(s: string): int =
  result = 0
  var inWord = false
  for ch in s:
    if ch == ' ':
      inWord = false
    else:
      if not inWord: result = result + 1
      inWord = true

proc classifyIntent*(utterance: string; confidence: var float): string =
  ## Longest-phrase-wins keyword matching. A pattern scores its own word count,
  ## so "who are you" (3) beats a bare "you" and "dont move" beats "move".
  ## `confidence` is that score scaled by how much of the utterance it covers,
  ## clamped to [0,1]; a line matching nothing comes back "unknown" with 0.0 --
  ## which is what lets the nonsense case fall through to the next tier instead
  ## of being answered confidently by a table.
  confidence = 0.0
  let norm = normalizeText(utterance)
  if norm.len == 0 or not gLoaded: return "unknown"
  let uw = wordCount(norm)
  var bestId = "unknown"
  var bestScore = 0
  var i = 0
  while i < gIntentId.len:
    var score = 0
    let pats = splitSep(gIntentPatterns[i])
    for p in pats:
      if containsWord(norm, p):
        let w = wordCount(p)
        if w > score: score = w
    if score > bestScore:
      bestScore = score
      bestId = gIntentId[i]
    i = i + 1
  if bestScore == 0: return "unknown"
  # coverage: a 1-word match inside a 12-word sentence is a weak signal.
  var cov = 1.0
  if uw > 0: cov = float(bestScore) / float(uw)
  var conf = 0.45 + 0.35 * float(clampI(bestScore, 1, 3)) / 3.0 + 0.35 * cov
  confidence = clampF(conf, 0.0, 1.0)
  result = bestId

proc stanceBucket*(attitude, factionRep: int): string =
  ## One number out of two: the person's own attitude counts double their
  ## faction's standing, because a friend in a hostile faction still talks to
  ## you like a friend.
  let blended = (attitude * 2 + factionRep) div 3
  if blended <= -50: return "hostile"
  if blended <= -15: return "wary"
  if blended < 20: return "neutral"
  if blended < 60: return "warm"
  result = "loyal"

# ---------------------------------------------------------------------------
# Reply
# ---------------------------------------------------------------------------

proc fillSlots(tpl: string; c: PersonCard): string =
  var want = c.wants
  # `wants` may be a comma list; a template wants one thing, not a list.
  let comma = want.find(',')
  if comma > 0: want = want[0 ..< comma]
  want = want.strip()
  if want.len == 0: want = "anything worth carrying"
  var place = c.placeName
  if place.len == 0: place = (if c.map.len > 0: c.map else: "the camp")
  var fac = c.faction
  if fac.len == 0: fac = "nobody in particular"
  var nm = c.name
  if nm.len == 0: nm = "nobody you need to know"
  # The objective clause goes in verbatim, lower case and all: the row texts
  # are written to read correctly with a lower-case clause dropped into them,
  # which is cheaper and less breakable than case-fixing a sentence here.
  var s = tpl.replace("{objective}", c.objective)
  s = s.replace("{name}", nm)
  s = s.replace("{faction}", fac)
  s = s.replace("{want}", want)
  s = s.replace("{place}", place)
  result = s

proc pickVariant(joined, personId, utterance: string): string =
  ## Deterministic per (person, thing said): the same person answers the same
  ## way twice, and two different people standing in the same doorway do not
  ## say one identical sentence. It is a hash, NOT randomness -- a reply that
  ## changed between two identical turns would make the line cache a liar.
  let vs = splitSep(joined)
  if vs.len == 0: return ""
  if vs.len == 1: return vs[0]
  let h = fnv1a64(personId & "\x1f" & normalizeText(utterance))
  result = vs[int(h mod uint64(vs.len))]

proc bucketFor*(c: PersonCard; s: Situation): string =
  ## The stance bucket a REPLY is served from, which is not always the stance
  ## bucket of the relationship: a person with a rifle pointed at them does not
  ## answer a greeting warmly, whatever they think of you. MEASURED 2026-09-07:
  ## without this floor a greeting to a threatened person came back through the
  ## warm/neutral row and read as if nothing was happening.
  var b = stanceBucket(c.attitude, c.factionRep)
  if s.state == "threatened" or s.state == "fighting" or s.playerAiming:
    if b == "neutral" or b == "warm" or b == "loyal": b = "wary"
  result = b

proc findRow(intent, bucket: string): int =
  result = -1
  var i = 0
  while i < gRowIntent.len:
    if gRowIntent[i] == intent and gRowBucket[i] == bucket: return i
    i = i + 1

proc findFallback(bucket: string): int =
  result = -1
  var i = 0
  while i < gFbBucket.len:
    if gFbBucket[i] == bucket: return i
    i = i + 1

proc ontologyReply*(intent: string; c: PersonCard; s: Situation;
                    utterance: string; reply: var string;
                    tags: var seq[string]): bool =
  ## false when there is no row for this (intent, bucket) -- the caller must
  ## then fall through to the next tier rather than inventing something.
  reply = ""
  if not gLoaded: return false
  let bucket = bucketFor(c, s)
  # A person with NO objective must not be served the row that describes one:
  # "{objective}" would render empty and the line would read as an answer.
  # Falling through to the next tier is the honest outcome.
  if intent == "ask_activity" and c.objective.len == 0: return false
  let idx = findRow(intent, bucket)
  if idx < 0: return false
  reply = fillSlots(pickVariant(gRowText[idx], c.id, utterance), c)
  let rowTags = splitSep(gRowTags[idx])
  for t in rowTags:
    tags.add fillSlots(t, c)
  # One situational rider, not a second table: someone aiming a gun at you
  # colours every line, whatever was said.
  if s.playerAiming and bucket == "hostile" and intent != "unknown":
    reply.add " Lower it or do not, it is the same to me."
  result = true

proc ontologyFallback*(c: PersonCard; s: Situation; utterance: string;
                       reply: var string; tags: var seq[string]): bool =
  ## The `builtin` tier's row. It is a TEMPLATE, not a language model, and the
  ## data says so (`notALanguageModel: true`); the caller must put that in the
  ## Decision's notes.
  reply = ""
  if not gLoaded: return false
  let bucket = bucketFor(c, s)
  var idx = findFallback(bucket)
  if idx < 0: idx = findFallback("neutral")
  if idx < 0: return false
  reply = fillSlots(pickVariant(gFbText[idx], c.id, utterance), c)
  let fbT = splitSep(gFbTags[idx])
  for t in fbT:
    tags.add fillSlots(t, c)
  result = true

# ---------------------------------------------------------------------------
# Yelling and proactive barks
# ---------------------------------------------------------------------------

proc ontologyYellFor*(text, personId: string): string =
  ## The SHOUTED variant of a line this table served, or "" when the row that
  ## produced it carries none. It is a reverse lookup on the exact variant
  ## text, so it cannot invent a shout for a line that came from the LLM: the
  ## caller must then fall back to its own rewrite AND say that it did.
  if not gLoaded or text.len == 0: return ""
  var i = 0
  while i < gRowText.len:
    if gRowYell[i].len > 0:
      for v in splitSep(gRowText[i]):
        if v == text:
          let ys = splitSep(gRowYell[i])
          let n = ys.len
          if n == 0: return ""
          return ys[int(fnv1a64("yell\x1f" & personId) mod uint64(n))]
    i = i + 1
  result = ""

proc findBark(trigger, bucket: string): int =
  result = -1
  var i = 0
  while i < gBarkTrigger.len:
    if gBarkTrigger[i] == trigger and gBarkBucket[i] == bucket: return i
    i = i + 1

proc ontologyBark*(trigger, bucket, personId, salt: string;
                   yell: bool; note: var string): string =
  ## One proactive line. Deterministic per (person, trigger, salt): `salt`
  ## is what makes the SECOND combat taunt from the same person differ from the
  ## first, and it is the caller's -- usually a rate-limit counter.
  ##
  ## Returns "" with a note when the table has no row; a caller must never
  ## substitute a line of its own for a missing row, because then the table is
  ## no longer the record of what people can say.
  note = ""
  if not gLoaded:
    note = "the ontology is not loaded (" & gLoadNote & ")"
    return ""
  var idx = findBark(trigger, bucket)
  if idx < 0:
    idx = findBark(trigger, "neutral")
    if idx >= 0: note = "no '" & bucket & "' row for trigger '" & trigger &
                        "'; used the neutral row"
  if idx < 0:
    note = "ontology.json has no bark row for trigger '" & trigger &
           "' in any bucket (" & $gBarkTrigger.len & " bark rows loaded)"
    return ""
  var pool = splitSep(gBarkText[idx])
  if yell:
    let ys = splitSep(gBarkYell[idx])
    if ys.len > 0: pool = ys
    else:
      note = (if note.len > 0: note & "; " else: "") &
             "trigger '" & trigger & "'/'" & bucket &
             "' has no yell variants; the spoken line is used unchanged"
  if pool.len == 0:
    note = "the bark row for '" & trigger & "'/'" & bucket & "' is empty"
    return ""
  let n = pool.len
  let h = fnv1a64(trigger & "\x1f" & personId & "\x1f" & salt)
  result = pool[int(h mod uint64(n))]

# ---------------------------------------------------------------------------
# Offscreen narratives
# ---------------------------------------------------------------------------

proc ontologyOffscreen*(event, salt, a, b, place, extra: string;
                        note: var string): string =
  ## One line describing something that happened where nobody was watching.
  ## Deterministic per (event, salt): re-running the same six hours from the
  ## same saved state must produce byte-identical journals, so a random pick
  ## here would break the determinism check -- which is exactly what that check
  ## is for.
  ##
  ## Returns "" WITH a note when the table has no row for the event. The caller
  ## must not substitute a sentence of its own without saying so: a narrative
  ## this code invented would not be in the record of what the world can say.
  note = ""
  if not gLoaded:
    note = "the ontology is not loaded (" & gLoadNote & ")"
    return ""
  var idx = -1
  var i = 0
  while i < gOffEvent.len:
    if gOffEvent[i] == event: idx = i
    i = i + 1
  if idx < 0:
    note = "ontology.json has no offscreen row for event '" & event & "' (" &
           $gOffEvent.len & " offscreen rows loaded)"
    return ""
  let pool = splitSep(gOffText[idx])
  if pool.len == 0:
    note = "the offscreen row for '" & event & "' is empty"
    return ""
  let h = fnv1a64("offscreen" & event & "" & salt)
  var line = pool[int(h mod uint64(pool.len))]
  line = line.replace("{a}", a)
  line = line.replace("{b}", b)
  line = line.replace("{place}", place)
  line = line.replace("{extra}", extra)
  result = line
