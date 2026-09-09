## The weighting primitive shared by world loot and bot-carried loot.
##
## World loot and bot loadouts are the same problem wearing two hats: something
## draws an item template out of a weighted pool, and an operator wants to say
## "more of this, less of that, never that, and only on Woods". Before this
## module each side grew its own multiplier fields, so `lootCategoryWeights`
## existed and `botCategoryWeights` did not, and the two could never be made to
## agree because there was nothing for them to agree *about*.
##
## So: ONE resolver. A `RuleSet` is a bag of `Rule`s; a `Subject` is one
## candidate item in one situation; `resolve` turns the pair into a weight, and
## `explain` turns it into the list of rules that produced that weight and why
## each one applied. Both callers build the same `Subject` shape -- the only
## difference between them is the `ctx` fields, which is exactly the difference
## between "in this crate" and "on this bot".
##
## ==========================================================================
## PRECEDENCE -- this is a DECISION, not a fact about the world
## ==========================================================================
##
## "Most specific wins" is a slogan; it does not say what happens when a map
## rule and an item rule both match, and a config system whose resolution order
## is undefined is worse than no config system. The order below is the whole
## contract, and `explain` prints it back for any subject so a misbehaving knob
## can be found rather than argued about.
##
## **Phase A -- GATES.** Every matching `opDrop` rule is considered first. One
## match removes the candidate outright and no weight rule can outvote it.
## Rationale: a drop is a statement about CONTENT ("this must not spawn"),
## while a weight is a statement about MIX. A rule that says "never spawn
## keycards" must not be defeated by an unrelated slider that happens to
## multiply keycards by 4. Drops are idempotent, so their relative order is
## unobservable and no tie-break is needed.
##
## **Phase B1 -- the BASE weight.** The pool's own `relativeProbability` is the
## base. If any `opSet` rule matches, exactly ONE of them replaces it: the one
## with the highest specificity score. Ties are broken by declaration order and
## the LAST declared wins, because rules are loaded named-sliders-first and
## free-text-last, and the advanced control is the one that should win when two
## controls disagree. Only one `opSet` ever applies -- two "set" rules that both
## took effect would mean the second silently discarded the first.
##
## **Phase B2 -- MULTIPLIERS.** Every matching `opMul` rule multiplies the base,
## all of them. Multiplication is commutative so the order is cosmetic; they are
## nonetheless applied and reported in descending specificity so `explain` reads
## from the most specific rule down. This is the axis that composes: a
## `base:Mod *0.5` and an `item:<a scope> *4` both apply, and that is intended --
## families and individuals are different statements about the same item.
##
## **Phase B3 -- CLAMPS.** `opFloor` raises and `opCeil` lowers, floor before
## ceiling, each taking the most specific match only. A floor above a ceiling is
## resolved in the ceiling's favour and `explain` says so.
##
## **Zero is a drop.** A weight that lands at or below zero removes the entry
## from the pool rather than keeping it at weight zero. `pick` would never
## return it either way, but a removed entry makes an EMPTY pool reachable,
## which is how a caller learns its whole pool was gated away instead of drawing
## forever from a dead list.
##
## ==========================================================================
## SPECIFICITY
## ==========================================================================
##
## A score, summed over three independent axes. Higher wins.
##
##   selector      item id .................... 1000
##                 handbook category ..........  400 - 10*depth
##                 base class .................  300 - 10*depth
##                 rarity band ................  100
##                 price band .................   50
##                 anything ...................    0
##   context       this exact container/bot ...  200
##                 this KIND of context .......  100
##                 any context ................    0
##   map           this exact map .............   50
##                 any map ....................    0
##
## `depth` is how far up the parent chain the match was found, so a rule on the
## item's immediate base class beats one on `Item`, the root every template
## descends from. The axes are additive and the selector range (1000/400/300)
## exceeds the sum of the other two (250), so **a selector can never be outvoted
## by context or map**: `item:<x> *2` always outranks `base:<y> @woods *2` for a
## `set`. That is deliberate; naming the item is the most specific thing an
## operator can do and it should read that way.
##
## ==========================================================================
## THE TEXT GRAMMAR
## ==========================================================================
##
## Named sliders cover the common cases (see `emu/lootcats`, generated from the
## database). Everything else is one free-text setting, `;`-separated:
##
##     item:<tplId> *2.0 @bigmap #container:<containerTpl>
##     base:<baseClassId> *0.5
##     hb:<handbookCatId> =10
##     rarity:superrare *3
##     price>50000 drop
##     price<500 *0.25
##     any *1.2 #bot:assault
##
## selector    `item:` `base:` `hb:` `rarity:` `price>` `price<` `any`
## operation   `*<n>` multiply, `=<n>` set, `drop`, `min<n>` floor, `max<n>` ceil
## map filter  `@<locationId>`   (optional, database location id)
## context     `#container:<tpl>` `#bot:<role>` `#loose` `#static` `#bot`
##             `#container` (the bare kind matches any member of that kind)
##
## A malformed clause is DROPPED and counted, never guessed at, and the count is
## reported by `summary` -- a typo must be visible rather than read as "that
## family now has no loot".

