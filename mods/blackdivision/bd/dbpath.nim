## Writing to a database path that is not there yet.
##
## The same helper as `mods/morebots/bots/dbpath.nim`, and deliberately a copy:
## mods are separate binaries and cannot import one another, so a helper two of
## them need is either duplicated or promoted into `aowlspt/server`. It belongs
## in `aowlspt/server` — see the note at the end of this file — and until it is
## there, forty lines twice is better than one mod reaching into another.
##
## `dbWrite` merges a patch into the object at a path — and the two hosts
## disagree about what happens when the path does not exist. The simulator
## creates it; the backend refuses, because its `locate` walks the dotted path
## down from the root and returns "no such database path" the moment a segment
## is missing. The document root is not addressable either, so there is no
## "patch the whole thing" escape hatch.
##
## That matters here more than for most mods: a fresh server's database has no
## `bots.types` at all, and the entire job of this mod is to put things there.
## A mod that only works against a database which already contains what it is
## trying to add is a mod that cannot be installed.
##
## So: try the write, and if the host refuses, walk *up* the path to the
## deepest ancestor that does exist and re-wrap the patch in the segments that
## were missing. `{"a":{"b":{"c":X}}}` merged into `a` creates `b` and `c`,
## because a merge adds members the target does not have — which is the same
## rule, applied one level higher.
##
## The one case this cannot rescue is a database with no top-level object of
## that name at all, since the root cannot be patched. That is reported rather
## than silently skipped.

import std/strutils
import aowlspt
import aowlspt/server

proc quoteKey(s: string): string =
  result = "\""
  for ch in s:
    if ch == '"' or ch == '\\':
      result.add '\\'
    result.add ch
  result.add "\""

proc pathParts*(path: string): seq[string] =
  result = @[]
  for p in split(path, '.'):
    if p.len > 0:
      result.add p

proc joinParts(parts: seq[string]; upto: int): string =
  result = ""
  for i in 0 ..< upto:
    if i > 0:
      result.add "."
    result.add parts[i]

proc wrapFrom(parts: seq[string]; fromIndex: int; inner: string): string =
  ## `inner`, nested inside the path segments from `fromIndex` onwards.
  result = inner
  var i = parts.len - 1
  while i >= fromIndex:
    result = "{" & quoteKey(parts[i]) & ":" & result & "}"
    dec i

proc dbPut*(path, patchJson: string): bool =
  ## `dbWrite`, but it also works the first time.
  if dbWrite(path, patchJson) == Ok:
    return true
  let parts = pathParts(path)
  if parts.len <= 1:
    # Nothing above it to attach to: the root is not writable.
    return false
  var depth = parts.len - 1
  while depth >= 1:
    let prefix = joinParts(parts, depth)
    let existing = dbRead(prefix)
    if existing.ok:
      return dbWrite(prefix, wrapFrom(parts, depth, patchJson)) == Ok
    dec depth
  result = false

# Worth promoting: `dbWrite` that creates is what every mod adding content to
# the database needs, and every one of them will otherwise write this file.
