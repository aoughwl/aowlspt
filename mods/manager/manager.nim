## The mod manager — the registry, your lists, and what is actually running.
##
##     aowl build-mod mods/manager
##     aowl run mods/manager
##
## A backend mod on the same public API as any other: `aowlspt`,
## `aowlspt/server`, `aowlspt/json` and nothing else. It has no private door
## into the host, which is the same constraint the emulator is written under and
## for the same reason — a manager that needed privileged access would prove the
## plugin API is not enough to manage plugins with.
##
## What it does:
##
##  * reads `registry/mods.json` (one git repository, every mod, and the named
##    lists that select them),
##  * resolves it against your own selection — active lists plus your per-mod
##    overrides — and can say, for every mod in the registry, whether it is
##    loading and *why*,
##  * serves that under `/aowlspt/mods/...` so it can be driven from a second
##    window while the game is up,
##  * persists your selection with `save`/`load`, so it survives a restart,
##  * `broadcast`s when the selection changes, so anything else in the system
##    can react without polling.
##
## ## The honest part
##
## Enabling and disabling a mod *while the game runs* needs the host to be able
## to tear one down, and that facility is being built. Everything the manager
## needs from it goes through `mgr/control.nim`, which today probes for it,
## finds nothing, and says so:
##
##     manager: no host answered the control probe, so this host has no live
##     enable/disable. Selection changes are saved and take effect when the
##     host restarts.
##
## Routes report the same thing, per change, in `outcome`. Nothing here claims
## to have enabled a mod that is not running.
##
## ## Layout
##
##     mgr/semver.nim     versions and ranges
##     mgr/registry.nim   reading mods.json
##     mgr/selection.nim  the user's lists and overrides, persisted
##     mgr/resolve.nim    the resolution rules, as written in registry/README.md
##     mgr/control.nim    the host-side load/unload facade
##
## ## The routes
##
##     GET  /aowlspt/mods                what this is, and a one-line summary
##     GET  /aowlspt/mods/list           every mod, its verdict and the reason
##     GET  /aowlspt/mods/lists          the lists in the registry
##     GET  /aowlspt/mods/conflicts      only the problems
##     GET  /aowlspt/mods/describe/<id>  one mod, in full
##     GET  /aowlspt/mods/enable/<id>    override it on
##     GET  /aowlspt/mods/disable/<id>   override it off
##     GET  /aowlspt/mods/clear/<id>     drop the override; the lists decide
##     GET  /aowlspt/mods/select/<id>    make one list the active list
##     POST /aowlspt/mods/select         {"lists":["a","b"]}
##     GET  /aowlspt/mods/reload         re-read the registry from disk
##     GET  /aowlspt/mods/apply          push the current selection at the host
##
## Every route also accepts `{"id":"..."}` in the body, because a browser can
## reach a path and a script would rather send a document.

import std/syncio
import aowlspt
import aowlspt/server
import aowlspt/json
import mgr/registry
import mgr/resolve
import mgr/selection
import mgr/control

const
  ModGuid = "aowl.manager"
  ModName = "Mod Manager"
  ModVersion = "1.0.0"
  SelectionFile = "aowlspt-selection.json"

# Globals with literal initialisers only: in an `--app:lib` build a global that
# needs a *call* to initialise is silently left zeroed, so `emptyRegistry()`
# here would produce a registry that looks loaded and is not.
var gRegistry: Registry = Registry(ok: false, path: "", error: "not loaded",
                                   name: "", warnings: @[], mods: @[],
                                   lists: @[])
var gRes: Resolution = Resolution(order: @[], decisions: @[], problems: @[],
                                  pipelineChecked: false, hostVersion: "",
                                  side: "")
var gDefaultLists: seq[string] = @[]
var gProbeMs = 750
var gWriteSelectionFile = true
var gRegistryPath = ""
var gPending = false

# ---------------------------------------------------------------------------
# Finding the registry
# ---------------------------------------------------------------------------

