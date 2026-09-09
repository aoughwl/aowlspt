## What *this player* chose: which lists are active, and which individual mods
## they turned on or off on top of them.
##
## Kept in the mod's own store (`save`/`load`), never in the registry. The
## registry is a git repository somebody else may own; a manager that wrote your
## choices back into it would make every `git pull` a merge conflict, and would
## make "share my list" mean "share my machine's state".
##
## Three pieces, and the split is the whole design:
##
##  * `lists` — an ordered set of list ids. Shared documents. Changing one is
##    changing *which* curated set you are playing.
##  * `overrides` — your own per-mod enable/disable, applied after every list.
##    This is "pick certain mods out of a list" without editing the list.
##  * `local` — **lists you wrote**, stored here in full rather than by id.
##
## An override is remembered even when the mod it names is not in any active
## list: switching lists and switching back must not lose the fact that you
## turned one thing off.
##
## ## Why your own lists live here and not in the registry
##
## The registry can be *replaced*. `mgr/refresh.nim` can fetch a newer
## `mods.json` and adopt it, and `aowlspt-install` overwrites the installed copy
## every time it runs. A list that lived in that file would be a list either of
## those could silently delete — and "my raid night setup vanished after an
## update" is the one failure this whole feature exists to prevent.
##
## So a local list is stored beside the selection, in the mod's own store, and
## `withLocalLists` in `mgr/registry.nim` merges it into the registry *after*
## the registry is read. A refresh replaces the mods and the published lists and
## cannot touch yours. The cost is that a local list can go stale — it can name
## a mod the new registry does not have — and that is reported (`refresh.nim`
## computes it and the refresh answer names them) rather than repaired, because
## deleting an entry out of somebody's list to make it resolve is exactly the
## silent edit this is arranged against.
##
## A local list may `inherits` a registry list. That is the intended shape: you
## keep pointing at somebody else's curated set, their updates keep reaching
## you, and your own document is three lines of difference on top.

import aowlspt
import aowlspt/server
import aowlspt/json
import registry

const StoreKey = "selection"

const StoreSchema* = "aowlspt.selection.store/1"
  ## What `persist` stamps on the document it writes, and the only value
  ## `selectionFaultIn` will act on.
  ##
  ## Absence is accepted: every selection written before this field existed has
  ## no `schema` in it, and refusing those would throw away the setups this
  ## module exists to protect. What is refused is a schema that is *there* and
  ## is something else -- a store written by a newer manager, or by a build that
  ## changed what `overrides` means. `aowlspt/json` scans, so such a document
  ## does not fail to read: it reads as whatever fields happen to still be
  ## spelled the same, and the manager then saves that reading back over the
  ## original. The half it could not understand is gone, and there is no copy.
  ## `mgr/registry.nim` refuses an unknown registry schema for the identical
  ## reason and in the identical words.

type
  SelectionState* = enum
    ssFresh       ## nothing was stored yet; the config defaults seeded it
    ssLoaded      ## a stored selection was read and is in effect
    ssUnreadable  ## there *is* one and the store would not hand it over
    ssCorrupt     ## it was handed over and is not a selection document

  Override* = object
    id*: string
    enabled*: bool

  LocalList* = object
    ## The same shape as a registry `ModList`, because it *is* one once
    ## `withLocalLists` has merged it: resolution must not be able to tell the
    ## difference, or a local list would be a second-class list with its own
    ## rules to get wrong.
    id*: string
    name*: string
    description*: string
    inherits*: seq[string]
    entries*: seq[ListEntry]

## ## Threading
##
## **Everything in this module assumes the mod's lock is already held**
## (`aowlspt/sync`; the discipline is in the header of `manager.nim`). Nothing
## here takes it, and nothing here may: the lock is documented non-reentrant,
## and the callers are routes that have to hold it across more than one call
## anyway -- "is the store usable" followed by "write this" is one decision, and
## a lock taken twice in the middle of it would let another thread land between
## the question and the answer.

