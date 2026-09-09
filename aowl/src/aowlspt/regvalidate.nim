## Is this text a registry?
##
## One implementation, two callers, and that is the point:
##
##  * `tools/regcheck.nim` runs it as `aowl-regcheck --file mods.json`, which is
##    what a standalone registry repository puts in its CI before it publishes;
##  * `mods/manager/mgr/refresh.nim` runs it on every fetched document before
##    that document is allowed to replace the registry the player is running.
##
## Two copies of these rules would drift, and the drift would be silent in the
## worst direction: the publisher's check passing on a file the manager then
## refuses, or — much worse — the manager accepting a file the publisher's check
## would have caught. So both call this, and `registry/README.md` is the prose
## for exactly what is here.
##
## **This checks the file against itself.** Schema, required fields, versions
## and ranges that parse, ids that are unique and referenced consistently,
## inheritance that terminates. It does *not* look at `mods/` — a registry
## repository has no `mods/` to look at, and the manager on a player's machine
## has a mods directory that is allowed to differ from the manifest. Checking an
## entry against the mod's own `exportMod` is the in-tree half and stays in
## `regcheck`.
##
## **Every finding is one of three severities**, and the difference is whether
## acting on the file anyway is defensible:
##
##  * `svFail` — the file is not usable. A duplicate id, a list entry naming a
##    mod that is not here, an inheritance cycle. Refuse the whole document; a
##    registry that resolves to fewer mods than it reads as is the failure this
##    is all arranged against.
##  * `svWarn` — usable, and something is likely wrong. A `loadAfter` naming a
##    mod nobody defines is *defined* to be ignored, so it cannot be a failure,
##    but it is almost always a typo.
##  * `svNote` — legal, and worth saying out loud. A `conflicts` entry may name
##    somebody else's mod, so an unresolvable name there is correct behaviour.
##
## `semver.nim` is imported from the manager rather than copied. The vocabulary
## of version ranges has to be the vocabulary the resolver actually implements —
## a validator that accepted `1.2.3 || 2.0.0` because it had its own looser
## parser would pass a file the resolver then excludes every mod in.

import aowlspt/semver
import aowlspt/json

const
  SchemaId* = "aowlspt.registry/1"
  ## The panel's rows are fixed-size structs (`abi/aowlspt_overlay.h`), so a
  ## longer value truncates on screen rather than crashing. Checked here because
  ## truncation is invisible from the side that wrote the file.
  MaxIdBytes* = 80
  MaxVersionBytes* = 24

type
  Severity* = enum
    svNote
    svWarn
    svFail

  Finding* = object
    severity*: Severity
    ## Phrased as the statement that is true when the check passes, so a caller
    ## can print it with a tick in front of it either way.
    what*: string
    detail*: string

  Validation* = object
    ok*: bool                  ## no `svFail`
    parsed*: bool              ## it was JSON, and an object
    schema*: string
    registryId*: string
    registryName*: string
    revision*: int             ## `registry.revision`, or -1 when absent
    modIds*: seq[string]
    modVersions*: seq[string]  ## parallel to `modIds`
    listIds*: seq[string]
    withDownload*: seq[string] ## mod ids carrying a non-null `download`
    findings*: seq[Finding]
    failures*: int
    warnings*: int
    notes*: int
    rules*: int
      ## How many rules below were *applied* beyond the per-entry ones a caller
      ## can count for itself from `modIds` and `listIds`. Findings are only
      ## reported when something is wrong, so without this a file that passes
      ## the order check and four per-list checks prints as though none of them
      ## had run. `tools/regcheck.nim` adds it to its own total.

proc severityName*(s: Severity): string =
  if s == svFail: return "fail"
  if s == svWarn: return "warn"
  result = "note"

# ---------------------------------------------------------------------------
# Small helpers. Spelled out rather than taken from `strutils`: this file is
# compiled by nimony both into a command-line tool and into a mod library, and
# the smaller its dependency surface is the fewer ways those two differ.
# ---------------------------------------------------------------------------