proc parentOf(path: string): string =
  ## The same rule as `mgr/control.nim`: a name with no separator lives in the
  ## current directory, so its parent is ".". `aowl run` hands the simulator a
  ## relative mod path and the registry sits two levels above it.
  var cut = -1
  for i in 0 ..< path.len:
    if path[i] == '/' or path[i] == '\\':
      cut = i
  if path.len == 0: return ""
  if cut < 0: return "."
  if cut == 0: return path.substr(0, 0)
  result = path.substr(0, cut - 1)

proc registryCandidates(): seq[string] =
  ## Where a checkout of the registry repository plausibly is, most specific
  ## first. Searched rather than hard-coded because the same binary runs from a
  ## source tree (`aowl run`) and from an install, and those are different
  ## trees — and because the registry is a *separate* repository that a player
  ## may have cloned anywhere, which is what `registryPath` in config is for.
  result = @[]
  let cfg = setting("registryPath").asText("")
  if cfg.len > 0:
    result.add cfg
    return                       # an explicit path is not a hint to search past
  let data = dataDir()
  if data.len > 0:
    result.add data & "/mods.json"
    result.add data & "/registry/mods.json"
  let mods = modsRoot()
  if mods.len > 0:
    result.add mods & "/registry/mods.json"
    let root = parentOf(mods)
    if root.len > 0:
      result.add root & "/registry/mods.json"
      let up = parentOf(root)
      if up.len > 0:
        result.add up & "/registry/mods.json"

proc discoverRegistry() =
  let candidates = registryCandidates()
  for path in candidates:
    let text = readTextFile(path)
    if text.len == 0:
      continue
    # The first file that *exists* wins, even if it fails to parse. Falling
    # through to the next candidate on a parse error would silently resolve
    # against a stale copy while the one you are editing is broken.
    gRegistryPath = path
    gRegistry = parseRegistry(text, path)
    return
  gRegistryPath = ""
  gRegistry = Registry(ok: false, path: "",
                       error: "no registry found. Looked for mods.json in " &
                              "this mod's data/ directory and in registry/ " &
                              "beside the mods folder; set \"registryPath\" " &
                              "in config.json to point at a checkout.",
                       name: "", warnings: @[], mods: @[], lists: @[])

# ---------------------------------------------------------------------------
# Resolving
# ---------------------------------------------------------------------------

proc recompute() =
  var ids: seq[string] = @[]
  var flags: seq[bool] = @[]
  let overrides = allOverrides()
  for ov in overrides:
    ids.add ov.id
    flags.add ov.enabled
  gRes = resolve(gRegistry, activeLists(), ids, flags, sideName(), hostVersion())

proc selectionDocument(): string =
  ## The resolved order, as the host would need it at startup.
  ##
  ## Written beside the mods so a host *can* read it, and documented as inert
  ## until one does. It is not a claim that anything reads it — `startupHonoured`
  ## in `/aowlspt/mods` says whether a host has ever said it does.
  var a = arr()
  for id in gRes.order:
    a.add id
  var o = obj()
  put(o, "schema", "aowlspt.selection/1")
  put(o, "writtenBy", ModGuid)
  put(o, "side", gRes.side)
  put(o, "registry", gRegistryPath)
  put(o, "load", a)
  result = done(o).text

proc writeSelectionFile() =
  if not gWriteSelectionFile:
    return
  let root = modsRoot()
  if root.len == 0:
    return
  let path = root & "/" & SelectionFile
  try:
    writeFile(path, selectionDocument())
  except:
    warn "manager: could not write " & path

proc summaryLine(): string =
  result = $gRes.order.len & " of " & $gRegistry.mods.len &
           " registry mods resolve on the " & gRes.side & " side"

proc announce() =
  var o = obj()
  put(o, "side", gRes.side)
  put(o, "loaded", gRes.order.len)
  var a = arr()
  for id in gRes.order:
    a.add id
  put(o, "order", a)
  put(o, "control", stateName(controlState()))
  put(o, "pending", gPending)
  discard broadcast("aowlspt.mods.selection", o)

