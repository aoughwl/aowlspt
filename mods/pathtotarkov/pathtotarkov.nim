## Path To Tarkov, rebuilt on the game's own transit graph.
##
## ---------------------------------------------------------------------------
## WHAT IT IS
## ---------------------------------------------------------------------------
##
## The deploy screen is a teleporter: every map, always, from a menu. Path To
## Tarkov is the mod that took that away and gave the player a *place* instead —
## you are standing somewhere, you may only go where that place connects to, and
## the map you climb out onto is where you now are. It is one of the most
## downloaded server-side mods SPT ever had, and the reason is that it turns a
## map list into a world.
##
## This is that design, rewritten from scratch against `aowlspt`. It is not a
## translation: upstream is TypeScript against SPT's server and a client plugin
## against a pre-1.0 client, and neither exists here. What survives is the idea
## and the shape of the rules.
##
## **The one thing this port does differently, and it is the whole reason it can
## exist post-1.0.** Upstream had to *invent* the connections between maps: the
## pre-1.0 client had no notion of one map leading to another, so the mod
## shipped a hand-written table of exfil-name → destination and a client plugin
## to read the exfil the player actually took. Post-1.0 the game ships the
## table itself. Every `locations.<key>.base` carries a `transits` array naming
## the maps it connects to, and `TransitSettings` in `globals.config` prices
## them. This mod reads BSG's graph and never invents an edge — which means the
## connections cannot drift out of date with the client, because they *are* the
## client's.
##
## The graph on the database in `build/db/db.json`: 19 maps, 38 transits, all 38
## resolving to a map in the same table.
##
## ---------------------------------------------------------------------------
## THE MECHANISM, IN ONE PARAGRAPH
## ---------------------------------------------------------------------------
##
## `locations.<key>.base.Locked` is a boolean the database ships on every map,
## and the maps that ship it `true` — `hideout`, `town`, `privatearea`,
## `suburbs`, `terminal` — are exactly the maps you cannot deploy to. This mod
## writes that field: the map you stand on and everything one transit away are
## `false`, everything else is `true`, and the set is recomputed every time you
## come out of a raid. That is the entire game-facing surface. There is no
## client half, no detour and no invented endpoint.
##
## **That the client honours `Locked` is an argument from the database, not an
## observation.** Nothing here has ever run against BSG's client. The evidence
## is that BSG uses the field for precisely this purpose on five maps in the
## shipped data; the disproof would be a raid launched onto a map this mod has
## locked. `README.md` says what that would cost and what to do about it.
##
## ---------------------------------------------------------------------------
## WHAT IT REFUSES
## ---------------------------------------------------------------------------
##
## * **Per-zone traders and per-zone stashes.** Upstream's headline feature —
##   only the traders in your zone will talk to you, and your stash follows you —
##   is per *profile*, and the profile belongs to `mods/tarkov`. A second mod
##   editing another mod's profile documents behind its back is how a save gets
##   corrupted. Not done, and not worked around.
## * **Which exfil you took.** Upstream reads the exfil name from the client and
##   moves you to the map that exfil leads to. Here the raid-end event carries a
##   profile id and nothing else, so this mod knows the map you were on and not
##   the door you left by. It therefore moves you to *the map you played*, which
##   is right for a transit (you arrive where the transit went) and wrong for an
##   ordinary extract (you should have moved on). The cost is in `README.md`.
## * **Refusing a raid onto a locked map.** `/client/match/local/start` belongs
##   to `mods/tarkov` and a route may be registered once. If the client ignores
##   `Locked`, this mod cannot stop the raid — it can only notice afterwards.
##
## ---------------------------------------------------------------------------
## WHAT IT IS THE FIRST MOD HERE TO USE
## ---------------------------------------------------------------------------
##
## `stateSave`/`stateLoad` with `mfHotReloadable` (no mod in `mods/` had any),
## `configFaulted()` and `notifyReady()` (nothing had called either), and
## `everyMs` (one other call site in the tree). Each is used because the mod
## needs it, and the reason is written at the site.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ptt/graph
import ptt/state

const
  ModGuid* = "aowl.pathtotarkov"
  ModName* = "Path To Tarkov"
  ModVersion* = "1.0.0"

  ## The map keys a stock database ships. Used when `maps` in the config is
  ## empty, which is how it ships: a hard-coded list is wrong the first time a
  ## map mod adds one, so this is the fallback and `aowlspt.locations.hello`
  ## (below) is the mechanism.
  StockMaps: array[19, string] = [
    "bigmap", "develop", "factory4_day", "factory4_night", "hideout",
    "interchange", "laboratory", "labyrinth", "lighthouse", "privatearea",
    "rezervbase", "sandbox", "sandbox_high", "shoreline", "suburbs",
    "tarkovstreets", "terminal", "town", "woods"]

  RouteWhere = "/aowlspt/ptt/where"
  RouteGraph = "/aowlspt/ptt/graph"
  RouteTravel = "/aowlspt/ptt/travel/"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

