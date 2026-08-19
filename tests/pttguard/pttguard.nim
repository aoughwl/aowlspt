## Proof that `mods/pathtotarkov` answers about the real database, and that
## its answers can be wrong.
##
## Everything below is driven from `build/db/db.json` — the file `aowl importdb`
## produces from an SPT install — through the mod's own two pure modules, with
## no host, no backend and no game. What is asserted is *numbers off that
## database*: 19 maps, 38 transits, all 38 resolving, `sandbox` a source,
## `terminal` a sink, `bigmap` connecting to exactly Reserve, Factory,
## Interchange and Shoreline.
##
## **Every check comes with its opposite.** The failure this repository keeps
## producing is a check that passes because the thing it checks never happened:
## a graph that resolved nothing would satisfy "no unresolved edges", an empty
## graph would satisfy "no map is reachable from a sink", and a `keyOf` that
## answered `bigmap` for everything would satisfy every positive spelling
## check. So each of those is paired with an input that must come out the other
## way.
##
## Build and run (from PowerShell — gcc fails silently under Git Bash here):
##
##     nimony c -p:mods\pathtotarkov -p:aowl\src -o:installer\build\pttguard.exe ^
##         tests\pttguard\pttguard.nim
##     installer\build\pttguard.exe [path\to\db.json]

import std/[strutils, syncio, cmdline]
import aowlspt/json
import ptt/graph
import ptt/state

var gFailures = 0
var gChecks = 0

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    echo "ok    " & what
  else:
    echo "FAIL  " & what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc heading(what: string) =
  echo ""
  echo what
  echo repeat("-", what.len)

proc readWholeFile(path: string): string =
  result = ""
  try:
    result = readFile(path)
  except:
    result = ""

# ---------------------------------------------------------------------------
# The database
# ---------------------------------------------------------------------------

const StockMaps = [
  "bigmap", "develop", "factory4_day", "factory4_night", "hideout",
  "interchange", "laboratory", "labyrinth", "lighthouse", "privatearea",
  "rezervbase", "sandbox", "sandbox_high", "shoreline", "suburbs",
  "tarkovstreets", "terminal", "town", "woods"]

proc buildGraph(dbText: string; g: var Graph): int =
  ## The same two steps the mod takes: one `base` per map, then resolve.
  ## Answers how many maps were read.
  result = 0
  let locations = field(dbText, "locations")
  if not exists(locations):
    return 0
  for key in StockMaps:
    let base = child(child(locations, key), "base")
    if not exists(base):
      continue
    if addBase(g, key, raw(base)):
      inc result

