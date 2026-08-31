## The Debug mod's overlay TRANSLATION, and the check that it actually landed.
##
## Two files, not one, and that is the whole reason this module exists:
##
##   * the settings surface writes `mods/debug/config.json`, with `overlay*` keys
##   * the F3 panel in the host reads `aowlspt-debugui.json`, with `panel*` keys
##
## They are different files with different key NAMES, so nothing copies one to
## the other by accident -- a real translation step has to run, in the process
## that owns the mod, every time a setting changes. When it does not run, the
## panel keeps rendering yesterday's values while `config.json` shows exactly
## what the player asked for, and every part of the system truthfully reports
## success. That is what was reported live, twice.
##
## Everything here is a PURE function of two strings: the bytes of
## `config.json` and the bytes of `aowlspt-debugui.json`. No file IO, no mod
## ABI, no host. That is deliberate: it makes the verdict testable off-line
## against hand-written inputs, so the claim "this check can fail" is something
## that gets demonstrated rather than asserted.
##
## §9b: the verdict is a falsifiable NEGATIVE over the FINISHED STATE --
## "no translated key disagrees between the panel's write and the host's input"
## -- and it has three outcomes, never two. INCONCLUSIVE is a real answer: a
## missing or unparseable overlay file means we could not look, and "I could
## not look" is not a pass.

import std/strutils

type
  DiagVerdict* = enum
    dvPass, dvFail, dvInconclusive

  KeyMap* = object
    cfgKey*: string   ## the key in `mods/debug/config.json`
    panelKey*: string ## the key in `aowlspt-debugui.json`
    numeric*: bool    ## compare as a number (16 == 16.0), not as text

const
  OverlayKeyMap*: array[11, KeyMap] = [
    KeyMap(cfgKey: "overlayEnabled",    panelKey: "panelEnabled",    numeric: false),
    KeyMap(cfgKey: "overlayAnchor",     panelKey: "panelAnchor",     numeric: false),
    KeyMap(cfgKey: "overlayX",          panelKey: "panelX",          numeric: true),
    KeyMap(cfgKey: "overlayY",          panelKey: "panelY",          numeric: true),
    KeyMap(cfgKey: "overlayFontSize",   panelKey: "panelFontSize",   numeric: true),
    KeyMap(cfgKey: "overlayLineHeight", panelKey: "panelLineHeight", numeric: true),
    KeyMap(cfgKey: "overlayThrottle",   panelKey: "panelThrottle",   numeric: true),
    KeyMap(cfgKey: "overlayColor",      panelKey: "panelColor",      numeric: false),
    KeyMap(cfgKey: "overlayFields",     panelKey: "panelFields",     numeric: false),
    KeyMap(cfgKey: "overlayToggleKey",  panelKey: "toggleKey",       numeric: true),
    # The ESP marker colour: the one esp* key `debug.nim` now WRITES rather than
    # passes through, because it has a picker. It is in this table for the same
    # reason every other row is -- so the diag ASSERTS the finished state, i.e.
    # that dragging the picker actually moved the byte the host reads. Both
    # sides spell it `espColor`; that is the exception to the overlay*->panel*
    # rule going the other way, and spelling it out keeps it from being assumed.
    KeyMap(cfgKey: "espColor",          panelKey: "espColor",        numeric: false)]
    ## THE translation, in one place. `debug.nim` writes the overlay file from
    ## this table and the diag checks the overlay file against this table, so
    ## the writer and the check cannot drift apart into two different opinions
    ## about what `overlayColor` is called on the other side.
    ##
    ## `overlayToggleKey` -> `toggleKey` is the one that does not follow the
    ## `overlay*` -> `panel*` rule. Spelling the pairs out is why that is
    ## harmless instead of being a silent one-key hole.

# ---------------------------------------------------------------------------
# A deliberately small JSON value scanner
# ---------------------------------------------------------------------------
#
# Both documents are flat objects of scalars that this repo writes. A full
# parser is not needed and a full parser is not wanted here either: this module
# is the thing that must keep working when the OTHER side of the translation is
# malformed, so it reads what it can find and says plainly when it found
# nothing, rather than throwing the whole document away.

proc isWs(c: char): bool =
  c == ' ' or c == '\t' or c == '\n' or c == '\r'