var cfgEnabled = false
var cfgStartAt = "sandbox"
var cfgHops = 1
var cfgIncludeInactive = false
var cfgScavRaidsMove = false
var cfgLockUnknown = false
var cfgFreeRoamWhenStranded = true
var cfgReconcileSeconds = 300
var cfgNotifyOnMove = false
var cfgRoutes = true
var cfgDiscover = "config"
var cfgMaps: seq[string] = @[]
var cfgAlwaysOpen: seq[string] = @[]
var cfgFaulted = false

proc textList(key: string): seq[string] =
  ## A JSON array of strings out of the config, empty when absent.
  result = @[]
  let v = setting(key)
  if not v.ok or v.raw.len < 2:
    return
  let list = whole(v.raw)
  if not isArray(list):
    return
  let items = each(list)
  for it in items:
    let s = asText(it, "")
    if s.len > 0:
      result.add s

proc readConfig() =
  # `configFaulted` first, and it decides whether anything else is read.
  #
  # This is the mod the note in `aowlspt/server` is describing: its defaults
  # are a *decision* (a starting map, a list of maps, a hop count) and not a
  # fallback, and acting on them because a config file failed to parse means
  # locking fifteen maps a player never asked to have locked. A missing file is
  # fine — that is a player who never wrote one. A file that is there and does
  # not parse is a player whose intent is unknown, and the safe reading of an
  # unknown intent is to do nothing at all.
  cfgFaulted = configFaulted()
  if cfgFaulted:
    error "config.json is present and does not parse (" & lastError() &
          "). Nothing will be locked and nothing will be moved: the settings " &
          "this mod would otherwise fall back on are decisions about your " &
          "game, not defaults. Fix the file or delete it."
    cfgEnabled = false
    return

  cfgEnabled = setting("enabled").asBool(false)
  cfgStartAt = setting("startAt").asText("sandbox")
  cfgHops = setting("hops").asInt(1)
  if cfgHops < 1: cfgHops = 1
  if cfgHops > 6: cfgHops = 6
  cfgIncludeInactive = setting("includeInactiveTransits").asBool(false)
  cfgScavRaidsMove = setting("scavRaidsMove").asBool(false)
  cfgLockUnknown = setting("lockMapsWithNoTransits").asBool(false)
  cfgFreeRoamWhenStranded = setting("freeRoamWhenStranded").asBool(true)
  cfgReconcileSeconds = setting("reconcileSeconds").asInt(300)
  cfgNotifyOnMove = setting("notifyOnMove").asBool(false)
  cfgRoutes = setting("routes").asBool(true)
  cfgDiscover = setting("discoverMaps").asText("config")
  cfgMaps = textList("maps")
  cfgAlwaysOpen = textList("alwaysOpen")

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

const StoreKey = "world"

var gGraph = Graph(nodes: @[])
var gState = newState("sandbox")
var gLoadedState = false
var gApplied: seq[string] = @[]      ## map keys this mod has written `true` to
var gWrites = 0
var gTampered = 0
var gMoves = 0
var gDbPresent = false
var gDiscoverMs = 0
var gNotifyReady = false
var gNotifySent = 0
var gNotifyRefused = 0
var gRestored = 0
var gTransitsKnown = false
var gTransitsActive = false

proc contains(s: seq[string]; v: string): bool =
  result = false
  for x in s:
    if x == v: return true

proc persist() =
  if save(StoreKey, encode(gState)) != Ok:
    warn "could not save the world state: " & lastError()

proc loadState() =
  ## `missing` is the field with teeth, and this is the mod it has teeth for.
  ##
  ## A failed-but-present save is the case that must never be overwritten: the
  ## baseline in it is the only record of what `Locked` said before this mod
  ## ran, and starting a fresh one would capture this mod's own writes as the
  ## world's original state. From then on uninstalling leaves fifteen maps
  ## locked forever and the file that could have said otherwise has been
  ## replaced. So: missing means new, unreadable means refuse.
  if gLoadedState:
    return
  gLoadedState = true
  let stored = load(StoreKey)
  if stored.ok:
    gState = decode(stored.raw, cfgStartAt)
    return
  if not stored.missing:
    error "the saved world state exists and could not be read (" &
          stored.error & "). This mod will not start a new one over it: the " &
          "baseline it holds is the only record of which maps were locked " &
          "before this mod ran. Nothing will be locked this session. A copy " &
          "under store/" & ModGuid & "/.hist/ very likely still has it."
    cfgEnabled = false
    return
  gState = newState(cfgStartAt)

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