proc graphChecks(g: var Graph) =
  heading "BSG's transit table, as this database ships it"

  check("all 19 stock map keys are present", nodeCount(g) == 19, $nodeCount(g))
  check("38 transits are read across them", edgeCount(g) == 38, $edgeCount(g))

  # The control for "all 38 resolve": before `resolve` runs, all 38 are
  # unresolved. Without this line a `resolve` that did nothing, or an
  # `unresolvedCount` that always answered 0, would pass the check under it.
  check("before resolving, every edge is unresolved",
        unresolvedCount(g) == 38, $unresolvedCount(g))
  let missed = resolve(g)
  check("resolving by `target` leaves nothing unresolved", missed == 0, $missed)
  check("and `unresolvedCount` agrees", unresolvedCount(g) == 0,
        $unresolvedCount(g))

  # An edge naming a map that is not in this database must NOT resolve --
  # otherwise "0 unresolved" above means only that the counter is broken.
  block negative:
    var g2 = Graph(nodes: @[])
    discard addBase(g2, "onlymap",
                    "{\"Id\":\"onlymap\",\"_Id\":\"aaa\",\"Name\":\"Only\"," &
                    "\"Enabled\":true,\"Locked\":false,\"transits\":[" &
                    "{\"target\":\"not-a-map\",\"location\":\"Nowhere\"," &
                    "\"active\":true,\"conditions\":\"C\"}]}")
    check("an edge to a map that is not in the table stays unresolved",
          resolve(g2) == 1, $resolve(g2))
    check("and it is not offered as a neighbour",
          neighbours(g2, "onlymap", true).len == 0, "")

  heading "Where you can go from where"

  let fromCustoms = neighbours(g, "bigmap", false)
  check("Customs connects to exactly four maps", fromCustoms.len == 4,
        $fromCustoms.len)
  var names = ""
  for k in fromCustoms:
    if names.len > 0: names.add ","
    names.add k
  check("and they are Reserve, Factory, Interchange and Shoreline",
        find(names, "rezervbase") >= 0 and find(names, "factory4_day") >= 0 and
        find(names, "interchange") >= 0 and find(names, "shoreline") >= 0,
        names)
  # The pair: a map Customs does not connect to must be absent. `woods` is one
  # transit from Customs in the other direction only, which is the case a
  # direction-blind graph gets wrong.
  check("Woods leads to Customs but Customs does not lead to Woods",
        find(names, "woods") < 0 and
        neighbours(g, "woods", false).len > 0, names)
  var woodsOut = ""
  for k in neighbours(g, "woods", false):
    if woodsOut.len > 0: woodsOut.add ","
    woodsOut.add k
  check("and Woods really does name Customs among its own transits",
        find(woodsOut, "bigmap") >= 0, woodsOut)

  check("Labs has exactly one way out", outboundCount(g, "laboratory", false) == 1,
        $outboundCount(g, "laboratory", false))
  check("and it is Streets",
        neighbours(g, "laboratory", false)[0] == "tarkovstreets", "")

  heading "The shape of the whole graph"

  let sk = sinks(g, false)
  var sinkNames = ""
  for k in sk:
    if sinkNames.len > 0: sinkNames.add ","
    sinkNames.add k
  check("six maps have no way out at all", sk.len == 6, sinkNames)
  check("terminal is one of them", find(sinkNames, "terminal") >= 0, sinkNames)
  check("and Customs is not", find(sinkNames, "bigmap") < 0, sinkNames)
  check("standing on terminal strands you",
        strandedFrom(g, "terminal", false), "")
  check("standing on Customs does not",
        not strandedFrom(g, "bigmap", false), "")

  let src = sources(g, false)
  var srcNames = ""
  for k in src:
    if srcNames.len > 0: srcNames.add ","
    srcNames.add k
  check("nothing in the table leads to Ground Zero",
        find(srcNames, "sandbox,") >= 0 or srcNames == "sandbox" or
        find(srcNames, ",sandbox") >= 0, srcNames)
  check("but something does lead to Streets",
        find(srcNames, "tarkovstreets") < 0, srcNames)
  check("and inboundCount agrees for both",
        inboundCount(g, "sandbox", false) == 0 and
        inboundCount(g, "tarkovstreets", false) > 0,
        $inboundCount(g, "sandbox", false) & "/" &
        $inboundCount(g, "tarkovstreets", false))

  heading "Transits the game itself has switched off"

  # Three of the 38 ship `active: false`. A mod that ignored the flag would
  # open Labs from Ground Zero on day one, which is exactly the shortcut this
  # setting exists to keep shut.
  check("Ground Zero leads nowhere but Streets while inactive transits are out",
        neighbours(g, "sandbox", false).len == 1, "")
  check("and to Labs as well once they are counted",
        neighbours(g, "sandbox", true).len == 2, "")
  check("the inactive edge is the Labs one",
        find(neighbours(g, "sandbox", true)[0] &
             neighbours(g, "sandbox", true)[1], "laboratory") >= 0, "")

  heading "Four spellings of one map"

  let at = indexOf(g, "rezervbase")
  check("the database has rezervbase", at >= 0, "")
  if at >= 0:
    let n = g.nodes[at]
    check("its key resolves to itself", keyOf(g, "rezervbase") == "rezervbase", "")
    check("its base.Id (`" & n.id & "`) resolves to it", keyOf(g, n.id) == "rezervbase",
          keyOf(g, n.id))
    check("its base._Id resolves to it", keyOf(g, n.objectId) == "rezervbase",
          keyOf(g, n.objectId))
    check("its base.Name (`" & n.name & "`) resolves to it",
          keyOf(g, n.name) == "rezervbase", keyOf(g, n.name))
    check("case does not matter", keyOf(g, "REZERVBASE") == "rezervbase", "")
  # The pair that makes all of the above mean something: a name that is not a
  # map must answer "", not the first key in the table.
  check("a name that is not a map resolves to nothing",
        keyOf(g, "Tarkov") == "", keyOf(g, "Tarkov"))
  check("and neither does the empty string", keyOf(g, "") == "", keyOf(g, ""))

  heading "What the mod would lock"

  let open1 = openSet(g, "bigmap", 1, false, @[])
  check("from Customs, five maps stay open", open1.len == 5, $open1.len)
  check("and Customs itself is one of them",
        find(open1[0] & "|" & open1[1], "bigmap") >= 0, open1[0])
  let open2 = openSet(g, "bigmap", 2, false, @[])
  check("two hops opens more than one does", open2.len > open1.len,
        $open2.len & " vs " & $open1.len)
  let open3 = openSet(g, "bigmap", 1, false, @["woods", "labyrinth"])
  check("alwaysOpen adds exactly what it names", open3.len == open1.len + 2,
        $open3.len)
  # And the pair: a position the graph does not have must still be open, or the
  # mod locks a player out of the map they are standing on.
  let open4 = openSet(g, "a-map-from-another-mod", 1, false, @[])
  check("a position the graph does not know is still open",
        open4.len == 1 and open4[0] == "a-map-from-another-mod", $open4.len)

