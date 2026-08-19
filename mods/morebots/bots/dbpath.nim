## Writing to a database path that is not there yet — and not writing it yet.
##
## `dbWrite` merges a patch into the object at a path, and it creates the path
## when the database has never held it. That last part used to be this file's
## whole job: a fresh server's database has no `bots.types` at all, and the
## entire job of this mod is to put things there. It has since moved into
## `aowlspt/server`, where three mods had hand-rolled the same walk.
##
## What this file is for now is **when** the write happens.
##
## `dbWrite` costs the size of the database, not the size of the patch — the
## backend splices into one 41 MB text document and throws its member index
## away — so this mod's four hundred small writes cost fifty seconds of copying
## the same forty-one megabytes. `bots/pending.nim` has the measurement and the
## fold. Here, `dbPut` buffers and `dbView` reads the buffer first, so every call
## site keeps reading as what it means and none of them has to know.

import aowlspt
import aowlspt/server
import std/strutils
import pending

export pending

proc pathParts*(path: string): seq[string] =
  result = @[]
  for p in split(path, '.'):
    if p.len > 0:
      result.add p

proc dbPut*(path, patchJson: string): bool =
  ## Buffer a merge into `path`. It reaches the database at the next `flush()`
  ## — the `morebots.flush` event, any route this mod serves, or the first
  ## server tick, whichever comes first.
  ##
  ## Returning `true` without having written is not a lie about the write, and
  ## the alternative is worse: a `bool` that meant "the bytes are on disk" would
  ## have every call site either ignoring it (as they did) or forcing a flush to
  ## find out (which is the cost this exists to remove). What it means is "this
  ## is now part of what the mod will write", and `dbView` below answers
  ## accordingly from that moment.
  if patchJson.len == 0:
    return false
  pendPut(path, patchJson)
  result = true

proc dbView*(path: string): DbValue =
  ## `dbRead` with this mod's buffered work in front of it.
  result = pendRead(path)

proc dbPutNow*(path, patchJson: string): bool =
  ## An unbuffered write, for the one case that wants it: a caller that has
  ## nothing else to add and no tick to wait for.
  result = dbWrite(path, patchJson) == Ok
