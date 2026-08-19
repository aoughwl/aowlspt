## The travel graph, read out of BSG's own transit table.
##
## Path To Tarkov's central idea is that the deploy screen is not a teleporter:
## you are *somewhere*, and the only maps you may go to are the ones connected
## to where you stand. Upstream built that connection table by hand, because the
## pre-1.0 client had no notion of one map leading to another.
##
## Post-1.0 the game ships the table. Every `locations.<key>.base` carries a
## `transits` array, and each entry names a destination twice over:
##
##     {"id": 9, "location": "RezervBase", "name": "CUS_TRANSIT_9",
##      "target": "5704e5fad2720bc05b8b4567", "active": true,
##      "conditions": "CUS_TRANSIT_9_COND", "activateAfterSec": 60, "time": 20}
##
## `location` is a display-ish string whose spelling agrees with nothing in
## particular — `RezervBase`, `factory4_day` and `Interchange` all appear in the
## same table — and `target` is the destination's `_Id`. **This module resolves
## by `target` and never by `location`**, because `_Id` is the one field that is
## a key rather than a name. On the database in `build/db/db.json` that resolves
## 38 of 38 edges across 19 maps; resolving by `location` instead needs a
## case-insensitive match against three different fields and still misses.
##
## The graph is **directed and is not strongly connected**, which is a fact
## about BSG's table and not a modelling choice:
##
##   * nothing anywhere targets `sandbox` (Ground Zero, low), so it is a source
##     you can leave and never re-enter;
##   * `terminal` has no outgoing transits at all, so it is a sink — a player
##     standing there under a strict graph can never move again;
##   * `laboratory` has exactly one way out (`tarkovstreets`).
##
## `sinks`, `sources` and `strandedFrom` exist so the mod can *say* that before
## it locks anything, instead of the player discovering it from a menu with one
## map left on it. `tests/pttguard` asserts each of those numbers against the
## real database.
##
## Nothing in this file talks to a host. It takes JSON text and answers
## questions about it, so the test drives it with the real `db.json` and no
## backend.

import std/strutils
import aowlspt/json

type
  Edge* = object
    toKey*: string        ## resolved destination map key; "" when unresolved
    target*: string       ## the `target` id the table named
    named*: string        ## the `location` string the table named
    active*: bool         ## BSG's own `active` flag on the transit
    conditions*: string   ## the condition id, kept for the report

  MapNode* = object
    key*: string          ## the database key: `bigmap`, `factory4_day`, ...
    id*: string           ## base.Id      -- `Interchange`, `bigmap`, ...
    objectId*: string     ## base._Id     -- the MongoId edges resolve against
    name*: string         ## base.Name    -- `Customs`
    enabled*: bool        ## base.Enabled
    locked*: bool         ## base.Locked, as first read
    edges*: seq[Edge]

  Graph* = object
    nodes*: seq[MapNode]

proc indexOf*(g: Graph; key: string): int =
  ## The node for a database key, or -1.
  result = -1
  for i in 0 ..< g.nodes.len:
    if g.nodes[i].key == key:
      return i

proc has*(g: Graph; key: string): bool = indexOf(g, key) >= 0

proc nodeCount*(g: Graph): int = g.nodes.len

proc edgeCount*(g: Graph): int =
  result = 0
  for n in g.nodes:
    result = result + n.edges.len

proc addBase*(g: var Graph; key, baseText: string): bool =
  ## Read one map's `base` document into the graph. False when there is nothing
  ## usable there — which is an ordinary answer for a map key that is not in
  ## this database, and the caller reports it rather than inventing a node.
  ##
  ## A map already present is *replaced*, so that a second pass after
  ## `aowlspt.locations.changed` corrects a node rather than duplicating it.
  ## `locked` is the exception: see `mergeLocked` at the call site — this
  ## records what the database says right now, and what the world looked like
  ## before this mod touched it is the mod's business, not the graph's.
  if key.len == 0 or baseText.len < 2:
    return false
  let base = whole(baseText)
  if not isObject(base):
    return false

  var node = MapNode(key: key,
                     id: child(base, "Id").asText(""),
                     objectId: child(base, "_Id").asText(""),
                     name: child(base, "Name").asText(""),
                     enabled: child(base, "Enabled").asBool(false),
                     locked: child(base, "Locked").asBool(false),
                     edges: @[])

  # `transits` is pulled out as text before it is walked. `each` hands back a
  # JsonRef per element and each one carries the document it points into, so
  # walking the array in place would copy a 200 KB `base` once per transit.
  let transitsRaw = raw(child(base, "transits"))
  if transitsRaw.len >= 2:
    let list = whole(transitsRaw)
    if isArray(list):
      let items = each(list)
      for t in items:
        let target = child(t, "target").asText("")
        if target.len == 0:
          continue
        node.edges.add Edge(toKey: "",
                            target: target,
                            named: child(t, "location").asText(""),
                            active: child(t, "active").asBool(false),
                            conditions: child(t, "conditions").asText(""))

  let at = indexOf(g, key)
  if at >= 0:
    g.nodes[at] = node
  else:
    g.nodes.add node
  result = true