# Declared one `var` at a time and with literal initialisers: a global in an
# `--app:lib` build that needs a call to initialise is left zeroed, and a
# grouped `var` block hides declarations that follow a proc-typed entry.
var gLists: seq[string] = @[]
var gOverrides: seq[Override] = @[]
var gLocal: seq[LocalList] = @[]
var gLoaded = false
var gStored = false
var gState = ssFresh
var gFault = ""
# True when `gLists` came out of `config.json` rather than off the disk. It is
# the difference between "the player has never chosen anything and these are the
# defaults" and "the player chose this", and `manager.nim` needs it to decide
# whether an empty resolution is a choice or an accident: a *fresh* store whose
# seeded lists are empty means the config had nothing to say, and a config with
# nothing to say is far more often a config that did not parse than a player who
# wanted no mods.
var gSeeded = false

# ---------------------------------------------------------------------------
# Is this a selection document?
# ---------------------------------------------------------------------------
#
# The reader below is a scanner: `field` walks the text and hands back whatever
# it finds, so a *truncated* document does not fail to parse -- it parses as
# whatever survived the truncation. `{"lists":["raidnight` reads as a document
# with no lists in it, which is a real state ("everything off") and is exactly
# how a person's setup gets silently forgotten.
#
# So the raw text is checked for structural wholeness before a single field is
# read out of it, and anything that fails is refused *loudly* and left on disk
# untouched. Refusing is the whole point: the manager can be restarted, and a
# store the manager overwrote with an empty document cannot be un-overwritten.

# The scanner that answers "did all of the bytes arrive" lives in
# `mgr/registry.nim` (`wholeJsonObject`), because a `mods.json` cut short is the
# same failure with worse consequences and one balance-counter is easier to
# trust than two. This module asked the question first; it now asks that one.

proc selectionFaultIn*(raw: string): string =
  ## "" when `raw` is a selection document this reader will act on, and a
  ## sentence naming the fault when it is not. Exported and pure so that
  ## `tools/modresolve.nim` can drive every shape of damage through it without
  ## a host, a store or a running server.
  if raw.len == 0:
    return "it is empty"
  if not wholeJsonObject(raw):
    return "it is not one complete JSON object -- truncated, or not a " &
           "selection document at all"
  let doc = whole(raw)
  if not doc.exists or not doc.isObject:
    return "it is not a JSON object"
  let sch = doc.field("schema")
  if sch.exists and not sch.isNull:
    let schema = sch.asText("")
    if schema != StoreSchema:
      return "it declares schema \"" & schema & "\"; this manager writes \"" &
             StoreSchema & "\" and will not guess at the difference"
  var any = false
  let l = doc.field("lists")
  if l.exists and not l.isNull:
    if not l.isArray:
      return "its \"lists\" is not an array"
    any = true
  let o = doc.field("overrides")
  if o.exists and not o.isNull:
    if not o.isArray:
      return "its \"overrides\" is not an array"
    any = true
  let c = doc.field("local")
  if c.exists and not c.isNull:
    if not c.isArray:
      return "its \"local\" is not an array"
    any = true
  if not any:
    return "it has none of \"lists\", \"overrides\" or \"local\" in it, so " &
           "it is not a selection this manager wrote"
  result = ""

proc selectionState*(): SelectionState = gState

proc selectionUsable*(): bool =
  ## False when there is a stored selection that could not be read or made
  ## sense of. Everything that *writes* has to ask first: a manager that
  ## persists on top of a selection it could not read has destroyed the copy
  ## that a person could otherwise have opened in an editor and fixed.
  result = gState == ssFresh or gState == ssLoaded

proc selectionFault*(): string = gFault

proc storeWorks*(): bool =
  ## Whether the last persist actually reached disk. Reported rather than
  ## assumed: a host older than ABI revision 2 has no store, and a selection
  ## that silently evaporates on restart is the worst way to find that out.
  result = gStored