proc afterChange() =
  recompute()
  writeSelectionFile()
  announce()

# ---------------------------------------------------------------------------
# JSON views
# ---------------------------------------------------------------------------

proc decisionJson(d: Decision): JsonObject =
  var o = obj()
  put(o, "id", d.id)
  put(o, "name", d.name)
  put(o, "verdict", verdictName(d.verdict))
  put(o, "reason", d.reason)
  put(o, "from", d.fromList)
  put(o, "explicit", d.explicit)
  put(o, "order", d.order)
  result = o

proc problemsJson(): JsonArray =
  var a = arr()
  for p in gRes.problems:
    a.add p
  for w in gRegistry.warnings:
    a.add w
  if not gRegistry.ok and gRegistry.error.len > 0:
    a.add gRegistry.error
  result = a

proc statusJson(): JsonObject =
  var lists = arr()
  let act = activeLists()
  for l in act:
    lists.add l
  var o = obj()
  put(o, "ok", gRegistry.ok)
  put(o, "mod", ModName)
  put(o, "version", ModVersion)
  put(o, "registry", gRegistryPath)
  put(o, "registryName", gRegistry.name)
  put(o, "mods", gRegistry.mods.len)
  put(o, "lists", gRegistry.lists.len)
  put(o, "side", gRes.side)
  put(o, "host", hostName() & " " & hostVersion())
  put(o, "pipelineChecked", gRes.pipelineChecked)
  put(o, "activeLists", lists)
  put(o, "loaded", gRes.order.len)
  put(o, "control", stateName(controlState()))
  put(o, "controlHost", controlHost())
  put(o, "liveChanges", controlState() == csPresent)
  put(o, "selectionPersisted", storeWorks())
  put(o, "selectionFile", (if gWriteSelectionFile: modsRoot() & "/" & SelectionFile else: ""))
  put(o, "pendingRestart", gPending)
  put(o, "problems", problemsJson())
  result = o

# ---------------------------------------------------------------------------
# Reading a request
# ---------------------------------------------------------------------------

proc idFrom(url, prefix, body: string): string =
  ## The path tail, or `{"id":"..."}` from the body. Both, because a browser can
  ## only reach a path and a script would rather send a document.
  result = pathAfter(url, prefix)
  if result.len == 0:
    result = field(body, "id").asText("")

proc errorBody(message: string): string =
  var o = obj()
  put(o, "ok", false)
  put(o, "error", message)
  result = done(o).text

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

proc applySelection(): JsonObject =
  ## Ask the host to make the resolved selection true. Every mod gets an
  ## outcome, and `aoDeferred` is a perfectly ordinary one today.
  var results = arr()
  var deferredCount = 0
  var requested = 0
  for id in gRes.order:
    var idx = -1
    if not findMod(gRegistry, id, idx):
      continue
    let m = gRegistry.mods[idx]
    let r = requestLoad(m.id, m.artifactDir, m.artifactLib)
    if r.outcome == aoDeferred: inc deferredCount
    if r.outcome == aoRequested: inc requested
    var e = obj()
    put(e, "id", id)
    put(e, "action", "load")
    put(e, "outcome", outcomeName(r.outcome))
    put(e, "message", r.message)
    results.add e

  # Anything the registry knows, that a list had switched on at some point, and
  # that is not in the resolved order, is asked to go away. Mods the registry
  # never mentions are left alone: they are somebody else's, and unloading a mod
  # this manager does not manage would be overreach.
  for d in gRes.decisions:
    if d.verdict == vLoaded or d.verdict == vNotSelected or d.verdict == vUnknown:
      continue
    let r = requestUnload(d.id)
    if r.outcome == aoDeferred: inc deferredCount
    if r.outcome == aoRequested: inc requested
    var e = obj()
    put(e, "id", d.id)
    put(e, "action", "unload")
    put(e, "outcome", outcomeName(r.outcome))
    put(e, "message", r.message)
    results.add e

  gPending = deferredCount > 0
  var o = obj()
  put(o, "ok", true)
  put(o, "requested", requested)
  put(o, "deferred", deferredCount)
  put(o, "restartRequired", gPending)
  put(o, "control", stateName(controlState()))
  put(o, "results", results)
  if deferredCount > 0:
    put(o, "note", "the selection is saved; " & $deferredCount & " change(s) " &
                   "cannot take effect until the host restarts")
  result = o

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc routeStatus(url, body, session: string): string =
  var o = statusJson()
  put(o, "summary", summaryLine())
  result = done(o).text

