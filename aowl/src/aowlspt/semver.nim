## Versions and version ranges, for the registry.
##
## Deliberately a small grammar, written out here rather than pulled in, because
## every operator this accepts has to be *implemented* — and a range that is
## parsed as something it does not mean is worse than one that is refused. The
## whole vocabulary is in `registry/README.md`; there is nothing here that is
## not documented there, and nothing there that is not here.
##
##     *                 anything
##     1.2.3   =1.2.3    exactly
##     >=  >  <=  <      comparison
##     ~1.2.3            >=1.2.3 <1.3.0
##     ^1.2.3            >=1.2.3 <2.0.0
##     ^0.2.3            >=0.2.3 <0.3.0 -- for a 0.x major the *minor* is the
##                       breaking component, so caret pins it
##     ">=1.2.3 <2.0.0"  space-separated terms are ANDed
##
## `||` is refused rather than approximated. So is a version with fewer than
## three components: a missing patch would otherwise read as zero and make "1.2"
## satisfy "~1.2.0" without anyone having said so.

type
  Version* = object
    ok*: bool
    major*: int
    minor*: int
    patch*: int

proc badVersion*(): Version = Version(ok: false, major: 0, minor: 0, patch: 0)

proc parseVersion*(s: string): Version =
  ## `MAJOR.MINOR.PATCH`. A `-prerelease` or `+build` suffix is ignored for
  ## comparison — SPT and this pipeline both version in three numbers, and
  ## ordering prereleases correctly is machinery nothing here would use.
  var vals0 = 0
  var vals1 = 0
  var vals2 = 0
  var comp = 0
  var digits = 0
  var i = 0
  while i < s.len:
    let ch = s[i]
    if ch >= '0' and ch <= '9':
      let d = ord(ch) - ord('0')
      if comp == 0: vals0 = vals0 * 10 + d
      elif comp == 1: vals1 = vals1 * 10 + d
      elif comp == 2: vals2 = vals2 * 10 + d
      else: return badVersion()
      inc digits
      inc i
      continue
    if ch == '.':
      if digits == 0 or comp >= 2:
        # "1..2" and "1.2.3.4" are both malformed; neither gets a guess.
        return badVersion()
      inc comp
      digits = 0
      inc i
      continue
    if ch == '-' or ch == '+':
      break
    return badVersion()
  if comp != 2 or digits == 0:
    return badVersion()
  result = Version(ok: true, major: vals0, minor: vals1, patch: vals2)

proc compare*(a, b: Version): int =
  ## -1, 0, 1. Only meaningful for two parsed versions; the callers check `ok`
  ## before they get here.
  if a.major != b.major:
    return (if a.major < b.major: -1 else: 1)
  if a.minor != b.minor:
    return (if a.minor < b.minor: -1 else: 1)
  if a.patch != b.patch:
    return (if a.patch < b.patch: -1 else: 1)
  result = 0

proc render*(v: Version): string =
  if not v.ok: return "?"
  result = $v.major & "." & $v.minor & "." & $v.patch

# ---------------------------------------------------------------------------
# Ranges
# ---------------------------------------------------------------------------

proc splitTerms(s: string): seq[string] =
  ## Whitespace-separated terms. Hand-rolled rather than `split`: the only
  ## separator that matters is a run of spaces, and this keeps the module free
  ## of a stdlib import it would otherwise need for one call.
  result = @[]
  var cur = ""
  for ch in s:
    if ch == ' ' or ch == '\t':
      if cur.len > 0:
        result.add cur
        cur = ""
    else:
      cur.add ch
  if cur.len > 0:
    result.add cur

proc hasBar(s: string): bool =
  var i = 0
  while i + 1 < s.len:
    if s[i] == '|' and s[i + 1] == '|':
      return true
    inc i
  result = false

proc matchTerm(v: Version; term: string; err: var string): bool =
  ## One term of a range. `err` is set only when the *term* is malformed, which
  ## is a registry bug; a version that simply does not satisfy a well-formed
  ## term returns false with `err` untouched.
  var op = "="
  var rest = term
  if term.len >= 2 and (term[0] == '>' or term[0] == '<') and term[1] == '=':
    op = term.substr(0, 1)
    rest = term.substr(2)
  elif term.len >= 1 and (term[0] == '>' or term[0] == '<' or term[0] == '=' or
                          term[0] == '~' or term[0] == '^'):
    op = term.substr(0, 0)
    rest = term.substr(1)

  let w = parseVersion(rest)
  if not w.ok:
    err = "\"" & term & "\" is not a version range this reader understands"
    return false

  let c = compare(v, w)
  if op == "=": return c == 0
  if op == ">=": return c >= 0
  if op == ">": return c > 0
  if op == "<=": return c <= 0
  if op == "<": return c < 0

  if op == "~":
    # Patch-level drift: same major.minor.
    if c < 0: return false
    return v.major == w.major and v.minor == w.minor

  if op == "^":
    # Compatible-with. For 0.x the minor is the breaking component, which is
    # the whole reason caret has a special case at all — and this pipeline is
    # 0.1.0, so it is the branch that actually runs.
    if c < 0: return false
    if w.major == 0:
      return v.major == 0 and v.minor == w.minor
    return v.major == w.major

  err = "\"" & term & "\" uses an operator this reader does not implement"
  result = false

proc matchRange*(v: Version; rangeText: string; err: var string): bool =
  ## Whether `v` satisfies `rangeText`. `err` is set when the *range* cannot be
  ## read, and the caller must treat that as a registry fault rather than as a
  ## version mismatch: they call for different reporting.
  err = ""
  if rangeText.len == 0 or rangeText == "*":
    return true
  if hasBar(rangeText):
    err = "\"" & rangeText & "\" uses `||`, which this reader does not " &
          "implement; it is refused rather than read as something else"
    return false
  if not v.ok:
    err = "the version being tested is not MAJOR.MINOR.PATCH"
    return false
  let terms = splitTerms(rangeText)
  if terms.len == 0:
    return true
  for t in terms:
    if not matchTerm(v, t, err):
      return false
  result = true
