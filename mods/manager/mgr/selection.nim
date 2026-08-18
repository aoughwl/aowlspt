## What *this player* chose: which lists are active, and which individual mods
## they turned on or off on top of them.
##
## Kept in the mod's own store (`save`/`load`), never in the registry. The
## registry is a git repository somebody else may own; a manager that wrote your
## choices back into it would make every `git pull` a merge conflict, and would
## make "share my list" mean "share my machine's state".
##
## Two pieces, and the split is the whole design:
##
##  * `lists` — an ordered set of list ids. Shared documents. Changing one is
##    changing *which* curated set you are playing.
##  * `overrides` — your own per-mod enable/disable, applied after every list.
##    This is "pick certain mods out of a list" without editing the list.
##
## An override is remembered even when the mod it names is not in any active
## list: switching lists and switching back must not lose the fact that you
## turned one thing off.

import aowlspt
import aowlspt/server
import aowlspt/json

const StoreKey = "selection"

type
  Override* = object
    id*: string
    enabled*: bool

# Declared one `var` at a time and with literal initialisers: a global in an
# `--app:lib` build that needs a call to initialise is left zeroed, and a
# grouped `var` block hides declarations that follow a proc-typed entry.
var gLists: seq[string] = @[]
var gOverrides: seq[Override] = @[]
var gLoaded = false
var gStored = false

proc storeWorks*(): bool =
  ## Whether the last persist actually reached disk. Reported rather than
  ## assumed: a host older than ABI revision 2 has no store, and a selection
  ## that silently evaporates on restart is the worst way to find that out.
  result = gStored

proc persist*(): bool =
  var l = arr()
  for id in gLists:
    l.add id
  var o = arr()
  for ov in gOverrides:
    var e = obj()
    put(e, "id", ov.id)
    put(e, "enabled", ov.enabled)
    o.add e
  var doc = obj()
  put(doc, "lists", l)
  put(doc, "overrides", o)
  if save(StoreKey, doc) != Ok:
    gStored = false
    warn "manager: the selection could not be persisted (" & lastError() &
         "); it is in effect for this run only"
    return false
  gStored = true
  result = true

proc ensureLoaded*(defaults: seq[string]) =
  ## Reads the stored selection, or seeds it from `config.json` on first run.
  if gLoaded:
    return
  gLoaded = true
  let stored = load(StoreKey)
  if not stored.ok:
    gLists = defaults
    return
  gStored = true
  let doc = whole(stored.raw)
  let ids = each(doc.field("lists"))
  for id in ids:
    let s = id.asText("")
    if s.len > 0:
      gLists.add s
  let ovs = each(doc.field("overrides"))
  for ov in ovs:
    let id = ov.field("id").asText("")
    if id.len > 0:
      gOverrides.add Override(id: id, enabled: ov.field("enabled").asBool(true))
  # A stored selection with no lists is a real state (everything off) and is
  # left alone; only a *missing* document falls back to the config defaults.

proc activeLists*(): seq[string] = gLists
proc allOverrides*(): seq[Override] = gOverrides

proc setLists*(ids: seq[string]) =
  gLists = ids
  discard persist()

proc findOverride*(id: string; outEnabled: var bool): bool =
  outEnabled = false
  for ov in gOverrides:
    if ov.id == id:
      outEnabled = ov.enabled
      return true
  result = false

proc setOverride*(id: string; enabled: bool) =
  for i in 0 ..< gOverrides.len:
    if gOverrides[i].id == id:
      gOverrides[i].enabled = enabled
      discard persist()
      return
  gOverrides.add Override(id: id, enabled: enabled)
  discard persist()

proc clearOverride*(id: string): bool =
  ## Hands the mod back to whatever the lists say about it. Returns false when
  ## there was nothing to clear, so a route can say "no override on that mod"
  ## instead of reporting a change that did not happen.
  var keep: seq[Override] = @[]
  var removed = false
  for ov in gOverrides:
    if ov.id == id:
      removed = true
    else:
      keep.add ov
  if not removed:
    return false
  gOverrides = keep
  discard persist()
  result = true