proc routeList(url, body, session: string): string =
  var a = arr()
  for d in gRes.decisions:
    a.add decisionJson(d)
  var order = arr()
  for id in gRes.order:
    order.add id
  var o = obj()
  put(o, "ok", true)
  put(o, "side", gRes.side)
  put(o, "order", order)
  put(o, "mods", a)
  put(o, "problems", problemsJson())
  result = done(o).text

proc routeLists(url, body, session: string): string =
  var active = arr()
  let act = activeLists()
  for l in act:
    active.add l
  var a = arr()
  for li in 0 ..< gRegistry.lists.len:
    # Bound to locals, and the nested seqs copied out, one field at a time.
    # `for p in l.inherits` where `l` is itself a loop variable over a seq of
    # objects miscompiles in nimony -- the generated C names a field the struct
    # does not have. It fails at the C compiler rather than silently, but it
    # costs an hour if you do not know to look for it.
    let l = gRegistry.lists[li]
    let inherits = l.inherits
    let listEntries = l.entries
    var inh = arr()
    for p in inherits:
      inh.add p
    var entries = arr()
    for e in listEntries:
      var eo = obj()
      put(eo, "id", e.id)
      put(eo, "enabled", e.enabled)
      if e.note.len > 0:
        put(eo, "note", e.note)
      entries.add eo
    var o = obj()
    put(o, "id", l.id)
    put(o, "name", l.name)
    put(o, "author", l.author)
    put(o, "version", l.version)
    put(o, "description", l.description)
    put(o, "inherits", inh)
    put(o, "entries", entries)
    a.add o
  var out1 = obj()
  put(out1, "ok", true)
  put(out1, "active", active)
  put(out1, "lists", a)
  result = done(out1).text

proc routeConflicts(url, body, session: string): string =
  ## Only what is wrong. The list route answers "what is loading"; this one
  ## answers "what did I do that did not work", which is a different question
  ## and the one asked at two in the morning.
  var a = arr()
  for d in gRes.decisions:
    if d.verdict == vLoaded or d.verdict == vNotSelected or
       d.verdict == vDisabled or d.verdict == vWrongSide:
      continue
    a.add decisionJson(d)
  var o = obj()
  put(o, "ok", a.len == 0 and gRes.problems.len == 0)
  put(o, "excluded", a)
  put(o, "problems", problemsJson())
  result = done(o).text

proc routeDescribe(url, body, session: string): string =
  let id = idFrom(url, "/aowlspt/mods/describe/", body)
  if id.len == 0:
    return errorBody("name a mod: /aowlspt/mods/describe/<id>")
  var idx = -1
  if not findMod(gRegistry, id, idx):
    return errorBody("no mod called " & id & " in " & gRegistryPath)
  let m = gRegistry.mods[idx]
  var sides = arr()
  for s in m.sides:
    sides.add s
  var reqs = arr()
  for r in m.requires:
    var ro = obj()
    put(ro, "id", r.id)
    put(ro, "version", r.versionRange)
    reqs.add ro
  var cons = arr()
  for c in m.conflicts:
    var co = obj()
    put(co, "id", c.id)
    put(co, "reason", c.reason)
    cons.add co
  var provides = arr()
  for p in m.provides:
    provides.add p
  var after = arr()
  for a in m.loadAfter:
    after.add a
  var o = obj()
  put(o, "ok", true)
  put(o, "id", m.id)
  put(o, "name", m.name)
  put(o, "author", m.author)
  put(o, "version", m.version)
  put(o, "description", m.description)
  put(o, "pipeline", m.pipeline)
  put(o, "sides", sides)
  put(o, "license", m.license)
  put(o, "sourceKind", m.sourceKind)
  put(o, "sourcePath", m.sourcePath)
  put(o, "sourceUrl", m.sourceUrl)
  put(o, "downloadUrl", m.downloadUrl)
  put(o, "downloadHash", m.downloadHash)
  put(o, "library", libraryPath(m.artifactDir, m.artifactLib))
  put(o, "requires", reqs)
  put(o, "conflicts", cons)
  put(o, "provides", provides)
  put(o, "loadAfter", after)
  var di = -1
  if decisionFor(gRes, m.id, di):
    put(o, "decision", decisionJson(gRes.decisions[di]))
  result = done(o).text

