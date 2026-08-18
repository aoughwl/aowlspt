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

proc readTextFile*(path: string): string =
  ## `readFile` is `{.raises.}` in nimony, so every call is wrapped. The empty
  ## string is the failure, and the caller turns it into a message that names
  ## the path — a mod that cannot say *which* file it could not read is a
  ## twenty-minute problem instead of a ten-second one.
  result = ""
  try:
    result = readFile(path)
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
                    loadAfter: @[], tags: @[])
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
                   inherits: @[], entries: @[])
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

  result.ok = true
  result.error = ""

proc loadRegistry*(path: string): Registry =
  result = parseRegistry(readTextFile(path), path)

# ---------------------------------------------------------------------------
# Lookup
# ---------------------------------------------------------------------------

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