proc addMap(key: string): bool =
  ## Read one map's `base` into the graph, and capture its `Locked` baseline the
  ## first time it is seen.
  let v = dbRead("locations." & key & ".base")
  if not v.ok or v.raw.len < 2:
    return false
  if not addBase(gGraph, key, v.raw):
    return false
  let at = indexOf(gGraph, key)
  if at >= 0:
    discard rememberBaseline(gState, key, gGraph.nodes[at].locked)
  result = true

proc discoverFromConfig(): int =
  result = 0
  var wanted: seq[string] = @[]
  if cfgMaps.len > 0:
    for k in cfgMaps: wanted.add k
  else:
    for k in StockMaps: wanted.add k
  for k in wanted:
    if addMap(k):
      inc result

proc discoverByScan(): int =
  ## Every key under `locations`, by reading the table and asking for its member
  ## names.
  ##
  ## **This is the expensive one and it is here because the API leaves no cheap
  ## way to do it.** There is no `dbKeys(path)`: `dbRead` answers with a
  ## subtree's text, so "which maps does this database have" costs the whole
  ## `locations` table — 13.5 MB on a stock import, and ~560 MB on one imported
  ## with loose loot, which is why `mods/tarkov` stopped reading it whole. The
  ## config list is the default for that reason. This exists so that a database
  ## with maps nobody listed can still be handled, and it prints what it cost.
  let t0 = nowMs()
  let v = dbRead("locations")
  if not v.ok:
    gDiscoverMs = int(nowMs() - t0)
    return 0
  let names = keys(whole(v.raw))
  result = 0
  for k in names:
    if addMap(k):
      inc result
  gDiscoverMs = int(nowMs() - t0)

proc discover(): int =
  gGraph = Graph(nodes: @[])
  if cfgDiscover == "scan":
    result = discoverByScan()
    if result == 0:
      result = discoverFromConfig()
  else:
    let t0 = nowMs()
    result = discoverFromConfig()
    gDiscoverMs = int(nowMs() - t0)
  discard resolve(gGraph)

# ---------------------------------------------------------------------------
# The world
# ---------------------------------------------------------------------------

proc desiredOpen(): seq[string] =
  ## The maps that must be unlocked right now.
  result = openSet(gGraph, gState.position, cfgHops, cfgIncludeInactive,
                   cfgAlwaysOpen)

proc managed(key: string): bool =
  ## Whether this mod locks this map at all.
  ##
  ## A map with no transits in either direction is not part of the travel graph
  ## — `terminal`, `town`, `suburbs` and the two non-maps `hideout` and
  ## `develop` are all in that state on a stock database. Locking them would be
  ## this mod deciding about maps the game's own graph says nothing about, so by
  ## default it leaves them exactly as it found them. `lockMapsWithNoTransits`
  ## turns that off for a player who wants a closed world.
  let at = indexOf(gGraph, key)
  if at < 0:
    return false
  if cfgLockUnknown:
    return true
  if gGraph.nodes[at].edges.len > 0:
    return true
  result = inboundCount(gGraph, key, true) > 0

proc writeLocked(key: string; locked: bool): bool =
  let st = dbWrite("locations." & key & ".base",
                   "{\"Locked\":" & (if locked: "true" else: "false") & "}")
  if st != Ok:
    warn "could not write Locked on " & key & ": " & lastError()
    return false
  inc gWrites
  result = true

proc readLocked(key: string; known: var bool): bool =
  let v = dbRead("locations." & key & ".base.Locked")
  known = v.ok
  if not v.ok:
    return false
  result = v.raw == "true"