import std/strutils

type
  CtxKind* = enum
    ckAny        ## the rule does not care where the draw is happening
    ckStatic     ## inside a static container (crate, safe, jacket)
    ckLoose      ## a loose spawn point on the ground
    ckBot        ## going into a bot's inventory

  SelKind* = enum
    selAny
    selItem        ## exact template id
    selBase        ## a `_parent` base class anywhere on the chain
    selHb          ## a handbook category anywhere on its chain
    selRarity      ## the template's rarity band
    selPriceAbove  ## handbook price strictly greater than `num`
    selPriceBelow  ## handbook price strictly less than `num`

  RuleOp* = enum
    opMul
    opSet
    opDrop
    opFloor
    opCeil

  Rule* = object
    sel*: SelKind
    key*: string        ## the id or band the selector names; "" for price/any
    num*: float         ## the threshold, for the price selectors
    map*: string        ## "" = any map
    ctx*: string        ## "" = any specific context
    ctxKind*: CtxKind
    op*: RuleOp
    value*: float
    source*: string     ## the settings key or text clause this came from
    seq*: int           ## declaration order, for the `opSet` tie-break

  RuleSet* = object
    rules*: seq[Rule]
    dropped*: int       ## malformed text clauses
    n*: int             ## declaration counter

  Subject* = object
    ## One candidate, in one situation. Both callers fill the same shape; the
    ## bot side differs only in `ctxKind`/`ctx`.
    tpl*: string
    parents*: seq[string]   ## `_parent` chain, NEAREST FIRST, excluding `tpl`
    hb*: seq[string]        ## handbook category chain, nearest first
    rarity*: string         ## lowercased band, or ""
    price*: float           ## handbook price, or -1.0 when unlisted
    map*: string
    ctx*: string
    ctxKind*: CtxKind

  Outcome* = object
    weight*: float
    dropped*: bool
    matched*: int           ## how many rules applied
    reason*: string         ## set when `dropped`

proc newRuleSet*(): RuleSet =
  RuleSet(rules: @[], dropped: 0, n: 0)

proc len*(rs: RuleSet): int = rs.rules.len

# ---------------------------------------------------------------------------
# Building rules
# ---------------------------------------------------------------------------

proc add*(rs: var RuleSet; r: Rule) =
  var x = r
  x.seq = rs.n
  rs.n = rs.n + 1
  rs.rules.add x

proc mulRule*(sel: SelKind; key: string; value: float; source: string;
              map = ""; ctx = ""; ctxKind = ckAny; num = 0.0): Rule =
  Rule(sel: sel, key: key, num: num, map: map, ctx: ctx, ctxKind: ctxKind,
       op: opMul, value: value, source: source, seq: 0)

proc opRule*(sel: SelKind; key: string; op: RuleOp; value: float;
             source: string; map = ""; ctx = ""; ctxKind = ckAny;
             num = 0.0): Rule =
  Rule(sel: sel, key: key, num: num, map: map, ctx: ctx, ctxKind: ctxKind,
       op: op, value: value, source: source, seq: 0)

