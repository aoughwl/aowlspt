## `aowl importdb` -- build the emulator's database out of a real SPT install.
##
##     aowl importdb --from D:\SPT
##     aowl importdb --from D:\SPT --only items,handbook,traders --out C:\tmp\db
##     aowl importdb --from D:\SPT --survey
##
## The emulator (`mods/tarkov`) answers the client out of `<root>\db.json`, and
## every database it has been tested against is a hand-written fixture of a few
## dozen entries. A person cannot run it that way: a real client wants the real
## item table, the handbook, traders and their assorts, quests, the hideout,
## locations and their loot, globals, settings and locales. SPT ships all of
## that on disk as ordinary JSON, in a layout that is very close to the one the
## emulator reads -- close enough that this importer is mostly a *splice*, not
## a translation.
##
## Three things about it are deliberate.
##
## **It never writes into the source.** The SPT install is opened read-only,
## and *every* path this program writes to -- `--out` and `--report` alike --
## goes through `refusesWrite` before anything is opened, with the reason
## printed. A tool that regenerates a database is a tool that will be run
## repeatedly and half-attended, and the failure mode of getting that wrong is
## somebody's game install. It was `--report` that got it wrong: the refusal
## existed, it was documented, and it was wired to one of the two flags.
##
## **It converts rather than reshapes the emulator.** Where SPT's shape and the
## emulator's differ -- `prestige.json` is `{elements:[...]}` where the mod
## wants the array, `locales/menu/en.json` is `{menu:{...}}` where the mod wants
## the inner map -- the *importer* bends. The emulator's shapes are pinned by
## the tests and by other people's work in that directory.
##
## **Size is the engineering problem, so the subset is a documented choice.**
## The full SPT database is 671.48 MiB on disk, of which 548.10 MiB is loose
## loot: one map's `looseLoot.json` is 42 MB and already minified. Everything
## else, minified, is 39.40 MiB. So loose loot is opt-in per map (`--loose`)
## and everything else is in by default, and both ends of that are named on the
## command line rather than silently truncated. `docs/IMPORTDB.md` has the
## measurements the default is chosen from; `--survey` re-derives them.
##
## The **reason** it is opt-in has changed, and the old one is retired: it was
## that `dbWrite` replaced the whole document, which is no longer true (a patch
## went from 171 ms to 6.1 ms on the 41 MB database). What actually costs is one
## route — `/client/locations` splices the whole `locations` subtree verbatim,
## so importing loose loot does not merely enlarge the database, it enlarges a
## single response by all of it: **587.49 MiB imported, a 560 MB response body,
## 19.1 s**, to draw a list of nineteen maps. Per-map stays right because a
## player raids one map. Making it the default is a change in `mods/tarkov`,
## not here.
##
## What comes out is **BSG's data by way of SPT's**. It is not committed to this
## repository and never goes in a release. This tool exists so that each person
## produces it locally, on demand, from the install they already own.

import std/[strutils, syncio, cmdline, sets, algorithm]
import aowlsptinstall/[winfs, log]

const Usage = """
importdb -- build the emulator's db.json from an SPT installation

  aowl importdb --from PATH [--out PATH] [options]

  --from PATH      an SPT install (D:\SPT), or its SPT_Data\database directory.
                   Opened read-only; neither --out nor --report may name a
                   path under it.
  --out PATH       where db.json goes. A directory, or a path ending in .json.
                   Default: <repo>\build\db\db.json
  --only LIST      comma-separated sections, instead of the default set:
                     items handbook quests repeatable customization
                     achievements prestige profiles globals settings locales
                     traders hideout locations bots
  --skip LIST      sections to leave out of the default set
  --maps LIST      which locations to import (default: all)
  --loose LIST     maps whose looseLoot to EMBED in db.json: none (default),
                   all, or a comma-separated list of map names. 42 MB for one
                   map, 548 MiB for all thirteen -- see --loose sidecar.
  --loose sidecar  write each map's looseLoot to <outdir>\looseloot\<map>.json
                   instead of embedding it. The backend reads one of these at
                   raid start and drops it again, so the resident cost is one
                   map for the length of one loot build rather than all
                   thirteen for the life of the process.
  --locales LIST   languages to import (default: en). "all" for every one,
                   +46 MiB. Include en whatever else you ask for: three
                   modules fall back to locales.global.en by name.
  --pretty         do not minify (roughly 1.6x the bytes, for reading by hand)
  --no-check       skip the self-check pass
  --strict         exit non-zero when the self-check finds a dangling reference
  --survey         walk the source, print an inventory, write nothing
  --report PATH    write the survey/import report to a markdown file. Refused
                   if inside --from, on the same check as --out.
  -h, --help       this
"""

var gFailures = 0
var gStrict = false

# ---------------------------------------------------------------------------
# A JSON scanner
#
# Not a parser: the importer never needs a value's *meaning*, only where it
# begins and ends, so that a subtree can be spliced into the output verbatim.
# The same shape the backend's own `jsondb` uses, for the same reason -- a
# parsed tree would need a mutable dynamic value type nimony does not give
# cheaply, and copying 19 MB of items into one would be the whole runtime.
# ---------------------------------------------------------------------------

proc skipWs(s: string; i: var int) =
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i

proc skipString(s: string; i: var int): bool =
  ## `i` is at the opening quote; leaves it just past the closing one.
  if i >= s.len or s[i] != '"':
    return false
  inc i
  while i < s.len:
    if s[i] == '\\':
      inc i, 2
      continue
    if s[i] == '"':
      inc i
      return true
    inc i
  result = false

proc skipValue(s: string; i: var int): bool =
  ## Leaves `i` just past one complete JSON value. Depth-counting rather than
  ## parsing.
  skipWs(s, i)
  if i >= s.len:
    return false
  if s[i] == '"':
    return skipString(s, i)
  if s[i] == '{' or s[i] == '[':
    var depth = 0
    while i < s.len:
      let c = s[i]
      if c == '"':
        if not skipString(s, i):
          return false
        continue
      if c == '{' or c == '[':
        inc depth
      elif c == '}' or c == ']':
        dec depth
        if depth == 0:
          inc i
          return true
      inc i
    return false
  # A number, `true`, `false` or `null`: everything up to the next structural
  # character. Nothing here has to know which of those it was.
  while i < s.len and s[i] != ',' and s[i] != '}' and s[i] != ']' and
        s[i] != ' ' and s[i] != '\n' and s[i] != '\r' and s[i] != '\t':
    inc i
  result = true

proc unquoted(s: string): string =
  ## A JSON string literal to its text. Only the escapes that occur in the
  ## keys this tool compares -- ids, template names, locale keys -- are
  ## unescaped; a `\uXXXX` is left as written, because it is never one of the
  ## things being matched and mangling it would be worse than keeping it.
  result = ""
  if s.len < 2:
    return s
  var i = 1
  while i < s.len - 1:
    if s[i] == '\\' and i + 1 < s.len - 1:
      let c = s[i + 1]
      if c == 'n': result.add '\n'
      elif c == 't': result.add '\t'
      elif c == 'r': result.add '\r'
      elif c == 'u':
        result.add "\\u"
        inc i, 2
        continue
      else: result.add c
      inc i, 2
      continue
    result.add s[i]
    inc i

