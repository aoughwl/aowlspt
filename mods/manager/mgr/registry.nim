## Reading `registry/mods.json`.
##
## The registry is somebody's git repository and this only ever *reads* it: the
## user's own choices live in the manager's store, never in the manifest, so a
## `git pull` can never conflict with what you turned off last night.
##
## Parsed once into records rather than re-scanned per request. `aowlspt/json`
## scans text and copies the document into every `JsonRef` it hands out, which
## is the right trade for a request body read three times and the wrong one for
## a manifest walked on every route call.
##
## Anything malformed is *reported and skipped at entry granularity*: one mod
## with a broken `requires` block must not take the other seven down. What is
## refused whole is a file whose `schema` this reader does not know — a
## half-understood registry produces a list that loads five of your seven mods
## and says everything is fine, which is the failure worth preventing.

import std/syncio
import aowlspt
import aowlspt/json

const
  SchemaId* = "aowlspt.registry/1"

type
  Requirement* = object
    id*: string
    versionRange*: string

  Conflict* = object
    id*: string
    reason*: string

  ModEntry* = object
    id*: string
    name*: string
    author*: string
    version*: string
    description*: string
    pipeline*: string
    sides*: seq[string]
    sourceKind*: string
    sourcePath*: string
    sourceUrl*: string
    artifactDir*: string
    artifactLib*: string
    license*: string
    downloadUrl*: string
    downloadHash*: string
    requires*: seq[Requirement]
    conflicts*: seq[Conflict]
    provides*: seq[string]
    loadAfter*: seq[string]
    tags*: seq[string]
    parent*: string
      ## PRESENTATION ONLY. The id of the mod this one belongs UNDER in the
      ## player-facing tree -- e.g. `aowl.morebots` and `aowl.waypoints` are
      ## halves of `aowl.sain` ("Bot AI") and are not separate mods to a
      ## player. Empty means root-level. Nothing in resolution reads it: a
      ## child is resolved, ordered, required and loaded exactly as before,
      ## and its guid, path, dll and routes are unchanged, so no stored
      ## config path moves when a mod acquires a parent. It is a separate
      ## axis from `internal`: `internal` says "do not draw this row at all",
      ## `parent` says "draw it there". A parent id the registry does not
      ## know is left as written and reported, never silently dropped --
      ## making an unrecognised value disappear is the one outcome this must
      ## not produce.
    internal*: bool
      ## PRESENTATION ONLY. True for infrastructure a player has no business
      ## seeing on the mod list -- the settings index, the fallback browser
      ## page, an ABI experiment. Nothing in resolution reads it: an internal
      ## mod is resolved, ordered, required and loaded exactly as before. It
      ## is a separate axis from `shipped`, on purpose -- `aowl.settingshub`
      ## ships in every install and must be invisible, `aowl.textures` is not
      ## shipped yet and is an ordinary player mod. Collapsing the two would
      ## hide the wrong ones.
    shipped*: bool
      ## DISTRIBUTION ONLY. False when the built artifact can never reach an
      ## install (`aowl payload` stages `mods/*`, so `examples/*` cannot).
      ## Default true. Read by tooling; it does NOT hide a row -- see above.

  ListEntry* = object
    id*: string
    enabled*: bool
    note*: string

  ModList* = object
    id*: string
    name*: string
    author*: string
    version*: string
    description*: string
    inherits*: seq[string]
    entries*: seq[ListEntry]
    ## True for a list the player wrote, merged in from the selection store by
    ## `withLocalLists` rather than read out of the manifest. Resolution does
    ## not look at this and must not: a local list is a list. It is here so a
    ## UI can say which of your lists a registry refresh is able to replace,
    ## which is a question with a real answer and a bad guess.
    local*: bool

  Registry* = object
    ok*: bool
    path*: string
    error*: string
    name*: string
    warnings*: seq[string]
    mods*: seq[ModEntry]
    lists*: seq[ModList]

proc emptyRegistry*(): Registry =
  Registry(ok: false, path: "", error: "not loaded", name: "",
           warnings: @[], mods: @[], lists: @[])

# ---------------------------------------------------------------------------
# Small readers
# ---------------------------------------------------------------------------

proc textOf(j: JsonRef; default: string = ""): string =
  ## A string field, where JSON `null` means absent.
  ##
  ## `asText` hands back a non-string value as written, so a null reads as the
  ## four characters `null` — which would put the word "null" in a licence field
  ## and, worse, make an absent `download.url` look like a URL.
  if not j.exists or j.isNull:
    return default
  result = j.asText(default)