proc contains(s: seq[string]; v: string): bool =
  for x in s:
    if x == v: return true
  result = false

proc isKnownSide(s: string): bool =
  result = s == "server" or s == "client" or s == "sim"

proc isKnownSourceKind(s: string): bool =
  result = s == "intree" or s == "git"

proc isHex(s: string): bool =
  if s.len == 0: return false
  for ch in s:
    if not ((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or
            (ch >= 'A' and ch <= 'F')):
      return false
  result = true

proc hasDot(s: string): bool =
  for ch in s:
    if ch == '.': return true
  result = false

proc hasSpace(s: string): bool =
  for ch in s:
    if ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r': return true
  result = false

proc textOf(j: JsonRef; default: string = ""): string =
  ## A string field, where JSON `null` reads as absent. `asText` hands back a
  ## non-string as written, so a null would arrive as the four characters
  ## `null` — which is how "no licence" becomes the licence "null".
  if not j.exists or j.isNull: return default
  result = j.asText(default)

proc textList(j: JsonRef): seq[string] =
  result = @[]
  if not j.exists or not j.isArray: return
  for it in each(j):
    let s = it.asText("")
    if s.len > 0: result.add s

# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------

proc add(v: var Validation; sev: Severity; what, detail: string) =
  v.findings.add Finding(severity: sev, what: what, detail: detail)
  if sev == svFail: inc v.failures
  elif sev == svWarn: inc v.warnings
  else: inc v.notes

proc need(v: var Validation; condition: bool; what, detail: string) =
  if not condition: add(v, svFail, what, detail)

proc prefer(v: var Validation; condition: bool; what, detail: string) =
  if not condition: add(v, svWarn, what, detail)

# ---------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------

proc emptyValidation*(): Validation =
  Validation(ok: false, parsed: false, schema: "", registryId: "",
             registryName: "", revision: -1, modIds: @[], modVersions: @[],
             listIds: @[], withDownload: @[], findings: @[], failures: 0,
             warnings: 0, notes: 0, rules: 0)

proc checkVersionText(v: var Validation; who, field, value: string;
                      maxBytes: int) =
  if value.len == 0:
    add(v, svFail, who & " has a " & field, "the field is missing or empty")
    return
  let parsed = parseVersion(value)
  need(v, parsed.ok, who & " " & field & " is MAJOR.MINOR.PATCH",
       "\"" & value & "\" is not three numbers; a missing component would " &
       "read as zero and make it match ranges nobody wrote")
  if maxBytes > 0:
    prefer(v, value.len <= maxBytes,
           who & " " & field & " fits the panel's " & $maxBytes & " bytes",
           "\"" & value & "\" is " & $value.len & " bytes and truncates on " &
           "screen")

proc checkRange(v: var Validation; who, field, value: string) =
  if value.len == 0:
    add(v, svWarn, who & " states a " & field,
        "an absent range is read as \"*\"; write it down if that is meant")
    return
  var err = ""
  # Matched against a version that exists only to drive the parser. The answer
  # is discarded; the error text is the whole point.
  discard matchRange(Version(ok: true, major: 1, minor: 0, patch: 0), value, err)
  need(v, err.len == 0, who & " " & field & " parses",
       "\"" & value & "\": " & err)

proc checkDownload(v: var Validation; who: string; j: JsonRef;
                   sourceKind: string) =
  let d = j.child("download")
  if not d.exists or d.isNull:
    if sourceKind != "intree":
      add(v, svWarn, who & " states where its binary comes from",
          "source.kind is \"" & sourceKind & "\" and `download` is null, so " &
          "nothing can obtain this mod; that is legal and it means the entry " &
          "is documentation only")
    return
  v.withDownload.add who
  let url = textOf(d.child("url"), "")
  let sha = textOf(d.child("sha256"), "")
  let size = d.child("size")
  need(v, url.len > 0, who & " download has a url", "`download.url` is empty")
  need(v, sha.len == 64 and isHex(sha),
       who & " download has a sha256",
       "`download.sha256` must be 64 hex characters; a hash that is not one " &
       "verifies nothing, and a field that looks checked and is not is worse " &
       "than an empty one")
  need(v, size.exists and not size.isNull and size.asInt(0) > 0,
       who & " download states a size",
       "`download.size` must be the byte count, so a fetcher can refuse a " &
       "body of the wrong length before it has hashed it")

proc checkMod(v: var Validation; j: JsonRef; index: int) =
  let id = textOf(j.child("id"), "")
  let who = if id.len > 0: id else: "mods[" & $index & "]"
  if id.len == 0:
    add(v, svFail, who & " has an id",
        "an entry with no id cannot be named by a list, enabled, disabled or " &
        "matched to a loaded mod")
    return
  need(v, not v.modIds.contains(id), "the id " & id & " appears once",
       "two entries for one id make \"which version is this\" depend on " &
       "which one the reader hit first")
  need(v, id.len <= MaxIdBytes, id & " fits the panel's " & $MaxIdBytes & " bytes",
       "the id is " & $id.len & " bytes and truncates in the overlay's row")
  prefer(v, hasDot(id) and not hasSpace(id), id & " is a reverse-DNS id",
         "ids are reverse-DNS and must equal the guid the mod's exportMod " &
         "declares; \"" & id & "\" does not look like one")

  let version = textOf(j.child("version"), "")
  v.modIds.add id
  v.modVersions.add version

  need(v, textOf(j.child("name"), "").len > 0, who & " has a name",
       "the panel has a row for this and nothing to put in it")
  prefer(v, textOf(j.child("author"), "").len > 0, who & " names an author",
         "credit is the field most often left out and the one people ask for")
  checkVersionText(v, who, "version", version, MaxVersionBytes)
  checkRange(v, who, "pipeline", textOf(j.child("pipeline"), ""))

  let sides = textList(j.child("sides"))
  need(v, sides.len > 0, who & " declares at least one side",
       "a mod that declares no side is `wrong-side` everywhere and can never " &
       "load")
  for s in sides:
    need(v, isKnownSide(s), who & " side \"" & s & "\" is known",
         "sides are server, client and sim; anything else is silently never " &
         "matched")

  let kind = textOf(j.field("source.kind"), "")
  need(v, isKnownSourceKind(kind),
       who & " source.kind is intree or git",
       "\"" & kind & "\" is not a kind any reader here implements")
  if kind == "intree":
    need(v, textOf(j.field("source.path"), "").len > 0,
         who & " intree source names a path",
         "an intree entry with no path names no directory")
  elif kind == "git":
    need(v, textOf(j.field("source.url"), "").len > 0,
         who & " git source names a url",
         "a git entry with no url points at nothing")

  let artDir = textOf(j.field("artifact.dir"), "")
  let artLib = textOf(j.field("artifact.library"), "")
  need(v, artDir.len > 0 and artLib.len > 0, who & " has an artifact",
       "`artifact` is the only thing that lets the manager say which file to " &
       "load, so a mod without one answers `refused` on every enable")

  checkDownload(v, who, j, kind)

proc checkList(v: var Validation; j: JsonRef; index: int) =
  let id = textOf(j.child("id"), "")
  let who = if id.len > 0: id else: "lists[" & $index & "]"
  if id.len == 0:
    add(v, svFail, who & " has an id", "a list with no id cannot be selected")
    return
  need(v, not v.listIds.contains(id), "the list id " & id & " appears once",
       "the second one is unreachable")
  v.listIds.add id
  need(v, textOf(j.child("name"), "").len > 0, who & " has a name", "")
  let version = textOf(j.child("version"), "")
  if version.len > 0:
    checkVersionText(v, who, "version", version, 0)

# ---------------------------------------------------------------------------
# Cross-references and inheritance
# ---------------------------------------------------------------------------

proc walk(v: var Validation; root: JsonRef; listIndex: int;
          stack: var seq[string]; done: var seq[string]) =
  ## Depth-first over `inherits`, reporting a cycle exactly once.
  ##
  ## `stack` is the current path and is checked *before* `done`: with the two
  ## the other way round a diamond — two lists inheriting one parent — reads as
  ## a cycle, and a real cycle is silently ignored. The same order, and the same
  ## reason, as `mgr/resolve.nim`'s `flattenInto`.
  let lists = each(root.child("lists"))
  if listIndex < 0 or listIndex >= lists.len: return
  let l = lists[listIndex]
  let id = textOf(l.child("id"), "")
  if stack.contains(id):
    var path = ""
    for s in stack:
      path.add s
      path.add " -> "
    path.add id
    add(v, svFail, id & "'s inheritance terminates", path)
    return
  if done.contains(id): return
  stack.add id
  for parent in textList(l.child("inherits")):
    var idx = -1
    var k = 0
    for other in lists:
      if textOf(other.child("id"), "") == parent: idx = k
      inc k
    if idx < 0:
      add(v, svFail, id & " inherits " & parent & ", which this file defines",
          "a list that inherits a list nobody defines silently loses every " &
          "mod that list was carrying")
    else:
      walk(v, root, idx, stack, done)
  var keep: seq[string] = @[]
  for i in 0 ..< stack.len - 1:
    keep.add stack[i]
  stack = keep
  done.add id

proc crossCheck(v: var Validation; root: JsonRef) =
  var index = 0
  for m in each(root.child("mods")):
    let id = textOf(m.child("id"), "")
    let who = if id.len > 0: id else: "mods[" & $index & "]"
    for r in each(m.child("requires")):
      let rid = textOf(r.child("id"), "")
      need(v, rid.len > 0, who & " requires an entry with an id", "")
      if rid.len > 0:
        need(v, v.modIds.contains(rid),
             who & " requires " & rid & ", which this file defines",
             "resolution excludes " & who & " with missing-dependency on " &
             "every run, so this is a mod written down as if it could load")
        checkRange(v, who, "requires " & rid & " version",
                   textOf(r.child("version"), "*"))
        # A dependency is only a dependency where it can run. Resolution
        # decides sides (step 5) *before* it decides dependencies (step 7), so
        # a mod that declares a side its requirement does not is excluded on
        # that side with `missing-dependency` -- a mod that is on the panel,
        # in a list, correct in every field, and unable to load on the side it
        # was written for. Not a failure, because the entry is still right on
        # the sides they share.
        if rid.len > 0 and v.modIds.contains(rid):
          inc v.rules
          var depSides: seq[string] = @[]
          for other in each(root.child("mods")):
            if textOf(other.child("id"), "") == rid:
              depSides = textList(other.child("sides"))
          var uncovered = ""
          for s in textList(m.child("sides")):
            if not depSides.contains(s):
              if uncovered.len > 0: uncovered.add ", "
              uncovered.add s
          prefer(v, uncovered.len == 0,
                 rid & " declares every side " & who & " does",
                 who & " declares " & uncovered & " and " & rid &
                 " does not, so on " & uncovered & " the requirement can " &
                 "never be met and " & who & " is excluded with " &
                 "`missing-dependency` every run")
    for a in textList(m.child("loadAfter")):
      prefer(v, v.modIds.contains(a),
             who & " loadAfter " & a & ", which this file defines",
             "soft ordering against a mod this registry does not define; it " &
             "is simply ignored, which makes a typo here invisible")
    for c in each(m.child("conflicts")):
      let cid = textOf(c.child("id"), "")
      need(v, cid.len > 0, who & " conflicts with something named", "")
      prefer(v, textOf(c.child("reason"), "").len > 0,
             who & " gives a reason for conflicting with " & cid,
             "the reason is what the manager prints when it refuses to load " &
             "both, so an empty one is a refusal with no explanation")
      if cid.len > 0 and not v.modIds.contains(cid):
        add(v, svNote, who & " conflicts with " & cid,
            "this file does not define " & cid & ", which is legal — a " &
            "conflict may name somebody else's mod")
    inc index

  var listIndex = 0
  for l in each(root.child("lists")):
    let lid = textOf(l.child("id"), "")
    let who = if lid.len > 0: lid else: "lists[" & $listIndex & "]"
    for e in each(l.child("entries")):
      let eid = textOf(e.child("id"), "")
      need(v, eid.len > 0, who & " has an entry with an id", "")
      if eid.len > 0:
        need(v, v.modIds.contains(eid),
             who & " names " & eid & ", which this file defines",
             "resolution drops it as `unknown`, so this list quietly " &
             "resolves to fewer mods than it reads as")
    inc listIndex

  var stack: seq[string] = @[]
  var done: seq[string] = @[]
  var i = 0
  let lists = each(root.child("lists"))
  while i < lists.len:
    walk(v, root, i, stack, done)
    stack = @[]
    inc i

# ---------------------------------------------------------------------------
# The order the resolver will actually compute
# ---------------------------------------------------------------------------
#
# Everything above checks the file against itself. This checks it against the
# one piece of behaviour that is *not* visible in any single entry: what
# `mgr/resolve.nim` step 9 does with `requires` and `loadAfter` together.
#
# That step emits a mod once every id it requires and every id it names in
# `loadAfter` has been emitted, and when nothing can be emitted and mods are
# left it excludes **every survivor** with `cycle`. So a file where two mods
# each name the other in `loadAfter` -- or where one names itself -- satisfies
# every rule above and still resolves to a registry with mods missing from it.
# The symptom is not a wrong order, it is those mods silently not loading, and
# neither the publisher's gate nor the manager could see it coming.
#
# The same loop runs here, over the same two edge kinds, and names the
# survivors. Edges to ids this file does not define are left out on purpose: an
# unknown `requires` is already a failure above, and an unknown `loadAfter` is
# *defined* to be ignored, so counting one here would invent a cycle the
# resolver cannot have.

proc indexOfId(ids: seq[string]; id: string): int =
  result = -1
  for i in 0 ..< ids.len:
    if ids[i] == id: return i

proc orderCheck(v: var Validation; root: JsonRef) =
  let mods = each(root.child("mods"))
  let n = mods.len
  if n == 0: return
  inc v.rules
  var ids: seq[string] = @[]
  for m in mods:
    ids.add textOf(m.child("id"), "")

  # The edges, as two parallel arrays. A sequence of sequences is the natural
  # shape and not one nimony is reliably happy with; this is the same data.
  var edgeFrom: seq[int] = @[]
  var edgeTo: seq[int] = @[]
  var i = 0
  while i < n:
    var targets: seq[string] = @[]
    for r in each(mods[i].child("requires")):
      let rid = textOf(r.child("id"), "")
      if rid.len > 0: targets.add rid
    for a in textList(mods[i].child("loadAfter")):
      targets.add a
    for t in targets:
      let k = indexOfId(ids, t)
      if k >= 0:
        edgeFrom.add i
        edgeTo.add k
    inc i

  var emitted: seq[bool] = @[]
  i = 0
  while i < n:
    emitted.add false
    inc i
  var remaining = n
  while remaining > 0:
    var progressed = false
    i = 0
    while i < n:
      if not emitted[i]:
        var ready = true
        var e = 0
        while e < edgeFrom.len:
          if edgeFrom[e] == i and not emitted[edgeTo[e]]:
            ready = false
          inc e
        if ready:
          emitted[i] = true
          dec remaining
          progressed = true
      inc i
    if not progressed:
      var names = ""
      i = 0
      while i < n:
        if not emitted[i]:
          if names.len > 0: names.add ", "
          names.add (if ids[i].len > 0: ids[i] else: "mods[" & $i & "]")
        inc i
      add(v, svFail, "every mod can be placed in a load order",
          names & " cannot: each is waiting, through `requires` or " &
          "`loadAfter`, on another of them. A mod naming itself counts. The " &
          "resolver's step 9 excludes every one of them with `cycle`, so " &
          "this is not a wrong order -- it is those mods not loading at all")
      return

# ---------------------------------------------------------------------------
# What one list resolves to on its own
# ---------------------------------------------------------------------------
#
# A list is a document somebody sends somebody else, and the thing it promises
# is the set of mods it names. Two ways it can quietly promise less:
#
#  * it enables a mod whose `requires` it does not enable -- resolution step 7
#    then excludes that mod with `missing-dependency`, every run;
#  * it enables two mods that conflict, either by a declared `conflicts` entry
#    or by both providing the same capability -- step 8 then excludes **both**.
#
# Warnings and not failures, and the reason is the selection rather than the
# file: several lists can be active at once and a per-mod override can add a
# mod none of them names, so a list that is not self-sufficient is a legal
# thing to publish. What it is not is a list you can hand somebody on its own,
# which is what most lists are for.

proc flattenList(root: JsonRef; listIndex: int; stack: var seq[string];
                 ids: var seq[string]; on: var seq[bool]) =
  ## The enabled/disabled set one list resolves to, parents first, later
  ## entries updating the flag of an earlier one rather than moving it. The
  ## same rule as `mgr/resolve.nim`'s `mergeEntry`, for the same reason: an
  ## inherited override flips a switch, it does not reorder anything.
  let lists = each(root.child("lists"))
  if listIndex < 0 or listIndex >= lists.len: return
  let l = lists[listIndex]
  let id = textOf(l.child("id"), "")
  if stack.contains(id): return       # already reported by `walk`
  stack.add id
  for parent in textList(l.child("inherits")):
    var k = 0
    var idx = -1
    for other in lists:
      if textOf(other.child("id"), "") == parent: idx = k
      inc k
    if idx >= 0:
      flattenList(root, idx, stack, ids, on)
  for e in each(l.child("entries")):
    let eid = textOf(e.child("id"), "")
    if eid.len == 0: continue
    let enabled = e.child("enabled").asBool(true)
    let at = indexOfId(ids, eid)
    if at >= 0:
      on[at] = enabled
    else:
      ids.add eid
      on.add enabled
  var keep: seq[string] = @[]
  for i in 0 ..< stack.len - 1:
    keep.add stack[i]
  stack = keep

proc conflictBetween(a, b: JsonRef): string =
  ## "" when there is none. Either direction, and a shared `provides` counts --
  ## the same three rules, in the same order, as `mgr/resolve.nim`.
  let aid = textOf(a.child("id"), "")
  let bid = textOf(b.child("id"), "")
  for c in each(a.child("conflicts")):
    if textOf(c.child("id"), "") == bid:
      return textOf(c.child("reason"), "no reason given")
  for c in each(b.child("conflicts")):
    if textOf(c.child("id"), "") == aid:
      return textOf(c.child("reason"), "no reason given")
  for p in textList(a.child("provides")):
    for q in textList(b.child("provides")):
      if p == q:
        return "both provide " & p
  result = ""

proc listCheck(v: var Validation; root: JsonRef) =
  let mods = each(root.child("mods"))
  let lists = each(root.child("lists"))
  var modIds: seq[string] = @[]
  for m in mods:
    modIds.add textOf(m.child("id"), "")

  var li = 0
  while li < lists.len:
    let lid = textOf(lists[li].child("id"), "")
    if lid.len == 0:
      inc li
      continue
    inc v.rules
    var stack: seq[string] = @[]
    var ids: seq[string] = @[]
    var on: seq[bool] = @[]
    flattenList(root, li, stack, ids, on)

    # The mods this list actually switches on, as indices into `mods`.
    var live: seq[int] = @[]
    for i in 0 ..< ids.len:
      if not on[i]: continue
      let at = indexOfId(modIds, ids[i])
      if at >= 0: live.add at

    for a in live:
      for r in each(mods[a].child("requires")):
        let rid = textOf(r.child("id"), "")
        if rid.len == 0: continue
        if indexOfId(modIds, rid) < 0: continue   # already a failure above
        var satisfied = false
        for b in live:
          if modIds[b] == rid: satisfied = true
        prefer(v, satisfied,
               lid & " enables everything " & modIds[a] & " requires",
               modIds[a] & " requires " & rid & ", which " & lid &
               " does not enable, so resolution excludes " & modIds[a] &
               " with `missing-dependency` unless another active list or an " &
               "override supplies it. A list that is handed to somebody on " &
               "its own has to carry its own dependencies")

    var x = 0
    while x < live.len:
      var y = x + 1
      while y < live.len:
        let why = conflictBetween(mods[live[x]], mods[live[y]])
        if why.len > 0:
          add(v, svWarn,
              lid & " enables no two mods that conflict",
              modIds[live[x]] & " and " & modIds[live[y]] & " conflict (" &
              why & ") and this list switches both on; resolution step 8 " &
              "excludes *both* of them, so the list resolves to two fewer " &
              "mods than it reads as")
        inc y
      inc x
    inc li

# ---------------------------------------------------------------------------
# The entry point
# ---------------------------------------------------------------------------

proc validateRegistry*(text: string): Validation =
  result = emptyValidation()
  if text.len == 0:
    add(result, svFail, "there is something to read", "the document is empty")
    return
  let root = whole(text)
  if not root.exists or not root.isObject:
    add(result, svFail, "the document is a JSON object",
        "it did not parse, or the top level is not an object")
    return
  result.parsed = true

  result.schema = textOf(root.child("schema"), "")
  need(result, result.schema == SchemaId,
       "the schema is \"" & SchemaId & "\"",
       "this file declares \"" & result.schema & "\"; a reader that does not " &
       "know the schema refuses the file rather than guessing at fields it " &
       "has never seen")
  if result.schema != SchemaId:
    # Nothing below is meaningful once the schema is unknown: the field names
    # this walks are exactly the ones the schema string is a promise about.
    return

  result.registryId = textOf(root.field("registry.id"), "")
  result.registryName = textOf(root.field("registry.name"), "")
  need(result, result.registryId.len > 0, "the registry has an id",
       "`registry.id` is how a person tells two registries apart in a log line")
  prefer(result, result.registryName.len > 0, "the registry has a name", "")

  let rev = root.field("registry.revision")
  if rev.exists and not rev.isNull:
    result.revision = rev.asInt(-1)
    need(result, result.revision >= 0, "registry.revision is a whole number",
         "the revision is the only thing that orders two copies of a " &
         "registry, so it has to be a number that goes up")
  else:
    add(result, svNote, "the registry states a revision",
        "`registry.revision` is absent, so a reader cannot tell a newer copy " &
        "of this file from an older one and a refresh can only ever be " &
        "\"take it or leave it\"")

  let mods = root.child("mods")
  need(result, mods.exists and mods.isArray, "`mods` is an array",
       "order is meaningful and an array is what produces a readable diff")
  let lists = root.child("lists")
  need(result, lists.exists and lists.isArray, "`lists` is an array", "")
  if not (mods.exists and mods.isArray) or not (lists.exists and lists.isArray):
    result.ok = result.failures == 0
    return

  var i = 0
  for m in each(mods):
    checkMod(result, m, i)
    inc i
  need(result, result.modIds.len > 0, "the registry defines at least one mod",
       "an empty registry resolves to nothing at all, which is almost always " &
       "a URL pointing somewhere unexpected rather than somebody's intent")

  i = 0
  for l in each(lists):
    checkList(result, l, i)
    inc i

  crossCheck(result, root)
  # These two need every id to have been collected first: one walks the whole
  # `requires`/`loadAfter` graph and the other flattens every list through its
  # parents, and both are meaningless against a half-read file.
  orderCheck(result, root)
  listCheck(result, root)
  result.ok = result.failures == 0