proc memberRaw*(s: string; key: string): string =
  ## The raw text of one member of the object `s`, or "" when it is not there.
  result = ""
  var i = 0
  skipWs(s, i)
  if i >= s.len or s[i] != '{':
    return
  inc i
  while true:
    skipWs(s, i)
    if i >= s.len or s[i] == '}':
      return
    if s[i] != '"':
      return
    let ks = i
    if not skipString(s, i):
      return
    let k = unquoted(s.substr(ks, i - 1))
    skipWs(s, i)
    if i >= s.len or s[i] != ':':
      return
    inc i
    skipWs(s, i)
    let vs = i
    if not skipValue(s, i):
      return
    if k == key:
      return s.substr(vs, i - 1)
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc memberSpan(s: string; lo, hi: int; key: string;
                vs, ve: var int): bool =
  ## The span of one member of the object occupying `s[lo ..< hi]`, as offsets
  ## into `s`. `memberRaw` above answers the same question by *copying* the
  ## value out, which is the right shape when the value is a quest and the
  ## wrong one when it is `templates.items` -- 12 MB, or 575 MB with loose
  ## loot, copied to find out whether a key is there at all.
  var i = lo
  skipWs(s, i)
  if i >= hi or s[i] != '{':
    return false
  inc i
  while true:
    skipWs(s, i)
    if i >= hi or s[i] == '}':
      return false
    if s[i] != '"':
      return false
    let ks = i
    if not skipString(s, i):
      return false
    let k = unquoted(s.substr(ks, i - 1))
    skipWs(s, i)
    if i >= hi or s[i] != ':':
      return false
    inc i
    skipWs(s, i)
    let a = i
    if not skipValue(s, i):
      return false
    if k == key:
      vs = a
      ve = i
      return true
    skipWs(s, i)
    if i < hi and s[i] == ',':
      inc i

proc pathSpan*(s, path: string; vs, ve: var int): bool =
  ## A dotted path -- the same spelling `dbRead` takes -- resolved to a span of
  ## `s`. False when any segment along the way is not there.
  var lo = 0
  var hi = s.len
  for part in split(path, '.'):
    var a = 0
    var b = 0
    if not memberSpan(s, lo, hi, part, a, b):
      return false
    lo = a
    hi = b
  vs = lo
  ve = hi
  result = true

proc objectKeys*(s: string): seq[string] =
  ## Every member name of an object, without copying any of the values. This is
  ## what turns 12 MB of item templates into 4,673 ids for a couple of hundred
  ## kilobytes.
  result = @[]
  var i = 0
  skipWs(s, i)
  if i >= s.len or s[i] != '{':
    return
  inc i
  while true:
    skipWs(s, i)
    if i >= s.len or s[i] == '}':
      return
    if s[i] != '"':
      return
    let ks = i
    if not skipString(s, i):
      return
    result.add unquoted(s.substr(ks, i - 1))
    skipWs(s, i)
    if i >= s.len or s[i] != ':':
      return
    inc i
    if not skipValue(s, i):
      return
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc objectMembers*(s: string; keys: var seq[string]; vals: var seq[string]) =
  keys = @[]
  vals = @[]
  var i = 0
  skipWs(s, i)
  if i >= s.len or s[i] != '{':
    return
  inc i
  while true:
    skipWs(s, i)
    if i >= s.len or s[i] == '}':
      return
    if s[i] != '"':
      return
    let ks = i
    if not skipString(s, i):
      return
    let k = unquoted(s.substr(ks, i - 1))
    skipWs(s, i)
    if i >= s.len or s[i] != ':':
      return
    inc i
    skipWs(s, i)
    let vs = i
    if not skipValue(s, i):
      return
    keys.add k
    vals.add s.substr(vs, i - 1)
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc arrayItems*(s: string): seq[string] =
  result = @[]
  var i = 0
  skipWs(s, i)
  if i >= s.len or s[i] != '[':
    return
  inc i
  while true:
    skipWs(s, i)
    if i >= s.len or s[i] == ']':
      return
    let vs = i
    if not skipValue(s, i):
      return
    result.add s.substr(vs, i - 1)
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc textOf*(s: string; key: string): string =
  ## A string member's text, unquoted. Empty when absent or not a string.
  let raw = memberRaw(s, key)
  if raw.len >= 2 and raw[0] == '"':
    return unquoted(raw)
  result = ""

proc stringsOf*(s: string; key: string): seq[string] =
  ## A member that is either a string or an array of strings, as a list. Quest
  ## conditions use both spellings for `target` and the difference is not
  ## meaningful -- one target or several.
  result = @[]
  let raw = memberRaw(s, key)
  if raw.len == 0:
    return
  if raw[0] == '"':
    result.add unquoted(raw)
    return
  if raw[0] == '[':
    let items = arrayItems(raw)
    for it in items:
      if it.len >= 2 and it[0] == '"':
        result.add unquoted(it)

proc topShape(s: string): string =
  ## "object, N members" / "array, N items" / "scalar" -- what the survey
  ## prints. Cheap: it counts one level and skips the rest.
  var i = 0
  skipWs(s, i)
  if i >= s.len:
    return "empty"
  if s[i] == '{':
    let ks = objectKeys(s)
    return "object, " & $ks.len & " keys"
  if s[i] == '[':
    let its = arrayItems(s)
    return "array, " & $its.len & " items"
  result = "scalar"

# ---------------------------------------------------------------------------
# Minifying
#
# SPT ships its database pretty-printed -- two-space indented, one member per
# line -- and the emulator never reads a byte of that whitespace. Stripping it
# takes the import from 68 MB to 41 MB, and every one of those bytes is a byte
# the backend holds in memory, indexes, and copies on `dbWrite`.
#
# The exception is loose loot, which SPT already ships minified: 42 MB of
# `bigmap/looseLoot.json` is 42 MB either way. That is why the size problem
# there is answered by leaving it out rather than by squeezing it.
# ---------------------------------------------------------------------------