proc changeReply(id: string; what: string): string =
  ## The answer to enable/disable/clear: what changed, what it resolves to now,
  ## and — the part that has to be honest — whether that is in effect.
  var o = obj()
  put(o, "ok", true)
  put(o, "id", id)
  put(o, "action", what)
  var di = -1
  if decisionFor(gRes, id, di):
    put(o, "decision", decisionJson(gRes.decisions[di]))
  put(o, "loaded", gRes.order.len)
  put(o, "control", stateName(controlState()))
  if controlState() == csPresent:
    put(o, "inEffect", "apply it with /aowlspt/mods/apply")
  else:
    put(o, "inEffect", "saved, but this host cannot load or unload a mod " &
                       "while it runs; it takes effect on the next start")
  put(o, "problems", problemsJson())
  result = done(o).text

proc routeEnable(url, body, session: string): string =
  let id = idFrom(url, "/aowlspt/mods/enable/", body)
  if id.len == 0:
    return errorBody("name a mod: /aowlspt/mods/enable/<id>")
  var idx = -1
  if not findMod(gRegistry, id, idx):
    return errorBody("no mod called " & id & " in " & gRegistryPath)
  setOverride(id, true)
  afterChange()
  result = changeReply(id, "enable")

proc routeDisable(url, body, session: string): string =
  let id = idFrom(url, "/aowlspt/mods/disable/", body)
  if id.len == 0:
    return errorBody("name a mod: /aowlspt/mods/disable/<id>")
  setOverride(id, false)
  afterChange()
  result = changeReply(id, "disable")

proc routeClear(url, body, session: string): string =
  let id = idFrom(url, "/aowlspt/mods/clear/", body)
  if id.len == 0:
    return errorBody("name a mod: /aowlspt/mods/clear/<id>")
  if not clearOverride(id):
    return errorBody(id & " has no override to clear; the active lists decide it")
  afterChange()
  result = changeReply(id, "clear")

proc routeSelectOne(url, body, session: string): string =
  let id = pathAfter(url, "/aowlspt/mods/select/")
  if id.len == 0:
    return errorBody("name a list: /aowlspt/mods/select/<list-id>")
  var idx = -1
  if not findList(gRegistry, id, idx):
    return errorBody("no list called " & id & " in " & gRegistryPath)
  var one: seq[string] = @[]
  one.add id
  setLists(one)
  afterChange()
  var o = obj()
  put(o, "ok", true)
  put(o, "active", id)
  put(o, "loaded", gRes.order.len)
  put(o, "problems", problemsJson())
  result = done(o).text