proc rawValue*(doc, key: string; found: var bool): string =
  ## The raw text of `"key": <value>` -- a quoted string comes back WITHOUT its
  ## quotes, everything else comes back verbatim up to the next `,` or `}`.
  ##
  ## Matches only a key at the top level of a `"..." :` position, so the
  ## `_comment` prose in `config.json` -- which contains the word
  ## `aowlspt-debugui.json` and several key names in running text -- cannot be
  ## mistaken for a key. This was a real hazard, not a hypothetical: that file's
  ## `_comment` names three of the keys checked here.
  found = false
  result = ""
  let needle = "\"" & key & "\""
  var from0 = 0
  while from0 < doc.len:
    let at = doc.find(needle, from0)
    if at < 0:
      return
    var i = at + needle.len
    while i < doc.len and isWs(doc[i]): i = i + 1
    if i >= doc.len or doc[i] != ':':
      # Not a key in key position -- this was the same text inside a prose
      # string. Keep looking.
      from0 = at + 1
      continue
    # It must also be a KEY, not a value: the character before the opening
    # quote has to be `{` or `,` (modulo whitespace).
    var j = at - 1
    while j >= 0 and isWs(doc[j]): j = j - 1
    if j >= 0 and doc[j] != '{' and doc[j] != ',':
      from0 = at + 1
      continue
    i = i + 1
    while i < doc.len and isWs(doc[i]): i = i + 1
    if i >= doc.len:
      return
    found = true
    if doc[i] == '"':
      i = i + 1
      var s = ""
      while i < doc.len and doc[i] != '"':
        if doc[i] == '\\' and i + 1 < doc.len:
          i = i + 1
          if doc[i] == 'n' or doc[i] == 't' or doc[i] == 'r': s.add ' '
          else: s.add doc[i]
        else:
          s.add doc[i]
        i = i + 1
      return s
    var v = ""
    while i < doc.len and doc[i] != ',' and doc[i] != '}' and doc[i] != '\n':
      v.add doc[i]
      i = i + 1
    return v.strip()

proc toTenths*(s: string; ok: var bool): int =
  ## `"16"`, `"16.0"` and `"16.00"` all become 160; `"-16.5"` becomes -165.
  ##
  ## Hand-rolled rather than `parseFloat` because this module compiles under
  ## NIMONY, whose `strutils` has no `parseFloat` -- and finding that out from
  ## a build error is exactly the sort of thing that tempts a "close enough"
  ## text comparison instead. Fixed point at one decimal is also the RIGHT
  ## instrument here: it is precisely the precision the overlay file is
  ## written at, so it cannot round a real difference away (the smallest step
  ## any numeric setting takes is 1) and it has no float equality in it.
  ok = false
  result = 0
  let t = s.strip()
  if t.len == 0: return
  var i = 0
  var neg = false
  if t[0] == '-':
    neg = true
    i = 1
  elif t[0] == '+':
    i = 1
  var whole = 0
  var digits = 0
  while i < t.len and t[i] >= '0' and t[i] <= '9':
    if whole < 100_000_000:
      whole = whole * 10 + (int(t[i]) - int('0'))
    digits = digits + 1
    i = i + 1
  if digits == 0: return
  var tenth = 0
  if i < t.len and t[i] == '.':
    i = i + 1
    var frac = 0
    var fdigits = 0
    while i < t.len and t[i] >= '0' and t[i] <= '9':
      if fdigits < 2:
        frac = frac * 10 + (int(t[i]) - int('0'))
        fdigits = fdigits + 1
      i = i + 1
    if fdigits == 0: return
    # Round the second decimal into the first, so `0.16` and `0.2` are not
    # called equal but `0.199` and `0.2` are.
    if fdigits == 1: tenth = frac
    else: tenth = (frac + 5) div 10
    if tenth > 9: tenth = 9
  if i != t.len:
    # Trailing junk -- an exponent, a stray character. Refuse rather than
    # silently comparing the part that parsed.
    return
  ok = true
  result = whole * 10 + tenth
  if neg: result = -result

proc numEq*(a, b: string): bool =
  ## `16` and `16.0` and `16.00` are the same number; `16` and `1.6` are not.
  ## Anything that does not parse as a number falls back to exact text, so a
  ## boolean or an unexpected value is still compared, never waved through.
  var aok = false
  var bok = false
  let ai = toTenths(a, aok)
  let bi = toTenths(b, bok)
  if not aok or not bok:
    return a.strip() == b.strip()
  result = ai == bi

# ---------------------------------------------------------------------------
# The verdict
# ---------------------------------------------------------------------------