proc applyWorld(reason: string): int =
  ## Lock everything that is not reachable, unlock everything that is. Answers
  ## how many maps were written.
  ##
  ## Written by comparing against the database rather than against a memory of
  ## what was written last: another mod, a hand edit or a reload can have moved
  ## it, and a mod that trusts its own memory of a shared database is a mod that
  ## stops matching it silently.
  result = 0
  if not cfgEnabled:
    return 0
  let open = desiredOpen()

  # The stranding check, before anything is written. A position with no way out
  # is a dead end in BSG's graph, not a mistake by the player, and locking the
  # world around one ends the game with no message.
  if strandedFrom(gGraph, gState.position, cfgIncludeInactive) and
     cfgFreeRoamWhenStranded:
    warn "you are standing on " & gState.position & ", which has no outgoing " &
         "transit in the game's own table. Nothing is locked this pass -- " &
         "locking the world around a dead end would leave you with one map " &
         "and no way off it. Travel somewhere with /aowlspt/ptt/travel/<map>, " &
         "or set freeRoamWhenStranded to false to accept the dead end."
    for n in gGraph.nodes:
      if managed(n.key):
        var known = false
        let cur = readLocked(n.key, known)
        if known and cur and contains(gApplied, n.key):
          if writeLocked(n.key, false): inc result
    gApplied = @[]
    return

  var nowApplied: seq[string] = @[]
  for n in gGraph.nodes:
    let key = n.key
    if not managed(key):
      continue
    let wantLocked = not contains(open, key)
    if wantLocked:
      nowApplied.add key
    var known = false
    let cur = readLocked(key, known)
    if not known:
      continue
    if cur == wantLocked:
      continue
    # A map this mod had locked that is now unlocked in the database, while the
    # position has not changed, is somebody else's write. Counted separately,
    # because "the reconcile pass keeps finding work" is a fact about the
    # install and not about this mod.
    if reason == "reconcile":
      inc gTampered
    if writeLocked(key, wantLocked):
      inc result
  gApplied = nowApplied

proc restoreWorld(): int =
  ## Put `Locked` back to what it was before this mod ever wrote it.
  ##
  ## `onUnload` is for putting the game back the way you found it, and for a
  ## server mod that means the database. Without this, uninstalling leaves the
  ## world locked in whatever shape the last raid left it, in a file that
  ## persists, with no mod loaded to explain it.
  result = 0
  for n in gGraph.nodes:
    var known = false
    let was = baselineLocked(gState, n.key, known)
    if not known:
      continue
    var isKnown = false
    let cur = readLocked(n.key, isKnown)
    if not isKnown or cur == was:
      continue
    if writeLocked(n.key, was):
      inc result

# ---------------------------------------------------------------------------
# Telling the player
# ---------------------------------------------------------------------------

proc announceMove(toKey: string) =
  var o = obj()
  put(o, "guid", ModGuid)
  put(o, "position", toKey)
  var open = arr()
  let d = desiredOpen()
  for k in d: add(open, k)
  put(o, "open", open)
  put(o, "moves", gState.moves)
  discard broadcast("pathtotarkov.moved", o)

  if not cfgNotifyOnMove:
    return
  # `notifyReady()` is a size test against ABI revision 5 and answers "there is
  # a function here", not "it will deliver". It is true on the backend and false
  # everywhere else, and this is the first mod in the tree to ask.
  #
  # **And the honest part: this mod usually has nobody to push to.**
  # `notifyPush` addresses a *session*, every event a mod can observe carries a
  # *profile*, and the API offers no way to turn one into the other and no way
  # to enumerate live sessions. The only session ids this mod can ever hold are
  # the ones that arrive on its own routes, which the game client never calls.
  # So this fires for an operator tool that has talked to `/aowlspt/ptt/*`, and
  # for nobody else. The refusal is logged rather than swallowed; see README.md.
  if not gNotifyReady:
    info "notifyOnMove is on and this host has no notifier (notifyReady is " &
         "false on " & hostName() & "); the move was broadcast to mods only"
    return
  if gState.lastSession.len == 0:
    info "notifyOnMove is on and no session has ever reached this mod's " &
         "routes, so there is no session id to push to. A profile id is not " &
         "one -- see README.md."
    return
  var note = obj()
  put(note, "type", "aowl.pathtotarkov.moved")
  put(note, "eventId", ModGuid & "." & $gState.moves)
  put(note, "location", toKey)
  let st = notifyPush(gState.lastSession, done(note).text)
  if st == Ok:
    inc gNotifySent
    success "pushed the move to session " & gState.lastSession
  else:
    inc gNotifyRefused
    info "the notifier refused the move for session " & gState.lastSession &
         " (" & lastError() & "). The payload shape above is this mod's " &
         "guess and no client has ever acknowledged one."

proc moveTo(key: string; why: string): bool =
  let resolved = keyOf(gGraph, key)
  let target = (if resolved.len > 0: resolved else: key)
  if not moveTo(gState, target):
    return false
  inc gMoves
  persist()
  let written = applyWorld(why)
  success "you are now on " & target & " (" & why & "); " & $written &
          " map(s) rewritten, " & $desiredOpen().len & " open"
  announceMove(target)
  result = true

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

