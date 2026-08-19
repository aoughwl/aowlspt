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

proc pathParts*(path: string): seq[string] =
  result = @[]
  for p in split(path, '.'):
    if p.len > 0:
      result.add p

proc dbPut*(path, patchJson: string): bool =
  ## `dbWrite`, which now also works the first time.
  ##
  ## This used to walk the path itself, finding the deepest prefix that existed
  ## and wrapping the rest into it. Three mods had written that same walk under
  ## three names, so it moved into `aowlspt/server`'s `dbWrite` and this is a
  ## forward. Kept as a name rather than deleted because it reads as what it
  ## means at twenty call sites, and because a `bool` is what those call sites
  ## want.
  result = dbWrite(path, patchJson) == Ok