proc routeSelect(url, body, session: string): string =
  ## `{"lists":["a","b"]}` — the ordered set of active lists. Order matters:
  ## a later list's entries override an earlier one's for the same mod.
  let given = each(field(body, "lists"))
  var wanted: seq[string] = @[]
  for g in given:
    let id = g.asText("")
    if id.len == 0:
      continue
    var idx = -1
    if not findList(gRegistry, id, idx):
      return errorBody("no list called " & id & " in " & gRegistryPath)
    wanted.add id
  if wanted.len == 0 and body.len > 0 and field(body, "lists").exists:
    # An explicit empty array is a real selection ("nothing"), and is honoured;
    # a body with no `lists` at all is a malformed request and is refused rather
    # than read as "turn everything off".
    setLists(wanted)
    afterChange()
  elif wanted.len == 0:
    return errorBody("send {\"lists\":[\"<list-id>\",...]}")
  else:
    setLists(wanted)
    afterChange()
  var active = arr()
  let act = activeLists()
  for l in act:
    active.add l
  var o = obj()
  put(o, "ok", true)
  put(o, "active", active)
  put(o, "loaded", gRes.order.len)
  put(o, "problems", problemsJson())
  result = done(o).text

proc routeReload(url, body, session: string): string =
  ## Re-read the registry from disk. This is what makes `git pull` in the
  ## registry checkout visible without restarting anything.
  discoverRegistry()
  afterChange()
  var o = statusJson()
  put(o, "reloaded", true)
  result = done(o).text

proc routeApply(url, body, session: string): string =
  let o = applySelection()
  result = done(o).text

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc readConfig() =
  gProbeMs = setting("controlProbeMs").asInt(750)
  gWriteSelectionFile = setting("writeSelectionFile").asBool(true)
  let raw = setting("activeLists").asText("")
  if raw.len > 0:
    let entries = each(whole(raw))
    for e in entries:
      let id = e.asText("")
      if id.len > 0:
        gDefaultLists.add id

proc logSummary() =
  if not gRegistry.ok:
    warn "manager: " & gRegistry.error
  else:
    success "manager: " & gRegistryPath & " -- " & $gRegistry.mods.len &
            " mods, " & $gRegistry.lists.len & " lists"
  var activeText = ""
  let act = activeLists()
  for l in act:
    if activeText.len > 0: activeText.add ", "
    activeText.add l
  if activeText.len == 0:
    activeText = "(none)"
  info "manager: active lists: " & activeText
  info "manager: " & summaryLine()
  var pos = 1
  for id in gRes.order:
    info "manager:   " & $pos & ". " & id
    inc pos
  for d in gRes.decisions:
    if d.verdict == vLoaded or d.verdict == vNotSelected:
      continue
    info "manager:   - " & d.id & ": " & verdictName(d.verdict) & " -- " & d.reason
  for p in gRes.problems:
    warn "manager: " & p
  for w in gRegistry.warnings:
    warn "manager: " & w
  if not storeWorks():
    info "manager: nothing has been persisted yet; the selection is stored " &
         "on the first change"

proc registerRoutes() =
  discard serve("/aowlspt/mods", routeStatus)
  discard serve("/aowlspt/mods/status", routeStatus)
  discard serve("/aowlspt/mods/list", routeList)
  discard serve("/aowlspt/mods/lists", routeLists)
  discard serve("/aowlspt/mods/conflicts", routeConflicts)
  discard serve("/aowlspt/mods/reload", routeReload)
  discard serve("/aowlspt/mods/apply", routeApply)
  discard serve("/aowlspt/mods/select", routeSelect)
  discard servePrefix("/aowlspt/mods/describe/", routeDescribe)
  discard servePrefix("/aowlspt/mods/enable/", routeEnable)
  discard servePrefix("/aowlspt/mods/disable/", routeDisable)
  discard servePrefix("/aowlspt/mods/clear/", routeClear)
  discard servePrefix("/aowlspt/mods/select/", routeSelectOne)

proc onLoad(): Status =
  readConfig()
  ensureLoaded(gDefaultLists)
  discoverRegistry()
  recompute()
  registerRoutes()
  # The probe goes out after the routes exist: a host that answers instantly
  # would otherwise be answered by a mod that cannot yet be asked anything.
  controlInit(gProbeMs)
  writeSelectionFile()
  logSummary()
  announce()
  Ok

proc onUnload(): Status =
  info "manager: unloading with " & $gRes.order.len & " mods resolved"
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = "aowlspt",
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