proc onRaidConfigured(payload: string): string =
  result = ""
  let loc = field(payload, "location").asText("")
  let key = keyOf(gGraph, loc)
  if key.len == 0:
    warn "a raid was configured on \"" & loc & "\", which is not a map this " &
         "mod knows. The raid is not touched and the position will not move."
    return
  beginRaid(gState, field(payload, "profileId").asText(""), key,
            field(payload, "side").asText("Pmc"))
  if cfgEnabled and not contains(desiredOpen(), key):
    warn "the raid is on " & key & ", which this mod has locked. Either the " &
         "client does not act on Locked, or something else unlocked it. That " &
         "is the one observation that would disprove this mod; see README.md."

proc onRaidEnded(payload: string): string =
  result = ""
  var toKey = ""
  let profile = field(payload, "profile").asText("")
  if not raidEndMoves(gState, profile, cfgScavRaidsMove, toKey):
    clearRaid(gState)
    return
  clearRaid(gState)
  if not moveTo(toKey, "raid"):
    # Ending a raid on the map you started it from is the ordinary case, not a
    # failure: you extracted rather than transited.
    persist()

proc onLocationsChanged(payload: string): string =
  ## A map mod has added or changed a location. `mods/icebreaker` emits this
  ## after its writes land, and answers `aowlspt.locations.hello` with the same
  ## payload — so a mod that reads every location has to join that protocol or
  ## it silently excludes every map another mod added.
  result = ""
  let list = field(payload, "locations")
  if not exists(list):
    return
  var added = 0
  let items = each(list)
  for it in items:
    let key = asText(it, "")
    if key.len > 0 and addMap(key):
      inc added
  if added == 0:
    return
  discard resolve(gGraph)
  info "a map mod announced " & $added & " location(s); the graph is now " &
       $nodeCount(gGraph) & " map(s) and " & $edgeCount(gGraph) & " transit(s)"
  discard applyWorld("locations.changed")

proc onReconcileEvent(payload: string): string =
  result = ""
  let n = applyWorld("reconcile")
  info "reconcile: " & $n & " map(s) rewritten"

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc noteSession(session: string) =
  if session.len == 0 or session == gState.lastSession:
    return
  gState.lastSession = session
  persist()

proc whereBody(): string =
  var o = obj()
  put(o, "guid", ModGuid)
  put(o, "version", ModVersion)
  put(o, "enabled", cfgEnabled)
  put(o, "position", gState.position)
  put(o, "moves", gState.moves)
  put(o, "maps", nodeCount(gGraph))
  put(o, "transits", edgeCount(gGraph))
  put(o, "unresolved", unresolvedCount(gGraph))
  put(o, "writes", gWrites)
  put(o, "tampered", gTampered)
  var open = arr()
  let d = desiredOpen()
  for k in d: add(open, k)
  put(o, "open", open)
  var locked = arr()
  for n in gGraph.nodes:
    if managed(n.key) and not contains(d, n.key):
      add(locked, n.key)
  put(o, "locked", locked)
  var live = arr()
  for n in gGraph.nodes:
    var known = false
    let cur = readLocked(n.key, known)
    if known and cur:
      add(live, n.key)
  put(o, "lockedInDatabase", live)
  result = done(o).text

proc onWhere(url, body, session: string): string =
  noteSession(session)
  result = whereBody()

proc onGraph(url, body, session: string): string =
  noteSession(session)
  var maps = arr()
  for n in gGraph.nodes:
    var m = obj()
    put(m, "key", n.key)
    put(m, "name", n.name)
    put(m, "enabled", n.enabled)
    var to = arr()
    for e in n.edges:
      var t = obj()
      put(t, "to", e.toKey)
      put(t, "named", e.named)
      put(t, "active", e.active)
      put(t, "target", e.target)
      add(to, t)
    put(m, "transits", to)
    add(maps, m)
  var o = obj()
  put(o, "guid", ModGuid)
  put(o, "maps", maps)
  var sinkList = arr()
  let sk = sinks(gGraph, cfgIncludeInactive)
  for k in sk: add(sinkList, k)
  put(o, "sinks", sinkList)
  var sourceList = arr()
  let sc = sources(gGraph, cfgIncludeInactive)
  for k in sc: add(sourceList, k)
  put(o, "sources", sourceList)
  result = done(o).text

proc onTravel(url, body, session: string): string =
  ## Move the player deliberately. This is the operator's door, not the game's:
  ## the client never calls it. It exists because a graph with a dead end in it
  ## needs a way out that does not involve editing a store file by hand.
  noteSession(session)
  let want = pathAfter(url, RouteTravel)
  let key = keyOf(gGraph, want)
  if key.len == 0:
    return errJson("no such map: " & want)
  if not cfgEnabled:
    return errJson("this mod is not enabled; nothing was moved")
  let open = desiredOpen()
  if not contains(open, key) and not setting("allowTeleport").asBool(false):
    return errJson(key & " is not reachable from " & gState.position &
                   "; set allowTeleport to travel anywhere")
  discard moveTo(key, "travel")
  result = whereBody()

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

