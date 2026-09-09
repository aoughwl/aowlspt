## Server value modifiers -- the singleplayer settings that reach the CLIENT.
##
## `globals.config` in `db.json` is the document the client's own ballistics,
## stamina, malfunction, skill, flea-market and experience code reads once per
## session, out of the body of `/client/globals`. Nothing on our side has to be
## patched into the game for a change here to take effect: the client asked for
## the number, and this decides what number it gets. That is exactly the lever
## SPT's ServerValueModifier pulled, and it is why this module exists rather
## than a host detour per value.
##
## The one list rule
## -----------------
## `globaltunedata.nim` is generated from a real `db.json` and holds one record
## per exposed value. **`tuneSchema` and `applyGlobalTunes` read the same
## records**, so a row cannot be declared without also being applied, and
## cannot be applied without being declared. This is deliberate and it is the
## whole design: CLAUDE.md 9b's failure mode is a setting that renders and
## changes nothing, and the only structural defence against it is refusing to
## let the schema and the behaviour come from two places.
##
## What is NOT claimed
## -------------------
## That every one of these values is read by the client. The claim this module
## can make -- and the only one it makes -- is that an edited value **reaches
## the client, in the document the client asked for, in place of the stock
## value**. Whether the client's code then acts on a particular leaf is the
## client's business, and `globalTuneReport` prints exactly what was changed so
## a human can tell the difference instead of guessing.
##
## Cost
## ----
## Zero when nothing is overridden: `applyGlobalTunes` returns its input
## unchanged and the 694 KB globals document is never reparsed. When something
## IS overridden the document is rewritten ONCE, in a single recursive pass
## that visits only the branches an override lives on.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import aowlspt/settings
import globaltunedata

type
  TuneRow* = object
    key*: string        ## the flat config.json key, e.g. `g_Stamina_Capacity`
    path*: string       ## the dotted path inside the globals document
    parts*: seq[string] ## `path` pre-split, because the patcher walks it
    kind*: char         ## 'i' | 'f' | 'b'
    defRaw*: string     ## the value db.json holds, as a JSON literal
    lo*: float
    hi*: float
    hasRange*: bool
    category*: string
    label*: string

var gRows: seq[TuneRow] = @[]
var gRowsParsed = false

# The overrides in force, resolved once at load. Parallel arrays rather than a
# seq of objects so the recursive patcher can pass indices around cheaply.
var gOvParts: seq[seq[string]] = @[]
var gOvValue: seq[string] = @[]
var gOvKey: seq[string] = @[]
var gOvRejected: seq[string] = @[]

proc splitDots(s: string): seq[string] =
  result = @[]
  var part = ""
  for i in 0 ..< s.len:
    if s[i] == '.':
      if part.len > 0:
        result.add part
        part = ""
    else:
      part.add s[i]
  if part.len > 0:
    result.add part

proc splitFields(line: string): seq[string] =
  ## `|`-separated, empty fields preserved -- an empty `lo` is meaningful
  ## (it means "this value has no sensible range"), so a splitter that drops
  ## empties would shift every field after it.
  result = @[]
  var part = ""
  for i in 0 ..< line.len:
    if line[i] == '|':
      result.add part
      part = ""
    else:
      part.add line[i]
  result.add part

proc toFloat(s: string): float =
  var v = DbValue(ok: true, raw: s, error: "")
  result = asFloat(v, 0.0)

proc rows*(): seq[TuneRow] =
  ## The generated table, parsed once.
  if gRowsParsed:
    return gRows
  gRowsParsed = true
  gRows = @[]
  for line in splitLines(GlobalTuneTable):
    if line.len == 0:
      continue
    let f = splitFields(line)
    if f.len != 8:
      # A malformed record is dropped rather than half-read. Half-reading it
      # would produce a row whose key and path came from different columns --
      # a setting that writes somewhere nobody asked for.
      continue
    var r = TuneRow(key: f[0], path: f[1], parts: splitDots(f[1]),
                    kind: (if f[2].len > 0: f[2][0] else: 'f'),
                    defRaw: f[3], lo: 0.0, hi: 0.0, hasRange: false,
                    category: f[6], label: f[7])
    if f[4].len > 0 and f[5].len > 0:
      r.lo = toFloat(f[4])
      r.hi = toFloat(f[5])
      r.hasRange = r.hi > r.lo
    gRows.add r
  result = gRows