proc textList(j: JsonRef): seq[string] =
  ## A JSON array of strings. A missing array and an empty one are the same
  ## thing here, which is why neither is an error.
  result = @[]
  if not j.exists or not j.isArray:
    return
  let items = each(j)
  for it in items:
    let s = it.asText("")
    if s.len > 0:
      result.add s

# ---------------------------------------------------------------------------
# Did all of the bytes arrive?
# ---------------------------------------------------------------------------
#
# `aowlspt/json` is a *scanner*: `field` walks the text and hands back whatever
# it finds, so a truncated document does not fail to parse -- it parses as
# whatever survived the truncation. A `mods.json` cut in half by a failed
# `git checkout`, a full disk or an interrupted download therefore reads as a
# perfectly valid registry with fewer mods in it than the publisher wrote, and
# `parseRegistry` used to hand that back with `ok = true`.
#
# That is the same class of bug as the truncated selection store, and worse in
# its consequences: the manager resolves against the surviving half, every mod
# that fell off the end becomes "no active list mentions it", and the selection
# document written beside the mods names the survivors. The next start loads
# exactly those. Nobody is told anything.
#
# So the raw text is checked for structural wholeness *before* a single field
# is read out of it. This is not a parser -- a second parser would be a second
# thing to disagree with `aowlspt/json`. It answers one question: did all of
# the bytes arrive.
#
# It lives here rather than in `selection.nim`, which asked it first, because
# both callers need the identical answer and two copies of a balance-counter
# are two chances to fix a bug once.

proc isJsonWs*(ch: char): bool =
  result = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r'

proc wholeJsonObject*(raw: string): bool =
  ## Whether `raw` is one complete, balanced JSON object with nothing after it.
  var i = 0
  while i < raw.len and isJsonWs(raw[i]):
    inc i
  if i >= raw.len or raw[i] != '{':
    return false
  var depth = 0
  var inStr = false
  var esc = false
  while i < raw.len:
    let ch = raw[i]
    if ord(ch) == 0:
      # A NUL is not something any writer here produces, and a value that has
      # picked one up has been through something that does not handle text.
      return false
    if inStr:
      if esc:
        esc = false
      elif ch == '\\':
        esc = true
      elif ch == '"':
        inStr = false
    else:
      if ch == '"': inStr = true
      elif ch == '{' or ch == '[': inc depth
      elif ch == '}' or ch == ']':
        dec depth
        if depth < 0: return false
        if depth == 0:
          # Only whitespace may follow the outermost object.
          var k = i + 1
          while k < raw.len:
            if not isJsonWs(raw[k]): return false
            inc k
          return true
    inc i
  # Ran off the end inside the document: the bytes stop before the object does.
  result = false

proc stripBom*(text: string): string =
  ## A UTF-8 byte-order mark off the front of a document.
  ##
  ## The host's `readTextFile` strips one; this module has its own reader and
  ## did not, so a `mods.json` saved by a Windows editor read as "not a JSON
  ## object" and the whole registry went missing. Stripped here too, because
  ## "which of the two readers opened this file" is not something a player can
  ## be expected to know, and because a BOM is a *transport* artefact rather
  ## than something the document says.
  if text.len >= 3 and ord(text[0]) == 0xEF and ord(text[1]) == 0xBB and
     ord(text[2]) == 0xBF:
    return text.substr(3, text.len - 1)
  result = text

proc readTextFile*(path: string): string =
  ## `readFile` is `{.raises.}` in nimony, so every call is wrapped. The empty
  ## string is the failure, and the caller turns it into a message that names
  ## the path — a mod that cannot say *which* file it could not read is a
  ## twenty-minute problem instead of a ten-second one.
  result = ""
  try:
    result = stripBom(readFile(path))
  except:
    result = ""

# ---------------------------------------------------------------------------
# Entries
# ---------------------------------------------------------------------------

