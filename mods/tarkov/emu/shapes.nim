## Type-shape repair for values already PERSISTED in a saved profile.
##
## Why this module exists, measured 2026-08-31. The client threw
##
##     error reading integer. unexpected token: Boolean.
##     Path '[0].Quests[558].availableAfter'
##
## because `emu/quests.setState` wrote `availableAfter` as a BOOLEAN. That
## writer is fixed. It is still only half a fix: the bad value is **on disk**,
## in `store/aowl.tarkov/profile.<id>`, and a saved profile outlives any number
## of code fixes. A player whose save carries the boolean keeps hitting the same
## dialog after we ship the fix, and nothing in the host log says why.
##
## Newtonsoft does not degrade on a shape mismatch -- it THROWS, out of the
## client's own request handling, and the player gets a modal dialog. So the
## cost of one wrong-typed scalar is a dead session, and this is the second such
## defect in one day (the admintrader's `items_sell` reusing the buy-side shape
## was the first). That is a class of bug, not an incident.
##
## THE RULE IS MEASURED, NOT GUESSED. Every entry in `ScalarShapes` names an
## allowed SET of JSON kinds derived by byte-scanning the real database:
##
##     python tools/fieldshape.py D:/Aowlspt/aowlspt/db.json availableAfter
##       -> 801 occurrences, 801 number (758 of them 0), zero boolean
##          VERDICT: MONOMORPHIC -- allowed set is {number}
##
## A SET and not a single kind, because stock data is genuinely polymorphic in
## places and a rule written from one observation condemns valid data:
##
##     python tools/fieldshape.py D:/Aowlspt/aowlspt/db.json insurance_price_coef
##       -> 37 occurrences, 20 string and 17 number
##          VERDICT: POLYMORPHIC -- allowed set is {number, string}
##
## `insurance_price_coef` is in the table below with BOTH kinds allowed, so it
## documents the polymorphism and can never be "repaired" into uniformity. It is
## there as the counter-example that keeps the next author honest.
##
## ADDING THE NEXT FIELD IS ONE LINE. Run `tools/fieldshape.py`, paste its
## verdict into a new `ShapeRule` in `ScalarShapes`, done -- no count to bump
## (the array length is inferred), no scanner to touch.
##
## Text surgery, not reserialisation, for the same reason as `replaceValue` in
## `emu/profile`: the profile holds fields this emulator does not model and a
## round trip through a builder would drop every one of them. It also means the
## scan reaches values inside ARRAYS -- `Quests[558].availableAfter` is one of
## 559 siblings and no dotted-path helper here addresses it.

import std/strutils
import aowlspt

type
  ValueKind* = enum
    ## The six JSON value kinds, plus the one that means "the document is not
    ## shaped the way a scanner can read here". `vkUnknown` is never repaired:
    ## three outcomes, not two.
    vkString, vkNumber, vkBool, vkNull, vkObject, vkArray, vkUnknown

  ShapeRule* = object
    field*: string          ## the JSON key, matched in KEY position only
    allowed*: set[ValueKind] ## every kind stock data is measured to use
    repair*: string         ## JSON literal to write instead; "" = REFUSE, log only
    why*: string            ## the measurement, so the rule can be re-checked

const ScalarShapes* = [
  ShapeRule(field: "availableAfter", allowed: {vkNumber}, repair: "0",
            why: "801/801 in db.json are numbers, 758 of them 0; the boolean " &
                 "came from emu/quests.setState before 9554755"),
  # Present to DOCUMENT polymorphism, never to repair it. Both kinds are stock,
  # so this rule can only ever fire on a third kind -- which would be real news.
  ShapeRule(field: "insurance_price_coef", allowed: {vkNumber, vkString},
            repair: "",
            why: "37/37 in db.json: 20 string, 17 number. A rule naming one " &
                 "kind would condemn 5 of 12 traders' valid data"),
]