proc persist*(): bool =
  ## Writes the whole document, every time, through the store's own durable
  ## commit -- so a kill in the middle leaves the previous selection, never
  ## half of this one.
  ##
  ## And it refuses outright when the selection on disk is one this manager
  ## could not read. That is the rule the whole module is arranged around: a
  ## partial write must not lose your lists, and the way that happens is not a
  ## torn file, it is the manager reading a damaged one as "nothing selected"
  ## and then helpfully saving that.
  if not selectionUsable():
    warn "manager: refusing to write the selection: " & gFault &
         ". Your stored selection is left exactly as it is; fix or delete it " &
         "and restart."
    gStored = false
    return false
  var l = arr()
  for id in gLists:
    l.add id
  var o = arr()
  for ov in gOverrides:
    var e = obj()
    put(e, "id", ov.id)
    put(e, "enabled", ov.enabled)
    o.add e
  var locals = arr()
  for li in 0 ..< gLocal.len:
    # Bound to a local and the nested seqs copied out one field at a time:
    # `for e in ll.entries` where `ll` is itself a loop variable over a seq of
    # objects miscompiles in nimony, and it fails at the C compiler rather than
    # at the point of the mistake.
    let ll = gLocal[li]
    let inherits = ll.inherits
    let entries = ll.entries
    var inh = arr()
    for p in inherits:
      inh.add p
    var ents = arr()
    for e in entries:
      var eo = obj()
      put(eo, "id", e.id)
      put(eo, "enabled", e.enabled)
      if e.note.len > 0:
        put(eo, "note", e.note)
      ents.add eo
    var lo = obj()
    put(lo, "id", ll.id)
    put(lo, "name", ll.name)
    put(lo, "description", ll.description)
    put(lo, "inherits", inh)
    put(lo, "entries", ents)
    locals.add lo
  var doc = obj()
  put(doc, "schema", StoreSchema)
  put(doc, "lists", l)
  put(doc, "overrides", o)
  put(doc, "local", locals)
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
    if stored.missing:
      gSeeded = true
      # Nothing has ever been written. The one case where starting from the
      # config's defaults is right, and it is right *because* the store said
      # "no such key" rather than "I could not read it".
      gState = ssFresh
      gLists = defaults
      return
    # There is a selection and the store would not hand it over. Seeding the
    # defaults here is what "the manager silently forgot my setup" looks like
    # from the inside: the next change would persist those defaults over the
    # file that could not be read.
    gState = ssUnreadable
    gFault = "the stored selection could not be read (" & stored.error & ")"
    error "manager: " & gFault & ". No selection is in effect and nothing " &
          "will be written until it can be read; the file itself is untouched."
    return
  let fault = selectionFaultIn(stored.raw)
  if fault.len > 0:
    gState = ssCorrupt
    gFault = "the stored selection is not usable: " & fault
    error "manager: " & gFault & ". It is left on disk as it is -- no mods " &
          "are selected this run and no change will be saved over it. Fix it " &
          "or delete it and restart."
    return
  gState = ssLoaded
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
  let locals = each(doc.field("local"))
  for ll in locals:
    let id = ll.field("id").asText("")
    if id.len == 0:
      continue
    var entries: seq[ListEntry] = @[]
    let ents = each(ll.field("entries"))
    for e in ents:
      let eid = e.field("id").asText("")
      if eid.len == 0:
        continue
      entries.add ListEntry(id: eid, enabled: e.field("enabled").asBool(true),
                            note: e.field("note").asText(""))
    var inherits: seq[string] = @[]
    let inh = each(ll.field("inherits"))
    for p in inh:
      let s = p.asText("")
      if s.len > 0: inherits.add s
    gLocal.add LocalList(id: id, name: ll.field("name").asText(id),
                         description: ll.field("description").asText(""),
                         inherits: inherits, entries: entries)
  # A stored selection with no lists is a real state (everything off) and is
  # left alone; only a *missing* document falls back to the config defaults.

proc selectionSeeded*(): bool = gSeeded
  ## Whether the active lists are the config's defaults rather than a stored
  ## choice. See `gSeeded`.

proc activeLists*(): seq[string] = gLists
proc allOverrides*(): seq[Override] = gOverrides
proc localLists*(): seq[LocalList] = gLocal