proc minified(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '"':
      let start = i
      if not skipString(s, i):
        # An unterminated string means the file is not JSON. Copy the rest
        # verbatim rather than silently dropping it: the checker downstream
        # will say so, and a truncated file is better evidence than a
        # rearranged one.
        result.add s.substr(start, s.len - 1)
        return
      result.add s.substr(start, i - 1)
    elif c == ' ' or c == '\t' or c == '\n' or c == '\r':
      inc i
    else:
      result.add c
      inc i

# ---------------------------------------------------------------------------
# Reading the source
# ---------------------------------------------------------------------------

proc readSource(path: string; into: var string): bool =
  if not fileExists(path):
    return false
  result = readTextFile(path, into)
  if not result:
    warn "could not read " & path

proc loadJson(path: string; pretty: bool): string =
  ## One source file, ready to splice. Empty when it is not there -- half of
  ## these are optional, and a missing optional file is not an error.
  var text = ""
  if not readSource(path, text):
    return ""
  if text.len == 0:
    return ""
  if pretty:
    return text
  result = minified(text)

# ---------------------------------------------------------------------------
# The output document
# ---------------------------------------------------------------------------

proc addKey(o: var string; first: var bool; key: string) =
  if not first:
    o.add ","
  first = false
  o.add "\""
  o.add key
  o.add "\":"

proc addMember(o: var string; first: var bool; key, valueJson: string) =
  if valueJson.len == 0:
    return
  addKey(o, first, key)
  o.add valueJson

# ---------------------------------------------------------------------------
# What the self-check holds
#
# Kept while the document is built rather than re-read from it afterwards: the
# finished database is tens of megabytes and re-parsing it to check it would
# double the peak memory for no additional truth.
# ---------------------------------------------------------------------------

var gItemIds = initHashSet[string]()
var gQuestIds = initHashSet[string]()
var gTraderIds = initHashSet[string]()
var gLocaleKeys = initHashSet[string]()
var gHandbook = ""
var gQuests = ""
var gProduction = ""
var gAssorts: seq[string] = @[]
var gAssortOwners: seq[string] = @[]
var gLocationIds: seq[string] = @[]
var gAreaTypes = initHashSet[string]()
var gRepeatable = ""
var gRepeatableConfig = ""

# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

const AllSections = ["items", "handbook", "quests", "repeatable",
                     "customization", "achievements", "prestige", "profiles",
                     "globals", "settings", "locales", "traders", "hideout",
                     "locations", "bots"]

proc byName(a, b: string): int =
  ## nimony's `sort` wants an explicit comparator. Ordering the walk's output
  ## is what makes two imports of the same install produce the same bytes --
  ## a directory listing is in whatever order the file system feels like.
  if a < b: -1
  elif a > b: 1
  else: 0

proc splitList(s: string): seq[string] =
  result = @[]
  for part in split(s, ','):
    let t = strip(part)
    if t.len > 0:
      result.add t

proc mib(bytes: int): string =
  ## Two decimals of MiB. `$` on a float in nimony prints more digits than a
  ## size wants, so the rounding is done in integers.
  let hundredths = (bytes * 100 + 524288) div 1048576
  result = $(hundredths div 100) & "." &
           (if hundredths mod 100 < 10: "0" else: "") & $(hundredths mod 100) &
           " MiB"

# ---------------------------------------------------------------------------
# The survey
# ---------------------------------------------------------------------------

proc survey(db: string; report: var string) =
  ## Walk the source database and describe it: every file, its size, and its
  ## top-level shape. This is the map for everyone who comes after -- an
  ## importer is only trustworthy if the thing it read is written down.
  heading "Survey of " & db
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(db, files, dirs)
  sort(files, byName)

  report.add "| file | bytes | shape |\n|---|---:|---|\n"
  var total = 0
  var loose = 0
  for rel in files:
    let full = joinPath(db, rel)
    let size = int(fileSizeOf(full))
    if size < 0:
      continue
    total = total + size
    if endsWith(toLowerAscii(rel), "looseloot.json"):
      loose = loose + size
    var shape = "(not read)"
    # Reading every file to describe it would mean reading 671 MiB, most of it
    # loose loot nobody is going to import. The big ones are described by their
    # name and size, which is what the reader wants from them anyway.
    if size < 4_000_000:
      var text = ""
      if readSource(full, text):
        shape = topShape(text)
    report.add "| `" & rel & "` | " & $size & " | " & shape & " |\n"
    line "  " & rel & "  " & $size & "  " & shape

  ok $files.len & " files, " & mib(total) & " total, of which " &
     mib(loose) & " is loose loot"
  report.add "\n" & $files.len & " files, " & mib(total) & " total, " &
             mib(loose) & " of it loose loot.\n"

# ---------------------------------------------------------------------------
# The self-check
#
# "It produced a file" is not the same claim as "the emulator can serve it".
# These are the invariants the emulator's own code depends on, asserted against
# the data that is about to be handed to it:
#
#   * every handbook entry names a template that exists -- `handbookPrice` and
#     the flea market are both built by walking the handbook and looking the
#     template up;
#   * every assort item names a template that exists -- an assort offer with no
#     template is an item the trader screen draws and the client cannot buy;
#   * every quest condition that names an item, a trader or another quest names
#     one that exists -- `emu/questcond` resolves all three;
#   * every hideout recipe's inputs and its area exist.
#
# A dangling reference is reported with counts and a sample rather than
# aborting: real data has some, and a tool that refuses the whole import over
# three unreachable quest targets is a tool nobody can use. `--strict` is there
# for the run that wants the opposite.
# ---------------------------------------------------------------------------

proc reportRefs(what: string; total, missing: int; sample: string;
                report: var string) =
  let lineText = what & ": " & $total & " checked, " & $missing & " dangling"
  if missing == 0:
    ok lineText
  else:
    warn lineText & (if sample.len > 0: " (e.g. " & sample & ")" else: "")
    if gStrict:
      inc gFailures
  report.add "- " & lineText &
             (if sample.len > 0 and missing > 0: " (e.g. `" & sample & "`)"
              else: "") & "\n"

# ---------------------------------------------------------------------------
# What the emulator actually reads
#
# The reference-integrity checks below ask whether the *contents* of a table
# hang together. This one asks the question underneath it: **is the table there
# at all.**
#
# It exists because that question kept being answered from memory. Four tables
# grew a route in `mods/tarkov` in a single day -- `hideout.customisation`,
# `hideout.qte`, `templates.customization`, `globals.config.Health` -- and each
# time the importer's status was re-derived by reading a sentence in a document
# rather than by looking at the data. A table that is read and not imported does
# not error anywhere: `dbRead` answers "not there", every reader here treats
# that as "the database does not have this", and the client gets an empty
# hideout screen with `err: 0` on the wire.
#
# So the list below is the *inventory of paths `mods/tarkov` reads with a
# literal spelling*, and it is checked against the document that is about to be
# written. Regenerate it with:
#
#     grep -rno 'dbRead("[^"]*"\|table("[^"]*"\|dbList("[^"]*"\|sub(d, "[^"]*"' mods/tarkov --include=*.nim
#
# and drop the ones built by concatenation (`"traders." & id & ".base"`), whose
# container is on the list instead. Paths in a section the run deselected are
# reported as such rather than counted, and a missing one in a section that
# *was* selected is a finding -- the same treatment, and the same `--strict`
# escalation, as a dangling reference.
#
# One path the emulator reads is deliberately **not** on this list, and saying
# so here is the point: `weather`. See the note at the end of `checkReadPaths`.
# ---------------------------------------------------------------------------

const ReadPath = [
  "templates.items", "templates.handbook.Items", "templates.handbook.Categories",
  "templates.quests", "templates.customization", "templates.achievements",
  "templates.prestige", "templates.profiles",
  "templates.repeatableQuests.templates",
  "templates.repeatableQuests.data", "configs.quest.repeatableQuests",
  "globals.ItemPresets", "globals.config.Health", "globals.config.RagFair",
  "globals.config.RepairSettings", "globals.config.Mastering",
  "globals.config.SkillsSettings", "settings",
  "locales.global.en", "locales.menu.en", "locales.languages",
  "traders", "hideout.areas", "hideout.production", "hideout.settings",
  "hideout.qte", "hideout.customisation", "locations", "bots.core",
  "bots.types"]

const ReadSection = [
  "items", "handbook", "handbook",
  "quests", "customization", "achievements",
  "prestige", "profiles", "repeatable",
  "repeatable", "repeatable",
  "globals", "globals", "globals",
  "globals", "globals",
  "globals", "settings",
  "locales", "locales", "locales",
  "traders", "hideout", "hideout", "hideout",
  "hideout", "hideout", "locations", "bots",
  "bots"]

const ReadBy = [
  "emu/templates, emu/bots, emu/grid", "emu/market, emu/production, emu/templates",
  "emu/market",
  "emu/quests", "emu/customise", "emu/achievements",
  "tarkov.onPrestigeList", "emu/profile", "emu/repeatable",
  "emu/repeatable", "emu/repeatable",
  "emu/loot", "emu/health", "emu/market",
  "emu/repair", "emu/skills",
  "emu/skills", "tarkov.onSettings",
  "emu/templates, emu/dialogue, emu/market", "emu/templates", "emu/templates",
  "emu/traders, emu/trading, emu/market", "emu/hideout", "emu/production",
  "emu/production, tarkov.onHideoutSettings",
  "emu/gym", "emu/decorate", "tarkov.onLocations, emu/raid, emu/loot",
  "emu/bots, tarkov.onBotLimit",
  "emu/bots, emu/scav"]

# `false` for the one path whose absence `docs/IMPORTDB.md` already promises is
# a warning and not a failure: `configs\quest.json` is a sibling of the database
# rather than part of it, and an install without it still produces a database
# that serves -- `activityPeriods` answers an empty list.
const ReadRequired = [
  true, true, true,
  true, true, true,
  true, true,
  true, false,
  true, true, true,
  true, true,
  true, true,
  true, true, true,
  true, true, true, true,
  true, true, true, true,
  true]

proc checkReadPaths(document: string; want: HashSet[string];
                    report: var string) =
  report.add "\n### Tables the emulator reads\n\n"
  var present = 0
  var absent = 0
  var deselected = 0
  var i = 0
  while i < ReadPath.len:
    let path = ReadPath[i]
    var vs = 0
    var ve = 0
    if pathSpan(document, path, vs, ve):
      inc present
      report.add "- `" & path & "` -- " & $(ve - vs) & " bytes -- " &
                 ReadBy[i] & "\n"
    elif not contains(want, ReadSection[i]):
      inc deselected
      report.add "- `" & path & "` -- absent; section `" & ReadSection[i] &
                 "` was not selected for this run\n"
    else:
      inc absent
      warn path & " is absent, and " & ReadBy[i] & " reads it"
      report.add "- **`" & path & "` -- absent, and " & ReadBy[i] &
                 " reads it**\n"
      if ReadRequired[i] and gStrict:
        inc gFailures
    inc i
  let lineText = "database paths mods/tarkov reads: " & $present &
                 " present, " & $absent & " absent" &
                 (if deselected > 0:
                    ", " & $deselected & " in sections this run left out"
                  else: "")
  if absent == 0:
    ok lineText
  else:
    warn lineText
  report.add "\n" & lineText & "\n"

  # The one read path this importer will not fill, said out loud so that it is
  # not filed as a missing import for a fifth time.
  #
  # `emu/raid.weather` reads `weather` and expects the *response* --
  # `{season, acceleration, weather: {cloud, wind_speed, fog, temp, ...}}`.
  # SPT's `configs\weather.json` is not that. It is the generator's settings:
  # `presetWeights.SUNNY.clouds` is a weight table mapping a cloud value to how
  # often it should be rolled. Splicing it in would hand the client a forecast
  # made of weight tables, with none of the members it reads -- strictly worse
  # than the dull-but-complete constant `emu/raid` falls back to. Rendering a
  # forecast out of those weights is a generator, and a generator that invents
  # numbers is not what a splice tool should grow.
  line "  weather        read by emu/raid and deliberately not imported: " &
       "configs\\weather.json is the generator's settings, not a forecast"
  report.add "\n`weather` is read by `emu/raid` and deliberately not " &
             "imported: SPT's `configs\\weather.json` holds the weather " &
             "generator's weight tables, not a rendered forecast, so the " &
             "emulator's own default answers and the path stays open for a " &
             "weather mod to write.\n"

proc selfCheck(document: string; want: HashSet[string];
               report: var string) =
  heading "Self-check"
  report.add "\n## Self-check\n\n"
  report.add "- templates: " & $gItemIds.len & "\n"
  report.add "- quests: " & $gQuestIds.len & "\n"
  report.add "- traders: " & $gTraderIds.len & "\n"
  line "  " & $gItemIds.len & " item templates, " & $gQuestIds.len &
       " quests, " & $gTraderIds.len & " traders"

  checkReadPaths(document, want, report)

  # Handbook -> templates
  if gHandbook.len > 0 and gItemIds.len > 0:
    let items = arrayItems(memberRaw(gHandbook, "Items"))
    var missing = 0
    var sample = ""
    for entry in items:
      let id = textOf(entry, "Id")
      if id.len > 0 and not contains(gItemIds, id):
        inc missing
        if sample.len == 0: sample = id
    reportRefs("handbook entries naming a real template", items.len, missing,
               sample, report)

  # Assorts -> templates
  if gAssorts.len > 0 and gItemIds.len > 0:
    var total = 0
    var missing = 0
    var sample = ""
    var i = 0
    while i < gAssorts.len:
      let items = arrayItems(memberRaw(gAssorts[i], "items"))
      for it in items:
        let tpl = textOf(it, "_tpl")
        if tpl.len == 0:
          continue
        inc total
        if not contains(gItemIds, tpl):
          inc missing
          if sample.len == 0: sample = gAssortOwners[i] & " " & tpl
      inc i
    reportRefs("assort items naming a real template", total, missing, sample,
               report)

  # Quests -> templates, traders, quests
  if gQuests.len > 0:
    var qk: seq[string] = @[]
    var qv: seq[string] = @[]
    objectMembers(gQuests, qk, qv)
    var itemRefs = 0
    var itemMissing = 0
    var itemSample = ""
    var traderRefs = 0
    var traderMissing = 0
    var traderSample = ""
    var questRefs = 0
    var questMissing = 0
    var questSample = ""
    var i = 0
    while i < qv.len:
      let quest = qv[i]
      let qid = qk[i]
      let trader = textOf(quest, "traderId")
      if trader.len > 0 and gTraderIds.len > 0:
        inc traderRefs
        if not contains(gTraderIds, trader):
          inc traderMissing
          if traderSample.len == 0: traderSample = qid & " -> " & trader
      let conds = memberRaw(quest, "conditions")
      var gk: seq[string] = @[]
      var gv: seq[string] = @[]
      objectMembers(conds, gk, gv)
      var g = 0
      while g < gv.len:
        let group = arrayItems(gv[g])
        for cond in group:
          # A current dump flattens the condition; an older one wraps it in
          # `_props` under `_parent`. `emu/questcond` reads both, so the check
          # has to look in both places or it silently checks nothing.
          var kind = textOf(cond, "conditionType")
          if kind.len == 0: kind = textOf(cond, "_parent")
          var body = memberRaw(cond, "_props")
          if body.len == 0: body = cond
          let targets = stringsOf(body, "target")
          if kind == "HandoverItem" or kind == "FindItem" or
             kind == "LeaveItemAtLocation" or kind == "PlaceBeacon" or
             kind == "SellItemToTrader" or kind == "WeaponAssembly":
            if gItemIds.len > 0:
              for t in targets:
                inc itemRefs
                if not contains(gItemIds, t):
                  inc itemMissing
                  if itemSample.len == 0: itemSample = qid & " -> " & t
          elif kind == "Quest":
            for t in targets:
              inc questRefs
              if not contains(gQuestIds, t):
                inc questMissing
                if questSample.len == 0: questSample = qid & " -> " & t
          elif kind == "TraderLoyalty" or kind == "TraderStanding":
            if gTraderIds.len > 0:
              for t in targets:
                inc traderRefs
                if not contains(gTraderIds, t):
                  inc traderMissing
                  if traderSample.len == 0: traderSample = qid & " -> " & t
        inc g
      inc i
    reportRefs("quest conditions naming a real template", itemRefs,
               itemMissing, itemSample, report)
    reportRefs("quest references to another quest", questRefs, questMissing,
               questSample, report)
    reportRefs("quest references to a trader", traderRefs, traderMissing,
               traderSample, report)

  # Hideout production -> templates and areas
  if gProduction.len > 0:
    let recipes = arrayItems(memberRaw(gProduction, "recipes"))
    var inputs = 0
    var missing = 0
    var sample = ""
    var areaMissing = 0
    for r in recipes:
      let endProduct = textOf(r, "endProduct")
      if endProduct.len > 0 and gItemIds.len > 0:
        inc inputs
        if not contains(gItemIds, endProduct):
          inc missing
          if sample.len == 0: sample = endProduct
      let reqs = arrayItems(memberRaw(r, "requirements"))
      for q in reqs:
        let tpl = textOf(q, "templateId")
        if tpl.len > 0 and gItemIds.len > 0:
          inc inputs
          if not contains(gItemIds, tpl):
            inc missing
            if sample.len == 0: sample = tpl
      let area = memberRaw(r, "areaType")
      if area.len > 0 and gAreaTypes.len > 0 and not contains(gAreaTypes, area):
        inc areaMissing
    reportRefs("hideout recipe items naming a real template", inputs, missing,
               sample, report)
    if gAreaTypes.len > 0:
      reportRefs("hideout recipes whose area exists", recipes.len, areaMissing,
                 "", report)

  # Repeatable quests -> traders and templates.
  #
  # Two different tables and both are checked, because a generator built on
  # them fails silently in different ways: a quest skeleton pointing at a
  # trader that is not there is a daily nobody can hand in, and a target pool
  # naming templates that are not there is a "find 7 of X" for an X the client
  # cannot draw.
  #
  # What is deliberately **not** checked is `traderWhitelist.rewardBaseWhitelist`
  # in the config. Those are item **base class** ids -- `543be6564bdc2df4348b4568`
  # is the money class, not an item -- so checking them against the template
  # table would report every one of them as dangling and teach the reader to
  # ignore this section.
  if gRepeatable.len > 0:
    let kinds = memberRaw(gRepeatable, "templates")
    var kk: seq[string] = @[]
    var kv: seq[string] = @[]
    objectMembers(kinds, kk, kv)
    var traderRefs = 0
    var traderMissing = 0
    var traderSample = ""
    var costRefs = 0
    var costMissing = 0
    var costSample = ""
    var i = 0
    while i < kv.len:
      let trader = textOf(kv[i], "traderId")
      if trader.len > 0 and gTraderIds.len > 0:
        inc traderRefs
        if not contains(gTraderIds, trader):
          inc traderMissing
          if traderSample.len == 0: traderSample = kk[i] & " -> " & trader
      # `changeCost` is what a reroll costs: a template id and a count. A
      # dangling one is a reroll the player cannot pay for.
      for c in arrayItems(memberRaw(kv[i], "changeCost")):
        let tpl = textOf(c, "templateId")
        if tpl.len > 0 and gItemIds.len > 0:
          inc costRefs
          if not contains(gItemIds, tpl):
            inc costMissing
            if costSample.len == 0: costSample = kk[i] & " -> " & tpl
      inc i
    reportRefs("repeatable quest types naming a real trader", traderRefs,
               traderMissing, traderSample, report)
    reportRefs("repeatable reroll costs naming a real template", costRefs,
               costMissing, costSample, report)

    # The target pools, `data.<type>.itemsWhitelist` / `itemsBlacklist`, each
    # banded by `minPlayerLevel`.
    var poolRefs = 0
    var poolMissing = 0
    var poolSample = ""
    var dk: seq[string] = @[]
    var dv: seq[string] = @[]
    objectMembers(memberRaw(gRepeatable, "data"), dk, dv)
    var d = 0
    while d < dv.len:
      for listName in ["itemsWhitelist", "itemsBlacklist"]:
        for band in arrayItems(memberRaw(dv[d], listName)):
          for id in stringsOf(band, "itemIds"):
            if gItemIds.len > 0:
              inc poolRefs
              if not contains(gItemIds, id):
                inc poolMissing
                if poolSample.len == 0: poolSample = dk[d] & " -> " & id
      inc d
    reportRefs("repeatable target pools naming a real template", poolRefs,
               poolMissing, poolSample, report)

  if gRepeatableConfig.len > 0:
    var setRefs = 0
    var setMissing = 0
    var setSample = ""
    for one in arrayItems(gRepeatableConfig):
      let name = textOf(one, "name")
      for w in arrayItems(memberRaw(one, "traderWhitelist")):
        let trader = textOf(w, "traderId")
        if trader.len > 0 and gTraderIds.len > 0:
          inc setRefs
          if not contains(gTraderIds, trader):
            inc setMissing
            if setSample.len == 0: setSample = name & " -> " & trader
    reportRefs("repeatable quest sets naming a real trader", setRefs,
               setMissing, setSample, report)

  # Locales -> templates. Not a failure: a template with no localised name
  # renders as its id, which is ugly and not broken, and the count is the
  # useful thing to know before somebody reports it as a bug.
  if gLocaleKeys.len > 0 and gItemIds.len > 0:
    var missing = 0
    var sample = ""
    for id in gItemIds:
      if not contains(gLocaleKeys, id & " Name"):
        inc missing
        if sample.len == 0: sample = id
    let lineText = "templates with a localised name: " &
                   $(gItemIds.len - missing) & " of " & $gItemIds.len
    line "  " & lineText
    report.add "- " & lineText & "\n"

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

proc findDatabase(fromPath: string): string =
  ## The database directory inside whatever the user pointed at. SPT has moved
  ## this before, so it is looked for rather than assumed, and the path that
  ## was found is printed.
  let candidates = [
    joinPath(fromPath, "SPT_Runtime\\SPT_Data\\database"),
    joinPath(fromPath, "SPT_Data\\database"),
    joinPath(fromPath, "database"),
    fromPath]
  for c in candidates:
    if isDirectory(c) and fileExists(joinPath(c, "globals.json")):
      return c
  result = ""

proc refusesWrite(target, flag, src, db: string): bool =
  ## The one refusal that is not negotiable. Reading an SPT install is fine;
  ## writing into one is somebody's game, and a tool that regenerates a
  ## database will be run half-attended.
  ##
  ## It is a proc rather than three lines at the `--out` site because it was
  ## three lines at the `--out` site, and **`--report` therefore wrote
  ## wherever it was pointed**: `--from D:\SPT --report D:\SPT\report.md
  ## --survey` put an 18 KB file in the root of the install and printed
  ## `ok report ->`. The header of this file and `docs/IMPORTDB.md` both said
  ## the importer never writes into the source, and the check behind that
  ## sentence guarded one of the two paths this program writes to. Every
  ## write target goes through here now, which is the only arrangement in
  ## which "never" is a checkable claim rather than a remembered one.
  let dir = parentOf(target)
  if isUnder(target, src) or toLowerAscii(dir) == toLowerAscii(src) or
     isUnder(target, db) or toLowerAscii(dir) == toLowerAscii(db):
    err "refusing to write inside the source install"
    note "  " & flag & " " & target
    note "  is under " & src
    note "  This importer reads an SPT installation and never writes to" &
         " one: the source is somebody's game, and an import is a command" &
         " that gets re-run. Point " & flag & " outside it."
    return true
  result = false

proc main(): int =
  var fromPath = ""
  var outPath = ""
  var repo = ""
  var only: seq[string] = @[]
  var skips: seq[string] = @[]
  var maps: seq[string] = @[]
  var looseSpec = "none"
  var locales: seq[string] = @["en"]
  var pretty = false
  var doCheck = true
  var doSurvey = false
  var reportPath = ""

  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--from":
      inc i
      if i <= n: fromPath = paramStr(i)
    elif a == "--out":
      inc i
      if i <= n: outPath = paramStr(i)
    elif a == "--repo":
      inc i
      if i <= n: repo = paramStr(i)
    elif a == "--only":
      inc i
      if i <= n: only = splitList(paramStr(i))
    elif a == "--skip":
      inc i
      if i <= n: skips = splitList(paramStr(i))
    elif a == "--maps":
      inc i
      if i <= n: maps = splitList(paramStr(i))
    elif a == "--loose":
      inc i
      if i <= n: looseSpec = paramStr(i)
    elif a == "--locales":
      inc i
      if i <= n: locales = splitList(paramStr(i))
    elif a == "--pretty":
      pretty = true
    elif a == "--no-check":
      doCheck = false
    elif a == "--strict":
      gStrict = true
    elif a == "--survey":
      doSurvey = true
    elif a == "--report":
      inc i
      if i <= n: reportPath = paramStr(i)
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      err "unknown option: " & a
      echo Usage
      return 1
    inc i

  if fromPath.len == 0:
    err "importdb needs --from, an SPT installation"
    echo Usage
    return 1
  let src = absolutePathOf(fromPath)
  if not exists(src):
    err "no such path: " & src
    return 1
  let db = findDatabase(src)
  if db.len == 0:
    err "no SPT database under " & src
    note "  looked for SPT_Runtime\\SPT_Data\\database, SPT_Data\\database, " &
         "database, and the path itself"
    return 1

  # Checked here, before a byte is read or written, because `--survey`
  # returns before the `--out` check below is ever reached.
  var reportFile = ""
  if reportPath.len > 0:
    reportFile = absolutePathOf(reportPath)
    if refusesWrite(reportFile, "--report", src, db):
      return 1

  heading "importdb"
  line "  source  " & db & "  (read-only)"

  var report = "# Import report\n\nSource: `" & db & "`\n\n"

  if doSurvey:
    survey(db, report)
    if reportFile.len > 0:
      discard writeTextFile(reportFile, report)
      ok "report -> " & reportFile
    return 0

  # ---------------------------------------------------------------- the out
  if outPath.len == 0:
    if repo.len == 0:
      err "no --out, and no --repo to default it from"
      return 1
    outPath = joinPath(repo, "build\\db")
  var outFile = absolutePathOf(outPath)
  if not endsWith(toLowerAscii(outFile), ".json"):
    outFile = joinPath(outFile, "db.json")
  if refusesWrite(outFile, "--out", src, db):
    return 1

  let outDir = parentOf(outFile)

  # -------------------------------------------------------------- selection
  var want = initHashSet[string]()
  if only.len > 0:
    for s in only:
      var known = false
      for a in AllSections:
        if a == s: known = true
      if not known:
        err "unknown section: " & s
        return 1
      incl(want, s)
  else:
    for a in AllSections:
      incl(want, a)
  for s in skips:
    excl(want, s)

  var looseAll = false
  var looseSidecar = false
  var looseMaps: seq[string] = @[]
  if looseSpec == "all":
    looseAll = true
  elif looseSpec == "sidecar":
    looseSidecar = true
  elif looseSpec != "none" and looseSpec.len > 0:
    looseMaps = splitList(looseSpec)
  let looseDir = joinPath(outDir, "looseloot")
  if looseSidecar and not ensureDir(looseDir).ok:
    err "could not create " & looseDir
    return 1

  # ------------------------------------------------------------------ build
  heading "Converting"
  var o = ""
  var first = true
  o.add "{"

  # --- templates ---------------------------------------------------------
  let wantTemplates = contains(want, "items") or contains(want, "handbook") or
                      contains(want, "quests") or
                      contains(want, "repeatable") or
                      contains(want, "customization") or
                      contains(want, "achievements") or
                      contains(want, "prestige") or
                      contains(want, "profiles")
  if wantTemplates:
    addKey(o, first, "templates")
    o.add "{"
    var tf = true
    if contains(want, "items"):
      let text = loadJson(joinPath(db, "templates\\items.json"), pretty)
      if text.len > 0:
        let ids = objectKeys(text)
        for id in ids: incl(gItemIds, id)
        addMember(o, tf, "items", text)
        line "  items           " & $ids.len & " templates, " & mib(text.len)
      else:
        warn "no templates\\items.json"
    if contains(want, "handbook"):
      let text = loadJson(joinPath(db, "templates\\handbook.json"), pretty)
      if text.len > 0:
        gHandbook = text
        addMember(o, tf, "handbook", text)
        let items = arrayItems(memberRaw(text, "Items"))
        line "  handbook        " & $items.len & " priced entries"
    if contains(want, "quests"):
      let text = loadJson(joinPath(db, "templates\\quests.json"), pretty)
      if text.len > 0:
        gQuests = text
        let ids = objectKeys(text)
        for id in ids: incl(gQuestIds, id)
        addMember(o, tf, "quests", text)
        line "  quests          " & $ids.len & ", " & mib(text.len)
    if contains(want, "repeatable"):
      # `templates/repeatableQuests.json` -- the reference's
      # `RepeatableQuestDatabase`: `templates` (one quest skeleton per type),
      # `data` (the target pools, banded by player level), `rewards` (the item
      # ids no repeatable reward may be) and `samples`. Spliced verbatim under
      # the name the emulator reads it by, keeping SPT's own member casing --
      # the C# property names in the dump and the JSON keys on disk differ
      # everywhere else in this file too, and the mod reads the disk spelling.
      #
      # It carries the **change-condition cost**: `changeCost` (a template id
      # and a count) and `changeStandingCost`, per quest type. That is the one
      # number a reroll needs and it is the reason this section is worth
      # importing on its own rather than only alongside the config below.
      let text = loadJson(joinPath(db, "templates\\repeatableQuests.json"),
                          pretty)
      if text.len > 0:
        gRepeatable = text
        addMember(o, tf, "repeatableQuests", text)
        let kinds = objectKeys(memberRaw(text, "templates"))
        line "  repeatable      " & $kinds.len & " quest type(s)"
      else:
        warn "no templates\\repeatableQuests.json"
    if contains(want, "customization"):
      let text = loadJson(joinPath(db, "templates\\customization.json"), pretty)
      if text.len > 0:
        addMember(o, tf, "customization", text)
        line "  customization   " & $objectKeys(text).len & " suites"
    if contains(want, "achievements"):
      let text = loadJson(joinPath(db, "templates\\achievements.json"), pretty)
      if text.len > 0:
        addMember(o, tf, "achievements", text)
        line "  achievements    " & $arrayItems(text).len
    if contains(want, "profiles"):
      # `templates/profiles.json` -- the STARTING PROFILE per edition, per side.
      #
      # This is the table that decides what a new player spawns owning. Each
      # edition (`Standard`, `Edge Of Darkness`, ...) carries a `usec` and a
      # `bear` branch, and each of those a `character` (the profile document
      # BSG's own server hands back, with 205 inventory items for Standard usec
      # and 337 for Edge Of Darkness) plus a `trader` block holding
      # `initialLoyaltyLevel`, `initialStanding`, `jaegerUnlocked` and
      # `lockedByDefaultOverride`.
      #
      # Spliced verbatim, keyed by SPT's own display names, because `emu/profile`
      # resolves an edition by matching `character.Info.GameVersion` rather than
      # by the display name -- reshaping the keys here would put a second
      # spelling of the edition list in a second place.
      #
      # Without this section a fresh profile has no gear at all: `emu/profile`
      # falls back to five containers and a money stack, and says so loudly.
      let text = loadJson(joinPath(db, "templates\\profiles.json"), pretty)
      if text.len > 0:
        addMember(o, tf, "profiles", text)
        let editions = objectKeys(text)
        var withGear = 0
        for e in editions:
          let ch = memberRaw(memberRaw(memberRaw(text, e), "usec"), "character")
          if arrayItems(memberRaw(memberRaw(ch, "Inventory"), "items")).len > 0:
            inc withGear
        line "  profiles        " & $editions.len & " edition(s), " &
             $withGear & " with starting gear, " & mib(text.len)
      else:
        warn "no templates\\profiles.json -- every new profile will start " &
             "with no gear"
    if contains(want, "prestige"):
      # SPT's file is `{elements:[...]}`; `onPrestigeList` wraps whatever it
      # finds in `{elements: ...}` itself, so what goes in the database is the
      # array. Wrapping it twice gives the prestige screen an object where it
      # enumerates a list.
      let text = loadJson(joinPath(db, "templates\\prestige.json"), pretty)
      if text.len > 0:
        let elements = memberRaw(text, "elements")
        if elements.len > 0:
          addMember(o, tf, "prestige", elements)
          line "  prestige        " & $arrayItems(elements).len & " levels"
    o.add "}"

  # --- globals and settings ---------------------------------------------
  if contains(want, "globals"):
    let text = loadJson(joinPath(db, "globals.json"), pretty)
    if text.len > 0:
      addMember(o, first, "globals", text)
      line "  globals         " & mib(text.len)
  if contains(want, "settings"):
    let text = loadJson(joinPath(db, "settings.json"), pretty)
    if text.len > 0:
      addMember(o, first, "settings", text)
      line "  settings        " & mib(text.len)

  # --- the repeatable-quest config ----------------------------------------
  #
  # The one section here that does **not** come out of `database/`. Everything
  # else in this file is a splice of SPT's database directory; this is
  # `SPT_Data/configs/quest.json`, which is that server's own configuration
  # rather than BSG's data, and it is imported because the database half of
  # repeatable quests is not enough to generate one.
  #
  # What is in `templates/repeatableQuests.json` is the quest *skeletons* -- the
  # conditions, the change cost -- and the Completion target pool. What is only
  # here is everything that decides how many of them there are and what they
  # pay: the three sets (`Daily`, `Weekly`, `Scav`) with their `resetTime`,
  # `numQuests` and `minPlayerLevel`; `rewardScaling`, which is the reward
  # budget banded by player level; `traderWhitelist`, which says which traders
  # offer which types and what they may pay in; and `questConfig`, the per-type
  # level bands that size a quest's target counts.
  #
  # Only the `repeatableQuests` member is taken. The rest of `quest.json` --
  # `eventQuests`, `locationIdMap`, the profile black and white lists -- is
  # SPT's own machinery with no route here that reads it, and the rule this
  # importer follows is that a table nothing reads does not get imported.
  #
  # The path is a sibling of the database directory rather than a search,
  # because `configs` sits beside `database` inside `SPT_Data` in every layout
  # `findDatabase` knows. A missing file is a warning and not a failure: an
  # install without it still produces a database, and the generator answers
  # "no dailies" exactly as it did before this section existed.
  if contains(want, "repeatable"):
    let questConfig = loadJson(joinPath(parentOf(db), "configs\\quest.json"),
                               pretty)
    if questConfig.len > 0:
      let rq = memberRaw(questConfig, "repeatableQuests")
      if rq.len > 0:
        gRepeatableConfig = rq
        addKey(o, first, "configs")
        o.add "{"
        var cf = true
        addKey(o, cf, "quest")
        o.add "{"
        var qf = true
        addMember(o, qf, "repeatableQuests", rq)
        o.add "}"
        o.add "}"
        line "  repeatable cfg  " & $arrayItems(rq).len & " set(s)"
      else:
        warn "configs\\quest.json has no repeatableQuests"
    else:
      warn "no configs\\quest.json beside the database; repeatable " &
           "quests will have no reward budget and will not be generated"

  # --- locales ------------------------------------------------------------
  if contains(want, "locales"):
    var langs = locales
    if langs.len == 1 and langs[0] == "all":
      langs = @[]
      var files: seq[string] = @[]
      var dirs: seq[string] = @[]
      collectEntries(joinPath(db, "locales\\global"), files, dirs)
      for f in files:
        if endsWith(toLowerAscii(f), ".json"):
          langs.add f.substr(0, f.len - 6)
    addKey(o, first, "locales")
    o.add "{"
    var lf = true
    addKey(o, lf, "global")
    o.add "{"
    var gf = true
    var localeBytes = 0
    for lang in langs:
      let text = loadJson(joinPath(db, "locales\\global\\" & lang & ".json"),
                          pretty)
      if text.len > 0:
        if lang == "en":
          let ks = objectKeys(text)
          for k in ks: incl(gLocaleKeys, k)
        addMember(o, gf, lang, text)
        localeBytes = localeBytes + text.len
      else:
        warn "no locale " & lang
    o.add "}"
    addKey(o, lf, "menu")
    o.add "{"
    var mf = true
    for lang in langs:
      let text = loadJson(joinPath(db, "locales\\menu\\" & lang & ".json"),
                          pretty)
      if text.len > 0:
        # SPT wraps the menu strings in `{menu: {...}}`; `/client/menu/locale`
        # returns what is at `locales.menu.<lang>` verbatim, so the wrapper has
        # to come off here or every menu string is one level too deep.
        let inner = memberRaw(text, "menu")
        addMember(o, mf, lang, if inner.len > 0: inner else: text)
    o.add "}"
    let langsJson = loadJson(joinPath(db, "locales\\languages.json"), pretty)
    if langsJson.len > 0:
      addMember(o, lf, "languages", langsJson)
    o.add "}"
    line "  locales         " & $langs.len & " language(s), " &
         mib(localeBytes)

  # --- traders ------------------------------------------------------------
  if contains(want, "traders"):
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(joinPath(db, "traders"), files, dirs)
    sort(dirs, byName)
    addKey(o, first, "traders")
    o.add "{"
    var trf = true
    var count = 0
    var assortItems = 0
    for id in dirs:
      let base = loadJson(joinPath(db, "traders\\" & id & "\\base.json"),
                          pretty)
      if base.len == 0:
        continue
      incl(gTraderIds, id)
      addKey(o, trf, id)
      o.add "{"
      var bf = true
      addMember(o, bf, "base", base)
      let assort = loadJson(joinPath(db, "traders\\" & id & "\\assort.json"),
                            pretty)
      if assort.len > 0:
        addMember(o, bf, "assort", assort)
        gAssorts.add assort
        gAssortOwners.add id
        assortItems = assortItems + arrayItems(memberRaw(assort, "items")).len
      let qa = loadJson(joinPath(db, "traders\\" & id & "\\questassort.json"),
                        pretty)
      if qa.len > 0:
        addMember(o, bf, "questassort", qa)
      let dlg = loadJson(joinPath(db, "traders\\" & id & "\\dialogue.json"),
                         pretty)
      if dlg.len > 0:
        addMember(o, bf, "dialogue", dlg)
      o.add "}"
      inc count
    o.add "}"
    line "  traders         " & $count & ", " & $assortItems & " assort items"

  # --- hideout ------------------------------------------------------------
  if contains(want, "hideout"):
    addKey(o, first, "hideout")
    o.add "{"
    var hf = true
    # SPT keeps the areas added after the base game in a second file and merges
    # the two in its server at load. The emulator reads `hideout.areas` and
    # nothing else, so the merge happens here instead -- otherwise the Cultist
    # Circle (area type 21) is an area seventeen recipes produce into and the
    # hideout has never heard of, which is what the self-check reported before
    # this line existed.
    var areas = loadJson(joinPath(db, "hideout\\areas.json"), pretty)
    let custom = loadJson(joinPath(db, "hideout\\customAreas.json"), pretty)
    if areas.len > 2 and custom.len > 2 and areas[areas.len - 1] == ']' and
       custom[0] == '[':
      areas = areas.substr(0, areas.len - 2) & "," &
              custom.substr(1, custom.len - 1)
    if areas.len > 0:
      addMember(o, hf, "areas", areas)
      let list = arrayItems(areas)
      for a in list:
        let t = memberRaw(a, "type")
        if t.len > 0: incl(gAreaTypes, t)
    let prod = loadJson(joinPath(db, "hideout\\production.json"), pretty)
    if prod.len > 0:
      gProduction = prod
      addMember(o, hf, "production", prod)
    for extra in ["settings", "qte", "customisation"]:
      let text = loadJson(joinPath(db, "hideout\\" & extra & ".json"), pretty)
      if text.len > 0:
        addMember(o, hf, extra, text)
    o.add "}"
    let recipes = arrayItems(memberRaw(gProduction, "recipes"))
    line "  hideout         " & $arrayItems(areas).len & " areas, " &
         $recipes.len & " recipes"

  # --- locations ----------------------------------------------------------
  if contains(want, "locations"):
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(joinPath(db, "locations"), files, dirs)
    sort(dirs, byName)
    addKey(o, first, "locations")
    o.add "{"
    var lof = true
    var count = 0
    var looseBytes = 0
    var sidecarBytes = 0
    var sidecarCount = 0
    for name in dirs:
      if maps.len > 0:
        var wanted = false
        for m in maps:
          if m == name: wanted = true
        if not wanted:
          continue
      let base = loadJson(joinPath(db, "locations\\" & name & "\\base.json"),
                          pretty)
      if base.len == 0:
        continue
      # Keyed by the directory name, which is what the client sends as
      # `locationId` to `/client/location/getLocalloot` and what
      # `emu/raid.locationBase` looks up. `base._Id` is carried inside the
      # value, so a caller that has one can still find the other.
      addKey(o, lof, name)
      o.add "{"
      var mfirst = true
      addMember(o, mfirst, "base", base)
      for part in ["staticContainers", "staticLoot", "staticAmmo"]:
        let text = loadJson(
          joinPath(db, "locations\\" & name & "\\" & part & ".json"), pretty)
        if text.len > 0:
          addMember(o, mfirst, part, text)
      var takeLoose = looseAll
      for m in looseMaps:
        if m == name: takeLoose = true
      let looseSrc = joinPath(db, "locations\\" & name & "\\looseLoot.json")
      if takeLoose:
        let text = loadJson(looseSrc, pretty)
        if text.len > 0:
          addMember(o, mfirst, "looseLoot", text)
          looseBytes = looseBytes + text.len
      elif looseSidecar and exists(looseSrc):
        # Copied, not loaded and re-emitted: SPT already ships these
        # minified (42 MB of bigmap is 42 MB either way), so a
        # load/minify/write pass would hold 126 MiB of lighthouse in
        # memory to produce the bytes it started with. Named by the
        # DATABASE KEY, which is what `emu/raid.resolveLocation` hands
        # `lootFor`.
        let dst = joinPath(looseDir, name & ".json")
        if copyFileAt(looseSrc, dst).ok:
          sidecarBytes = sidecarBytes + int(fileSizeOf(dst))
          inc sidecarCount
        else:
          err "could not copy " & looseSrc & " -> " & dst
          gFailures = gFailures + 1
      o.add "}"
      gLocationIds.add name
      inc count
    o.add "}"
    line "  locations       " & $count & " maps" &
         (if looseBytes > 0: ", " & mib(looseBytes) & " of loose loot"
          else: ", no loose loot")
    if looseSidecar:
      line "  loose sidecars  " & $sidecarCount & " maps, " &
           mib(sidecarBytes) & " -> " & looseDir

  # --- bots ---------------------------------------------------------------
  if contains(want, "bots"):
    addKey(o, first, "bots")
    o.add "{"
    var bf = true
    let core = loadJson(joinPath(db, "bots\\core.json"), pretty)
    if core.len > 0:
      addMember(o, bf, "core", core)
    let baseText = loadJson(joinPath(db, "bots\\base.json"), pretty)
    if baseText.len > 0:
      addMember(o, bf, "base", baseText)
    addKey(o, bf, "types")
    o.add "{"
    var tf2 = true
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(joinPath(db, "bots\\types"), files, dirs)
    sort(files, byName)
    var count = 0
    var bytes = 0
    for f in files:
      if not endsWith(toLowerAscii(f), ".json"):
        continue
      let text = loadJson(joinPath(db, "bots\\types\\" & f), pretty)
      if text.len == 0:
        continue
      # The emulator lower-cases the role before looking it up
      # (`emu/bots.nim`), so the key is lower-cased here rather than relying on
      # the file system's case.
      addMember(o, tf2, toLowerAscii(f.substr(0, f.len - 6)), text)
      bytes = bytes + text.len
      inc count
    o.add "}"
    o.add "}"
    line "  bots            " & $count & " types, " & mib(bytes)

  o.add "}"

  # ------------------------------------------------------------------ write
  heading "Writing"
  let mk = ensureDir(outDir)
  if not mk.ok:
    err "could not create " & outDir & " (error " & $mk.err & ")"
    return 1
  let w = writeTextFile(outFile, o)
  if not w.ok:
    err "could not write " & outFile & " (error " & $w.err & ")"
    return 1
  ok outFile & "  " & mib(o.len) & " (" & $o.len & " bytes)"

  report.add "\n## Result\n\n- output: `" & outFile & "`\n- size: " &
             mib(o.len) & " (" & $o.len & " bytes)\n- item templates: " &
             $gItemIds.len & "\n- quests: " & $gQuestIds.len &
             "\n- traders: " & $gTraderIds.len & "\n- locations: " &
             $gLocationIds.len & "\n"

  if doCheck:
    selfCheck(o, want, report)

  if reportFile.len > 0:
    discard writeTextFile(reportFile, report)
    ok "report -> " & reportFile

  note "This database is BSG's data by way of SPT's. It is not committed to " &
       "this repository and does not go in a release -- produce it locally, " &
       "from your own install, whenever you need it."

  if gFailures > 0:
    err $gFailures & " check(s) failed"
    return 1
  result = 0

quit(main())