proc addMul*(rs: var RuleSet; sel: SelKind; key: string; value: float;
             source: string) =
  ## The named-slider path. A value of exactly 1.0 adds NOTHING -- not a rule
  ## worth 1.0 -- so a page nobody touched leaves the rule set empty and the
  ## whole resolver is skipped by `active`. That is what makes "defaults
  ## reproduce current behaviour" a property of the control flow rather than an
  ## argument about arithmetic.
  if value == 1.0:
    return
  var v = value
  if v < 0.0:
    v = 0.0
  rs.add mulRule(sel, key, v, source)

proc active*(rs: RuleSet): bool = rs.rules.len > 0

# ---------------------------------------------------------------------------
# Parsing the text grammar
# ---------------------------------------------------------------------------

proc parseNum(s: string; ok: var bool): float =
  ## A number out of text without raising. `parseFloat` is `.raises`, and a
  ## raising call here would drag a `try` into every config read; worse, a
  ## silent zero for a multiplier means "delete this family", so an
  ## unparseable value must be reportable as unparseable.
  ok = false
  if s.len == 0:
    return 0.0
  var i = 0
  var neg = false
  if s[i] == '-' or s[i] == '+':
    neg = s[i] == '-'
    inc i
  var digits = 0
  var whole = 0.0
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    whole = whole * 10.0 + float(ord(s[i]) - ord('0'))
    inc i
    inc digits
  var frac = 0.0
  var scale = 0.1
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      frac = frac + float(ord(s[i]) - ord('0')) * scale
      scale = scale * 0.1
      inc i
      inc digits
  if digits == 0 or i != s.len:
    return 0.0
  ok = true
  result = whole + frac
  if neg:
    result = -result

proc ctxKindOf(name: string): CtxKind =
  case name
  of "static", "container": ckStatic
  of "loose": ckLoose
  of "bot": ckBot
  else: ckAny

proc parseClause(text: string; r: var Rule): bool =
  ## One clause of the grammar into one rule. Returns false on anything it does
  ## not fully understand -- there is no partial acceptance, because a clause
  ## half-read is a rule the operator did not write.
  r = Rule(sel: selAny, key: "", num: 0.0, map: "", ctx: "", ctxKind: ckAny,
           op: opMul, value: 1.0, source: strip(text), seq: 0)
  var haveSel = false
  var haveOp = false
  for tokRaw in strip(text).split({' ', '\t'}):
    let tok = strip(tokRaw)
    if tok.len == 0:
      continue
    if tok[0] == '@':
      if tok.len < 2: return false
      r.map = tok.substr(1, tok.len - 1)
      continue
    if tok[0] == '#':
      if tok.len < 2: return false
      let body = tok.substr(1, tok.len - 1)
      var colon = -1
      for i in 0 ..< body.len:
        if body[i] == ':':
          colon = i
          break
      if colon < 0:
        r.ctxKind = ctxKindOf(toLowerAscii(body))
        if r.ctxKind == ckAny: return false
      else:
        r.ctxKind = ctxKindOf(toLowerAscii(body.substr(0, colon - 1)))
        if r.ctxKind == ckAny: return false
        r.ctx = body.substr(colon + 1, body.len - 1)
        if r.ctx.len == 0: return false
      continue
    if tok[0] == '*' or tok[0] == '=':
      if haveOp: return false
      var ok = false
      let v = parseNum(tok.substr(1, tok.len - 1), ok)
      if not ok or v < 0.0: return false
      r.op = (if tok[0] == '*': opMul else: opSet)
      r.value = v
      haveOp = true
      continue
    let low = toLowerAscii(tok)
    if low == "drop":
      if haveOp: return false
      r.op = opDrop
      r.value = 0.0
      haveOp = true
      continue
    if low.len > 3 and low.substr(0, 2) == "min":
      if haveOp: return false
      var ok = false
      let v = parseNum(tok.substr(3, tok.len - 1), ok)
      if not ok: return false
      r.op = opFloor
      r.value = v
      haveOp = true
      continue
    if low.len > 3 and low.substr(0, 2) == "max":
      if haveOp: return false
      var ok = false
      let v = parseNum(tok.substr(3, tok.len - 1), ok)
      if not ok: return false
      r.op = opCeil
      r.value = v
      haveOp = true
      continue
    # selectors
    if haveSel: return false
    if low == "any":
      r.sel = selAny
      haveSel = true
      continue
    if low.len > 6 and low.substr(0, 5) == "price>":
      var ok = false
      r.num = parseNum(tok.substr(6, tok.len - 1), ok)
      if not ok: return false
      r.sel = selPriceAbove
      haveSel = true
      continue
    if low.len > 6 and low.substr(0, 5) == "price<":
      var ok = false
      r.num = parseNum(tok.substr(6, tok.len - 1), ok)
      if not ok: return false
      r.sel = selPriceBelow
      haveSel = true
      continue
    var colon = -1
    for i in 0 ..< tok.len:
      if tok[i] == ':':
        colon = i
        break
    if colon <= 0 or colon >= tok.len - 1:
      return false
    let kind = toLowerAscii(tok.substr(0, colon - 1))
    let val = tok.substr(colon + 1, tok.len - 1)
    case kind
    of "item": r.sel = selItem
    of "base", "parent": r.sel = selBase
    of "hb", "cat", "category": r.sel = selHb
    of "rarity": r.sel = selRarity
    else: return false
    r.key = (if r.sel == selRarity: toLowerAscii(val) else: val)
    haveSel = true
  result = haveSel and haveOp

