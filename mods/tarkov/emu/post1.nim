## Static post-1.0 tables that SPT's database does not contain.
##
## The emulator's database is imported from a pre-1.0 SPT install, and there
## are routes the post-1.0 client asks for that have no pre-1.0 equivalent at
## all -- the main-quest chapter list, the variable groups, the tape and
## subtitle tracks, the metrics configuration. There is nothing in `db.json`
## to build them from, so before this the routes were simply not served, and a
## 404 on any of them is a menu that retries and then sits there.
##
## These are BSG's own answers, taken verbatim from a capture of a real session
## (`data/capture/raid1`, seq numbers recorded in `data/post1/README.md`) and
## checked in as one file per table under `data/post1/`. That is the same
## bargain the rest of the database already makes -- `db.json` is BSG's data
## too, by way of SPT -- and the same one `data/metadata` makes for the
## `/client/metadata` blob.
##
## **What is deliberately not here.** `/client/dialogue` is the same kind of
## static table and is 13 MB decoded, which is not a file to check in beside
## these; and `/client/tutor-game/profile` looks static but carries a profile,
## so it is not a table at all. Both are named in the backlog rather than
## quietly omitted.
##
## Loaded once, on first use, and held. These are answered on every menu load,
## and re-reading 97 KB off disk each time to hand back a constant is the sort
## of cost that does not show up until three of them land in the same frame.

import std/syncio
import aowlspt

type
  Cached = object
    name: string
    text: string     ## "" once the file has been found missing

# A seq rather than a `Table`: nimony's `Table` subscript is `.raises`, and
# there are seven of these. A linear scan over seven strings is not the cost
# here -- reading 97 KB off disk again would be, which is what the cache is for.
var gTables: seq[Cached] = @[]

proc readWhole(path: string; into: var string): bool =
  ## The whole file as one string.
  ##
  ## Read line by line and rejoined rather than in one call, matching
  ## `emu/metadata`: nimony's `readAll` is not dependable across the file sizes
  ## here, and a JSON parser does not care where the newlines are.
  var f: File
  if not open(f, path, fmRead):
    return false
  into = ""
  var line = ""
  var first = true
  while readLine(f, line):
    if not first: into.add "\n"
    into.add line
    first = false
  close(f)
  result = true

proc tablePath*(name: string): string =
  result = modDir() & "/data/post1/" & name & ".json"

proc post1Table*(name: string): string =
  ## The raw JSON of one table, or `""` if its file is not installed.
  ##
  ## A missing file is reported once and then remembered, because the
  ## alternative is a log line per menu load per table for as long as the
  ## install stays broken -- which buries the first one, the only useful one.
  ## The caller decides what a missing table means; this does not invent an
  ## empty one, because an empty quest-chapter list and an absent one look the
  ## same to the client and only one of them is true.
  for c in gTables:
    if c.name == name:
      return c.text
  var text = ""
  if not readWhole(tablePath(name), text):
    gTables.add Cached(name: name, text: "")
    warn "post-1.0 table '" & name & "' is not installed at " &
         tablePath(name) & "; the route that needs it will refuse"
    return ""
  gTables.add Cached(name: name, text: text)
  result = text