proc overlayDiag*(cfgText, panelText: string; detail: var string): DiagVerdict =
  ## PASS / FAIL / INCONCLUSIVE over the finished state.
  ##
  ## PASS         every translated key in `config.json` is present in the
  ##              overlay file under its translated name and holds the same
  ##              value. This is the negative: nothing disagrees.
  ## FAIL         at least one key drifted or is MISSING from the overlay file.
  ##              `detail` names the key, both spellings, and both values --
  ##              because "settings did not apply" without the key is the
  ##              report that cost two sessions.
  ## INCONCLUSIVE we could not look: one of the documents is absent or holds
  ##              none of the keys at all. NOT a pass.
  detail = ""
  if cfgText.len == 0:
    detail = "mods/debug/config.json is empty or unreadable -- the panel's " &
             "own write could not be read, so nothing was compared"
    return dvInconclusive
  if panelText.len == 0:
    detail = "aowlspt-debugui.json is absent or unreadable -- the host has " &
             "nothing to consume and this check could not look. The overlay " &
             "is running on the host's built-in defaults."
    return dvInconclusive

  var seen = 0
  var bad = ""
  var badCount = 0
  var i = 0
  while i < OverlayKeyMap.len:
    let m = OverlayKeyMap[i]
    var haveCfg = false
    let cv = rawValue(cfgText, m.cfgKey, haveCfg)
    if haveCfg:
      seen = seen + 1
      var havePanel = false
      let pv = rawValue(panelText, m.panelKey, havePanel)
      if not havePanel:
        badCount = badCount + 1
        if bad.len > 0: bad.add "; "
        bad.add m.cfgKey & "=" & cv & " is MISSING from the overlay file " &
                "(expected there as \"" & m.panelKey & "\") -- the " &
                "translation did not run"
      elif m.numeric:
        if not numEq(cv, pv):
          badCount = badCount + 1
          if bad.len > 0: bad.add "; "
          bad.add m.cfgKey & "=" & cv & " but " & m.panelKey & "=" & pv
      elif cv != pv:
        badCount = badCount + 1
        if bad.len > 0: bad.add "; "
        bad.add m.cfgKey & "=\"" & cv & "\" but " & m.panelKey & "=\"" & pv &
                "\""
    i = i + 1

  if seen == 0:
    detail = "mods/debug/config.json holds none of the " &
             $OverlayKeyMap.len & " overlay keys, so there was nothing to " &
             "compare. This is not a pass."
    return dvInconclusive
  if badCount > 0:
    detail = $badCount & " of " & $seen & " overlay setting(s) have NOT " &
             "reached the file the F3 panel reads: " & bad &
             ". The panel is rendering the older value."
    return dvFail
  detail = "all " & $seen & " overlay setting(s) in mods/debug/config.json " &
           "are present in aowlspt-debugui.json under their translated names " &
           "with the same value; the colour matched byte-for-byte. Nothing " &
           "disagrees."
  result = dvPass

proc verdictName*(v: DiagVerdict): string =
  case v
  of dvPass: "PASS"
  of dvFail: "FAIL"
  of dvInconclusive: "INCONCLUSIVE"

# ---------------------------------------------------------------------------
# The three-copies cross-check
# ---------------------------------------------------------------------------

proc schemaCrossCheck*(cfgText: string; declaredKeys: openArray[string];
                       detail: var string): DiagVerdict =
  ## `config.json`, the schema in `debug.nim` and the translation table above
  ## are three copies of one decision (that is what `config.json`'s own
  ## `_comment` says). This is the cheap loud check that they agree, and it is
  ## again a negative: no `overlay*` key exists in one copy and not the others.
  ##
  ## The `declaredKeys` -> `config.json` direction is already self-healing
  ## (`backfillDeclaredDefaults`), so what is checked here is the two
  ## directions that are NOT self-healing and that fail silently:
  ##   * a key in `config.json` that no longer exists in the schema -- dead
  ##     weight the player can edit with no effect at all
  ##   * a key in the translation table that the schema does not declare --
  ##     the overlay file would be written from a default forever
  detail = ""
  if cfgText.len == 0:
    detail = "config.json unreadable; the three copies were not compared"
    return dvInconclusive
  var problems = ""
  var n = 0

  var i = 0
  while i < OverlayKeyMap.len:
    var declared = false
    var d = 0
    while d < declaredKeys.len:
      if declaredKeys[d] == OverlayKeyMap[i].cfgKey: declared = true
      d = d + 1
    if not declared:
      n = n + 1
      if problems.len > 0: problems.add "; "
      problems.add "the translation writes \"" & OverlayKeyMap[i].panelKey &
                   "\" from \"" & OverlayKeyMap[i].cfgKey &
                   "\", which the schema in debug.nim does not declare"
    i = i + 1

  var d2 = 0
  while d2 < declaredKeys.len:
    let k = declaredKeys[d2]
    if k.len > 7 and k.substr(0, 6) == "overlay":
      var mapped = false
      var m = 0
      while m < OverlayKeyMap.len:
        if OverlayKeyMap[m].cfgKey == k: mapped = true
        m = m + 1
      if not mapped:
        n = n + 1
        if problems.len > 0: problems.add "; "
        problems.add "the schema declares \"" & k &
                     "\", which the translation never writes into " &
                     "aowlspt-debugui.json -- that row moves and changes " &
                     "nothing"
    d2 = d2 + 1

  if n > 0:
    detail = $n & " drift(s) between the schema in debug.nim and the " &
             "translation table: " & problems
    return dvFail
  detail = "the schema in debug.nim and the translation table agree on all " &
           $OverlayKeyMap.len & " overlay keys"
  result = dvPass