proc readMod(j: JsonRef; warnings: var seq[string]): ModEntry =
  result = ModEntry(id: "", name: "", author: "", version: "", description: "",
                    pipeline: "*", sides: @[], sourceKind: "", sourcePath: "",
                    sourceUrl: "", artifactDir: "", artifactLib: "",
                    license: "", downloadUrl: "", downloadHash: "",
                    requires: @[], conflicts: @[], provides: @[],
                    loadAfter: @[], tags: @[], parent: "",
                    internal: false, shipped: true)
  result.id = textOf(j.field("id"), "")
  if result.id.len == 0:
    warnings.add "a mod entry has no id and was skipped"
    return
  result.name = textOf(j.field("name"), result.id)
  result.author = textOf(j.field("author"), "")
  result.version = textOf(j.field("version"), "0.0.0")
  result.description = textOf(j.field("description"), "")
  result.pipeline = textOf(j.field("pipeline"), "*")
  result.sides = textList(j.field("sides"))
  result.sourceKind = textOf(j.field("source.kind"), "")
  result.sourcePath = textOf(j.field("source.path"), "")
  result.sourceUrl = textOf(j.field("source.url"), "")
  result.artifactDir = textOf(j.field("artifact.dir"), "")
  result.artifactLib = textOf(j.field("artifact.library"), "")
  result.license = textOf(j.field("license"), "")
  result.downloadUrl = textOf(j.field("download.url"), "")
  result.downloadHash = textOf(j.field("download.sha256"), "")
  result.provides = textList(j.field("provides"))
  result.loadAfter = textList(j.field("loadAfter"))
  result.tags = textList(j.field("tags"))
  result.parent = textOf(j.field("parent"), "")
  result.internal = j.field("internal").asBool(false)
  result.shipped = j.field("shipped").asBool(true)

  let reqs = each(j.field("requires"))
  for r in reqs:
    let rid = r.field("id").asText("")
    if rid.len == 0:
      warnings.add result.id & ": a `requires` entry has no id and was ignored"
      continue
    result.requires.add Requirement(id: rid,
                                    versionRange: r.field("version").asText("*"))

  let cons = each(j.field("conflicts"))
  for c in cons:
    let cid = c.field("id").asText("")
    if cid.len == 0:
      warnings.add result.id & ": a `conflicts` entry has no id and was ignored"
      continue
    result.conflicts.add Conflict(id: cid,
                                  reason: c.field("reason").asText("no reason given"))

  # A mod with no artifact cannot be loaded or unloaded by path, so the manager
  # would be able to say "enabled" and never be able to act on it. Named at load
  # rather than discovered at apply time.
  if result.artifactDir.len == 0 or result.artifactLib.len == 0:
    warnings.add result.id & ": no `artifact` block, so this mod can be " &
                 "resolved but never loaded or unloaded by the manager"

proc readList(j: JsonRef; warnings: var seq[string]): ModList =
  result = ModList(id: "", name: "", author: "", version: "", description: "",
                   inherits: @[], entries: @[], local: false)
  result.id = textOf(j.field("id"), "")
  if result.id.len == 0:
    warnings.add "a list entry has no id and was skipped"
    return
  result.name = textOf(j.field("name"), result.id)
  result.author = textOf(j.field("author"), "")
  result.version = textOf(j.field("version"), "0.0.0")
  result.description = textOf(j.field("description"), "")
  result.inherits = textList(j.field("inherits"))

  let entries = each(j.field("entries"))
  for e in entries:
    let eid = e.field("id").asText("")
    if eid.len == 0:
      warnings.add result.id & ": an entry has no id and was ignored"
      continue
    result.entries.add ListEntry(id: eid,
                                 enabled: e.field("enabled").asBool(true),
                                 note: e.field("note").asText(""))

# ---------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------