proc kindAt(text: string; i: int): (ValueKind, int) =
  ## The kind of the value token starting at `i`, and the index one past it.
  ## For containers only the opening brace is consumed: this module repairs
  ## SCALARS, and a container appearing where a scalar belongs is reported, not
  ## rewritten.
  if i >= text.len:
    return (vkUnknown, i)
  case text[i]
  of '"':
    var j = i + 1
    while j < text.len:
      if text[j] == '\\':
        j += 2
        continue
      if text[j] == '"':
        return (vkString, j + 1)
      inc j
    return (vkUnknown, text.len)
  of 't':
    if i + 4 <= text.len and text.substr(i, i + 3) == "true":
      return (vkBool, i + 4)
    return (vkUnknown, i + 1)
  of 'f':
    if i + 5 <= text.len and text.substr(i, i + 4) == "false":
      return (vkBool, i + 5)
    return (vkUnknown, i + 1)
  of 'n':
    if i + 4 <= text.len and text.substr(i, i + 3) == "null":
      return (vkNull, i + 4)
    return (vkUnknown, i + 1)
  of '{': return (vkObject, i + 1)
  of '[': return (vkArray, i + 1)
  of '-', '+', '.', '0'..'9':
    var j = i
    while j < text.len and (text[j] in {'-', '+', '.', 'e', 'E'} or
                            text[j] in {'0'..'9'}):
      inc j
    return (vkNumber, j)
  else:
    return (vkUnknown, i + 1)

proc kindName*(k: ValueKind): string =
  case k
  of vkString: "string"
  of vkNumber: "number"
  of vkBool: "boolean"
  of vkNull: "null"
  of vkObject: "object"
  of vkArray: "array"
  of vkUnknown: "unreadable"

proc allowedNames*(s: set[ValueKind]): string =
  ## "number|string" -- for a refusal message that has to say what WAS allowed.
  result = ""
  # An explicit list rather than `for k in ValueKind`: nimony has no iterator
  # over an enum TYPE, and the compiler's message for that ("expected
  # openArray[T] but got typedesc") does not say so.
  const All = [vkString, vkNumber, vkBool, vkNull, vkObject, vkArray, vkUnknown]
  for k in All:
    if k in s:
      if result.len > 0: result.add "|"
      result.add kindName(k)

proc valueAfterKey(text: string; keyEnd: int): (bool, int, ValueKind, int) =
  ## Given the index one past a closing `"` of a candidate key, answer
  ## `(isAKey, valueStart, kind, valueEnd)`.
  ##
  ## Factored out because the two callers below both need it AND because nimony
  ## rejects a `continue` inside a `while true` nested in a `for` -- codegen
  ## fails with `[Error] unreachable: (continue@i,2g,emu/shapes.nim .)`, an
  ## internal label with no line number. Folding the guards into one return
  ## makes each loop body a single `if`. (Toolchain rough edge, worth reporting:
  ## the message names neither the construct nor the source line.)
  var j = keyEnd
  while j < text.len and text[j] in {' ', '\t', '\r', '\n'}: inc j
  if j >= text.len or text[j] != ':':
    return (false, 0, vkUnknown, 0)
  inc j
  while j < text.len and text[j] in {' ', '\t', '\r', '\n'}: inc j
  let (kind, last) = kindAt(text, j)
  result = (true, j, kind, last)

proc isKeyPosition(text: string; quoteAt: int): bool =
  ## The previous non-space byte must open an object or a pair. Without this, a
  ## string VALUE that happens to read "availableAfter" would be treated as a
  ## field and the byte after it rewritten.
  var k = quoteAt - 1
  while k >= 0 and text[k] in {' ', '\t', '\r', '\n'}: dec k
  result = k >= 0 and text[k] in {'{', ','}

type
  ShapeFinding* = object
    ## One value that did not match its rule. `repaired` is the third outcome:
    ## a finding with `repaired == false` was NOT fixed and is still on disk.
    field*: string
    found*: ValueKind
    oldText*: string
    newText*: string
    repaired*: bool

