## `aowl-regcheck` -- does `registry/mods.json` describe the mods that are
## actually in this repository?
##
##     aowl-regcheck                    from anywhere inside the repo
##     aowl-regcheck --repo D:\aowlspt
##     aowl-regcheck -q                 findings only
##
## The registry is the one file that claims to know every mod that exists. That
## claim is only worth having if something checks it, because the failure mode
## is silent in both directions: a mod that is built, installed and loaded but
## missing from the manifest cannot be enabled or disabled by anything, and a
## manifest entry naming a guid no mod exports produces a row on the panel that
## is keyed to nothing -- it never merges with the host's row for the real mod,
## so one mod shows up twice and one of the two cannot be toggled.
##
## Neither of those is visible from inside the manager. It reads the registry,
## resolves it, and reports honestly on what it was told; being told something
## false is not a state it can detect. `aowlspt-verify` sees half of it -- it
## notices installed mods the registry does not name -- but only as a `note`,
## only against an install, and only by substring, so it cannot tell a wrong
## guid from a right one. This runs against the *source tree*, before anything
## is built, and it reads the guid out of each mod's own `exportMod` call.
##
## **The source is the truth and the registry is the copy.** Every disagreement
## is reported in that direction: the mod exports X, the registry says Y, fix
## the registry. A mod is not asked to rename itself to match a manifest.
##
## ## Two modes, and the reason there are two
##
##     aowl-regcheck                    the repository: the file *and* the mods
##     aowl-regcheck --file mods.json   the file alone
##
## The registry is meant to live in a repository of its own (see
## `registry/README.md`), and that repository has no `mods/` tree to check
## against -- there is nothing there but the manifest. `--file` is the mode for
## it: schema, required fields, versions and ranges that parse, ids that are
## unique, list entries and `inherits` that resolve, inheritance that
## terminates, a `requires`/`loadAfter` graph that terminates, and each list
## against its own contents -- the dependencies it enables and the conflicts it
## does not. It is what a registry repository runs in CI before it publishes,
## and it is the *same code* the mod manager runs on a fetched document before
## it will adopt it (`registry/validate.nim`), so a file that passes here is a
## file the manager will accept, and one that fails here is one it refuses.
##
## The default mode runs that same validation first and then the half that
## needs the source tree -- which is the half `--file` cannot do, and the reason
## both exist.
##
## What the repository mode checks on top of the file:
##
##  * every directory under `mods/` has exactly one registry entry,
##  * every `intree` registry entry names a directory that exists,
##  * `id` equals the guid the mod's `exportMod` declares -- the rule the whole
##    schema is arranged around, and the one nothing else enforces,
##  * `name`, `author`, `version` and `sides` equal what `exportMod` declares,
##  * `artifact` names the file `aowl build-mod` actually produces,
##  * ids are unique, and `requires` / `inherits` / list entries name mods and
##    lists this registry defines.
##
## ## Reading the guid out of a `.nim`
##
## By scanning the text, not by compiling it. `exportMod(...)` is found, its
## arguments are split, and a value that is a string literal is taken as-is
## while a value that is an identifier is resolved against the `const` block in
## the same file -- which covers every mod here, since they all write either
## `guid = "aowl.sain"` or `guid = ModGuid` with `ModGuid = "..."` above.
##
## The alternative was to build every mod and ask the loaded library for its
## descriptor, which is *more* true and much slower, and which would make this
## unusable as the thing that runs before a build. The scanner's own failure is
## visible rather than silent: a value it cannot resolve is reported as
## unresolved and that mod's metadata checks are skipped with a line saying so,
## rather than being compared against the empty string and passing.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]
import aowlspt/json
import aowlspt/regvalidate

const
  Usage = """
aowl-regcheck -- check a mods.json, and (in a repo) the mods it describes

  aowl-regcheck [--repo PATH] [-q]
  aowl-regcheck --file PATH [-q]

  --repo PATH    the repository to check (default: found from this exe, or
                 the current directory)
  --file PATH    check one mods.json on its own, with no mods/ tree. This is
                 the mode for a standalone registry repository; see
                 registry/README.md.
  -q, --quiet    findings only
  -h, --help     this
"""