proc report() =
  info ModName & " " & ModVersion & " on " & hostName() &
       " (spt " & (if sptVersion().len > 0: sptVersion() else: "unreported") &
       ", host api " & $hostApiSize() & "/" & $expectedApiSize() & ")"
  if not gDbPresent:
    warn "no database on this host, so there is no transit table to read and " &
         "nothing to lock. That is the expected answer on the simulator " &
         "without --db and on the client host."
    return
  info "  graph: " & $nodeCount(gGraph) & " map(s), " & $edgeCount(gGraph) &
       " transit(s), " & $unresolvedCount(gGraph) &
       " of them naming a map this database does not have (" & $gDiscoverMs &
       " ms to read, discoverMaps=" & cfgDiscover & ")"
  let sk = sinks(gGraph, cfgIncludeInactive)
  var sinkNames = ""
  for k in sk:
    if sinkNames.len > 0: sinkNames.add ", "
    sinkNames.add k
  # The game's own switch for the whole transit system. Worth one read and one
  # line, because it is the setting that decides whether the graph this mod
  # locks by is a graph the player can actually walk: with it off, a locked
  # world is one you travel through the deploy screen or not at all.
  if not gTransitsKnown:
    warn "  globals.config.TransitSettings is not in this database, so " &
         "whether the game's transit system is on at all is unknown here"
  elif gTransitsActive:
    info "  the game's own transit system is on " &
         "(globals.config.TransitSettings.active)"
  else:
    warn "  the game's own transit system is switched OFF in this database " &
         "(globals.config.TransitSettings.active is false). The graph below " &
         "is still what the maps declare, but nothing in the client would " &
         "let you walk it, so locking by it leaves you with the deploy " &
         "screen and fewer maps on it."
  info "  no way out of: " & (if sinkNames.len > 0: sinkNames else: "-")
  let sc = sources(gGraph, cfgIncludeInactive)
  var sourceNames = ""
  for k in sc:
    if sourceNames.len > 0: sourceNames.add ", "
    sourceNames.add k
  info "  nothing leads to: " & (if sourceNames.len > 0: sourceNames else: "-")
  var openNames = ""
  let d = desiredOpen()
  for k in d:
    if openNames.len > 0: openNames.add ", "
    openNames.add k
  info "  standing on " & gState.position & " (" & $gState.moves &
       " move(s) so far); open: " & openNames
  if not cfgEnabled:
    var wouldLock = 0
    for n in gGraph.nodes:
      if managed(n.key) and not contains(d, n.key):
        inc wouldLock
    warn "enabled is false, so nothing has been written. With it on, " &
         $wouldLock & " map(s) would be locked and " & $d.len & " left open."

# ---------------------------------------------------------------------------
# Load, unload, and the state that crosses a rebuild
# ---------------------------------------------------------------------------

proc onLoadServer(): Status =
  readConfig()
  loadState()
  gNotifyReady = notifyReady()
  gDbPresent = dbRead("locations." & StockMaps[0] & ".base.Id").ok or
               dbRead("locations").ok
  if gDbPresent:
    discard discover()
    let ts = dbRead("globals.config.TransitSettings.active")
    gTransitsKnown = ts.ok
    gTransitsActive = ts.ok and ts.raw == "true"
  report()

  if cfgRoutes:
    discard serve(RouteWhere, onWhere)
    discard serve(RouteGraph, onGraph)
    discard servePrefix(RouteTravel, onTravel)

  discard onEvent("tarkov.raid.configured", onRaidConfigured)
  discard onEvent("tarkov.raid.ended", onRaidEnded)
  discard onEvent("aowlspt.locations.changed", onLocationsChanged)
  discard onEvent("pathtotarkov.reconcile", onReconcileEvent)
  # Ask every map mod that is already loaded to say what it added. Icebreaker
  # answers this with `aowlspt.locations.changed`; a mod that loads later will
  # announce on its own.
  discard broadcast("aowlspt.locations.hello", objOf("guid", ModGuid))

  if cfgEnabled and gDbPresent:
    let n = applyWorld("load")
    success "the world is set for " & gState.position & ": " & $n &
            " map(s) written"
    # `everyMs` rather than a check inside a request: nothing this mod serves is
    # on the client's path, so there is no request to hang the check off. The
    # database is shared and another mod may write `Locked` after this pass; a
    # slow repeat is what turns "the world quietly stopped matching" into a
    # line in the log. Off with `reconcileSeconds: 0`.
    if cfgReconcileSeconds > 0:
      discard everyMs(cfgReconcileSeconds * 1000, onReconcileEvent)
  result = Ok