proc parseRegistry*(text, path: string): Registry =
  result = emptyRegistry()
  result.path = path
  if text.len == 0:
    result.error = "could not read " & path
    return
  if not wholeJsonObject(text):
    # Checked before any field is read. `aowlspt/json` scans, so a manifest cut
    # short parses as a smaller manifest rather than failing -- and a smaller
    # manifest is a mod list nobody chose. See the note above `wholeJsonObject`.
    result.error = path & " is not one complete JSON object -- truncated, or " &
                   "not a registry at all. Nothing was read out of it: a " &
                   "manifest that stops half way through parses as a shorter " &
                   "manifest, and resolving against that would quietly drop " &
                   "every mod after the cut."
    return
  let doc = whole(text)
  if not doc.exists or not doc.isObject:
    result.error = path & " is not a JSON object"
    return
  let schema = doc.field("schema").asText("")
  if schema != SchemaId:
    result.error = path & " declares schema \"" & schema & "\"; this reader " &
                   "implements \"" & SchemaId & "\" and will not guess at the " &
                   "difference"
    return
  result.name = doc.field("registry.name").asText("registry")

  let mods = each(doc.field("mods"))
  for m in mods:
    let entry = readMod(m, result.warnings)
    if entry.id.len == 0:
      continue
    var duplicate = false
    for existing in result.mods:
      if existing.id == entry.id:
        duplicate = true
    if duplicate:
      # Two entries for one id would make "which version is this" depend on
      # which one the reader happened to hit first.
      result.warnings.add entry.id & " appears twice; the second was ignored"
      continue
    result.mods.add entry

  let lists = each(doc.field("lists"))
  for l in lists:
    let entry = readList(l, result.warnings)
    if entry.id.len == 0:
      continue
    var duplicate = false
    for existing in result.lists:
      if existing.id == entry.id:
        duplicate = true
    if duplicate:
      result.warnings.add entry.id & " appears twice; the second was ignored"
      continue
    result.lists.add entry

  if result.mods.len == 0:
    # Valid, well-formed, and describes nothing. It is not an error -- the file
    # says what it says -- but it is never what anybody meant, and it is the
    # input that makes a resolution come back empty with no fault anywhere to
    # explain it. Named here so that `selectionWriteFault` in `manager.nim` has
    # something to refuse on, and so the panel says it rather than showing an
    # empty table.
    result.warnings.add path & " parses but has no mods in it, so nothing can " &
                        "resolve from it"

  result.ok = true
  result.error = ""

proc loadRegistry*(path: string): Registry =
  result = parseRegistry(readTextFile(path), path)

# ---------------------------------------------------------------------------
# Lookup
# ---------------------------------------------------------------------------

const MaxIdBytes* = 80
  ## The panel's fixed row field -- `registry/README.md`, "What the in-game
  ## panel needs from an entry". `registry/validate.nim` refuses a longer id in
  ## a manifest; this is the same number, applied to an id that arrives from
  ## somewhere else.

proc idFault*(id: string): string =
  ## "" when `id` is shaped like a mod or list id, and a sentence naming the
  ## fault when it is not.
  ##
  ## Checked by every route that takes an id, *before* the id is looked up --
  ## not instead of it. A lookup already refuses anything the registry does not
  ## have, but it refuses it by quoting the id back into an error body, a log
  ## line and, on the routes that set an override or write a list, into the
  ## player's selection store. Four kilobytes of quotes, backslashes and NULs
  ## should not travel that far to arrive at the same "no", and a store key or
  ## a panel row is not the place to find out that it did.
  ##
  ## The charset is the registry's own: ids are reverse-DNS, `[A-Za-z0-9._-]`,
  ## and nothing in this pipeline has ever produced anything else. Bytes above
  ## 0x7F are refused by the same rule, which also disposes of "is this valid
  ## UTF-8" -- an id is not text that needs an encoding, it is a name.
  if id.len == 0:
    return "no id was given"
  if id.len > MaxIdBytes:
    return "an id of " & $id.len & " bytes is not an id; the limit is " &
           $MaxIdBytes & " bytes, which is what the panel can draw"
  for i in 0 ..< id.len:
    let ch = id[i]
    let okChar = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                 (ch >= '0' and ch <= '9') or ch == '.' or ch == '_' or
                 ch == '-'
    if not okChar:
      return "an id may only contain letters, digits, `.`, `_` and `-`; " &
             "there is a byte (0x" & $ord(ch) & ") at position " & $i &
             " that is none of those"
  result = ""

proc findMod*(reg: Registry; id: string; outIndex: var int): bool =
  outIndex = -1
  for i in 0 ..< reg.mods.len:
    if reg.mods[i].id == id:
      outIndex = i
      return true
  result = false

proc findList*(reg: Registry; id: string; outIndex: var int): bool =
  outIndex = -1
  for i in 0 ..< reg.lists.len:
    if reg.lists[i].id == id:
      outIndex = i
      return true
  result = false

proc hasSide*(m: ModEntry; side: string): bool =
  for s in m.sides:
    if s == side:
      return true
  result = false

proc sideName*(): string =
  ## The registry spells sides the way `exportMod` does.
  let s = side()
  if s == sideServer: return "server"
  if s == sideClient: return "client"
  result = "sim"