proc resolve*(g: var Graph): int =
  ## Second pass: turn every `target` into a map key. Answers how many edges
  ## could **not** be resolved, which is the number the mod prints — an
  ## unresolved edge is a destination this database does not contain, and it
  ## has to be visible rather than silently dropped, because it is the shape a
  ## renamed or removed map arrives in.
  result = 0
  for i in 0 ..< g.nodes.len:
    for e in 0 ..< g.nodes[i].edges.len:
      let target = g.nodes[i].edges[e].target
      var found = ""
      for j in 0 ..< g.nodes.len:
        if g.nodes[j].objectId.len > 0 and g.nodes[j].objectId == target:
          found = g.nodes[j].key
          break
      g.nodes[i].edges[e].toKey = found
      if found.len == 0:
        inc result

proc unresolvedCount*(g: Graph): int =
  result = 0
  for n in g.nodes:
    for e in n.edges:
      if e.toKey.len == 0:
        inc result

proc keyOf*(g: Graph; nameOrId: string): string =
  ## Normalise whatever named a map into a database key.
  ##
  ## Four spellings reach this mod for the same place and none of them is under
  ## its control: the database key (`rezervbase`), `base.Id` (`RezervBase`),
  ## `base._Id` (a MongoId), and `base.Name` (`ReserveBase`). The raid the
  ## client configures arrives as whatever the client sent, and the transit
  ## table's own `location` field uses a third spelling again. Matching on one
  ## of them and calling it a day is how a mod ends up moving the player to a
  ## map they did not play.
  ##
  ## Exact key first, then case-insensitive `Id`, `_Id`, `Name`. "" when
  ## nothing matches, which the caller must treat as "I do not know where the
  ## player is" rather than as a default.
  if nameOrId.len == 0:
    return ""
  if has(g, nameOrId):
    return nameOrId
  let want = toLowerAscii(nameOrId)
  for n in g.nodes:
    if toLowerAscii(n.key) == want: return n.key
  for n in g.nodes:
    if n.id.len > 0 and toLowerAscii(n.id) == want: return n.key
  for n in g.nodes:
    if n.objectId.len > 0 and toLowerAscii(n.objectId) == want: return n.key
  for n in g.nodes:
    if n.name.len > 0 and toLowerAscii(n.name) == want: return n.key
  result = ""

proc contains(s: seq[string]; v: string): bool =
  result = false
  for x in s:
    if x == v: return true

proc neighbours*(g: Graph; key: string; includeInactive: bool): seq[string] =
  ## Every map one transit away from `key`.
  result = @[]
  let at = indexOf(g, key)
  if at < 0:
    return
  for e in g.nodes[at].edges:
    if e.toKey.len == 0:
      continue
    if not e.active and not includeInactive:
      continue
    if not contains(result, e.toKey):
      result.add e.toKey

proc reachable*(g: Graph; fromKey: string; hops: int;
                includeInactive: bool): seq[string] =
  ## Breadth-first from `fromKey`, up to `hops` transits. Does **not** include
  ## `fromKey` itself; the caller adds it, because "the map you are standing on"
  ## and "the maps you can travel to" are two different reasons for a map to be
  ## open and the mod reports them separately.
  result = @[]
  if hops <= 0 or indexOf(g, fromKey) < 0:
    return
  var frontier: seq[string] = @[fromKey]
  var depth = 0
  while depth < hops and frontier.len > 0:
    var next: seq[string] = @[]
    for f in frontier:
      let ns = neighbours(g, f, includeInactive)
      for n in ns:
        if n == fromKey or contains(result, n) or contains(next, n):
          continue
        next.add n
    for n in next:
      result.add n
    frontier = next
    inc depth

proc inboundCount*(g: Graph; key: string; includeInactive: bool): int =
  result = 0
  for n in g.nodes:
    if n.key == key:
      continue
    for e in n.edges:
      if e.toKey == key and (e.active or includeInactive):
        inc result

proc outboundCount*(g: Graph; key: string; includeInactive: bool): int =
  let ns = neighbours(g, key, includeInactive)
  result = ns.len

proc sinks*(g: Graph; includeInactive: bool): seq[string] =
  ## Maps with no way out. Standing on one under a strict graph is the end of
  ## the game, so the mod refuses to leave the player there without saying so.
  result = @[]
  for n in g.nodes:
    if outboundCount(g, n.key, includeInactive) == 0:
      result.add n.key

proc sources*(g: Graph; includeInactive: bool): seq[string] =
  ## Maps nothing leads to. Reachable only by starting there.
  result = @[]
  for n in g.nodes:
    if inboundCount(g, n.key, includeInactive) == 0:
      result.add n.key

proc strandedFrom*(g: Graph; fromKey: string; includeInactive: bool): bool =
  ## True when standing on `fromKey` leaves nowhere to go.
  result = outboundCount(g, fromKey, includeInactive) == 0

proc openSet*(g: Graph; position: string; hops: int; includeInactive: bool;
              alwaysOpen: seq[string]): seq[string] =
  ## The maps that must be unlocked while the player stands on `position`:
  ## the position itself, everything within `hops` transits of it, and the
  ## always-open list. Anything else in the graph is locked.
  ##
  ## `position` is included even when it is not in the graph — a player standing
  ## on a map this mod does not know about must still be able to play, and a
  ## graph that has just lost a map to a database change is the ordinary way
  ## that happens.
  result = @[]
  if position.len > 0:
    result.add position
  let r = reachable(g, position, hops, includeInactive)
  for k in r:
    if not contains(result, k):
      result.add k
  for k in alwaysOpen:
    if k.len > 0 and not contains(result, k):
      result.add k