proc tuneSchema*(): seq[Setting] =
  ## One declared setting per record. The default shown is the value the
  ## database actually holds, so the page opens reading the truth rather than
  ## a number somebody typed into this file.
  result = @[]
  let allRows = rows()
  for r in allRows:
    let help = "Overrides globals." & r.path.substr(7) &
               " in the document the client fetches from /client/globals"
    # The second level of grouping is the branch of the globals document the
    # value lives on -- `Stamina`, `RagFair`, `Overheat`. Derived from the path
    # rather than named separately, because a subcategory that can disagree
    # with the path is a label that lies about where the value goes.
    let sub = (if r.parts.len > 2: r.parts[1] else: "")
    case r.kind
    of 'b':
      result.add boolSetting(r.key, r.label, r.defRaw == "true",
                             category = r.category, subcategory = sub,
                             description = help)
    of 'i':
      result.add intSetting(r.key, r.label, int(toFloat(r.defRaw)),
                            lo = int(r.lo), hi = int(r.hi), step = 1,
                            category = r.category, subcategory = sub,
                            description = help)
    else:
      var step = 0.01
      if r.hasRange and (r.hi - r.lo) > 100.0:
        step = 1.0
      result.add floatSetting(r.key, r.label, toFloat(r.defRaw),
                              lo = r.lo, hi = r.hi, step = step,
                              category = r.category, subcategory = sub,
                              description = help)

proc literalOk(kind: char; raw: string): bool =
  ## Whether `raw` is a JSON literal of the declared kind.
  ##
  ## Checked rather than trusted. These values are spliced verbatim into the
  ## globals document; one non-numeric byte from a hand-edited `config.json`
  ## would make the whole 694 KB body unparseable, and a client handed
  ## unparseable globals does not report a bad setting -- it hangs, because a
  ## response of the wrong shape hangs rather than errors.
  if raw.len == 0:
    return false
  if kind == 'b':
    return raw == "true" or raw == "false"
  var seenDigit = false
  for i in 0 ..< raw.len:
    let c = raw[i]
    if c >= '0' and c <= '9':
      seenDigit = true
    elif c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E':
      discard
    else:
      return false
  result = seenDigit

proc loadGlobalTunes*() =
  ## Read every declared key out of `config.json` and keep the ones that differ
  ## from what the database holds.
  ##
  ## `setting(key).ok` is false for a key `config.json` does not contain, and
  ## the settings UI writes a key only when somebody edits it -- so an
  ## untouched install produces zero overrides and `applyGlobalTunes` becomes a
  ## no-op that does not even parse the document.
  gOvParts = @[]
  gOvValue = @[]
  gOvKey = @[]
  gOvRejected = @[]
  let allRows = rows()
  for r in allRows:
    let c = setting(r.key)
    if not c.ok:
      continue
    var raw = c.raw
    if r.kind != 'b' and raw.len >= 2 and raw[0] == '"' and
       raw[raw.len - 1] == '"':
      # A host that hands string-shaped values back quoted (see `asText` in
      # aowlspt/server for why the three hosts disagree) must not put a quoted
      # number into a numeric field of the globals document.
      raw = raw.substr(1, raw.len - 2)
    if not literalOk(r.kind, raw):
      gOvRejected.add r.key & "=" & c.raw
      continue
    if raw == r.defRaw:
      continue
    gOvParts.add r.parts
    gOvValue.add raw
    gOvKey.add r.key

proc globalTuneCount*(): int = gOvValue.len
proc globalTuneRejected*(): seq[string] = gOvRejected
proc globalTuneTotal*(): int = rows().len

proc globalTuneReport*(): seq[string] =
  ## Every override in force, as `path = value`. Printed at load, because a
  ## silent modifier is indistinguishable from one that did not take.
  result = @[]
  for i in 0 ..< gOvValue.len:
    var path = "globals"
    for k in 0 ..< gOvParts[i].len:
      path.add "."
      path.add gOvParts[i][k]
    result.add gOvKey[i] & ": " & path & " = " & gOvValue[i]