proc addRuleText*(rs: var RuleSet; text: string) =
  ## `;`-separated clauses. Newlines separate too, so the setting can be edited
  ## as a block of lines in a text editor and pasted back as one string.
  if strip(text).len == 0:
    return
  for part in text.multiReplace([("\r", ";"), ("\n", ";")]).split(';'):
    if strip(part).len == 0:
      continue
    var r = Rule(sel: selAny, key: "", num: 0.0, map: "", ctx: "",
                 ctxKind: ckAny, op: opMul, value: 1.0, source: "", seq: 0)
    if parseClause(part, r):
      rs.add r
    else:
      rs.dropped = rs.dropped + 1

# ---------------------------------------------------------------------------
# Matching and specificity
# ---------------------------------------------------------------------------

proc chainDepth(chain: seq[string]; key: string): int =
  ## Where on a chain the id sits, 0 = nearest, -1 = not on it.
  for i in 0 ..< chain.len:
    if chain[i] == key:
      return i
  result = -1

proc selectorScore(r: Rule; s: Subject; ok: var bool): int =
  ## The selector half of the specificity score, and whether it matched at all.
  ## One function does both so a selector can never match with one score and be
  ## ranked with another -- that split is how "most specific wins" becomes
  ## "whichever the two functions happened to agree on".
  ok = false
  case r.sel
  of selAny:
    ok = true
    result = 0
  of selItem:
    ok = r.key == s.tpl
    result = 1000
  of selBase:
    if r.key == s.tpl:
      ok = true
      result = 1000
    else:
      let d = chainDepth(s.parents, r.key)
      ok = d >= 0
      result = 300 - 10 * (if d < 0: 0 elif d > 25: 25 else: d)
  of selHb:
    let d = chainDepth(s.hb, r.key)
    ok = d >= 0
    result = 400 - 10 * (if d < 0: 0 elif d > 25: 25 else: d)
  of selRarity:
    ok = s.rarity.len > 0 and s.rarity == r.key
    result = 100
  of selPriceAbove:
    ok = s.price >= 0.0 and s.price > r.num
    result = 50
  of selPriceBelow:
    ok = s.price >= 0.0 and s.price < r.num
    result = 50