proc stateChecks() =
  heading "The record that makes uninstalling safe"

  var s = newState("sandbox")
  check("a fresh state knows no baseline", not knowsBaseline(s, "bigmap"), "")
  check("the first sighting of a map is recorded",
        rememberBaseline(s, "bigmap", false), "")
  check("a second sighting is refused",
        not rememberBaseline(s, "bigmap", true), "")
  var known = false
  check("and the first value is the one kept",
        baselineLocked(s, "bigmap", known) == false and known, "")
  # The pair with teeth: `false` from a map with no baseline must be
  # distinguishable from `false` meaning "it was unlocked".
  discard baselineLocked(s, "no-such-map", known)
  check("a map with no baseline answers `not known`", not known, "")
  check("a map BSG ships locked keeps that value",
        rememberBaseline(s, "terminal", true) and
        baselineLocked(s, "terminal", known) and known, "")

  heading "Moving"

  check("moving somewhere else is a move", moveTo(s, "bigmap"), "")
  check("moving where you already are is not", not moveTo(s, "bigmap"), "")
  check("and the counter followed", s.moves == 1, $s.moves)

  heading "A raid ending"

  var dest = ""
  beginRaid(s, "profile-1", "woods", "Pmc")
  check("a PMC raid ended by the profile that configured it moves you",
        raidEndMoves(s, "profile-1", false, dest) and dest == "woods", dest)
  check("the same raid ended by another profile moves nobody",
        not raidEndMoves(s, "profile-2", false, dest), dest)
  beginRaid(s, "profile-1", "woods", "Savage")
  check("a scav raid moves nobody by default",
        not raidEndMoves(s, "profile-1", false, dest), dest)
  check("and moves you when the setting says so",
        raidEndMoves(s, "profile-1", true, dest) and dest == "woods", dest)
  beginRaid(s, "profile-1", "woods", "Something BSG renamed")
  check("an unrecognised side is treated as a PMC raid",
        raidEndMoves(s, "profile-1", false, dest), dest)
  clearRaid(s)
  check("with no raid configured, an ending moves nobody",
        not raidEndMoves(s, "profile-1", true, dest), dest)

  heading "Surviving a rebuild"

  var s2 = newState("sandbox")
  discard moveTo(s2, "lighthouse")
  discard rememberBaseline(s2, "bigmap", false)
  discard rememberBaseline(s2, "terminal", true)
  beginRaid(s2, "p", "woods", "Pmc")
  s2.lastSession = "abc123"
  let round = decode(encode(s2), "nowhere")
  check("position survives", round.position == "lighthouse", round.position)
  check("the move count survives", round.moves == s2.moves, $round.moves)
  check("both baselines survive", round.baseline.len == 2, $round.baseline.len)
  var k2 = false
  check("and each keeps its value",
        baselineLocked(round, "terminal", k2) and k2 and
        not baselineLocked(round, "bigmap", k2), "")
  check("the raid in flight survives", round.pendingLocation == "woods",
        round.pendingLocation)
  check("the session survives", round.lastSession == "abc123", round.lastSession)
  # The pair: rubbish must not decode into a state that looks usable, and in
  # particular must not produce a baseline, because an empty baseline read as
  # "nothing was locked" is the uninstall bug this record exists to prevent.
  let broken = decode("not json at all", "sandbox")
  check("an unreadable state falls back to the starting position",
        broken.position == "sandbox", broken.position)
  check("and carries no baseline at all", broken.baseline.len == 0,
        $broken.baseline.len)
  check("an empty document does the same", decode("", "x").position == "x", "")

proc main() =
  var dbPath = "build\\db\\db.json"
  if paramCount() >= 1:
    dbPath = paramStr(1)
  let dbText = readWholeFile(dbPath)
  if dbText.len == 0:
    echo "FAIL  the database at " & dbPath & " could not be read"
    echo ""
    echo "This test asserts on the real database rather than on a fixture."
    echo "Produce one with: aowl importdb --from D:\\SPT"
    quit 1
  echo "database " & dbPath & " (" & $dbText.len & " bytes)"

  var g = Graph(nodes: @[])
  let read = buildGraph(dbText, g)
  check("every stock map key is in this database", read == 19, $read)
  graphChecks(g)
  stateChecks()

  heading "Result"
  if gFailures == 0:
    echo "ok    " & $gChecks & " checks passed"
  else:
    echo "FAIL  " & $gFailures & " of " & $gChecks & " checks failed"
    quit 1

main()