proc stateSave(): string =
  ## Just before the library is freed. Position, baseline and the pending raid
  ## — no handles, no pointers, nothing that names anything in this address
  ## space.
  result = encode(gState)

proc stateLoad(saved: string): Status =
  ## The next incarnation. Taking the state from here rather than from the store
  ## matters for the pending raid: a rebuild in the middle of a raid would
  ## otherwise lose the location the raid was configured on, and the raid would
  ## end with the player left standing where they started.
  if saved.len > 1:
    gState = decode(saved, cfgStartAt)
    gLoadedState = true
    info "carried " & $gState.baseline.len & " baseline(s) and position " &
         gState.position & " across the reload"
  result = Ok

proc onUnload(): Status =
  if side() == sideClient:
    return Ok
  persist()
  if cfgEnabled:
    gRestored = restoreWorld()
    if gRestored > 0:
      success "put " & $gRestored & " map(s) back to the Locked they had " &
              "before this mod ran"
    else:
      info "no map needed restoring"
  info ModName & ": " & $gMoves & " move(s), " & $gWrites & " database " &
       "write(s), " & $gTampered & " foreign change(s) corrected, " &
       $gNotifySent & " notification(s) delivered, " & $gNotifyRefused &
       " refused"
  result = Ok

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------

proc selfTest(): Status =
  ## `aowl run mods/pathtotarkov --db build\db\db.json`.
  ##
  ## Everything here is offline and every number is measured in this process.
  ## What it cannot establish is named rather than skipped.
  var bad = 0
  discard onLoadServer()

  if not gDbPresent:
    warn "no database was attached. Re-run with --db build\\db\\db.json to " &
         "check this mod against the real transit table; without one there " &
         "is nothing here to check and nothing was checked."
    return Ok

  if nodeCount(gGraph) < 2:
    error "the graph has " & $nodeCount(gGraph) & " map(s); a transit table " &
          "needs at least two"
    inc bad
  if edgeCount(gGraph) == 0:
    error "no transits were read at all. Either this database has none or " &
          "the field moved."
    inc bad
  if unresolvedCount(gGraph) > 0:
    warn $unresolvedCount(gGraph) & " transit(s) name a map this database " &
         "does not contain; those edges are dropped"

  # Normalisation, against the four spellings the same map arrives under. The
  # pair is deliberate: a `keyOf` that answered the first key for everything
  # would pass the positive half and fail here.
  block spellings:
    let at = indexOf(gGraph, "rezervbase")
    if at < 0:
      warn "this database has no rezervbase; the spelling check is skipped"
      break spellings
    let n = gGraph.nodes[at]
    if keyOf(gGraph, n.id) != "rezervbase" or
       keyOf(gGraph, n.objectId) != "rezervbase" or
       keyOf(gGraph, n.name) != "rezervbase":
      error "a map's Id/_Id/Name do not all resolve back to its key"
      inc bad
    if keyOf(gGraph, "a map that is not here") != "":
      error "keyOf answered a key for a name that is not in the database"
      inc bad

  # The move the mod exists to make, driven end to end with no server: a raid
  # is configured somewhere reachable, it ends, and the position follows it.
  block travel:
    let from1 = gState.position
    let ns = neighbours(gGraph, from1, true)
    if ns.len == 0:
      warn "standing on " & from1 & ", which has no outgoing transit; the " &
           "travel check is skipped"
      break travel
    let dest = ns[0]
    discard onRaidConfigured("{\"profileId\":\"p1\",\"location\":\"" & dest &
                             "\",\"side\":\"Pmc\"}")
    discard onRaidEnded("{\"profile\":\"p1\"}")
    if gState.position != dest:
      error "a raid on " & dest & " ended and the position is still " &
            gState.position
      inc bad
    else:
      success "a raid on " & dest & " moved the player there"
    # And the control: a raid ending for a profile that never configured one
    # must move nobody. Configuring it on the map just left produces the
    # "the raid is on a map this mod has locked" warning below, and that
    # warning is this check's own doing rather than a real disagreement.
    let held = gState.position
    discard onRaidConfigured("{\"profileId\":\"p1\",\"location\":\"" & from1 &
                             "\",\"side\":\"Pmc\"}")
    discard onRaidEnded("{\"profile\":\"somebody-else\"}")
    if gState.position != held:
      error "a raid ended by another profile moved this one from " & held &
            " to " & gState.position
      inc bad
    else:
      success "a raid ended by another profile moved nobody"
    clearRaid(gState)

  # Somebody else moving `Locked` underneath this mod. The reconcile pass is
  # the only thing that would ever notice, and a pass that never notices
  # anything is indistinguishable from one that is not running.
  block tamper:
    if not cfgEnabled:
      info "enabled is false, so the reconcile check is skipped -- with " &
           "nothing locked there is nothing to tamper with. Run this mod " &
           "with enabled:true against --db to exercise it."
      break tamper
    var victim = ""
    let open = desiredOpen()
    for n in gGraph.nodes:
      if managed(n.key) and not contains(open, n.key):
        victim = n.key
        break
    if victim.len == 0:
      warn "nothing is locked, so the reconcile check is skipped"
      break tamper
    discard writeLocked(victim, false)
    var known = false
    if readLocked(victim, known) or not known:
      error "the tamper did not take: " & victim & " is still locked, so the " &
            "check below would pass without the reconcile doing anything"
      inc bad
      break tamper
    let before = gTampered
    discard applyWorld("reconcile")
    let after = readLocked(victim, known)
    if known and after and gTampered > before:
      success "a foreign unlock of " & victim & " was found by the reconcile " &
              "pass and put back"
    else:
      error "a foreign unlock of " & victim & " survived the reconcile pass"
      inc bad

  # The routes, driven as the host would drive them. Each check has its
  # opposite beside it, because a handler that answered the same document to
  # everything would satisfy the positive half alone.
  block routes:
    let w = whole(onWhere(RouteWhere, "", "sim-session"))
    if not isObject(w):
      error "/aowlspt/ptt/where did not answer an object"
      inc bad
    elif child(w, "position").asText("") != gState.position or
         count(child(w, "open")) < 1:
      error "/aowlspt/ptt/where disagrees with the mod's own position"
      inc bad
    let g1 = whole(onGraph(RouteGraph, "", "sim-session"))
    if count(child(g1, "maps")) != nodeCount(gGraph):
      error "/aowlspt/ptt/graph listed " & $count(child(g1, "maps")) &
            " map(s) out of " & $nodeCount(gGraph)
      inc bad
    let refused = onTravel(RouteTravel & "not-a-map-at-all", "", "sim")
    if find(refused, "no such map") < 0:
      error "travel to a map that does not exist was not refused: " & refused
      inc bad
    let accepted = onTravel(RouteTravel & gState.position, "", "sim")
    if find(accepted, "no such map") >= 0:
      error "travel to " & gState.position & " was refused as unknown"
      inc bad
    else:
      success "the three routes answer, and travel to a map that is not " &
              "there is refused while travel to one that is, is not"

  # The notifier, asked rather than assumed.
  if gNotifyReady:
    info "this host has a notifier (ABI revision 5)"
  else:
    info "this host has no notifier, so notifyOnMove can never deliver here " &
         "(" & hostName() & ")"
  let st = notifyPush("no-such-session", "{\"type\":\"probe\"}")
  if st == Ok:
    error "the host accepted a push to a session that does not exist"
    inc bad
  elif st == ErrUnsupported:
    success "a push was refused as unsupported: this host has no notifier"
  elif st == ErrNotFound:
    success "a push to a session that does not exist was refused as not found"
  else:
    success "a push to a session that does not exist was refused (status " &
            $st & ")"

  # What crosses a rebuild.
  block reload:
    let saved = stateSave()
    let round = decode(saved, "nowhere")
    if round.position != gState.position or
       round.baseline.len != gState.baseline.len:
      error "the state does not survive its own encode/decode"
      inc bad
    else:
      success "state survives a reload: " & $round.baseline.len &
              " baseline(s), position " & round.position

  info "what this run does NOT establish:"
  info "  that the client acts on Locked. Nothing here has ever run against " &
       "BSG's client. The five maps BSG ships Locked are the argument, and a " &
       "raid launched onto a locked map is the disproof."
  info "  that a transit in the client goes where the table says. The graph " &
       "is read, never exercised."
  info "  that a notification arrives. See notifyOnMove in README.md."

  if bad == 0:
    success ModName & " self-test: the graph, the move and the state all hold"
    result = Ok
  else:
    error ModName & " self-test: " & $bad & " problem(s)"
    result = ErrGeneric

proc onLoad(): Status =
  case side()
  of sideClient:
    info ModName & " is a server mod; there is nothing for it to do in the " &
         "game's process"
    result = Ok
  of sideSim:
    result = selfTest()
  else:
    result = onLoadServer()

exportMod(
  guid = ModGuid,
  name = ModName,
  author = "Path To Tarkov's design, rewritten for aowlspt",
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad,
  onUnload = onUnload,
  stateSave = stateSave,
  stateLoad = stateLoad,
  flags = {mfHotReloadable})