type
  RegMod = object
    id: string
    name: string
    author: string
    version: string
    srcKind: string
    srcPath: string
    artDir: string
    artLib: string
    shipped: bool
    sides: seq[string]
    requires: seq[string]
    conflicts: seq[string]
    loadAfter: seq[string]

  RegList = object
    id: string
    inherits: seq[string]
    entries: seq[string]

  SrcMod = object
    dir: string        ## the directory name under `mods/`
    file: string       ## the `.nim` holding `exportMod`, or ""
    guid: string
    name: string
    author: string
    version: string
    sides: seq[string]
    found: bool        ## an `exportMod` call was located at all

var gFailures = 0
var gWarnings = 0
var gChecks = 0

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    inc gFailures
    err what
    if detail.len > 0:
      line "      " & detail

proc soft(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    inc gWarnings
    warn what
    if detail.len > 0:
      line "      " & detail

proc softEither(whenTrue, whenFalse: string; condition: bool; detail = "") =
  ## `soft`, but the warning line states the FINDING rather than the property
  ## that was tested. `soft` printed `warn <id> is named by at least one list`
  ## when the finding was the exact opposite -- so the one line an agent reads
  ## said the reverse of the truth.
  inc gChecks
  if condition:
    ok whenTrue
  else:
    inc gWarnings
    warn whenFalse
    if detail.len > 0:
      line "      " & detail

# --------------------------------------------------------- small text helpers

proc findFrom(s, sub: string; start: int): int =
  ## `find` with a starting offset, spelled out rather than assumed of the
  ## stdlib -- this file is compiled by nimony, whose `strutils` is not Nim's.
  result = -1
  if sub.len == 0 or start < 0:
    return
  var i = start
  while i + sub.len <= s.len:
    if s.substr(i, i + sub.len - 1) == sub:
      return i
    inc i

proc isIdentChar(c: char): bool =
  result = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
           (c >= '0' and c <= '9') or c == '_'

proc joined(items: seq[string]; sep: string): string =
  result = ""
  for it in items:
    if result.len > 0: result.add sep
    result.add it

proc sameSet(a, b: seq[string]): bool =
  ## Order-insensitive comparison of two small string sets. `sides` is a set in
  ## the source (`{sideServer, sideClient}`) and an array in the registry, so
  ## comparing them in order would report a difference that is not one.
  if a.len != b.len:
    return false
  for x in a:
    var hit = false
    for y in b:
      if x == y: hit = true
    if not hit: return false
  result = true

# ------------------------------------------------------- reading the registry

proc idsOfArray(j: JsonRef): seq[string] =
  result = @[]
  if not j.exists or not j.isArray:
    return
  for it in each(j):
    let s = it.asText("")
    if s.len > 0: result.add s

proc idsOfObjectArray(j: JsonRef; key: string): seq[string] =
  ## The `id` of every object in an array: `requires`, `conflicts`, `entries`.
  result = @[]
  if not j.exists or not j.isArray:
    return
  for it in each(j):
    let s = it.child(key).asText("")
    if s.len > 0: result.add s

proc readRegistry(text: string; mods: var seq[RegMod];
                  lists: var seq[RegList]): bool =
  let root = whole(text)
  if not root.exists or not root.isObject:
    return false
  let modsArr = root.child("mods")
  if modsArr.exists and modsArr.isArray:
    for m in each(modsArr):
      var e = RegMod(id: "", name: "", author: "", version: "",
                     srcKind: "", srcPath: "", artDir: "", artLib: "",
                     shipped: true,
                     sides: @[], requires: @[], conflicts: @[], loadAfter: @[])
      e.id = m.child("id").asText("")
      e.name = m.child("name").asText("")
      e.author = m.child("author").asText("")
      e.version = m.child("version").asText("")
      e.srcKind = m.field("source.kind").asText("")
      e.srcPath = m.field("source.path").asText("")
      e.artDir = m.field("artifact.dir").asText("")
      e.artLib = m.field("artifact.library").asText("")
      # `shipped` is the OPT-OUT this file used to only pretend to have. Absent
      # means true, so every existing entry keeps its meaning; `false` says, in
      # a field a tool can read, what several descriptions used to say only in
      # prose -- "it is meant to be switched on by hand". Before this, that
      # sentence was ignored and the warning fired anyway, which is a documented
      # escape hatch that does nothing.
      e.shipped = m.child("shipped").asBool(true)
      e.sides = idsOfArray(m.child("sides"))
      e.requires = idsOfObjectArray(m.child("requires"), "id")
      e.conflicts = idsOfObjectArray(m.child("conflicts"), "id")
      e.loadAfter = idsOfArray(m.child("loadAfter"))
      mods.add e
  let listsArr = root.child("lists")
  if listsArr.exists and listsArr.isArray:
    for l in each(listsArr):
      var e = RegList(id: "", inherits: @[], entries: @[])
      e.id = l.child("id").asText("")
      e.inherits = idsOfArray(l.child("inherits"))
      e.entries = idsOfObjectArray(l.child("entries"), "id")
      lists.add e
  result = true

# ----------------------------------------------------- reading a mod's source

proc matchingClose(s: string; open: int): int =
  ## The `)` closing the `(` at `open`, skipping nesting and string literals.
  ## A `)` inside `"a (b"` is not a close paren, and a mod's description strings
  ## do contain them.
  var depth = 0
  var i = open
  while i < s.len:
    let c = s[i]
    if c == '"':
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\': inc i
        inc i
    elif c == '(' or c == '{' or c == '[':
      inc depth
    elif c == ')' or c == '}' or c == ']':
      dec depth
      if depth == 0 and c == ')':
        return i
    inc i
  result = -1

proc exportModBody(src: string): string =
  ## The text between the parentheses of the `exportMod(` call.
  result = ""
  let at = find(src, "exportMod(")
  if at < 0:
    return
  let open = at + len("exportMod")
  let close = matchingClose(src, open)
  if close <= open:
    return
  result = src.substr(open + 1, close - 1)

proc valueTextOf(body, key: string): string =
  ## The raw text of the named argument, from just after its `=` to the comma
  ## that ends it at depth zero. Returns "" when the argument is absent.
  result = ""
  var i = 0
  var start = -1
  while true:
    let at = findFrom(body, key, i)
    if at < 0:
      return
    let before = if at == 0: ' ' else: body[at - 1]
    let afterIdx = at + key.len
    if not isIdentChar(before) and
       (afterIdx >= body.len or not isIdentChar(body[afterIdx])):
      # Followed by `=` (with spaces allowed) and not `==`.
      var j = afterIdx
      while j < body.len and (body[j] == ' ' or body[j] == '\t'): inc j
      if j < body.len and body[j] == '=' and
         (j + 1 >= body.len or body[j + 1] != '='):
        start = j + 1
        break
    i = at + key.len
  if start < 0:
    return
  var depth = 0
  var i2 = start
  while i2 < body.len:
    let c = body[i2]
    if c == '"':
      inc i2
      while i2 < body.len and body[i2] != '"':
        if body[i2] == '\\': inc i2
        inc i2
    elif c == '(' or c == '{' or c == '[':
      inc depth
    elif c == ')' or c == '}' or c == ']':
      dec depth
    elif c == ',' and depth == 0:
      break
    inc i2
  result = strip(body.substr(start, i2 - 1))

proc literalOrIdent(src, expr: string; resolved: var bool): string =
  ## A `guid = ...` value as a string. Handles `"a" & "b"` spread over lines,
  ## and a bare identifier resolved against a `const` in the same file.
  ##
  ## `resolved` is the honest half: a value this cannot work out leaves it
  ## false, and the caller skips the comparison and says so rather than
  ## comparing against "".
  resolved = false
  result = ""
  var i = 0
  var any = false
  while i < expr.len:
    while i < expr.len and (expr[i] <= ' ' or expr[i] == '&'): inc i
    if i >= expr.len: break
    if expr[i] == '"':
      inc i
      while i < expr.len and expr[i] != '"':
        if expr[i] == '\\' and i + 1 < expr.len:
          inc i
          if expr[i] == 'n': result.add '\n'
          elif expr[i] == 't': result.add '\t'
          else: result.add expr[i]
        else:
          result.add expr[i]
        inc i
      inc i
      any = true
    elif isIdentChar(expr[i]):
      var ident = ""
      while i < expr.len and isIdentChar(expr[i]):
        ident.add expr[i]
        inc i
      # A `const` in this file: `  Ident = "value"` or `  Ident* = "value"`.
      var found = false
      var k = 0
      while true:
        let at = findFrom(src, ident, k)
        if at < 0: break
        k = at + ident.len
        let before = if at == 0: '\n' else: src[at - 1]
        if isIdentChar(before) or before == '.':
          continue
        var j = at + ident.len
        if j < src.len and src[j] == '*': inc j
        while j < src.len and (src[j] == ' ' or src[j] == '\t'): inc j
        if j < src.len and src[j] == '=' and
           (j + 1 >= src.len or src[j + 1] != '='):
          inc j
          while j < src.len and (src[j] == ' ' or src[j] == '\t'): inc j
          if j < src.len and src[j] == '"':
            # Take the const's own initialiser through this same reader, so a
            # `Foo = "a" & "b"` const works too.
            var rest = src.substr(j, src.len - 1)
            var eol = find(rest, "\n")
            if eol < 0: eol = rest.len
            var sub = false
            let v = literalOrIdent(src, rest.substr(0, eol - 1), sub)
            if sub:
              result.add v
              found = true
              any = true
              break
      if not found:
        return
    else:
      # Something this reader does not understand -- a call, a concatenation of
      # a non-literal. Report it as unresolved rather than half-read.
      return
  resolved = any

proc sidesOf(expr: string): seq[string] =
  ## `{sideServer, sideClient, sideSim}` as `@["server","client","sim"]`.
  result = @[]
  for part in split(expr, ","):
    var t = ""
    for ch in part:
      if isIdentChar(ch): t.add ch
    if t == "sideServer": result.add "server"
    elif t == "sideClient": result.add "client"
    elif t == "sideSim": result.add "sim"

proc readSourceMod(modDir: string): SrcMod =
  ## Find the `.nim` in `modDir` that calls `exportMod` and read it.
  result = SrcMod(dir: baseName(modDir), file: "", guid: "", name: "",
                  author: "", version: "", sides: @[], found: false)
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(modDir, files, dirs)
  # The convention is `<dir>/<dir>.nim`; it is tried first so a helper module
  # that happens to mention `exportMod` in a comment cannot win.
  var candidates: seq[string] = @[]
  let preferred = result.dir & ".nim"
  for f in files:
    if find(f, "\\") >= 0: continue
    if f == preferred: candidates.add f
  for f in files:
    if find(f, "\\") >= 0: continue
    if f != preferred and endsWith(f, ".nim"): candidates.add f

  for c in candidates:
    let full = joinPath(modDir, c)
    var text = ""
    if not readTextFile(full, text): continue
    let body = exportModBody(text)
    if body.len == 0: continue
    result.file = full
    result.found = true
    var r = false
    result.guid = literalOrIdent(text, valueTextOf(body, "guid"), r)
    if not r: result.guid = ""
    result.name = literalOrIdent(text, valueTextOf(body, "name"), r)
    if not r: result.name = ""
    result.author = literalOrIdent(text, valueTextOf(body, "author"), r)
    if not r: result.author = ""
    result.version = literalOrIdent(text, valueTextOf(body, "version"), r)
    if not r: result.version = ""
    result.sides = sidesOf(valueTextOf(body, "sides"))
    return

proc modDirsIn(modsRoot: string): seq[string] =
  ## Top-level directories under `mods/`, minus build output. Same rule
  ## `aowl`'s own `modDirs` uses, so the gate covers exactly what the build
  ## covers -- a mod the build compiles and this skips would be the one hole
  ## worth caring about.
  result = @[]
  if not isDirectory(modsRoot):
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(modsRoot, files, dirs)
  for d in dirs:
    if find(d, "\\") >= 0: continue
    if d == "bin" or d == "nimcache": continue
    result.add joinPath(modsRoot, d)

# ------------------------------------------------------------------- checking

proc compare(what, sourceValue, registryValue, modId: string) =
  ## One metadata field. An unresolved source value is a `note`, never a pass:
  ## "the scanner could not read it" and "they agree" must not print the same.
  if sourceValue.len == 0:
    note modId & ": " & what & " could not be read from the source; not checked"
    return
  check(modId & " " & what & " matches the source", sourceValue == registryValue,
        "exportMod says \"" & sourceValue & "\", the registry says \"" &
        registryValue & "\"")

proc runFileChecks(text: string): bool =
  ## The half of the gate that needs nothing but the file. Shared with the mod
  ## manager, which runs the identical rules over a fetched registry before it
  ## will adopt one -- so what passes here is what the manager accepts, and a
  ## disagreement between the two is impossible rather than unlikely.
  heading "The file itself"
  let v = validateRegistry(text)
  for f in v.findings:
    if f.severity == svFail:
      inc gFailures
      inc gChecks
      err f.what
      if f.detail.len > 0: line "      " & f.detail
    elif f.severity == svWarn:
      inc gWarnings
      inc gChecks
      warn f.what
      if f.detail.len > 0: line "      " & f.detail
    else:
      note f.what & (if f.detail.len > 0: " -- " & f.detail else: "")
  if not v.parsed:
    return false
  # One check per entry that came through, plus the file-level one, plus
  # `rules` -- the checks that are about the file as a whole rather than about
  # one entry: the load-order graph, and each list against its own contents.
  # The validator reports findings rather than passes, so without this a clean
  # file would print "1 checks" over a hundred rules it actually applied.
  gChecks = gChecks + 1 + v.modIds.len + v.listIds.len + v.rules
  if v.failures == 0:
    ok "the file is a well-formed " & SchemaId & " registry" &
       (if v.registryId.len > 0: " (" & v.registryId & ")" else: "")
  line "  " & $v.modIds.len & " mods, " & $v.listIds.len & " lists" &
       (if v.revision >= 0: ", revision " & $v.revision else: ", no revision")
  if v.withDownload.len > 0:
    # Named rather than counted. Nothing in this pipeline downloads a mod
    # binary today -- the manager refuses a fetched registry that carries one --
    # so an entry with a `download` is a claim about a future that has not
    # arrived, and it should be a deliberate one.
    note $v.withDownload.len & " entry/entries carry a `download` block: " &
         joined(v.withDownload, ", ") &
         ". Nothing in this repository fetches a mod binary; see " &
         "registry/README.md, the open question."
  result = v.failures == 0

proc checkFile(path: string): bool =
  ## `--file`: one mods.json, alone. There is no mods/ tree here and none is
  ## looked for -- a registry repository does not have one, and inventing a
  ## check it cannot pass would make the mode useless for the thing it is for.
  heading "aowl-regcheck --file"
  line "  " & path
  var text = ""
  if not fileExists(path) or not readTextFile(path, text):
    inc gFailures
    err "there is no file at " & path
    return false
  result = runFileChecks(text)

proc checkRepo(repo: string): bool =
  let regPath = joinPath(repo, "registry\\mods.json")
  let modsRoot = joinPath(repo, "mods")

  heading "The registry"
  line "  " & regPath
  var regText = ""
  if not fileExists(regPath) or not readTextFile(regPath, regText):
    inc gFailures
    err "there is no registry/mods.json"
    return false
  if not runFileChecks(regText):
    return false

  var mods: seq[RegMod] = @[]
  var lists: seq[RegList] = @[]
  if not readRegistry(regText, mods, lists):
    inc gFailures
    err "the registry is not a JSON object"
    return false
  line "  " & $mods.len & " mods, " & $lists.len & " lists"

  # Duplicate ids: two entries for one guid resolve to whichever the reader
  # kept, and the loser is invisible.
  block:
    var dupes = ""
    var i = 0
    while i < mods.len:
      var j = i + 1
      while j < mods.len:
        if mods[i].id == mods[j].id:
          if dupes.len > 0: dupes.add ", "
          dupes.add mods[i].id
        inc j
      inc i
    check("every mod id appears once", dupes.len == 0, dupes)

  heading "Directories against entries"
  let dirs = modDirsIn(modsRoot)
  check("there is a mods directory", dirs.len > 0,
        "no directories under " & modsRoot)

  var srcs: seq[SrcMod] = @[]
  for d in dirs:
    srcs.add readSourceMod(d)

  # 1. Every directory has an entry. Matched on `source.path`, which is the
  #    field that says which directory an entry is about; matching on the guid
  #    instead would make a wrong guid look like a missing directory and hide
  #    the more specific failure behind the vaguer one.
  var i = 0
  while i < dirs.len:
    let rel = "mods/" & srcs[i].dir
    var idx = -1
    var j = 0
    while j < mods.len:
      if normSep(mods[j].srcPath) == normSep(rel): idx = j
      inc j
    check("mods/" & srcs[i].dir & " has a registry entry", idx >= 0,
          "nothing in registry/mods.json has source.path \"" & rel &
          "\", so the manager cannot enable, disable or even list this mod")
    if idx >= 0:
      let m = mods[idx]
      let s = srcs[i]
      if not s.found:
        inc gWarnings
        warn "mods/" & s.dir & ": no exportMod call found; nothing to check " &
             "the entry against"
      else:
        # 3. The rule the whole schema is arranged around.
        compare("guid", s.guid, m.id, "mods/" & s.dir)
        compare("name", s.name, m.name, "mods/" & s.dir)
        compare("author", s.author, m.author, "mods/" & s.dir)
        compare("version", s.version, m.version, "mods/" & s.dir)
        check("mods/" & s.dir & " sides match the source",
              sameSet(s.sides, m.sides),
              "exportMod says {" & joined(s.sides, ", ") &
              "}, the registry says [" & joined(m.sides, ", ") & "]")
      # The artifact is what the manager passes to the host to load a file, so
      # it has to be the file `aowl build-mod` writes: `<dir>/bin/<dir>.dll`,
      # staged as `<dir>/<dir>.dll`.
      check("mods/" & s.dir & " artifact names the built library",
            m.artDir == s.dir and m.artLib == s.dir & ".dll",
            "the build produces " & s.dir & "/" & s.dir & ".dll; the " &
            "registry says " & m.artDir & "/" & m.artLib)
    inc i

  # 2. Every intree entry names a directory.
  #
  # There are two different failures hiding behind "no such directory", and
  # collapsing them cost real time: an entry pointing at a directory that was
  # renamed or deleted is broken, while an entry pointing OUTSIDE `mods/` --
  # `aowl.callproof` at `examples/callproof` -- is a mod that builds fine and
  # can never SHIP, because `aowl payload` stages the `mods/*` tree and nothing
  # else. The manager offered it anyway. Say which one it is, in those words.
  heading "Entries against directories"
  for m in mods:
    if m.srcKind != "intree":
      note m.id & ": source.kind is \"" & m.srcKind & "\"; no directory " &
           "expected here"
      continue
    if not normSep(m.srcPath).startsWith("mods\\"):
      # NOT SHIPPABLE. A `shipped: false` entry is saying so on purpose and is
      # allowed; anything else is claiming to ship out of a tree the payload
      # never stages.
      check(m.id & " is marked non-shippable, as an out-of-tree entry must be",
            not m.shipped,
            "source.path is \"" & m.srcPath & "\", which is outside mods/, " &
            "so `aowl payload` never stages it and this mod CANNOT SHIP -- " &
            "the manager would offer a mod no install can ever have. Keep it " &
            "as an in-tree experiment by adding \"shipped\": false to its " &
            "entry, or move the source under mods/")
      if not m.shipped:
        note m.id & ": in-tree experiment at \"" & m.srcPath & "\" -- NOT " &
             "SHIPPABLE by design (outside mods/, so `aowl payload` does not " &
             "stage it), and marked \"shipped\": false to say so"
      continue
    var hit = false
    for s in srcs:
      if normSep("mods/" & s.dir) == normSep(m.srcPath): hit = true
    check(m.id & " names a directory that exists", hit,
          "source.path is \"" & m.srcPath & "\" and there is no such " &
          "directory under mods/, so this entry describes a mod that cannot " &
          "be built or loaded")

  heading "Cross-references"
  for m in mods:
    for r in m.requires:
      var hit = false
      for o in mods:
        if o.id == r: hit = true
      # A `requires` naming an unknown id excludes the dependent every time --
      # resolution step 7 has no other answer -- so this is a mod that can
      # never load, written down as if it could.
      check(m.id & " requires " & r & ", which is in the registry", hit,
            "resolution excludes " & m.id & " with missing-dependency on " &
            "every run")
    for r in m.loadAfter:
      var hit = false
      for o in mods:
        if o.id == r: hit = true
      # `loadAfter` is soft by design: a name that is not here is ignored, so
      # this is worth saying and not worth failing over.
      soft(m.id & " loadAfter " & r & ", which is in the registry", hit,
           "soft ordering against a mod this registry does not define; it " &
           "will simply be ignored")
    for r in m.conflicts:
      var hit = false
      for o in mods:
        if o.id == r: hit = true
      if not hit:
        note m.id & " conflicts with " & r & ", which this registry does not " &
             "define; that is legal -- a conflict may name somebody else's mod"

  for l in lists:
    for inh in l.inherits:
      var hit = false
      for o in lists:
        if o.id == inh: hit = true
      check(l.id & " inherits " & inh & ", which is in the registry", hit,
            "a list that inherits a list nobody defines silently loses every " &
            "mod that list was carrying")
    for e in l.entries:
      var hit = false
      for o in mods:
        if o.id == e: hit = true
      check(l.id & " names " & e & ", which is in the registry", hit,
            "resolution drops it as `unknown`, so this list quietly resolves " &
            "to fewer mods than it reads as")

  # And the other direction, which nothing checked: a mod that is in the
  # registry and in no list at all.
  #
  # Every check above reads from a list towards the mods, so a registry can
  # pass all of them while carrying a mod no list can reach. That is what
  # happened: `aowl.perf` was published, resolvable, and named by nothing, so a
  # player picking any of the four lists never got it and nothing said why. It
  # is not a broken registry -- resolution is perfectly correct about a mod
  # nobody asked for -- which is exactly why it needs saying out loud.
  #
  # `soft`, not `check`. A mod may be deliberately unlisted: something a player
  # is meant to switch on by hand, or one held back while it is being written.
  # The failure here is silence, not the state itself.
  for m in mods:
    var named = false
    for l in lists:
      for e in l.entries:
        if e == m.id: named = true
    if not m.shipped:
      # The escape hatch, honoured. It used to be documented in prose ("it is
      # meant to be switched on by hand", verbatim, in three descriptions) and
      # ignored by this check, which is worse than having no hatch at all.
      inc gChecks
      note m.id & " is in no list, deliberately: its entry says " &
           "\"shipped\": false, so it is switched on by hand"
      continue
    softEither(m.id & " is named by at least one list",
               m.id & " is named by NO list",
               named,
               "it is in the registry and in no list, so selecting any list " &
               "never selects it and the panel offers it only to somebody " &
               "who already knows it exists. Add it to a list, or add " &
               "\"shipped\": false to its entry -- a field this tool " &
               "honours, unlike a sentence in `description`")

  result = gFailures == 0

# ----------------------------------------------------------------------- main

proc looksLikeRepo(p: string): bool =
  result = isDirectory(joinPath(p, "registry")) and
           isDirectory(joinPath(p, "mods")) and
           isDirectory(joinPath(p, "tools"))

proc main(): int =
  var repo = ""
  var only = ""
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--repo":
      inc i
      if i <= n: repo = paramStr(i)
    elif a == "--file":
      inc i
      if i <= n: only = paramStr(i)
    elif a == "--quiet" or a == "-q":
      setVerbosity vQuiet
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    elif a.startsWith("-"):
      fatal "unknown option: " & a
    elif repo.len == 0:
      repo = a
    inc i

  if only.len > 0:
    # `--file` is complete on its own: there is no repository to find and none
    # is searched for, so a registry repository can run this from its own
    # checkout with nothing of aowlspt beside it but this exe.
    discard checkFile(absolutePathOf(only))
    heading "Result"
    line "  " & $gChecks & " checks"
    if gWarnings > 0:
      line "  " & $gWarnings & " warning(s)"
    if gFailures > 0:
      err $gFailures & " failed"
      return 1
    ok "the registry is well-formed"
    return 0

  if repo.len == 0:
    # This exe is built into `installer\build`, so the repository is two levels
    # up. Walking up rather than assuming it lets the tool be run from a copy.
    var here = parentOf(absolutePathOf(paramStr(0)))
    var hops = 0
    while hops < 6 and here.len > 3:
      if looksLikeRepo(here):
        repo = here
        break
      here = parentOf(here)
      inc hops
  if repo.len == 0:
    repo = absolutePathOf(".")
  repo = absolutePathOf(repo)

  heading "aowl-regcheck"
  line "  " & repo
  discard checkRepo(repo)

  heading "Result"
  line "  " & $gChecks & " checks"
  if gWarnings > 0:
    line "  " & $gWarnings & " warning(s)"
  if gFailures > 0:
    err $gFailures & " failed"
    return 1
  ok "the registry and the mods on disk agree"
  result = 0

quit(main())