proc findLocalList*(id: string; outIndex: var int): bool =
  outIndex = -1
  for i in 0 ..< gLocal.len:
    if gLocal[i].id == id:
      outIndex = i
      return true
  result = false

proc putLocalList*(l: LocalList): bool =
  ## Create or replace one of your own lists. Replacing is by id and in place,
  ## so editing a list you are currently playing does not reorder the selection.
  ##
  ## False when it could not be stored, *including* when the stored selection
  ## is one this manager refused to read -- in which case nothing is changed in
  ## memory either. Half-applying a change whose other half cannot be saved is
  ## how a session and a disk come to disagree about what you chose.
  if not selectionUsable():
    return false
  var idx = -1
  if findLocalList(l.id, idx):
    gLocal[idx] = l
  else:
    gLocal.add l
  result = persist()

proc deleteLocalList*(id: string): bool =
  ## Returns false when there was no such list, so a route can say "you have no
  ## list by that name" rather than reporting a deletion that did not happen.
  ##
  ## The list is *not* removed from `gLists`. An active selection naming a list
  ## that no longer exists is a state the resolver already reports honestly, and
  ## quietly editing the selection here would mean a mistyped delete silently
  ## changed which mods load.
  if not selectionUsable():
    return false
  var keep: seq[LocalList] = @[]
  var removed = false
  for i in 0 ..< gLocal.len:
    if gLocal[i].id == id:
      removed = true
    else:
      keep.add gLocal[i]
  if not removed:
    return false
  gLocal = keep
  discard persist()
  result = true

proc toModList*(l: LocalList): ModList =
  ## A local list as the resolver sees it. `author` and `version` are empty on
  ## purpose: they are the fields a *published* list carries so somebody else
  ## can tell two copies of it apart, and inventing values for a document that
  ## has never left this machine would put two lies on the panel.
  result = ModList(id: l.id, name: l.name, author: "", version: "",
                   description: l.description, inherits: l.inherits,
                   entries: l.entries, local: true)

proc withLocalLists*(reg: Registry): Registry =
  ## The registry, plus your own lists.
  ##
  ## Applied once, right after the registry is read, so that everything
  ## downstream -- resolution, `/aowlspt/mods/lists`, `findList`, the panel --
  ## sees one set of lists and cannot treat yours differently by accident.
  ##
  ## A local list whose id collides with a published one **wins, and is said
  ## out loud**. The other way round, a registry refresh could silently take
  ## over the meaning of a list you wrote by publishing its id; this way the
  ## worst case is a warning and a list that still does what you wrote down.
  result = reg
  let locals = gLocal
  for i in 0 ..< locals.len:
    let ll = locals[i]
    var idx = -1
    var hit = false
    for k in 0 ..< result.lists.len:
      if result.lists[k].id == ll.id:
        idx = k
        hit = true
    if hit:
      result.warnings.add ll.id & " is both one of your own lists and a list " &
                          "in " & reg.path & "; yours is the one in effect"
      result.lists[idx] = toModList(ll)
    else:
      result.lists.add toModList(ll)

proc setLists*(ids: seq[string]): bool =
  ## False when the change could not be saved. The caller says so in its
  ## answer: "it is on for this run only" and "it is on" are different
  ## sentences and only one of them survives a restart.
  if not selectionUsable():
    return false
  gLists = ids
  result = persist()

proc findOverride*(id: string; outEnabled: var bool): bool =
  outEnabled = false
  for ov in gOverrides:
    if ov.id == id:
      outEnabled = ov.enabled
      return true
  result = false

proc setOverride*(id: string; enabled: bool): bool =
  if not selectionUsable():
    return false
  for i in 0 ..< gOverrides.len:
    if gOverrides[i].id == id:
      gOverrides[i].enabled = enabled
      return persist()
  gOverrides.add Override(id: id, enabled: enabled)
  result = persist()

proc clearOverride*(id: string): bool =
  ## Hands the mod back to whatever the lists say about it. Returns false when
  ## there was nothing to clear, so a route can say "no override on that mod"
  ## instead of reporting a change that did not happen.
  if not selectionUsable():
    return false
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