proc checkScalarShapes*(text: string): seq[ShapeFinding] =
  ## Every value in `text` whose kind is outside its rule's allowed set, with
  ## no mutation. Separated from the repair so a caller can ASK without writing,
  ## and so the acceptance test can assert on the finding list.
  result = @[]
  for rule in ScalarShapes:
    let needle = "\"" & rule.field & "\""
    var at = 0
    while true:
      let i = text.find(needle, at)
      if i < 0: break
      at = i + needle.len
      if isKeyPosition(text, i):
        let (isKey, vstart, kind, last) = valueAfterKey(text, at)
        if isKey and kind notin rule.allowed:
          result.add ShapeFinding(
            field: rule.field, found: kind,
            oldText: text.substr(vstart, last - 1), newText: rule.repair,
            repaired: rule.repair.len > 0 and
                      kind in {vkBool, vkNull, vkString, vkNumber})

proc repairScalarShapes*(text: var string): seq[ShapeFinding] =
  ## Rewrites every repairable finding in place and returns ALL findings --
  ## including the ones it refused, which the caller must log at error level.
  ##
  ## Rewrites right-to-left so an earlier splice cannot move a later offset.
  ## Deliberately narrow: only a SCALAR is ever replaced. An object or array
  ## sitting where a number belongs is a different bug with a different repair,
  ## and silently flattening it would destroy data while reporting success.
  result = @[]
  # ONE scan collecting (start, end, literal), then splice DESCENDING so an
  # earlier rewrite can never move a later offset. The obvious alternative --
  # rescan after each fix -- is O(n^2) over a megabyte document with 559
  # candidate sites, i.e. hundreds of megabytes scanned on every profile load.
  var starts: seq[int] = @[]
  var ends: seq[int] = @[]
  var lits: seq[string] = @[]
  for rule in ScalarShapes:
    let needle = "\"" & rule.field & "\""
    var at = 0
    while true:
      let i = text.find(needle, at)
      if i < 0: break
      at = i + needle.len
      if isKeyPosition(text, i):
        let (isKey, vstart, kind, last) = valueAfterKey(text, at)
        if isKey and kind notin rule.allowed:
          let old = text.substr(vstart, last - 1)
          if rule.repair.len == 0 or kind in {vkObject, vkArray, vkUnknown}:
            result.add ShapeFinding(field: rule.field, found: kind,
                                    oldText: old, newText: "", repaired: false)
          else:
            starts.add vstart
            ends.add last
            lits.add rule.repair
            result.add ShapeFinding(field: rule.field, found: kind,
                                    oldText: old, newText: rule.repair,
                                    repaired: true)
  # Descending by start offset. Insertion sort: the list is already grouped per
  # rule and ascending within a rule, and there are only a handful of rules.
  # Selection sort rather than an insertion into a seq: nimony has no
  # `seq.insert`. There are only a few hundred sites, so O(n^2) here is nothing
  # next to the string splices themselves.
  var order: seq[int] = @[]
  var taken: seq[bool] = @[]
  for idx in 0 ..< starts.len: taken.add false
  for round in 0 ..< starts.len:
    var best = -1
    for idx in 0 ..< starts.len:
      if taken[idx]: continue
      if best < 0 or starts[idx] > starts[best]: best = idx
    if best < 0: break
    taken[best] = true
    order.add best
  for idx in order:
    text = text.substr(0, starts[idx] - 1) & lits[idx] & text.substr(ends[idx])

proc summarise*(findings: seq[ShapeFinding]): string =
  ## One line per (field, old-kind, new-value) with a COUNT -- a silent repair
  ## is how you lose track of what your saves contain, and 559 identical lines
  ## is the same as no line at all.
  # Counts kept beside the keys rather than parsed back out of the formatted
  # string: `parseInt` is `.raises` and nimony refuses it outside a try block,
  # and re-parsing your own output is the sort of round trip that quietly loses
  # a count anyway.
  var keys: seq[string] = @[]
  var counts: seq[int] = @[]
  for f in findings:
    var key = f.field & ": " & kindName(f.found) & " " & f.oldText
    if f.repaired: key.add " -> " & f.newText
    else: key.add " -> REFUSED (not a scalar this rule can repair)"
    var hit = -1
    for idx in 0 ..< keys.len:
      if keys[idx] == key:
        hit = idx
        break
    if hit >= 0:
      counts[hit] = counts[hit] + 1
    else:
      keys.add key
      counts.add 1
  result = ""
  for idx in 0 ..< keys.len:
    if result.len > 0: result.add "; "
    result.add keys[idx] & " x" & $counts[idx]