proc matches(r: Rule; s: Subject; score: var int): bool =
  ## Full match plus its specificity. Every filter is a CONJUNCTION: a rule with
  ## a map and a context must satisfy both.
  score = 0
  if r.map.len > 0:
    if r.map != s.map:
      return false
    score = score + 50
  if r.ctxKind != ckAny:
    if r.ctxKind != s.ctxKind:
      return false
    if r.ctx.len > 0:
      if r.ctx != s.ctx:
        return false
      score = score + 200
    else:
      score = score + 100
  elif r.ctx.len > 0:
    # a context id with no kind: match the id in whatever kind it appears
    if r.ctx != s.ctx:
      return false
    score = score + 200
  var ok = false
  let sc = selectorScore(r, s, ok)
  if not ok:
    return false
  score = score + sc
  result = true

proc beats(aScore, aSeq, bScore, bSeq: int): bool =
  ## Higher specificity wins; on an exact tie the LATER declaration wins.
  ## Rules are loaded named-sliders-first, free-text-last, so this is the
  ## documented "the advanced control beats the slider" rule expressed once.
  if aScore != bScore:
    return aScore > bScore
  result = aSeq > bSeq

# ---------------------------------------------------------------------------
# Resolving
# ---------------------------------------------------------------------------

proc resolveInto(rs: RuleSet; s: Subject; base: float;
                 trace: var seq[string]; wantTrace: bool): Outcome =
  result = Outcome(weight: base, dropped: false, matched: 0, reason: "")
  if rs.rules.len == 0:
    return

  # Phase A -- gates.
  for r in rs.rules:
    if r.op != opDrop:
      continue
    var sc = 0
    if matches(r, s, sc):
      result.dropped = true
      result.matched = result.matched + 1
      result.reason = "dropped by " & r.source
      if wantTrace:
        trace.add "  DROP    spec=" & $sc & "  " & r.source
      return

  # Phase B1 -- the single most specific `set`.
  var haveSet = false
  var setScore = 0
  var setSeq = 0
  var setVal = 0.0
  var setSrc = ""
  for r in rs.rules:
    if r.op != opSet:
      continue
    var sc = 0
    if not matches(r, s, sc):
      continue
    if not haveSet or beats(sc, r.seq, setScore, setSeq):
      haveSet = true
      setScore = sc
      setSeq = r.seq
      setVal = r.value
      setSrc = r.source
  if haveSet:
    result.weight = setVal
    result.matched = result.matched + 1
    if wantTrace:
      trace.add "  SET     spec=" & $setScore & "  -> " & $setVal &
                "  " & setSrc

  # Phase B2 -- every matching multiplier, reported most specific first.
  var mIdx: seq[int] = @[]
  var mScore: seq[int] = @[]
  for i in 0 ..< rs.rules.len:
    if rs.rules[i].op != opMul:
      continue
    var sc = 0
    if matches(rs.rules[i], s, sc):
      mIdx.add i
      mScore.add sc
  # Descending by (score, seq). The list is a handful of entries per subject;
  # a comparator-based sort would need a closure and `sort` from std/algorithm
  # pulls `.raises` in.
  # Selection sort into a fresh order, rather than swapping in place: the
  # in-place version is the obvious code and nimony refuses it (an element
  # write aliasing an element read of the same seq), and a "clever" workaround
  # around an ownership check is how a subtle miscompare gets shipped.
  var order: seq[int] = @[]
  var taken: seq[bool] = @[]
  for _ in 0 ..< mIdx.len:
    taken.add false
  for _ in 0 ..< mIdx.len:
    var best = -1
    for c in 0 ..< mIdx.len:
      if taken[c]:
        continue
      if best < 0:
        best = c
      else:
        let sc = mScore[c]
        let qc = rs.rules[mIdx[c]].seq
        let sb = mScore[best]
        let qb = rs.rules[mIdx[best]].seq
        if beats(sc, qc, sb, qb):
          best = c
    if best < 0:
      break
    taken[best] = true
    order.add best
  for k in 0 ..< order.len:
    let o = order[k]
    let r = rs.rules[mIdx[o]]
    result.weight = result.weight * r.value
    result.matched = result.matched + 1
    if wantTrace:
      trace.add "  MUL x" & $r.value & "  spec=" & $mScore[o] & "  " & r.source

  # Phase B3 -- clamps, floor then ceiling.
  var haveFloor = false
  var floorScore = 0
  var floorSeq = 0
  var floorVal = 0.0
  var floorSrc = ""
  var haveCeil = false
  var ceilScore = 0
  var ceilSeq = 0
  var ceilVal = 0.0
  var ceilSrc = ""
  for r in rs.rules:
    var sc = 0
    if r.op == opFloor and matches(r, s, sc):
      if not haveFloor or beats(sc, r.seq, floorScore, floorSeq):
        haveFloor = true; floorScore = sc; floorSeq = r.seq
        floorVal = r.value; floorSrc = r.source
    elif r.op == opCeil and matches(r, s, sc):
      if not haveCeil or beats(sc, r.seq, ceilScore, ceilSeq):
        haveCeil = true; ceilScore = sc; ceilSeq = r.seq
        ceilVal = r.value; ceilSrc = r.source
  if haveFloor and result.weight < floorVal:
    result.weight = floorVal
    result.matched = result.matched + 1
    if wantTrace:
      trace.add "  FLOOR   spec=" & $floorScore & "  -> " & $floorVal &
                "  " & floorSrc
  if haveCeil and result.weight > ceilVal:
    result.weight = ceilVal
    result.matched = result.matched + 1
    if wantTrace:
      trace.add "  CEIL    spec=" & $ceilScore & "  -> " & $ceilVal &
                "  " & ceilSrc
      if haveFloor and floorVal > ceilVal:
        trace.add "  NOTE    floor " & $floorVal & " is above ceiling " &
                  $ceilVal & "; the ceiling won"

  if result.weight <= 0.0:
    result.dropped = true
    if result.reason.len == 0:
      result.reason = "weight fell to zero"
    if wantTrace:
      trace.add "  ZERO    weight <= 0, entry removed from the pool"