proc patchInto(text: string; idxs: seq[int]; depth: int): string =
  ## One level of the document, with every override that lives under it applied.
  ##
  ## Rewrites only the members an override names; every other member is carried
  ## through as its own raw text, untouched and unreparsed. That is what keeps
  ## a 694 KB document from being rebuilt member-by-member.
  var d = parseObject(text)
  if not d.ok:
    return text
  var names: seq[string] = @[]
  var groups: seq[seq[int]] = @[]
  for i in idxs:
    if depth >= gOvParts[i].len:
      continue
    let n = gOvParts[i][depth]
    var at = -1
    for k in 0 ..< names.len:
      if names[k] == n:
        at = k
    if at < 0:
      names.add n
      var fresh: seq[int] = @[]
      fresh.add i
      groups.add fresh
    else:
      groups[at].add i
  for gi in 0 ..< names.len:
    var leaf = ""
    var deeper: seq[int] = @[]
    for i in groups[gi]:
      if gOvParts[i].len == depth + 1:
        leaf = gOvValue[i]
      else:
        deeper.add i
    if not d.has(names[gi]):
      # The path is not in this database. Skipped, not created: inventing a
      # member the client never asked for is a guess, and a wrong guess here
      # is a globals document that does not match the schema the client parses.
      continue
    if leaf.len > 0:
      setRaw(d, names[gi], leaf)
    elif deeper.len > 0:
      let sub = getRaw(d, names[gi])
      if sub.len > 0 and sub[0] == '{':
        setRaw(d, names[gi], patchInto(sub, deeper, depth + 1))
  result = text(d)

proc applyGlobalTunes*(globalsText: string): string =
  ## The globals document as the client should receive it.
  if gOvValue.len == 0:
    return globalsText
  var all: seq[int] = @[]
  for i in 0 ..< gOvValue.len:
    all.add i
  result = patchInto(globalsText, all, 0)

proc selfCheckTuning*(into: var seq[string]): bool =
  ## Arithmetic this module can prove without a database, a host or a profile.
  ##
  ## Deliberately negative and falsifiable (CLAUDE.md 9b): each case names an
  ## input that makes it fail. It does NOT assert "the patch wrote what I told
  ## it to" -- it re-reads the finished document through the JSON reader and
  ## asserts a property of that.
  result = true
  let n = rows().len
  if n < 100:
    into.add "globals tune table parsed " & $n &
             " rows; the generated table has hundreds -- the parse is wrong"
    result = false

  # Every key unique. A duplicate makes the second row unreachable, which is a
  # decorative setting produced by accident rather than by intent.
  var dupes = 0
  var seen: seq[string] = @[]
  let allRows = rows()
  for r in allRows:
    for s in seen:
      if s == r.key:
        inc dupes
    seen.add r.key
  if dupes > 0:
    into.add $dupes & " duplicate keys in the globals tune table"
    result = false

  # Every declared row must have a path that starts at `config.`, or it patches
  # nothing and is decorative by construction.
  var badPath = 0
  let pathRows = rows()
  for r in pathRows:
    if r.parts.len < 2 or r.parts[0] != "config":
      inc badPath
  if badPath > 0:
    into.add $badPath & " globals tune rows do not address config.*"
    result = false

  # A nested patch, end to end, checked by READING BACK the finished document.
  block:
    let src = """{"config":{"Stamina":{"Capacity":100,"SprintDrainRate":4},
                  "Keep":{"Me":7}},"other":[1,2,3]}"""
    let saveParts = gOvParts
    let saveValue = gOvValue
    gOvParts = @[splitDots("config.Stamina.Capacity")]
    gOvValue = @["999"]
    let outText = applyGlobalTunes(src)
    gOvParts = saveParts
    gOvValue = saveValue
    if field(outText, "config.Stamina.Capacity").asInt(0) != 999:
      into.add "globals tune: the override did not land in the finished document"
      result = false
    if field(outText, "config.Stamina.SprintDrainRate").asInt(0) != 4:
      into.add "globals tune: patching one member destroyed its sibling"
      result = false
    if field(outText, "config.Keep.Me").asInt(0) != 7:
      into.add "globals tune: patching one branch destroyed another"
      result = false
    if not field(outText, "other").isArray:
      into.add "globals tune: a non-object member did not survive the rewrite"
      result = false

  # A value that is not a JSON literal must be refused, not spliced. The input
  # that makes this fail is `literalOk` returning true for junk.
  if literalOk('i', "1; drop"):
    into.add "globals tune: a non-numeric literal was accepted for an int row"
    result = false
  if literalOk('b', "yes"):
    into.add "globals tune: a non-boolean literal was accepted for a bool row"
    result = false
  if not literalOk('f', "-0.25"):
    into.add "globals tune: a valid float literal was refused"
    result = false