# ---------------------------------------------------------------------------
# Acceptance
# ---------------------------------------------------------------------------

proc selfCheckShapes*(into: var seq[string]) =
  ## Pure over literals, no database and no server. Registered in
  ## `emu/selfchecks`.
  ##
  ## Written to §9b: the assertions are about the FINISHED DOCUMENT, and three
  ## of the five are NEGATIVE -- "no boolean availableAfter survives", "a valid
  ## document comes back byte-identical", "a string insurance_price_coef is not
  ## touched". A check that only re-read its own write is exactly the defect
  ## this file exists to catch, so it does not do that.

  # 1. The measured live failure, reproduced: the boolean at Quests[558].
  var doc = "{\"Quests\":[{\"qid\":\"a\",\"availableAfter\":0}," &
            "{\"qid\":\"b\",\"availableAfter\":false}," &
            "{\"qid\":\"c\",\"availableAfter\":true}]}"
  let before = doc
  let found = repairScalarShapes(doc)
  if found.len != 2:
    into.add "shapes: expected 2 findings in the reproduced live document, got " &
             $found.len
  if doc.contains("\"availableAfter\":false") or
     doc.contains("\"availableAfter\":true"):
    into.add "shapes: a BOOLEAN availableAfter survived the repair -- this is " &
             "the exact value that threw \"error reading integer. unexpected " &
             "token: Boolean\" live on 2026-08-31"
  if doc != "{\"Quests\":[{\"qid\":\"a\",\"availableAfter\":0}," &
            "{\"qid\":\"b\",\"availableAfter\":0}," &
            "{\"qid\":\"c\",\"availableAfter\":0}]}":
    into.add "shapes: repaired document is not the expected text: " & doc

  # 2. A document that was already correct must come back BYTE-IDENTICAL. A
  #    repair that rewrites valid data is worse than no repair.
  var clean = "{\"Quests\":[{\"availableAfter\":0},{\"availableAfter\":86400}]}"
  let cleanBefore = clean
  let none = repairScalarShapes(clean)
  if none.len != 0:
    into.add "shapes: reported " & $none.len & " findings on a document whose " &
             "availableAfter values are all numbers"
  if clean != cleanBefore:
    into.add "shapes: rewrote a document that needed no repair"

  # 3. Polymorphism is not a defect. `insurance_price_coef` is a STRING in 5 of
  #    12 stock traders and a number in the other 7 (tools/fieldshape.py), so a
  #    rule that "normalised" it would condemn valid data.
  var poly = "{\"insurance_price_coef\":\"17\",\"b\":{\"insurance_price_coef\":10}}"
  let polyBefore = poly
  let polyFound = repairScalarShapes(poly)
  if polyFound.len != 0 or poly != polyBefore:
    into.add "shapes: touched insurance_price_coef, which stock data uses as " &
             "BOTH string and number -- the rule is too strict"

  # 4. The field name appearing as a string VALUE must not be treated as a key.
  var decoy = "{\"note\":\"availableAfter\",\"availableAfter\":0}"
  let decoyBefore = decoy
  discard repairScalarShapes(decoy)
  if decoy != decoyBefore:
    into.add "shapes: rewrote past a field name that appeared as a VALUE"

  # 5. A non-scalar where a number belongs is REFUSED, not flattened, and the
  #    refusal is reported so it reaches the log.
  var weird = "{\"availableAfter\":{\"x\":1}}"
  let weirdFound = repairScalarShapes(weird)
  if weirdFound.len != 1 or weirdFound[0].repaired:
    into.add "shapes: an OBJECT at availableAfter should be reported and " &
             "refused, not repaired"
  if weird != "{\"availableAfter\":{\"x\":1}}":
    into.add "shapes: flattened a non-scalar value instead of refusing"
  if before.len == 0:
    into.add "shapes: the reproduced live document was empty; check 1 proved nothing"