proc resolve*(rs: RuleSet; s: Subject; base: float): Outcome =
  ## The hot path. No trace is built.
  var t: seq[string] = @[]
  resolveInto(rs, s, base, t, false)

proc explain*(rs: RuleSet; s: Subject; base: float): string =
  ## WHY this item got this weight, rule by rule, in the order they applied.
  ##
  ## Without this a thousand config points is unusable: the failure mode of a
  ## large rule set is not "it crashed", it is "the numbers are wrong and
  ## nobody can say which knob did it". Every line names the settings key or
  ## the literal text clause it came from, so the answer is directly editable.
  var t: seq[string] = @[]
  let o = resolveInto(rs, s, base, t, true)
  result = "item " & s.tpl & "  map=" & (if s.map.len > 0: s.map else: "-") &
           "  ctx=" & $s.ctxKind &
           (if s.ctx.len > 0: ":" & s.ctx else: "") &
           "  rarity=" & (if s.rarity.len > 0: s.rarity else: "-") &
           "  price=" & (if s.price < 0.0: "unlisted" else: $s.price) & "\n"
  result.add "  BASE    " & $base & "  (the pool's own relativeProbability)\n"
  if t.len == 0:
    result.add "  (no rule matched; " & $rs.rules.len &
               " rules in the set)\n"
  else:
    for line in t:
      result.add line & "\n"
  result.add "  RESULT  " &
             (if o.dropped: "DROPPED -- " & o.reason else: $o.weight) &
             "  after " & $o.matched & " rule(s)\n"

proc summary*(rs: RuleSet): string =
  ## One line for the server log and the settings page.
  var muls = 0
  var sets = 0
  var drops = 0
  var clamps = 0
  for r in rs.rules:
    case r.op
    of opMul: inc muls
    of opSet: inc sets
    of opDrop: inc drops
    of opFloor, opCeil: inc clamps
  result = "loot rules: " & $rs.rules.len & " active (" & $muls & " mul, " &
           $sets & " set, " & $drops & " drop, " & $clamps & " clamp)"
  if rs.dropped > 0:
    result.add "; " & $rs.dropped &
               " text clause(s) MALFORMED and ignored -- check the syntax"
